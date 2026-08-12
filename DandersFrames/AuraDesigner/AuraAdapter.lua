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

-- Per-spec identity index, built lazily by GetSpecIdentity.
local identityCache = {}  -- { [spec] = { byName = {...}, byID = {...} } }

-- Per-spec merged trackable-aura lists (curated Config list + FilterRegistry
-- SpellDB class pool), built lazily by GetTrackableAuras.
local trackableCache = {}  -- { [spec] = { auraInfo, ... } }

-- Full-database list for the Other Buffs picker, built lazily by
-- GetAllTrackableAuras.
local allTrackableCache = nil

-- Clear the per-spec caches. Called on spec change so the new spec's spell IDs
-- (e.g., Earth Shield for Resto Shaman) get rebuilt on next lookup.
function AuraAdapter:InvalidateSpecCache()
    identityCache = {}
    trackableCache = {}
    allTrackableCache = nil
end

-- ============================================================
-- SPELL IDENTITY  (the ONE place a curated aura's ID set is decided)
-- ============================================================
-- Returns { byName = { [auraName] = { id, ... } }, byID = { [id] = auraName } }
-- for one spec's curated pool. Both directions come from the same build, so
-- the renderer (DF:BuildADIdentityFilters) and the editor's add-by-ID snap can
-- never disagree about which IDs belong to a spell -- they used to, and that
-- mismatch is what let add-by-ID mint config keys no UI surface could name.
--
-- ☠ INHERITANCE RULE (lab 029736dd, option C). A curated entry that declares
-- NO alternates of its own INHERITS the SpellDB record's `alts`. An entry that
-- DOES declare alternates is left byte-identical -- EarthShield,
-- EarthlivingWeapon and HolyArmaments are hand-curated shapes the database
-- genuinely disagrees with (HolyArmaments deliberately fuses Sacred Weapon and
-- Holy Bulwark, which the DB models as two records), so hand curation wins
-- wherever it has spoken. Before this, path 1 returned early and the SpellDB
-- was never consulted for a curated name at all: 17 of 58 curated entries
-- tracked a narrower ID set than the same spell used as a FILTER, e.g. Ebon
-- Might resolved {395152} and so never lit on the caster's own frame, because
-- the self-buff 395296 lives only in the database.
--
-- ☠ JOIN BY ID, NEVER BY NAME. Curated keys are internal ("EbonMight");
-- `rec.n` is the real spell name ("Ebon Might"). They are different strings for
-- most entries, and matching on them silently resolves nothing.
--
-- ☠ RESOLVE THE REGISTRY LIVE. FilterRegistry\SpellDB.lua is .toc line 153;
-- this file is line 130. A file-scope capture of DF.FilterRegistry would bind
-- nil forever -- the same load-order trap that made the defensive row show
-- every buff. Built lazily on first call (render time, long after load) and
-- wiped by InvalidateSpecCache.
function AuraAdapter:GetSpecIdentity(spec)
    if not spec then return nil end
    local cached = identityCache[spec]
    if cached then return cached end

    local AD = DF.AuraDesigner
    local specIDs = AD.SpellIDs and AD.SpellIDs[spec]
    local alts = AD.AlternateSpellIDs and AD.AlternateSpellIDs[spec]
    if not specIDs and not alts then return nil end

    local byName, byID = {}, {}

    local function add(name, id)
        if type(id) ~= "number" then return end
        local set = byName[name]
        if not set then set = {}; byName[name] = set end
        for _, have in ipairs(set) do
            if have == id then return end
        end
        set[#set + 1] = id
        -- First writer wins: a curated primary must never be re-pointed by
        -- another entry's inherited alt.
        if byID[id] == nil then byID[id] = name end
    end

    -- 1) Curated primaries. `id` is a number for every shipped entry; the table
    --    form is tolerated because the picker's own reverse scan always has.
    if specIDs then
        for name, id in pairs(specIDs) do
            if type(id) == "table" then
                for _, sub in ipairs(id) do add(name, sub) end
            else
                add(name, id)
            end
        end
    end

    -- 2) Curated alternates. Recorded before inheritance so step 3 can tell
    --    "hand-curated multi-ID entry" from "single-ID entry".
    local hasCuratedAlts = {}
    if alts then
        for altID, name in pairs(alts) do
            hasCuratedAlts[name] = true
            add(name, altID)
        end
    end

    -- 3) Inherit the SpellDB's ids for entries that declared no alts of their own.
    local R = DF.FilterRegistry
    if R and R.ByID then
        for name, ids in pairs(byName) do
            if not hasCuratedAlts[name] then
                -- Only the curated primary is a safe join key; walking the whole
                -- set could hop onto a record this entry does not own.
                local rec = R.ByID[ids[1]]
                if rec then
                    -- ☠ TAKE rec.id TOO, not just rec.alts. Curation does not
                    -- always pick the database's canonical: Dream Flight is
                    -- curated as 363502, which the DB carries as an ALT of
                    -- 359816. Unioning only the alts silently dropped the
                    -- canonical and left that entry one id short of the filter.
                    add(name, rec.id)
                    if rec.alts then
                        for _, altID in ipairs(rec.alts) do add(name, altID) end
                    end
                end
            end
        end
    end

    identityCache[spec] = { byName = byName, byID = byID }
    return identityCache[spec]
end

-- Every spell ID a curated aura tracks, or nil when the name is not curated for
-- this spec. The returned array is CACHED and shared -- read it, never mutate it.
function AuraAdapter:GetAuraSpellIDs(spec, auraName)
    local ident = self:GetSpecIdentity(spec)
    return ident and ident.byName[auraName] or nil
end

-- The curated aura name owning a spell ID, or nil. Covers primaries, curated
-- alternates and inherited SpellDB alts.
function AuraAdapter:GetAuraNameForSpellID(spec, spellID)
    local ident = self:GetSpecIdentity(spec)
    return ident and ident.byID[spellID] or nil
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

-- Returns the FULL SpellDB pool — every record, every class — adapted to the
-- same aura-info shape as GetTrackableAuras entries. Powers the Other Buffs
-- picker (B2), which groups entries by their `class` token (or "ALL").
-- `name` is the stable config key (the shipped English rec.n — the B1 naming
-- contract for the spec-independent other pool: identity resolves via
-- DF:BuildADIdentityFilters(nil, name), which the curated internal keys
-- can't do). Cached; wiped by InvalidateSpecCache.
function AuraAdapter:GetAllTrackableAuras()
    if allTrackableCache then return allTrackableCache end
    local list = {}
    local R = DF.FilterRegistry
    if R and R.Spells and R.GetSpellDisplay then
        for _, rec in ipairs(R.Spells) do
            local display, icon = R:GetSpellDisplay(rec)
            list[#list + 1] = {
                name = rec.n,
                display = display,
                color = POOL_COLOR,
                icon = icon,
                spellID = rec.id,
                class = rec.class or "ALL",
            }
        end
    end
    allTrackableCache = list
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
