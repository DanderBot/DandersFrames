local addonName, DF = ...

-- ============================================================
-- WOW FOREVER SPELL DATABASE (GENERATED -- DO NOT HAND-EDIT)
-- Built by _Reference/tools/forever_spelldb.py from Blizzard's client tables
-- (wago.tools DB2, build 1.60.1.70205). Each record lists EVERY rank: vanilla-era
-- spells change spell id per rank, and aura matching is by exact id.
-- Categories: retail SpellDB's category for the same class+name, else
-- EllesmereUI's; raid buffs fold their group version (Prayer of / Greater
-- Blessing of / Gift of) into the single buff. Regenerate, don't edit.
-- SpellDB.lua reads R.ForeverSpells / R.ForeverStamp through its
-- `DF.IS_FOREVER and (...)` prefixes; this file loads first and is a no-op on retail.
-- ============================================================
if not DF.IS_FOREVER then return end

DF.FilterRegistry = DF.FilterRegistry or {}
local R = DF.FilterRegistry

R.ForeverStamp = { flavor = "forever", harvest = "2026-10-05", gameBuild = 70205 }

R.ForeverSpells = {
    -- defensives
    { id = 22812, n = "Barkskin", class = "DRUID", cats = { defensives = true, tankCooldowns = true } },
    { id = 22842, n = "Frenzied Regeneration", class = "DRUID", cats = { defensives = true, tankCooldowns = true } },
    { id = 408024, n = "Survival Instincts", class = "DRUID", cats = { defensives = true, tankCooldowns = true } },
    { id = 19263, n = "Deterrence", class = "HUNTER", cats = { defensives = true } },
    { id = 11426, alts = { 13031, 13032, 13033 }, n = "Ice Barrier", class = "MAGE", cats = { defensives = true } },
    { id = 11958, n = "Ice Block", class = "MAGE", cats = { defensives = true } },
    { id = 1463, alts = { 8494, 8495, 10191, 10192, 10193 }, n = "Mana Shield", class = "MAGE", cats = { defensives = true } },
    { id = 498, alts = { 5573 }, n = "Divine Protection", class = "PALADIN", cats = { defensives = true } },
    { id = 642, alts = { 1020 }, n = "Divine Shield", class = "PALADIN", cats = { defensives = true } },
    { id = 425294, n = "Dispersion", class = "PRIEST", cats = { defensives = true } },
    { id = 586, alts = { 9578, 9579, 9592, 10941, 10942 }, n = "Fade", class = "PRIEST", cats = { defensives = true } },
    { id = 5277, n = "Evasion", class = "ROGUE", cats = { defensives = true } },
    { id = 11327, alts = { 11329, 18461 }, n = "Vanish", class = "ROGUE", cats = { defensives = true } },
    { id = 6229, alts = { 11739, 11740, 28610 }, n = "Shadow Ward", class = "WARLOCK", cats = { defensives = true } },
    { id = 402913, n = "Enraged Regeneration", class = "WARRIOR", cats = { defensives = true } },
    { id = 12976, n = "Last Stand", class = "WARRIOR", cats = { defensives = true, tankCooldowns = true } },
    { id = 20230, n = "Retaliation", class = "WARRIOR", cats = { defensives = true } },
    { id = 871, n = "Shield Wall", class = "WARRIOR", cats = { defensives = true, tankCooldowns = true } },
    -- externalDefensives
    { id = 1022, alts = { 5599, 10278 }, n = "Blessing of Protection", class = "PALADIN", cats = { externalDefensives = true } },
    { id = 6940, alts = { 20729 }, n = "Blessing of Sacrifice", class = "PALADIN", cats = { externalDefensives = true } },
    { id = 6346, n = "Fear Ward", class = "PRIEST", cats = { externalDefensives = true } },
    { id = 402004, n = "Pain Suppression", class = "PRIEST", cats = { externalDefensives = true } },
    -- healing
    { id = 408124, n = "Lifebloom", class = "DRUID", cats = { healing = true } },
    { id = 8936, alts = { 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858 }, n = "Regrowth", class = "DRUID", cats = { healing = true } },
    { id = 774, alts = { 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841, 25299 }, n = "Rejuvenation", class = "DRUID", cats = { healing = true } },
    { id = 408120, alts = { 1238214, 1238215 }, n = "Wild Growth", class = "DRUID", cats = { healing = true } },
    { id = 17, alts = { 592, 600, 3747, 6065, 6066, 10898, 10899, 10900, 10901 }, n = "Power Word: Shield", class = "PRIEST", cats = { healing = true } },
    { id = 139, alts = { 425268, 6074, 425269, 6075, 425270, 6076, 425271, 6077, 425272, 6078, 425273, 10927, 425274, 10928, 425275, 10929, 425276, 25315, 425277 }, n = "Renew", class = "PRIEST", cats = { healing = true } },
    { id = 408514, n = "Earth Shield", class = "SHAMAN", cats = { healing = true } },
    { id = 408521, alts = { 1239242, 1239243 }, n = "Riptide", class = "SHAMAN", cats = { healing = true } },
    -- movement
    { id = 1850, alts = { 9821 }, n = "Dash", class = "DRUID", cats = { movement = true } },
    { id = 5215, alts = { 6783, 9913 }, n = "Prowl", class = "DRUID", cats = { movement = true } },
    { id = 783, n = "Travel Form", class = "DRUID", cats = { movement = true } },
    { id = 5118, n = "Aspect of the Cheetah", class = "HUNTER", cats = { movement = true } },
    { id = 13159, n = "Aspect of the Pack", class = "HUNTER", cats = { movement = true } },
    { id = 5384, n = "Feign Death", class = "HUNTER", cats = { movement = true } },
    { id = 130, n = "Slow Fall", class = "MAGE", cats = { movement = true } },
    { id = 1044, n = "Blessing of Freedom", class = "PALADIN", cats = { movement = true } },
    { id = 1706, n = "Levitate", class = "PRIEST", cats = { movement = true } },
    { id = 2983, alts = { 8696, 11305 }, n = "Sprint", class = "ROGUE", cats = { movement = true } },
    { id = 1784, alts = { 1785, 1786, 1787 }, n = "Stealth", class = "ROGUE", cats = { movement = true } },
    { id = 2645, n = "Ghost Wolf", class = "SHAMAN", cats = { movement = true } },
    { id = 18499, n = "Berserker Rage", class = "WARRIOR", cats = { movement = true } },
    -- offensiveCooldowns
    { id = 417141, n = "Berserk", class = "DRUID", cats = { offensiveCooldowns = true } },
    { id = 5217, n = "Tiger's Fury", class = "DRUID", cats = { offensiveCooldowns = true } },
    { id = 19574, n = "Bestial Wrath", class = "HUNTER", cats = { offensiveCooldowns = true, petBuffs = true } },
    { id = 3045, n = "Rapid Fire", class = "HUNTER", cats = { offensiveCooldowns = true } },
    { id = 12042, n = "Arcane Power", class = "MAGE", cats = { offensiveCooldowns = true } },
    { id = 425124, n = "Arcane Surge", class = "MAGE", cats = { offensiveCooldowns = true } },
    { id = 11129, alts = { 28682 }, n = "Combustion", class = "MAGE", cats = { offensiveCooldowns = true } },
    { id = 12043, n = "Presence of Mind", class = "MAGE", cats = { offensiveCooldowns = true } },
    { id = 407788, n = "Avenging Wrath", class = "PALADIN", cats = { offensiveCooldowns = true } },
    { id = 20216, n = "Divine Favor", class = "PALADIN", cats = { offensiveCooldowns = true } },
    { id = 14751, n = "Inner Focus", class = "PRIEST", cats = { offensiveCooldowns = true } },
    { id = 13750, n = "Adrenaline Rush", class = "ROGUE", cats = { offensiveCooldowns = true } },
    { id = 13877, n = "Blade Flurry", class = "ROGUE", cats = { offensiveCooldowns = true } },
    { id = 14177, n = "Cold Blood", class = "ROGUE", cats = { offensiveCooldowns = true } },
    { id = 12328, n = "Death Wish", class = "WARRIOR", cats = { offensiveCooldowns = true } },
    { id = 1719, n = "Recklessness", class = "WARRIOR", cats = { offensiveCooldowns = true } },
    { id = 12292, n = "Sweeping Strikes", class = "WARRIOR", cats = { offensiveCooldowns = true } },
    -- petBuffs
    { id = 19621, n = "Frenzy", class = "HUNTER", cats = { petBuffs = true } },
    { id = 136, alts = { 3111, 3661, 3662, 13542, 13543, 13544 }, n = "Mend Pet", class = "HUNTER", cats = { petBuffs = true } },
    -- powerExternals
    { id = 29166, n = "Innervate", class = "DRUID", cats = { powerExternals = true } },
    { id = 10060, n = "Power Infusion", class = "PRIEST", cats = { powerExternals = true } },
    -- raidBuffs
    { id = 1126, alts = { 5232, 6756, 5234, 8907, 9884, 9885, 364163, 16878, 24752, 1291335, 1310503, 21849, 21850 }, n = "Mark of the Wild", class = "DRUID", cats = { raidBuffs = true } },
    { id = 467, alts = { 782, 1075, 8914, 9756, 9910, 1236308, 21335, 21337, 22128, 22351, 22696, 25640, 25777, 1291338, 438294, 16877, 15438, 1312955, 1213813, 1213816, 1213834 }, n = "Thorns", class = "DRUID", cats = { raidBuffs = true } },
    { id = 1459, alts = { 1460, 1461, 10156, 10157, 364161, 13326, 16876, 23028 }, n = "Arcane Intellect", class = "MAGE", cats = { raidBuffs = true } },
    { id = 20217, alts = { 1213408, 25898 }, n = "Blessing of Kings", class = "PALADIN", cats = { raidBuffs = true } },
    { id = 19977, alts = { 19978, 19979, 26650, 25890 }, n = "Blessing of Light", class = "PALADIN", cats = { raidBuffs = true } },
    { id = 19740, alts = { 19834, 19835, 19836, 19837, 19838, 25291, 25782, 25916 }, n = "Blessing of Might", class = "PALADIN", cats = { raidBuffs = true } },
    { id = 1038, alts = { 25895 }, n = "Blessing of Salvation", class = "PALADIN", cats = { raidBuffs = true } },
    { id = 19742, alts = { 19850, 19852, 19853, 19854, 25290, 25894, 25918 }, n = "Blessing of Wisdom", class = "PALADIN", cats = { raidBuffs = true } },
    { id = 19746, n = "Concentration Aura", class = "PALADIN", cats = { raidBuffs = true } },
    { id = 465, alts = { 10290, 643, 10291, 1032, 10292, 10293 }, n = "Devotion Aura", class = "PALADIN", cats = { raidBuffs = true } },
    { id = 14752, alts = { 14818, 14819, 27841, 16875, 27681 }, n = "Divine Spirit", class = "PRIEST", cats = { raidBuffs = true } },
    { id = 1243, alts = { 1244, 1245, 2791, 10937, 10938, 13864, 23947, 23948, 21562, 21564, 450086 }, n = "Power Word: Fortitude", class = "PRIEST", cats = { raidBuffs = true } },
    { id = 976, alts = { 10957, 10958, 7235, 7241, 7242, 7243, 7244, 17548, 16874, 27683 }, n = "Shadow Protection", class = "PRIEST", cats = { raidBuffs = true } },
    { id = 6673, alts = { 5242, 6192, 11549, 11550, 11551, 25289, 9128, 24438, 25101, 27578, 26043, 26099 }, n = "Battle Shout", class = "WARRIOR", cats = { raidBuffs = true } },
    { id = 403215, alts = { 22440, 403435 }, n = "Commanding Shout", class = "WARRIOR", cats = { raidBuffs = true } },
    -- raidDefensives
    { id = 740, alts = { 8918, 9862, 9863 }, n = "Tranquility", class = "DRUID", cats = { raidDefensives = true } },
    { id = 425207, n = "Power Word: Barrier", class = "PRIEST", cats = { raidDefensives = true } },
    { id = 426490, n = "Rallying Cry", class = "WARRIOR", cats = { raidDefensives = true } },
    -- utility
    { id = 17116, n = "Nature's Swiftness", class = "DRUID", cats = { utility = true } },
    { id = 1008, alts = { 8455, 10169, 10170 }, n = "Amplify Magic", class = "MAGE", cats = { utility = true } },
    { id = 604, alts = { 8450, 8451, 10173, 10174 }, n = "Dampen Magic", class = "MAGE", cats = { utility = true } },
    { id = 588, alts = { 7128, 602, 1006, 10951, 10952 }, n = "Inner Fire", class = "PRIEST", cats = { utility = true } },
    { id = 16188, n = "Nature's Swiftness", class = "SHAMAN", cats = { utility = true } },
    { id = 131, n = "Water Breathing", class = "SHAMAN", cats = { utility = true } },
    { id = 546, n = "Water Walking", class = "SHAMAN", cats = { utility = true } },
    { id = 5697, n = "Unending Breath", class = "WARLOCK", cats = { utility = true } },
}

-- Missing Buffs: the four group buffs Forever shares with retail, under the same
-- setting keys. Replaces DF.RaidBuffs / DF.ClassToRaidBuff from Frames/Bars.lua,
-- whose retail ids don't exist here. Entry = {ids, configKey, name, class}; ids
-- cover every rank, the group version and item/NPC sources.
DF.RaidBuffs = {
    { { 1243, 1244, 1245, 2791, 10937, 10938, 13864, 23947, 23948, 21562, 21564, 450086 }, "missingBuffCheckStamina", "Power Word: Fortitude", "PRIEST" },
    { { 1459, 1460, 1461, 10156, 10157, 364161, 13326, 16876, 23028 }, "missingBuffCheckIntellect", "Arcane Intellect", "MAGE" },
    { { 1126, 5232, 6756, 5234, 8907, 9884, 9885, 364163, 16878, 24752, 1291335, 1310503, 21849, 21850 }, "missingBuffCheckVersatility", "Mark of the Wild", "DRUID" },
    { { 6673, 5242, 6192, 11549, 11550, 11551, 25289, 9128, 24438, 25101, 27578, 26043, 26099 }, "missingBuffCheckAttackPower", "Battle Shout", "WARRIOR" },
}
DF.ClassToRaidBuff = {
    PRIEST = "missingBuffCheckStamina",
    MAGE = "missingBuffCheckIntellect",
    DRUID = "missingBuffCheckVersatility",
    WARRIOR = "missingBuffCheckAttackPower",
}
