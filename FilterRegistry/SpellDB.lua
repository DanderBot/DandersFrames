local addonName, DF = ...

-- ============================================================
-- FILTER REGISTRY — SHIPPED SPELL DATABASE
-- Curated spell records for the buff filter presets. Source:
-- WCL harvest (lab discussion ee16e59f-d4c9-4680-b2ca-17a754a3e102),
-- 280 spells / 11 categories. One record per SPELL; alts carry
-- every other known spellID for the same spell. `n` is an
-- English fallback name — display prefers C_Spell at runtime.
-- `off = true` ships the spell disabled-by-default (still listed
-- in the Filter Designer). Regenerate per patch from the WCL
-- pipeline; bump DBStamp when you do.
-- ============================================================

local pairs, ipairs = pairs, ipairs

DF.FilterRegistry = DF.FilterRegistry or {}
local R = DF.FilterRegistry

R.DBStamp = { harvest = "2026-07-11", gameBuild = 68569 }

-- Sidebar/list display order. `name` keys are looked up through L at
-- display time (Options code does L[cat.name]); keep them stable.
R.Categories = {
    { key = "healing",            name = "Per-spec Healing" },
    { key = "raidBuffs",          name = "Raid Buffs" },
    { key = "raidDefensives",     name = "Raid Defensives" },
    { key = "externalDefensives", name = "External Defensives" },
    { key = "defensives",         name = "Defensives" },
    { key = "powerExternals",     name = "Power Externals" },
    { key = "movement",           name = "Movement" },
    { key = "utility",            name = "Utility" },
    { key = "consumables",        name = "Consumables" },
    { key = "trinketsItems",      name = "Trinkets & Items" },
    { key = "petBuffs",           name = "Pet Buffs" },
}

-- Records are grouped by the section they FIRST appear in within the
-- source data; multi-category spells carry every category in `cats`.
R.Spells = {
    -- ------------------------------------------------------------
    -- Per-spec Healing
    -- ------------------------------------------------------------
    { id = 774,     alts = { 419204 }, n = "Rejuvenation", class = "DRUID", cats = { healing = true } },
    { id = 8936,    alts = { 419287 }, n = "Regrowth", class = "DRUID", cats = { healing = true } },
    { id = 33763,   alts = { 419207 }, n = "Lifebloom", class = "DRUID", cats = { healing = true } },
    { id = 155777,  n = "Germination",              class = "DRUID",   cats = { healing = true } },
    { id = 48438,   alts = { 419344, 422382 }, n = "Wild Growth", class = "DRUID", cats = { healing = true } },
    { id = 474754,  alts = { 474750 }, n = "Symbiotic Relationship", class = "DRUID", cats = { healing = true } },
    { id = 439530,  n = "Symbiotic Blooms",         class = "DRUID",   cats = { healing = true } },
    { id = 102342,  n = "Ironbark",                 class = "DRUID",   cats = { healing = true, externalDefensives = true } },
    { id = 17,      alts = { 1246768, 1254306, 1300008 }, n = "Power Word: Shield", class = "PRIEST", cats = { healing = true, externalDefensives = true } },
    { id = 194384,  n = "Atonement",                class = "PRIEST",  cats = { healing = true } },
    { id = 1253593, alts = { 1300009 }, n = "Void Shield", class = "PRIEST", cats = { healing = true } },
    { id = 41635,   n = "Prayer of Mending",        class = "PRIEST",  cats = { healing = true } },
    { id = 33206,   n = "Pain Suppression",         class = "PRIEST",  cats = { healing = true, externalDefensives = true } },
    { id = 10060,   n = "Power Infusion",           class = "PRIEST",  cats = { healing = true, powerExternals = true } },
    { id = 139,     n = "Renew",                    class = "PRIEST",  cats = { healing = true } },
    { id = 77489,   n = "Echo of Light",            class = "PRIEST",  cats = { healing = true } },
    { id = 47788,   n = "Guardian Spirit",          class = "PRIEST",  cats = { healing = true, externalDefensives = true } },
    { id = 119611,  n = "Renewing Mist",            class = "MONK",    cats = { healing = true } },
    { id = 124682,  n = "Enveloping Mist",          class = "MONK",    cats = { healing = true } },
    { id = 115175,  alts = { 1260617, 198533 }, n = "Soothing Mist", class = "MONK", cats = { healing = true } },
    { id = 450769,  n = "Aspect of Harmony",        class = "MONK",    cats = { healing = true } },
    { id = 116849,  n = "Life Cocoon",              class = "MONK",    cats = { healing = true, externalDefensives = true } },
    { id = 443113,  n = "Strength of the Black Ox", class = "MONK",    cats = { healing = true, externalDefensives = true } },
    { id = 61295,   n = "Riptide",                  class = "SHAMAN",  cats = { healing = true } },
    { id = 383648,  alts = { 974 }, n = "Earth Shield", class = "SHAMAN", cats = { healing = true } },
    { id = 207400,  n = "Ancestral Vigor",          class = "SHAMAN",  cats = { healing = true } },
    { id = 382024,  n = "Earthliving Weapon",       class = "SHAMAN",  cats = { healing = true } },
    { id = 444490,  n = "Hydrobubble",              class = "SHAMAN",  cats = { healing = true } },
    { id = 156910,  n = "Beacon of Faith",          class = "PALADIN", cats = { healing = true } },
    { id = 156322,  alts = { 461432 }, n = "Eternal Flame", class = "PALADIN", cats = { healing = true } },
    { id = 53563,   n = "Beacon of Light",          class = "PALADIN", cats = { healing = true, externalDefensives = true } },
    { id = 1244893, alts = { 1245369 }, n = "Beacon of the Savior", class = "PALADIN", cats = { healing = true } },
    { id = 200025,  n = "Beacon of Virtue",         class = "PALADIN", cats = { healing = true } },
    { id = 1022,    alts = { 1309794 }, n = "Blessing of Protection", class = "PALADIN", cats = { healing = true, externalDefensives = true } },
    { id = 432502,  n = "Sacred Weapon",            class = "PALADIN", cats = { healing = true } },
    { id = 6940,    n = "Blessing of Sacrifice",    class = "PALADIN", cats = { healing = true, externalDefensives = true } },
    { id = 1044,    alts = { 299256 }, n = "Blessing of Freedom", class = "PALADIN", cats = { healing = true, movement = true } },
    { id = 431381,  n = "Dawnlight",                class = "PALADIN", cats = { healing = true } },
    { id = 364343,  n = "Echo",                     class = "EVOKER",  cats = { healing = true } },
    { id = 366155,  n = "Reversion",                class = "EVOKER",  cats = { healing = true } },
    { id = 367364,  n = "Echo: Reversion",          class = "EVOKER",  cats = { healing = true } },
    { id = 355941,  n = "Dream Breath",             class = "EVOKER",  cats = { healing = true } },
    { id = 376788,  n = "Echo: Dream Breath",       class = "EVOKER",  cats = { healing = true } },
    { id = 363502,  alts = { 359816 }, n = "Dream Flight", class = "EVOKER", cats = { healing = true, raidDefensives = true } },
    { id = 373267,  n = "Lifebind",                 class = "EVOKER",  cats = { healing = true } },
    { id = 357170,  n = "Time Dilation",            class = "EVOKER",  cats = { healing = true, externalDefensives = true } },
    { id = 363534,  n = "Rewind",                   class = "EVOKER",  cats = { healing = true, raidDefensives = true } },
    { id = 409895,  n = "Verdant Embrace",          class = "EVOKER",  cats = { healing = true } },
    { id = 445740,  n = "Enkindle",                 class = "EVOKER",  cats = { healing = true } },
    { id = 432607,  alts = { 432496 }, n = "Holy Bulwark", class = "PALADIN", cats = { healing = true } },
    { id = 1291636, n = "Temporal Barrier",         class = "EVOKER",  cats = { healing = true } },
    { id = 47753,   n = "Divine Aegis",             class = "PRIEST",  cats = { healing = true } },
    { id = 373862,  n = "Temporal Anomaly",         class = "EVOKER",  cats = { healing = true } },
    { id = 409678,  n = "Chrono Ward",              class = "EVOKER",  cats = { healing = true } },
    { id = 431415,  n = "Sun Sear",                 class = "PALADIN", cats = { healing = true } },
    { id = 1278914, n = "Dream Guide",              class = "DRUID",   cats = { healing = true } },
    { id = 390677,  n = "Inspiration",              class = "PRIEST",  cats = { healing = true } },
    { id = 1301739, n = "Blessed Word",             class = "PALADIN", cats = { healing = true } },
    { id = 1239091, n = "Lesser Weapon",            class = "PALADIN", cats = { healing = true } },
    { id = 1239002, n = "Lesser Bulwark",           class = "PALADIN", cats = { healing = true } },
    { id = 414407,  n = "Veneration",               class = "PALADIN", cats = { healing = true } },
    { id = 1241866, n = "Glistening Radiance",      class = "PALADIN", cats = { healing = true } },
    { id = 431907,  n = "Sun's Avatar",             class = "PALADIN", cats = { healing = true } },
    { id = 453846,  n = "Resonant Energy",          class = "PRIEST",  cats = { healing = true } },
    { id = 469703,  n = "Tempered in Battle",       class = "PALADIN", cats = { healing = true } },

    -- ------------------------------------------------------------
    -- Raid Buffs
    -- ------------------------------------------------------------
    { id = 1459,    n = "Arcane Intellect",         class = "MAGE",    cats = { raidBuffs = true } },
    { id = 21562,   n = "Power Word: Fortitude",    class = "PRIEST",  cats = { raidBuffs = true } },
    { id = 6673,    n = "Battle Shout",             class = "WARRIOR", cats = { raidBuffs = true } },
    { id = 1126,    n = "Mark of the Wild",         class = "DRUID",   cats = { raidBuffs = true } },
    { id = 462854,  n = "Skyfury",                  class = "SHAMAN",  cats = { raidBuffs = true } },
    { id = 381748,  alts = { 381732, 381741, 381746, 381749, 381750, 381751, 381752, 381753, 381754, 381756, 381757, 381758 },
      n = "Blessing of the Bronze", class = "EVOKER", cats = { raidBuffs = true } },
    { id = 465,     n = "Devotion Aura",            class = "PALADIN", cats = { raidBuffs = true } },
    { id = 32223,   n = "Crusader Aura",            class = "PALADIN", cats = { raidBuffs = true } },
    { id = 317920,  n = "Concentration Aura",       class = "PALADIN", cats = { raidBuffs = true } },

    -- ------------------------------------------------------------
    -- Raid Defensives
    -- ------------------------------------------------------------
    { id = 97463,   alts = { 97462 }, n = "Rallying Cry", class = "WARRIOR", cats = { raidDefensives = true } },
    { id = 145629,  alts = { 51052 }, n = "Anti-Magic Zone", class = "DEATHKNIGHT", cats = { raidDefensives = true } },
    { id = 209426,  alts = { 196718 }, n = "Darkness", class = "DEMONHUNTER", cats = { raidDefensives = true } },
    { id = 81782,   alts = { 62618 }, n = "Power Word: Barrier", class = "PRIEST", cats = { raidDefensives = true } },
    { id = 64843,   alts = { 64844 }, n = "Divine Hymn", class = "PRIEST", cats = { raidDefensives = true } },
    { id = 200183,  n = "Apotheosis",               class = "PRIEST",  cats = { raidDefensives = true } },
    { id = 15286,   n = "Vampiric Embrace",         class = "PRIEST",  cats = { raidDefensives = true } },
    { id = 421453,  n = "Ultimate Penitence",       class = "PRIEST",  cats = { raidDefensives = true } },
    { id = 120517,  n = "Halo",                     class = "PRIEST",  cats = { raidDefensives = true } },
    { id = 31821,   alts = { 317929 }, n = "Aura Mastery", class = "PALADIN", cats = { raidDefensives = true } },
    { id = 31884,   n = "Avenging Wrath",           class = "PALADIN", cats = { raidDefensives = true } },
    { id = 216331,  n = "Avenging Crusader",        class = "PALADIN", cats = { raidDefensives = true } },
    { id = 200652,  alts = { 200654 }, n = "Tyr's Deliverance", class = "PALADIN", cats = { raidDefensives = true } },
    { id = 325174,  alts = { 98008 }, n = "Spirit Link Totem", class = "SHAMAN", cats = { raidDefensives = true } },
    { id = 108280,  n = "Healing Tide Totem",       class = "SHAMAN",  cats = { raidDefensives = true } },
    { id = 5394,    n = "Healing Stream Totem",     class = "SHAMAN",  cats = { raidDefensives = true } },
    { id = 114052,  n = "Ascendance",               class = "SHAMAN",  cats = { raidDefensives = true } },
    { id = 198103,  n = "Earth Elemental",          class = "SHAMAN",  cats = { raidDefensives = true } },
    { id = 383013,  n = "Poison Cleansing Totem",   class = "SHAMAN",  cats = { raidDefensives = true } },
    { id = 740,     alts = { 157982 }, n = "Tranquility", class = "DRUID", cats = { raidDefensives = true } },
    { id = 374227,  n = "Zephyr",                   class = "EVOKER",  cats = { raidDefensives = true } },
    { id = 322118,  n = "Invoke Yu'lon",            class = "MONK",    cats = { raidDefensives = true } },
    { id = 325197,  n = "Invoke Chi-Ji",            class = "MONK",    cats = { raidDefensives = true } },
    { id = 443028,  n = "Celestial Conduit",        class = "MONK",    cats = { raidDefensives = true } },
    { id = 462568,  n = "Elemental Resistance",     class = "SHAMAN",  cats = { raidDefensives = true } },
    { id = 1260681, alts = { 406139, 406220 }, n = "Chi Cocoon", class = "MONK", cats = { raidDefensives = true } },
    { id = 211210,  n = "Protection of Tyr",        class = "PALADIN", cats = { raidDefensives = true } },

    -- ------------------------------------------------------------
    -- Movement
    -- ------------------------------------------------------------
    { id = 48265,   n = "Death's Advance",          class = "DEATHKNIGHT", cats = { movement = true } },
    { id = 212552,  n = "Wraith Walk",              class = "DEATHKNIGHT", cats = { movement = true } },
    { id = 457343,  n = "Death's Arrival",          class = "ROGUE",   cats = { movement = true } },
    { id = 389847,  n = "Felfire Haste",            class = "DEMONHUNTER", cats = { movement = true } },
    { id = 1850,    n = "Dash",                     class = "DRUID",   cats = { movement = true } },
    { id = 252216,  n = "Tiger Dash",               class = "DRUID",   cats = { movement = true } },
    { id = 106898,  alts = { 77761, 77764 }, n = "Stampeding Roar", class = "DRUID", cats = { movement = true } },
    { id = 400126,  n = "Forestwalk",               class = "DRUID",   cats = { movement = true } },
    { id = 449609,  n = "Lighter Than Air",         class = "MONK",    cats = { movement = true } },
    { id = 406732,  alts = { 406789 }, n = "Spatial Paradox", class = "EVOKER", cats = { movement = true } },
    { id = 375226,  n = "Time Spiral",              class = "EVOKER",  cats = { movement = true } },
    { id = 370665,  n = "Rescue",                   class = "EVOKER",  cats = { movement = true } },
    { id = 431698,  n = "Temporal Burst",           class = "EVOKER",  cats = { movement = true } },
    { id = 432061,  n = "Motes of Acceleration",    class = "EVOKER",  cats = { movement = true } },
    { id = 452701,  n = "Roar from the Heavens",    class = "MONK",    cats = { movement = true } },
    { id = 186257,  n = "Aspect of the Cheetah",    class = "HUNTER",  cats = { movement = true } },
    { id = 118922,  n = "Posthaste",                class = "HUNTER",  cats = { movement = true } },
    { id = 1224810, alts = { 54216 }, n = "Master's Call", class = "HUNTER", cats = { movement = true } },
    { id = 382294,  n = "Incantation of Swiftness", class = "MAGE",    cats = { movement = true } },
    { id = 444754,  n = "Slippery Slinging",        class = "MAGE",    cats = { movement = true } },
    { id = 119085,  n = "Chi Torpedo",              class = "MONK",    cats = { movement = true } },
    { id = 101545,  n = "Flying Serpent Kick",      class = "MONK",    cats = { movement = true } },
    { id = 116841,  n = "Tiger's Lust",             class = "MONK",    cats = { movement = true } },
    { id = 443569,  n = "Chi-Ji's Swiftness",       class = "MONK",    cats = { movement = true } },
    { id = 276111,  n = "Divine Steed",             class = "PALADIN", cats = { movement = true } },
    { id = 431752,  n = "Will of the Dawn",         class = "PALADIN", cats = { movement = true } },
    { id = 121557,  n = "Angelic Feather",          class = "PRIEST",  cats = { movement = true } },
    { id = 65081,   n = "Body and Soul",            class = "PRIEST",  cats = { movement = true } },
    { id = 73325,   n = "Leap of Faith",            class = "PRIEST",  cats = { movement = true } },
    { id = 355851,  n = "Blaze of Light",           class = "PRIEST",  cats = { movement = true } },
    { id = 47585,   n = "Dispersion",               class = "PRIEST",  cats = { movement = true, defensives = true } },
    { id = 2983,    n = "Sprint",                   class = "ROGUE",   cats = { movement = true } },
    { id = 36554,   n = "Shadowstep",               class = "ROGUE",   cats = { movement = true } },
    { id = 2645,    n = "Ghost Wolf",               class = "SHAMAN",  cats = { movement = true } },
    { id = 58875,   n = "Spirit Walk",              class = "SHAMAN",  cats = { movement = true } },
    { id = 79206,   n = "Spiritwalker's Grace",     class = "SHAMAN",  cats = { movement = true } },
    { id = 192082,  n = "Wind Rush",                class = "SHAMAN",  cats = { movement = true } },
    { id = 378076,  n = "Thunderous Paws",          class = "SHAMAN",  cats = { movement = true } },
    { id = 111400,  n = "Burning Rush",             class = "WARLOCK", cats = { movement = true } },
    { id = 387633,  n = "Soulburn: Demonic Circle", class = "WARLOCK", cats = { movement = true } },
    { id = 202164,  n = "Bounding Stride",          class = "WARRIOR", cats = { movement = true } },
    { id = 18499,   n = "Berserker Rage",           class = "WARRIOR", cats = { movement = true } },
    { id = 446044,  n = "Relentless Pursuit",       class = "WARRIOR", cats = { movement = true } },
    { id = 262232,  n = "War Machine",              class = "WARRIOR", cats = { movement = true } },
    { id = 434029,  n = "Vampiric Speed",           class = "DEATHKNIGHT", cats = { movement = true } },

    -- ------------------------------------------------------------
    -- Power Externals
    -- ------------------------------------------------------------
    { id = 29166,   n = "Innervate",                class = "DRUID",   cats = { powerExternals = true } },
    { id = 410089,  n = "Prescience",               class = "EVOKER",  cats = { powerExternals = true } },
    { id = 395152,  n = "Ebon Might",               class = "EVOKER",  cats = { powerExternals = true } },
    { id = 413984,  n = "Shifting Sands",           class = "EVOKER",  cats = { powerExternals = true } },
    { id = 360827,  n = "Blistering Scales",        class = "EVOKER",  cats = { powerExternals = true } },
    { id = 410263,  n = "Inferno's Blessing",       class = "EVOKER",  cats = { powerExternals = true } },
    { id = 410686,  n = "Symbiotic Bloom",          class = "EVOKER",  cats = { powerExternals = true } },
    { id = 369459,  n = "Source of Magic",          class = "EVOKER",  cats = { powerExternals = true } },

    -- ------------------------------------------------------------
    -- External Defensives
    -- ------------------------------------------------------------
    { id = 204018,  n = "Blessing of Spellwarding", class = "PALADIN", cats = { externalDefensives = true } },
    { id = 387804,  n = "Echoing Protection",       class = "PALADIN", cats = { externalDefensives = true } },
    { id = 53480,   n = "Roar of Sacrifice",        class = "HUNTER",  cats = { externalDefensives = true } },
    { id = 370889,  alts = { 370888 }, n = "Twin Guardian", class = "EVOKER", cats = { externalDefensives = true } },
    { id = 1241717, n = "Seraphic Barrier",         class = "PALADIN", cats = { externalDefensives = true } },
    { id = 454863,  n = "Lesser Anti-Magic Shell",  class = "DEATHKNIGHT", cats = { externalDefensives = true } },
    { id = 461499,  n = "Overflowing Light",        class = "PALADIN", cats = { externalDefensives = true } },

    -- ------------------------------------------------------------
    -- Defensives
    -- ------------------------------------------------------------
    { id = 190456,  n = "Ignore Pain",              class = "WARRIOR", cats = { defensives = true } },
    { id = 118038,  n = "Die by the Sword",         class = "WARRIOR", cats = { defensives = true } },
    { id = 23920,   n = "Spell Reflection",         class = "WARRIOR", cats = { defensives = true } },
    { id = 386208,  n = "Defensive Stance",         class = "WARRIOR", cats = { defensives = true } },
    { id = 184364,  n = "Enraged Regeneration",     class = "WARRIOR", cats = { defensives = true } },
    { id = 147833,  n = "Intervene",                class = "WARRIOR", cats = { defensives = true } },
    { id = 642,     n = "Divine Shield",            class = "PALADIN", cats = { defensives = true } },
    { id = 498,     n = "Divine Protection",        class = "PALADIN", cats = { defensives = true } },
    { id = 184662,  n = "Shield of Vengeance",      class = "PALADIN", cats = { defensives = true } },
    { id = 461867,  n = "Sacrosanct Crusade",       class = "PALADIN", cats = { defensives = true } },
    { id = 209388,  n = "Bulwark of Order",         class = "PALADIN", cats = { defensives = true } },
    { id = 157128,  n = "Saved by the Light",       class = "PALADIN", cats = { defensives = true } },
    { id = 48792,   n = "Icebound Fortitude",       class = "DEATHKNIGHT", cats = { defensives = true } },
    { id = 48707,   alts = { 444741 }, n = "Anti-Magic Shell", class = "DEATHKNIGHT", cats = { defensives = true } },
    { id = 49039,   n = "Lichborne",                class = "DEATHKNIGHT", cats = { defensives = true } },
    { id = 45438,   n = "Ice Block",                class = "MAGE",    cats = { defensives = true } },
    { id = 414658,  n = "Ice Cold",                 class = "MAGE",    cats = { defensives = true } },
    { id = 235450,  n = "Prismatic Barrier",        class = "MAGE",    cats = { defensives = true } },
    { id = 235313,  n = "Blazing Barrier",          class = "MAGE",    cats = { defensives = true } },
    { id = 11426,   n = "Ice Barrier",              class = "MAGE",    cats = { defensives = true } },
    { id = 66,      n = "Invisibility",             class = "MAGE",    cats = { defensives = true } },
    { id = 110960,  alts = { 113862 }, n = "Greater Invisibility", class = "MAGE", cats = { defensives = true } },
    { id = 55342,   n = "Mirror Image",             class = "MAGE",    cats = { defensives = true } },
    { id = 342246,  n = "Alter Time",               class = "MAGE",    cats = { defensives = true } },
    { id = 19236,   n = "Desperate Prayer",         class = "PRIEST",  cats = { defensives = true } },
    { id = 586,     n = "Fade",                     class = "PRIEST",  cats = { defensives = true } },
    { id = 45242,   n = "Focused Will",             class = "PRIEST",  cats = { defensives = true } },
    { id = 193065,  n = "Protective Light",         class = "PRIEST",  cats = { defensives = true } },
    { id = 114216,  alts = { 114214 }, n = "Angelic Bulwark", class = "PRIEST", cats = { defensives = true } },
    { id = 22812,   n = "Barkskin",                 class = "DRUID",   cats = { defensives = true } },
    { id = 61336,   n = "Survival Instincts",       class = "DRUID",   cats = { defensives = true } },
    { id = 22842,   n = "Frenzied Regeneration",    class = "DRUID",   cats = { defensives = true } },
    { id = 192081,  n = "Ironfur",                  class = "DRUID",   cats = { defensives = true } },
    { id = 393903,  n = "Ursine Vigor",             class = "DRUID",   cats = { defensives = true } },
    { id = 5487,    n = "Bear Form",                class = "DRUID",   cats = { defensives = true } },
    { id = 363916,  n = "Obsidian Scales",          class = "EVOKER",  cats = { defensives = true } },
    { id = 115203,  n = "Fortifying Brew",          class = "MONK",    cats = { defensives = true } },
    { id = 122783,  n = "Diffuse Magic",            class = "MONK",    cats = { defensives = true } },
    { id = 108271,  n = "Astral Shift",             class = "SHAMAN",  cats = { defensives = true } },
    { id = 457387,  n = "Wind Barrier",             class = "SHAMAN",  cats = { defensives = true } },
    { id = 186265,  n = "Aspect of the Turtle",     class = "HUNTER",  cats = { defensives = true } },
    { id = 264735,  n = "Survival of the Fittest",  class = "HUNTER",  cats = { defensives = true } },
    { id = 472708,  n = "Shell Cover",              class = "HUNTER",  cats = { defensives = true } },
    { id = 104773,  n = "Unending Resolve",         class = "WARLOCK", cats = { defensives = true } },
    { id = 108416,  n = "Dark Pact",                class = "WARLOCK", cats = { defensives = true } },
    { id = 387847,  n = "Fel Armor",                class = "WARLOCK", cats = { defensives = true } },
    { id = 108366,  n = "Soul Leech",               class = "WARLOCK", cats = { defensives = true } },
    { id = 427912,  alts = { 258920 }, n = "Infernal Armor", class = "DEMONHUNTER", cats = { defensives = true } },
    { id = 1266616, alts = { 394933 }, n = "Demon Muzzle", class = "DEMONHUNTER", cats = { defensives = true } },
    { id = 31224,   n = "Cloak of Shadows",         class = "ROGUE",   cats = { defensives = true } },
    { id = 1966,    n = "Feint",                    class = "ROGUE",   cats = { defensives = true } },
    { id = 5277,    n = "Evasion",                  class = "ROGUE",   cats = { defensives = true } },
    { id = 442715,  n = "Blade Ward",               class = "DEMONHUNTER", cats = { defensives = true } },
    { id = 212800,  n = "Blur",                     class = "DEMONHUNTER", cats = { defensives = true } },
    { id = 434107,  n = "Vampiric Aura",            class = "DEATHKNIGHT", cats = { defensives = true } },
    { id = 404381,  n = "Defy Fate",                class = "EVOKER",  cats = { defensives = true } },
    { id = 374349,  n = "Renewing Blaze",           class = "EVOKER",  cats = { defensives = true } },
    { id = 455179,  n = "Elixir of Determination",  class = "MONK",    cats = { defensives = true } },

    -- ------------------------------------------------------------
    -- Utility
    -- ------------------------------------------------------------
    { id = 2825,    n = "Bloodlust",                class = "SHAMAN",  cats = { utility = true } },
    { id = 32182,   n = "Heroism",                  class = "SHAMAN",  cats = { utility = true } },
    { id = 80353,   n = "Time Warp",                class = "MAGE",    cats = { utility = true } },
    { id = 390386,  n = "Fury of the Aspects",      class = "EVOKER",  cats = { utility = true } },
    { id = 264667,  alts = { 357650 }, n = "Primal Rage", class = "HUNTER", cats = { utility = true } },
    { id = 466904,  n = "Harrier's Cry",            class = "HUNTER",  cats = { utility = true } },
    { id = 115834,  n = "Shroud of Concealment",    class = "ROGUE",   cats = { utility = true } },
    { id = 34477,   n = "Misdirection",             class = "HUNTER",  cats = { utility = true } },
    { id = 1224098, alts = { 57934 }, n = "Tricks of the Trade", class = "ROGUE", cats = { utility = true } },
    { id = 20707,   n = "Soulstone",                class = "WARLOCK", cats = { utility = true } },

    -- ------------------------------------------------------------
    -- Pet Buffs
    -- ------------------------------------------------------------
    { id = 186254,  alts = { 1235388, 1285912 }, n = "Bestial Wrath", class = "HUNTER", cats = { petBuffs = true } },
    { id = 118455,  alts = { 433984 }, n = "Beast Cleave", class = "HUNTER", cats = { petBuffs = true } },
    { id = 392054,  n = "Piercing Fangs",           class = "HUNTER",  cats = { petBuffs = true } },
    { id = 272790,  n = "Frenzy",                   class = "HUNTER",  cats = { petBuffs = true } },
    { id = 90361,   n = "Spirit Mend",              class = "HUNTER",  cats = { petBuffs = true } },
    { id = 1250772, n = "Imp Gang Boss",            class = "WARLOCK", cats = { petBuffs = true } },
    { id = 387552,  n = "Infernal Command",         class = "WARLOCK", cats = { petBuffs = true } },
    { id = 108446,  n = "Soul Link",                class = "WARLOCK", cats = { petBuffs = true } },
    { id = 1233448, n = "Dark Transformation",      class = "DEATHKNIGHT", cats = { petBuffs = true } },
    { id = 390264,  n = "Commander of the Dead",    class = "DEATHKNIGHT", cats = { petBuffs = true } },
    { id = 211947,  n = "Dark Empowerment",         class = "DEATHKNIGHT", cats = { petBuffs = true } },

    -- ------------------------------------------------------------
    -- Consumables
    -- ------------------------------------------------------------
    { id = 1235111, n = "Flask of the Shattered Sun", class = "ALL", cats = { consumables = true } },
    { id = 1235108, n = "Flask of the Magisters",   class = "ALL",     cats = { consumables = true } },
    { id = 1235110, n = "Flask of the Blood Knights", class = "ALL",   cats = { consumables = true } },
    { id = 1235057, n = "Flask of Thalassian Resistance", class = "ALL", cats = { consumables = true } },
    { id = 1236994, n = "Potion of Recklessness",   class = "ALL",     cats = { consumables = true } },
    { id = 1236998, n = "Draught of Rampant Abandon", class = "ALL",   cats = { consumables = true } },
    { id = 1287772, n = "Rune of Critical Power",   class = "ALL",     cats = { consumables = true } },
    { id = 1287771, n = "Rune of Masterful Cunning", class = "ALL",    cats = { consumables = true } },
    { id = 1287774, n = "Rune of Burning Haste",    class = "ALL",     cats = { consumables = true } },
    { id = 1287770, n = "Rune of the Versatile Warrior", class = "ALL", cats = { consumables = true } },
    { id = 1287978, n = "Rune of Lynxlike Reflexes", class = "ALL",    cats = { consumables = true } },
    { id = 1287955, n = "Rune of Void-Tainted Shell", class = "ALL",   cats = { consumables = true } },
    { id = 1237015, alts = { 1237017 }, n = "Dawn's Protection", class = "ALL", cats = { consumables = true } },
    { id = 1289063, n = "Rune of Echoes",           class = "ALL",     cats = { consumables = true } },

    -- ------------------------------------------------------------
    -- Trinkets & Items
    -- ------------------------------------------------------------
    { id = 1229746, n = "Arcanoweave Insight",      class = "ALL",     cats = { trinketsItems = true } },
    { id = 1285161, n = "Protective Toadstools",    class = "ALL",     cats = { trinketsItems = true } },
    { id = 1287665, n = "Rune of Lingering",        class = "ALL",     cats = { trinketsItems = true } },
    { id = 1262496, n = "Light Company Guidon",     class = "ALL",     cats = { trinketsItems = true } },
    { id = 1307578, n = "Soulcoil Barrier",         class = "ALL",     cats = { trinketsItems = true } },
    { id = 1305846, n = "Preternatural Antivenom",  class = "ALL",     cats = { trinketsItems = true } },
    { id = 1263727, n = "Litany of Lightblind Wrath", class = "ALL",   cats = { trinketsItems = true } },
    { id = 387028,  n = "Burning Embers",           class = "ALL",     cats = { trinketsItems = true } },
    { id = 1242003, n = "Worldsoul Cradle",         class = "ALL",     cats = { trinketsItems = true } },
    { id = 1300642, n = "Condensation",             class = "SHAMAN",  cats = { trinketsItems = true } },
    { id = 1250533, n = "Freightrunner's Flask",    class = "ALL",     cats = { trinketsItems = true } },
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
