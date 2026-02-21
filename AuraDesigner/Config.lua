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
