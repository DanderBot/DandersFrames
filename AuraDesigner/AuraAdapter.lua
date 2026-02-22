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
--     spellId        = number,   -- our known non-secret spell ID
--     icon           = number,   -- texture ID (may be secret in combat)
--     duration       = number,   -- total duration (may be secret in combat)
--     expirationTime = number,   -- GetTime()-based expiry (may be secret)
--     stacks         = number,   -- stack/application count (may be secret)
--     caster         = string,   -- who applied it
--     auraInstanceID = number,   -- unique instance ID for C_UnitAuras API
--   }
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local wipe = table.wipe
local GetTime = GetTime
local issecretvalue = issecretvalue or function() return false end
local GetAuraDataByAuraInstanceID = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID
local IsAuraFilteredOutByInstanceID = C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID

DF.AuraDesigner = DF.AuraDesigner or {}

local AuraAdapter = {}
DF.AuraDesigner.Adapter = AuraAdapter

-- ============================================================
-- PROVIDER ABSTRACTION
-- The adapter auto-selects the best available provider:
--   1. Harrek's Advanced Raid Frames (if installed)
--   2. Fallback: event-driven aura tracking with fingerprint ID
-- ============================================================

local activeProvider = nil  -- Set during initialization

-- ============================================================
-- HARREK'S PROVIDER
-- Uses AdvancedRaidFramesAPI which already handles secret-safe
-- aura identification internally. We just read its results.
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
        -- API.GetUnitAura returns C_UnitAuras.GetAuraDataByAuraInstanceID() data
        -- which already contains all fields (some may be secret in combat — that's OK)
        local harfData = API.GetUnitAura(unit, auraName)
        if harfData then
            result[auraName] = {
                spellId = spellIDs[auraName] or 0,  -- our known non-secret ID
                icon = harfData.icon,                 -- may be secret; OK for SetTexture
                duration = harfData.duration,          -- may be secret; OK for SetCooldownFromExpirationTime
                expirationTime = harfData.expirationTime,  -- may be secret
                stacks = harfData.applications,        -- may be secret; OK for GetAuraApplicationDisplayCount
                caster = harfData.sourceUnit,
                auraInstanceID = harfData.auraInstanceID,  -- always non-secret
            }
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
-- Event-driven aura tracking with secret-safe fingerprint
-- identification. Inspired by Harrek's Advanced Raid Frames.
--
-- Architecture:
--   1. Maintains persistent state: unitAuraState[unit][auraInstanceID] = auraName
--   2. Identifies auras using C_UnitAuras.IsAuraFilteredOutByInstanceID()
--      (returns non-secret boolean) + #aura.points (non-secret count)
--   3. On UNIT_AURA: uses addedAuras/removedAuraInstanceIDs for incremental updates
--   4. On full scan: uses C_UnitAuras.GetUnitAuras(unit, 'PLAYER|HELPFUL')
--   5. GetUnitAuras() reads current state + fetches display data via GetAuraDataByAuraInstanceID
-- ============================================================

local FallbackProvider = {}

function FallbackProvider:IsAvailable()
    return true  -- Always available
end

function FallbackProvider:GetSourceName()
    return "Built-in (Event-Driven)"
end

-- Persistent aura state per unit: { [unit] = { [auraInstanceID] = auraName } }
local unitAuraState = {}

-- Debug throttle for adapter
local adapterDebugLast = 0
local ADAPTER_DEBUG_INTERVAL = 3

-- ============================================================
-- FINGERPRINT IDENTIFICATION (secret-safe)
-- Uses C_UnitAuras.IsAuraFilteredOutByInstanceID() to check
-- multiple filter combinations, plus #aura.points for tooltip
-- point count. This creates a unique signature per aura type.
-- ============================================================

local function IdentifyAuraByFingerprint(unit, auraInstanceID, aura, spec)
    local fingerprints = DF.AuraDesigner.AuraFingerprints
    if not fingerprints then return nil end
    local specFP = fingerprints[spec]
    if not specFP then return nil end

    if not IsAuraFilteredOutByInstanceID then return nil end

    -- Build the fingerprint from the live aura
    local passesRaid = not IsAuraFilteredOutByInstanceID(unit, auraInstanceID, "PLAYER|HELPFUL|RAID")
    local passesRic  = not IsAuraFilteredOutByInstanceID(unit, auraInstanceID, "PLAYER|HELPFUL|RAID_IN_COMBAT")
    local passesExt  = not IsAuraFilteredOutByInstanceID(unit, auraInstanceID, "PLAYER|HELPFUL|EXTERNAL_DEFENSIVE")
    local passesDisp = not IsAuraFilteredOutByInstanceID(unit, auraInstanceID, "PLAYER|HELPFUL|RAID_PLAYER_DISPELLABLE")
    local pointCount = aura and aura.points and #aura.points or 0

    -- Match against known aura fingerprints
    for auraName, fp in pairs(specFP) do
        local matchesRaid = (fp.raid == passesRaid)
        local matchesRic  = (fp.ric == passesRic)
        local matchesExt  = (fp.ext == passesExt)
        local matchesDisp = (fp.disp == passesDisp)
        -- points = -1 means variable count (skip check)
        local matchesPoints = (fp.points == -1) or (fp.points == pointCount)

        if matchesRaid and matchesRic and matchesExt and matchesDisp and matchesPoints then
            return auraName
        end
    end

    return nil
end

-- ============================================================
-- FULL SCAN
-- Initializes or rebuilds the aura state for a unit.
-- Uses C_UnitAuras.GetUnitAuras() + fingerprint identification.
-- Also tries spellId lookup when not secret (out of combat).
-- ============================================================

local function FullScanUnit(unit, spec)
    if not unitAuraState[unit] then
        unitAuraState[unit] = {}
    end
    wipe(unitAuraState[unit])

    -- Build reverse lookup: spellId → auraName (for out-of-combat fast path)
    local spellIDs = DF.AuraDesigner.SpellIDs[spec]
    local reverseLookup = {}
    if spellIDs then
        for auraName, spellId in pairs(spellIDs) do
            reverseLookup[spellId] = auraName
        end
    end

    -- Scan all player-helpful auras
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuras then return end
    local ok, auras = pcall(C_UnitAuras.GetUnitAuras, unit, "PLAYER|HELPFUL")
    if not ok or not auras then return end

    for _, aura in ipairs(auras) do
        local auraInstanceID = aura.auraInstanceID
        if auraInstanceID then
            local auraName = nil

            -- Fast path: try spellId lookup (works out of combat)
            local sid = aura.spellId
            if sid and not issecretvalue(sid) then
                auraName = reverseLookup[sid]
            end

            -- Fallback: fingerprint identification (works in combat too)
            if not auraName then
                auraName = IdentifyAuraByFingerprint(unit, auraInstanceID, aura, spec)
            end

            if auraName then
                unitAuraState[unit][auraInstanceID] = auraName
            end
        end
    end
end

-- ============================================================
-- INCREMENTAL UPDATE
-- Called from UNIT_AURA event handler with updateInfo.
-- Processes addedAuras / removedAuraInstanceIDs / isFullUpdate.
-- ============================================================

local function ProcessUnitAuraUpdate(unit, updateInfo, spec)
    if not spec then return end
    if not unitAuraState[unit] then
        unitAuraState[unit] = {}
    end

    -- Full update: rescan everything
    if not updateInfo or updateInfo.isFullUpdate then
        FullScanUnit(unit, spec)
        return
    end

    -- Build reverse lookup for spellId fast path
    local spellIDs = DF.AuraDesigner.SpellIDs[spec]
    local reverseLookup = {}
    if spellIDs then
        for auraName, spellId in pairs(spellIDs) do
            reverseLookup[spellId] = auraName
        end
    end

    -- Process removed auras
    if updateInfo.removedAuraInstanceIDs then
        for _, auraId in ipairs(updateInfo.removedAuraInstanceIDs) do
            unitAuraState[unit][auraId] = nil
        end
    end

    -- Process added auras
    if updateInfo.addedAuras then
        for _, aura in ipairs(updateInfo.addedAuras) do
            local auraInstanceID = aura.auraInstanceID
            if auraInstanceID then
                local auraName = nil

                -- Fast path: try spellId (works out of combat)
                local sid = aura.spellId
                if sid and not issecretvalue(sid) then
                    auraName = reverseLookup[sid]
                end

                -- Fallback: fingerprint (works in combat)
                if not auraName then
                    auraName = IdentifyAuraByFingerprint(unit, auraInstanceID, aura, spec)
                end

                if auraName then
                    unitAuraState[unit][auraInstanceID] = auraName
                end
            end
        end
    end

    -- Process updated auras (auraInstanceID may have changed properties but not identity)
    -- No action needed — we track by auraInstanceID which doesn't change
end

-- ============================================================
-- GET UNIT AURAS
-- Reads from the persistent state, fetches display data from
-- C_UnitAuras.GetAuraDataByAuraInstanceID (secret-safe).
-- ============================================================

function FallbackProvider:GetUnitAuras(unit, spec)
    local forwardLookup = DF.AuraDesigner.SpellIDs[spec]  -- { [auraName] = spellId }

    -- Initialize state for this unit if we haven't seen it yet
    if not unitAuraState[unit] then
        FullScanUnit(unit, spec)
    end

    local state = unitAuraState[unit]
    if not state then return {} end

    local now = GetTime()
    local shouldLog = (now - adapterDebugLast) >= ADAPTER_DEBUG_INTERVAL

    local result = {}
    local stateCount = 0
    local matchedCount = 0

    for auraInstanceID, auraName in pairs(state) do
        stateCount = stateCount + 1
        -- Fetch live aura data (may have secret fields — that's OK for display)
        local auraData = GetAuraDataByAuraInstanceID and GetAuraDataByAuraInstanceID(unit, auraInstanceID)
        if auraData then
            matchedCount = matchedCount + 1
            result[auraName] = {
                spellId = forwardLookup and forwardLookup[auraName] or 0,  -- our known non-secret ID
                icon = auraData.icon,                   -- may be secret; OK for SetTexture
                duration = auraData.duration,            -- may be secret; OK for SetCooldownFromExpirationTime
                expirationTime = auraData.expirationTime, -- may be secret
                stacks = auraData.applications,           -- may be secret; OK for GetAuraApplicationDisplayCount
                caster = auraData.sourceUnit,
                auraInstanceID = auraInstanceID,          -- always non-secret
            }
        else
            -- Aura no longer active — clean up stale state
            state[auraInstanceID] = nil
        end
    end

    if shouldLog then
        adapterDebugLast = now
        DF:Debug("AD", "Fallback: unit=%s spec=%s tracked=%d active=%d",
            unit, spec, stateCount, matchedCount)
    end

    return result
end

-- ============================================================
-- FALLBACK EVENT FRAME
-- Listens for UNIT_AURA with updateInfo to drive incremental
-- tracking, and forwards to registered callbacks.
-- ============================================================

local fallbackCallbacks = {}
local fallbackEventFrame
local fallbackSpec = nil  -- Current player spec, cached

function FallbackProvider:RegisterCallback(owner, callback)
    fallbackCallbacks[owner] = callback
    if not fallbackEventFrame then
        fallbackEventFrame = CreateFrame("Frame")
        fallbackEventFrame:RegisterEvent("UNIT_AURA")
        fallbackEventFrame:SetScript("OnEvent", function(_, _, unit, updateInfo)
            -- Resolve current spec for fingerprinting
            if not fallbackSpec then
                local Adapter = DF.AuraDesigner.Adapter
                if Adapter and Adapter.GetPlayerSpec then
                    fallbackSpec = Adapter:GetPlayerSpec()
                end
            end

            -- Incremental update of our aura tracking state
            if fallbackSpec then
                ProcessUnitAuraUpdate(unit, updateInfo, fallbackSpec)
            end

            -- Fire registered callbacks
            for _, cb in pairs(fallbackCallbacks) do
                cb(unit)
            end
        end)

        -- Also listen for spec changes to update fingerprinting
        fallbackEventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
        fallbackEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        fallbackEventFrame:HookScript("OnEvent", function(_, event, arg1)
            if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
                fallbackSpec = nil  -- Force re-resolve on next UNIT_AURA
                wipe(unitAuraState)  -- Clear all state — specs changed, fingerprints are different
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
-- Format: { [auraName] = { spellId, icon, duration, expirationTime, stacks, caster, auraInstanceID } }
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
