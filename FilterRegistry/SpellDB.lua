local addonName, DF = ...

-- ============================================================
-- FILTER REGISTRY — SHIPPED SPELL DATABASE
-- Curated spell records for the buff filter presets. Source:
-- WCL harvest v2, 2026-07-12 (lab discussion
-- ee16e59f-d4c9-4680-b2ca-17a754a3e102), 353 spells / 13
-- categories. One record per SPELL; alts carry every other known
-- spellID for the same spell — but IDs are merged into one record
-- ONLY when they share the identical category set (per-ID category
-- divergences ship as separate records). `n` is an English
-- fallback name — display prefers C_Spell at runtime.
-- `off = true` ships the spell disabled-by-default (still listed
-- in the Filter Designer). Regenerate per patch from the WCL
-- pipeline; bump DBStamp when you do.
-- ============================================================

local pairs, ipairs = pairs, ipairs

DF.FilterRegistry = DF.FilterRegistry or {}
local R = DF.FilterRegistry

R.DBStamp = { harvest = "2026-07-12", gameBuild = 68569 }

-- Hand-maintained exclusion list — harvest ids DF refuses to carry, with the
-- reason. Regeneration (/update-spelldb) DROPS these ids from records (a record
-- whose only id is excluded vanishes entirely) and the diff tool treats their
-- absence as intentional, so they stay gone across re-harvests. Remove an entry
-- to let the next regeneration re-add the spell.
R.Excluded = {
    -- Maintainer curation 2026-07-19 (Krathe filter pass; kept in sync via lab discussion)
    [363502]  = "Dream Flight (Healing aura id) - we track the raid-cooldown id 359816; drop the Healing duplicate",
    [108280]  = "Healing Tide Totem - totem, not an aura on the unit",
    [5394]    = "Healing Stream Totem - totem, not an aura on the unit",
    [198103]  = "Earth Elemental - guardian/pet, not an aura on the unit",
    [383013]  = "Poison Cleansing Totem - totem, not an aura on the unit",
    [472708]  = "Shell Cover - not an aura on the unit",
    [408233]  = "Bestow Weyrnstone cast id - the tracked aura is 410318; drop the cast id",
    [7744]    = "Will of the Forsaken — aura is a 100ms immunity blip; functionally a CC-removal cast, nothing to display",
    [59752]   = "Will to Survive — 100ms stun-immunity blip; nothing to display",
    [422382]  = "Wild Growth log-side id — no client-side spell data (audit INVALID)",
    [1308649] = "Vampiric Insight — no client-side spell data (audit INVALID); re-add with the corrected id from the harvest",
    [443113]  = "Strength of the Black Ox (ally absorb) — spec-variable rider, not worth tracking (maintainer curation)",
    [443112]  = "Strength of the Black Ox (self cast-time buff) — same call as 443113",
}

-- Maintainer category overrides — the FINAL category set for these ids, replacing
-- the harvest's placement (one home per spell; picked by Danders 2026-07-15 to kill
-- cross-filter duplicates). Regeneration applies these AFTER building records and
-- re-runs the merge step (ids whose patched sets now match collapse into one
-- record); the diff tool compares against the PATCHED expectation. List EVERY id
-- of the spell. Remove an entry to return to the harvest's placement.
R.CategoryPatch = {
    -- Maintainer curation 2026-07-19 (Krathe filter pass; kept in sync via lab discussion)
    -- kept in the DB/picker but in no preset (empty final category set):
    [1278914] = {},  -- Dream Guide (out of Healing)
    [388513]  = {},  -- Overflowing Mists (out of Healing)
    [370889]  = { utility = true, movement = true },  -- Twin Guardian (moved off External Defensives)
    [370888]  = { utility = true, movement = true },
    [406732]  = { movement = true, utility = true },  -- Spatial Paradox (also copied into Utility)
    [406789]  = { movement = true, utility = true },
    [431698]  = { movement = true, utility = true },  -- Temporal Burst (also into Utility; off by default)
    [53563]   = { healing = true },             -- Beacon of Light
    [17]      = { healing = true },             -- Power Word: Shield
    [1246768] = { healing = true },
    [1254306] = { healing = true },
    [1300008] = { healing = true },
    [47788]   = { externalDefensives = true },  -- Guardian Spirit
    [102342]  = { externalDefensives = true },  -- Ironbark
    [116849]  = { externalDefensives = true },  -- Life Cocoon
    [33206]   = { externalDefensives = true },  -- Pain Suppression
    [1022]    = { externalDefensives = true },  -- Blessing of Protection
    [1309794] = { externalDefensives = true },
    [6940]    = { externalDefensives = true },  -- Blessing of Sacrifice
    [357170]  = { externalDefensives = true },  -- Time Dilation
    [363534]  = { raidDefensives = true },      -- Rewind
    [1044]    = { movement = true },            -- Blessing of Freedom
    [299256]  = { movement = true },
    [10060]   = { powerExternals = true },      -- Power Infusion
    [47585]   = { defensives = true },          -- Dispersion
}

-- Sidebar/list display order. `name` keys are looked up through L at
-- display time (Options code does L[cat.name]); keep them stable.
R.Categories = {
    { key = "healing",            name = "Healing" },
    { key = "raidBuffs",          name = "Raid Buffs" },
    { key = "raidDefensives",     name = "Raid Cooldowns" },
    { key = "externalDefensives", name = "External Defensives" },
    { key = "defensives",         name = "Defensives" },
    { key = "powerExternals",     name = "Power Externals" },
    { key = "movement",           name = "Movement" },
    { key = "utility",            name = "Utility" },
    { key = "consumables",        name = "Consumables" },
    { key = "trinketsItems",      name = "Trinkets & Items" },
    { key = "tierSetAuras",       name = "Tier Set Auras" },
    { key = "petBuffs",           name = "Pet Buffs" },
    { key = "racials",            name = "Racials" },
}

-- Records are grouped by the section they FIRST appear in within the
-- source data; multi-category spells carry every category in `cats`.
R.Spells = {
    -- ------------------------------------------------------------
    -- Healing
    -- ------------------------------------------------------------
    { id = 774,      alts = { 419204 }, n = "Rejuvenation", class = "DRUID", cats = { healing = true } },
    { id = 8936,     alts = { 419287 }, n = "Regrowth", class = "DRUID", cats = { healing = true } },
    { id = 33763,    alts = { 419207, 1227806 }, n = "Lifebloom", class = "DRUID", cats = { healing = true } },
    { id = 155777,   n = "Germination",               class = "DRUID",         cats = { healing = true } },
    { id = 48438,    alts = { 419344 }, n = "Wild Growth", class = "DRUID", cats = { healing = true } },
    { id = 474754,   alts = { 474750 }, n = "Symbiotic Relationship", class = "DRUID", cats = { healing = true } },
    { id = 439530,   n = "Symbiotic Blooms",          class = "DRUID",         cats = { healing = true } },
    { id = 102342,   n = "Ironbark",                  class = "DRUID",         cats = { externalDefensives = true } },
    { id = 17,       alts = { 1246768, 1254306, 1300008 }, n = "Power Word: Shield", class = "PRIEST", cats = { healing = true } },
    { id = 194384,   n = "Atonement",                 class = "PRIEST",        cats = { healing = true } },
    { id = 1253593,  alts = { 1300009 }, n = "Void Shield", class = "PRIEST", cats = { healing = true } },
    { id = 41635,    n = "Prayer of Mending",         class = "PRIEST",        cats = { healing = true } },
    { id = 33206,    n = "Pain Suppression",          class = "PRIEST",        cats = { externalDefensives = true } },
    { id = 10060,    n = "Power Infusion",            class = "PRIEST",        cats = { powerExternals = true } },
    { id = 139,      n = "Renew",                     class = "PRIEST",        cats = { healing = true } },
    { id = 77489,    n = "Echo of Light",             class = "PRIEST",        off = true, cats = { healing = true } },
    { id = 47788,    n = "Guardian Spirit",           class = "PRIEST",        cats = { externalDefensives = true } },
    { id = 119611,   n = "Renewing Mist",             class = "MONK",          cats = { healing = true } },
    { id = 124682,   n = "Enveloping Mist",           class = "MONK",          cats = { healing = true } },
    { id = 115175,   alts = { 1260617, 198533 }, n = "Soothing Mist", class = "MONK", cats = { healing = true } },
    { id = 450769,   alts = { 450521, 450711, 450526, 450531 }, n = "Aspect of Harmony", class = "MONK", cats = { healing = true } },
    { id = 116849,   n = "Life Cocoon",               class = "MONK",          cats = { externalDefensives = true } },
    { id = 61295,    n = "Riptide",                   class = "SHAMAN",        cats = { healing = true } },
    { id = 383648,   alts = { 974 }, n = "Earth Shield", class = "SHAMAN", cats = { healing = true } },
    { id = 207400,   n = "Ancestral Vigor",           class = "SHAMAN",        off = true, cats = { healing = true } },
    { id = 382024,   alts = { 382022, 382021 }, n = "Earthliving Weapon", class = "SHAMAN", off = true, cats = { healing = true } },
    { id = 444490,   n = "Hydrobubble",               class = "SHAMAN",        cats = { healing = true } },
    { id = 156910,   n = "Beacon of Faith",           class = "PALADIN",       cats = { healing = true } },
    { id = 156322,   alts = { 461432 }, n = "Eternal Flame", class = "PALADIN", cats = { healing = true } },
    { id = 53563,    n = "Beacon of Light",           class = "PALADIN",       cats = { healing = true } },
    { id = 1244893,  alts = { 1245369 }, n = "Beacon of the Savior", class = "PALADIN", cats = { healing = true } },
    { id = 200025,   n = "Beacon of Virtue",          class = "PALADIN",       cats = { healing = true } },
    { id = 1022,     alts = { 1309794 }, n = "Blessing of Protection", class = "PALADIN", cats = { externalDefensives = true } },
    { id = 432502,   n = "Sacred Weapon",             class = "PALADIN",       cats = { healing = true } },
    { id = 6940,     n = "Blessing of Sacrifice",     class = "PALADIN",       cats = { externalDefensives = true } },
    { id = 1044,     alts = { 299256 }, n = "Blessing of Freedom", class = "PALADIN", cats = { movement = true } },
    { id = 431381,   alts = { 431522 }, n = "Dawnlight", class = "PALADIN", cats = { healing = true } },
    { id = 364343,   n = "Echo",                      class = "EVOKER",        cats = { healing = true } },
    { id = 366155,   n = "Reversion",                 class = "EVOKER",        cats = { healing = true } },
    { id = 367364,   n = "Echo: Reversion",           class = "EVOKER",        cats = { healing = true } },
    { id = 355941,   alts = { 355936, 382614 }, n = "Dream Breath", class = "EVOKER", cats = { healing = true } },
    { id = 376788,   n = "Echo: Dream Breath",        class = "EVOKER",        cats = { healing = true } },
    { id = 373267,   n = "Lifebind",                  class = "EVOKER",        cats = { healing = true } },
    { id = 357170,   n = "Time Dilation",             class = "EVOKER",        cats = { externalDefensives = true } },
    { id = 363534,   n = "Rewind",                    class = "EVOKER",        cats = { raidDefensives = true } },
    { id = 409895,   n = "Verdant Embrace",           class = "EVOKER",        cats = { healing = true } },
    { id = 445740,   n = "Enkindle",                  class = "EVOKER",        off = true, cats = { healing = true } },
    { id = 432607,   alts = { 432496 }, n = "Holy Bulwark", class = "PALADIN", cats = { healing = true } },
    { id = 1291636,  n = "Temporal Barrier",          class = "EVOKER",        cats = { healing = true } },
    { id = 47753,    n = "Divine Aegis",              class = "PRIEST",        off = true, cats = { healing = true } },
    { id = 373862,   n = "Temporal Anomaly",          class = "EVOKER",        cats = { healing = true } },
    { id = 409678,   n = "Chrono Ward",               class = "EVOKER",        cats = { healing = true } },
    { id = 431415,   n = "Sun Sear",                  class = "PALADIN",       off = true, cats = { healing = true } },
    { id = 1278914,  n = "Dream Guide",               class = "DRUID",         cats = {} },  -- DB-only: out of Healing preset, still addable via the picker
    { id = 390677,   n = "Inspiration",               class = "PRIEST",        off = true, cats = { healing = true } },
    { id = 1301739,  n = "Blessed Word",              class = "PALADIN",       cats = { healing = true } },
    { id = 1239091,  n = "Lesser Weapon",             class = "PALADIN",       off = true, cats = { healing = true } },
    { id = 1239002,  n = "Lesser Bulwark",            class = "PALADIN",       off = true, cats = { healing = true } },
    { id = 414407,   alts = { 392939 }, n = "Veneration", class = "PALADIN", cats = { healing = true } },
    { id = 1241866,  n = "Glistening Radiance",       class = "PALADIN",       cats = { healing = true } },
    { id = 431907,   alts = { 463073 }, n = "Sun's Avatar", class = "PALADIN", off = true, cats = { healing = true } },
    { id = 453846,   alts = { 453850 }, n = "Resonant Energy", class = "PRIEST", off = true, cats = { healing = true } },
    { id = 469703,   n = "Tempered in Battle",        class = "PALADIN",       cats = { healing = true } },
    { id = 1292922,  n = "Coalescence",               class = "MONK",          cats = { healing = true } },
    { id = 450805,   n = "Purified Spirit",           class = "MONK",          cats = { healing = true } },
    { id = 388513,   n = "Overflowing Mists",         class = "MONK",          cats = {} },  -- DB-only: out of Healing preset, still addable via the picker
    { id = 467281,   alts = { 427296 }, n = "Healing Elixir", class = "MONK", cats = { healing = true } },
    { id = 54149,    n = "Infusion of Light",         class = "PALADIN",       off = true, cats = { healing = true } },

    -- ------------------------------------------------------------
    -- Raid Buffs
    -- ------------------------------------------------------------
    { id = 1459,     n = "Arcane Intellect",          class = "MAGE",          cats = { raidBuffs = true } },
    { id = 21562,    n = "Power Word: Fortitude",     class = "PRIEST",        cats = { raidBuffs = true } },
    { id = 6673,     n = "Battle Shout",              class = "WARRIOR",       cats = { raidBuffs = true } },
    { id = 1126,     n = "Mark of the Wild",          class = "DRUID",         cats = { raidBuffs = true } },
    { id = 462854,   n = "Skyfury",                   class = "SHAMAN",        cats = { raidBuffs = true } },
    { id = 381732,   alts = { 381741, 381746, 381748, 381749, 381750, 381751, 381752, 381753, 381756, 381757, 381758, 381754 },
      n = "Blessing of the Bronze", class = "EVOKER", cats = { raidBuffs = true } },
    { id = 465,      n = "Devotion Aura",             class = "PALADIN",       cats = { raidBuffs = true } },
    { id = 32223,    n = "Crusader Aura",             class = "PALADIN",       cats = { raidBuffs = true } },
    { id = 317920,   n = "Concentration Aura",        class = "PALADIN",       cats = { raidBuffs = true } },

    -- ------------------------------------------------------------
    -- Raid Cooldowns
    -- ------------------------------------------------------------
    { id = 97463,    alts = { 97462 }, n = "Rallying Cry", class = "WARRIOR", cats = { raidDefensives = true } },
    { id = 145629,   alts = { 51052 }, n = "Anti-Magic Zone", class = "DEATHKNIGHT", cats = { raidDefensives = true } },
    { id = 209426,   alts = { 196718 }, n = "Darkness", class = "DEMONHUNTER", cats = { raidDefensives = true } },
    { id = 81782,    alts = { 62618 }, n = "Power Word: Barrier", class = "PRIEST", cats = { raidDefensives = true } },
    { id = 64843,    alts = { 64844 }, n = "Divine Hymn", class = "PRIEST", cats = { raidDefensives = true } },
    { id = 200183,   n = "Apotheosis",                class = "PRIEST",        cats = { raidDefensives = true } },
    { id = 15286,    n = "Vampiric Embrace",          class = "PRIEST",        cats = { raidDefensives = true } },
    { id = 421453,   n = "Ultimate Penitence",        class = "PRIEST",        cats = { raidDefensives = true } },
    { id = 120517,   alts = { 120644, 453094, 449840 }, n = "Halo", class = "PRIEST", cats = { raidDefensives = true } },
    { id = 31821,    alts = { 317929 }, n = "Aura Mastery", class = "PALADIN", cats = { raidDefensives = true } },
    { id = 31884,    alts = { 454351 }, n = "Avenging Wrath", class = "PALADIN", off = true, cats = { raidDefensives = true } },
    { id = 216331,   n = "Avenging Crusader",         class = "PALADIN",       off = true, cats = { raidDefensives = true } },
    { id = 200652,   alts = { 200654 }, n = "Tyr's Deliverance", class = "PALADIN", cats = { raidDefensives = true } },
    { id = 325174,   alts = { 98008 }, n = "Spirit Link Totem", class = "SHAMAN", cats = { raidDefensives = true } },
    { id = 114052,   n = "Ascendance",                class = "SHAMAN",        cats = { raidDefensives = true } },
    { id = 740,      alts = { 157982, 1264623 }, n = "Tranquility", class = "DRUID", cats = { raidDefensives = true } },
    { id = 374227,   n = "Zephyr",                    class = "EVOKER",        cats = { raidDefensives = true } },
    { id = 359816,   alts = { 362361 }, n = "Dream Flight", class = "EVOKER", cats = { raidDefensives = true } },
    { id = 322118,   n = "Invoke Yu'lon",             class = "MONK",          cats = { raidDefensives = true } },
    { id = 325197,   n = "Invoke Chi-Ji",             class = "MONK",          cats = { raidDefensives = true } },
    { id = 443028,   alts = { 1248992 }, n = "Celestial Conduit", class = "MONK", cats = { raidDefensives = true } },
    { id = 462568,   n = "Elemental Resistance",      class = "SHAMAN",        off = true, cats = { raidDefensives = true } },
    { id = 1260681,  alts = { 406139, 406220, 451299 }, n = "Chi Cocoon", class = "MONK", cats = { raidDefensives = true } },
    { id = 211210,   n = "Protection of Tyr",         class = "PALADIN",       cats = { raidDefensives = true } },

    -- ------------------------------------------------------------
    -- Movement
    -- ------------------------------------------------------------
    { id = 48265,    n = "Death's Advance",           class = "DEATHKNIGHT",   cats = { movement = true } },
    { id = 212552,   n = "Wraith Walk",               class = "DEATHKNIGHT",   cats = { movement = true } },
    { id = 457343,   alts = { 457333 }, n = "Death's Arrival", class = "ROGUE", cats = { movement = true } },
    { id = 389847,   n = "Felfire Haste",             class = "DEMONHUNTER",   cats = { movement = true } },
    { id = 1850,     alts = { 61684 }, n = "Dash", class = "DRUID", cats = { movement = true } },
    { id = 252216,   n = "Tiger Dash",                class = "DRUID",         cats = { movement = true } },
    { id = 106898,   alts = { 77761, 77764 }, n = "Stampeding Roar", class = "DRUID", cats = { movement = true } },
    { id = 400126,   n = "Forestwalk",                class = "DRUID",         off = true, cats = { movement = true } },
    { id = 449609,   n = "Lighter Than Air",          class = "MONK",          cats = { movement = true } },
    { id = 406732,   alts = { 406789 }, n = "Spatial Paradox", class = "EVOKER", cats = { movement = true, utility = true } },
    { id = 375226,   alts = { 375252, 375230, 375229, 375257, 375253, 375256, 375240, 375254, 375238, 375234, 375258, 375255 },
      n = "Time Spiral", class = "EVOKER", cats = { movement = true } },
    { id = 370665,   alts = { 370666, 370667, 420217 }, n = "Rescue", class = "EVOKER", cats = { movement = true } },
    { id = 431698,   n = "Temporal Burst",            class = "EVOKER",        off = true, cats = { movement = true, utility = true } },
    { id = 432061,   n = "Motes of Acceleration",     class = "EVOKER",        cats = { movement = true } },
    { id = 452701,   n = "Roar from the Heavens",     class = "MONK",          cats = { movement = true } },
    { id = 186257,   alts = { 186258 }, n = "Aspect of the Cheetah", class = "HUNTER", cats = { movement = true } },
    { id = 118922,   n = "Posthaste",                 class = "HUNTER",        cats = { movement = true } },
    { id = 1224810,  alts = { 54216, 62305 }, n = "Master's Call", class = "HUNTER", cats = { movement = true } },
    { id = 382294,   n = "Incantation of Swiftness",  class = "MAGE",          cats = { movement = true } },
    { id = 444754,   n = "Slippery Slinging",         class = "MAGE",          cats = { movement = true } },
    { id = 119085,   n = "Chi Torpedo",               class = "MONK",          cats = { movement = true } },
    { id = 101545,   n = "Flying Serpent Kick",       class = "MONK",          cats = { movement = true } },
    { id = 116841,   n = "Tiger's Lust",              class = "MONK",          cats = { movement = true } },
    { id = 443569,   n = "Chi-Ji's Swiftness",        class = "MONK",          cats = { movement = true } },
    { id = 276111,   alts = { 221886, 221883, 276112, 254474, 254472, 254471, 221885, 254473, 363608, 294133, 221887, 1272854, 453804, 1253874, 1253723, 1253881 },
      n = "Divine Steed", class = "PALADIN", cats = { movement = true } },
    { id = 431752,   alts = { 431462 }, n = "Will of the Dawn", class = "PALADIN", cats = { movement = true } },
    { id = 394454,   n = "Echoing Freedom",            class = "PALADIN",       cats = { movement = true } },
    { id = 121557,   n = "Angelic Feather",           class = "PRIEST",        cats = { movement = true } },
    { id = 65081,    n = "Body and Soul",             class = "PRIEST",        cats = { movement = true } },
    { id = 73325,    n = "Leap of Faith",             class = "PRIEST",        cats = { movement = true } },
    { id = 355851,   n = "Blaze of Light",            class = "PRIEST",        cats = { movement = true } },
    { id = 47585,    n = "Dispersion",                class = "PRIEST",        cats = { defensives = true } },
    { id = 2983,     n = "Sprint",                    class = "ROGUE",         cats = { movement = true } },
    { id = 36554,    n = "Shadowstep",                class = "ROGUE",         cats = { movement = true } },
    { id = 2645,     n = "Ghost Wolf",                class = "SHAMAN",        off = true, cats = { movement = true } },
    { id = 58875,    alts = { 90328 }, n = "Spirit Walk", class = "SHAMAN", cats = { movement = true } },
    { id = 79206,    n = "Spiritwalker's Grace",      class = "SHAMAN",        cats = { movement = true } },
    { id = 192082,   n = "Wind Rush",                 class = "SHAMAN",        cats = { movement = true } },
    { id = 378076,   n = "Thunderous Paws",           class = "SHAMAN",        cats = { movement = true } },
    { id = 111400,   n = "Burning Rush",              class = "WARLOCK",       cats = { movement = true } },
    { id = 387633,   n = "Soulburn: Demonic Circle",  class = "WARLOCK",       cats = { movement = true } },
    { id = 202164,   n = "Bounding Stride",           class = "WARRIOR",       cats = { movement = true } },
    { id = 18499,    n = "Berserker Rage",            class = "WARRIOR",       cats = { movement = true } },
    { id = 446044,   n = "Relentless Pursuit",        class = "WARRIOR",       cats = { movement = true } },
    { id = 262232,   n = "War Machine",               class = "WARRIOR",       cats = { movement = true } },
    { id = 434029,   n = "Vampiric Speed",            class = "DEATHKNIGHT",   cats = { movement = true } },

    -- ------------------------------------------------------------
    -- Power Externals
    -- ------------------------------------------------------------
    { id = 29166,    n = "Innervate",                 class = "DRUID",         cats = { powerExternals = true } },
    { id = 410089,   n = "Prescience",                class = "EVOKER",        cats = { powerExternals = true } },
    { id = 395152,   alts = { 395296 }, n = "Ebon Might", class = "EVOKER", cats = { powerExternals = true } },
    { id = 413984,   n = "Shifting Sands",            class = "EVOKER",        off = true, cats = { powerExternals = true } },
    { id = 360827,   n = "Blistering Scales",         class = "EVOKER",        cats = { powerExternals = true } },
    { id = 410263,   n = "Inferno's Blessing",        class = "EVOKER",        off = true, cats = { powerExternals = true } },
    { id = 410686,   n = "Symbiotic Bloom",           class = "EVOKER",        cats = { powerExternals = true } },
    { id = 369459,   n = "Source of Magic",           class = "EVOKER",        cats = { powerExternals = true } },

    -- ------------------------------------------------------------
    -- External Defensives
    -- ------------------------------------------------------------
    { id = 204018,   n = "Blessing of Spellwarding",  class = "PALADIN",       cats = { externalDefensives = true } },
    { id = 387804,   n = "Echoing Protection",        class = "PALADIN",       cats = { externalDefensives = true } },
    { id = 53480,    n = "Roar of Sacrifice",         class = "HUNTER",        cats = { externalDefensives = true } },
    { id = 370889,   alts = { 370888 }, n = "Twin Guardian", class = "EVOKER", cats = { utility = true, movement = true } },
    { id = 1241717,  n = "Seraphic Barrier",          class = "PALADIN",       cats = { externalDefensives = true } },
    { id = 454863,   n = "Lesser Anti-Magic Shell",   class = "DEATHKNIGHT",   cats = { externalDefensives = true } },
    { id = 461499,   n = "Overflowing Light",         class = "PALADIN",       cats = { externalDefensives = true } },
    { id = 387792,   n = "Empyreal Ward",             class = "PALADIN",       cats = { externalDefensives = true } },

    -- ------------------------------------------------------------
    -- Defensives
    -- ------------------------------------------------------------
    { id = 190456,   alts = { 1277297 }, n = "Ignore Pain", class = "WARRIOR", cats = { defensives = true } },
    { id = 118038,   n = "Die by the Sword",          class = "WARRIOR",       cats = { defensives = true } },
    { id = 23920,    alts = { 385391 }, n = "Spell Reflection", class = "WARRIOR", cats = { defensives = true } },
    { id = 386208,   alts = { 1261776, 1243856 }, n = "Defensive Stance", class = "WARRIOR", off = true, cats = { defensives = true } },
    { id = 184364,   n = "Enraged Regeneration",      class = "WARRIOR",       cats = { defensives = true } },
    { id = 147833,   n = "Intervene",                 class = "WARRIOR",       cats = { defensives = true } },
    { id = 642,      n = "Divine Shield",             class = "PALADIN",       cats = { defensives = true } },
    { id = 498,      alts = { 403876 }, n = "Divine Protection", class = "PALADIN", cats = { defensives = true } },
    { id = 184662,   n = "Shield of Vengeance",       class = "PALADIN",       cats = { defensives = true } },
    { id = 461867,   n = "Sacrosanct Crusade",        class = "PALADIN",       cats = { defensives = true } },
    { id = 209388,   alts = { 453043 }, n = "Bulwark of Order", class = "PALADIN", cats = { defensives = true } },
    { id = 157128,   n = "Saved by the Light",        class = "PALADIN",       cats = { defensives = true } },
    { id = 48792,    n = "Icebound Fortitude",        class = "DEATHKNIGHT",   cats = { defensives = true } },
    { id = 48707,    alts = { 444741 }, n = "Anti-Magic Shell", class = "DEATHKNIGHT", cats = { defensives = true } },
    { id = 49039,    n = "Lichborne",                 class = "DEATHKNIGHT",   cats = { defensives = true } },
    { id = 45438,    n = "Ice Block",                 class = "MAGE",          cats = { defensives = true } },
    { id = 414658,   n = "Ice Cold",                  class = "MAGE",          cats = { defensives = true } },
    { id = 235450,   n = "Prismatic Barrier",         class = "MAGE",          cats = { defensives = true } },
    { id = 235313,   n = "Blazing Barrier",           class = "MAGE",          cats = { defensives = true } },
    { id = 11426,    n = "Ice Barrier",               class = "MAGE",          cats = { defensives = true } },
    { id = 66,       n = "Invisibility",              class = "MAGE",          cats = { defensives = true } },
    { id = 110960,   alts = { 113862 }, n = "Greater Invisibility", class = "MAGE", cats = { defensives = true } },
    { id = 55342,    n = "Mirror Image",              class = "MAGE",          cats = { defensives = true } },
    { id = 342246,   n = "Alter Time",                class = "MAGE",          cats = { defensives = true } },
    { id = 19236,    n = "Desperate Prayer",          class = "PRIEST",        cats = { defensives = true } },
    { id = 586,      n = "Fade",                      class = "PRIEST",        cats = { defensives = true } },
    { id = 45242,    alts = { 426401 }, n = "Focused Will", class = "PRIEST", off = true, cats = { defensives = true } },
    { id = 193065,   n = "Protective Light",          class = "PRIEST",        off = true, cats = { defensives = true } },
    { id = 114216,   alts = { 114214 }, n = "Angelic Bulwark", class = "PRIEST", cats = { defensives = true } },
    { id = 22812,    n = "Barkskin",                  class = "DRUID",         cats = { defensives = true } },
    { id = 61336,    n = "Survival Instincts",        class = "DRUID",         cats = { defensives = true } },
    { id = 22842,    n = "Frenzied Regeneration",     class = "DRUID",         cats = { defensives = true } },
    { id = 192081,   n = "Ironfur",                   class = "DRUID",         off = true, cats = { defensives = true } },
    { id = 393903,   n = "Ursine Vigor",              class = "DRUID",         off = true, cats = { defensives = true } },
    { id = 5487,     n = "Bear Form",                 class = "DRUID",         off = true, cats = { defensives = true } },
    { id = 363916,   n = "Obsidian Scales",           class = "EVOKER",        cats = { defensives = true } },
    { id = 115203,   alts = { 120954 }, n = "Fortifying Brew", class = "MONK", cats = { defensives = true } },
    { id = 122783,   n = "Diffuse Magic",             class = "MONK",          cats = { defensives = true } },
    { id = 108271,   n = "Astral Shift",              class = "SHAMAN",        cats = { defensives = true } },
    { id = 457387,   n = "Wind Barrier",              class = "SHAMAN",        cats = { defensives = true } },
    { id = 381755,   n = "Primordial Bond",           class = "SHAMAN",        cats = { defensives = true } },
    { id = 186265,   n = "Aspect of the Turtle",      class = "HUNTER",        cats = { defensives = true } },
    { id = 264735,   n = "Survival of the Fittest",   class = "HUNTER",        cats = { defensives = true } },
    { id = 104773,   n = "Unending Resolve",          class = "WARLOCK",       cats = { defensives = true } },
    { id = 108416,   n = "Dark Pact",                 class = "WARLOCK",       cats = { defensives = true } },
    { id = 387847,   n = "Fel Armor",                 class = "WARLOCK",       off = true, cats = { defensives = true } },
    { id = 108366,   n = "Soul Leech",                class = "WARLOCK",       off = true, cats = { defensives = true } },
    { id = 427912,   alts = { 258920 }, n = "Infernal Armor", class = "DEMONHUNTER", off = true, cats = { defensives = true } },
    { id = 1266616,  alts = { 394933 }, n = "Demon Muzzle", class = "DEMONHUNTER", cats = { defensives = true } },
    { id = 31224,    n = "Cloak of Shadows",          class = "ROGUE",         cats = { defensives = true } },
    { id = 1966,     n = "Feint",                     class = "ROGUE",         cats = { defensives = true } },
    { id = 5277,     n = "Evasion",                   class = "ROGUE",         cats = { defensives = true } },
    { id = 442715,   n = "Blade Ward",                class = "DEMONHUNTER",   cats = { defensives = true } },
    { id = 212800,   n = "Blur",                      class = "DEMONHUNTER",   cats = { defensives = true } },
    { id = 434107,   alts = { 434105 }, n = "Vampiric Aura", class = "DEATHKNIGHT", off = true, cats = { defensives = true } },
    { id = 404381,   n = "Defy Fate",                 class = "EVOKER",        cats = { defensives = true } },
    { id = 374349,   n = "Renewing Blaze",            class = "EVOKER",        cats = { defensives = true } },
    { id = 455179,   n = "Elixir of Determination",   class = "MONK",          cats = { defensives = true } },
    { id = 378412,   n = "Light of the Titans",       class = "PALADIN",       cats = { defensives = true } },

    -- ------------------------------------------------------------
    -- Utility
    -- ------------------------------------------------------------
    { id = 2825,     n = "Bloodlust",                 class = "SHAMAN",        cats = { utility = true } },
    { id = 32182,    n = "Heroism",                   class = "SHAMAN",        cats = { utility = true } },
    { id = 80353,    n = "Time Warp",                 class = "MAGE",          cats = { utility = true } },
    { id = 390386,   n = "Fury of the Aspects",       class = "EVOKER",        cats = { utility = true } },
    { id = 264667,   alts = { 357650 }, n = "Primal Rage", class = "HUNTER", cats = { utility = true } },
    { id = 466904,   n = "Harrier's Cry",             class = "HUNTER",        cats = { utility = true } },
    { id = 115834,   alts = { 114018 }, n = "Shroud of Concealment", class = "ROGUE", cats = { utility = true } },
    { id = 34477,    alts = { 35079 }, n = "Misdirection", class = "HUNTER", cats = { utility = true } },
    { id = 1224098,  alts = { 57934, 59628 }, n = "Tricks of the Trade", class = "ROGUE", cats = { utility = true } },
    { id = 20707,    n = "Soulstone",                 class = "WARLOCK",       cats = { utility = true } },
    { id = 3714,     n = "Path of Frost",             class = "DEATHKNIGHT",   cats = { utility = true } },
    { id = 410318,   n = "Bestow Weyrnstone",         class = "EVOKER",        cats = { utility = true } },
    { id = 1243972,  n = "Void-touched Drums",        class = "ALL",           cats = { utility = true } },

    -- ------------------------------------------------------------
    -- Pet Buffs
    -- ------------------------------------------------------------
    { id = 186254,   alts = { 1235388, 1285912, 19574 }, n = "Bestial Wrath", class = "HUNTER", cats = { petBuffs = true } },
    { id = 118455,   alts = { 433984, 268877 }, n = "Beast Cleave", class = "HUNTER", cats = { petBuffs = true } },
    { id = 392054,   n = "Piercing Fangs",            class = "HUNTER",        off = true, cats = { petBuffs = true } },
    { id = 272790,   n = "Frenzy",                    class = "HUNTER",        cats = { petBuffs = true } },
    { id = 90361,    n = "Spirit Mend",               class = "HUNTER",        cats = { petBuffs = true } },
    { id = 1250772,  n = "Imp Gang Boss",             class = "WARLOCK",       cats = { petBuffs = true } },
    { id = 387552,   n = "Infernal Command",          class = "WARLOCK",       off = true, cats = { petBuffs = true } },
    { id = 108446,   n = "Soul Link",                 class = "WARLOCK",       off = true, cats = { petBuffs = true } },
    { id = 1233448,  alts = { 1235391 }, n = "Dark Transformation", class = "DEATHKNIGHT", cats = { petBuffs = true } },
    { id = 390264,   alts = { 390260 }, n = "Commander of the Dead", class = "DEATHKNIGHT", off = true, cats = { petBuffs = true } },
    { id = 211947,   n = "Dark Empowerment",          class = "DEATHKNIGHT",   cats = { petBuffs = true } },
    { id = 136,      alts = { 290819 }, n = "Mend Pet", class = "HUNTER", cats = { petBuffs = true } },

    -- ------------------------------------------------------------
    -- Racials
    -- ------------------------------------------------------------
    { id = 273104,   n = "Fireblood",                 class = "ALL",           cats = { racials = true } },
    { id = 59547,    alts = { 59542, 59543, 59544, 59545, 416250, 121093, 59548, 28880 }, n = "Gift of the Naaru", class = "ALL", cats = { racials = true } },
    { id = 65116,    n = "Stoneform",                 class = "ALL",           cats = { racials = true } },
    { id = 1238467,  n = "Thorn Bloom",               class = "ALL",           cats = { racials = true } },
    { id = 255654,   n = "Bull Rush",                 class = "ALL",           cats = { racials = true } },
    { id = 274739,   alts = { 274741, 274740, 274742 }, n = "Ancestral Call", class = "ALL", cats = { racials = true } },
    { id = 312924,   n = "Hyper Organic Light Originator", class = "ALL",           cats = { racials = true } },
    { id = 58984,    n = "Shadowmeld",                class = "ALL",           cats = { racials = true } },
    { id = 20572,    alts = { 33702, 33697 }, n = "Blood Fury", class = "ALL", cats = { racials = true } },
    { id = 26297,    n = "Berserking",                class = "ALL",           cats = { racials = true } },
    { id = 256948,   n = "Spatial Rift",              class = "ALL",           cats = { racials = true } },
    { id = 68992,    n = "Darkflight",                class = "ALL",           cats = { racials = true } },
    { id = 291944,   n = "Regeneratin'",              class = "ALL",           cats = { racials = true } },

    -- ------------------------------------------------------------
    -- Tier Set Auras
    -- ------------------------------------------------------------
    { id = 1310372,  n = "Blood Debt",                class = "DEATHKNIGHT",   cats = { tierSetAuras = true } },
    { id = 1297365,  n = "Freezing Tempest",          class = "DEATHKNIGHT",   cats = { tierSetAuras = true } },
    { id = 1302255,  n = "Genesis",                   class = "DRUID",         cats = { tierSetAuras = true } },
    { id = 1301286,  n = "Gorestained Claws",         class = "DRUID",         cats = { tierSetAuras = true } },
    { id = 1301600,  n = "Halazzi's Fury",            class = "DRUID",         cats = { tierSetAuras = true } },
    { id = 1247577,  alts = { 1301768 }, n = "Akil'zon's Clarity", class = "DRUID", cats = { tierSetAuras = true } },
    { id = 1297728,  n = "Magnified Fate",            class = "EVOKER",        cats = { tierSetAuras = true } },
    { id = 1299389,  n = "Cobra Fang",                class = "HUNTER",        cats = { tierSetAuras = true } },
    { id = 1296930,  n = "Cumulative Power",          class = "MAGE",          cats = { tierSetAuras = true } },
    { id = 1310248,  n = "Rapid Refreezing",          class = "MAGE",          cats = { tierSetAuras = true } },
    { id = 1296687,  n = "Rising Sun Kick",           class = "MONK",          cats = { tierSetAuras = true } },
    { id = 1297033,  n = "Unbroken Rhythm",           class = "MONK",          cats = { tierSetAuras = true } },
    { id = 1305230,  n = "Divine Power",              class = "PALADIN",       cats = { tierSetAuras = true } },
    { id = 1306118,  n = "Renewed Haste",             class = "PRIEST",        cats = { tierSetAuras = true } },
    { id = 1307795,  n = "Dark Transference",         class = "PRIEST",        cats = { tierSetAuras = true } },
    { id = 1300642,  n = "Condensation",              class = "SHAMAN",        cats = { tierSetAuras = true } },
    { id = 1300219,  n = "Flowing Elements",          class = "SHAMAN",        cats = { tierSetAuras = true } },
    { id = 1300222,  n = "Overcharge!",               class = "SHAMAN",        cats = { tierSetAuras = true } },
    { id = 1299991,  n = "Short Circuit",             class = "SHAMAN",        cats = { tierSetAuras = true } },
    { id = 1305774,  n = "Unstable Empowerment",      class = "WARLOCK",       cats = { tierSetAuras = true } },
    { id = 1300681,  n = "Vengeful Shield",           class = "WARRIOR",       cats = { tierSetAuras = true } },
    { id = 1300670,  n = "Winding Up",                class = "WARRIOR",       cats = { tierSetAuras = true } },

    -- ------------------------------------------------------------
    -- Consumables
    -- ------------------------------------------------------------
    { id = 1236998,  n = "Draught of Rampant Abandon", class = "ALL",           cats = { consumables = true } },
    { id = 1236616,  n = "Light's Potential",         class = "ALL",           cats = { consumables = true } },
    { id = 1235568,  n = "Light's Preservation",      class = "ALL",           cats = { consumables = true } },
    { id = 1239479,  n = "Potion of Devoured Dreams", class = "ALL",           cats = { consumables = true } },
    { id = 1236994,  n = "Potion of Recklessness",    class = "ALL",           cats = { consumables = true } },

    -- ------------------------------------------------------------
    -- Trinkets & Items
    -- ------------------------------------------------------------
    { id = 1250587,  n = "Binding Flame",             class = "ALL",           cats = { trinketsItems = true } },
    { id = 1272482,  n = "Cosmic Bell",               class = "ALL",           cats = { trinketsItems = true } },
    { id = 1250533,  n = "Freightrunner's Flask",     class = "ALL",           cats = { trinketsItems = true } },
    { id = 1295885,  alts = { 1307470 }, n = "Hex Lord's Dooming Idol", class = "ALL", cats = { trinketsItems = true } },
    { id = 1262496,  n = "Light Company Guidon",      class = "ALL",           cats = { trinketsItems = true } },
    { id = 1295275,  alts = { 1294745 }, n = "The King's Unyielding Wind", class = "ALL", cats = { trinketsItems = true } },
    { id = 1272460,  n = "Ultradon Cuirass",          class = "ALL",           cats = { trinketsItems = true } },
    { id = 1250557,  n = "Void Execution Mandate",    class = "ALL",           cats = { trinketsItems = true } },
    { id = 1297761,  n = "Voracious Heart of Ula'tek", class = "ALL",           cats = { trinketsItems = true } },
    { id = 1308013,  alts = { 1292300, 1308014, 1292299, 1308012, 1306870 }, n = "Gebbo's Bottomless Bag", class = "ALL", cats = { trinketsItems = true } },
    { id = 1266182,  n = "Lost Idol of The Hash'ey",  class = "ALL",           cats = { trinketsItems = true } },
    { id = 387028,   n = "Burning Embers",            class = "ALL",           cats = { trinketsItems = true } },
    { id = 1264404,  n = "Cosmic Siphon",             class = "ALL",           cats = { trinketsItems = true } },
    { id = 1265323,  n = "Despair",                   class = "ALL",           cats = { trinketsItems = true } },
    { id = 1295582,  n = "Keeper's Seething Core",    class = "ALL",           cats = { trinketsItems = true } },
    { id = 1263727,  n = "Litany of Lightblind Wrath", class = "ALL",           cats = { trinketsItems = true } },
    { id = 1305846,  n = "Preternatural Antivenom",   class = "ALL",           cats = { trinketsItems = true } },
    { id = 1254624,  n = "Radiant Blessing",          class = "ALL",           cats = { trinketsItems = true } },
    { id = 1266403,  n = "Sacred Duty",               class = "ALL",           cats = { trinketsItems = true } },
    { id = 1303479,  n = "Vashniks's Sanguine Rancor", class = "ALL",           cats = { trinketsItems = true } },
    { id = 1263644,  n = "Seed of Radiant Hope",      class = "ALL",           cats = { trinketsItems = true } },
    { id = 1307578,  alts = { 1291894 }, n = "Soulcoiler Ritual Vessel", class = "ALL", cats = { trinketsItems = true } },
    { id = 1295057,  n = "Wavecaller's Seastone",     class = "ALL",           cats = { trinketsItems = true } },
    { id = 1255200,  n = "Unstable Felheart Crystal", class = "ALL",           cats = { trinketsItems = true } },
    { id = 1254180,  n = "Xathuux's Last Roar",       class = "ALL",           cats = { trinketsItems = true } },
    { id = 1293316,  n = "Empowering Venom",          class = "ALL",           cats = { trinketsItems = true } },
    { id = 1253114,  n = "Ever-collapsing Void Fissure", class = "ALL",           cats = { trinketsItems = true } },
    { id = 1295649,  n = "Bolstering Gale",           class = "ALL",           cats = { trinketsItems = true } },
    { id = 1294941,  n = "Curse of the Wound",        class = "ALL",           cats = { trinketsItems = true } },
    { id = 1254331,  n = "Echoing Roar",              class = "ALL",           cats = { trinketsItems = true } },
    { id = 1276677,  n = "Fiber of Living Agony",     class = "ALL",           cats = { trinketsItems = true } },
    { id = 1306822,  n = "Imminent Gale",             class = "ALL",           cats = { trinketsItems = true } },
    { id = 1305360,  n = "Soul Fang Alacrity",        class = "ALL",           cats = { trinketsItems = true } },
    { id = 1294330,  n = "Spirit Ward",               class = "ALL",           cats = { trinketsItems = true } },
    { id = 1307910,  n = "Venomcursed Critical Strike", class = "ALL",           cats = { trinketsItems = true } },
    { id = 1307927,  n = "Venomcursed Haste",         class = "ALL",           cats = { trinketsItems = true } },
    { id = 1229746,  n = "Arcanoweave Insight",       class = "ALL",           cats = { trinketsItems = true } },
    { id = 1285161,  n = "Protective Toadstools",     class = "ALL",           cats = { trinketsItems = true } },
    { id = 1242003,  n = "Worldsoul Cradle",          class = "ALL",           cats = { trinketsItems = true } },
}

-- ============================================================
-- INDEXES (built once at load)
-- ============================================================
R.ByID = {}
R.ByCategory = {}
for _, cat in ipairs(R.Categories) do R.ByCategory[cat.key] = {} end

for _, rec in ipairs(R.Spells) do
    R.ByID[rec.id] = rec
    if rec.alts then
        for _, alt in ipairs(rec.alts) do R.ByID[alt] = rec end
    end
    for catKey in pairs(rec.cats) do
        local bucket = R.ByCategory[catKey]
        if bucket then bucket[#bucket + 1] = rec end
    end
end
