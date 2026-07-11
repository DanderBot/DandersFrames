local addonName, DF = ...

-- ============================================================
-- AURA FILTERING SYSTEM
-- Hooks into Blizzard's raid frame aura filtering to capture results
-- ============================================================

-- Local caching of frequently used globals and WoW API for performance
local pairs, ipairs, type, pcall, wipe = pairs, ipairs, type, pcall, wipe
local tinsert, tremove = table.insert, table.remove
local C_UnitAuras = C_UnitAuras
local UnitIsUnit = UnitIsUnit
local GetTime = GetTime

-- Additional cached API for direct aura update (Tier 1 optimization)
local UnitExists = UnitExists
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsConnected = UnitIsConnected
local InCombatLockdown = InCombatLockdown
local issecretvalue = issecretvalue
local strsplit = strsplit
local C_CurveUtil = C_CurveUtil
local GetAuraDataByAuraInstanceID = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID
local IsAuraFilteredOut = C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID
-- Fix A additions: slot-based iteration APIs (used by ScanUnitFull)
local GetAuraSlots = C_UnitAuras and C_UnitAuras.GetAuraSlots
local GetAuraDataBySlot = C_UnitAuras and C_UnitAuras.GetAuraDataBySlot
local strfind = string.find

-- Roster-unit allowlist guard. The 12.0.5 aura APIs reject compound unit
-- tokens like `boss1targetpet` with a hard error, so any aura-scanning
-- function that can be reached with an arbitrary unit token (frame hooks,
-- external callers) needs to early-return on non-roster tokens before
-- touching them. Same allowlist pattern v4.2.6 added to SecretAuras as an
-- interim filter — same problem, different code path.
local function IsRosterUnit(unit)
    if not unit then return false end
    if unit == "player" then return true end
    if strfind(unit, "^party%d$") then return true end
    if strfind(unit, "^raid%d+$") then return true end
    if strfind(unit, "^boss%d$") then return true end
    return false
end

-- Table pool to reduce garbage collection
-- PERFORMANCE FIX 2025-01-20: Reuse aura entry tables instead of creating new ones
local tablePool = {}
local poolSize = 0

local function AcquireTable()
    if poolSize > 0 then
        local t = tablePool[poolSize]
        tablePool[poolSize] = nil
        poolSize = poolSize - 1
        return t
    end
    return {}
end

local function ReleaseTable(t)
    if t then
        wipe(t)
        poolSize = poolSize + 1
        tablePool[poolSize] = t
    end
end

-- Helper to release all entry tables in an array before wiping
-- This returns entries to the pool so they can be reused
local function ReleaseAndWipe(arr)
    for i = 1, #arr do
        ReleaseTable(arr[i])
        arr[i] = nil
    end
end

-- Reusable result arrays for aura collection (reduces garbage)
-- These get wiped and reused each call instead of creating new tables

-- Per-unit aura cache, the single source of truth for aura data across
-- all DF consumers (Direct mode aura pipeline, Aura Designer, defensive
-- icon, dispel overlay, sound engine, missing-buff detection, etc.).
--
-- Originally named DF.BlizzardAuraCache because it was populated only
-- from Blizzard's compact frame state. Since Direct mode was added and
-- Blizzard mode is being removed in the upcoming 12.0.5 patch, the
-- cache is no longer Blizzard-specific. `DF.AuraCache` is the new
-- canonical name; `DF.BlizzardAuraCache` is kept as an alias for the
-- ~35 existing call sites and for third-party code that may reference
-- the old name. Both names reference the same underlying table.
--
-- Cache entry shape (per unit):
--
--   buffs             = { [auraInstanceID] = true }   -- buffs that pass the user's buff filter
--   debuffs           = { [auraInstanceID] = true }   -- debuffs that pass the user's debuff filter
--   buffOrder         = { [i] = auraInstanceID }      -- sorted display order for buffs
--   debuffOrder       = { [i] = auraInstanceID }      -- sorted display order for debuffs
--   buffData          = { [i] = auraData }            -- legacy sorted array (Direct mode only)
--   debuffData        = { [i] = auraData }            -- legacy sorted array (Direct mode only)
--   playerDispellable = { [auraInstanceID] = true }   -- debuffs the player can dispel
--   allDispellable    = { [auraInstanceID] = true }   -- debuffs anyone can dispel
--   defensives        = { [auraInstanceID] = true }   -- tracked defensive auras
--
-- Fix A extensions (added 2026-04-08, consumers not yet migrated):
--
--   buffsByID         = { [auraInstanceID] = auraData }  -- raw aura data, unsorted, keyed by ID
--   debuffsByID       = { [auraInstanceID] = auraData }  -- raw aura data, unsorted, keyed by ID
--   hasFullScan       = boolean                          -- true once ScanUnitFull has run for this unit
--   buffOrderDirty    = boolean                          -- true if buffOrder needs to be re-sorted
--   debuffOrderDirty  = boolean                          -- true if debuffOrder needs to be re-sorted
--
-- Fix A commit 1 (infrastructure): the new ScanUnitFull and
-- ApplyAuraDelta helpers populate the new fields, but the hot path
-- (directModeSubscriber:OnUnitAura) still calls the old ScanUnitDirect
-- which populates the legacy fields. Both old and new fields coexist
-- until commit 2 flips the hot path to the incremental model.
DF.AuraCache = {}
DF.BlizzardAuraCache = DF.AuraCache  -- backward-compat alias, same table

-- Ensure a cache entry exists for a unit. Creates the full shape (old
-- legacy fields + new Fix A fields) on first access. Safe to call
-- multiple times — no-op if the entry already exists. Returns the
-- entry table.
local function EnsureAuraCacheEntry(unit)
    local entry = DF.AuraCache[unit]
    if entry then return entry end
    entry = {
        -- Legacy fields (populated by old ScanUnitDirect / Blizzard capture)
        buffs             = {},
        debuffs           = {},
        buffOrder         = {},
        debuffOrder       = {},
        buffData          = {},
        debuffData        = {},
        playerDispellable = {},
        allDispellable    = {},
        defensives        = {},
        -- Fix A new fields (populated by ScanUnitFull / ApplyAuraDelta)
        buffsByID         = {},
        debuffsByID       = {},
        hasFullScan       = false,
        buffOrderDirty    = false,
        debuffOrderDirty  = false,
    }
    DF.AuraCache[unit] = entry
    return entry
end

-- Track if we've successfully hooked Blizzard's frames

-- ============================================================
-- SCAN BLIZZARD FRAMES FOR APPROVED AURAS
-- ============================================================

-- ============================================================
-- TRIGGER AURA UPDATES FOR ALL DF FRAMES SHOWING A UNIT
-- Shared by both Blizzard hook and Direct UNIT_AURA handler
-- ============================================================

local function TriggerAuraUpdateForUnit(unit)
    -- Fast unit→frame lookup via exposed unitFrameMap
    local ourFrame = DF.unitFrameMap and DF.unitFrameMap[unit]

    DF:Debug("BLIZAURA", "TriggerUpdate for %s — unitFrameMap hit: %s", unit, ourFrame and ourFrame:GetName() or "nil")

    -- Fallback: iterate if unitFrameMap not yet available (early init)
    if not ourFrame then
        DF:Debug("BLIZAURA", "TriggerUpdate fallback iterate for %s", unit)
        -- Check arena first (IsInRaid()=true in arena)
        if DF.IsInArena and DF:IsInArena() then
            if DF.IterateArenaFrames then
                DF:IterateArenaFrames(function(f)
                    if f and f.unit == unit then
                        ourFrame = f
                        return true
                    end
                end)
            end
        else
            if DF.IteratePartyFrames then
                DF:IteratePartyFrames(function(f)
                    if f and f.unit == unit then
                        ourFrame = f
                        return true
                    end
                end)
            end
            if not ourFrame and DF.IterateRaidFrames then
                DF:IterateRaidFrames(function(f)
                    if f and f.unit == unit then
                        ourFrame = f
                        return true
                    end
                end)
            end
        end
        if ourFrame then
            DF:Debug("BLIZAURA", "TriggerUpdate fallback found: %s", ourFrame:GetName())
        else
            DF:DebugWarn("BLIZAURA", "TriggerUpdate NO frame found for %s", unit)
        end
    end

    if ourFrame and ourFrame:IsVisible() then
        if DF.UpdateAuras_Enhanced then
            DF:Debug("BLIZAURA", "Calling UpdateAuras_Enhanced for %s on %s", unit, ourFrame:GetName())
            DF:UpdateAuras_Enhanced(ourFrame)
        end
        if DF.UpdateDefensiveBar then
            DF:UpdateDefensiveBar(ourFrame)
        end
        if DF.UpdateMissingBuffIcon then
            -- forceUpdate=true: bypass the cache equality check so a zone-transition
            -- cache wipe can't leave a stale "missing" icon after rebuffing.
            DF:UpdateMissingBuffIcon(ourFrame, true)
        end
        if DF.UpdateDispelOverlay then
            DF:UpdateDispelOverlay(ourFrame)
        end
    elseif ourFrame then
        DF:DebugWarn("BLIZAURA", "TriggerUpdate SKIPPED for %s — frame %s not visible", unit, ourFrame:GetName())
    end

    -- Also update pinned frames showing this unit
    -- (Pinned frames share units with main frames but are excluded from unitFrameMap)
    if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
        local pinnedDB = DF.db and DF.db[IsInRaid() and "raid" or "party"]
        pinnedDB = pinnedDB and pinnedDB.pinnedFrames
        for setIndex = 1, 2 do
            local header = DF.PinnedFrames.headers[setIndex]
            local set = pinnedDB and pinnedDB.sets and pinnedDB.sets[setIndex]
            if header and header:IsShown() and set and set.enabled then
                for i = 1, 40 do
                    local child = header:GetAttribute("child" .. i)
                    if child and child:IsVisible() and child.unit == unit then
                        if DF.UpdateAuras_Enhanced then
                            DF:UpdateAuras_Enhanced(child)
                        end
                        if DF.UpdateDefensiveBar then
                            DF:UpdateDefensiveBar(child)
                        end
                        if DF.UpdateMissingBuffIcon then
                            -- forceUpdate=true: same cache-desync fix as the main fan-out above.
                            DF:UpdateMissingBuffIcon(child, true)
                        end
                        if DF.UpdateDispelOverlay then
                            DF:UpdateDispelOverlay(child)
                        end
                    end
                end
            end
        end
    end

    -- Also update pinned boss frames
    if DF.PinnedFrames and DF.PinnedFrames.bossFrames then
        for setIndex = 1, 2 do
            local frames = DF.PinnedFrames.bossFrames[setIndex]
            if frames then
                for i = 1, 8 do
                    local f = frames[i]
                    if f and f:IsVisible() and f.unit == unit then
                        if DF.UpdateAuras_Enhanced then DF:UpdateAuras_Enhanced(f) end
                        if DF.UpdateDefensiveBar then DF:UpdateDefensiveBar(f) end
                    end
                end
            end
        end
    end
end

-- Forward declarations: these helpers are defined later in the file but used
-- by code above their definitions (the ClassifyAura defensive/dispel filter
-- pass), computing aura classification via the secret-safe
-- IsAuraFilteredOutByInstanceID API.
local BuildDirectDefensiveFilters
local AuraPassesAnyFilter

-- ============================================================
-- DIRECT AURA API PROVIDER
-- Queries C_UnitAuras directly with user-configured filter strings
-- Writes results to DF.BlizzardAuraCache (same structure as Blizzard provider)
-- ============================================================

-- Cache AuraUtil filter constants (available in 11.1+)
local AuraFilters = AuraUtil and AuraUtil.AuraFilters or {}

-- Cached filter tables per mode (rebuilt only when settings change)
-- Each is nil (show all / unavailable) or a table of individual filter strings
-- e.g. {"HELPFUL|PLAYER", "HELPFUL|RAID", "HELPFUL|BIG_DEFENSIVE"}
local cachedPartyBuffFilters = nil
local cachedPartyDebuffFilters = nil
local cachedRaidBuffFilters = nil
local cachedRaidDebuffFilters = nil
local cachedDefensiveFilters = nil   -- mode-independent
local cachedDispelFilter = nil       -- mode-independent (single string, no OR needed)

-- Build individual filter strings for buffs (OR logic via post-classification)
-- Returns nil (show all) or table of "HELPFUL|CLASSIFICATION" strings
local function BuildDirectBuffFilters(db)
    local onlyMine = db.directBuffOnlyMine
    local playerSuffix = onlyMine and "|PLAYER" or ""

    if db.directBuffShowAll then
        return onlyMine and {"HELPFUL|PLAYER"} or nil
    end

    local filters = {}
    if db.directBuffFilterRaid then filters[#filters + 1] = "HELPFUL|RAID" .. playerSuffix end
    if db.directBuffFilterRaidInCombat and AuraFilters.RaidInCombat then
        filters[#filters + 1] = "HELPFUL|" .. AuraFilters.RaidInCombat .. playerSuffix
    end
    if db.directBuffFilterCancelable then filters[#filters + 1] = "HELPFUL|CANCELABLE" .. playerSuffix end
    -- 12.1 (68569) removed the NOT_CANCELABLE token; the "!" negation prefix replaces it, and
    -- AddAuraGroup asserts IsValidFilterString so the old token would hard-error. This branch
    -- is 12.1-only (TOC 120100), so !CANCELABLE is unconditional (12.0.7 lacks "!" — Krathe's
    -- live fix is build-gated).
    if db.directBuffFilterNotCancelable then filters[#filters + 1] = "HELPFUL|!CANCELABLE" .. playerSuffix end
    if db.directBuffFilterBigDefensive and AuraFilters.BigDefensive then
        filters[#filters + 1] = "HELPFUL|" .. AuraFilters.BigDefensive .. playerSuffix
    end
    if db.directBuffFilterExternalDefensive and AuraFilters.ExternalDefensive then
        filters[#filters + 1] = "HELPFUL|" .. AuraFilters.ExternalDefensive .. playerSuffix
    end
    -- No sub-filters selected: show all mine or show all
    if #filters == 0 then
        return onlyMine and {"HELPFUL|PLAYER"} or nil
    end
    return filters
end

-- Build individual filter strings for debuffs (OR logic via post-classification)
-- Returns nil (show all) or table of "HARMFUL|CLASSIFICATION" strings
local function BuildDirectDebuffFilters(db)
    if db.directDebuffShowAll then return nil end
    local filters = {}
    if db.directDebuffFilterRaid then filters[#filters + 1] = "HARMFUL|RAID" end
    if db.directDebuffFilterRaidInCombat and AuraFilters.RaidInCombat then
        filters[#filters + 1] = "HARMFUL|" .. AuraFilters.RaidInCombat
    end
    if db.directDebuffFilterCrowdControl and AuraFilters.CrowdControl then
        filters[#filters + 1] = "HARMFUL|" .. AuraFilters.CrowdControl
    end
    if db.directDebuffDispellableMode == "PLAYER" then
        filters[#filters + 1] = "HARMFUL|" .. (AuraFilters.RaidPlayerDispellable or "RAID_PLAYER_DISPELLABLE")
    end
    -- Note: directDebuffDispellableMode == "ALL" has no Blizzard filter constant —
    -- it's post-classified in ScanUnitDirect via auraData.dispelName ~= nil.
    -- No sub-filters selected = show all (backward compat)
    if #filters == 0 then return nil end
    return filters
end

-- Build defensive filter table (BIG_DEFENSIVE + EXTERNAL_DEFENSIVE, nil if unavailable)
-- Assigned to the forward-declared local at the top of the file so it is
-- visible to code defined above this point.
function BuildDirectDefensiveFilters()
    if cachedDefensiveFilters then return cachedDefensiveFilters end
    local filters = {}
    if AuraFilters.BigDefensive then filters[#filters + 1] = "HELPFUL|" .. AuraFilters.BigDefensive end
    if AuraFilters.ExternalDefensive then filters[#filters + 1] = "HELPFUL|" .. AuraFilters.ExternalDefensive end
    if #filters == 0 then return nil end
    cachedDefensiveFilters = filters
    return cachedDefensiveFilters
end

-- Build dispel filter (HARMFUL + RAID_PLAYER_DISPELLABLE, single string)
local function BuildDirectDispelFilter()
    if cachedDispelFilter then return cachedDispelFilter end
    local dispelConst = AuraFilters.RaidPlayerDispellable or "RAID_PLAYER_DISPELLABLE"
    cachedDispelFilter = "HARMFUL|" .. dispelConst
    return cachedDispelFilter
end

-- Check if an aura passes any filter in a table (OR logic)
-- Returns true if IsAuraFilteredOutByInstanceID says the aura is NOT filtered out
-- for at least one of the provided filter strings.
-- Assigned to the forward-declared local at the top of the file so it is
-- visible to code defined above this point.
function AuraPassesAnyFilter(unit, auraInstanceID, filters)
    if not IsAuraFilteredOut then return true end
    for i = 1, #filters do
        if not IsAuraFilteredOut(unit, auraInstanceID, filters[i]) then
            return true
        end
    end
    return false
end

-- ============================================================
-- FIX A: INCREMENTAL AURA CACHE HELPERS
-- ============================================================
--
-- These two helpers implement the oUF-style incremental aura update
-- pattern. See _Reference/fix-a-plan.md for the full design.
--
-- ScanUnitFull(unit)
--     Full aura scan for a unit. Wipes and rebuilds the entire
--     AuraCache entry from scratch via GetAuraSlots + GetAuraDataBySlot.
--     Called on first access, on isFullUpdate, on mode transitions,
--     and on filter settings changes. Sets cache.hasFullScan = true.
--
-- ApplyAuraDelta(unit, updateInfo)
--     Incremental update for a unit. Applies updateInfo.addedAuras,
--     updateInfo.updatedAuraInstanceIDs, and updateInfo.removedAuraInstanceIDs
--     to the existing cache entry. Called on UNIT_AURA when
--     updateInfo is present and isFullUpdate is false.
--
-- COMMIT 1 STATUS: infrastructure only. These helpers are defined but
-- the hot path (directModeSubscriber:OnUnitAura) still calls the old
-- ScanUnitDirect. Commit 2 will flip the hot path to use these.
--
-- Both helpers populate the NEW cache fields (buffsByID, debuffsByID,
-- classification sets, hasFullScan, buffOrderDirty, debuffOrderDirty)
-- but do NOT touch the legacy fields (buffOrder, buffData, etc.) that
-- the current hot path depends on. Commit 3 and 4 migrate consumers
-- off the legacy fields.
--
-- COMMIT 2 UPDATE: ScanUnitFull and ApplyAuraDelta now ALSO populate
-- the legacy cache.buffOrder / cache.buffData / cache.debuffOrder /
-- cache.debuffData arrays in sorted order via RebuildLegacySortedArrays,
-- so they are drop-in replacements for the old ScanUnitDirect.
-- UpdateAuraIconsDirect (the icon renderer at ~line 2528) continues to
-- read cache.buffData unchanged. Legacy and new fields both stay fresh.
-- ============================================================

-- Sort comparators for Direct mode — moved here (from below) so
-- RebuildLegacySortedArrays can reference them. The pcall wrappers
-- are deliberately left in place per audit finding #8 — some aura
-- data fields may be secret values on Midnight and would silently
-- fail sort comparisons without the guard.
local function SortByTimeRemaining(a, b)
    local ok, result = pcall(function()
        local aExp = a.expirationTime or 0
        local bExp = b.expirationTime or 0
        if aExp == 0 and bExp == 0 then return false end
        if aExp == 0 then return false end
        if bExp == 0 then return true end
        return aExp < bExp
    end)
    if ok then return result end
    return false
end

local function SortByName(a, b)
    local ok, result = pcall(function()
        return (a.name or "") < (b.name or "")
    end)
    if ok then return result end
    return false
end

-- Module-level scratch tables for RebuildLegacySortedArrays — reused
-- across every rebuild to avoid per-call allocation. wipe()'d at the
-- start of each rebuild.
local sortScratchBuffs  = {}
local sortScratchDebuffs = {}

-- ============================================================
-- FIX A DIAGNOSTIC COUNTERS
-- ============================================================
-- Track how often the hot path takes ScanUnitFull vs ApplyAuraDelta.
-- Goal: verify the incremental path is actually being used in steady
-- state, not just falling through to full rescans. Reset via /dfscan
-- (or manually via DF.AuraCacheStats:Reset()) before a test run.
--
-- TEMPORARY DIAGNOSTIC — remove or demote to debug-only after Fix A
-- is verified working in raid content.
-- ============================================================
DF.AuraCacheStats = {
    scanFull       = 0,  -- ScanUnitFull invocations
    deltaApplied   = 0,  -- ApplyAuraDelta invocations that succeeded
    deltaFallback  = 0,  -- ApplyAuraDelta returned false → fell back to ScanUnitFull
    eventsSeen     = 0,  -- total UNIT_AURA events that reached directModeSubscriber:OnUnitAura
}
function DF.AuraCacheStats:Reset()
    self.scanFull = 0
    self.deltaApplied = 0
    self.deltaFallback = 0
    self.eventsSeen = 0
end

-- Rebuild cache.buffData / cache.buffOrder / cache.debuffData /
-- cache.debuffOrder from cache.buffsByID + cache.debuffsByID + the
-- classification sets. Sorted according to the user's sort preference
-- (TIME, NAME, or DEFAULT = insertion order from buffsByID).
--
-- This is the single place where the legacy sorted arrays get
-- populated. Called from both ScanUnitFull (after a full rebuild)
-- and ApplyAuraDelta (after an incremental update).
--
-- Typical N is small (5-20 auras per unit), so the sort cost is
-- negligible. The module-level scratch tables avoid allocation.
local function RebuildLegacySortedArrays(cache, unit, db)
    if not db then return end

    -- ----- BUFFS -----
    wipe(sortScratchBuffs)
    for id, auraData in pairs(cache.buffsByID) do
        -- Only include auras that passed the user's buff filter
        -- (cache.buffs is the set of classified instance IDs)
        if cache.buffs[id] then
            sortScratchBuffs[#sortScratchBuffs + 1] = auraData
        end
    end

    local buffSort = db.directBuffSortOrder or "DEFAULT"
    if buffSort == "TIME" and #sortScratchBuffs > 1 then
        table.sort(sortScratchBuffs, SortByTimeRemaining)
    elseif buffSort == "NAME" and #sortScratchBuffs > 1 then
        table.sort(sortScratchBuffs, SortByName)
    end

    wipe(cache.buffOrder)
    wipe(cache.buffData)
    for i = 1, #sortScratchBuffs do
        local auraData = sortScratchBuffs[i]
        cache.buffOrder[i] = auraData.auraInstanceID
        cache.buffData[i] = auraData
    end
    cache.buffOrderDirty = false

    -- ----- DEBUFFS -----
    wipe(sortScratchDebuffs)
    for id, auraData in pairs(cache.debuffsByID) do
        if cache.debuffs[id] then
            sortScratchDebuffs[#sortScratchDebuffs + 1] = auraData
        end
    end

    local debuffSort = db.directDebuffSortOrder or "DEFAULT"
    if debuffSort == "TIME" and #sortScratchDebuffs > 1 then
        table.sort(sortScratchDebuffs, SortByTimeRemaining)
    elseif debuffSort == "NAME" and #sortScratchDebuffs > 1 then
        table.sort(sortScratchDebuffs, SortByName)
    end

    wipe(cache.debuffOrder)
    wipe(cache.debuffData)
    for i = 1, #sortScratchDebuffs do
        local auraData = sortScratchDebuffs[i]
        cache.debuffOrder[i] = auraData.auraInstanceID
        cache.debuffData[i] = auraData
    end
    cache.debuffOrderDirty = false
end

-- Resolve a unit's filter arrays (per-mode-cached).
-- Returns: buffFilters, debuffFilters, defensiveFilters, dispelFilter
-- Any of these can be nil meaning "show all" for that category.
local function ResolveFiltersForUnit(unit)
    local frame = DF.unitFrameMap and DF.unitFrameMap[unit]
    local db, isRaid
    if frame then
        isRaid = frame.isRaidFrame
        db = isRaid and DF:GetRaidDB() or DF:GetDB()
    else
        db = DF:GetDB()
        isRaid = false
    end
    if not db then return nil, nil, nil, nil end

    local buffFilters = isRaid
        and (cachedRaidBuffFilters or BuildDirectBuffFilters(db))
        or (cachedPartyBuffFilters or BuildDirectBuffFilters(db))
    local debuffFilters = isRaid
        and (cachedRaidDebuffFilters or BuildDirectDebuffFilters(db))
        or (cachedPartyDebuffFilters or BuildDirectDebuffFilters(db))
    local defFilters = BuildDirectDefensiveFilters()
    local dispelFilter = BuildDirectDispelFilter()

    return buffFilters, debuffFilters, defFilters, dispelFilter, db
end

-- Classify a single aura against all filter categories and write the
-- result into the cache's classification sets. Called from both
-- ScanUnitFull (bulk) and ApplyAuraDelta (incremental) so classification
-- logic lives in exactly one place.
--
-- `kind` is either "buff" (helpful auras) or "debuff" (harmful auras).
-- The caller has already done the HELPFUL/HARMFUL split.
local function ClassifyAura(cache, unit, auraData, kind, buffFilters, debuffFilters, defFilters, dispelFilter, db)
    local id = auraData.auraInstanceID
    if not id then return end

    if kind == "buff" then
        -- User-configurable buff filter (nil means show all)
        if not buffFilters or AuraPassesAnyFilter(unit, id, buffFilters) then
            cache.buffs[id] = true
        end
        -- Defensive classification (filter-list, independent of user buff filter)
        if defFilters and AuraPassesAnyFilter(unit, id, defFilters) then
            cache.defensives[id] = true
        end
    else  -- "debuff"
        -- All-dispellable classification (independent of debuff filters).
        -- Used by the dispel overlay's "All Dispellable" mode.
        local isAllDispellable = auraData.dispelName ~= nil
        if isAllDispellable then
            cache.allDispellable[id] = true
        end
        -- User-configurable debuff filter (nil means show all)
        local passesFilters = not debuffFilters or AuraPassesAnyFilter(unit, id, debuffFilters)
        local passesAllDispellable = db and db.directDebuffDispellableMode == "ALL" and isAllDispellable
        if passesFilters or passesAllDispellable then
            cache.debuffs[id] = true
        end
        -- Player-dispellable bookkeeping (dispel overlay reads this)
        if dispelFilter and (not IsAuraFilteredOut or not IsAuraFilteredOut(unit, id, dispelFilter)) then
            cache.playerDispellable[id] = true
        end
    end
end

-- Remove a single aura from all classification sets.
local function UnclassifyAura(cache, id)
    cache.buffs[id] = nil
    cache.debuffs[id] = nil
    cache.defensives[id] = nil
    cache.playerDispellable[id] = nil
    cache.allDispellable[id] = nil
end

-- Full scan — wipes and rebuilds the entire cache entry for a unit.
local function ScanUnitFull(unit)
    -- 12.1: the factory (DF.AuraContainer) renders auras natively; this legacy DF.AuraCache scan
    -- reads the now-fully-secret aura data (dispelName/expirationTime/name compares) which TAINTS
    -- DandersFrames and poisons secure frames in combat. Gate the scan PRIMITIVE off on 12.1 —
    -- covers every caller at once (OnUnitAura, DirectScanAllUnits, PopulateDefensiveCache,
    -- PinnedFrames, Range, AD adapter). Legacy cache consumers are already non-functional on
    -- secret 12.1 data; they port to the factory in later phases. TriggerAuraUpdateForUnit still
    -- fires (drives the factory); it just finds an empty cache, which the factory doesn't use.
    if DF.AuraContainer and DF.AuraContainer.IsSupported and DF.AuraContainer.IsSupported() then return end
    if not unit or not UnitExists(unit) then return end
    if not IsRosterUnit(unit) then return end
    if not GetAuraSlots or not GetAuraDataBySlot then return end

    local cache = EnsureAuraCacheEntry(unit)

    -- Don't wipe aura cache for out-of-range units — the API returns nothing
    -- for OOR units, so rescanning would destroy valid cached data.
    -- When they come back in range, UNIT_AURA fires again with real data.
    local frame = DF.unitFrameMap and DF.unitFrameMap[unit]
    if frame then
        local inRange = frame.dfInRange
        local isSecret = issecretvalue and issecretvalue(inRange)
        if not isSecret and inRange == false then
            -- Only skip if we already have data cached (don't skip first scan)
            if cache.hasFullScan then
                return
            end
        end
    end

    -- Wipe the new Fix A fields
    wipe(cache.buffsByID)
    wipe(cache.debuffsByID)
    -- Wipe the classification sets (shared with legacy fields)
    wipe(cache.buffs)
    wipe(cache.debuffs)
    wipe(cache.defensives)
    wipe(cache.playerDispellable)
    wipe(cache.allDispellable)

    local buffFilters, debuffFilters, defFilters, dispelFilter, db = ResolveFiltersForUnit(unit)

    -- HELPFUL pass
    -- GetAuraSlots returns (continuationToken, slot1, slot2, ...) as varargs.
    -- We don't use continuation beyond the first 40-ish slots because our
    -- max aura count is 40. Ignore the continuation token by starting at i=2
    -- in oUF's pattern, but since we use select() we can just iterate all
    -- returns and skip the first one.
    do
        local helpfulReturns = { GetAuraSlots(unit, "HELPFUL") }
        -- helpfulReturns[1] is the continuation token; slots start at [2]
        for i = 2, #helpfulReturns do
            local slot = helpfulReturns[i]
            local auraData = GetAuraDataBySlot(unit, slot)
            if auraData and auraData.auraInstanceID then
                cache.buffsByID[auraData.auraInstanceID] = auraData
                ClassifyAura(cache, unit, auraData, "buff",
                    buffFilters, debuffFilters, defFilters, dispelFilter, db)
            end
        end
    end

    -- HARMFUL pass
    do
        local harmfulReturns = { GetAuraSlots(unit, "HARMFUL") }
        for i = 2, #harmfulReturns do
            local slot = harmfulReturns[i]
            local auraData = GetAuraDataBySlot(unit, slot)
            if auraData and auraData.auraInstanceID then
                cache.debuffsByID[auraData.auraInstanceID] = auraData
                ClassifyAura(cache, unit, auraData, "debuff",
                    buffFilters, debuffFilters, defFilters, dispelFilter, db)
            end
        end
    end

    -- Rebuild legacy sorted arrays so consumers that read cache.buffData /
    -- cache.buffOrder still work (the icon renderer at UpdateAuraIconsDirect
    -- is the primary reader). Uses module-level scratch tables — no allocation.
    RebuildLegacySortedArrays(cache, unit, db)

    cache.hasFullScan = true
end

-- Incremental delta — process updateInfo.addedAuras,
-- updatedAuraInstanceIDs, and removedAuraInstanceIDs.
local function ApplyAuraDelta(unit, updateInfo)
    if not unit or not updateInfo then return end
    if not IsRosterUnit(unit) then return end

    local cache = EnsureAuraCacheEntry(unit)

    -- If we've never done a full scan for this unit, the classification
    -- sets are empty — incremental updates alone would produce an
    -- incomplete cache. Bail out and let the caller run ScanUnitFull.
    if not cache.hasFullScan then return false end

    local buffFilters, debuffFilters, defFilters, dispelFilter, db = ResolveFiltersForUnit(unit)

    -- Added auras: Blizzard provides full auraData in the event payload.
    -- Zero API calls on our side for the data itself.
    --
    -- addedAuras is a FLAT list containing both helpful and harmful auras.
    -- We cannot use auraData.isHarmful to categorize because it is a
    -- secret value on Midnight (see oUF auras.lua:276 — "isHarmful is a
    -- secret, use a different name"). Instead, categorize via the
    -- secret-safe IsAuraFilteredOutByInstanceID with the base filters
    -- "HELPFUL" and "HARMFUL". If the aura matches HELPFUL (not filtered
    -- out), it's a buff; otherwise check HARMFUL.
    if updateInfo.addedAuras then
        for _, auraData in ipairs(updateInfo.addedAuras) do
            local id = auraData.auraInstanceID
            if id and IsAuraFilteredOut then
                if not IsAuraFilteredOut(unit, id, "HELPFUL") then
                    cache.buffsByID[id] = auraData
                    ClassifyAura(cache, unit, auraData, "buff",
                        buffFilters, debuffFilters, defFilters, dispelFilter, db)
                    cache.buffOrderDirty = true
                elseif not IsAuraFilteredOut(unit, id, "HARMFUL") then
                    cache.debuffsByID[id] = auraData
                    ClassifyAura(cache, unit, auraData, "debuff",
                        buffFilters, debuffFilters, defFilters, dispelFilter, db)
                    cache.debuffOrderDirty = true
                end
            end
        end
    end

    -- Updated auras: we only get the instance IDs, so fetch fresh data
    -- via GetAuraDataByAuraInstanceID. Typically 1-3 entries.
    if updateInfo.updatedAuraInstanceIDs then
        for _, id in ipairs(updateInfo.updatedAuraInstanceIDs) do
            if cache.buffsByID[id] then
                local fresh = GetAuraDataByAuraInstanceID and GetAuraDataByAuraInstanceID(unit, id)
                if fresh then
                    cache.buffsByID[id] = fresh
                    -- Re-classify: filter matches may have changed
                    UnclassifyAura(cache, id)
                    ClassifyAura(cache, unit, fresh, "buff",
                        buffFilters, debuffFilters, defFilters, dispelFilter, db)
                    cache.buffOrderDirty = true
                end
            elseif cache.debuffsByID[id] then
                local fresh = GetAuraDataByAuraInstanceID and GetAuraDataByAuraInstanceID(unit, id)
                if fresh then
                    cache.debuffsByID[id] = fresh
                    UnclassifyAura(cache, id)
                    ClassifyAura(cache, unit, fresh, "debuff",
                        buffFilters, debuffFilters, defFilters, dispelFilter, db)
                    cache.debuffOrderDirty = true
                end
            end
        end
    end

    -- Removed auras: delete from cache and classification sets.
    if updateInfo.removedAuraInstanceIDs then
        for _, id in ipairs(updateInfo.removedAuraInstanceIDs) do
            if cache.buffsByID[id] then
                cache.buffsByID[id] = nil
                UnclassifyAura(cache, id)
                cache.buffOrderDirty = true
            elseif cache.debuffsByID[id] then
                cache.debuffsByID[id] = nil
                UnclassifyAura(cache, id)
                cache.debuffOrderDirty = true
            end
        end
    end

    -- Rebuild legacy sorted arrays if any delta touched them.
    -- Typical N is 5-20 per unit so the sort cost is negligible, and
    -- the rebuild only runs when at least one aura actually changed.
    if cache.buffOrderDirty or cache.debuffOrderDirty then
        RebuildLegacySortedArrays(cache, unit, db)
    end

    return true
end

-- Expose on DF so the dev slash command and tests can call them directly
DF.ScanUnitFull   = function(self, unit) ScanUnitFull(unit) end
DF.ApplyAuraDelta = function(self, unit, updateInfo) return ApplyAuraDelta(unit, updateInfo) end
DF.TriggerAuraUpdateForUnit = function(self, unit) TriggerAuraUpdateForUnit(unit) end

-- ============================================================
-- DEFENSIVE CACHE POPULATOR (mode-independent)
-- ============================================================
-- Rebuilds cache.defensives for a unit by scanning every helpful aura via
-- GetUnitAuras and running each through the secret-safe IsAuraFilteredOut
-- against BIG_DEFENSIVE / EXTERNAL_DEFENSIVE filters.
--
-- This is called from UpdateDefensiveBar (in Frames/Icons.lua) directly
-- so the defensive icon is fully decoupled from either capture path —
-- Blizzard's frame.buffs:Iterate doesn't have to succeed for defensive
-- icons to render. The icon renderer always reads fresh data, regardless
-- of whether the Blizzard or Direct capture ran (or failed) first.
function DF:PopulateDefensiveCache(unit)
    if not unit then return end
    -- Early-return on non-roster tokens (e.g. boss1targetpet from arena
    -- enemy frame hooks). GetUnitAuras hard-errors on these in 12.0.5.
    if not IsRosterUnit(unit) then return end

    -- Fix A commit 3: cache.defensives is now maintained incrementally
    -- by ScanUnitFull and ApplyAuraDelta via ClassifyAura's defensive-
    -- filter classification pass. If the cache has a fresh full scan,
    -- cache.defensives is already up to date and there is nothing to do.
    -- This is the common-case early-return for Direct mode — the path
    -- UpdateDefensiveBar takes on every render (~184 calls/sec in a
    -- 25-player raid). Old behavior: full GetUnitAuras scan every time,
    -- ~26 KB allocation per call. New behavior: one table lookup, zero
    -- allocation.
    local cache = DF.AuraCache[unit]
    if cache and cache.hasFullScan then
        return
    end

    -- Remaining reachable case: a Direct-mode edge where UpdateDefensiveBar
    -- fires before the first UNIT_AURA event for the unit (initial load,
    -- before ScanUnitFull has run). Run the full direct scan — it populates
    -- cache.defensives via the ClassifyAura filter pass and sets hasFullScan,
    -- so subsequent calls take the early-return above. (The legacy
    -- GetUnitAuras scan that lived here served the removed Blizzard capture
    -- mode, and that API is gone from Midnight 12.0+ anyway.)
    if DF.ScanUnitFull and UnitExists(unit) then
        DF:ScanUnitFull(unit)
    end
end

-- Rebuild cached filter tables from current settings (per mode)
function DF:RebuildDirectFilterStrings()
    local partyDb = DF:GetDB("party")
    local raidDb = DF:GetDB("raid")
    if partyDb then
        cachedPartyBuffFilters = BuildDirectBuffFilters(partyDb)
        cachedPartyDebuffFilters = BuildDirectDebuffFilters(partyDb)
    end
    if raidDb then
        cachedRaidBuffFilters = BuildDirectBuffFilters(raidDb)
        cachedRaidDebuffFilters = BuildDirectDebuffFilters(raidDb)
    end
    -- Defensive and dispel are mode-independent, clear to rebuild on next use
    cachedDefensiveFilters = nil
    cachedDispelFilter = nil

    -- Fix A: classification sets are built against the OLD filters and
    -- are now stale. Mark every cache entry as needing a fresh full
    -- scan so the next UNIT_AURA event re-classifies everything from
    -- scratch. We use hasFullScan = false rather than wiping the cache
    -- so off-event readers (options page preview, etc.) still see data
    -- until the next event lands.
    for _, entry in pairs(DF.AuraCache) do
        entry.hasFullScan = false
    end
end

-- Scan a single unit with Direct API and populate DF.AuraCache.
--
-- COMMIT 2: ScanUnitDirect is now a thin delegation to ScanUnitFull.
-- The legacy body (which did its own GetUnitAuras scans + sorted +
-- classified + called PopulateDefensiveCache) has been replaced by
-- the new cache-based pipeline. ScanUnitFull is a strict superset —
-- it populates both the new (buffsByID, debuffsByID, hasFullScan)
-- and legacy (buffData, buffOrder via RebuildLegacySortedArrays)
-- cache fields in one pass.
--
-- This delegation keeps DirectScanAllUnits + DirectModeRosterUpdate
-- working unchanged — they call ScanUnitDirect in a roster loop and
-- now get ScanUnitFull behavior for free. Also means the initial
-- bulk scan sets hasFullScan = true, so the first UNIT_AURA event
-- per unit after login can take the cheap delta path instead of
-- falling back to a full rescan.
local function ScanUnitDirect(unit)
    -- because it's a lower-level primitive. Keep the check here so
    -- DirectScanAllUnits doesn't run ScanUnitFull when the user is
    -- still in Blizzard mode.
    if not unit then return end
    local frame = DF.unitFrameMap and DF.unitFrameMap[unit]
    local db
    if frame then
        db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    else
        db = DF:GetDB()
    end
    if not db then return end

    ScanUnitFull(unit)
end

-- ============================================================
-- DIRECT MODE EVENT HANDLING
-- ============================================================

-- Direct-mode UNIT_AURA subscriber. Routed through the roster dispatcher
-- (RosterEvents.lua) so we only see player/partyN/raidN events — never
-- nameplates, target, focus, mouseover, etc. The dispatcher uses
-- RegisterUnitEvent at the C++ level for filtering.
local directModeSubscriber = {}
local directModeActive = false

function directModeSubscriber:OnUnitAura(event, unit, updateInfo)
    if not unit then return end
    -- Only process units shown by DF frames (main frames or pinned frames).
    -- Main frames: O(1) check via unitFrameMap.
    -- Pinned frames are excluded from unitFrameMap (to avoid overwriting main
    -- frame entries), so fall through and check them when unitFrameMap misses.
    -- Common case: player unit when hidePlayerFrame = true — the player has no
    -- main party frame but may be pinned, causing auras to never update on the
    -- pinned frame without this check.
    if not DF.unitFrameMap then return end
    if not DF.unitFrameMap[unit] then
        -- Fast bail: non-roster units (target, focus, nameplate, etc.) are
        -- never shown by pinned party/raid frames.
        if not IsRosterUnit(unit) then return end
        -- Check if any enabled pinned header currently shows this unit.
        -- Mirrors the gating used by TriggerAuraUpdateForUnit so we don't
        -- pay the scan/delta cost for disabled or invisible pinned children.
        local shownInPinned = false
        if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
            local pinnedDB = DF.db and DF.db[IsInRaid() and "raid" or "party"]
            pinnedDB = pinnedDB and pinnedDB.pinnedFrames
            for setIndex = 1, 2 do
                local header = DF.PinnedFrames.headers[setIndex]
                local set = pinnedDB and pinnedDB.sets and pinnedDB.sets[setIndex]
                if header and header:IsShown() and set and set.enabled then
                    for i = 1, 40 do
                        local child = header:GetAttribute("child" .. i)
                        if child and child:IsVisible() and child.unit == unit then
                            shownInPinned = true
                            break
                        end
                    end
                end
                if shownInPinned then break end
            end
        end
        if not shownInPinned then return end
    end

    DF.AuraCacheStats.eventsSeen = DF.AuraCacheStats.eventsSeen + 1

    -- Fix A hot path: decide between a full scan and an incremental
    -- delta based on updateInfo. Full scans happen only on first-access,
    -- isFullUpdate, or if a delta fails (hasFullScan == false).
    -- Every other UNIT_AURA event flows through the cheap delta path.
    --
    -- See _Reference/fix-a-plan.md for the full architecture.
    -- 12.1: the legacy cache scan reads the now-fully-secret UNIT_AURA payload (updateInfo /
    -- aura data), a boolean/compare on a secret that is BLOCKED and TAINTS DandersFrames —
    -- poisoning the secure header + aura containers in combat (taint.log Auras.lua:1300). The
    -- factory renders auras natively and never uses DF.AuraCache, so SKIP the scan on 12.1 —
    -- but STILL trigger the frame render below so the factory gets driven. (Legacy cache
    -- consumers not yet ported are already non-functional on secret 12.1 data.)
    if not (DF.AuraContainer and DF.AuraContainer.IsSupported and DF.AuraContainer.IsSupported()) then
        local cache = DF.AuraCache[unit]
        local needsFull = not updateInfo
                          or updateInfo.isFullUpdate
                          or not cache
                          or not cache.hasFullScan

        if needsFull then
            DF.AuraCacheStats.scanFull = DF.AuraCacheStats.scanFull + 1
            ScanUnitFull(unit)
        else
            -- Try the incremental path. If it returns false (cache in
            -- a state where delta isn't safe), fall back to full scan.
            if ApplyAuraDelta(unit, updateInfo) then
                DF.AuraCacheStats.deltaApplied = DF.AuraCacheStats.deltaApplied + 1
            else
                DF.AuraCacheStats.deltaFallback = DF.AuraCacheStats.deltaFallback + 1
                ScanUnitFull(unit)
            end
        end
    end

    TriggerAuraUpdateForUnit(unit)   -- drives the factory (and legacy render on 12.0)
end

function DF:EnableDirectAuraMode()
    if directModeActive then return end
    directModeActive = true

    DF:RegisterRosterUnitEvent(directModeSubscriber, "UNIT_AURA", "OnUnitAura")

    -- Rebuild filter strings from current settings
    DF:RebuildDirectFilterStrings()

    -- Do an initial full scan
    DF:DirectScanAllUnits()
end

-- Full scan of all units currently in the frame map
function DF:DirectScanAllUnits()
    if not DF.unitFrameMap then return end
    for unit in pairs(DF.unitFrameMap) do
        ScanUnitDirect(unit)
        TriggerAuraUpdateForUnit(unit)
    end
    -- Also scan units shown only in pinned frames (not in unitFrameMap).
    -- Example: player unit when hidePlayerFrame = true. Without this pass the
    -- aura cache for those units is empty until the first UNIT_AURA fires.
    if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
        local scanned = {}  -- avoid double-scanning units already handled above
        for setIndex = 1, 2 do
            local header = DF.PinnedFrames.headers[setIndex]
            if header and header:IsShown() then
                for i = 1, 40 do
                    local child = header:GetAttribute("child" .. i)
                    -- Pinned headers pre-create all 40 children up-front, so
                    -- we walk every slot and let child.unit being nil filter
                    -- out the unassigned ones.
                    if child then
                        local unit = child.unit
                        if unit and not DF.unitFrameMap[unit] and not scanned[unit] then
                            scanned[unit] = true
                            ScanUnitDirect(unit)
                            TriggerAuraUpdateForUnit(unit)
                        end
                    end
                end
            end
        end
    end
end

-- Re-scan when roster changes (units may change)
function DF:DirectModeRosterUpdate()
    if not directModeActive then return end
    if not DF.unitFrameMap then return end

    -- The roster dispatcher handles add/remove of units automatically when
    -- GROUP_ROSTER_UPDATE fires, so no re-registration is needed here — just
    -- rescan to populate state for the new roster.
    DF:DirectScanAllUnits()
end

-- ============================================================
-- HOOK BLIZZARD'S COMPACT RAID FRAMES
-- ============================================================

-- ============================================================
-- EVENT FRAME FOR PROACTIVE UPDATES
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

-- Apply our saved Blizzard frame settings via CVars only (not optionTable)
-- Modifying optionTable causes protected value errors in combat
local function ApplyBlizzardFrameSettings()
    if not DF.db or not DF.db.party then return end
    
    local db = DF.db.party
    
    local dispelIndicator = db._blizzDispelIndicator

    -- Force dispel indicator to be at least 1 (never disabled)
    if dispelIndicator == nil or dispelIndicator == 0 then
        dispelIndicator = 1
        db._blizzDispelIndicator = 1
    end

    -- Set via CVar only - do NOT modify optionTable
    SetCVar("raidFramesDispelIndicatorType", dispelIndicator)
end

-- Export for use elsewhere
DF.ApplyBlizzardFrameSettings = ApplyBlizzardFrameSettings

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "GROUP_ROSTER_UPDATE" then
        if DF.RosterDebugEvent then DF:RosterDebugEvent("Auras.lua(blizz):GROUP_ROSTER_UPDATE") end
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
        -- Apply our saved Blizzard-frame settings (CVars) once frames settle
        C_Timer.After(0.2, ApplyBlizzardFrameSettings)
        C_Timer.After(1.0, ApplyBlizzardFrameSettings)

        -- Direct mode: re-register unit events for new roster
        local db = DF.db and DF.db.party
        local raidDb = DF.db and DF.db.raid
        local isDirectMode = true -- direct is the only aura source (4.6.1)
        if isDirectMode then
            C_Timer.After(0.2, function() DF:DirectModeRosterUpdate() end)
        end
    end
end)

-- Canonical discovery/setup for an aura icon's native cooldown countdown text.
-- Finds the FontString inside the Blizzard cooldown, creates durationHideWrapper
-- (the parent frame whose alpha implements "hide duration above threshold") and
-- parents the text into it, and applies the current duration font/anchor on
-- first discovery so the large default font never flashes. Every path that
-- needs the native text (live render, shared timer safety net, slider
-- lightweight update, test mode) MUST come through here: the hand-rolled
-- copies this replaces disagreed about parenting — test mode moved the text to
-- textOverlay and the slider path never created the wrapper, either of which
-- left hide-above-threshold driving an empty wrapper until /reload.
function DF:EnsureAuraDurationText(icon, db, prefix)
    if not icon or not icon.cooldown then return icon and icon.nativeCooldownText end

    if not icon.nativeCooldownText then
        local regions = {icon.cooldown:GetRegions()}
        for _, region in ipairs(regions) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                icon.nativeCooldownText = region

                if db and prefix and DF.SafeSetFont then
                    local durationScale = db[prefix .. "DurationScale"] or 1.0
                    local durationFont = db[prefix .. "DurationFont"] or "Fonts\\FRIZQT__.TTF"
                    local durationOutline = db[prefix .. "DurationOutline"] or "OUTLINE"
                    if durationOutline == "NONE" then durationOutline = "" end
                    DF:SafeSetFont(region, durationFont, 10 * durationScale, durationOutline)

                    local durationAnchor = db[prefix .. "DurationAnchor"] or "CENTER"
                    region:ClearAllPoints()
                    region:SetPoint(durationAnchor, icon, durationAnchor,
                        db[prefix .. "DurationX"] or 0, db[prefix .. "DurationY"] or 0)
                end

                -- Sync Blizzard's own countdown-number visibility to the user setting
                -- (icon.showDuration is stamped by ApplyAuraLayout, which runs before
                -- any icon displays in both live and test paths; if it hasn't been
                -- stamped yet, leave visibility to the caller rather than force-hiding).
                if icon.showDuration ~= nil and icon.cooldown.SetHideCountdownNumbers then
                    icon.cooldown:SetHideCountdownNumbers(not icon.showDuration)
                end
                break
            end
        end
    end

    local text = icon.nativeCooldownText
    if text then
        if not icon.durationHideWrapper then
            icon.durationHideWrapper = CreateFrame("Frame", nil, icon.cooldown)
            icon.durationHideWrapper:SetAllPoints(icon)
            icon.durationHideWrapper:SetFrameLevel(icon.cooldown:GetFrameLevel() + 2)
            icon.durationHideWrapper:EnableMouse(false)
        end
        if text:GetParent() ~= icon.durationHideWrapper then
            text:SetParent(icon.durationHideWrapper)
        end
    end
    return text
end

-- Dispel-type name → configured debuff border colour (with the shared default
-- palette). Single source for the live colour-curve construction and test
-- mode's mock recolour so the defaults can't drift apart.
function DF:GetDebuffTypeColor(db, dispelName)
    if dispelName == "Magic" then
        return db.debuffBorderColorMagic or {r = 0.2, g = 0.6, b = 1.0}
    elseif dispelName == "Curse" then
        return db.debuffBorderColorCurse or {r = 0.6, g = 0.0, b = 1.0}
    elseif dispelName == "Disease" then
        return db.debuffBorderColorDisease or {r = 0.6, g = 0.4, b = 0.0}
    elseif dispelName == "Poison" then
        return db.debuffBorderColorPoison or {r = 0.0, g = 0.6, b = 0.0}
    elseif dispelName == "Bleed" or dispelName == "Enrage" then
        return db.debuffBorderColorBleed or {r = 1.0, g = 0.0, b = 0.0}
    end
    return db.debuffBorderColorNone or {r = 0.8, g = 0.0, b = 0.0}
end

-- ============================================================
-- BUFF FACTORY BRIDGE
-- Routes the buff ROW through DF.AuraContainer (WoW 12.1 native aura widgets).
-- The container renders and self-updates; the drive below only keeps its
-- config current (build-once, sig-gated).
-- ============================================================

-- Is the factory buff path active for this frame right now? Excludes test mode:
-- the test drives (TestMode.lua) call DriveBuffFactory themselves with the test
-- provider, so the live update path must not double-drive.
function DF:UseFactoryForBuffs(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
end

-- GUI-facing predicate: does the factory own the buff row for this mode's db? Unlike
-- UseFactoryForBuffs (the render gate, which also excludes test mode), this must NOT flip in
-- test mode — else "blocked" overlays would wrongly lift while previewing. Used by GUI when().
function DF:FactoryOwnsBuffRow(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
end

-- Duration-text formatters for the factory row, by format key:
--   NUMBER -> bare seconds (45), then "2m"/"1h"   (NumericRuleFormatter)
--   SHORT  -> "45s" / "2m" / "1h"                 (SecondsFormatter, OneLetter)
--   FULL   -> "45 Seconds" / "2 Minutes"          (SecondsFormatter, None = full word)
-- Blizzard's own default is SHORT-like; DF's legacy rows showed NUMBER. Built once per
-- format and cached (Blizzard securecopies the options table, so one object per format is fine).
local function BuildDurationFormatter(format, hideAboveT, colorByTime)
    format = format or "NUMBER"
    -- Hide-above-threshold and/or COLOUR-BY-TIME buckets: both need per-band format
    -- strings, which only the NumericRuleFormatter has (SecondsFormatter carries none) —
    -- so SHORT/FULL are emulated with the matching unit suffix (the pre-existing
    -- hide-above tradeoff: English unit text, not locale-aware).
    --
    -- Colour-by-time: the smooth curve is NOT addon-reachable on 12.1 (see the
    -- GetDurationColorCurve tombstone below). Instead each band's format string EMBEDS a
    -- |cffRRGGBB escape; the C-side DurationTextBinding evaluates the SECRET remaining
    -- time against the breakpoints and renders the pre-coloured string — no aura read,
    -- no addon ticker, secret-safe (the DF_AuraLab-proven formatter trick). Bands are
    -- the legacy curve's colours discretised on ABSOLUTE remaining time:
    --   <5s red · 5-15s orange · 15-60s yellow · 60s+ green (fresh).
    -- (The legacy path coloured by PERCENT of total duration; a static formatter can't
    -- know the total, so absolute-seconds bands are the 12.1 equivalent.)
    if hideAboveT or colorByTime then
        if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
        local secFmt = (format == "SHORT" and "%.0fs") or (format == "FULL" and "%.0f Seconds") or "%.0f"
        local ok, f = pcall(function()
            local down = Enum.NumericRuleFormatRounding.Down
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            -- Highest threshold <= remaining seconds wins.
            local function add(threshold, fstr, hex, components)
                if colorByTime then fstr = "|cff" .. hex .. fstr .. "|r" end
                fmt:AddBreakpoint({ threshold = threshold, step = 1, rounding = down,
                                    min = 1, format = fstr, components = components })
            end
            add(0, secFmt, "ff0000")
            if colorByTime then
                -- Colour cuts go in below the hide threshold only — a cut at/above it
                -- would shadow the blank band. (Hide slider caps at 60s, so the two
                -- sub-minute cuts are the only ones affected.)
                if not hideAboveT or hideAboveT > 5  then add(5,  secFmt, "ff8000") end
                if not hideAboveT or hideAboveT > 15 then add(15, secFmt, "ffff00") end
            end
            if hideAboveT then
                fmt:AddBreakpoint({ threshold = hideAboveT, step = 1, rounding = down, format = "" })
            else
                -- 60s+ renders minutes/hours (green = the legacy curve's fresh end).
                add(60,   (format == "FULL") and "%.0f Minutes" or "%.0fm", "00ff00",
                    { { div = 60,   step = 1, rounding = down } })
                add(3600, (format == "FULL") and "%.0f Hours"   or "%.0fh", "00ff00",
                    { { div = 3600, step = 1, rounding = down } })
            end
            return fmt
        end)
        return ok and f or nil
    end
    if format == "NUMBER" then
        if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
        local ok, f = pcall(function()
            local down = Enum.NumericRuleFormatRounding.Down
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            fmt:AddBreakpoint({ threshold = 0,    step = 1, rounding = down, min = 1, format = "%.0f" })
            fmt:AddBreakpoint({ threshold = 60,   step = 1, rounding = down, min = 1, format = "%.0fm",
                                components = { { div = 60,   step = 1, rounding = down } } })
            fmt:AddBreakpoint({ threshold = 3600, step = 1, rounding = down, min = 1, format = "%.0fh",
                                components = { { div = 3600, step = 1, rounding = down } } })
            return fmt
        end)
        return ok and f or nil
    end
    -- SHORT / FULL: Blizzard's SecondsFormatter, differing only in the abbreviation.
    if not (C_StringUtil and C_StringUtil.CreateSecondsFormatter and C_CurveUtil and Enum) then return nil end
    local abbrev = (format == "FULL") and Enum.SecondsFormatterAbbreviation.None
                    or Enum.SecondsFormatterAbbreviation.OneLetter
    local ok, f = pcall(function()
        local fmt = C_StringUtil.CreateSecondsFormatter()
        local mult = 1.5
        local curve = C_CurveUtil.CreateCurve()
        curve:AddPoint(1 + mult * SECONDS_PER_MIN,  Enum.SecondsFormatterInterval.Minutes)
        curve:AddPoint(1 + mult * SECONDS_PER_HOUR, Enum.SecondsFormatterInterval.Hours)
        curve:AddPoint(1 + mult * SECONDS_PER_DAY,  Enum.SecondsFormatterInterval.Days)
        fmt:SetDefaultAbbreviation(abbrev)
        fmt:SetMinInterval(Enum.SecondsFormatterInterval.Seconds)
        fmt:SetMaxIntervalCurve(curve)
        fmt:SetDesiredUnitCount(1)
        -- SHORT: strip the space between number and unit ("45 s" -> "45s"; the default
        -- Preserve mode is why Short looked MORE spaced out than Number). Locale-aware:
        -- deDE/ruRU keep their space by design. FULL keeps the space ("45 Seconds").
        if format == "SHORT" and fmt.SetStripIntervalWhitespace
            and Enum.SecondsFormatterIntervalWhitespace then
            fmt:SetStripIntervalWhitespace(Enum.SecondsFormatterIntervalWhitespace.Strip)
        end
        return fmt
    end)
    return ok and f or nil
end

local durationFormatterCache = {}
local function GetDurationFormatter(format, hideAboveT, colorByTime)
    format = format or "NUMBER"
    local key = format .. "|" .. tostring(hideAboveT or "") .. (colorByTime and "|C" or "")
    if durationFormatterCache[key] == nil then
        durationFormatterCache[key] = BuildDurationFormatter(format, hideAboveT, colorByTime) or false
    end
    return durationFormatterCache[key] or nil
end

-- Shared with the Aura Designer factory (P4.4): its placed icon/square/bar duration text
-- reuses the EXACT same secret-safe colour-by-time BUCKET formatter as the #205 buff/debuff
-- rows (|cRRGGBB escapes baked into the native NumericRuleFormatter bands, evaluated C-side).
-- Cached, so repeated SyncFrame calls return the same shared formatter object.
function DF:GetFactoryDurationFormatter(format, hideAboveT, colorByTime)
    return GetDurationFormatter(format, hideAboveT, colorByTime)
end

-- ⚠ STACKS FORMATTERS ARE FORBIDDEN on container rows — do not re-add one.
-- (Removed 2026-07-09; was the alpha.2 in-combat container freeze.) Blizzard's
-- ApplyApplicationCount calls formatter:FormatNumber(applications) in LUA with the
-- stack count, which is SECRET in combat; formatter userdata cannot hold secrets, so
-- the call throws inside the container's dirty pass → the dirty-flag latch bricks the
-- container for the session. Bind-time validation can't catch it (AssertValidFormatter
-- test-drives with a non-secret value). The native no-formatter path (shows counts > 1,
-- rendered secure-side via secretwrap) is the only secret-safe option — `stackMinimum`
-- other than 2 is therefore not expressible on 12.1 container rows. Duration-text
-- formatters are NOT affected (C-side DurationTextBinding handles secrets).

-- (Removed 2026-07-09: GetDurationColorCurve. The smooth duration-text colour curve is
-- NOT addon-reachable on 68569 — SetDurationText{textColorCurve} drops the required
-- `property` arg, and the button's DurationTextBinding is PRIVATE, so "apply it on the
-- binding" cannot work; poking Blizzard-owned binding state on a live button is also the
-- exact touch class behind the combat dirty-latch freeze. durationColorByTime ships as
-- discrete colour BUCKETS via the duration formatter (|cRRGGBB escapes in AddBreakpoint
-- format strings — C-side, secret-safe, the NSRT-proven path): BuildDurationFormatter above.)

-- NATIVE BLACKLIST (buffs): the user's aura blacklist -> candidateFilters.excludeSpellIDs,
-- evaluated Blizzard-side (works for HELPFUL auras on friendly frames — helpful spell-ID
-- filters pass the assist gate; the DEBUFF blacklist can NOT be expressed on friendlies).
-- Alternates are expanded so every variant is excluded, matching the legacy IsBlacklisted
-- lookup. Split combat/OOC-only entries can't be expressed statically -> they stay VISIBLE
-- on factory rows (visible degrade, never a silent in-combat surprise); only entries
-- blacklisted in both states are excluded.
local function BuildBuffExcludeMap()
    local bl = DF.db and DF.db.auraBlacklist and DF.db.auraBlacklist.buffs
    if not bl or not next(bl) then return nil end
    local map, n = {}, 0
    for id, entry in pairs(bl) do
        if entry == true or (type(entry) == "table" and entry.combat and entry.ooc) then
            map[id] = true
            n = n + 1
        end
    end
    if n == 0 then return nil end
    local alts = DF.AuraBlacklist and DF.AuraBlacklist.AlternateSpellIDs
    if alts then
        for alt, primary in pairs(alts) do
            if map[primary] then map[alt] = true end
        end
    end
    return map
end

-- Stable signature of an excludeSpellIDs map (sorted IDs) — blacklist changes are
-- STRUCTURAL (candidateFilters are declared at AddAuraGroup), so the row signature
-- must move when the set does.
local function excludeSig(cf)
    local m = cf and cf.excludeSpellIDs
    if not m then return "" end
    local ids = {}
    for id in pairs(m) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- Map a prefixed aura-row setting block (buff*/debuff*) -> DF.AuraContainer config.
-- prefix = "buff" (debuff reuses this later). opts.filterList is the PRE-BUILT native
-- filter list (buffs: BuildDirectBuffFilters); opts.unit is the initial unit token.
-- Scale note: layoutRow SetScale(layout.scale)'s each button, so fonts / border / spacing
-- all inherit the row scale — pass BASE (unscaled) sizes here, exactly as the db stores them.
function DF:BuildAuraRowConfig(db, prefix, opts)
    opts = opts or {}
    prefix = prefix or "buff"
    local function g(suffix) return db[prefix .. suffix] end
    local filter = opts.filterList
    if filter == nil then filter = (prefix == "debuff") and "HARMFUL" or "HELPFUL" end

    local iconSize = g("Size") or 20
    local dur
    if g("ShowDuration") ~= false then
        local durFormat = g("DurationFormat") or "NUMBER"
        local colorByTime = g("DurationColorByTime") and true or false
        local hideAboveT = (g("DurationHideAboveEnabled") and g("DurationHideAboveThreshold")) or nil
        -- Text styling (font/scale/outline/anchor/offsets/justify/colour) is a shared
        -- DF.TextStyle spec; the factory applies it via TextStyle:Apply. The justify box
        -- is the icon rect. Feature fields (show/formatter/formatKey) ride on top.
        dur = DF.TextStyle:BuildSpec(db, prefix .. "Duration", {
            baseSize = 10, defaultAnchor = "CENTER", boxW = iconSize, boxH = iconSize,
        })
        dur.show = true
        dur.formatter = GetDurationFormatter(durFormat, hideAboveT, colorByTime)
        -- colorByTime = colour BUCKETS baked into the formatter's band format strings
        -- (see BuildDurationFormatter — the smooth curve is not addon-reachable). The
        -- static colour must not stomp the escapes; formatKey keeps both flags in the
        -- rebuild signature (the formatter is creation-frozen on the native bind).
        if colorByTime then dur.color = nil end
        dur.formatKey = durFormat .. (colorByTime and ":C" or "") .. (hideAboveT and (":H" .. tostring(hideAboveT)) or "")
    end

    -- Buff rows: the aura blacklist as a native exclude map (see BuildBuffExcludeMap).
    -- Debuff rows get NO spell-ID filters — harmful spell-ID maps are inert on
    -- friendly frames (the assist/attack gate), so the debuff blacklist stays legacy.
    local candidateFilters
    if prefix == "buff" then
        local excludeMap = BuildBuffExcludeMap()
        if excludeMap then candidateFilters = { excludeSpellIDs = excludeMap } end
        -- Native max-TOTAL-duration filter (candidateFilters.maxDuration, seconds).
        -- Blizzard-side semantics: auras with duration > max OR duration == 0 are
        -- filtered — i.e. permanent auras are IMPLICITLY always hidden while this
        -- is on (documented in the GUI tooltip). Structural: declared at AddAuraGroup.
        if db.buffMaxDurationEnabled and (db.buffMaxDurationMinutes or 0) > 0 then
            candidateFilters = candidateFilters or {}
            candidateFilters.maxDuration = (db.buffMaxDurationMinutes or 0) * 60
        end
        -- Missing Buff "Hide From Buff Bar": union every raid-buff ID (all ranks/
        -- variants) into the exclude map. Legacy did this with an icon-texture match
        -- in the scan, OUT of combat only (reads); the native filter holds in combat
        -- too — a strict upgrade. Structural (rides excludeSig in the row signature).
        if db.missingBuffHideFromBar and DF.RaidBuffs then
            candidateFilters = candidateFilters or {}
            local map = candidateFilters.excludeSpellIDs or {}
            candidateFilters.excludeSpellIDs = map
            for i = 1, #DF.RaidBuffs do
                local ids = DF.RaidBuffs[i][1]
                if type(ids) == "table" then
                    for j = 1, #ids do map[ids[j]] = true end
                else
                    map[ids] = true
                end
            end
        end
        -- Aura Designer dedup (derived, read-free). When the legacy "Hide Duplicate Buffs"
        -- toggle is on AND the native factory owns AD for this frame, hide every aura
        -- tracked by ANY Aura Designer indicator from the buff bar so it doesn't render
        -- twice. The set is RECOMPUTED from the AD config every time the row rebuilds
        -- (GetADTrackedSpellIDs) — no stored-blacklist write, no refcount — so it is
        -- automatically correct across indicator add/remove, aura delete, profile
        -- switch and spec change. UNIONED into (never replacing) the manual blacklist
        -- map above, and folded into the row signature via excludeSig, so a change in
        -- the tracked set forces a buff-row Rebuild (see buffFactorySig). On 12.1 only
        -- the AD half of the legacy toggle is expressible — the defensive row's contents
        -- aren't enumerable as spell IDs read-free (category-filter driven).
        if db.buffDeduplicateDefensives and opts.frame and DF.GetADTrackedSpellIDs then
            local adIDs = DF:GetADTrackedSpellIDs(opts.frame, db)
            if adIDs then
                candidateFilters = candidateFilters or {}
                local map = candidateFilters.excludeSpellIDs or {}
                candidateFilters.excludeSpellIDs = map
                for id in pairs(adIDs) do map[id] = true end
            end
        end
    end

    -- Native sort: the legacy Sort Order dropdown (directBuffSortOrder) mapped onto
    -- AuraContainerSortMethod member NAMES — TIME/NAME map to the *Only comparators
    -- (pure single-dimension sorts, matching the legacy Lua sort's behaviour).
    -- DEFAULT/nil passes nothing = Blizzard's default slot order. The backend
    -- resolves the name against the securecopy'd global enum at build time.
    local sort
    if prefix == "buff" then
        local o = db.directBuffSortOrder
        if o == "TIME" then sort = { method = "ExpirationOnly" }
        elseif o == "NAME" then sort = { method = "NameOnly" } end
    elseif prefix == "debuff" then
        local o = db.directDebuffSortOrder
        if o == "TIME" then sort = { method = "ExpirationOnly" }
        elseif o == "NAME" then sort = { method = "NameOnly" } end
    end

    -- Debuff rows: NATIVE dispel border when Color-by-Dispel-Type is on. The colour is
    -- applied PRIVATE-side from Blizzard's palette (ApplyAuraBorder -> GetAuraBorderColor;
    -- the dispel type is secret) — DF's custom per-type colours are NOT expressible on
    -- 12.1 rows (pickers frosted). Shows only on dispellable debuffs; the static
    -- DF.Border below renders always, so non-dispellable keeps the base border.
    local dispel
    if prefix == "debuff" and db.debuffBorderColorByType then
        -- thickness: match the icon's own DF border so the dispel ring reads as
        -- "the border took the dispel colour" (flat square line at the same
        -- weight; inset 0 lands exactly on it, negative insets halo outward).
        local ringSize = db.debuffBorderSize or 2
        if db.pixelPerfect and DF.PixelPerfect then ringSize = DF:PixelPerfect(ringSize) end
        dispel = { nativeBorder = true, style = "Color", showWhenHarmful = true,
                   inset = db.debuffDispelBorderInset or -2,
                   thickness = ringSize }
    end

    return {
        sort     = sort,
        unit     = opts.unit,
        mode     = "row",
        filter   = filter,
        max      = g("Max") or 5,
        -- Test-mode preview cap: the test panel's Buffs/Debuffs count sliders
        -- (hot-applied via Handle:SetTestMax from the test drive seam).
        testMax  = (prefix == "buff" and (db.testBuffCount or 2))
                or (prefix == "debuff" and (db.testDebuffCount or 2))
                or nil,
        enabled  = true,
        candidateFilters = candidateFilters,
        -- Native hover tooltips: gated on BOTH the Integrations click-through toggle
        -- and the Tooltips page's per-row Enable (legacy honoured both; in the sig).
        tooltips = (not g("DisableMouse"))
            and db["tooltip" .. (prefix == "debuff" and "Debuff" or "Buff") .. "Enabled"] ~= false,
        layout = {
            size     = g("Size") or 20,
            scale    = g("Scale") or 1,
            spacingX = g("PaddingX") or 2,
            spacingY = g("PaddingY") or 2,
            anchor   = g("Anchor") or "BOTTOMRIGHT",
            growth   = g("Growth") or "LEFT_UP",
            wrap     = g("Wrap") or 3,
            offsetX  = g("OffsetX") or 0,
            offsetY  = g("OffsetY") or 0,
        },
        style = {
            icon   = { show = true, zoom = true, inset = 0 },
            border = g("ShowBorder") and { db = db, prefix = prefix } or nil,
            cooldown = { show = not g("HideSwipe"), reverse = true, edge = false, numbers = false },
            duration = dur,
            dispel   = dispel,
            -- Shared TextStyle spec (font/scale/outline/anchor/offsets/justify/colour).
            -- No formatter: forbidden on container rows (secret trap — see the
            -- GetStacksFormatter tombstone above). Native default = counts > 1.
            stacks = (function()
                local st = DF.TextStyle:BuildSpec(db, prefix .. "Stack", {
                    baseSize = 10, defaultAnchor = "BOTTOMRIGHT",
                    defaultOffsetX = 2, defaultOffsetY = -1,
                    boxW = iconSize, boxH = iconSize,
                })
                st.show = true
                return st
            end)(),
        },
    }
end

-- Structural signature: a change here needs a Rebuild (new container); everything else is
-- an in-place ApplyStyle (no frame leak — WoW never GCs frames).
local function buffFactorySig(cfg)
    local f = cfg.filter
    if type(f) == "table" then f = table.concat(f, ";") end
    -- Include region-presence toggles: ApplyStyle can't CREATE or REMOVE a region, so a
    -- show/hide flip (duration / border / swipe) must take the Rebuild path.
    local s = cfg.style
    return table.concat({
        tostring(cfg.max), tostring(f), tostring(cfg.tooltips),
        tostring(s.duration ~= nil), tostring(s.duration and s.duration.formatKey),
        tostring(s.stacks and s.stacks.formatKey),
        tostring(s.border ~= nil), tostring(s.cooldown and s.cooldown.show ~= false),
        excludeSig(cfg.candidateFilters),   -- blacklist set (structural: declared at AddAuraGroup)
        tostring(cfg.candidateFilters and cfg.candidateFilters.maxDuration),  -- max-duration filter (structural)
        tostring(cfg.sort and cfg.sort.method),                               -- native sort (declared at AddAuraGroup)
        tostring(s.dispel ~= nil),          -- native dispel border (region is create-once -> Rebuild)
    }, "|")
end

-- Drive the factory buff row for one frame. Creates the container lazily, hides the legacy
-- icons (no double row), keeps it on the frame's unit, and applies setting changes. The
-- container self-updates from UNIT_AURA, so there is no per-tick render here.
function DF:DriveBuffFactory(frame, db)
    local h = frame.buffFactory
    if not h then
        h = DF.AuraContainer:Create(frame, DF:BuildAuraRowConfig(db, "buff", {
            unit = frame.unit,
            frame = frame,   -- for the derived Aura Designer buff-bar dedup union
            filterList = BuildDirectBuffFilters(db),
        }))
        frame.buffFactory = h
        frame.dfBuffFactoryVersion = DF.auraLayoutVersion or 0
        if h then frame.buffFactorySig = buffFactorySig(h.config) end
    end

    if not h then return end

    -- Row-level opacity (legacy per-icon buffAlpha; container-frame children multiply it).
    -- BUILD-ONCE-LEAVE-IT: the standing container's frame tree is written ONLY on actual
    -- change, never per-event — the combat-proven DF_AuraLab pattern builds once and lets
    -- Blizzard drive; DriveBuffFactory runs per UNIT_AURA/range tick, so unconditional
    -- writes here would re-touch the live tree many times a second in combat.
    local rowAlpha = db.buffAlpha or 1
    if frame.dfBuffFactoryAlpha ~= rowAlpha then
        frame.dfBuffFactoryAlpha = rowAlpha
        h:GetFrame():SetAlpha(rowAlpha)
    end

    -- Keep the container on the frame's current unit. OOC retargets immediately; in combat
    -- the factory defers the retarget, so hide the row until regen rather than show the
    -- previous unit's buffs. Hide via the PLAIN anchor frame (GetFrame():SetShown), NOT
    -- h:SetShown -- the latter also queues an 'enable' op which, paired with the queued
    -- 'retarget', would upgrade to a full rebuild (frame leak). The container's own
    -- OnShow/OnHide drive event (de)registration. (SetUnit combat-legality is queued for Krathe.)
    if h:GetUnit() ~= frame.unit then
        h:SetUnit(frame.unit)
        frame.dfBuffFactoryHidden = InCombatLockdown() or nil
    elseif frame.dfBuffFactoryHidden and not InCombatLockdown() then
        frame.dfBuffFactoryHidden = nil
    end
    -- Show/hide only on state change (no per-event SetShown churn on the live tree).
    local rowShown = not frame.dfBuffFactoryHidden
    if frame.dfBuffFactoryShown ~= rowShown then
        frame.dfBuffFactoryShown = rowShown
        h:GetFrame():SetShown(rowShown)
    end

    -- Apply setting changes only when the layout version actually bumped — and only OUT
    -- of combat. In combat the standing container is left completely alone (the lab's
    -- proven pattern: existing containers keep running in combat; every addon-side
    -- re-touch — restyle, rebuild, SetFrameLevel, formatter churn — is a divergence).
    -- The version stays stale so the first OOC drive catches up.
    local ver = DF.auraLayoutVersion or 0
    if frame.dfBuffFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfBuffFactoryVersion = ver
        local cfg = DF:BuildAuraRowConfig(db, "buff", {
            unit = frame.unit,
            frame = frame,   -- for the derived Aura Designer buff-bar dedup union
            filterList = BuildDirectBuffFilters(db),
        })
        -- Re-apply the z-order level (buffs default to +40 = legacy parity). Not part of the sig.
        h:GetFrame():SetFrameLevel(math.max(0, frame:GetFrameLevel() + (cfg.frameLevelOffset or 40)))
        local sig = buffFactorySig(cfg)
        if frame.buffFactorySig ~= sig then
            frame.buffFactorySig = sig
            h:Rebuild(cfg)                      -- structural (max/filter/tooltips) — discrete, leak-safe
        else
            h:ApplyStyle(cfg.style, cfg.layout) -- cosmetics — in place, no leak
        end
    end
end

-- ============================================================
-- DEBUFF FACTORY BRIDGE (P3) — mirror of the buff bridge with debuff keys.
-- Filter list = the native direct-debuff filters; dispel colouring = the native
-- SetAuraBorder Color style (Blizzard palette — custom per-type colours are not
-- expressible on 12.1; pickers frosted). Debuff BLACKLIST stays legacy-inert:
-- harmful spell-ID candidate filters do nothing on friendly frames (Meorawr gate).
-- ============================================================

-- Render gate (excludes test mode, which paints legacy icons directly).
function DF:UseFactoryForDebuffs(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
end

-- GUI-facing predicate (does NOT exclude test mode — see FactoryOwnsBuffRow).
function DF:FactoryOwnsDebuffRow(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
end

-- Drive the factory debuff row for one frame. Structure identical to DriveBuffFactory
-- (see its comments for the build-once / combat-defer / version-gate reasoning).
function DF:DriveDebuffFactory(frame, db)
    local h = frame.debuffFactory
    if not h then
        h = DF.AuraContainer:Create(frame, DF:BuildAuraRowConfig(db, "debuff", {
            unit = frame.unit,
            filterList = BuildDirectDebuffFilters(db),
        }))
        frame.debuffFactory = h
        frame.dfDebuffFactoryVersion = DF.auraLayoutVersion or 0
        if h then frame.debuffFactorySig = buffFactorySig(h.config) end
    end

    if not h then return end

    local rowAlpha = db.debuffAlpha or 1
    if frame.dfDebuffFactoryAlpha ~= rowAlpha then
        frame.dfDebuffFactoryAlpha = rowAlpha
        h:GetFrame():SetAlpha(rowAlpha)
    end

    if h:GetUnit() ~= frame.unit then
        h:SetUnit(frame.unit)
        frame.dfDebuffFactoryHidden = InCombatLockdown() or nil
    elseif frame.dfDebuffFactoryHidden and not InCombatLockdown() then
        frame.dfDebuffFactoryHidden = nil
    end
    local rowShown = not frame.dfDebuffFactoryHidden
    if frame.dfDebuffFactoryShown ~= rowShown then
        frame.dfDebuffFactoryShown = rowShown
        h:GetFrame():SetShown(rowShown)
    end

    local ver = DF.auraLayoutVersion or 0
    if frame.dfDebuffFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfDebuffFactoryVersion = ver
        local cfg = DF:BuildAuraRowConfig(db, "debuff", {
            unit = frame.unit,
            filterList = BuildDirectDebuffFilters(db),
        })
        h:GetFrame():SetFrameLevel(math.max(0, frame:GetFrameLevel() + (cfg.frameLevelOffset or 40)))
        local sig = buffFactorySig(cfg)
        if frame.debuffFactorySig ~= sig then
            frame.debuffFactorySig = sig
            h:Rebuild(cfg)                      -- structural — REPLACES the config wholesale
        else
            h:ApplyStyle(cfg.style, cfg.layout) -- cosmetics — in place, no leak
        end
    end
end

-- ============================================================
-- DEFENSIVE-ICON FACTORY BRIDGE (pilot — first non-buff consumer)
-- Routes the defensive row through DF.AuraContainer on 12.1 using the native
-- BIG_DEFENSIVE / EXTERNAL_DEFENSIVE filters. Reuses the buff bridge's config SHAPE
-- + buffFactorySig (the element-agnostic row signature). Defensive settings have a
-- different key layout (defensiveIcon* + defensiveBar*), so they get a dedicated
-- mapper rather than the prefix builder. Native-only on 12.1 (requires
-- on) + IsSupported → no effect on live 12.0.x.
-- Known v1 gaps (native filters can't exclude specific instances until PTR-4):
-- no AD/buff dedup, no range fade, CENTER growth falls back to RIGHT.
-- ============================================================

-- Render gate (excludes test mode, which paints legacy icons directly).
function DF:UseFactoryForDefensive(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and BuildDirectDefensiveFilters() ~= nil
        and not (DF.testMode or DF.raidTestMode)
end

-- GUI-facing predicate (does NOT exclude test mode, so a "blocked" overlay doesn't
-- flicker while previewing). Mirrors DF:FactoryOwnsBuffRow.
function DF:FactoryOwnsDefensiveRow(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()
        and BuildDirectDefensiveFilters() ~= nil) or false
end

-- Map the defensive settings -> the AuraContainer config SHAPE. Filter = the native
-- defensive list the legacy classifier already uses; a row of up to defensiveBarMax
-- icons. Stacks use the legacy min-2 display. buffFactorySig treats this cfg the same
-- as a buff cfg (it reads derived fields, not db keys).
function DF:BuildDefensiveRowConfig(db, unit)
    local iconSize = db.defensiveIconSize or 24
    local dur
    if db.defensiveIconShowDuration ~= false then
        local colorByTime = db.defensiveIconDurationColorByTime and true or false
        -- Shared TextStyle spec (picks up defensiveIconDurationFont/Scale/Outline/X/Y/
        -- JustifyH/JustifyV/Color); feature fields ride on top.
        dur = DF.TextStyle:BuildSpec(db, "defensiveIconDuration", {
            baseSize = 10, defaultAnchor = "CENTER", boxW = iconSize, boxH = iconSize,
        })
        dur.show = true
        dur.formatter = GetDurationFormatter("NUMBER", nil, colorByTime)
        -- colorByTime = colour buckets baked into the formatter bands (see
        -- BuildDurationFormatter). Static colour must not stomp the escapes.
        if colorByTime then dur.color = nil end
        dur.formatKey = "NUMBER" .. (colorByTime and ":C" or "")
    end

    -- SINGLE group (12.1): overlapping groups render DUPLICATE buttons — the container
    -- has no cross-group dedup and addon-side dedup is impossible (button contents are
    -- secret). Guardian Spirit proved BIG ∩ EXTERNAL ≠ ∅; externals are classified as
    -- big defensives (Blizzard's BigDefensive comparator expects them in ONE list), so
    -- one BIG_DEFENSIVE group covers the row with no dupes. Legacy/test mode keeps the
    -- two-filter scan + Lua dedup (BuildDirectDefensiveFilters) — different pipeline.
    -- IN-GAME CHECK: if an external-only defensive (e.g. PS/Ironbark on someone) stops
    -- showing, external ⊄ big on this build — revert to BuildDirectDefensiveFilters().
    local factoryFilter
    if AuraFilters.BigDefensive then factoryFilter = { "HELPFUL|" .. AuraFilters.BigDefensive }
    elseif AuraFilters.ExternalDefensive then factoryFilter = { "HELPFUL|" .. AuraFilters.ExternalDefensive } end

    return {
        unit     = unit,
        mode     = "row",
        filter   = factoryFilter or BuildDirectDefensiveFilters(),
        max      = db.defensiveBarMax or 4,
        enabled  = true,
        -- Native sort built FOR this row: longest-duration external first, own
        -- defensives last (AuraUtil.BigDefensiveAuraCompare) — "show me the save
        -- someone else put on this player". Carried in the row signature.
        sort     = { method = "BigDefensive" },
        -- P5 preview: HELPFUL category alone would page the buff pool — show
        -- curated defensives instead (TestMode drives testMax per role).
        testPool = "defensives",
        tooltips = (not db.defensiveIconDisableMouse) and db.tooltipDefensiveEnabled ~= false,
        -- Z-order: match the legacy defensive level — contentOverlay+26 = frame+51 when auto
        -- (defensiveIconFrameLevel 0), else the user's own offset. Applied to the container's
        -- anchor frame in AuraContainer:Create + on each layout-version re-apply.
        frameLevelOffset = (db.defensiveIconFrameLevel and db.defensiveIconFrameLevel ~= 0)
            and db.defensiveIconFrameLevel or 51,
        layout = {
            size     = db.defensiveIconSize or 24,
            scale    = db.defensiveIconScale or 1,
            spacingX = db.defensiveBarSpacing or 2,
            spacingY = db.defensiveBarSpacing or 2,
            anchor   = db.defensiveIconAnchor or "CENTER",
            growth   = db.defensiveBarGrowth or "RIGHT_DOWN",
            wrap     = db.defensiveBarWrap or 5,
            offsetX  = db.defensiveIconX or 0,
            offsetY  = db.defensiveIconY or 0,
            preScaledStep = false,   -- legacy defensive spacing (unscaled size term; no double-scale)
        },
        style = {
            icon   = { show = true, zoom = true, inset = 0 },
            border = (db.defensiveIconShowBorder ~= false) and { db = db, prefix = "defensiveIcon" } or nil,
            cooldown = { show = not db.defensiveIconHideSwipe, reverse = true, edge = false, numbers = false },
            duration = dur,
            -- TextStyle-shaped spec (defensive stacks have no db keys — legacy fixed
            -- look, size/outline explicit now that TextStyle owns the render defaults).
            -- No formatter: forbidden on container rows (secret trap — see the
            -- GetStacksFormatter tombstone above). Native default = counts > 1.
            stacks = {
                show      = true,
                anchor    = "BOTTOMRIGHT",
                offsetX   = 2,
                offsetY   = -1,
                size      = 14,
                outline   = "OUTLINE",
            },
        },
    }
end

-- Drive the factory defensive row for one frame. Mirrors DriveBuffFactory: lazy create,
-- hide the legacy defensive pool (no double render), keep on the frame's unit, re-apply
-- on a layout-version bump. The container self-updates from UNIT_AURA (no per-tick render).
function DF:DriveDefensiveFactory(frame, db)
    local h = frame.defensiveFactory
    if not h then
        h = DF.AuraContainer:Create(frame, DF:BuildDefensiveRowConfig(db, frame.unit))
        frame.defensiveFactory = h
        frame.dfDefFactoryVersion = DF.auraLayoutVersion or 0
        if h then frame.defensiveFactorySig = buffFactorySig(h.config) end
    end

    -- No double render: keep the legacy defensive icon pool hidden while the factory owns it.
    if frame.defensiveIcon then frame.defensiveIcon:Hide() end
    if frame.defensiveBarIcons then
        for _, icon in pairs(frame.defensiveBarIcons) do
            if icon and icon.Hide then icon:Hide() end
        end
    end
    if not h then return end

    -- Keep on the frame's unit; defer a wrong-unit show until regen in combat. Hide via the
    -- plain anchor frame (GetFrame():SetShown), NOT h:SetShown -- the latter queues an enable
    -- op that would upgrade a queued retarget into a full rebuild (frame leak).
    if h:GetUnit() ~= frame.unit then
        h:SetUnit(frame.unit)
        frame.dfDefFactoryHidden = InCombatLockdown() or nil
    elseif frame.dfDefFactoryHidden and not InCombatLockdown() then
        frame.dfDefFactoryHidden = nil
    end
    -- Show/hide only on state change (no per-event SetShown churn on the live tree —
    -- build-once-leave-it, mirrors DriveBuffFactory).
    local rowShown = not frame.dfDefFactoryHidden
    if frame.dfDefFactoryShown ~= rowShown then
        frame.dfDefFactoryShown = rowShown
        h:GetFrame():SetShown(rowShown)
    end

    -- Re-apply settings only on a layout-version bump (defensive option changes bump it
    -- via UpdateAllDefensiveBars -> InvalidateAuraLayout) — and only OUT of combat: the
    -- standing container is never re-touched in lockdown (lab parity); the stale version
    -- catches up on the first OOC drive.
    local ver = DF.auraLayoutVersion or 0
    if frame.dfDefFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfDefFactoryVersion = ver
        local cfg = DF:BuildDefensiveRowConfig(db, frame.unit)
        -- Re-apply the z-order level (honors runtime defensiveIconFrameLevel changes; survives
        -- Rebuild since the new container inherits relative to h.frame). Not part of the sig.
        h:GetFrame():SetFrameLevel(math.max(0, frame:GetFrameLevel() + (cfg.frameLevelOffset or 40)))
        local sig = buffFactorySig(cfg)
        if frame.defensiveFactorySig ~= sig then
            frame.defensiveFactorySig = sig
            h:Rebuild(cfg)                      -- structural (max/filter/tooltips)
        else
            h:ApplyStyle(cfg.style, cfg.layout) -- cosmetics — in place, no leak
        end
    end
end

-- ============================================================
-- MISSING-BUFF FACTORY BRIDGE — read-free layout-push inversion (probe 32,
-- live-confirmed 2026-07-10). One "missing"-mode handle per tracked raid buff:
-- an empty spellID-filtered group parks the badge inside a clip window; the
-- buff's (blank) button pushes it out. ZERO aura reads — works in combat on
-- every assistable unit, independent of the transitional whitelist. Replaces
-- the legacy UnitHasBuff 4-method scan on 12.1.
-- Behaviour change vs legacy (flagged in the port plan §2.5): manual multi-buff
-- mode shows EVERY tracked-and-missing buff as a strip of badges — the old
-- "first missing only" priority pick was a cross-aura read, which is dead.
-- Class-detection mode (one buff) is identical to legacy.
-- ============================================================

local MISSING_BADGE_SIZE = 24   -- fallback when missingBuffIconSize is unset; missingBuffIconScale scales the strip
local MISSING_BADGE_GAP  = 2

-- Render gate (excludes test mode, which paints the legacy missingBuffFrame).
function DF:UseFactoryForMissingBuff(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
end

-- GUI-facing predicate (does NOT exclude test mode — see FactoryOwnsBuffRow).
function DF:FactoryOwnsMissingBuff(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
end

-- Tracked raid buffs per settings: class-detection = only YOUR class's buff;
-- manual = every enabled missingBuffCheck* key. Returns DF.RaidBuffs entries
-- ({spellIDOrTable, configKey, name, class}) in DF.RaidBuffs order.
local function missingTrackedBuffs(db)
    local list = {}
    local playerKey
    if db.missingBuffClassDetection then
        playerKey = DF.ClassToRaidBuff and DF.ClassToRaidBuff[select(2, UnitClass("player"))]
        if not playerKey then return list end   -- class has no raid buff -> nothing to track
    end
    for i = 1, #DF.RaidBuffs do
        local info = DF.RaidBuffs[i]
        if (playerKey and info[2] == playerKey) or (not playerKey and db[info[2]]) then
            list[#list + 1] = info
        end
    end
    return list
end

-- Structural signature: the tracked set (cell handles are created per entry).
local function missingFactorySig(tracked)
    local keys = {}
    for i = 1, #tracked do keys[i] = tracked[i][2] end
    return table.concat(keys, ",")
end

-- Per-cell container config: HELPFUL + includeSpellIDs (any rank/variant ID of
-- the tracked buff matches). Helpful spell-ID maps apply on assistable units —
-- exactly the frames this feature targets (the badge is guard-hidden elsewhere).
local function buildMissingCellConfig(info, unit, size)
    local ids = type(info[1]) == "table" and info[1] or { info[1] }
    local map = {}
    for i = 1, #ids do map[ids[i]] = true end
    return {
        unit = unit,
        mode = "missing",
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        badge = { w = size, h = size },
        enabled = true,
    }
end

-- Paint one cell's badge: spell icon + unified DF.Border (missingBuffIcon* keys).
-- The badge frame's POSITION derives from the container's secret size (§20c):
-- never pixel-snap it or read its rect; secretRect borders render anchor-only.
-- Animation is stripped like the container rows (expiry-triggered anim is dead
-- and the badge should match the aura buttons' treatment).
local function styleMissingBadge(h, db, frame, info)
    local badge = h.GetBadgeFrame and h:GetBadgeFrame()
    if not badge then return end
    local firstID = type(info[1]) == "table" and info[1][1] or info[1]
    if not badge.dfIcon then
        badge.dfIcon = badge:CreateTexture(nil, "ARTWORK")
        badge.dfIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    local iconTex
    if C_Spell and C_Spell.GetSpellTexture then iconTex = C_Spell.GetSpellTexture(firstID)
    elseif GetSpellTexture then iconTex = GetSpellTexture(firstID) end
    badge.dfIcon:SetTexture(iconTex)

    local showBorder = db.missingBuffIconShowBorder ~= false
    local borderSize = db.missingBuffIconBorderSize or 2
    if db.pixelPerfect then borderSize = DF:PixelPerfect(borderSize) end
    if not badge.dfBorder then
        badge.dfBorder = DF.Border:New(badge, { frameLevelOffset = 0, secretRect = true })
    end
    local spec = DF.Border:BuildSpec(db, "missingBuffIcon", { unit = frame.unit, frame = frame, iconMode = true })
    spec.enabled = showBorder
    spec.size = borderSize
    -- The badge border is secretRect, so an animation driver would be hosted on UIParent
    -- (see ensureDriver in Border.lua) and this badge is NOT covered by a container
    -- teardown loop. Keep animation OFF here — never let the badge animate, or its driver
    -- would tick forever with no teardown.
    spec.animation = nil
    DF.Border:Apply(badge.dfBorder, spec)

    local artInset = showBorder and borderSize or 0
    badge.dfIcon:ClearAllPoints()
    badge.dfIcon:SetPoint("TOPLEFT", artInset, -artInset)
    badge.dfIcon:SetPoint("BOTTOMRIGHT", -artInset, artInset)
end

-- Position/scale/level the strip (the OUR-side outer frame all cells live in) —
-- the legacy missingBuffFrame positioning block, applied to the strip. The strip
-- is a plain DF frame (non-secret rect): pixel-snap is fine HERE.
local function layoutMissingStrip(frame, db, strip, cellCount)
    local size = db.missingBuffIconSize or MISSING_BADGE_SIZE
    local w = cellCount * size + math.max(0, cellCount - 1) * MISSING_BADGE_GAP
    strip:SetSize(math.max(w, 1), size)
    strip:SetScale(db.missingBuffIconScale or 1.5)
    local anchor = db.missingBuffIconAnchor or "CENTER"
    strip:ClearAllPoints()
    strip:SetPoint(anchor, frame, anchor, db.missingBuffIconX or 0, db.missingBuffIconY or 0)
    DF:SnapPointToPixelGrid(strip, db.pixelPerfect)
    local frameLevel = db.missingBuffIconFrameLevel or 0
    if frameLevel == 0 and frame.contentOverlay then
        strip:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 10)
    else
        strip:SetFrameLevel(math.max(0, frame:GetFrameLevel() + frameLevel))
    end
end

-- Drive the missing-buff strip for one frame. Mirrors the row drives: lazy create,
-- hide the legacy icon (no double render), guard visibility on the NON-aura state
-- (dead/offline/range/UnitCanAssist — the read-free mechanism only answers aura
-- presence), keep cells on the frame's unit, re-apply on a layout-version bump.
function DF:DriveMissingBuffFactory(frame, db)
    -- No double render: the legacy icon stays hidden while the factory owns the feature.
    if frame.missingBuffFrame then frame.missingBuffFrame:Hide() end

    local strip = frame.missingBuffStrip
    local cells = frame.missingFactory

    -- Feature off -> hide the strip (keep the cells; cheap re-show on re-enable).
    if not db.missingBuffIconEnabled then
        if strip and frame.dfMissingStripShown ~= false then
            strip:Hide()
            frame.dfMissingStripShown = false
        end
        return
    end

    -- Lazy strip + cells; recreate the cells when the tracked set changes (rare:
    -- settings toggle / class-detection flip). Handle creation is combat-guarded
    -- inside the factory (defers the container build to regen).
    local tracked = missingTrackedBuffs(db)
    if #tracked == 0 then
        -- Nothing to track (no manual buffs checked / class has no raid buff):
        -- drop any stale cells and keep the strip hidden.
        if cells then
            for _, h in pairs(cells) do h:Destroy() end
            frame.missingFactory = nil
            frame.missingFactorySig = nil
        end
        if strip and frame.dfMissingStripShown ~= false then
            strip:Hide()
            frame.dfMissingStripShown = false
        end
        return
    end
    -- Badge size is NOT in the signature: it hot-applies through h:SetBadgeSize
    -- (live group-layout mutator + our frames) in the version-gated block below —
    -- a size slider drag must never recreate containers (per-tick churn).
    local badgeSize = db.missingBuffIconSize or MISSING_BADGE_SIZE
    local sig = missingFactorySig(tracked)
    if not strip then
        strip = CreateFrame("Frame", nil, frame.contentOverlay or frame)
        frame.missingBuffStrip = strip
        frame.dfMissingStripShown = nil
    end
    if not cells or frame.missingFactorySig ~= sig then
        if cells then
            for _, h in pairs(cells) do h:Destroy() end
        end
        cells = {}
        frame.missingFactory = cells
        frame.missingFactorySig = sig
        frame.dfMissingFactoryVersion = DF.auraLayoutVersion or 0
        for i = 1, #tracked do
            local info = tracked[i]
            local h = DF.AuraContainer:Create(strip, buildMissingCellConfig(info, frame.unit, badgeSize))
            if h then
                h:ClearAllPoints()
                h:SetPoint("LEFT", strip, "LEFT", (i - 1) * (badgeSize + MISSING_BADGE_GAP), 0)
                styleMissingBadge(h, db, frame, info)
                cells[info[2]] = h
            end
        end
        layoutMissingStrip(frame, db, strip, #tracked)
    end

    -- Non-aura visibility guards: the badge must never claim "missing" on a
    -- corpse / offline / out-of-range / unassistable unit. All non-secret reads;
    -- range mirrors the legacy issecretvalue guard. DELIBERATE change vs legacy:
    -- no UnitIsPlayer — legacy excluded NPC group members because its aura SCAN
    -- couldn't check them, but raid buffs are castable on follower-dungeon NPCs
    -- (Krathe-verified) and the read-free widget works on any assistable unit.
    -- Pets stay excluded (pet frames don't run this feature).
    local unit = frame.unit
    local visible
    if DF.AuraContainer and DF.AuraContainer._testMode then
        -- P5 preview: fabricated test units fail every unit API — visibility is
        -- the test panel's toggle (UpdateTestMissingBuff gates on it before
        -- calling). The badges show because missing containers stay DISABLED
        -- for the test session (the provider bounce skips them), so every
        -- group is empty and every badge sits parked in its window.
        visible = true
    else
        visible = unit and UnitExists(unit)
            and not UnitIsDeadOrGhost(unit) and UnitIsConnected(unit)
            and not frame.isPetFrame and UnitCanAssist("player", unit)
        if visible then
            local inRange = frame.dfInRange
            if issecretvalue and issecretvalue(inRange) then
                visible = false
            elseif inRange == false then
                visible = false
            end
        end
    end
    visible = visible and true or false
    if frame.dfMissingStripShown ~= visible then
        frame.dfMissingStripShown = visible
        strip:SetShown(visible)
    end

    -- Keep cells on the frame's unit (roster churn); refresh the border spec with
    -- the new unit's class/role colour. Combat: SetUnit self-defers in the factory.
    local trackedByKey
    for key, h in pairs(cells) do
        if h:GetUnit() ~= unit then
            h:SetUnit(unit)
            if not trackedByKey then
                trackedByKey = {}
                for i = 1, #tracked do trackedByKey[tracked[i][2]] = tracked[i] end
            end
            if trackedByKey[key] then styleMissingBadge(h, db, frame, trackedByKey[key]) end
        end
    end

    -- Re-apply settings on a layout-version bump only, out of combat (build-once-
    -- leave-it: the badges/strip are ours, but the cadence mirrors the row drives).
    -- Size hot-applies per cell (window/badge/cell mutators) + cells re-space.
    local ver = DF.auraLayoutVersion or 0
    if frame.dfMissingFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfMissingFactoryVersion = ver
        layoutMissingStrip(frame, db, strip, #tracked)
        for i = 1, #tracked do
            local info = tracked[i]
            local h = cells[info[2]]
            if h then
                if h.SetBadgeSize then h:SetBadgeSize(badgeSize, badgeSize) end
                h:ClearAllPoints()
                h:SetPoint("LEFT", strip, "LEFT", (i - 1) * (badgeSize + MISSING_BADGE_GAP), 0)
                styleMissingBadge(h, db, frame, info)
            end
        end
    end
end

-- Immediately re-drive the factory rows on every active frame (out of combat).
-- The drives normally run inside the aura update cycle, so a GUI layout change —
-- which only bumps auraLayoutVersion — would otherwise apply "one aura event late"
-- (the live slider lag). Called from DF:InvalidateAuraLayout right after the bump.
-- Cheap when nothing changed: each drive is version-gated and its ApplyStyle path
-- uses the container's live layout mutators (no rebuild). Pinned-set frames catch
-- up on their next aura event (they share the same version check).
local function driveFactoryRowsNow(frame)
    if not frame or not frame.unit then return end
    local db = DF:GetFrameDB(frame)
    if not db then return end
    if db.showBuffs and DF:UseFactoryForBuffs(frame, db) then
        DF:DriveBuffFactory(frame, db)
    end
    if db.showDebuffs and DF:UseFactoryForDebuffs(frame, db) then
        DF:DriveDebuffFactory(frame, db)
    end
    if db.defensiveIconEnabled and DF:UseFactoryForDefensive(frame, db) then
        DF:DriveDefensiveFactory(frame, db)
    end
    if db.missingBuffIconEnabled and DF:UseFactoryForMissingBuff(frame, db) then
        DF:DriveMissingBuffFactory(frame, db)
    end
    -- Un-gated on the enable setting: the drive tears its container down when the
    -- overlay is off, so a GUI disable applies on this pass rather than one late.
    if DF.UseFactoryForDispelOverlay and DF:UseFactoryForDispelOverlay(frame, db) then
        DF:DriveDispelOverlayFactory(frame, db)
    end
end

-- DEBOUNCED to one pass per frame-render: GUI callbacks often bump the version
-- several times in one click (Invalidate + UpdateAllFrames chains), and slider
-- drags fire per tick — coalescing keeps a 40-man raid drag at one drive pass
-- per rendered frame instead of one per callback. The 0-delay timer re-checks
-- combat when it fires (timers can land after lockdown re-engages).
local factoryRefreshQueued = false
function DF:RefreshFactoryRows()
    if factoryRefreshQueued then return end
    if not (DF.AuraContainer and DF.AuraContainer.IsSupported and DF.AuraContainer.IsSupported()) then return end
    factoryRefreshQueued = true
    C_Timer.After(0, function()
        factoryRefreshQueued = false
        if InCombatLockdown() then return end   -- drives self-defer in combat; version catches up at next drive
        if DF.IteratePartyFrames then DF:IteratePartyFrames(driveFactoryRowsNow) end
        if DF.IterateRaidFrames then DF:IterateRaidFrames(driveFactoryRowsNow) end
    end)
end

function DF:UpdateAuras_Enhanced(frame)
    if not frame or not frame.unit then return end

    -- PERF TEST: Skip if disabled
    if DF.PerfTest and not DF.PerfTest.enableAuras then return end

    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)

    -- Factory buff row (experimental). Compute once. If a container was built but the factory
    -- path is no longer active (dev toggle off, test mode, or showBuffs off),
    -- hide it via its plain anchor frame (combat-safe, queues no backend op) so the legacy
    -- render can't double up. DriveBuffFactory re-shows it when it drives.
    local buffFactoryActive = db.showBuffs and DF:UseFactoryForBuffs(frame, db)
    if frame.buffFactory and not buffFactoryActive then
        frame.buffFactory:GetFrame():Hide()
        frame.dfBuffFactoryShown = false   -- keep DriveBuffFactory's shown-cache coherent
    end
    local debuffFactoryActive = db.showDebuffs and DF:UseFactoryForDebuffs(frame, db)
    if frame.debuffFactory and not debuffFactoryActive then
        frame.debuffFactory:GetFrame():Hide()
        frame.dfDebuffFactoryShown = false
    end
    -- Missing-buff strip mirror: hide it when the factory path goes inactive (test
    -- mode enter / feature off) so the legacy/test render can't double up.
    local missingFactoryActive = db.missingBuffIconEnabled and DF:UseFactoryForMissingBuff(frame, db)
    if frame.missingBuffStrip and not missingFactoryActive and frame.dfMissingStripShown then
        frame.missingBuffStrip:Hide()
        frame.dfMissingStripShown = false
    end

    -- Aura Designer runs when enabled; standard buffs can coexist if showBuffs is on.
    local adEnabled = DF:IsAuraDesignerEnabled(frame)
    if adEnabled then
        -- Run AD engine (indicators, frame effects, etc.). On 12.1 the native factory
        -- bridge (DF.AuraDesigner.Factory) owns AD when DF:UseFactoryForAD is true; the
        -- legacy read-path engine stays byte-for-byte reachable when the gate is false
        -- (pre-12.1 clients, test mode, or adUseFactory=false).
        if DF.AuraDesigner and DF.AuraDesigner.Factory and DF:UseFactoryForAD(frame, db) then
            DF.AuraDesigner.Factory:SyncFrame(frame)
        elseif DF.AuraDesigner and DF.AuraDesigner.Engine then
            DF.AuraDesigner.Engine:UpdateFrame(frame)
        end

    end


    -- Buff display: the native container renders the row (Blizzard-driven).
    -- Shown when: AD is off, OR AD is on with showBuffs enabled (coexistence)
    if (not adEnabled or db.showBuffs) and buffFactoryActive then
        DF:DriveBuffFactory(frame, db)
    end

    -- Debuff display (always runs — AD doesn't manage debuffs)
    if debuffFactoryActive then
        DF:DriveDebuffFactory(frame, db)
    end
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

local OriginalUpdateAuras = nil
local enhancedAurasInitialized = false

local function InitializeEnhancedAuras()
    if enhancedAurasInitialized then return end

    -- Replace UpdateAuras with enhanced version
    if DF.UpdateAuras and not OriginalUpdateAuras then
        OriginalUpdateAuras = DF.UpdateAuras
        DF.UpdateAuras = DF.UpdateAuras_Enhanced
    elseif not DF.UpdateAuras then
        -- DF.UpdateAuras doesn't exist yet - define it directly
        DF.UpdateAuras = DF.UpdateAuras_Enhanced
    end

    enhancedAurasInitialized = true

    -- Direct scanning is the only aura source (the Blizzard-frame capture
    -- pipeline died with 12.0.5, and the mode was removed in 4.6.1).
    -- Delayed slightly to ensure unitFrameMap is populated.
    C_Timer.After(0.5, function()
        DF:EnableDirectAuraMode()
    end)
end

-- ============================================================
-- CRITICAL: Initialize synchronously, not with delay!
-- During combat reload, delayed initialization would fire AFTER combat
-- lockdown re-establishes, causing UpdateAuras to use the old (non-cached)
-- version instead of the Blizzard-cache-based enhanced version.
-- ============================================================
InitializeEnhancedAuras()

-- ============================================================
-- SAFEGUARD: Ensure enhanced version is used even if Icons.lua
-- loads after Auras.lua (shouldn't happen, but be defensive)
-- ============================================================
local auraInitFrame = CreateFrame("Frame")
auraInitFrame:RegisterEvent("ADDON_LOADED")
auraInitFrame:SetScript("OnEvent", function(self, event, arg1)
    if arg1 == "DandersFrames" then
        -- Double-check that enhanced version is active
        if DF.UpdateAuras ~= DF.UpdateAuras_Enhanced then
            if DF.UpdateAuras then
                OriginalUpdateAuras = DF.UpdateAuras
            end
            DF.UpdateAuras = DF.UpdateAuras_Enhanced
        end
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

-- ============================================================
-- DEBUG FUNCTION
-- ============================================================

function DF:DebugAuraFiltering()
    print("|cff00ccffDandersFrames Aura Filter Debug:|r")
    print("")
    print("|cffffcc00Hook Status:|r")
    print("  CompactUnitFrame_UpdateAuras exists:", CompactUnitFrame_UpdateAuras and "Yes" or "No")
    print("")
    
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    print("|cffffcc00Current Settings:|r")
    print("  Aura Source: Direct API (the only source since 4.6.1)")
    print("  Hide Blizzard Party Frames:", db.hideBlizzardPartyFrames and "Yes" or "No")
    print("  Hide Blizzard Raid Frames:", raidDb.hideBlizzardRaidFrames and "Yes" or "No")
    print("")
    
    print("|cffffcc00Blizzard Aura Cache:|r")
    local cacheCount = 0
    for unit, cache in pairs(DF.BlizzardAuraCache) do
        local buffCount, debuffCount = 0, 0
        for _ in pairs(cache.buffs) do buffCount = buffCount + 1 end
        for _ in pairs(cache.debuffs) do debuffCount = debuffCount + 1 end
        print("  " .. unit .. ": " .. buffCount .. " buffs, " .. debuffCount .. " debuffs cached")
        cacheCount = cacheCount + 1
    end
    if cacheCount == 0 then
        print("  (empty - no units scanned yet)")
        print("  Try: /dfauras scan")
    end
end

-- ============================================================
-- HIDE/SHOW BLIZZARD RAID FRAMES
-- Blizzard mode: hide containers, strip events but keep UNIT_AURA
-- Direct mode: fully disable frames (unregister ALL events,
--   reparent party frames to hidden parent — Grid2 pattern)
-- ============================================================

-- Track if we've installed hooks (only do once)
local blizzardHooksInstalled = false

-- Track which frames have been stripped so we can restore them
local strippedFrames = {}

-- Track frames that have been reparented to the hidden frame
local reparentedFrames = {}

-- Hidden parent frame for fully disabling Blizzard frames (Grid2 pattern)
local blizzardHiddenParent = CreateFrame("Frame")
blizzardHiddenParent:Hide()

-- Track if Direct-mode full disable is active
DF.blizzardFramesFullyDisabled = false

-- Function to strip events from a Blizzard unit frame
-- fullDisable=true: unregister ALL events (Direct mode, no Blizzard aura data needed)
-- fullDisable=false: keep UNIT_AURA + combat events (Blizzard mode, need aura cache)
local function StripUnitFrameEvents(frame, fullDisable)
    if not frame then return end
    local unit = frame.unit
    if unit then
        pcall(function()
            frame:UnregisterAllEvents()
            if not fullDisable then
                -- Re-register UNIT_AURA so Blizzard's aura cache keeps updating
                frame:RegisterUnitEvent("UNIT_AURA", unit)
                -- Keep combat events for proper updates
                frame:RegisterEvent("PLAYER_REGEN_ENABLED")
                frame:RegisterEvent("PLAYER_REGEN_DISABLED")
            end
        end)
        strippedFrames[frame] = true
    end
end

-- Reparent a frame to the hidden parent (fully removes it from the visual tree)
local function ReparentToHidden(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    pcall(function()
        if frame.GetParent then
            reparentedFrames[frame] = frame:GetParent()
        end
        frame:SetParent(blizzardHiddenParent)
        frame:Hide()
    end)
end

-- Restore a reparented frame back to its original parent
local function RestoreParent(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    local originalParent = reparentedFrames[frame]
    if originalParent then
        pcall(function()
            frame:SetParent(originalParent)
        end)
        reparentedFrames[frame] = nil
    end
end

-- Function to restore all events on a frame (call Blizzard's setup function)
local function RestoreUnitFrameEvents(frame)
    if not frame then return end
    if not strippedFrames[frame] then return end

    -- Restore parent first if it was reparented
    RestoreParent(frame)

    pcall(function()
        -- Call Blizzard's function to restore all events
        if CompactUnitFrame_UpdateUnitEvents then
            CompactUnitFrame_UpdateUnitEvents(frame)
        end
    end)
    strippedFrames[frame] = nil
end

-- Install hooks once to intercept Blizzard's event registration
local function InstallBlizzardHooks()
    if blizzardHooksInstalled then return end
    
    -- Hook CompactUnitFrame_UpdateUnitEvents to strip events but keep UNIT_AURA
    if CompactUnitFrame_UpdateUnitEvents then
        hooksecurefunc("CompactUnitFrame_UpdateUnitEvents", function(frame)
            -- Only strip events if we're hiding Blizzard frames
            local raidDb = DF:GetRaidDB()
            local partyDb = DF:GetDB()
            local shouldStrip = false
            
            if frame.unit then
                if frame.unit:match("^raid") and raidDb.hideBlizzardRaidFrames then
                    shouldStrip = true
                elseif frame.unit:match("^party") and partyDb.hideBlizzardPartyFrames then
                    shouldStrip = true
                elseif frame.unit == "player" and partyDb.hideBlizzardPartyFrames then
                    shouldStrip = true
                end
            end
            
            if shouldStrip then
                -- In Direct mode, fully disable (no events at all)
                local isDirectMode = false
                if frame.unit then
                    if frame.unit:match("^raid") then
                        isDirectMode = true
                    else
                        isDirectMode = true
                    end
                end
                StripUnitFrameEvents(frame, isDirectMode)
            end
        end)
    end

    -- Hook side menu frames to forcibly re-hide when Blizzard re-shows them
    -- SetAlpha(0) alone is insufficient — Blizzard code resets alpha on various events
    local function ShouldHideSideMenu()
        -- Always hide side menu when solo — it's a party/raid UI element
        if not IsInGroup() and not IsInRaid() then return true end
        local raidDb = DF:GetRaidDB()
        local partyDb = DF:GetDB()
        if not raidDb or not partyDb then return false end
        if IsInRaid() then
            return raidDb.hideBlizzardRaidFrames and not raidDb.showBlizzardSideMenu
        else
            return partyDb.hideBlizzardPartyFrames and not partyDb.showBlizzardSideMenu
        end
    end

    local function ForceHideSideMenuFrame(frame)
        if not frame then return end
        pcall(function()
            if not InCombatLockdown() then
                frame:Hide()
            else
                frame:SetAlpha(0)
            end
        end)
    end

    if CompactRaidFrameManager then
        hooksecurefunc(CompactRaidFrameManager, "Show", function()
            if ShouldHideSideMenu() then
                ForceHideSideMenuFrame(CompactRaidFrameManager)
            end
        end)
        if CompactRaidFrameManager.displayFrame then
            hooksecurefunc(CompactRaidFrameManager.displayFrame, "Show", function()
                if ShouldHideSideMenu() then
                    ForceHideSideMenuFrame(CompactRaidFrameManager.displayFrame)
                end
            end)
        end
    end

    blizzardHooksInstalled = true
end

function DF:UpdateBlizzardFrameVisibility()
    local partyDb = DF:GetDB()
    local raidDb = DF:GetRaidDB()

    -- Separate settings for party and raid frames
    local hidePartyFrames = partyDb.hideBlizzardPartyFrames
    local hideRaidFrames = raidDb.hideBlizzardRaidFrames

    -- Check if Direct mode is active (allows full disable instead of just hiding)
    local partyDirectMode = true -- direct is the only aura source (4.6.1)
    local raidDirectMode = true
    DF.blizzardFramesFullyDisabled = (hidePartyFrames and partyDirectMode) or (hideRaidFrames and raidDirectMode)
    
    -- Side menu visibility - hide when solo, respect setting when grouped
    local showSideMenu
    if not IsInGroup() and not IsInRaid() then
        showSideMenu = false
    elseif IsInRaid() then
        showSideMenu = raidDb.showBlizzardSideMenu
    else
        showSideMenu = partyDb.showBlizzardSideMenu
    end
    
    -- Install hooks if we're hiding frames
    if hidePartyFrames or hideRaidFrames then
        InstallBlizzardHooks()
    end
    
    -- Function to safely apply visibility using SetAlpha only
    local function SafeHideFrame(frame, hide)
        if not frame then return end
        pcall(function()
            if hide then
                frame:SetAlpha(0)
            else
                frame:SetAlpha(1)
            end
        end)
    end
    
    -- Function to safely scale container frames
    local function SafeScaleContainer(frame, hide)
        if not frame then return end
        if InCombatLockdown() then return end
        pcall(function()
            if hide then
                frame:SetAlpha(0)
                frame:SetScale(0.001)
            else
                frame:SetAlpha(1)
                frame:SetScale(1)
            end
        end)
    end
    
    -- Function to safely apply just alpha
    local function SafeSetAlpha(frame, alpha)
        if frame and frame.SetAlpha then
            pcall(function() frame:SetAlpha(alpha) end)
        end
    end
    
    -- Function to hide selection highlights
    local function HideSelectionHighlights(frame)
        if not frame then return end
        pcall(function()
            if frame.selectionHighlight and frame.selectionHighlight.SetShown then
                frame.selectionHighlight:SetShown(false)
            end
            if frame.selectionIndicator and frame.selectionIndicator.SetShown then
                frame.selectionIndicator:SetShown(false)
            end
        end)
    end
    
    -- Hide/show the main container frames (raid-style)
    SafeScaleContainer(CompactRaidFrameContainer, hideRaidFrames)
    
    -- Handle CompactPartyFrame (raid-style party frames)
    if CompactPartyFrame then
        SafeSetAlpha(CompactPartyFrame, hidePartyFrames and 0 or 1)
        SafeSetAlpha(CompactPartyFrame.title, hidePartyFrames and 0 or 1)
        SafeSetAlpha(CompactPartyFrame.borderFrame, hidePartyFrames and 0 or 1)
        if hidePartyFrames then
            HideSelectionHighlights(CompactPartyFrame)
        end
    end
    
    -- Handle traditional portrait-style party frames
    if hidePartyFrames and partyDirectMode then
        -- Direct mode: fully disable (reparent to hidden frame)
        ReparentToHidden(PartyFrame)
    else
        RestoreParent(PartyFrame)
        SafeScaleContainer(PartyFrame, hidePartyFrames)
    end

    -- Handle individual traditional party member frames (PartyMemberFrame1-4)
    for i = 1, 4 do
        local frame = _G["PartyMemberFrame" .. i]
        if frame then
            if hidePartyFrames and partyDirectMode then
                ReparentToHidden(frame)
            else
                RestoreParent(frame)
                SafeHideFrame(frame, hidePartyFrames)
                local petFrame = _G["PartyMemberFrame" .. i .. "PetFrame"]
                SafeSetAlpha(petFrame, hidePartyFrames and 0 or 1)
                local buffFrame = _G["PartyMemberFrame" .. i .. "BuffFrame"]
                SafeSetAlpha(buffFrame, hidePartyFrames and 0 or 1)
                local debuffFrame = _G["PartyMemberFrame" .. i .. "DebuffFrame"]
                SafeSetAlpha(debuffFrame, hidePartyFrames and 0 or 1)
            end
        end
    end

    -- Handle individual compact party member frames
    for i = 1, 5 do
        local frame = _G["CompactPartyFrameMember" .. i]
        if frame then
            if hidePartyFrames then
                SafeHideFrame(frame, true)
                HideSelectionHighlights(frame)
                StripUnitFrameEvents(frame, partyDirectMode)
            else
                -- Restore events when showing
                RestoreUnitFrameEvents(frame)
            end
        end
    end
    
    -- Handle raid frames
    for i = 1, 40 do
        local frame = _G["CompactRaidFrame" .. i]
        if frame then
            SafeHideFrame(frame, hideRaidFrames)
            if hideRaidFrames then
                HideSelectionHighlights(frame)
                StripUnitFrameEvents(frame, raidDirectMode)
            else
                -- Restore events when showing
                RestoreUnitFrameEvents(frame)
            end
        end
    end

    for group = 1, 8 do
        for member = 1, 5 do
            local frame = _G["CompactRaidGroup" .. group .. "Member" .. member]
            if frame then
                SafeHideFrame(frame, hideRaidFrames)
                if hideRaidFrames then
                    HideSelectionHighlights(frame)
                    StripUnitFrameEvents(frame, raidDirectMode)
                else
                    -- Restore events when showing
                    RestoreUnitFrameEvents(frame)
                end
            end
        end
        -- Also hide group headers
        local groupFrame = _G["CompactRaidGroup" .. group]
        SafeHideFrame(groupFrame, hideRaidFrames)
    end
    
    -- Force hide/show a frame using actual Hide()/Show() outside combat,
    -- falling back to SetAlpha inside combat to avoid taint.
    -- The hooks on Show() only re-hide when ShouldHideSideMenu() is true,
    -- so calling Show() here is safe — if we're showing, the setting is on
    -- and the hook will be a no-op.
    local function ForceHideShow(frame, hide)
        if not frame then return end
        pcall(function()
            if InCombatLockdown() then
                frame:SetAlpha(hide and 0 or 1)
            else
                if hide then
                    frame:Hide()
                else
                    frame:SetAlpha(1)
                    frame:Show()
                end
            end
        end)
    end

    -- Handle raid frame manager
    if CompactRaidFrameManager then
        local sideMenuVisible = showSideMenu or not hideRaidFrames

        SafeHideFrame(CompactRaidFrameManager.container, hideRaidFrames)
        SafeHideFrame(CompactRaidFrameManager.toggleButton, hideRaidFrames)

        -- Handle the display frame (side panel with settings/pings) separately
        -- Use actual Hide() to prevent Blizzard from re-showing via alpha resets
        ForceHideShow(CompactRaidFrameManager.displayFrame, not sideMenuVisible)

        -- The main manager frame itself
        ForceHideShow(CompactRaidFrameManager, not sideMenuVisible)
    end

    -- Handle the side menu elements for party frames
    local partySideMenuVisible = showSideMenu or not hidePartyFrames

    if CompactPartyFrame then
        -- Only adjust title if we want to show/hide the side menu differently
        if not partySideMenuVisible then
            SafeSetAlpha(CompactPartyFrame.title, 0)
        else
            SafeSetAlpha(CompactPartyFrame.title, 1)
        end
        ForceHideShow(CompactPartyFrame.dropdown, not partySideMenuVisible)
        ForceHideShow(CompactPartyFrame.menuButton, not partySideMenuVisible)
    end

    if PartyFrame then
        ForceHideShow(PartyFrame.DropdownButton, not partySideMenuVisible)
        SafeSetAlpha(PartyFrame.PartyMemberFrameDropDown, partySideMenuVisible and 1 or 0)
    end

    if EditModeManagerFrame and EditModeManagerFrame.PartyFramesSidePanel then
        ForceHideShow(EditModeManagerFrame.PartyFramesSidePanel, not sideMenuVisible)
    end
end

-- Apply visibility on load and when group changes
local blizzFrameEventHandler = CreateFrame("Frame")
blizzFrameEventHandler:RegisterEvent("PLAYER_ENTERING_WORLD")
blizzFrameEventHandler:RegisterEvent("GROUP_ROSTER_UPDATE")
blizzFrameEventHandler:RegisterEvent("PLAYER_REGEN_ENABLED")
blizzFrameEventHandler:RegisterEvent("PLAYER_TARGET_CHANGED")
blizzFrameEventHandler:RegisterEvent("RAID_ROSTER_UPDATE")
blizzFrameEventHandler:RegisterEvent("PARTY_MEMBER_ENABLE")
blizzFrameEventHandler:RegisterEvent("PARTY_MEMBER_DISABLE")

-- Coalesce rapid-fire events into a single deferred update to prevent
-- the multiple timer callbacks from fighting each other and causing flicker
local blizzVisibilityPending = false

blizzFrameEventHandler:SetScript("OnEvent", function(self, event)
    if event == "GROUP_ROSTER_UPDATE" then
        if DF.RosterDebugEvent then DF:RosterDebugEvent("Auras.lua(visibility):GROUP_ROSTER_UPDATE") end
    end
    -- Debounced update — first event arms the timer, subsequent events within
    -- the window are ignored; the single callback fires once Blizzard has settled
    if not blizzVisibilityPending then
        blizzVisibilityPending = true
        C_Timer.After(0.3, function()
            blizzVisibilityPending = false
            if DF.UpdateBlizzardFrameVisibility then
                DF:UpdateBlizzardFrameVisibility()
            end
        end)
    end
    
    -- For target changes, also do an immediate check to hide selection highlights
    if event == "PLAYER_TARGET_CHANGED" then
        local db = DF.GetDB and DF:GetDB()
        local raidDb = DF.GetRaidDB and DF:GetRaidDB()
        local hideParty = db and db.hideBlizzardPartyFrames
        local hideRaid = raidDb and raidDb.hideBlizzardRaidFrames
        
        if hideParty or hideRaid then
            -- Hide selection highlights on all Blizzard frames
            local function HideSelectionHighlight(frame)
                if frame then
                    if frame.selectionHighlight and frame.selectionHighlight.SetShown then
                        frame.selectionHighlight:SetShown(false)
                    end
                    if frame.selectionIndicator and frame.selectionIndicator.SetShown then
                        frame.selectionIndicator:SetShown(false)
                    end
                end
            end
            
            if hideParty then
                for i = 1, 5 do
                    HideSelectionHighlight(_G["CompactPartyFrameMember" .. i])
                end
            end
            if hideRaid then
                for i = 1, 40 do
                    HideSelectionHighlight(_G["CompactRaidFrame" .. i])
                end
                for group = 1, 8 do
                    for member = 1, 5 do
                        HideSelectionHighlight(_G["CompactRaidGroup" .. group .. "Member" .. member])
                    end
                end
            end
        end
    end
end)

-- Hook Blizzard's selection highlight function to hide it when our option is enabled
if CompactUnitFrame_UpdateSelectionHighlight then
    hooksecurefunc("CompactUnitFrame_UpdateSelectionHighlight", function(frame)
        local db = DF.GetDB and DF:GetDB()
        local raidDb = DF.GetRaidDB and DF:GetRaidDB()
        
        -- Only affect party/raid frames, not nameplates
        local unit = frame.unit or frame.displayedUnit
        if unit then
            local isParty = unit:match("^party") or unit == "player"
            local isRaid = unit:match("^raid")
            
            local shouldHide = false
            if isParty and db and db.hideBlizzardPartyFrames then
                shouldHide = true
            elseif isRaid and raidDb and raidDb.hideBlizzardRaidFrames then
                shouldHide = true
            end
            
            if shouldHide and frame.selectionHighlight and frame.selectionHighlight.SetShown then
                frame.selectionHighlight:SetShown(false)
            end
        end
    end)
end

-- Slash command
DF:RegisterDebugSlash("DFAURAS", "Aura filtering / pipeline state dump", false, "/dfauras")
SlashCmdList["DFAURAS"] = function(msg)
    if msg == "scan" then
        -- Re-scan aura data for all roster units, then refresh our frames
        if DF.DirectScanAllUnits then DF:DirectScanAllUnits() end
        if DF.UpdateAllFrames then DF:UpdateAllFrames() end
        print("|cff00ff00DandersFrames:|r Rescanned auras for all units")
    elseif msg == "hideparty" then
        local db = DF:GetDB()
        db.hideBlizzardPartyFrames = not db.hideBlizzardPartyFrames
        DF:UpdateBlizzardFrameVisibility()
        print("|cff00ff00DandersFrames:|r Blizzard party frames " .. (db.hideBlizzardPartyFrames and "hidden" or "visible"))
    elseif msg == "hideraid" then
        local raidDb = DF:GetRaidDB()
        raidDb.hideBlizzardRaidFrames = not raidDb.hideBlizzardRaidFrames
        DF:UpdateBlizzardFrameVisibility()
        print("|cff00ff00DandersFrames:|r Blizzard raid frames " .. (raidDb.hideBlizzardRaidFrames and "hidden" or "visible"))
    elseif msg == "hideblizz" or msg == "hide" then
        -- Toggle both for convenience
        local db = DF:GetDB()
        local raidDb = DF:GetRaidDB()
        local newState = not (db.hideBlizzardPartyFrames or raidDb.hideBlizzardRaidFrames)
        db.hideBlizzardPartyFrames = newState
        raidDb.hideBlizzardRaidFrames = newState
        DF:UpdateBlizzardFrameVisibility()
        print("|cff00ff00DandersFrames:|r Blizzard frames " .. (newState and "hidden" or "visible"))
    elseif msg == "sidemenu" then
        -- Debug: list potential side menu frames
        print("|cff00ff00DandersFrames:|r Searching for side menu frames...")
        local framesToCheck = {
            "CompactPartyFrame",
            "CompactPartyFrameTitle",
            "CompactPartyFrameBorderFrame", 
            "PartyFrame",
            "CompactRaidFrameManager",
            "CompactRaidFrameManagerDisplayFrame",
            "CompactRaidFrameManagerContainerResizeFrame",
        }
        for _, name in ipairs(framesToCheck) do
            local frame = _G[name]
            if frame then
                print("  Found: " .. name .. " (shown: " .. tostring(frame:IsShown()) .. ", alpha: " .. tostring(frame:GetAlpha()) .. ")")
                -- List children
                if frame.GetChildren then
                    for i, child in ipairs({frame:GetChildren()}) do
                        local childName = child:GetName() or ("unnamed_" .. i)
                        if child:IsShown() then
                            print("    Child: " .. childName .. " (alpha: " .. tostring(child:GetAlpha()) .. ")")
                        end
                    end
                end
            end
        end
        -- Also check for any visible frame with "party" in name at UIParent level
        print("  Checking UIParent children for party-related frames...")
        for i, child in ipairs({UIParent:GetChildren()}) do
            local name = child:GetName()
            if name and (name:lower():find("party") or name:lower():find("compact")) and child:IsShown() then
                print("    UIParent child: " .. name .. " (alpha: " .. tostring(child:GetAlpha()) .. ")")
            end
        end
    else
        DF:DebugAuraFiltering()
    end
end

-- ============================================================
-- LIVE DEBUFF DEBUG MODE
-- Prints Blizzard's internal debuff/dispel data in real-time
-- Usage: /dfauras debuglive
-- ============================================================

DF.debugLiveAuras = false

local function PrintBlizzardFrameData(frame, frameName)
    if not frame then return end
    
    local unit = frame.unit
    if not unit then return end
    
    print("|cff00ccff[" .. frameName .. "]|r Unit: " .. unit)
    
    -- Check debuffs container
    if frame.debuffs and frame.debuffs.Size then
        local count = frame.debuffs:Size()
        print("  |cffff8800debuffs container:|r Size = " .. count)
        if count > 0 and frame.debuffs.Iterate then
            pcall(function()
                for aura in frame.debuffs:Iterate() do
                    local dispelInfo = ""
                    if aura.dispelName then
                        dispelInfo = "|cff00ff00" .. aura.dispelName .. "|r"
                    else
                        dispelInfo = "|cffff0000NOT DISPELLABLE|r"
                    end
                    print("    - " .. (aura.name or "?") .. " | ID: " .. tostring(aura.auraInstanceID) .. " | dispelName: " .. dispelInfo .. " | dispelType: " .. tostring(aura.dispelType or "nil"))
                end
            end)
        end
    else
        print("  |cffff0000debuffs container: NOT FOUND|r")
    end
    
    -- Check buffs container (for comparison)
    if frame.buffs and frame.buffs.Size then
        local count = frame.buffs:Size()
        print("  |cff88ff88buffs container:|r Size = " .. count)
    end
    
    -- Check bigDefensives container
    if frame.bigDefensives and frame.bigDefensives.Size then
        local count = frame.bigDefensives:Size()
        print("  |cffff00ffbigDefensives container:|r Size = " .. count)
        if count > 0 and frame.bigDefensives.Iterate then
            pcall(function()
                for aura in frame.bigDefensives:Iterate() do
                    print("    - " .. (aura.name or "?") .. " | ID: " .. tostring(aura.auraInstanceID))
                end
            end)
        end
    end
    
    -- Check for private auras
    if frame.privateAuraSize and frame.privateAuraSize > 0 then
        print("  |cffff00ffPrivate Auras:|r " .. frame.privateAuraSize .. " (hidden from addons)")
    end
    if frame.PrivateAuraAnchors then
        local anchorCount = 0
        for _ in pairs(frame.PrivateAuraAnchors) do anchorCount = anchorCount + 1 end
        if anchorCount > 0 then
            print("  |cffff00ffPrivateAuraAnchors:|r " .. anchorCount .. " anchors")
        end
    end
    
    -- Check dispels container (by type)
    if frame.dispels then
        local hasAny = false
        for dispelType, container in pairs(frame.dispels) do
            if type(container) == "table" and container.Size and container:Size() > 0 then
                hasAny = true
                break
            end
        end
        if hasAny then
            print("  |cff00ff00dispels container:|r (YOUR class can dispel these)")
            for dispelType, container in pairs(frame.dispels) do
                if type(container) == "table" and container.Size then
                    local count = container:Size()
                    if count > 0 then
                        print("    |cff00ff00" .. dispelType .. ":|r " .. count .. " auras")
                        if container.Iterate then
                            pcall(function()
                                for aura in container:Iterate() do
                                    print("      - " .. (aura.name or "?") .. " | ID: " .. tostring(aura.auraInstanceID))
                                end
                            end)
                        end
                    end
                end
            end
        else
            print("  |cffffff00dispels container:|r (empty - no debuffs YOUR class can dispel)")
        end
    else
        print("  |cffff0000dispels container: NOT FOUND|r")
    end
    
    -- Check old-style debuffFrames (what we currently use)
    if frame.debuffFrames then
        local shownCount = 0
        local totalCount = #frame.debuffFrames
        local shownDetails = {}
        for i, df in ipairs(frame.debuffFrames) do
            if df:IsShown() and df.auraInstanceID then
                shownCount = shownCount + 1
                table.insert(shownDetails, tostring(df.auraInstanceID))
            end
        end
        print("  |cffffff00debuffFrames (UI):|r " .. shownCount .. "/" .. totalCount .. " shown with auraInstanceID")
        if shownCount > 0 then
            print("    IDs: " .. table.concat(shownDetails, ", "))
        end
    end
    
    -- Check dispelDebuffFrames
    if frame.dispelDebuffFrames then
        local shownCount = 0
        local totalCount = #frame.dispelDebuffFrames
        local shownDetails = {}
        for i, df in ipairs(frame.dispelDebuffFrames) do
            if df:IsShown() and df.auraInstanceID then
                shownCount = shownCount + 1
                table.insert(shownDetails, tostring(df.auraInstanceID))
            end
        end
        print("  |cffffff00dispelDebuffFrames (UI):|r " .. shownCount .. "/" .. totalCount .. " shown with auraInstanceID")
        if shownCount > 0 then
            print("    IDs: " .. table.concat(shownDetails, ", "))
        end
    end
    
    -- NEW: Check for any other aura-related containers we might have missed
    -- Look for anything with "boss", "debuff", "aura" in the name that's a table with Size method
    local checkedKeys = {debuffs=true, buffs=true, dispels=true, bigDefensives=true, debuffFrames=true, dispelDebuffFrames=true, buffFrames=true, PrivateAuraAnchors=true}
    local foundOther = false
    for key, value in pairs(frame) do
        if type(key) == "string" and type(value) == "table" and not checkedKeys[key] then
            local keyLower = key:lower()
            if keyLower:find("boss") or keyLower:find("aura") or keyLower:find("debuff") then
                if value.Size and type(value.Size) == "function" then
                    local count = 0
                    pcall(function() count = value:Size() end)
                    if count > 0 then
                        if not foundOther then
                            print("  |cffff00ff=== OTHER CONTAINERS ===|r")
                            foundOther = true
                        end
                        print("    |cffff00ff" .. key .. ":|r Size = " .. count)
                        if value.Iterate then
                            pcall(function()
                                for aura in value:Iterate() do
                                    print("      - " .. (aura.name or "?") .. " | ID: " .. tostring(aura.auraInstanceID or "?"))
                                end
                            end)
                        end
                    end
                end
            end
        end
    end
    
    -- Also check raw API for what debuffs the unit actually has
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local hasHarmful = false
        for i = 1, 10 do
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
            if aura then
                if not hasHarmful then
                    print("  |cffff5500=== RAW API HARMFUL AURAS ===|r")
                    hasHarmful = true
                end
                local dispelInfo = aura.dispelName and ("|cff00ff00" .. aura.dispelName .. "|r") or "|cffff0000none|r"
                local bossInfo = ""
                pcall(function()
                    if aura.isBossAura then bossInfo = " |cffff0000[BOSS]|r" end
                end)
                print("    [" .. i .. "] " .. (aura.name or "?") .. " | ID: " .. tostring(aura.auraInstanceID) .. " | dispel: " .. dispelInfo .. bossInfo)
            else
                break
            end
        end
        if not hasHarmful then
            print("  |cffffff00RAW API: No HARMFUL auras on " .. unit .. "|r")
        end
    end
    
    print("")
end

local function DebugAllBlizzardFrames()
    print("|cff00ff00=== BLIZZARD FRAME DEBUFF DEBUG ===|r")
    print("")
    
    -- Party frames
    for i = 1, 5 do
        local frame = _G["CompactPartyFrameMember" .. i]
        if frame and frame.unit then
            PrintBlizzardFrameData(frame, "CompactPartyFrameMember" .. i)
        end
    end
    
    -- Raid frames (just first 10 to avoid spam)
    for i = 1, 10 do
        local frame = _G["CompactRaidFrame" .. i]
        if frame and frame.unit then
            PrintBlizzardFrameData(frame, "CompactRaidFrame" .. i)
        end
    end
    
    print("|cff00ff00=== END DEBUG ===|r")
end

-- Hook for live monitoring
local debugHookInstalled = false
local function InstallDebugHook()
    if debugHookInstalled then return end
    
    if CompactUnitFrame_UpdateAuras then
        hooksecurefunc("CompactUnitFrame_UpdateAuras", function(frame)
            if not DF.debugLiveAuras then return end
            if not frame or not frame.unit then return end
            
            -- PERFORMANCE FIX 2025-01-20: Check for nameplate BEFORE calling GetName()
            -- Nameplates can error on GetName() - check unit string first
            local unit = frame.unit
            if unit and type(unit) == "string" and unit:find("nameplate") then
                return
            end
            local displayedUnit = frame.displayedUnit
            if displayedUnit and type(displayedUnit) == "string" and displayedUnit:find("nameplate") then
                return
            end
            
            -- Now safe to call GetName
            local name = frame:GetName()
            if not name then return end
            if name:find("NamePlate") then return end
            
            PrintBlizzardFrameData(frame, name)
        end)
        debugHookInstalled = true
        print("|cff00ff00DandersFrames:|r Debug hook installed")
    end
end

-- Slash command handler for debug
DF:RegisterDebugSlash("DFAURASDEBUG", "Aura debug logging toggle", false, "/dfaurasdebug")
SlashCmdList["DFAURASDEBUG"] = function(msg)
    msg = msg:lower():trim()
    
    if msg == "live" or msg == "on" then
        DF.debugLiveAuras = true
        InstallDebugHook()
        print("|cff00ff00DandersFrames:|r Live aura debug ENABLED - debuff data will print when auras change")
    elseif msg == "off" then
        DF.debugLiveAuras = false
        print("|cff00ff00DandersFrames:|r Live aura debug DISABLED")
    elseif msg == "now" or msg == "snap" or msg == "snapshot" then
        DebugAllBlizzardFrames()
    else
        print("|cff00ccffDandersFrames Aura Debug Commands:|r")
        print("  /dfaurasdebug live - Enable live monitoring (prints on every aura update)")
        print("  /dfaurasdebug off - Disable live monitoring")
        print("  /dfaurasdebug now - Print current snapshot of all Blizzard frame data")
    end
end

-- ============================================================
-- DEFENSIVE / BUFF DEDUPLICATION DEBUG
-- Dumps auraInstanceIDs from both caches to check for overlap
-- Usage: /dfdefdup
-- ============================================================

DF:RegisterDebugSlash("DFDEFDUP", "Defensive bar dedup state dump", false, "/dfdefdup")
SlashCmdList["DFDEFDUP"] = function()
    local issecret = issecretvalue or function() return false end
    local header = "|cff00ff00DandersFrames|r |cff00ccff[Defensive/Buff Dedup Debug]|r"
    print(header)

    local anyUnit = false
    for unit, cache in pairs(DF.BlizzardAuraCache) do
        if cache and (next(cache.defensives) or next(cache.buffs)) then
            anyUnit = true
            local unitName = UnitName(unit) or unit
            print("|cffffcc00--- " .. unit .. " (" .. unitName .. ") ---|r")

            -- Defensive IDs
            local defCount = 0
            local defIDs = {}
            for id in pairs(cache.defensives) do
                defCount = defCount + 1
                local isSecret = issecret(id)
                defIDs[defCount] = { id = id, secret = isSecret }
            end

            if defCount > 0 then
                print("  |cff00ff00Defensives (" .. defCount .. "):|r")
                for i, entry in ipairs(defIDs) do
                    if entry.secret then
                        print("    [" .. i .. "] SECRET (cannot read)")
                    else
                        -- Try to get aura data for extra info
                        local info = ""
                        local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, entry.id)
                        if ok and data then
                            local iconStr = data.icon
                            if iconStr and not issecret(iconStr) then
                                info = " icon=" .. tostring(iconStr)
                            end
                            local nameStr = data.name
                            if nameStr and not issecret(nameStr) then
                                info = info .. " name=" .. tostring(nameStr)
                            end
                            local spellStr = data.spellId
                            if spellStr and not issecret(spellStr) then
                                info = info .. " spellId=" .. tostring(spellStr)
                            end
                        end
                        print("    [" .. i .. "] ID=" .. tostring(entry.id) .. info)
                    end
                end
            else
                print("  |cff888888Defensives: (none)|r")
            end

            -- Buff IDs
            local buffCount = #(cache.buffOrder or {})
            if buffCount > 0 then
                print("  |cff3399ffBuffs (" .. buffCount .. "):|r")
                for i, id in ipairs(cache.buffOrder) do
                    local isSecret = issecret(id)
                    if isSecret then
                        print("    [" .. i .. "] SECRET (cannot read)")
                    else
                        local info = ""
                        local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, id)
                        if ok and data then
                            local iconStr = data.icon
                            if iconStr and not issecret(iconStr) then
                                info = " icon=" .. tostring(iconStr)
                            end
                            local nameStr = data.name
                            if nameStr and not issecret(nameStr) then
                                info = info .. " name=" .. tostring(nameStr)
                            end
                            local spellStr = data.spellId
                            if spellStr and not issecret(spellStr) then
                                info = info .. " spellId=" .. tostring(spellStr)
                            end
                        end
                        print("    [" .. i .. "] ID=" .. tostring(id) .. info)
                    end
                end
            else
                print("  |cff888888Buffs: (none)|r")
            end

            -- Check for overlaps
            local overlapCount = 0
            local overlaps = {}
            for id in pairs(cache.defensives) do
                if not issecret(id) and cache.buffs[id] then
                    overlapCount = overlapCount + 1
                    overlaps[overlapCount] = id
                end
            end

            if overlapCount > 0 then
                print("  |cffff3333DUPLICATES FOUND (" .. overlapCount .. "):|r")
                for i, id in ipairs(overlaps) do
                    local info = ""
                    local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, id)
                    if ok and data then
                        local nameStr = data.name
                        if nameStr and not issecret(nameStr) then
                            info = " name=" .. tostring(nameStr)
                        end
                    end
                    print("    |cffff3333" .. tostring(id) .. info .. "|r")
                end
            else
                print("  |cff00ff00No duplicates between defensive and buff caches|r")
            end
        end
    end

    if not anyUnit then
        print("  |cffff8800No cached aura data found. Are you in a group?|r")
    end
end

-- ============================================================
-- FIX A DEV COMMAND: manually trigger a full scan + dump the cache
-- Usage: /dfscan <unit>
--   e.g. /dfscan player
--   e.g. /dfscan party1
-- ============================================================

DF:RegisterDebugSlash("DFSCAN", "Direct aura scan state / rescan", false, "/dfscan")
SlashCmdList["DFSCAN"] = function(msg)
    msg = msg and msg:match("^%s*(.-)%s*$") or ""

    -- /dfscan stats       — print the scan counter breakdown
    -- /dfscan reset       — reset the scan counters to zero
    -- /dfscan <unit>      — run ScanUnitFull on <unit> and dump the cache entry
    if msg == "stats" or msg == "" then
        local s = DF.AuraCacheStats
        print("|cff00ff00DandersFrames|r |cff00ccff[AuraCache Stats]|r")
        print(string.format("  events seen:     %d", s.eventsSeen))
        print(string.format("  scanFull:        %d", s.scanFull))
        print(string.format("  deltaApplied:    %d", s.deltaApplied))
        print(string.format("  deltaFallback:   %d", s.deltaFallback))
        if s.eventsSeen > 0 then
            local deltaPct = (s.deltaApplied / s.eventsSeen) * 100
            print(string.format("  delta hit rate:  %.1f%% (higher = better)", deltaPct))
        end
        print("  |cffaaaaaaTip: /dfscan reset to zero the counters, then do a sustained combat test|r")
        print("  |cffaaaaaaUsage: /dfscan <unit> to dump the cache entry for a unit|r")
        return
    end

    if msg == "reset" then
        DF.AuraCacheStats:Reset()
        print("|cff00ff00DandersFrames|r AuraCache counters reset.")
        return
    end

    local unit = msg
    local header = "|cff00ff00DandersFrames|r |cff00ccff[Fix A ScanUnitFull]|r " .. unit
    print(header)

    if not UnitExists(unit) then
        print("  |cffff8800Unit does not exist|r")
        return
    end

    -- Trigger a full scan
    DF:ScanUnitFull(unit)

    local cache = DF.AuraCache[unit]
    if not cache then
        print("  |cffff8800No cache entry after scan|r")
        return
    end

    print(string.format("  hasFullScan = %s, buffOrderDirty = %s, debuffOrderDirty = %s",
        tostring(cache.hasFullScan), tostring(cache.buffOrderDirty), tostring(cache.debuffOrderDirty)))

    local function countKeys(t)
        local n = 0
        if t then for _ in pairs(t) do n = n + 1 end end
        return n
    end

    print(string.format("  buffsByID: %d entries", countKeys(cache.buffsByID)))
    print(string.format("  debuffsByID: %d entries", countKeys(cache.debuffsByID)))
    print(string.format("  classification sets: buffs=%d defensives=%d debuffs=%d playerDispellable=%d allDispellable=%d",
        countKeys(cache.buffs), countKeys(cache.defensives),
        countKeys(cache.debuffs), countKeys(cache.playerDispellable), countKeys(cache.allDispellable)))

    -- Dump a few sample aura names if non-secret
    local issecret = issecretvalue or function() return false end
    local shown = 0
    for id, auraData in pairs(cache.buffsByID) do
        if shown >= 5 then break end
        local name = auraData.name
        if name and not issecret(name) then
            print(string.format("    buff[%s] = %s", tostring(id), tostring(name)))
            shown = shown + 1
        end
    end
    shown = 0
    for id, auraData in pairs(cache.debuffsByID) do
        if shown >= 5 then break end
        local name = auraData.name
        if name and not issecret(name) then
            print(string.format("    debuff[%s] = %s", tostring(id), tostring(name)))
            shown = shown + 1
        end
    end
end
