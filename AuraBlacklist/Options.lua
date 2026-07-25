local addonName, DF = ...

-- ============================================================
-- AURA BLACKLIST — page RETIRED.
--
-- The debuff blacklist now lives inside the Filter Designer
-- (FilterRegistry/Options.lua -> "Debuffs > Blacklist"), giving one home for
-- all per-spell aura control. Buffs are whitelist-by-design there; this is the
-- debuff-side hide list for the non-secret nuisances (Sated/Exhaustion family,
-- Deserters, Ride Along).
--
-- The BACKEND is unchanged and still lives in AuraBlacklist/Config.lua
-- (DF.AuraBlacklist.DebuffSpells / .AlternateSpellIDs / .BuildExcludeMap),
-- consumed by Features/Auras.lua applyDebuffBlacklist. Only the old standalone
-- Options page was removed; stored data (db.debuffBlacklist) carries over.
--
-- This file is intentionally empty apart from this note. It stays in the .toc
-- so AuraBlacklist/ keeps a stable load footprint alongside its Config.lua.
-- ============================================================
