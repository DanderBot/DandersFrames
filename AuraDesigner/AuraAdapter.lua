local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - SPEC / SPELL-POOL RESOLVER
-- Config-side lookups shared by the editor, the factory bridge
-- and the test preview: player spec detection, per-spec trackable
-- aura lists and display names (all sourced from the static
-- DF.AuraDesigner tables in Config.lua).
--
-- The legacy aura-scanning provider that used to live here died
-- with the 12.1 rework: live indicators are rendered by the game
-- engine via AuraDesigner\Factory.lua and no aura data is read.
-- ============================================================

local pairs = pairs

DF.AuraDesigner = DF.AuraDesigner or {}

local AuraAdapter = {}
DF.AuraDesigner.Adapter = AuraAdapter

-- Per-spec spellId -> auraName reverse lookup, built lazily from
-- DF.AuraDesigner.SpellIDs / AlternateSpellIDs.
local spellIdLookup = {}  -- { [spec] = { [spellId] = auraName } }

-- Clear the per-spec spellId->auraName cache. Called on spec change so the
-- new spec's spell IDs (e.g., Earth Shield for Resto Shaman) get rebuilt
-- from DF.AuraDesigner.SpellIDs / AlternateSpellIDs on next lookup.
function AuraAdapter:InvalidateSpecCache()
    spellIdLookup = {}
end

-- ============================================================
-- SPEC / AURA QUERIES (uses local Config data)
-- ============================================================

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
-- UTILITY
-- ============================================================

-- Check if Aura Designer is enabled for a frame
function DF:IsAuraDesignerEnabled(frame)
    local adDB = frame and DF.ResolveAuraDesigner and DF:ResolveAuraDesigner(frame)
    if adDB then
        return adDB.enabled
    end
    return false
end
