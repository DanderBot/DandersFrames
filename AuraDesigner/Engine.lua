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
        -- Count configured auras and indicator types
        local configCount = 0
        local configTypes = 0
        if adDB.auras then
            for auraName, auraCfg in pairs(adDB.auras) do
                configCount = configCount + 1
                for _, typeDef in ipairs(INDICATOR_TYPES) do
                    if auraCfg[typeDef.key] then configTypes = configTypes + 1 end
                end
            end
        end
        local providerName = Adapter:GetSourceName() or "none"
        DF:Debug("AD", "Engine: unit=%s spec=%s provider=%s active=%d configured=%d types=%d", unit, tostring(spec), providerName, activeCount, configCount, configTypes)
        -- Log active aura names
        for auraName in pairs(activeAuras) do
            DF:Debug("AD", "  active: %s", auraName)
        end
        -- Log configured aura names and their indicator types
        if adDB.auras then
            for auraName, auraCfg in pairs(adDB.auras) do
                local types = {}
                for _, typeDef in ipairs(INDICATOR_TYPES) do
                    if auraCfg[typeDef.key] then types[#types+1] = typeDef.key end
                end
                DF:Debug("AD", "  config: %s -> %s", auraName, #types > 0 and table.concat(types, ", ") or "(no types)")
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
                for _, typeDef in ipairs(INDICATOR_TYPES) do
                    local typeCfg = auraCfg[typeDef.key]
                    if typeCfg then
                        tinsert(activeIndicators, {
                            auraName = auraName,
                            typeKey  = typeDef.key,
                            placed   = typeDef.placed,
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

    if shouldLog and #activeIndicators > 0 then
        DF:Debug("AD", "Dispatching %d indicators for %s", #activeIndicators, unit)
    end

    -- Dispatch to indicator renderers
    Indicators:BeginFrame(frame)

    for _, ind in ipairs(activeIndicators) do
        Indicators:Apply(frame, ind.typeKey, ind.config, ind.auraData, adDB.defaults, ind.auraName, ind.priority)
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
