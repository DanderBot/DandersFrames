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

-- Track whether we've registered the HARF callback
local harfCallbackRegistered = false

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

local function prioritySort(a, b)
    return a.priority > b.priority  -- Higher priority first (wins conflicts)
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
-- HARF CALLBACK REGISTRATION
-- Register for HARF_UNIT_AURA callbacks so the engine runs
-- with fresh data directly from HARF — not stale data from
-- the CompactUnitFrame_UpdateAuras hook (which fires BEFORE
-- HARF processes the event due to frame creation order).
-- ============================================================

local function RegisterHARFCallback()
    if harfCallbackRegistered then return end
    if not Adapter then
        Adapter = DF.AuraDesigner.Adapter
    end
    if not Adapter then return end

    -- Only register if the Harrek provider is active
    local sourceName = Adapter:GetSourceName()
    if not sourceName or not sourceName:find("Harrek") then return end

    Adapter:RegisterCallback("AuraDesignerEngine", function(unit)
        if not unit then return end

        -- Find all DF frames showing this unit and update them
        local function UpdateFrameForUnit(frame)
            if not frame or not frame:IsVisible() then return end
            if not frame.unit or frame.unit ~= unit then return end
            if not DF:IsAuraDesignerEnabled(frame) then return end
            Engine:UpdateFrame(frame)
        end

        -- Check unitFrameMap first (fast path)
        local ourFrame = DF.unitFrameMap and DF.unitFrameMap[unit]
        if ourFrame then
            UpdateFrameForUnit(ourFrame)
        else
            -- Fallback: iterate frames
            if DF.IteratePartyFrames then
                DF:IteratePartyFrames(function(f)
                    if f and f.unit == unit then
                        UpdateFrameForUnit(f)
                    end
                end)
            end
            if DF.IterateRaidFrames then
                DF:IterateRaidFrames(function(f)
                    if f and f.unit == unit then
                        UpdateFrameForUnit(f)
                    end
                end)
            end
        end

        -- Also update pinned frames for this unit
        if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
            for setIndex = 1, 2 do
                local header = DF.PinnedFrames.headers[setIndex]
                if header and header:IsShown() then
                    for i = 1, 40 do
                        local child = header:GetAttribute("child" .. i)
                        if child and child:IsVisible() and child.unit == unit then
                            UpdateFrameForUnit(child)
                        end
                    end
                end
            end
        end
    end)

    harfCallbackRegistered = true
    DF:Debug("AD", "Registered HARF_UNIT_AURA callback for fresh data updates")
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

    -- Register HARF callback once (ensures fresh data updates)
    if not harfCallbackRegistered then
        RegisterHARFCallback()
    end

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

    -- Debug: throttled diagnostic dump
    local now = GetTime()
    local shouldLog = (now - debugLastLog) >= DEBUG_INTERVAL

    -- Query adapter for active auras on this unit
    local activeAuras = Adapter:GetUnitAuras(unit, spec)

    if shouldLog then
        debugLastLog = now
        -- Count active auras from adapter
        local activeCount = 0
        for k in pairs(activeAuras) do activeCount = activeCount + 1 end
        -- Count configured auras and indicators
        local configCount = 0
        local configIndicators = 0
        if adDB.auras then
            for auraName, auraCfg in pairs(adDB.auras) do
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
        if adDB.auras then
            for auraName, auraCfg in pairs(adDB.auras) do
                local types = {}
                if auraCfg.indicators then
                    for _, ind in ipairs(auraCfg.indicators) do
                        types[#types+1] = ind.type .. "#" .. ind.id
                    end
                end
                for _, typeDef in ipairs(FRAME_LEVEL_TYPES) do
                    if auraCfg[typeDef.key] then types[#types+1] = typeDef.key end
                end
                DF:Debug("AD", "  config: %s -> %s", auraName, #types > 0 and table.concat(types, ", ") or "(no indicators)")
            end
        end
    end

    -- Gather configured auras that are currently active
    wipe(activeIndicators)
    local auras = adDB.auras
    if auras then
        for auraName, auraCfg in pairs(auras) do
            local auraData = activeAuras[auraName]
            if auraData then
                local priority = auraCfg.priority or 5

                -- Placed indicators from instances array
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

                -- Frame-level indicators (unchanged keys)
                for _, typeDef in ipairs(FRAME_LEVEL_TYPES) do
                    local typeCfg = auraCfg[typeDef.key]
                    if typeCfg then
                        tinsert(activeIndicators, {
                            auraName = auraName,
                            typeKey  = typeDef.key,
                            placed   = false,
                            config   = typeCfg,
                            auraData = auraData,
                            priority = priority,
                        })
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

    -- Dispatch to indicator renderers
    Indicators:BeginFrame(frame)

    for _, ind in ipairs(activeIndicators) do
        -- Placed indicators use instanceKey (e.g., "Rejuvenation#1") for pool lookup
        -- Frame-level indicators use auraName
        local key = ind.placed and ind.instanceKey or ind.auraName
        Indicators:Apply(frame, ind.typeKey, ind.config, ind.auraData, adDB.defaults, key, ind.priority)
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
end
