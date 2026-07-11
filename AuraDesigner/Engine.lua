local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - ENGINE
-- Runtime loop that reads per-aura config, queries the adapter
-- for active auras, and dispatches to indicator renderers.
--
-- Called from the frame update cycle (UpdateAuras) when the
-- Aura Designer is enabled for a frame's mode.
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local tinsert = table.insert
local sort = table.sort
local wipe = table.wipe
local floor = math.floor
local strsplit = strsplit
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local issecretvalue = issecretvalue or function() return false end

-- Debug throttle: only log once per N seconds to avoid spam
local debugLastLog = 0
local DEBUG_INTERVAL = 3  -- seconds between debug dumps

-- Track which spec aura tables have been sanitized this session
local sanitizedSpecAuras = {}

DF.AuraDesigner = DF.AuraDesigner or {}
DF.adConfigVersion = 0

local Engine = {}
DF.AuraDesigner.Engine = Engine

local Adapter   -- Set during init
local Indicators -- Set during init (AuraDesigner/Indicators.lua)
local SoundEngine -- Set during init (AuraDesigner/SoundEngine.lua)

-- ============================================================
-- GROUP GRID LAYOUT HELPER
-- Computes X/Y offsets for a group member based on growth
-- direction, icons per row, and active index.
-- ============================================================

local function GetGroupGrowthOffset(direction, step)
    if direction == "LEFT" then      return -step, 0
    elseif direction == "RIGHT" then return step, 0
    elseif direction == "UP" then    return 0, step
    elseif direction == "DOWN" then  return 0, -step
    end
    return 0, 0
end

local function ComputeGroupOffset(group, activeIdx, step, totalCount)
    local growth = group.growDirection or "RIGHT"
    local primary, secondary = strsplit("_", growth)
    -- Legacy single-direction compat: if no underscore, default secondary
    if not secondary then
        if primary == "RIGHT" or primary == "LEFT" then
            secondary = "DOWN"
        else
            secondary = "RIGHT"
        end
    end

    local wrap = group.iconsPerRow or 8
    if wrap < 1 then wrap = 1 end

    local col = activeIdx % wrap
    local row = floor(activeIdx / wrap)

    local sX, sY = GetGroupGrowthOffset(secondary, step)

    if primary == "CENTER" then
        -- Center icons within each row
        local iconsInRow = wrap
        if totalCount then
            local lastRow = floor((totalCount - 1) / wrap)
            if row == lastRow then
                iconsInRow = ((totalCount - 1) % wrap) + 1
            end
        end
        local centerOffset = -((iconsInRow - 1) * step) / 2
        -- Determine center axis from secondary direction
        local cX, cY
        if sX ~= 0 then
            -- Secondary is horizontal, so center vertically
            cX = 0
            cY = centerOffset + (col * step)
        else
            -- Secondary is vertical (or zero), so center horizontally
            cX = centerOffset + (col * step)
            cY = 0
        end
        return (group.offsetX or 0) + cX + (row * sX),
               (group.offsetY or 0) + cY + (row * sY)
    else
        local pX, pY = GetGroupGrowthOffset(primary, step)
        return (group.offsetX or 0) + (col * pX) + (row * sX),
               (group.offsetY or 0) + (col * pY) + (row * sY)
    end
end

-- ============================================================
-- INDICATOR TYPE DEFINITIONS
-- Ordered: placed types first, then frame-level types
-- ============================================================

local INDICATOR_TYPES = {
    { key = "icon",       placed = true  },
    { key = "square",     placed = true  },
    { key = "bar",        placed = true  },
    { key = "border",     placed = false },
    { key = "healthbar",  placed = false },
    { key = "background",  placed = false },
    { key = "nametext",   placed = false },
    { key = "healthtext", placed = false },
    { key = "framealpha", placed = false },
    { key = "sound",      placed = false },
}

-- Frame-level types only (for gathering loop — placed types come from indicators array)
local FRAME_LEVEL_TYPES = {}
for _, typeDef in ipairs(INDICATOR_TYPES) do
    if not typeDef.placed then
        FRAME_LEVEL_TYPES[#FRAME_LEVEL_TYPES + 1] = typeDef
    end
end

-- ============================================================
-- REUSABLE TABLES (avoid per-frame allocation)
-- ============================================================

local activeIndicators = {}  -- Reused each frame: { { auraName, typeKey, config, auraData, priority } }
local groupLookup = {}       -- Reused: "auraName#indicatorID" → { group, memberIdx }
local groupActiveMembers = {} -- Reused: groupID → { ordered active members }

local function prioritySort(a, b)
    return a.priority > b.priority  -- Higher number = higher priority (10 wins over 1)
end

-- Hoisted from an inline closure inside ResolveLayoutGroups' sort call.
-- Module-level so table.sort doesn't allocate a fresh closure every
-- Engine:UpdateTestFrame call.
local function memberIdxSort(a, b)
    return a.memberIdx < b.memberIdx
end

-- ============================================================
-- INDICATOR ENTRY POOL
-- ============================================================
-- activeIndicators is a list of small tables, each describing one
-- tracked-aura indicator for a single frame update. Old code did
-- `tinsert(activeIndicators, { auraName=..., instanceKey=..., ... })`
-- at 2-4 sites per Engine:UpdateTestFrame call, allocating a fresh 7-8
-- field table per tinsert. For a Restoration Druid with ~15 tracked
-- auras and a few active at any given time, that's 3-10 fresh tables
-- per call at 1-5 calls/sec per unit in raid — a real contributor to
-- the 10-15 KB/call observed in UpdateAuras_Enhanced's profile row
-- after Fix A commit 4 landed.
--
-- Pool strategy: reuse entries across calls. At the start of each
-- Engine:UpdateTestFrame, return all entries from the previous run to
-- the pool before wiping activeIndicators. New entries come from
-- AcquireIndicatorEntry which either pulls from the pool or
-- allocates a single table.
--
-- Fields MUST be explicitly set by the caller — the acquire step
-- does not clear them, and stale values from a previous use would
-- leak if the caller relies on nil. The release step clears all
-- known fields so the table is safe to reuse.
local indicatorEntryPool = {}
local INDICATOR_POOL_MAX = 64  -- generous cap for any realistic AD config

local function AcquireIndicatorEntry()
    local n = #indicatorEntryPool
    if n > 0 then
        local entry = indicatorEntryPool[n]
        indicatorEntryPool[n] = nil
        return entry
    end
    return {}
end

local function ReleaseIndicatorEntry(entry)
    -- Clear all fields that any tinsert site sets — prevents stale
    -- values leaking when the entry is reused for a different code
    -- path (e.g. a placed-indicator entry being reused for a
    -- frame-level-indicator entry that doesn't have instanceKey).
    entry.auraName = nil
    entry.instanceKey = nil
    entry.typeKey = nil
    entry.placed = nil
    entry.config = nil
    entry.auraData = nil
    entry.isMissingAura = nil
    entry.priority = nil
    if #indicatorEntryPool < INDICATOR_POOL_MAX then
        indicatorEntryPool[#indicatorEntryPool + 1] = entry
    end
    -- else: drop the entry, let GC collect it (only if pool is saturated)
end

-- Release all entries currently in the active list and wipe it.
-- Called at the start of Engine:UpdateTestFrame before the new run
-- rebuilds the list.
local function ReleaseAndWipeActiveIndicators()
    for i = 1, #activeIndicators do
        ReleaseIndicatorEntry(activeIndicators[i])
    end
    wipe(activeIndicators)
end

-- ============================================================
-- INSTANCE KEY CACHE
-- ============================================================
-- `instanceKey` is the string "auraName#indicatorID" used by
-- Indicators:Configure/Apply for pool lookup and by the layout
-- group system for member identification. The old code built this
-- string fresh every call via concatenation — each concat allocates
-- a new Lua string.
--
-- Cache the string per (auraName, indicatorID) pair. For a typical
-- AD config the set of unique keys is small (one per indicator,
-- ~15-50 total) and never grows during normal play. After warmup,
-- GetInstanceKey is a pure two-level table lookup with zero
-- allocation.
local instanceKeyCache = {}  -- [auraName] = { [indicatorID] = "auraName#indicatorID" }

local function GetInstanceKey(auraName, indicatorID)
    local sub = instanceKeyCache[auraName]
    if not sub then
        sub = {}
        instanceKeyCache[auraName] = sub
    end
    local key = sub[indicatorID]
    if not key then
        key = auraName .. "#" .. indicatorID
        sub[indicatorID] = key
    end
    return key
end

-- ============================================================
-- LAYOUT GROUP RESOLUTION
-- Builds lookup tables for layout group membership and computes
-- which grouped indicators are currently active.
-- ============================================================

local function ResolveLayoutGroups(adDB, activeInds, spec)
    wipe(groupLookup)
    wipe(groupActiveMembers)

    local specGroups = adDB.layoutGroups and adDB.layoutGroups[spec]
    if not specGroups then return end

    -- Build lookup from all group members
    for _, group in ipairs(specGroups) do
        if group.members then
            groupActiveMembers[group.id] = {}
            for memberIdx, member in ipairs(group.members) do
                local key = member.auraName .. "#" .. member.indicatorID
                groupLookup[key] = { group = group, memberIdx = memberIdx }
            end
        end
    end

    -- Identify which group members are active (in display order)
    for _, ind in ipairs(activeInds) do
        if ind.placed and ind.instanceKey then
            local entry = groupLookup[ind.instanceKey]
            if entry and groupActiveMembers[entry.group.id] then
                tinsert(groupActiveMembers[entry.group.id], { indicator = ind, memberIdx = entry.memberIdx })
            end
        end
    end

    -- Sort each group's active members by their member order
    for _, actives in pairs(groupActiveMembers) do
        if #actives > 1 then
            sort(actives, memberIdxSort)
        end
    end
end

-- ============================================================
-- SYNTHETIC AURA DATA (Show When Missing)
-- ============================================================

local function buildSyntheticAuraData(auraName, spec)
    local spellIds = DF.AuraDesigner.SpellIDs and DF.AuraDesigner.SpellIDs[spec]
    local sidRaw = spellIds and spellIds[auraName]
    local sid = type(sidRaw) == "number" and sidRaw or (type(sidRaw) == "table" and sidRaw[1] or 0)
    local iconTextures = DF.AuraDesigner.IconTextures
    local icon = iconTextures and iconTextures[auraName] or 136243
    return {
        spellId = sid,
        icon = icon,
        duration = 0,
        expirationTime = 0,
        stacks = 0,
        caster = nil,
        auraInstanceID = nil,
        isMissingAura = true,
    }
end

-- ============================================================
-- SPEC RESOLUTION
-- ============================================================

function Engine:ResolveSpec(adDB)
    if adDB.spec == "auto" then
        if not Adapter then
            Adapter = DF.AuraDesigner.Adapter
        end
        if not Adapter then return nil end
        return Adapter:GetPlayerSpec()
    end
    return adDB.spec
end

-- ============================================================
-- HIDE ALL INDICATORS
-- Called when Aura Designer is disabled or unit doesn't exist.
-- ============================================================

function Engine:ClearFrame(frame)
    if not Indicators then
        Indicators = DF.AuraDesigner.Indicators
    end
    if Indicators then
        Indicators:HideAll(frame)
    end
    -- Tear down any native-factory AD containers (12.1 path) hung off this frame.
    if DF.AuraDesigner.Factory then
        DF.AuraDesigner.Factory:ClearFrame(frame)
    end
    -- Stop sound engine when AD is disabled
    if not SoundEngine then
        SoundEngine = DF.AuraDesigner.SoundEngine
    end
    if SoundEngine then
        SoundEngine:StopAll()
    end
    -- Clear active instance IDs so buff bar dedup doesn't stale-filter
    if frame.dfAD_activeInstanceIDs then
        wipe(frame.dfAD_activeInstanceIDs)
    end
end

-- ============================================================
-- TEST MODE UPDATE
-- Renders AD indicators on test frames using mock aura data
-- built from the user's configured auras for their spec.
-- ============================================================

function Engine:UpdateTestFrame(frame)
    -- Lazy init references
    if not Adapter then
        Adapter = DF.AuraDesigner.Adapter
    end
    if not Indicators then
        Indicators = DF.AuraDesigner.Indicators
    end
    if not Indicators then return end

    -- Pinned set with Hide Auras: clear AD indicators (see UpdateFrame).
    if frame.dfPinnedHideAuras then
        Indicators:HideAll(frame)
        return
    end

    -- Skip invisible frames (e.g. disabled pinned frame children)
    if not frame:IsVisible() then return end

    local db = DF:GetFrameDB(frame)
    if not db then return end
    local adDB = DF:ResolveAuraDesigner(frame)
    if not adDB or not adDB.enabled then
        Indicators:HideAll(frame)
        return
    end

    local spec = self:ResolveSpec(adDB)
    if not spec then
        Indicators:HideAll(frame)
        return
    end

    -- Lazy migration
    if (not adDB._specScopedV1 or not adDB._specScopedV2) and DF.MigrateAuraDesignerSpecScope then
        DF.MigrateAuraDesignerSpecScope(adDB)
    end
    if DF.MigrateAuraDesignerInstancesLazy then DF.MigrateAuraDesignerInstancesLazy(adDB) end
    if DF.MigrateAuraDesignerBorderKeysLazy then DF.MigrateAuraDesignerBorderKeysLazy(adDB) end
    if DF.MigrateAuraDesignerPrioritiesLazy then DF.MigrateAuraDesignerPrioritiesLazy(adDB) end

    local specAuras = adDB.auras and adDB.auras[spec]
    if not specAuras then
        Indicators:HideAll(frame)
        return
    end

    -- Build mock activeAuras from configured auras
    local specSpellIDs = DF.AuraDesigner.SpellIDs and DF.AuraDesigner.SpellIDs[spec] or {}
    local iconTextures = DF.AuraDesigner.IconTextures or {}
    local now = GetTime()
    local mockCounter = 99000

    -- Release entries from the previous call back to the pool before
    -- rebuilding.
    ReleaseAndWipeActiveIndicators()

    for auraName, auraCfg in pairs(specAuras) do
      if type(auraCfg) == "table" then
        -- Build mock aura data for this configured aura
        local spellId = specSpellIDs[auraName] or 0
        local icon = iconTextures[auraName]
        if not icon and spellId > 0 and C_Spell and C_Spell.GetSpellTexture then
            icon = C_Spell.GetSpellTexture(spellId)
        end
        mockCounter = mockCounter + 1

        local auraData = {
            spellId = spellId,
            icon = icon or 136243,  -- question mark fallback
            duration = 0,           -- 0 = permanent (bars show full fill, no countdown)
            expirationTime = 0,
            stacks = 0,
            caster = "player",
            auraInstanceID = nil,   -- nil so bar OnUpdate skips expiration guard
        }

        local priority = auraCfg.priority or 5

        -- Check if ALL indicators want missing mode — if so, nil out mock data
        -- so showWhenMissing indicators render in test mode
        local allMissing = true
        if auraCfg.indicators then
            for _, indicator in ipairs(auraCfg.indicators) do
                if not indicator.showWhenMissing or indicator.type == "bar" then
                    allMissing = false
                    break
                end
            end
        else
            allMissing = false
        end
        if allMissing then
            for _, typeDef in ipairs(FRAME_LEVEL_TYPES) do
                local typeCfg = auraCfg[typeDef.key]
                if typeCfg and not typeCfg.showWhenMissing then
                    allMissing = false
                    break
                end
            end
        end
        if allMissing then
            auraData = nil
        end

        -- Placed indicators (handles showWhenMissing)
        if auraCfg.indicators then
            for _, indicator in ipairs(auraCfg.indicators) do
                local isMissing = not auraData
                local wantMissing = indicator.showWhenMissing
                if indicator.type == "bar" then wantMissing = false end

                if wantMissing then
                    -- Always add: missing → synthetic, present → real (Apply handles visibility)
                    local effectiveAuraData = auraData
                    if isMissing then
                        effectiveAuraData = buildSyntheticAuraData(auraName, spec)
                    end
                    local entry = AcquireIndicatorEntry()
                    entry.auraName      = auraName
                    entry.instanceKey   = GetInstanceKey(auraName, indicator.id)
                    entry.typeKey       = indicator.type
                    entry.placed        = true
                    entry.config        = indicator
                    entry.auraData      = effectiveAuraData
                    entry.isMissingAura = isMissing
                    entry.priority      = priority
                    tinsert(activeIndicators, entry)
                elseif auraData then
                    local entry = AcquireIndicatorEntry()
                    entry.auraName    = auraName
                    entry.instanceKey = GetInstanceKey(auraName, indicator.id)
                    entry.typeKey     = indicator.type
                    entry.placed      = true
                    entry.config      = indicator
                    entry.auraData    = auraData
                    -- isMissingAura intentionally left nil
                    entry.priority    = priority
                    tinsert(activeIndicators, entry)
                end
            end
        end

        -- Frame-level indicators (handles showWhenMissing)
        for _, typeDef in ipairs(FRAME_LEVEL_TYPES) do
            local typeCfg = auraCfg[typeDef.key]
            if typeCfg then
                local wantMissing = typeCfg.showWhenMissing
                local isMissing = not auraData
                if wantMissing then
                    -- Always add: missing → synthetic, present → real (Apply handles visibility)
                    local effectiveAuraData = auraData
                    if isMissing then
                        effectiveAuraData = buildSyntheticAuraData(auraName, spec)
                    end
                    local entry = AcquireIndicatorEntry()
                    entry.auraName    = auraName
                    -- instanceKey intentionally left nil (frame-level indicator)
                    entry.typeKey     = typeDef.key
                    entry.placed      = false
                    entry.config      = typeCfg
                    entry.auraData    = effectiveAuraData
                    -- isMissingAura intentionally left nil (legacy test-mode behavior
                    -- didn't set this — matches the pre-refactor state)
                    entry.priority    = priority
                    tinsert(activeIndicators, entry)
                elseif auraData then
                    local entry = AcquireIndicatorEntry()
                    entry.auraName    = auraName
                    -- instanceKey intentionally left nil (frame-level indicator)
                    entry.typeKey     = typeDef.key
                    entry.placed      = false
                    entry.config      = typeCfg
                    entry.auraData    = auraData
                    -- isMissingAura intentionally left nil
                    entry.priority    = priority
                    tinsert(activeIndicators, entry)
                end
            end
        end
      end
    end

    -- Sort by priority
    if #activeIndicators > 1 then
        sort(activeIndicators, prioritySort)
    end

    -- Resolve layout groups
    ResolveLayoutGroups(adDB, activeIndicators, spec)

    -- Dispatch to indicator renderers (using ApplyTest to skip aura validation)
    Indicators:BeginFrame(frame)

    local setmetatable = setmetatable
    for _, ind in ipairs(activeIndicators) do
        local key = ind.placed and ind.instanceKey or ind.auraName
        local config = ind.config

        -- Layout group position override (same as production)
        if ind.placed and ind.instanceKey then
            local entry = groupLookup[ind.instanceKey]
            if entry then
                local group = entry.group
                local actives = groupActiveMembers[group.id]
                local activeIdx = 0
                if actives then
                    for i, am in ipairs(actives) do
                        if am.indicator == ind then activeIdx = i - 1; break end
                    end
                end
                local size = config.size or (adDB.defaults and adDB.defaults.iconSize) or 24
                local scale = config.scale or (adDB.defaults and adDB.defaults.iconScale) or 1.0
                local step = (size * scale) + (group.spacing or 2)
                local oX, oY = ComputeGroupOffset(group, activeIdx, step, actives and #actives or 0)
                config = setmetatable({
                    anchor = group.anchor or "TOPLEFT",
                    offsetX = oX,
                    offsetY = oY,
                }, { __index = ind.config })
            end
        end

        Indicators:ApplyTest(frame, ind.typeKey, config, ind.auraData, adDB.defaults, key, ind.priority)
    end

    Indicators:EndFrame(frame)
end

-- ============================================================
-- FORCE REFRESH ALL AD-ENABLED FRAMES
-- Re-runs UpdateFrame on every visible AD frame so changed
-- global defaults (fonts, sizes, etc.) take effect immediately.
-- ============================================================

function Engine:ForceRefreshAllFrames()
    -- Bump config version so indicators reconfigure on their next paint
    -- (the test renderer's widgets gate on this).
    DF.adConfigVersion = (DF.adConfigVersion or 0) + 1

    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    local function TryUpdate(frame)
        if not frame then return end
        if DF:IsAuraDesignerEnabled(frame) then
            -- Live 12.1 path: re-sync the factory containers immediately so an
            -- editor change applies now, not one aura event late.
            if frame:IsVisible() and Factory and DF.UseFactoryForAD
                and DF:UseFactoryForAD(frame, DF:GetFrameDB(frame)) then
                Factory:SyncFrame(frame)
            end
        else
            -- AD is OFF for this frame's mode (toggled off, or a profile swap to
            -- an AD-off profile) -- tear down any leftover indicators so they
            -- don't linger on screen until the next /reload.
            Engine:ClearFrame(frame)
        end
    end

    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(TryUpdate)
    end
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(TryUpdate)
    end
    if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
        for setIndex = 1, 2 do
            local header = DF.PinnedFrames.headers[setIndex]
            if header and header:IsShown() then
                for i = 1, 40 do
                    local child = header:GetAttribute("child" .. i)
                    if child then TryUpdate(child) end
                end
            end
        end
    end

    -- The native factory buff row derives its Aura-Designer dedup set from the AD
    -- config at build time, so an AD config change must re-drive the buff row for
    -- the derived exclusion to follow (sig-gated, cheap when unchanged).
    if DF.InvalidateAuraLayout then
        DF:InvalidateAuraLayout()
    end

    -- Refresh the test previews too when the editor is used with test mode open.
    if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestAuraDesigner then
        DF:UpdateAllTestAuraDesigner()
    end
end
