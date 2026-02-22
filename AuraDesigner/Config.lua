local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER CONFIG
-- Spec-specific aura display definitions for the adapter stub
-- ============================================================

local pairs = pairs

-- Initialize the AuraDesigner namespace
DF.AuraDesigner = DF.AuraDesigner or {}

-- ============================================================
-- SPEC MAP
-- Maps CLASS_SPECNUM to internal spec key (mirrors HARF Data.specMap)
-- ============================================================
DF.AuraDesigner.SpecMap = {
    DRUID_4     = "RestorationDruid",
    SHAMAN_3    = "RestorationShaman",
    PRIEST_1    = "DisciplinePriest",
    PRIEST_2    = "HolyPriest",
    PALADIN_1   = "HolyPaladin",
    EVOKER_2    = "PreservationEvoker",
    EVOKER_3    = "AugmentationEvoker",
    MONK_2      = "MistweaverMonk",
}

-- ============================================================
-- SPEC INFO
-- Display names and class tokens for each supported spec
-- ============================================================
DF.AuraDesigner.SpecInfo = {
    PreservationEvoker  = { display = "Preservation Evoker",  class = "EVOKER"  },
    AugmentationEvoker  = { display = "Augmentation Evoker",  class = "EVOKER"  },
    RestorationDruid    = { display = "Restoration Druid",    class = "DRUID"   },
    DisciplinePriest    = { display = "Discipline Priest",    class = "PRIEST"  },
    HolyPriest          = { display = "Holy Priest",          class = "PRIEST"  },
    MistweaverMonk      = { display = "Mistweaver Monk",      class = "MONK"    },
    RestorationShaman   = { display = "Restoration Shaman",   class = "SHAMAN"  },
    HolyPaladin         = { display = "Holy Paladin",         class = "PALADIN" },
}

-- ============================================================
-- SPELL IDS PER SPEC
-- Used to fetch real spell icons via C_Spell.GetSpellTexture()
-- ============================================================
DF.AuraDesigner.SpellIDs = {
    PreservationEvoker = {
        Echo = 364343, Reversion = 366155, EchoReversion = 367364,
        DreamBreath = 355941, EchoDreamBreath = 376788, TimeDilation = 357170,
        Rewind = 363534, DreamFlight = 363502, Lifebind = 373267, VerdantEmbrace = 409895,
    },
    AugmentationEvoker = {
        Prescience = 410089, ShiftingSands = 413984, BlisteringScales = 360827,
        InfernosBlessing = 410263, SymbioticBloom = 410686, EbonMight = 395152,
    },
    RestorationDruid = {
        Rejuvenation = 774, Regrowth = 8936, Lifebloom = 33763,
        Germination = 155777, WildGrowth = 48438, IronBark = 102342,
    },
    DisciplinePriest = {
        PowerWordShield = 17, Atonement = 194384, PainSuppression = 33206,
        VoidShield = 1253593, PrayerOfMending = 41635, PowerInfusion = 10060,
    },
    HolyPriest = {
        Renew = 139, EchoOfLight = 77489, GuardianSpirit = 47788,
        PrayerOfMending = 41635, PowerInfusion = 10060,
    },
    MistweaverMonk = {
        RenewingMist = 119611, EnvelopingMist = 124682, SoothingMist = 115175,
        LifeCocoon = 116849, AspectOfHarmony = 450769, StrengthOfTheBlackOx = 443113,
    },
    RestorationShaman = {
        Riptide = 61295, EarthShield = 383648,
    },
    HolyPaladin = {
        BeaconOfFaith = 156910, EternalFlame = 156322, BeaconOfLight = 53563,
        BlessingOfProtection = 1022, HolyBulwark = 432496, SacredWeapon = 432502,
        BlessingOfSacrifice = 6940, BeaconOfVirtue = 200025, BeaconOfTheSavior = 1244893,
    },
}

-- ============================================================
-- AURA FINGERPRINTS PER SPEC
-- Secret-safe aura identification using C_UnitAuras.IsAuraFilteredOutByInstanceID().
-- Instead of reading spellId (which is secret in combat), we use the combination
-- of filter results + tooltip point count to uniquely identify each aura.
-- Data sourced from Harrek's Advanced Raid Frames (Data/Specs.lua).
--
-- Each aura: { points = N, raid = bool, ric = bool, ext = bool, disp = bool }
-- Where:
--   points = number of tooltip points (#aura.points), -1 = variable (skip check)
--   raid   = passes PLAYER|HELPFUL|RAID filter
--   ric    = passes PLAYER|HELPFUL|RAID_IN_COMBAT filter
--   ext    = passes PLAYER|HELPFUL|EXTERNAL_DEFENSIVE filter
--   disp   = passes PLAYER|HELPFUL|RAID_PLAYER_DISPELLABLE filter
-- ============================================================
DF.AuraDesigner.AuraFingerprints = {
    PreservationEvoker = {
        Echo             = { points = 2,  raid = true,  ric = true,  ext = false, disp = false },
        Reversion        = { points = 3,  raid = true,  ric = true,  ext = false, disp = true  },
        EchoReversion    = { points = 3,  raid = false, ric = true,  ext = false, disp = true  },
        DreamBreath      = { points = 3,  raid = false, ric = true,  ext = false, disp = false },
        EchoDreamBreath  = { points = -1, raid = false, ric = true,  ext = false, disp = false },
        TimeDilation     = { points = 2,  raid = true,  ric = true,  ext = true,  disp = false },
        Rewind           = { points = 4,  raid = true,  ric = true,  ext = false, disp = false },
        DreamFlight      = { points = 2,  raid = false, ric = true,  ext = false, disp = false },
        Lifebind         = { points = -1, raid = false, ric = true,  ext = false, disp = false },
        VerdantEmbrace   = { points = 1,  raid = false, ric = true,  ext = false, disp = false },
    },
    AugmentationEvoker = {
        Prescience       = { points = 3,  raid = false, ric = true,  ext = false, disp = false },
        ShiftingSands    = { points = 2,  raid = false, ric = true,  ext = false, disp = false },
        BlisteringScales = { points = 2,  raid = true,  ric = true,  ext = false, disp = false },
        InfernosBlessing = { points = 0,  raid = false, ric = true,  ext = false, disp = false },
        SymbioticBloom   = { points = 1,  raid = false, ric = true,  ext = false, disp = false },
        EbonMight        = { points = 3,  raid = true,  ric = true,  ext = false, disp = false },
    },
    RestorationDruid = {
        Rejuvenation     = { points = 1,  raid = true,  ric = true,  ext = false, disp = true  },
        Regrowth         = { points = 3,  raid = true,  ric = true,  ext = false, disp = true  },
        Lifebloom        = { points = -1, raid = true,  ric = true,  ext = false, disp = true  },
        Germination      = { points = 1,  raid = false, ric = true,  ext = false, disp = true  },
        WildGrowth       = { points = 2,  raid = true,  ric = true,  ext = false, disp = true  },
        IronBark         = { points = 2,  raid = true,  ric = true,  ext = true,  disp = false },
    },
    DisciplinePriest = {
        PowerWordShield  = { points = 2,  raid = true,  ric = true,  ext = false, disp = true  },
        Atonement        = { points = 0,  raid = false, ric = true,  ext = false, disp = false },
        PainSuppression  = { points = 0,  raid = true,  ric = true,  ext = true,  disp = false },
        VoidShield       = { points = 3,  raid = false, ric = true,  ext = false, disp = true  },
        PrayerOfMending  = { points = 1,  raid = false, ric = true,  ext = false, disp = true  },
        PowerInfusion    = { points = 2,  raid = true,  ric = false, ext = false, disp = true  },
    },
    HolyPriest = {
        Renew            = { points = 2,  raid = false, ric = true,  ext = false, disp = true  },
        EchoOfLight      = { points = 1,  raid = false, ric = true,  ext = false, disp = false },
        GuardianSpirit   = { points = 3,  raid = true,  ric = true,  ext = true,  disp = false },
        PrayerOfMending  = { points = 1,  raid = false, ric = true,  ext = false, disp = true  },
        PowerInfusion    = { points = 2,  raid = true,  ric = false, ext = false, disp = true  },
    },
    MistweaverMonk = {
        RenewingMist          = { points = 2,  raid = false, ric = true,  ext = false, disp = true  },
        EnvelopingMist        = { points = 3,  raid = true,  ric = true,  ext = false, disp = true  },
        SoothingMist          = { points = 3,  raid = true,  ric = true,  ext = false, disp = false },
        LifeCocoon            = { points = 3,  raid = true,  ric = true,  ext = true,  disp = false },
        AspectOfHarmony       = { points = 2,  raid = false, ric = true,  ext = false, disp = false },
        StrengthOfTheBlackOx  = { points = 3,  raid = false, ric = true,  ext = false, disp = true  },
    },
    RestorationShaman = {
        Riptide          = { points = 2,  raid = true,  ric = true,  ext = false, disp = true  },
        EarthShield      = { points = 3,  raid = false, ric = true,  ext = false, disp = true  },
    },
    HolyPaladin = {
        BeaconOfFaith        = { points = 7,  raid = true,  ric = true,  ext = false, disp = false },
        EternalFlame         = { points = 3,  raid = true,  ric = true,  ext = false, disp = true  },
        BeaconOfLight        = { points = 6,  raid = true,  ric = true,  ext = false, disp = false },
        BlessingOfProtection = { points = 0,  raid = true,  ric = true,  ext = true,  disp = true  },
        HolyBulwark          = { points = -1, raid = false, ric = true,  ext = false, disp = false },
        SacredWeapon         = { points = 5,  raid = false, ric = true,  ext = false, disp = false },
        BlessingOfSacrifice  = { points = 9,  raid = true,  ric = true,  ext = true,  disp = false },
        BeaconOfVirtue       = { points = 4,  raid = true,  ric = false, ext = false, disp = false },
        BeaconOfTheSavior    = { points = 7,  raid = false, ric = true,  ext = false, disp = false },
    },
}

-- ============================================================
-- TRACKABLE AURAS PER SPEC
-- Each aura: { name = "InternalName", display = "Display Name", color = {r,g,b} }
-- Colors are used for tile accents in the Options UI
-- ============================================================
DF.AuraDesigner.TrackableAuras = {
    PreservationEvoker = {
        { name = "Echo",             display = "Echo",              color = {0.31, 0.76, 0.97} },
        { name = "Reversion",        display = "Reversion",         color = {0.51, 0.78, 0.52} },
        { name = "EchoReversion",    display = "Echo Reversion",    color = {0.40, 0.77, 0.74} },
        { name = "DreamBreath",      display = "Dream Breath",      color = {0.47, 0.87, 0.47} },
        { name = "EchoDreamBreath",  display = "Echo Dream Breath", color = {0.36, 0.82, 0.60} },
        { name = "TimeDilation",     display = "Time Dilation",     color = {1.00, 0.84, 0.28} },
        { name = "Rewind",           display = "Rewind",            color = {0.39, 0.58, 0.93} },
        { name = "DreamFlight",      display = "Dream Flight",      color = {0.81, 0.58, 0.93} },
        { name = "Lifebind",         display = "Lifebind",          color = {0.94, 0.50, 0.50} },
        { name = "VerdantEmbrace",   display = "Verdant Embrace",   color = {0.56, 0.93, 0.56} },
    },
    AugmentationEvoker = {
        { name = "Prescience",       display = "Prescience",        color = {0.81, 0.58, 0.85} },
        { name = "ShiftingSands",    display = "Shifting Sands",    color = {1.00, 0.84, 0.28} },
        { name = "BlisteringScales", display = "Blistering Scales", color = {0.94, 0.50, 0.50} },
        { name = "InfernosBlessing", display = "Infernos Blessing", color = {1.00, 0.60, 0.28} },
        { name = "SymbioticBloom",   display = "Symbiotic Bloom",   color = {0.51, 0.78, 0.52} },
        { name = "EbonMight",        display = "Ebon Might",        color = {0.62, 0.47, 0.85} },
        { name = "SensePower",       display = "Sense Power",       color = {0.47, 0.78, 0.88} },
    },
    RestorationDruid = {
        { name = "Rejuvenation",  display = "Rejuvenation",  color = {0.51, 0.78, 0.52} },
        { name = "Regrowth",      display = "Regrowth",      color = {0.31, 0.76, 0.97} },
        { name = "Lifebloom",     display = "Lifebloom",     color = {0.56, 0.93, 0.56} },
        { name = "Germination",   display = "Germination",   color = {0.77, 0.89, 0.42} },
        { name = "WildGrowth",    display = "Wild Growth",   color = {0.81, 0.58, 0.93} },
        { name = "IronBark",      display = "Iron Bark",     color = {0.65, 0.47, 0.33} },
    },
    DisciplinePriest = {
        { name = "PowerWordShield", display = "PW: Shield",         color = {1.00, 0.84, 0.28} },
        { name = "Atonement",       display = "Atonement",          color = {0.94, 0.50, 0.50} },
        { name = "PainSuppression", display = "Pain Suppression",   color = {0.31, 0.76, 0.97} },
        { name = "VoidShield",      display = "Void Shield",        color = {0.62, 0.47, 0.85} },
        { name = "PrayerOfMending", display = "Prayer of Mending",  color = {0.56, 0.93, 0.56} },
        { name = "PowerInfusion",   display = "Power Infusion",     color = {0.81, 0.58, 0.93} },
    },
    HolyPriest = {
        { name = "Renew",           display = "Renew",              color = {0.56, 0.93, 0.56} },
        { name = "EchoOfLight",     display = "Echo of Light",      color = {1.00, 0.84, 0.28} },
        { name = "GuardianSpirit",  display = "Guardian Spirit",    color = {0.31, 0.76, 0.97} },
        { name = "PrayerOfMending", display = "Prayer of Mending",  color = {0.81, 0.58, 0.93} },
        { name = "PowerInfusion",   display = "Power Infusion",     color = {0.62, 0.47, 0.85} },
    },
    MistweaverMonk = {
        { name = "RenewingMist",          display = "Renewing Mist",           color = {0.56, 0.93, 0.56} },
        { name = "EnvelopingMist",        display = "Enveloping Mist",         color = {0.31, 0.76, 0.97} },
        { name = "SoothingMist",          display = "Soothing Mist",           color = {0.47, 0.87, 0.47} },
        { name = "LifeCocoon",            display = "Life Cocoon",             color = {1.00, 0.84, 0.28} },
        { name = "AspectOfHarmony",       display = "Aspect of Harmony",       color = {0.81, 0.58, 0.93} },
        { name = "StrengthOfTheBlackOx",  display = "Strength of the Black Ox", color = {0.94, 0.50, 0.50} },
    },
    RestorationShaman = {
        { name = "Riptide",     display = "Riptide",      color = {0.31, 0.76, 0.97} },
        { name = "EarthShield", display = "Earth Shield",  color = {0.65, 0.47, 0.33} },
    },
    HolyPaladin = {
        { name = "BeaconOfFaith",        display = "Beacon of Faith",        color = {1.00, 0.84, 0.28} },
        { name = "EternalFlame",         display = "Eternal Flame",          color = {1.00, 0.60, 0.28} },
        { name = "BeaconOfLight",        display = "Beacon of Light",        color = {1.00, 0.93, 0.47} },
        { name = "BlessingOfProtection", display = "Blessing of Protection", color = {0.31, 0.76, 0.97} },
        { name = "HolyBulwark",          display = "Holy Bulwark",           color = {0.94, 0.85, 0.47} },
        { name = "SacredWeapon",         display = "Sacred Weapon",          color = {0.94, 0.50, 0.50} },
        { name = "BlessingOfSacrifice",  display = "Blessing of Sacrifice",  color = {0.81, 0.58, 0.93} },
        { name = "BeaconOfVirtue",       display = "Beacon of Virtue",       color = {0.56, 0.93, 0.56} },
        { name = "BeaconOfTheSavior",    display = "Beacon of the Savior",   color = {0.93, 0.80, 0.47} },
    },
}
