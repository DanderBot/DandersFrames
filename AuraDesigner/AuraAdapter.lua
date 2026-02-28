local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - DATA SOURCE ADAPTER
-- Bridges the Aura Designer to Blizzard's C_UnitAuras API.
-- Scans ALL auras on a unit directly via C_UnitAuras.GetUnitAuras,
-- so the designer sees every aura regardless of what Blizzard's
-- compact frames choose to display.
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
local issecretvalue = issecretvalue or function() return false end
local GetAuraDataByAuraInstanceID = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID
local GetUnitAuras = C_UnitAuras and C_UnitAuras.GetUnitAuras

DF.AuraDesigner = DF.AuraDesigner or {}

local AuraAdapter = {}
DF.AuraDesigner.Adapter = AuraAdapter

-- ============================================================
-- BLIZZARD AURA PROVIDER
-- Scans all auras on a unit directly via C_UnitAuras.GetUnitAuras.
-- This sees every buff/debuff on the unit, not just what
-- Blizzard's compact frames choose to display.
-- Secret values are handled via issecretvalue() with a persistent
-- instanceId→auraName cache for combat use.
-- ============================================================

local Provider = {}

function Provider:IsAvailable()
    return true  -- Always available
end

function Provider:GetSourceName()
    return "Blizzard Aura API"
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
    -- Merge alternate spell IDs (e.g., Earth Shield 974 → "EarthShield")
    local alts = DF.AuraDesigner.AlternateSpellIDs and DF.AuraDesigner.AlternateSpellIDs[spec]
    if alts then
        for altSpellId, auraName in pairs(alts) do
            lookup[altSpellId] = auraName
        end
    end
    spellIdLookup[spec] = lookup
    return lookup
end

-- Persistent cache: auraInstanceID → auraName
-- Populated when spellId is non-secret, used in combat when spellId is secret.
-- auraInstanceIDs are monotonically increasing and never reused within a session.
local instanceIdToAuraName = {}  -- { [auraInstanceID] = auraName }

-- Debug throttle for adapter (shares interval with engine)
local adapterDebugLast = 0
local ADAPTER_DEBUG_INTERVAL = 3

function Provider:GetUnitAuras(unit, spec)
    local lookup = GetSpellIdLookup(spec)  -- { [spellId] = auraName }
    if not lookup or not next(lookup) then return {} end

    local forwardLookup = DF.AuraDesigner.SpellIDs[spec]  -- { [auraName] = spellId }

    local now = GetTime()
    local shouldLog = (now - adapterDebugLast) >= ADAPTER_DEBUG_INTERVAL

    local result = {}
    local scannedCount = 0
    local matchedCount = 0
    local cacheHits = 0

    -- Scan ALL auras directly via C_UnitAuras.GetUnitAuras.
    -- This sees every buff/debuff on the unit regardless of what
    -- Blizzard's compact frames choose to display (e.g., Symbiotic
    -- Relationship appears on the player but Blizzard's frame hides it).
    if GetUnitAuras then
        local filters = { "HELPFUL", "HARMFUL" }
        for _, filter in ipairs(filters) do
            local auras = GetUnitAuras(unit, filter, 100)
            if auras then
                for _, auraData in ipairs(auras) do
                    scannedCount = scannedCount + 1
                    local auraName = nil
                    local auraInstanceID = auraData.auraInstanceID

                    -- Try spellId lookup (works when not secret, i.e. out of combat)
                    local sid = auraData.spellId
                    if sid and not issecretvalue(sid) then
                        auraName = lookup[sid]
                        -- Update persistent cache for combat use
                        if auraName and auraInstanceID then
                            instanceIdToAuraName[auraInstanceID] = auraName
                        end
                    elseif auraInstanceID then
                        -- In combat (secret): use cached mapping
                        auraName = instanceIdToAuraName[auraInstanceID]
                        if auraName then cacheHits = cacheHits + 1 end
                    end

                    if auraName then
                        matchedCount = matchedCount + 1
                        result[auraName] = {
                            spellId = forwardLookup and forwardLookup[auraName] or 0,
                            icon = auraData.icon,
                            duration = auraData.duration,
                            expirationTime = auraData.expirationTime,
                            stacks = auraData.applications,
                            caster = auraData.sourceUnit,
                            auraInstanceID = auraInstanceID,
                        }
                    end
                end
            end
        end
    end

    if shouldLog then
        adapterDebugLast = now
        DF:Debug("AD", "unit=%s spec=%s scanned=%d matched=%d cacheHits=%d",
            unit, spec, scannedCount, matchedCount, cacheHits)
        -- Log all unmatched spell IDs on this unit (helps identify missing alternates)
        if GetUnitAuras then
            local unmatched = {}
            for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
                local auras = GetUnitAuras(unit, filter, 100)
                if auras then
                    for _, ad in ipairs(auras) do
                        local sid = ad.spellId
                        if sid and not issecretvalue(sid) and not lookup[sid] then
                            unmatched[#unmatched + 1] = sid
                        end
                    end
                end
            end
            if #unmatched > 0 then
                DF:Debug("AD", "  unmatched IDs on %s: %s", unit, table.concat(unmatched, ", "))
            end
        end
    end

    return result
end

-- Uses a simple event frame for UNIT_AURA
local callbacks = {}
local eventFrame

function Provider:RegisterCallback(owner, callback)
    callbacks[owner] = callback
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:RegisterEvent("UNIT_AURA")
        eventFrame:SetScript("OnEvent", function(_, _, unit)
            for _, cb in pairs(callbacks) do
                cb(unit)
            end
        end)
    end
end

function Provider:UnregisterCallback(owner)
    callbacks[owner] = nil
    -- Clean up event frame if no callbacks remain
    if eventFrame and not next(callbacks) then
        eventFrame:UnregisterAllEvents()
        eventFrame = nil
    end
end

-- ============================================================
-- PUBLIC ADAPTER API
-- These methods delegate to the provider.
-- ============================================================

-- Returns true if a data source is available
function AuraAdapter:IsAvailable()
    return Provider:IsAvailable()
end

-- Returns a display name for the current data source
function AuraAdapter:GetSourceName()
    return Provider:GetSourceName()
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
-- Delegates to the provider for live aura queries.
-- ============================================================

-- Returns a table of currently active tracked auras for a unit
-- Format: { [auraName] = { spellId, icon, duration, expirationTime, stacks, caster } }
function AuraAdapter:GetUnitAuras(unit, spec)
    if not spec then spec = self:GetPlayerSpec() end
    if not spec then return {} end
    return Provider:GetUnitAuras(unit, spec)
end

-- Registers a callback for when a unit's auras change
-- callback(unit) is called whenever unit auras may have changed
function AuraAdapter:RegisterCallback(owner, callback)
    Provider:RegisterCallback(owner, callback)
end

function AuraAdapter:UnregisterCallback(owner)
    Provider:UnregisterCallback(owner)
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
