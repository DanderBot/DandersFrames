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

local pairs, ipairs = pairs, ipairs

DF.AuraDesigner = DF.AuraDesigner or {}

local AuraAdapter = {}
DF.AuraDesigner.Adapter = AuraAdapter

-- Per-spec spellId -> auraName reverse lookup, built lazily from
-- DF.AuraDesigner.SpellIDs / AlternateSpellIDs.
local spellIdLookup = {}  -- { [spec] = { [spellId] = auraName } }

-- Per-spec merged trackable-aura lists (curated Config list + FilterRegistry
-- SpellDB class pool), built lazily by GetTrackableAuras.
local trackableCache = {}  -- { [spec] = { auraInfo, ... } }

-- Clear the per-spec spellId->auraName cache. Called on spec change so the
-- new spec's spell IDs (e.g., Earth Shield for Resto Shaman) get rebuilt
-- from DF.AuraDesigner.SpellIDs / AlternateSpellIDs on next lookup.
function AuraAdapter:InvalidateSpecCache()
    spellIdLookup = {}
    trackableCache = {}
end

-- ============================================================
-- SPEC / AURA QUERIES (uses local Config data)
-- ============================================================

-- Returns the display name for a spec key
function AuraAdapter:GetSpecDisplayName(specKey)
    local info = DF.AuraDesigner.SpecInfo[specKey]
    return info and info.display or specKey
end

-- Neutral tile accent for SpellDB pool entries (curated Config entries carry
-- hand-picked colours; the generic pool shares one grey). Read-only.
local POOL_COLOR = { 0.62, 0.62, 0.62 }

-- Returns the list of trackable auras for a spec: the curated Config list
-- FIRST and unchanged (same entry tables, same order — existing indicators
-- keep resolving identically), then the FilterRegistry SpellDB pool for the
-- spec's CLASS plus class="ALL" records, deduped against the curated list by
-- spell ID (canonical + alts) and by name. Pool entries are adapted to the
-- curated aura-info shape the picker consumers read:
--   { name, display, color } plus `spellID` (canonical id, for tooltips),
--   `icon` (via R:GetSpellDisplay) and `class` (the record's class token or
--   "ALL" — drives the picker's "Your Class" / "All Classes" grouping;
--   curated entries carry no class field and always group under the class).
-- `name` is the stable config key: the shipped English rec.n, never the
-- localized display (localized keys would go stale on language switch).
-- Cached per spec; wiped by InvalidateSpecCache.
function AuraAdapter:GetTrackableAuras(specKey)
    if not specKey then return {} end
    local cached = trackableCache[specKey]
    if cached then return cached end

    local list = {}
    local usedIDs, usedNames = {}, {}

    -- 1) Curated Config list (when present) — verbatim, first.
    local curated = DF.AuraDesigner.TrackableAuras[specKey]
    if curated then
        for _, info in ipairs(curated) do
            list[#list + 1] = info
            usedNames[info.name] = true
            if info.display then usedNames[info.display] = true end
        end
        local specIDs = DF.AuraDesigner.SpellIDs[specKey]
        if specIDs then
            for _, id in pairs(specIDs) do usedIDs[id] = true end
        end
        local alts = DF.AuraDesigner.AlternateSpellIDs[specKey]
        if alts then
            for altID in pairs(alts) do usedIDs[altID] = true end
        end
    end

    -- 2) SpellDB pool for the spec's class (+ ALL-class consumables etc.).
    local R = DF.FilterRegistry
    local info = DF.AuraDesigner.SpecInfo[specKey]
    local class = info and info.class
    if class and R and R.Spells and R.GetSpellDisplay then
        for _, rec in ipairs(R.Spells) do
            if rec.class == class or rec.class == "ALL" then
                local dup = usedIDs[rec.id]
                if not dup and rec.alts then
                    for _, altID in ipairs(rec.alts) do
                        if usedIDs[altID] then dup = true; break end
                    end
                end
                if not dup then
                    local display, icon = R:GetSpellDisplay(rec)
                    if not usedNames[rec.n] and not usedNames[display] then
                        list[#list + 1] = {
                            name = rec.n,
                            display = display,
                            color = POOL_COLOR,
                            icon = icon,
                            spellID = rec.id,
                            class = rec.class,
                        }
                        usedNames[rec.n] = true
                        usedNames[display] = true
                    end
                end
            end
        end
    end

    trackableCache[specKey] = list
    return list
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
