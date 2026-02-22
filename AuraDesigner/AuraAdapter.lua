local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - DATA SOURCE ADAPTER
-- Abstraction layer between the Aura Designer and the aura data
-- source. This is the ONLY file that knows about the external
-- data provider (currently Harrek's Advanced Raid Frames).
--
-- Any future provider must implement:
--   :IsAvailable()              → boolean
--   :GetSourceName()            → string
--   :GetUnitAuras(unit)         → { [auraName] = normalizedData }
--   :RegisterCallback(owner, cb)
--   :UnregisterCallback(owner)
--
-- Normalized aura data format:
--   {
--     spellId        = number,   -- spell ID
--     icon           = number,   -- texture ID
--     duration       = number,   -- total duration (0 = permanent)
--     expirationTime = number,   -- GetTime()-based expiry
--     stacks         = number,   -- stack/application count
--     caster         = string,   -- who applied it
--     auraInstanceID = number,   -- unique instance ID for C_UnitAuras API
--   }
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local GetTime = GetTime

DF.AuraDesigner = DF.AuraDesigner or {}

local AuraAdapter = {}
DF.AuraDesigner.Adapter = AuraAdapter

-- ============================================================
-- PROVIDER ABSTRACTION
-- The adapter auto-selects the best available provider:
--   1. Harrek's Advanced Raid Frames (if installed)
--   2. Fallback: direct C_UnitAuras scanning
-- ============================================================

local activeProvider = nil  -- Set during initialization

-- ============================================================
-- HARREK'S PROVIDER
-- Uses AdvancedRaidFramesAPI for fast aura presence checks,
-- then enriches with C_UnitAuras for duration/stacks/icon.
-- ============================================================

local HarrekProvider = {}

function HarrekProvider:IsAvailable()
    return AdvancedRaidFramesAPI ~= nil
end

function HarrekProvider:GetSourceName()
    return "Harrek's Advanced Raid Frames"
end

function HarrekProvider:GetUnitAuras(unit, spec)
    local API = AdvancedRaidFramesAPI
    if not API then return {} end

    local spellIDs = DF.AuraDesigner.SpellIDs[spec]
    if not spellIDs then return {} end

    local result = {}
    for _, auraInfo in ipairs(DF.AuraDesigner.TrackableAuras[spec] or {}) do
        local auraName = auraInfo.name
        -- HARF tracks this aura — check if it's active on the unit
        local harfData = API.GetUnitAura(unit, auraName)
        if harfData then
            -- Aura is active — enrich with C_UnitAuras data
            local spellId = spellIDs[auraName]
            local entry = {
                spellId = spellId,
                icon = nil,
                duration = 0,
                expirationTime = 0,
                stacks = 0,
                caster = nil,
            }
            -- Enrich from Blizzard API using spellId
            if spellId then
                AuraUtil.ForEachAura(unit, "HELPFUL", nil, function(auraData)
                    if auraData.spellId == spellId then
                        entry.icon = auraData.icon
                        entry.duration = auraData.duration or 0
                        entry.expirationTime = auraData.expirationTime or 0
                        entry.stacks = auraData.applications or 0
                        entry.caster = auraData.sourceUnit
                        entry.auraInstanceID = auraData.auraInstanceID
                        return true  -- stop iteration
                    end
                end)
                -- Fallback icon from C_Spell if ForEachAura didn't find it
                if not entry.icon and C_Spell and C_Spell.GetSpellTexture then
                    entry.icon = C_Spell.GetSpellTexture(spellId)
                end
            end
            result[auraName] = entry
        end
    end

    return result
end

-- Callback registry for Harrek provider
local harrekCallbacks = {}

function HarrekProvider:RegisterCallback(owner, callback)
    harrekCallbacks[owner] = callback
    -- Wire to HARF's callback system
    if AdvancedRaidFramesAPI and AdvancedRaidFramesAPI.RegisterCallback then
        AdvancedRaidFramesAPI.RegisterCallback(owner, "HARF_UNIT_AURA", function(_, unit, auraData)
            if callback then callback(unit) end
        end)
    end
end

function HarrekProvider:UnregisterCallback(owner)
    harrekCallbacks[owner] = nil
    if AdvancedRaidFramesAPI and AdvancedRaidFramesAPI.UnregisterCallback then
        AdvancedRaidFramesAPI.UnregisterCallback(owner, "HARF_UNIT_AURA")
    end
end

-- ============================================================
-- FALLBACK PROVIDER
-- Scans unit buffs directly via C_UnitAuras when HARF is not
-- installed. Slower but fully functional.
-- ============================================================

local FallbackProvider = {}

function FallbackProvider:IsAvailable()
    return true  -- Always available
end

function FallbackProvider:GetSourceName()
    return "Built-in (direct scan)"
end

-- Build a reverse lookup: spellId → auraName for fast matching
local spellIdLookup = {}  -- { [spec] = { [spellId] = auraName } }

local function GetSpellIdLookup(spec)
    if spellIdLookup[spec] then return spellIdLookup[spec] end
    local lookup = {}
    local ids = DF.AuraDesigner.SpellIDs[spec]
    if ids then
        for auraName, spellId in pairs(ids) do
            lookup[spellId] = auraName
        end
    end
    spellIdLookup[spec] = lookup
    return lookup
end

-- Debug throttle for adapter (shares interval with engine)
local adapterDebugLast = 0
local ADAPTER_DEBUG_INTERVAL = 3

function FallbackProvider:GetUnitAuras(unit, spec)
    local lookup = GetSpellIdLookup(spec)
    if not lookup or not next(lookup) then return {} end

    local now = GetTime()
    local shouldLog = (now - adapterDebugLast) >= ADAPTER_DEBUG_INTERVAL

    -- Count lookup entries for debug
    local lookupSize = 0
    if shouldLog then
        for _ in pairs(lookup) do lookupSize = lookupSize + 1 end
    end

    local result = {}
    local scannedCount = 0

    -- Try C_UnitAuras index-based scan (more reliable in modern WoW)
    local i = 1
    while true do
        local auraData = C_UnitAuras.GetBuffDataByIndex(unit, i)
        if not auraData then break end
        scannedCount = scannedCount + 1
        local auraName = lookup[auraData.spellId]
        if auraName then
            result[auraName] = {
                spellId = auraData.spellId,
                icon = auraData.icon,
                duration = auraData.duration or 0,
                expirationTime = auraData.expirationTime or 0,
                stacks = auraData.applications or 0,
                caster = auraData.sourceUnit,
                auraInstanceID = auraData.auraInstanceID,
            }
        end
        i = i + 1
    end

    if shouldLog then
        adapterDebugLast = now
        local foundCount = 0
        for _ in pairs(result) do foundCount = foundCount + 1 end
        DF:Debug("AD", "Fallback scan: unit=%s spec=%s lookup=%d scanned=%d found=%d", unit, spec, lookupSize, scannedCount, foundCount)
        -- Log first few scanned spellIds for verification
        local j = 1
        while j <= 5 do
            local ad = C_UnitAuras.GetBuffDataByIndex(unit, j)
            if not ad then break end
            local match = lookup[ad.spellId] and " MATCH" or ""
            DF:Debug("AD", "  buff[%d]: spellId=%d name=%s%s", j, ad.spellId, ad.name or "?", match)
            j = j + 1
        end
    end

    return result
end

-- Fallback uses a simple event frame for UNIT_AURA
local fallbackCallbacks = {}
local fallbackEventFrame

function FallbackProvider:RegisterCallback(owner, callback)
    fallbackCallbacks[owner] = callback
    if not fallbackEventFrame then
        fallbackEventFrame = CreateFrame("Frame")
        fallbackEventFrame:RegisterEvent("UNIT_AURA")
        fallbackEventFrame:SetScript("OnEvent", function(_, _, unit)
            for _, cb in pairs(fallbackCallbacks) do
                cb(unit)
            end
        end)
    end
end

function FallbackProvider:UnregisterCallback(owner)
    fallbackCallbacks[owner] = nil
    -- Clean up event frame if no callbacks remain
    if fallbackEventFrame and not next(fallbackCallbacks) then
        fallbackEventFrame:UnregisterAllEvents()
        fallbackEventFrame = nil
    end
end

-- ============================================================
-- PROVIDER SELECTION
-- ============================================================

local function SelectProvider()
    if HarrekProvider:IsAvailable() then
        activeProvider = HarrekProvider
    else
        activeProvider = FallbackProvider
    end
end

-- ============================================================
-- PUBLIC ADAPTER API
-- These methods delegate to the active provider.
-- ============================================================

-- Returns true if a data source is available
function AuraAdapter:IsAvailable()
    if not activeProvider then SelectProvider() end
    return activeProvider:IsAvailable()
end

-- Returns a display name for the current data source
function AuraAdapter:GetSourceName()
    if not activeProvider then SelectProvider() end
    return activeProvider:GetSourceName()
end

-- ============================================================
-- SPEC / AURA QUERIES (uses local Config data)
-- These are provider-independent — always sourced from
-- DF.AuraDesigner tables in Config.lua.
-- ============================================================

-- Returns a list of supported spec keys
function AuraAdapter:GetSupportedSpecs()
    local specs = {}
    for spec in pairs(DF.AuraDesigner.SpecInfo) do
        specs[#specs + 1] = spec
    end
    return specs
end

-- Returns the display name for a spec key
function AuraAdapter:GetSpecDisplayName(specKey)
    local info = DF.AuraDesigner.SpecInfo[specKey]
    return info and info.display or specKey
end

-- Returns the list of trackable auras for a spec
-- Each entry: { name = "InternalName", display = "Display Name", color = {r,g,b} }
function AuraAdapter:GetTrackableAuras(specKey)
    return DF.AuraDesigner.TrackableAuras[specKey] or {}
end

-- ============================================================
-- PLAYER SPEC DETECTION
-- ============================================================

-- Returns the spec key for the current player, or nil if not supported
function AuraAdapter:GetPlayerSpec()
    local _, englishClass = UnitClass("player")
    local specIndex = GetSpecialization and GetSpecialization() or nil
    if not englishClass or not specIndex then return nil end

    local key = englishClass .. "_" .. specIndex
    return DF.AuraDesigner.SpecMap[key]
end

-- ============================================================
-- RUNTIME DATA
-- Delegates to the active provider for live aura queries.
-- ============================================================

-- Returns a table of currently active tracked auras for a unit
-- Format: { [auraName] = { spellId, icon, duration, expirationTime, stacks, caster } }
function AuraAdapter:GetUnitAuras(unit, spec)
    if not activeProvider then SelectProvider() end
    if not spec then spec = self:GetPlayerSpec() end
    if not spec then return {} end
    return activeProvider:GetUnitAuras(unit, spec)
end

-- Registers a callback for when a unit's auras change
-- callback(unit) is called whenever unit auras may have changed
function AuraAdapter:RegisterCallback(owner, callback)
    if not activeProvider then SelectProvider() end
    activeProvider:RegisterCallback(owner, callback)
end

function AuraAdapter:UnregisterCallback(owner)
    if not activeProvider then SelectProvider() end
    activeProvider:UnregisterCallback(owner)
end

-- Force re-selection of provider (e.g., after addon load order settles)
function AuraAdapter:RefreshProvider()
    activeProvider = nil
    SelectProvider()
end

-- ============================================================
-- UTILITY
-- ============================================================

-- Check if Aura Designer is enabled for a frame
function DF:IsAuraDesignerEnabled(frame)
    local frameDB = frame and DF.GetFrameDB and DF:GetFrameDB(frame)
    if frameDB and frameDB.auraDesigner then
        return frameDB.auraDesigner.enabled
    end
    return false
end
