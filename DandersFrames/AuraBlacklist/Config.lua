local addonName, DF = ...

-- ============================================================
-- AURA BLACKLIST CONFIG  —  DEBUFFS ONLY (by design)
--
-- WHERE THE UI WENT (this note moved here from AuraBlacklist/Options.lua, which is
-- deleted): the debuff blacklist now lives inside the Filter Designer,
-- FilterRegistry/Options.lua -> "Debuffs > Blacklist", giving one home for all
-- per-spell aura control. ONLY the old standalone Options page was removed. This
-- backend is unchanged (DF.AuraBlacklist.DebuffSpells / .AlternateSpellIDs /
-- .BuildExcludeMap, consumed by Features/Auras.lua applyDebuffBlacklist) and stored
-- db.debuffBlacklist data carries over.
--
-- DF is whitelist-by-design for BUFFS: the Filter Designer / Aura Filters let the
-- user opt IN to exactly the buffs they want to see, so a buff "blacklist" is
-- redundant and has been removed. The blacklist exists purely to HIDE nuisance
-- DEBUFFS that can't be opted out of any other way — Sated/Exhaustion (the
-- post-Bloodlust debuff) and the Deserters.
--
-- 12.1: a debuff is only hideable via excludeSpellIDs on friendly frames when
-- Blizzard flags it NeverSecret. Every ID below was live-confirmed NeverSecret via
-- DF_AuraLab `/al secretscan` / `/al secretcensus` on build 68824 (2026-07-22). Secret /
-- ContextuallySecret debuffs (encounter "move now!" debuffs, etc.) CANNOT be hidden —
-- that is the point of the lockdown — and are deliberately absent. (The census found
-- only 62 NeverSecret spells in 1..500000 — a small, deliberate Blizzard whitelist.)
-- ============================================================

local pairs = pairs

DF.AuraBlacklist = DF.AuraBlacklist or {}

-- ============================================================
-- DEBUFF SPELLS (universal — debuffs are not class-organized)
-- The meaningful nuisances are the Sated/Exhaustion family + the Deserters;
-- Ride Along is a skyriding status Blizzard grouped into the same non-secret wave.
-- Each entry: { spellId, display, icon }.
-- ============================================================
DF.AuraBlacklist.DebuffSpells = {
    -- Sated / Exhaustion family (the post-Bloodlust / Heroism debuff)
    { spellId = 57724,  display = "Sated",                  icon = 136090  },
    { spellId = 57723,  display = "Exhaustion",             icon = 136090  },
    { spellId = 80354,  display = "Temporal Displacement",  icon = 236502  },
    { spellId = 160455, display = "Fatigued",               icon = 132307  },
    { spellId = 95809,  display = "Insanity",               icon = 132127  },
    -- Deserter
    { spellId = 26013,  display = "BG Deserter",            icon = 135971  },
    { spellId = 71041,  display = "Dungeon Deserter",       icon = 135971  },
    -- Skyriding status (non-secret, grouped with the above by Blizzard)
    { spellId = 427490, display = "Ride Along Available",   icon = 4640493 },
    { spellId = 447959, display = "Ride Along Active",      icon = 4640493 },
    { spellId = 447960, display = "Ride Along Inactive",    icon = 4640493 },
    -- Mythic+ keystone scaling debuff. NeverSecret (confirmed via /al secretcensus),
    -- so it's hideable; opt-in (default off) because it's informative as well as noisy
    -- — it sits on every player for the whole dungeon. icon omitted → resolved live.
    { spellId = 206151, display = "Challenger's Burden" },
}

-- ============================================================
-- ALTERNATE SPELL ID MAP (debuff variants only)
-- Maps a variant ID to its primary entry so one entry covers all variants.
-- NeverSecret-confirmed on 68824.
-- ============================================================
DF.AuraBlacklist.AlternateSpellIDs = {
    [390435] = 57723,    -- Exhaustion variant
    [264689] = 160455,   -- Fatigued variant
}

-- ============================================================
-- HELPER: BuildExcludeMap
-- Builds the excludeSpellIDs map for the debuff row from an enabled set
-- (db.debuffBlacklist = { [primaryId] = true }). Includes each enabled primary
-- AND every alternate ID that maps to an enabled primary, so variant IDs are
-- hidden too. Returns a fresh map, or nil when nothing is enabled (so callers
-- can skip the exclude entirely). Read-only — safe to share by reference.
-- ============================================================
function DF.AuraBlacklist.BuildExcludeMap(enabledSet)
    if type(enabledSet) ~= "table" then return nil end
    local map, any = {}, false
    for id, on in pairs(enabledSet) do
        if on then map[id] = true; any = true end
    end
    if not any then return nil end
    for alt, primary in pairs(DF.AuraBlacklist.AlternateSpellIDs) do
        if map[primary] then map[alt] = true end
    end
    return map
end
