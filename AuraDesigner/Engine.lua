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
local GetTime = GetTime

-- Debug throttle: only log once per N seconds to avoid spam
local debugLastLog = 0
local DEBUG_INTERVAL = 3  -- seconds between debug dumps

DF.AuraDesigner = DF.AuraDesigner or {}

local Engine = {}
DF.AuraDesigner.Engine = Engine

local Adapter   -- Set during init
local Indicators -- Set during init (AuraDesigner/Indicators.lua)

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
    { key = "nametext",   placed = false },
    { key = "healthtext", placed = false },
    { key = "framealpha", placed = false },
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
    return a.priority < b.priority  -- Lower number = higher priority (1 wins over 10)
end

-- ============================================================
-- LAYOUT GROUP RESOLUTION
-- Builds lookup tables for layout group membership and computes
-- which grouped indicators are currently active.
-- ============================================================

local function ResolveLayoutGroups(adDB, activeInds)
    wipe(groupLookup)
    wipe(groupActiveMembers)

    if not adDB.layoutGroups then return end

    -- Build lookup from all group members
    for _, group in ipairs(adDB.layoutGroups) do
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
            sort(actives, function(a, b) return a.memberIdx < b.memberIdx end)
        end
    end
end

-- ============================================================
-- SPEC RESOLUTION
-- ============================================================

function Engine:ResolveSpec(adDB)
    if adDB.spec == "auto" then
        return Adapter:GetPlayerSpec()
    end
    return adDB.spec
end

-- ============================================================
-- MAIN UPDATE FUNCTION
-- Called per frame from UpdateAuras when Aura Designer is enabled.
-- ============================================================

function Engine:UpdateFrame(frame)
    -- Lazy init references
    if not Adapter then
        Adapter = DF.AuraDesigner.Adapter
    end
    if not Indicators then
        Indicators = DF.AuraDesigner.Indicators
    end
    if not Adapter or not Indicators then return end

    local unit = frame.unit
    if not unit or not UnitExists(unit) then
        Indicators:HideAll(frame)
        return
    end

    local db = DF:GetFrameDB(frame)
    if not db then return end
    local adDB = db.auraDesigner
    if not adDB then return end

    local spec = self:ResolveSpec(adDB)
    if not spec then
        Indicators:HideAll(frame)
        return
    end

    -- Lazy migration: ensure spec-scoped format
    if not adDB._specScopedV1 and DF.MigrateAuraDesignerSpecScope then
        DF.MigrateAuraDesignerSpecScope(adDB)
    end

    -- Debug: throttled diagnostic dump
    local now = GetTime()
    local shouldLog = (now - debugLastLog) >= DEBUG_INTERVAL

    -- Query adapter for active auras on this unit
    local activeAuras = Adapter:GetUnitAuras(unit, spec)

    -- Spec-scoped aura configs
    local specAuras = adDB.auras and adDB.auras[spec]

    if shouldLog then
        debugLastLog = now
        -- Count active auras from adapter
        local activeCount = 0
        for k in pairs(activeAuras) do activeCount = activeCount + 1 end
        -- Count configured auras and indicators
        local configCount = 0
        local configIndicators = 0
        if specAuras then
            for auraName, auraCfg in pairs(specAuras) do
                configCount = configCount + 1
                if auraCfg.indicators then
                    configIndicators = configIndicators + #auraCfg.indicators
                end
                for _, typeDef in ipairs(FRAME_LEVEL_TYPES) do
                    if auraCfg[typeDef.key] then configIndicators = configIndicators + 1 end
                end
            end
        end
        local providerName = Adapter:GetSourceName() or "none"
        DF:Debug("AD", "Engine: unit=%s spec=%s provider=%s active=%d configured=%d indicators=%d", unit, tostring(spec), providerName, activeCount, configCount, configIndicators)
        -- Log active aura names
        for auraName in pairs(activeAuras) do
            DF:Debug("AD", "  active: %s", auraName)
        end
        -- Log configured auras with their indicators
        if specAuras then
            for auraName, auraCfg in pairs(specAuras) do
                local types = {}
                if auraCfg.indicators then
                    for _, ind in ipairs(auraCfg.indicators) do
                        types[#types+1] = ind.type .. "#" .. ind.id
                    end
                end
                for _, typeDef in ipairs(FRAME_LEVEL_TYPES) do
                    local typeCfg = auraCfg[typeDef.key]
                    if typeCfg then
                        local trigStr = typeDef.key
                        if typeCfg.triggers and #typeCfg.triggers > 1 then
                            trigStr = trigStr .. "(triggers:" .. table.concat(typeCfg.triggers, ",") .. ")"
                        end
                        types[#types+1] = trigStr
                    end
                end
                DF:Debug("AD", "  config: %s -> %s", auraName, #types > 0 and table.concat(types, ", ") or "(no indicators)")
            end
        end
    end

    -- Gather configured auras that are currently active
    wipe(activeIndicators)
    local auras = specAuras
    if auras then
        for auraName, auraCfg in pairs(auras) do
            local auraData = activeAuras[auraName]
            if auraData then
                -- Skip blacklisted auras
                local blTable = DF.db and DF.db.auraBlacklist
                if blTable and auraData.spellId and DF.AuraBlacklist and DF.AuraBlacklist.IsBlacklisted(blTable.buffs, auraData.spellId) then
                    auraData = nil
                end
            end

            local priority = auraCfg.priority or 5

            -- Placed indicators from instances array (only when owning aura is active)
            if auraData then
                if auraCfg.indicators then
                    for _, indicator in ipairs(auraCfg.indicators) do
                        tinsert(activeIndicators, {
                            auraName    = auraName,
                            instanceKey = auraName .. "#" .. indicator.id,
                            typeKey     = indicator.type,
                            placed      = true,
                            config      = indicator,
                            auraData    = auraData,
                            priority    = priority,
                        })
                    end
                end
            end

            -- Frame-level indicators: check triggers array if present,
            -- otherwise fall back to owning aura only (legacy behavior)
            for _, typeDef in ipairs(FRAME_LEVEL_TYPES) do
                local typeCfg = auraCfg[typeDef.key]
                if typeCfg then
                    local triggerAuraData = nil
                    local triggers = typeCfg.triggers
                    if triggers then
                        -- Multi-trigger: fire if ANY trigger aura is active.
                        -- Pick the trigger with the highest remaining duration
                        -- so expiring color transitions use the longest-lasting aura.
                        local bestRemaining = -1
                        for _, trigName in ipairs(triggers) do
                            local trigData = activeAuras[trigName]
                            if trigData then
                                local expTime = trigData.expirationTime
                                if not expTime or expTime == 0 then
                                    -- Permanent buff — always prefer, never expires
                                    triggerAuraData = trigData
                                    bestRemaining = math.huge
                                else
                                    local remaining = expTime - now
                                    if remaining > bestRemaining then
                                        bestRemaining = remaining
                                        triggerAuraData = trigData
                                    end
                                end
                            end
                        end
                    else
                        -- Legacy: just use owning aura
                        triggerAuraData = auraData
                    end

                    if triggerAuraData then
                        tinsert(activeIndicators, {
                            auraName = auraName,
                            typeKey  = typeDef.key,
                            placed   = false,
                            config   = typeCfg,
                            auraData = triggerAuraData,
                            priority = priority,
                        })
                    end
                end
            end
        end
    end

    -- Expose active auraInstanceIDs on the frame for buff bar deduplication.
    -- Include auras with ANY indicator type (placed or frame-level) so the
    -- buff bar doesn't show duplicates of tracked auras.
    -- Also dedup trigger auras for multi-trigger frame effects.
    if not frame.dfAD_activeInstanceIDs then
        frame.dfAD_activeInstanceIDs = {}
    end
    wipe(frame.dfAD_activeInstanceIDs)
    if auras then
        for auraName, auraCfg in pairs(auras) do
            local auraData = activeAuras[auraName]
            if auraData and auraData.auraInstanceID then
                local hasIndicator = auraCfg.indicators and #auraCfg.indicators > 0
                if not hasIndicator then
                    for _, typeDef in ipairs(FRAME_LEVEL_TYPES) do
                        if auraCfg[typeDef.key] then
                            hasIndicator = true
                            break
                        end
                    end
                end
                if hasIndicator then
                    frame.dfAD_activeInstanceIDs[auraData.auraInstanceID] = true
                end
            end
            -- Also mark trigger auras for dedup when multi-trigger is configured
            for _, typeDef in ipairs(FRAME_LEVEL_TYPES) do
                local typeCfg = auraCfg[typeDef.key]
                if typeCfg and typeCfg.triggers then
                    for _, trigName in ipairs(typeCfg.triggers) do
                        local trigData = activeAuras[trigName]
                        if trigData and trigData.auraInstanceID then
                            frame.dfAD_activeInstanceIDs[trigData.auraInstanceID] = true
                        end
                    end
                end
            end
        end
    end

    -- Sort by priority (higher priority wins frame-level conflicts)
    if #activeIndicators > 1 then
        sort(activeIndicators, prioritySort)
    end

    if shouldLog then
        local inCombat = InCombatLockdown() and "yes" or "no"
        if #activeIndicators > 0 then
            DF:Debug("AD", "Dispatching %d indicators for %s (combat=%s)", #activeIndicators, unit, inCombat)
        else
            DF:Debug("AD", "No active indicators for %s (combat=%s)", unit, inCombat)
        end
    end

    -- Resolve layout group membership and compute active members
    ResolveLayoutGroups(adDB, activeIndicators)

    -- Dispatch to indicator renderers
    Indicators:BeginFrame(frame)

    local setmetatable = setmetatable
    for _, ind in ipairs(activeIndicators) do
        -- Placed indicators use instanceKey (e.g., "Rejuvenation#1") for pool lookup
        -- Frame-level indicators use auraName
        local key = ind.placed and ind.instanceKey or ind.auraName
        local config = ind.config

        -- Check if this indicator belongs to a layout group
        if ind.placed and ind.instanceKey then
            local entry = groupLookup[ind.instanceKey]
            if entry then
                local group = entry.group
                local actives = groupActiveMembers[group.id]

                -- Find this indicator's position among active members
                local activeIdx = 0
                if actives then
                    for i, am in ipairs(actives) do
                        if am.indicator == ind then activeIdx = i - 1; break end
                    end
                end

                -- Compute offset based on grow direction + active index
                local size = config.size or (adDB.defaults and adDB.defaults.iconSize) or 24
                local scale = config.scale or (adDB.defaults and adDB.defaults.iconScale) or 1.0
                local step = (size * scale) + (group.spacing or 2)

                local oX, oY = group.offsetX or 0, group.offsetY or 0
                local dir = group.growDirection or "RIGHT"
                if dir == "RIGHT" then
                    oX = oX + (activeIdx * step)
                elseif dir == "LEFT" then
                    oX = oX - (activeIdx * step)
                elseif dir == "DOWN" then
                    oY = oY - (activeIdx * step)
                elseif dir == "UP" then
                    oY = oY + (activeIdx * step)
                end

                -- Create a lightweight metatable wrapper so we don't mutate saved config
                config = setmetatable({
                    anchor = group.anchor or "TOPLEFT",
                    offsetX = oX,
                    offsetY = oY,
                }, { __index = ind.config })
            end
        end

        Indicators:Apply(frame, ind.typeKey, config, ind.auraData, adDB.defaults, key, ind.priority)
    end

    -- Hide/revert anything not applied this frame
    Indicators:EndFrame(frame)
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
    -- Clear active instance IDs so buff bar dedup doesn't stale-filter
    if frame.dfAD_activeInstanceIDs then
        wipe(frame.dfAD_activeInstanceIDs)
    end
end

-- ============================================================
-- FORCE REFRESH ALL AD-ENABLED FRAMES
-- Re-runs UpdateFrame on every visible AD frame so changed
-- global defaults (fonts, sizes, etc.) take effect immediately.
-- ============================================================

function Engine:ForceRefreshAllFrames()
    local function TryUpdate(frame)
        if frame and frame:IsVisible() and DF:IsAuraDesignerEnabled(frame) then
            Engine:UpdateFrame(frame)
        end
    end

    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(TryUpdate)
    end
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(TryUpdate)
    end

    -- Also refresh pinned frames
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
end
