-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local L = DF.L

-- ============================================================
-- FRAMES TEST MODE MODULE
-- Contains test mode data, functions, and test panel
-- ============================================================

-- ============================================================
-- TEST MODE DATA
-- ============================================================

DF.TestData = {
    units = {
        {name = "Tankerino", class = "WARRIOR", role = "TANK", specID = 73, health = 1.0, maxHealth = 100000, absorb = 0.20, healAbsorb = 0, healPrediction = 0.15, status = nil, outOfRange = false, isLeader = true, raidTarget = 8, dispelType = nil, centerStatus = nil, isMainTank = true, isAFK = false, isPhased = false, inVehicle = false, isBGCarrier = false, isInCombat = true, reducedMaxPct = 0.20},  -- Skull marker, leader, main tank, has HoT, in combat (BG carrier kept to raid test to avoid overlapping the leader's ready-check icon)
        {name = "Healsworth", class = "PRIEST", role = "HEALER", specID = 257, health = 0.95, maxHealth = 85000, absorb = 0.10, healAbsorb = 0, healPrediction = 0.05, status = nil, outOfRange = false, isAssist = true, raidTarget = nil, dispelType = "Magic", centerStatus = "summon", isMainAssist = true, isAFK = false, isPhased = false, inVehicle = false, reducedMaxPct = 0},  -- Assistant, main assist, summon pending
        {name = "Мишок", class = "MAGE", role = "DAMAGER", specID = 63, health = 0.60, maxHealth = 75000, absorb = 0, healAbsorb = 0.15, healPrediction = 0.15, status = nil, outOfRange = true, raidTarget = 1, dispelType = "Curse", centerStatus = nil, isAFK = true, isPhased = false, inVehicle = false, reducedMaxPct = 0},  -- Star marker, AFK, has HoT
        {name = "Alexandrosthegreat", class = "PALADIN", role = "DAMAGER", specID = 70, health = 0, maxHealth = 90000, absorb = 0, healAbsorb = 0, healPrediction = 0, status = "Dead", outOfRange = false, raidTarget = nil, dispelType = nil, centerStatus = "resurrect", isAFK = false, isPhased = false, inVehicle = false, reducedMaxPct = 0},  -- Dead unit, being resurrected
        {name = "Xx", class = "ROGUE", role = "DAMAGER", specID = 260, health = 0.30, maxHealth = 70000, absorb = 0.05, healAbsorb = 0.12, healPrediction = 0.25, status = nil, outOfRange = false, raidTarget = nil, dispelType = "Poison", centerStatus = nil, isAFK = false, isPhased = true, inVehicle = true, reducedMaxPct = 0.45},  -- Phased, in vehicle, has HoT
    },
    -- Test aura data - expanded for testing layouts. spellID (where a stable,
    -- still-live spell matches) lets the 12.1 container preview show the REAL
    -- spell tooltip on hover; entries without one fall back to a name tooltip.
    -- ☠ THE `name` IS THE SOURCE OF TRUTH, NOT THE ID. _paintTestSlot only keeps
    -- spellID when `C_Spell.GetSpellName(id) == name`, and resolves by name when it
    -- doesn't — so a stale ID self-heals. The one thing that gate CANNOT catch is a
    -- different spell sharing the name: `Deadly Poison` shipped as 2823, the rogue's
    -- one-hour WEAPON IMBUE, and previewed with the imbue's tooltip on a party frame
    -- for exactly that reason (2818 is the DoT). If two spells share a name, name the
    -- one you mean with its ID and check the tooltip in game.
    --
    -- ⚠ ORDER IS MEANINGFUL. Entries are handed out in pool order from a per-frame
    -- rotation (testPoolOffset), so ADJACENT entries appear together on one frame.
    -- Buffs alternate duration classes; the debuff pool front-loads the four dispellable
    -- colours (Bleed → Disease → Curse → Poison) then runs none/none/Magic/Curse/none/none,
    -- so no two neighbours share a type and the untyped slots pair off into the density
    -- dial described on the pool below. Reordering silently degrades both.
    -- ☠ ONE SPELL PER CLASS IN ANY WINDOW, AND THAT IS AN ARITHMETIC CONSTRAINT.
    --
    -- _paintTestSlot adopts the player's SPEC OVERRIDE wholesale so icon, name and
    -- tooltip move together (deliberate, and correct). The consequence is that two
    -- entries can COLLAPSE onto one spell for one class — a priest saw Prayer of Mending
    -- twice, because Power Word: Shield and PoM swap between Disc and Holy.
    --
    -- ⚠ SEPARATING THEM IS NOT ENOUGH, which is how the first fix failed. Each frame
    -- draws a WRAPPING run of `count` consecutive entries, so over a 10-entry pool with
    -- a 5-icon preview the only pairs that never share a window are those EXACTLY 5
    -- apart. PW:S was moved to 9 against PoM at 2 — distance 3 — and offset 7 hands a
    -- frame entries 8,9,10,1,2, containing both. (Krathe again: "we do random from the
    -- 1-10? so it can still pull PW:S and PoM on one set of 5 buffs".)
    --
    -- Which caps it at TWO spells per class, at i and i+5. Four priest spells cannot be
    -- made safe at any ordering, so the pool now runs one class per slot in the first
    -- five and repeats that order in the second five:
    --     1-5  PALADIN PRIEST DRUID SHAMAN MONK
    --     6-10 PALADIN PRIEST DRUID MAGE   WARRIOR
    -- Every window of 5 therefore holds five DIFFERENT classes, so no override can merge
    -- two of them. Verified for every offset the rotation produces.
    -- ⚠ Adding an entry breaks the arithmetic. Keep the pool at 10 and swap, or redo the
    -- spacing for the new size.
    buffs = {
        {icon = "Interface\Icons\Spell_Holy_BlessingOfProtection", name = "Blessing of Protection", duration = 10, stacks = 0, spellID = 1022},
        -- Stacks are REAL here (charges remaining), which is why PoM keeps its slot: the
        -- previous stack case was "Heal" with 2 stacks, a spell that applies no aura.
        {icon = "Interface\Icons\spell_holy_prayerofmending", name = "Prayer of Mending", duration = 30, stacks = 5, spellID = 41635},
        {icon = "Interface\Icons\Spell_Nature_Rejuvenation", name = "Rejuvenation", duration = 12, stacks = 0, spellID = 774},
        {icon = "Interface\Icons\Spell_Nature_Riptide", name = "Riptide", duration = 8, stacks = 0, spellID = 61295},
        {icon = "Interface\Icons\ability_monk_renewingmists", name = "Renewing Mist", duration = 20, stacks = 0, spellID = 119611},
        -- duration = 0 is the PERMANENT case, and it drives "Hide Duration on Permanent
        -- Auras". Beacon holds until the paladin moves it, so it is a real one rather
        -- than a made-up zero. ⚠ If a patch ever gives Beacon a timer this stops
        -- exercising that setting — the pool then needs another duration-less buff.
        {icon = "Interface\Icons\Ability_Paladin_BeaconofLight", name = "Beacon of Light", duration = 0, stacks = 0, spellID = 53563},
        -- 1 hour, like every modern raid buff — NOT permanent. This shipped as
        -- duration = 0 and was the preview's "permanent aura" case, which was wrong on
        -- both counts. Also the long-duration case, so the countdown formats get
        -- exercised above the minutes/hours boundary.
        {icon = "Interface\Icons\Spell_Holy_WordFortitude", name = "Power Word: Fortitude", duration = 3600, stacks = 0, spellID = 21562},
        {icon = "Interface\Icons\Spell_Nature_Regenerate", name = "Regrowth", duration = 12, stacks = 0, spellID = 8936},
        {icon = "Interface\Icons\Spell_Holy_MagicalSentry", name = "Arcane Intellect", duration = 3600, stacks = 0, spellID = 1459},
        {icon = "Interface\Icons\Ability_Warrior_BattleShout", name = "Battle Shout", duration = 3600, stacks = 0, spellID = 6673},
    },
    debuffs = {
        -- ☠ POSITIONS 5, 6, 9 AND 10 CARRY NO DISPEL TYPE, AND THAT IS THE DENSITY DIAL.
        -- The frame overlay now takes its type from the SAME window the icons draw, so
        -- how often an overlay appears is decided here rather than by a hardcoded
        -- frame-index pattern. At a preview count of 2 the windows tile into five
        -- disjoint pairs -- (1,2) (3,4) (5,6) (7,8) (9,10) -- and raid offsets land on
        -- the same pairs, so two undispellable pairs give 3 of 5 = 60% on BOTH party and
        -- raid. Krathe's spec.
        -- ⚠ Exact at count 2 only. At higher counts a window spans more of the pool and
        -- catches a dispellable entry more often, so the rate climbs; accepted rather
        -- than decoupling the overlay from the icons again, which is the bug being fixed.
        -- ⚠ Same-class entries must still sit EXACTLY 5 apart (see the buff pool):
        -- ROGUE at 4/9 and WARRIOR at 5/10.
        -- ★ THE ONLY Bleed ENTRY, and it has to live in slot 1. DF ships five dispel
        -- colours (Border.lua: Magic, Curse, Disease, Poison, Bleed, with Enrage sharing
        -- Bleed's red) and the pool had no Bleed at all, so that colour could be set on
        -- the Colors page and never previewed. Slot 1 is the one TYPED slot whose 5-apart
        -- partner is already DRUID (Rake at 6), so a druid bleed fits without breaking
        -- the class spacing. Converting Rake or Rend instead would have been simpler and
        -- was rejected: they are two of the four untyped slots that set the 60% density.
        {icon = "Interface\Icons\Ability_Gouge", name = "Rend", duration = 15, stacks = 0, debuffType = "Bleed", spellID = 772},
        {icon = "Interface\Icons\Spell_DeathKnight_FrostFever", name = "Frost Fever", duration = 24, stacks = 0, debuffType = "Disease", spellID = 55095},
        {icon = "Interface\Icons\Spell_Shadow_CurseOfSargeras", name = "Curse of Tongues", duration = 30, stacks = 0, debuffType = "Curse", spellID = 1714},
        -- 2818 = the DoT. NOT 2823, which is the weapon imbue of the same name, and the
        -- reason a party frame once previewed "Requires One-Handed Melee Weapon".
        -- Deadly Poison genuinely stacks to 5, so this is an honest stack case.
        {icon = "Interface\Icons\Spell_Nature_NullifyPoison", name = "Deadly Poison", duration = 12, stacks = 5, debuffType = "Poison", spellID = 2818},
        {icon = "Interface\Icons\Spell_Holy_RemoveCurse", name = "Forbearance", duration = 30, stacks = 0, debuffType = nil, spellID = 25771},
        {icon = "Interface\Icons\Ability_Warrior_SavageBlow", name = "Mortal Wounds", duration = 10, stacks = 0, debuffType = nil, spellID = 115804},
        {icon = "Interface\Icons\Spell_Shadow_ShadowWordPain", name = "Shadow Word: Pain", duration = 18, stacks = 0, debuffType = "Magic", spellID = 589},
        {icon = "Interface\Icons\Spell_Shaman_Hex", name = "Hex", duration = 8, stacks = 0, debuffType = "Curse", spellID = 51514},
        {icon = "Interface\Icons\Ability_CheapShot", name = "Dazed", duration = 4, stacks = 0, debuffType = nil, spellID = 1604},
        {icon = "Interface\Icons\Spell_Holy_Resurrection", name = "Resurrection Sickness", duration = 600, stacks = 0, debuffType = nil, spellID = 15007},
    },
    -- Defensive externals for the 12.1 container preview (config.testPool =
    -- "defensives" on the defensive row). Same spells the legacy test painter
    -- cycled; icons are the fallback when the spell ID doesn't validate.
    defensives = {
        {icon = "Interface\\Icons\\Spell_Holy_PainSupression", name = "Pain Suppression", duration = 8, stacks = 0, spellID = 33206},
        {icon = "Interface\\Icons\\spell_druid_ironbark", name = "Ironbark", duration = 12, stacks = 0, spellID = 102342},
        {icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice", name = "Blessing of Sacrifice", duration = 12, stacks = 0, spellID = 6940},
        {icon = "Interface\\Icons\\ability_monk_chicocoon", name = "Life Cocoon", duration = 12, stacks = 0, spellID = 116849},
    },
    animationTimer = nil,
    animationPhase = 0,
}

-- Get test unit data for a frame index
-- For party: index 0 = player, 1-4 = party members
-- For raid: index 1-40 = raid members
function DF:GetTestUnitData(index, isRaid, isBoss)
    local db = isRaid and DF:GetRaidDB() or DF:GetDB()

    -- Friendly Boss NPC test data (for pinned frame boss mode).
    -- Boss NPCs don't have classes or roles — we return a minimal fake unit
    -- so the frame renders a health bar with a readable name.
    if isBoss then
        local bossNames = {
            "Fiery Treant", "Charred Bramble", "Smoldering Sapling", "Ember Root",
            "Blazing Thorn", "Ashen Oak", "Cinder Vine", "Glowing Grove",
        }
        local i = index
        local basePercent = (0.9 - (i - 1) * 0.08)  -- slight descending stagger
        if basePercent < 0.25 then basePercent = 0.25 end

        local result = {
            index = index,
            name = bossNames[i] or ("Friendly Boss " .. i),
            class = nil,
            role = nil,
            specID = 0,
            healthPercent = basePercent,
            maxHealth = 500000,
            currentHealth = math.floor(basePercent * 500000),
            powerPercent = 0,
            absorbPercent = 0,
            healAbsorbPercent = 0,
            healPredictionPercent = 0,
            status = nil,
            outOfRange = false,
            isLeader = false,
            raidTarget = nil,
            dispelType = nil,
            centerStatus = nil,
            isMainTank = false,
            isMainAssist = false,
            isAFK = false,
            isDND = false,
            isPhased = false,
            inVehicle = false,
        }

        -- Animate health if enabled on either DB
        if db.testAnimateHealth and DF.TestData.animationPhase then
            local phase = DF.TestData.animationPhase
            local offset = (i * 0.13) % 1
            local wave = math.sin((phase + offset) * math.pi * 2)
            result.healthPercent = math.max(0.1, math.min(1, basePercent + wave * 0.15))
            result.currentHealth = math.floor(result.healthPercent * result.maxHealth)
        end

        return result
    end

    -- For raid frames, generate deterministic test data
    if isRaid then
        local testNames = {
            "Tankadin", "Healbot", "Magefire", "Stabbymc", "Huntard",
            "Shammywow", "Dkfrost", "Warlockz", "Monkbrew", "Priestess",
            "Druidtree", "Palaheals", "Rogueshadow", "Warriorfury", "Huntermark",
            "Magearcane", "Warlockaff", "Shamanrest", "Monkmist", "Priestshadow",
            "Dkblood", "Demonhunter", "Evokerdev", "Tankwarrior", "Tankdruid",
            "Holypriest", "Discpriest", "Restoshaman", "Mistweaver", "Holypaladin",
            "Boomkin", "Feral", "Enhance", "Elemental", "Retribution",
            "Windwalker", "Havoc", "Devastation", "Arms", "Assassination"
        }
        local testClasses = {
            "PALADIN", "PRIEST", "MAGE", "ROGUE", "HUNTER",
            "SHAMAN", "DEATHKNIGHT", "WARLOCK", "MONK", "PRIEST",
            "DRUID", "PALADIN", "ROGUE", "WARRIOR", "HUNTER",
            "MAGE", "WARLOCK", "SHAMAN", "MONK", "PRIEST",
            "DEATHKNIGHT", "DEMONHUNTER", "EVOKER", "WARRIOR", "DRUID",
            "PRIEST", "PRIEST", "SHAMAN", "MONK", "PALADIN",
            "DRUID", "DRUID", "SHAMAN", "SHAMAN", "PALADIN",
            "MONK", "DEMONHUNTER", "EVOKER", "WARRIOR", "ROGUE"
        }
        local testRoles = {
            "TANK", "HEALER", "DAMAGER", "DAMAGER", "DAMAGER",
            "HEALER", "DAMAGER", "DAMAGER", "TANK", "HEALER",
            "HEALER", "HEALER", "DAMAGER", "DAMAGER", "DAMAGER",
            "DAMAGER", "DAMAGER", "HEALER", "HEALER", "DAMAGER",
            "TANK", "DAMAGER", "DAMAGER", "TANK", "TANK",
            "HEALER", "HEALER", "HEALER", "HEALER", "HEALER",
            "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER",
            "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER", "DAMAGER"
        }
        -- Spec IDs matching each class/role for accurate melee/ranged separation
        local testSpecs = {
            66,   -- 1  PALADIN/TANK      - Protection
            257,  -- 2  PRIEST/HEALER     - Holy
            63,   -- 3  MAGE/DAMAGER      - Fire (ranged)
            260,  -- 4  ROGUE/DAMAGER     - Outlaw (melee)
            254,  -- 5  HUNTER/DAMAGER    - Marksmanship (ranged)
            264,  -- 6  SHAMAN/HEALER     - Restoration
            251,  -- 7  DEATHKNIGHT/DPS   - Frost (melee)
            265,  -- 8  WARLOCK/DAMAGER   - Affliction (ranged)
            268,  -- 9  MONK/TANK         - Brewmaster
            256,  -- 10 PRIEST/HEALER     - Discipline
            105,  -- 11 DRUID/HEALER      - Restoration
            65,   -- 12 PALADIN/HEALER    - Holy
            259,  -- 13 ROGUE/DAMAGER     - Assassination (melee)
            71,   -- 14 WARRIOR/DAMAGER   - Arms (melee)
            255,  -- 15 HUNTER/DAMAGER    - Survival (melee)
            64,   -- 16 MAGE/DAMAGER      - Frost (ranged)
            266,  -- 17 WARLOCK/DAMAGER   - Demonology (ranged)
            264,  -- 18 SHAMAN/HEALER     - Restoration
            270,  -- 19 MONK/HEALER       - Mistweaver
            258,  -- 20 PRIEST/DAMAGER    - Shadow (ranged)
            250,  -- 21 DEATHKNIGHT/TANK  - Blood
            577,  -- 22 DEMONHUNTER/DPS   - Havoc (melee)
            1467, -- 23 EVOKER/DAMAGER    - Devastation (ranged)
            73,   -- 24 WARRIOR/TANK      - Protection
            104,  -- 25 DRUID/TANK        - Guardian
            257,  -- 26 PRIEST/HEALER     - Holy
            256,  -- 27 PRIEST/HEALER     - Discipline
            264,  -- 28 SHAMAN/HEALER     - Restoration
            270,  -- 29 MONK/HEALER       - Mistweaver
            65,   -- 30 PALADIN/HEALER    - Holy
            102,  -- 31 DRUID/DAMAGER     - Balance (ranged)
            103,  -- 32 DRUID/DAMAGER     - Feral (melee)
            263,  -- 33 SHAMAN/DAMAGER    - Enhancement (melee)
            262,  -- 34 SHAMAN/DAMAGER    - Elemental (ranged)
            70,   -- 35 PALADIN/DAMAGER   - Retribution (melee)
            269,  -- 36 MONK/DAMAGER      - Windwalker (melee)
            577,  -- 37 DEMONHUNTER/DPS   - Havoc (melee)
            1473, -- 38 EVOKER/DAMAGER    - Augmentation (ranged)
            72,   -- 39 WARRIOR/DAMAGER   - Fury (melee)
            261,  -- 40 ROGUE/DAMAGER     - Subtlety (melee)
        }
        local testHealthPercents = {
            0.95, 0.88, 0.72, 0.65, 0.80,
            0.92, 0.58, 0.75, 0.85, 0.70,
            0.90, 0.82, 0.68, 0.55, 0.78,
            0.88, 0.62, 0.95, 0.72, 0.60,
            0.98, 0.75, 0.82, 0.90, 0.85,
            0.78, 0.92, 0.65, 0.88, 0.70,
            0.82, 0.75, 0.68, 0.95, 0.58,
            0.85, 0.72, 0.80, 0.65, 0.90
        }
        local testPowerPercents = {
            0.85, 0.92, 0.78, 0.65, 0.70,
            0.88, 0.55, 0.82, 0.95, 0.72,
            0.80, 0.68, 0.90, 0.75, 0.85,
            0.62, 0.95, 0.70, 0.88, 0.78,
            0.92, 0.65, 0.85, 0.72, 0.80,
            0.90, 0.75, 0.82, 0.68, 0.95,
            0.78, 0.85, 0.70, 0.88, 0.62,
            0.80, 0.92, 0.75, 0.68, 0.85
        }
        
        local i = index
        local baseHealth = testHealthPercents[i] or 0.75
        local basePower = testPowerPercents[i] or 0.80
        
        -- Determine if this frame should be dead (frames 9, 17, 29)
        local isDead = (i == 9 or i == 17 or i == 29)
        
        -- ☠ THE OVERLAY NAMES A DEBUFF THAT IS ACTUALLY ON THE FRAME. This used to be a
        -- hardcoded index pattern ("i % 5 == 1 -> Magic") while the debuff ICONS came
        -- from the curated pool — two sources that were never linked, and once the
        -- per-frame rotation stopped them coinciding a unit showed a Poison overlay with
        -- three debuffs, none of them Poison. Ask the engine which types the frame's own
        -- debuff window holds; nil when it holds none, which is how the pool's untyped
        -- entries set how often an overlay appears at all.
        local dispelType = nil
        if not isDead then  -- Dead frames don't show dispels
            dispelType = DF.GetTestDebuffDispelType
                and DF:GetTestDebuffDispelType("raid" .. i, (DF:GetRaidDB() or {}).testDebuffCount or 2,
                    testClasses[i])
        end
        
        local result = {
            index = index,  -- Include index for test mode features
            name = testNames[i] or ("Player" .. i),
            class = testClasses[i] or "WARRIOR",
            role = testRoles[i] or "DAMAGER",
            specID = testSpecs[i] or 0,
            healthPercent = isDead and 0 or baseHealth,
            maxHealth = 100000,
            currentHealth = isDead and 0 or math.floor(baseHealth * 100000),
            powerPercent = isDead and 0 or basePower,
            absorbPercent = isDead and 0 or ((i % 3 == 0) and 0.15 or ((i % 5 == 0) and 0.10 or 0)),
            reducedMaxPct = isDead and 0 or ((i % 7 == 0) and 0.30 or ((i % 11 == 0) and 0.15 or 0)),
            healAbsorbPercent = isDead and 0 or ((i % 7 == 0) and 0.15 or 0),
            healPredictionPercent = isDead and 0 or ((i % 2 == 0) and 0.12 or ((i % 3 == 1) and 0.08 or 0)),  -- Show heal prediction on some frames
            status = isDead and "Dead" or nil,
            outOfRange = (i % 4 == 3) and not isDead,  -- Every 4th frame starting at 3, but not dead frames
            isLeader = (i == 1),
            raidTarget = (i <= 8) and i or nil,
            dispelType = dispelType,
            centerStatus = isDead and "resurrect" or ((i == 2 or i == 6) and "summon" or nil),  -- Dead get resurrect, frames 2 and 6 get summon
            -- New icon states
            isMainTank = (i == 1 or i == 25),  -- First frame and frame 25
            isMainAssist = (i == 2 or i == 26),  -- Second frame and frame 26
            isAFK = (i == 3),             -- Frame 3 is away
            isDND = (i == 15),            -- Frame 15 is busy (the AFK icon's other state)
            isPhased = (i == 4 or i == 20),  -- Frames 4 and 20
            inVehicle = (i == 5 or i == 30),  -- Frames 5 and 30
            isBGCarrier = (i == 2 or i == 10),  -- Frames 2 and 10 carry an objective
            isInCombat = (i == 1 or i == 7),  -- Frames 1 and 7 in combat
        }
        
        -- Apply animation if enabled
        if db.testAnimateHealth and DF.TestData.animationPhase then
            local phase = DF.TestData.animationPhase
            local offset = (i * 0.15) % 1
            local wave = math.sin((phase + offset) * math.pi * 2)
            
            result.healthPercent = math.max(0.1, math.min(1, baseHealth + wave * 0.15))
            result.currentHealth = math.floor(result.healthPercent * result.maxHealth)
        end
        
        return result
    end
    
    -- Party test data. DF.TestData.units holds the 5 real-party scenarios (a party
    -- maxes at 5). Main party frames are 0-based (index 0-4 -> units[1-5]); pinned
    -- PLAYER frames are 1-based, so a raw index+1 lookup overruns the table by one and
    -- blanks the last frame. Wrap into the table so every party-mode frame maps to a
    -- distinct scenario instead of nil. (Counts are capped at 5 at the call sites.)
    local units = DF.TestData.units
    local data = units[(index % #units) + 1]
    
    local result = {
        index = index,  -- Include index for test mode features
        name = data.name,
        class = data.class,
        role = data.role,
        specID = data.specID or 0,
        healthPercent = data.health,
        maxHealth = data.maxHealth,
        currentHealth = math.floor(data.health * data.maxHealth),
        powerPercent = 0.8,  -- Default power for party
        absorbPercent = data.absorb,
        reducedMaxPct = data.reducedMaxPct or 0,
        healAbsorbPercent = data.healAbsorb,
        healPredictionPercent = data.healPrediction or 0,
        status = data.status,
        outOfRange = data.outOfRange,
        isLeader = data.isLeader,
        isAssist = data.isAssist,
        raidTarget = data.raidTarget,
        -- Same rule as raid: the type comes from THIS frame's debuff window, not from the
        -- unit table's hardcoded value, so the overlay can never name a debuff the frame
        -- is not showing. data.dispelType is left in the table above as scenario notes.
        dispelType = (data.status ~= "Dead") and DF.GetTestDebuffDispelType
            and DF:GetTestDebuffDispelType((index == 0) and "player" or ("party" .. index),
                (DF:GetDB() or {}).testDebuffCount or 2, data.class) or nil,
        centerStatus = data.centerStatus,
        -- New icon states
        isMainTank = data.isMainTank,
        isMainAssist = data.isMainAssist,
        isAFK = data.isAFK,
        isDND = data.isDND,
        isPhased = data.isPhased,
        inVehicle = data.inVehicle,
        isBGCarrier = data.isBGCarrier,
        isInCombat = data.isInCombat,
    }
    
    -- Don't animate dead or offline units
    if data.status then
        result.healthPercent = 0
        result.currentHealth = 0
        result.absorbPercent = 0
        result.healAbsorbPercent = 0
        result.healPredictionPercent = 0
        return result
    end
    
    -- Apply animation if enabled (only for alive units) - health only, not absorbs
    -- ☠ WAS `0.65 + (wave * 0.35)`, WHICH THREW AWAY THE UNIT'S CONFIGURED HEALTH.
    -- Every party scenario collapsed onto one curve centred at 65%, so switching
    -- Animate Health on erased the five frames' distinct levels (100 / 95 / 60 / 30)
    -- and switching it off brought them back. The raid and boss branches always did
    -- this correctly -- `baseHealth + wave * 0.15` -- and this now matches them, so
    -- the three agree and the scenarios survive the toggle. (Audit, 2026-08-07.)
    if db.testAnimateHealth and DF.TestData.animationPhase then
        local phase = DF.TestData.animationPhase
        local offset = (index * 0.2) % 1
        local wave = math.sin((phase + offset) * math.pi * 2)
        local baseHealth = result.healthPercent or 0.75

        result.healthPercent = math.max(0.1, math.min(1, baseHealth + wave * 0.15))
        result.currentHealth = math.floor(result.healthPercent * result.maxHealth)
        -- Note: Absorbs use static values from test data, not animated
    end
    
    return result
end

-- Start test mode animation
function DF:StartTestAnimation()
    if DF.TestData.animationTimer then return end
    
    DF.TestData.animationPhase = 0
    DF.TestData.animationTimer = C_Timer.NewTicker(0.05, function()
        DF.TestData.animationPhase = (DF.TestData.animationPhase + 0.02) % 1
        
        -- Update party test frames (lightweight - health only)
        if DF.testMode then
            for i = 0, 4 do
                local frame = DF.testPartyFrames[i]
                if frame and frame:IsShown() then
                    DF:UpdateTestFrameHealthOnly(frame, i)
                end
            end
        end
        
        -- Update raid test frames (lightweight - health only)
        if DF.raidTestMode then
            local db = DF:GetRaidDB()
            local testFrameCount = db.raidTestFrameCount or 10
            for i = 1, testFrameCount do
                local frame = DF.testRaidFrames[i]
                if frame and frame:IsShown() then
                    DF:UpdateTestFrameHealthOnly(frame, i)
                end
            end
        end

        -- Update pinned test frames (mock non-secure frames — same for
        -- both player-mode and boss-mode pinned sets). Lightweight.
        if DF.PinnedFrames and DF.PinnedFrames.IsTestModeActive
            and DF.PinnedFrames:IsTestModeActive() then
            for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
                local pool = DF.PinnedFrames.testFrames[setIndex]
                if pool then
                    for i = 1, #pool do
                        local f = pool[i]
                        if f and f:IsShown() and f.dfTestIndex then
                            DF:UpdateTestFrameHealthOnly(f, f.dfTestIndex)
                        end
                    end
                end
            end
        end
    end)
end

-- Lightweight animation update - updates health and repositions bars
function DF:UpdateTestFrameHealthOnly(frame, index)
    if not frame or not frame.healthBar then return end

    local isRaid = frame.isRaidFrame
    local isBoss = frame.isPinnedBossFrame
    local testData = DF:GetTestUnitData(index, isRaid, isBoss)
    if not testData then return end
    
    local db = DF:GetFrameDB(frame)
    
    -- Dead or offline units should always show 0 health - no animation
    if testData.status then
        frame.healthBar:SetValue(0)
        frame.testAnimatedHealth = 0
        if frame.healthText and frame.healthText:IsShown() then
            frame.healthText:SetText("")
        end
        return
    end
    
    -- ☠ THIS USED TO ADD A SECOND SINE ON TOP OF AN ALREADY-ANIMATED VALUE.
    -- GetTestUnitData applies the animation itself (see its party/raid/boss
    -- branches), so testData.healthPercent arrives animated -- and this then added
    -- its OWN wave, with a different per-frame phase offset (`index` radians rather
    -- than 2*pi*(0.2*index % 1)). Two waves at different phases summed to an
    -- amplitude near 0.5 and clamped flat at a full bar once per cycle, and because
    -- any settings change re-renders through GetTestUnitData's formula alone, the
    -- bar visibly jumped between the two whenever anything was touched.
    --
    -- ★ One formula now: the ticker advances animationPhase and simply RENDERS what
    -- GetTestUnitData produced. Do not reintroduce a wave here. (Audit, 2026-08-07.)
    local health = testData.healthPercent or testData.health or 0.75

    -- Store animated health for bar updates
    frame.testAnimatedHealth = health
    
    -- Update health bar
    frame.healthBar:SetValue(health)

    -- ☠ A THIRD HEALTH-FADE RULE LIVED HERE and it disagreed with the real one on
    -- both counts: it crossed at `>= threshold - 0.5` where DF:ApplyHealthFadeAlpha
    -- crosses at `>` (matching the curve's threshold/100 -/+ 0.001 points), and its
    -- below-threshold alpha was a flat 1.0, ignoring rangeFadeAlpha -- so an
    -- out-of-range unit under the threshold dimmed live and did not in the preview.
    -- Stamping the ANIMATED fraction and calling the real function fixes both, and
    -- keeps every other dfHealthPct consumer honest mid-animation. (Audit, 2026-08-07.)
    frame.dfHealthPct = health
    frame.dfTestMaxHealth = testData.maxHealth
    frame.dfTestCurrentHealth = math.floor((testData.maxHealth or 100000) * health)
    if DF.ApplyHealthFadeAlpha then DF:ApplyHealthFadeAlpha(frame) end

    -- ★ LIVE'S MISSING-HEALTH RENDERER, not a copy of it. Two near-identical ~55-line
    -- restatements (value, texture, all four colour modes, the dead-colour override)
    -- lived in this file. DF.SetMissingHealthBarValue now reads the frame stamps, so
    -- there is one renderer; it also owns the BACKGROUND-mode hide, so no branch is
    -- needed here. (Audit, 2026-08-07.)
    if frame.missingHealthBar then
        DF.SetMissingHealthBarValue(frame.missingHealthBar, frame.unit, frame)
    end

    -- ★ Live's formatter, driven by the stamps above -- the preview kept two of its
    -- own, both of which disagreed with live. (Audit, 2026-08-07.)
    DF:ApplyHealthText(frame, db, DF.IsLegacyTextHidden and DF:IsLegacyTextHidden(frame))

    -- Update bars to follow animated health (use animated health value)
    local animatedTestData = {}
    for k, v in pairs(testData) do
        animatedTestData[k] = v
    end
    animatedTestData.healthPercent = health
    
    -- ☠ REDUCED MAX HEALTH MUST RE-RUN ON EVERY HEALTH CHANGE. Live's UpdateHealthFast
    -- calls it explicitly for exactly that reason; this ticker never did, so with
    -- Reduced Max Health + Clip Health Bar on, the clipped edge was set once by
    -- UpdateTestFrame and then stayed put while the bar animated underneath it.
    -- (Audit, 2026-08-07.)
    if DF.UpdateReducedMaxHealth then DF:UpdateReducedMaxHealth(frame) end

    -- Update absorb bars if enabled
    if db.testShowAbsorbs then
        DF:UpdateAbsorb(frame, animatedTestData)
        DF:UpdateHealAbsorb(frame, animatedTestData)
    end
    
    -- Update heal prediction if enabled
    if db.testShowHealPrediction ~= false then
        DF:UpdateHealPrediction(frame, animatedTestData)
    end
    
    -- Update dispel gradient if it's tracking health
    if frame.dfDispelOverlay and frame.dfDispelOverlay.gradientTracksHealth then
        frame.dfDispelOverlay.gradient:SetMinMaxValues(0, 1)
        frame.dfDispelOverlay.gradient:SetValue(health)
    end

    -- Text Designer: re-render health-category text so TD follows the animated
    -- health value (TestSource reads frame.testAnimatedHealth while animating).
    if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "health") end
end

-- Stop test mode animation
function DF:StopTestAnimation()
    if DF.TestData.animationTimer then
        DF.TestData.animationTimer:Cancel()
        DF.TestData.animationTimer = nil
    end
end

-- Update a frame with test data (works for both party and raid)
function DF:UpdateTestFrame(frame, index, applyLayout)
    if not frame or not frame.healthBar then return end

    local isRaid = frame.isRaidFrame
    local isBoss = frame.isPinnedBossFrame
    local testData = DF:GetTestUnitData(index, isRaid, isBoss)
    if not testData then return end

    -- Stamped rather than re-resolved: the aura drives below (and their bulk
    -- refresh siblings, which do NOT receive testData) all need it, and
    -- GetTestUnitData rebuilds the raid class/role/name arrays on every call.
    -- Index -> data is fixed for a pooled frame's whole life, so it cannot go
    -- stale. See DF:IsTestFrameDead.
    frame.dfTestIsDead = (testData.status == "Dead") or nil

    -- ★ THE SHARED STAMPS ElementAppearance's helpers prefer. Test frames carry REAL
    -- unit tokens ("raid1", "player"), so in an actual group UnitIsDeadOrGhost /
    -- UnitClass would answer about a real player standing next to you rather than
    -- about this scenario -- which is what forced those helpers to be walled off from
    -- test mode in the first place. Stamping is what lets the live appearance code run
    -- on a preview frame at all. (Audit, 2026-08-07.)
    frame.dfIsDead = (testData.status == "Dead") or (testData.status == "Offline") or false
    frame.dfIsOffline = (testData.status == "Offline") or false
    frame.dfClassToken = testData.class
    -- The health fraction, so the three curve-driven appearance functions can run
    -- on a preview frame. Live gets this from UnitHealthPercent(unit, true, curve),
    -- which is secret-safe and needs a REAL unit; the preview has a plain number.
    frame.dfHealthPct = testData.healthPercent or 1
    -- Absolute health, for the current / current-max / deficit text formats.
    frame.dfTestMaxHealth = testData.maxHealth
    frame.dfTestCurrentHealth = testData.currentHealth

    local db = DF:GetFrameDB(frame)

    -- Set dfInRange for test mode - consumed by the range/alpha systems
    -- If testShowOutOfRange is enabled and this unit is marked as out of range, set false
    -- Otherwise set true (in range)
    local isTestOutOfRange = db.testShowOutOfRange and testData.outOfRange and not testData.status
    frame.dfInRange = not isTestOutOfRange
    
    -- Update health bar (use 0-1 range for test mode)
    frame.healthBar:SetMinMaxValues(0, 1)
    local healthValue = testData.healthPercent
    
    if db.smoothBars and Enum and Enum.StatusBarInterpolation then
        frame.healthBar:SetValue(healthValue, Enum.StatusBarInterpolation.ExponentialEaseOut)
    else
        frame.healthBar:SetValue(healthValue)
    end

    -- Re-anchor the health bar with the frame padding inset, matching what
    -- UpdateUnitFrame does unconditionally for live frames. Without this the
    -- test path only re-anchored as a side effect of UpdateReducedMaxHealth,
    -- so frames with no active reduced-max clipping kept a stale inset and the
    -- padding looked inconsistent across test frames. UpdateReducedMaxHealth
    -- below may re-clip the right edge afterwards.
    local padding = db.framePadding or 0
    frame.healthBar:ClearAllPoints()
    frame.healthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, -padding)
    frame.healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -padding, padding)
    -- Keep the missing-health overlay inside the padding too (matches live frames).
    if frame.missingHealthBar then
        frame.missingHealthBar:ClearAllPoints()
        frame.missingHealthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, -padding)
        frame.missingHealthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -padding, padding)
    end

    if db.testShowReducedMaxHealth ~= false then
        frame.dfTestReducedMaxPct = testData.reducedMaxPct or 0
    else
        frame.dfTestReducedMaxPct = 0
    end
    if DF.UpdateReducedMaxHealth then DF:UpdateReducedMaxHealth(frame) end

    -- ★ LIVE'S MISSING-HEALTH RENDERER, not a copy of it. Two near-identical ~55-line
    -- restatements (value, texture, all four colour modes, the dead-colour override)
    -- lived in this file. DF.SetMissingHealthBarValue now reads the frame stamps, so
    -- there is one renderer; it also owns the BACKGROUND-mode hide, so no branch is
    -- needed here. (Audit, 2026-08-07.)
    if frame.missingHealthBar then
        DF.SetMissingHealthBarValue(frame.missingHealthBar, frame.unit, frame)
    end

    DF:ApplyHealthText(frame, db, DF.IsLegacyTextHidden and DF:IsLegacyTextHidden(frame))

    -- Update name
    local displayName = testData.name
    if displayName then
        local maxLen = db.nameTextLength or 0
        local truncMode = db.nameTextTruncateMode or "ELLIPSIS"
        
        if maxLen > 0 and DF:UTF8Len(displayName) > maxLen then
            if truncMode == "CUT" then
                displayName = DF:UTF8Sub(displayName, 1, maxLen)
            else
                displayName = DF:UTF8Sub(displayName, 1, maxLen) .. "..."
            end
        end
    end
    frame.nameText:SetText(displayName)
    
    -- Determine if this frame should show out-of-range effects
    -- OOR takes priority over dead fade (they should never multiply)
    local isOutOfRange = db.testShowOutOfRange and testData.outOfRange
    
    -- Calculate per-element alphas for out-of-range
    local iconsAlpha = 1.0
    local powerBarAlpha = 1.0
    local dispelAlpha = 1.0
    -- ⚠ NO missingBuff / defensive / auraDesigner ALPHAS HERE ANY MORE. Those three
    -- surfaces fade through ElementAppearance's own functions now (called after the
    -- drives, further down) rather than being hand-mirrored into this block -- which
    -- is how each of them shipped a silent no-fade bug in turn. Add nothing here
    -- that ElementAppearance already owns. (Audit, 2026-08-07.)
    -- Border stays 1.0 in whole-frame mode (the frame's SetAlpha cascade fades
    -- it); only element-specific mode needs its own border alpha.

    if isOutOfRange then
        if db.oorEnabled then
            -- Element-specific alpha mode.
            -- ⚠ EVERY FALLBACK HERE MIRRORS ElementAppearance.lua's OWN. Six of them
            -- used to be a blanket 0.55 against live's 0.1-0.5 -- background was out
            -- by 5.5x. Invisible today because Config seeds all six, so it only bites
            -- a profile missing a key (an old import, a hand-edited SavedVariables).
            -- If you add an oor*Alpha, copy live's fallback, do not invent one.
            iconsAlpha = db.oorIconsAlpha or 0.5
            powerBarAlpha = db.oorPowerBarAlpha or 0.2
            dispelAlpha = db.oorDispelOverlayAlpha or 0.2
        end
        -- ☠ NO `else` BRANCH, DELIBERATELY. Simple range-fade mode fades the WHOLE
        -- FRAME with one SetAlpha further down -- exactly as live's
        -- UpdateFrameAppearance does, and that is live's ONLY alpha write in this
        -- mode. This block used to ALSO push rangeFadeAlpha into every per-element
        -- variable, so the preview applied the fade twice and rendered
        -- rangeFadeAlpha SQUARED: 0.16 against live's 0.40 at the stock 0.4, with no
        -- setting needed to hit it. Every element left at 1.0 here is the fix -- the
        -- cascade supplies the dim. (Audit, 2026-08-07.)
        -- ⚠ The status icons are the one exception and are handled separately: they
        -- set SetIgnoreParentAlpha(true), so the cascade cannot reach them and
        -- DF:GetStatusIconFadeAlpha applies their fade explicitly in both modes.
    end

    -- Store alpha values for use by UpdateTestIcons and UpdateTestPowerBar
    frame.dfTestOORAlphas = {
        icons = iconsAlpha,
        power = powerBarAlpha,
        dispel = dispelAlpha,
    }
    
    -- Check if this is a dead/offline unit for dead fade handling
    local isDeadOrOffline = testData.status == "Dead" or testData.status == "Offline"
    local applyDeadFade = isDeadOrOffline and db.fadeDeadFrames and not isOutOfRange
    
    -- Store dead fade alphas for use by UpdateTestIcons and UpdateTestPowerBar
    -- OOR takes priority: skip dead fade storage when out of range
    if applyDeadFade then
        frame.dfTestDeadFadeAlphas = {
            icons = db.fadeDeadIcons or 1.0,
            power = db.fadeDeadPowerBar or 0.4,
            auras = db.fadeDeadAuras or 1.0,
        }
    else
        frame.dfTestDeadFadeAlphas = nil
    end
    
    -- Health-based fading (above threshold): only when in range, alive, and option enabled
    local healthPct = (testData.healthPercent or 1) * 100
    local threshold = db.healthFadeThreshold or 100
    local isAboveHealthThreshold = not isOutOfRange and not applyDeadFade
        and db.healthFadeEnabled
        and (healthPct >= threshold - 0.5)
    if isAboveHealthThreshold and db.hfCancelOnDispel and frame.dfDispelOverlay and frame.dfDispelOverlay:IsShown() then
        isAboveHealthThreshold = false
    end
    
    if isAboveHealthThreshold then
        -- ☠ SAME DOUBLE-APPLY AS THE RANGE FADE ABOVE, and the same fix. Live has no
        -- per-element health fade at all: ApplyHealthFadeAlpha resolves ONE alpha and
        -- writes it to the FRAME (ElementAppearance references health fade in exactly
        -- one place, inside UpdateFrameAppearance). The preview pushed healthFadeAlpha
        -- into every element AND set the frame, rendering 0.25 against live's 0.50 at
        -- the stock 0.5. Only the element-specific mode needs per-element values,
        -- because there the frame stays at 1.0.
        local hfAlpha = db.healthFadeAlpha or 0.5
        if db.oorEnabled then
            iconsAlpha = hfAlpha
            powerBarAlpha = hfAlpha
            dispelAlpha = hfAlpha
        end
        frame.dfTestHealthFadeAlphas = {
            icons = iconsAlpha,
            power = powerBarAlpha,
            dispel = dispelAlpha,
        }
    else
        frame.dfTestHealthFadeAlphas = nil
    end
    
    -- Name text colour + alpha: DF:UpdateNameTextAppearance owns both (it deliberately
    -- writes colour at alpha 1.0 and controls opacity through SetAlpha, so that
    -- SetAlphaFromBoolean keeps working). Applied by the shared pass further down.
    
    -- ☠ THE HEALTH-BAR AND BACKGROUND COLOUR BLOCKS USED TO LIVE HERE (~135 lines).
    -- DF:UpdateHealthBarAppearance and DF:UpdateBackgroundAppearance own both now and
    -- accept test frames, so the shared appearance pass at the end of this function
    -- applies them. The copy was not merely redundant, it was WRONG in two ways:
    --   * it MULTIPLIED the OOR alpha into the base (classColorAlpha * healthBarAlpha)
    --     where live REPLACES it -- so at Health Bar Alpha 0.5 with the stock OOR 0.2
    --     the preview rendered 0.10 against live's 0.20, and the background, which
    --     multiplies twice, rendered 0.03 against live's 0.10;
    --   * its PERCENT-mode gradient took the raw class token from testData while live
    --     resolves through the same stops with the frame's own colour weights.
    -- (Audit, 2026-08-07.)

    -- Frame-level alpha when not using element-specific OOR (same as live UpdateFrameAppearance)
    if not db.oorEnabled then
        if isOutOfRange then
            frame:SetAlpha(db.rangeFadeAlpha or db.rangeAlpha or 0.4)
        elseif isAboveHealthThreshold then
            frame:SetAlpha(db.healthFadeAlpha or 0.5)
        else
            frame:SetAlpha(1)
        end
    else
        frame:SetAlpha(1)
    end


    -- Health text colour + alpha: DF:UpdateHealthTextAppearance owns both, same as the
    -- name text. Applied by the shared pass below.
    
    -- Update absorb bars
    if db.testShowAbsorbs then
        DF:UpdateAbsorb(frame, testData)
        DF:UpdateHealAbsorb(frame, testData)
    else
        if frame.dfAbsorbBar then frame.dfAbsorbBar:Hide() end
        if frame.dfHealAbsorbBar then frame.dfHealAbsorbBar:Hide() end
        if frame.absorbOvershieldGlow then frame.absorbOvershieldGlow:Hide() end
        if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
        if frame.healAbsorbOvershieldGlow then frame.healAbsorbOvershieldGlow:Hide() end
        -- Hide attached textures used for ATTACHED mode test display
        if frame.absorbAttachedTexture then frame.absorbAttachedTexture:Hide() end
        if frame.healAbsorbAttachedTexture then frame.healAbsorbAttachedTexture:Hide() end
        -- Hide overflow bar
        if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
    end
    
    -- Update heal prediction (check test mode setting)
    if db.testShowHealPrediction ~= false then
        DF:UpdateHealPrediction(frame, testData)
    else
        if frame.dfHealPredictionBar then frame.dfHealPredictionBar:Hide() end
    end

    -- Update power/resource bar
    DF:UpdateTestPowerBar(frame, testData)
    
    -- Update test auras
    if db.testShowAuras then
        DF:UpdateTestAuras(frame)
    else
        -- 12.1 factory rows: entering test mode with Show Auras already off
        -- never reaches the UpdateTestAuras seam, so hide them here too (via
        -- the shown-caches the live drives key on).
        if frame.buffFactory then
            frame.buffFactory:GetFrame():Hide()
            frame.dfBuffFactoryShown = false
        end
        if frame.debuffFactory then
            frame.debuffFactory:GetFrame():Hide()
            frame.dfDebuffFactoryShown = false
        end
    end
    
    
    -- Update status text (Dead, Offline, etc.)
    if testData.status then
        if db.statusTextEnabled ~= false then
            DF:StyleStatusText(frame)
            -- testData.status is a KEY, not display text -- it is compared against
            -- "Dead"/"Offline" for colour and fade decisions elsewhere in this file,
            -- so it stays raw in the roster and resolves only here, at display.
            -- No fallback needed: both DF.L metatables return the key on a miss.
            frame.statusText:SetText(L[testData.status])
            frame.statusText:Show()
            frame.healthText:Hide()
        end
        DF:ApplyDeadFade(frame, testData.status, true)  -- true = forceApply for test mode
    else
        if frame.statusText then
            frame.statusText:Hide()
        end
        if db.showHealthText ~= false then
            frame.healthText:Show()
        end
        frame.dfDeadFadeApplied = false
        
        -- Apply out of range effect to auras: the container rows fade as one
        -- (alpha on the row's plain anchor frame is ours to set).
        -- ★ Row fades through the live functions now. They compose the same three
        -- inputs this used to (row opacity x dead fade x out-of-range) and, since
        -- 2026-08-07, use the row's own opacity as the BASE -- which live had been
        -- dropping. One implementation, so the slider cannot mean two things.
        if DF.UpdateBuffIconsAppearance then DF:UpdateBuffIconsAppearance(frame) end
        if DF.UpdateDebuffIconsAppearance then DF:UpdateDebuffIconsAppearance(frame) end
    end

    -- Text Designer: render TD text on this test frame using its simulated
    -- per-unit data. Gated inside DF:UpdateTextDesigner via frame.dfIsTestFrame
    -- + db.testShowTextDesigner; no-op when the TD module isn't loaded.
    if DF.UpdateTextDesigner then
        DF:UpdateTextDesigner(frame, "all")
        -- Mirror live frames: hide the built-in name/health/status text whenever
        -- "Hide Legacy Text" is on — independent of the TD test toggle, so
        -- disabling TD in test doesn't bring the old text (e.g. "Dead") back.
        -- Runs after the text was set/shown above.
        if DF.IsLegacyTextHidden and DF:IsLegacyTextHidden(frame) then
            if frame.nameText then frame.nameText:Hide() end
            if frame.healthText then frame.healthText:Hide() end
            if frame.statusText then frame.statusText:Hide() end
        end
    end

    -- Update test icons (role, leader, raid target). Gated by the unified "Icons"
    -- toggle (testShowStatusIcons) — same key the status icons use.
    if db.testShowStatusIcons ~= false then
        DF:UpdateTestIcons(frame, testData)
    else
        -- Hide only role/leader/target icons when disabled (not status icons)
        if frame.roleIcon then frame.roleIcon:Hide() end
        if frame.leaderIcon then frame.leaderIcon:Hide() end
        if frame.raidTargetIcon then frame.raidTargetIcon:Hide() end
    end
    
    -- Always update status icons (they have their own checkbox testShowStatusIcons)
    DF:UpdateTestStatusIcons(frame, testData)
    
    -- Update dispel overlay (uses the real dispel system, which has test mode
    -- support). Unconditional: UpdateDispelOverlay reads testShowDispelGlow
    -- itself, and its OFF path (HideDispelAndInvalidate) hides the FULL region
    -- set — the manual hide this replaces missed the EDGE gradients and the
    -- darken layer, leaving them behind when the checkbox was unticked.
    if DF.UpdateDispelOverlay then
        DF:UpdateDispelOverlay(frame)
    end
    
    -- Update missing buff icon if enabled
    if db.testShowMissingBuff then
        DF:UpdateTestMissingBuff(frame)
    else
        -- 12.1 factory strip: hide via the shown-cache the live drive keys on.
        if frame.missingBuffStrip and frame.dfMissingStripShown ~= false then
            frame.dfMissingStripShown = false
            frame.missingBuffStrip:Hide()
        end
    end
    
    -- Update defensive icons. Unconditional: the painter reads
    -- testShowExternalDef itself (it must also hide the 12.1 container row
    -- when the toggle is off, not just the legacy icon).
    DF:UpdateTestDefensiveBar(frame, testData)

    -- ★ FADES NOW COME FROM THE LIVE FUNCTIONS. These three used to be hand-mirrored
    -- here -- and each one shipped a bug first (the missing-buff strip, the defensive
    -- row and the AD indicators all silently stopped fading out of range, one at a
    -- time, because each had an oor*Alpha key in ElementAppearance with no counterpart
    -- in this file). ElementAppearance's own functions now accept test frames: every
    -- unit read they make goes through GetInRange / IsDeadOrOffline, both of which
    -- prefer the stamps set at the top of this function. One policy, one place.
    --
    -- ⚠ AFTER the two drives above, not before: both widgets are created LAZILY by
    -- those drives, so earlier in the pass they are still nil on a frame's first
    -- paint. Neither drive touches alpha, so setting it here sticks.
    -- Update Aura Designer test indicators through the factory containers — the
    -- SAME path as the bulk DF:UpdateAllTestAuraDesigner, so the per-frame and
    -- bulk previews can't drift (the legacy Engine:UpdateTestFrame is gone).
    --
    -- ☠ THIS MUST RUN *BEFORE* THE APPEARANCE PASS, NOT AFTER. SyncFrame re-styles
    -- each indicator, which resets its alpha host to the indicator's BASE alpha --
    -- so with it below, every out-of-range AD fade the appearance pass had just
    -- applied was wiped a few lines later. It is signature-gated, which is what made
    -- the bug look intermittent and sent three fixes to the wrong place: toggling a
    -- setting that changes nothing structural makes SyncFrame a no-op, the fade
    -- survives, and the preview looks correct -- while a fresh Test Mode open or a
    -- Quick Preset swap DOES change the signature, re-styles, and drops the AD
    -- indicator back to full opacity on an out-of-range frame. Measured with
    -- /df debug zorder: buff 0.20, debuff 0.20, missing-buff 0.50, AD 1.00, and one
    -- re-run of UpdateAuraDesignerAppearance took it straight to 0.20.
    -- (Audit follow-up, 2026-08-07.)
    local ADFactory = DF.AuraDesigner and DF.AuraDesigner.Factory
    if ADFactory then
        if db.testShowAuraDesigner and DF:IsAuraDesignerEnabled(frame)
            and not DF:IsTestFrameDead(frame) then
            ADFactory:SyncFrame(frame)
        else
            ADFactory:ClearFrame(frame)
        end
    end

    -- ★★ ONE SHARED APPEARANCE PASS, and it goes LAST. Everything that BUILDS or
    -- RE-STYLES a surface runs above; this is the only thing that decides what any of
    -- it looks like under range / dead / health fade, so nothing may run after it.
    -- ElementAppearance owns colour AND alpha for the border, the name/health/status
    -- text, the power bar, the four header icons, the dispel overlay, the aura rows,
    -- the four bars, missing buff, defensive and the Aura Designer -- 16 of its 19
    -- functions accept test frames now. The three that still bail (health bar,
    -- background, frame-level health fade) need a health stamp that does not exist
    -- yet, and keep their own blocks above.
    --
    -- ☠ THIS IS THE FIX FOR A WHOLE CLASS OF BUG. The pattern was: an oor*Alpha or
    -- fadeDead* key gets added to ElementAppearance and silently not to the copy that
    -- used to live here, and the preview quietly stops matching live. That happened to
    -- the missing-buff strip, the defensive row and the AD indicators in three separate
    -- reports over two days. ADD NOTHING HERE THAT ElementAppearance ALREADY APPLIES,
    -- and ADD NOTHING BELOW IT that touches alpha. (Audit, 2026-08-07.)
    if DF.UpdateAllElementAppearances then
        DF:UpdateAllElementAppearances(frame)
    end

    -- Update selection and aggro highlights for test mode
    -- UpdateHighlights now handles test mode internally
    if DF.UpdateHighlights then
        DF:UpdateHighlights(frame)
    end
end

-- Update test icons for a frame (accepts testData directly for unified approach)
function DF:UpdateTestIcons(frame, testData)
    if not frame then return end
    if not testData then return end
    
    local db = DF:GetFrameDB(frame)
    
    -- Role Icon
    if frame.roleIcon then
        local role = testData.role
        -- Only TANK/HEALER/DAMAGER have a role icon; a nil/"NONE" role shows none
        -- (matches live StatusIcons and avoids GetRoleIconTexture indexing a nil
        -- coord table for a roleless test unit).
        local shouldShow = (role == "TANK" or role == "HEALER" or role == "DAMAGER")

        -- ☠ WAS GATED ON db.roleIconOnlyInCombat, A KEY THAT DOES NOT EXIST -- one
        -- read, no writes, absent from Config, so it was always nil and the gate
        -- was always open. The real key is roleIconHideInCombat, and wiring it
        -- here would be pointless: test mode is torn down on
        -- PLAYER_REGEN_DISABLED, so the preview can never be on screen in combat.
        -- Removed rather than repointed. (Audit, 2026-08-07.)
        if shouldShow then
            if role == "TANK" then
                shouldShow = db.roleIconShowTank ~= false
            elseif role == "HEALER" then
                shouldShow = db.roleIconShowHealer ~= false
            elseif role == "DAMAGER" then
                shouldShow = db.roleIconShowDPS ~= false
            end
        end
        
        if shouldShow then
            DF:SetIconTextureOrAtlas(frame.roleIcon.texture, DF:GetRoleIconTexture(db, role))

            frame.roleIcon:Show()
            local scale = db.roleIconScale or 1.0
            local anchor = db.roleIconAnchor or "TOPLEFT"
            local x = db.roleIconX or 2
            local y = db.roleIconY or -2
            frame.roleIcon:SetScale(scale)
            frame.roleIcon:ClearAllPoints()
            frame.roleIcon:SetPoint(anchor, frame, anchor, x, y)
            
            -- Apply frame level
            frame.roleIcon:SetFrameLevel(frame:GetFrameLevel() + (db.roleIconFrameLevel or 30))
        else
            frame.roleIcon:Hide()
        end
    end
    
    -- Leader Icon
    if frame.leaderIcon then
        if not db.leaderIconEnabled then
            frame.leaderIcon:Hide()
        elseif testData.isLeader then
            frame.leaderIcon.texture:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
            frame.leaderIcon.texture:SetTexCoord(0, 1, 0, 1)
            frame.leaderIcon:Show()
            
            local scale = db.leaderIconScale or 1.0
            local anchor = db.leaderIconAnchor or "TOPLEFT"
            local x = db.leaderIconX or -2
            local y = db.leaderIconY or 2
            frame.leaderIcon:SetScale(scale)
            frame.leaderIcon:ClearAllPoints()
            frame.leaderIcon:SetPoint(anchor, frame, anchor, x, y)
            
            -- Apply frame level
            frame.leaderIcon:SetFrameLevel(frame:GetFrameLevel() + (db.leaderIconFrameLevel or 30))
        elseif testData.isAssist then
            frame.leaderIcon.texture:SetTexture("Interface\\GroupFrame\\UI-Group-AssistantIcon")
            frame.leaderIcon.texture:SetTexCoord(0, 1, 0, 1)
            frame.leaderIcon:Show()
            
            local scale = db.leaderIconScale or 1.0
            local anchor = db.leaderIconAnchor or "TOPLEFT"
            local x = db.leaderIconX or -2
            local y = db.leaderIconY or 2
            frame.leaderIcon:SetScale(scale)
            frame.leaderIcon:ClearAllPoints()
            frame.leaderIcon:SetPoint(anchor, frame, anchor, x, y)
            
            -- Apply frame level
            frame.leaderIcon:SetFrameLevel(frame:GetFrameLevel() + (db.leaderIconFrameLevel or 30))
        else
            frame.leaderIcon:Hide()
        end
    end
    
    -- Raid Target Icon
    if frame.raidTargetIcon then
        if not db.raidTargetIconEnabled then
            frame.raidTargetIcon:Hide()
        elseif testData.raidTarget then
            frame.raidTargetIcon.texture:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
            SetRaidTargetIconTexture(frame.raidTargetIcon.texture, testData.raidTarget)
            
            local scale = db.raidTargetIconScale or 1.5
            local anchor = db.raidTargetIconAnchor or "TOP"
            local x = db.raidTargetIconX or 0
            local y = db.raidTargetIconY or 2
            frame.raidTargetIcon:SetScale(scale)
            frame.raidTargetIcon:ClearAllPoints()
            frame.raidTargetIcon:SetPoint(anchor, frame, anchor, x, y)
            frame.raidTargetIcon:Show()
            
            -- Apply frame level
            frame.raidTargetIcon:SetFrameLevel(frame:GetFrameLevel() + (db.raidTargetIconFrameLevel or 30))
        else
            frame.raidTargetIcon:Hide()
        end
    end
    
    -- Ready Check Icon (show on leader frame only for demo)
    if frame.readyCheckIcon then
        if not db.readyCheckIconEnabled or db.testShowStatusIcons == false then
            frame.readyCheckIcon:Hide()
        elseif testData.isLeader then
            DF:SetUpgradedStatusIcon(frame.readyCheckIcon.texture, "Interface\\RaidFrame\\ReadyCheck-Ready")
            
            local scale = db.readyCheckIconScale or 1.0
            local anchor = db.readyCheckIconAnchor or "CENTER"
            local x = db.readyCheckIconX or 0
            local y = db.readyCheckIconY or 0
            frame.readyCheckIcon:SetScale(scale)
            frame.readyCheckIcon:ClearAllPoints()
            frame.readyCheckIcon:SetPoint(anchor, frame, anchor, x, y)
            frame.readyCheckIcon:Show()
            
            -- Apply frame level
            frame.readyCheckIcon:SetFrameLevel(frame:GetFrameLevel() + (db.readyCheckIconFrameLevel or 30))
        else
            frame.readyCheckIcon:Hide()
        end
    end
    
    -- Apply alpha to icons - check dead fade first, then health-based fade, then OOR alpha
    local alpha = 1.0
    if frame.dfTestDeadFadeAlphas and frame.dfTestDeadFadeAlphas.icons then
        alpha = frame.dfTestDeadFadeAlphas.icons
    elseif frame.dfDeadFadeApplied then
        return
    elseif frame.dfTestHealthFadeAlphas and frame.dfTestHealthFadeAlphas.icons then
        alpha = frame.dfTestHealthFadeAlphas.icons
    elseif frame.dfTestOORAlphas and frame.dfTestOORAlphas.icons then
        alpha = frame.dfTestOORAlphas.icons
    end
    
    if frame.roleIcon and frame.roleIcon:IsShown() then
        frame.roleIcon:SetAlpha(alpha)
    end
    if frame.leaderIcon and frame.leaderIcon:IsShown() then
        frame.leaderIcon:SetAlpha(alpha)
    end
    if frame.raidTargetIcon and frame.raidTargetIcon:IsShown() then
        frame.raidTargetIcon:SetAlpha(alpha)
    end
    if frame.readyCheckIcon and frame.readyCheckIcon:IsShown() then
        frame.readyCheckIcon:SetAlpha(alpha)
    end
end

-- Helper function to show icon as text or texture in test mode
-- ★ ShowTestIconAsText and ApplyTestIconTimerFont are GONE. The first restated
-- live's ShowIconAsText and then re-applied the font and text colour on top --
-- work DF:ApplyStatusIconSettings already does, and doing it a second time AFTERWARDS
-- clobbered any per-state tint. The second was already a one-line forward to
-- DF:ApplyTimerTextSettings, which ApplyStatusIconSettings also calls. The preview now
-- uses DF:ShowStatusIconAsText, which IS live's function. (Audit, 2026-08-07.)

-- Format seconds as M:SS for AFK timer
local function FormatTestAFKTime(seconds)
    if seconds < 3600 then
        return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
    else
        local hours = math.floor(seconds / 3600)
        local mins = math.floor((seconds % 3600) / 60)
        return string.format("%02d:%02d:%02d", hours, mins, seconds % 60)
    end
end

-- Track test AFK start times
local testAFKStartTimes = {}

-- Update only status icons (ready check, center status) - separated from role/leader icons
function DF:UpdateTestStatusIcons(frame, testData)
    if not frame then return end
    if not testData then return end
    
    local db = DF:GetFrameDB(frame)
    
    -- Ready Check Icon (show on leader frame only for demo)
    if frame.readyCheckIcon then
        if not db.readyCheckIconEnabled or db.testShowStatusIcons == false then
            frame.readyCheckIcon:Hide()
        elseif testData.isLeader then
            DF:SetUpgradedStatusIcon(frame.readyCheckIcon.texture, "Interface\\RaidFrame\\ReadyCheck-Ready")
            
            local scale = db.readyCheckIconScale or 1.0
            local anchor = db.readyCheckIconAnchor or "CENTER"
            local x = db.readyCheckIconX or 0
            local y = db.readyCheckIconY or 0
            frame.readyCheckIcon:SetScale(scale)
            frame.readyCheckIcon:ClearAllPoints()
            frame.readyCheckIcon:SetPoint(anchor, frame, anchor, x, y)
            frame.readyCheckIcon:Show()
            
            -- Apply frame level
            frame.readyCheckIcon:SetFrameLevel(frame:GetFrameLevel() + (db.readyCheckIconFrameLevel or 30))
        else
            frame.readyCheckIcon:Hide()
        end
    end
    
    -- Summon Icon
    if frame.summonIcon then
        if not db.summonIconEnabled or db.testShowStatusIcons == false then
            frame.summonIcon:Hide()
        elseif testData.centerStatus == "summon" then
            DF:SetUpgradedStatusIcon(frame.summonIcon.texture, "Interface\\RaidFrame\\Raid-Icon-SummonPending")
            
            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.summonIcon, db, "summonIcon")
            end
            
            -- Show as text or icon (with font and color settings)
            DF:ShowStatusIconAsText(frame.summonIcon, db.summonIconTextPending or "Summon", db.summonIconShowText)
            frame.summonIcon:Show()
            
        else
            frame.summonIcon:Hide()
        end
    end

    -- BG Objective Carrier Icon
    if frame.bgCarrierIcon then
        if not db.bgCarrierIconEnabled or db.testShowStatusIcons == false then
            frame.bgCarrierIcon:Hide()
        elseif testData.isBGCarrier then
            -- ☠ WAS HARDCODED inv_bannerpvp_02, so the per-classification art was
            -- unpreviewable -- and it did not even match CreateStatusIcons' _03 default.
            -- Live picks from PVP_CARRIER_TEXTURES by UnitPvpClassification; the preview
            -- walks the same table so each variant can be seen and styled.
            local carrierArt = DF.PVP_CARRIER_TEXTURES
                and DF.PVP_CARRIER_TEXTURES[(frame.index or 0) % 3]
            DF:SetUpgradedStatusIcon(frame.bgCarrierIcon.texture,
                carrierArt or "Interface\\Icons\\inv_bannerpvp_02")

            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.bgCarrierIcon, db, "bgCarrierIcon")
            end

            DF:ShowStatusIconAsText(frame.bgCarrierIcon, db.bgCarrierIconText or "FC", db.bgCarrierIconShowText)
            frame.bgCarrierIcon:Show()

        else
            frame.bgCarrierIcon:Hide()
        end
    end

    -- Combat Icon
    if frame.combatIcon then
        if not db.combatIconEnabled or db.testShowStatusIcons == false then
            frame.combatIcon:Hide()
        elseif testData.isInCombat then
            frame.combatIcon.texture:SetTexture("Interface\\CharacterFrame\\UI-StateIcon")
            frame.combatIcon.texture:SetTexCoord(0.5, 1.0, 0, 0.49)

            -- ☠ THE LIVE APPLIER, like the other seven icons. This block used to
            -- hand-roll scale/anchor/x/y, and the commit that converted the rest
            -- ("preview uses the live geometry applier") deleted this one's SetAlpha and
            -- SetFrameLevel WITHOUT converting it -- so it lost combatIconAlpha, lost
            -- combatIconFrameLevel, and lost the out-of-range/dead fade that
            -- ApplyStatusIconSettings folds in via GetStatusIconFadeAlpha. A new
            -- preview-vs-live fork, created by the change that was removing forks, and
            -- invisible at default settings because combatIconAlpha seeds to 1.
            -- The hand-rolled fallbacks disagreed with live's as well ("TOPLEFT"/2/-2
            -- against CENTER/0/0), which is another reason not to keep a second copy.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.combatIcon, db, "combatIcon")
            end
            frame.combatIcon:Show()

        else
            frame.combatIcon:Hide()
        end
    end

    -- Resurrection Icon
    if frame.resurrectionIcon then
        if not db.resurrectionIconEnabled or db.testShowStatusIcons == false then
            frame.resurrectionIcon:Hide()
        elseif testData.centerStatus == "resurrect" then
            DF:SetUpgradedStatusIcon(frame.resurrectionIcon.texture, "Interface\\RaidFrame\\Raid-Icon-Rez")
            -- ☠ ONLY THE CASTING GREEN WAS PREVIEWABLE. Live also renders the
            -- PENDING-ACCEPT state at (1, 1, 0, 0.75) -- a different colour AND a
            -- different alpha -- which a user could never see in order to judge it.
            -- Alternate by frame so both states are on screen at once.
            if ((frame.index or 0) % 2) == 1 then
                frame.resurrectionIcon.texture:SetVertexColor(1, 1, 0, 0.75)  -- pending accept
            else
                frame.resurrectionIcon.texture:SetVertexColor(0, 1, 0, 1)     -- being cast
            end
            
            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.resurrectionIcon, db, "resurrectionIcon")
            end
            
            -- Show as text or icon (with font and color settings)
            DF:ShowStatusIconAsText(frame.resurrectionIcon, db.resurrectionIconTextCasting or "Res...", db.resurrectionIconShowText)
            frame.resurrectionIcon:Show()
            
        else
            frame.resurrectionIcon:Hide()
        end
    end
    
    -- Phased Icon
    if frame.phasedIcon then
        if not db.phasedIconEnabled or db.testShowStatusIcons == false then
            frame.phasedIcon:Hide()
        elseif testData.isPhased then
            -- ☠ phasedIconShowLFGEye DID NOTHING IN THE PREVIEW -- it always drew the
            -- phasing icon, so the setting could not be judged. Live swaps to the LFG
            -- eye for a unit who is in another party's instance.
            DF:SetUpgradedStatusIcon(frame.phasedIcon.texture,
                db.phasedIconShowLFGEye and "Interface\\LFGFrame\\LFG-Eye"
                or "Interface\\TargetingFrame\\UI-PhasingIcon")
            
            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.phasedIcon, db, "phasedIcon")
            end
            
            -- Show as text or icon (with font and color settings)
            DF:ShowStatusIconAsText(frame.phasedIcon, db.phasedIconText or "Phased", db.phasedIconShowText)
            frame.phasedIcon:Show()
            
        else
            frame.phasedIcon:Hide()
        end
    end
    
    -- AFK Icon with timer support
    if frame.afkIcon then
        if not db.afkIconEnabled or db.testShowStatusIcons == false then
            frame.afkIcon:Hide()
            if frame.afkIcon.timerText then frame.afkIcon.timerText:Hide() end
        elseif testData.isAFK or testData.isDND then
            DF:SetUpgradedStatusIcon(frame.afkIcon.texture, "Interface\\FriendsFrame\\StatusIcon-Away")
            
            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.afkIcon, db, "afkIcon")
            end
            
            -- Track AFK start time for test mode
            local frameKey = tostring(frame)
            if testData.isAFK and not testAFKStartTimes[frameKey] then
                testAFKStartTimes[frameKey] = GetTime()
            end
            
            -- ☠ DND WAS UNPREVIEWABLE. Live renders it on this same icon with a
            -- different label and a red tint, and with the timer suppressed (a DND
            -- flag has no start time). Neither the label nor the colour could be
            -- judged from the preview. (Audit, 2026-08-07.)
            local statusText
            if testData.isDND then
                statusText = DF.L["DND"]
                if frame.afkIcon.text then
                    frame.afkIcon.text:SetTextColor(1, 0.2, 0.2, 1)
                end
                if frame.afkIcon.timerText then frame.afkIcon.timerText:Hide() end
                testAFKStartTimes[frameKey] = nil
            else
                statusText = db.afkIconText or "AFK"
                local showTimer = db.afkIconShowTimer ~= false

                -- Calculate timer if enabled
                if showTimer and testAFKStartTimes[frameKey] then
                    local elapsed = math.floor(GetTime() - testAFKStartTimes[frameKey])
                    local timerStr = FormatTestAFKTime(elapsed)

                    if db.afkIconShowText then
                        -- Text mode: show "AFK 1:23"
                        statusText = statusText .. " " .. timerStr
                        if frame.afkIcon.timerText then frame.afkIcon.timerText:Hide() end
                    else
                        -- Icon mode: show timer below icon
                        if frame.afkIcon.timerText then
                            frame.afkIcon.timerText:SetText(timerStr)
                            frame.afkIcon.timerText:Show()
                        end
                    end
                else
                    if frame.afkIcon.timerText then frame.afkIcon.timerText:Hide() end
                end
            end
            
            -- Show as text or icon
            DF:ShowStatusIconAsText(frame.afkIcon, statusText, db.afkIconShowText)
            if db.afkIconShowText and frame.afkIcon.text and DF.ApplyStableTextAnchor then
                DF:ApplyStableTextAnchor(frame.afkIcon.text, frame.afkIcon)
            end
            frame.afkIcon:Show()
            
        else
            frame.afkIcon:Hide()
            if frame.afkIcon.timerText then frame.afkIcon.timerText:Hide() end
            -- Clear AFK start time
            testAFKStartTimes[tostring(frame)] = nil
        end
    end
    
    -- Vehicle Icon
    if frame.vehicleIcon then
        if not db.vehicleIconEnabled or db.testShowStatusIcons == false then
            frame.vehicleIcon:Hide()
        elseif testData.inVehicle then
            DF:SetUpgradedStatusIcon(frame.vehicleIcon.texture, "Interface\\Vehicles\\UI-Vehicles-Raid-Icon")
            
            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.vehicleIcon, db, "vehicleIcon")
            end
            
            -- Show as text or icon (with font and color settings)
            DF:ShowStatusIconAsText(frame.vehicleIcon, db.vehicleIconText or "Vehicle", db.vehicleIconShowText)
            frame.vehicleIcon:Show()
            
        else
            frame.vehicleIcon:Hide()
        end
    end
    
    -- Raid Role Icon (MT/MA)
    if frame.raidRoleIcon then
        if not db.raidRoleIconEnabled or db.testShowStatusIcons == false then
            frame.raidRoleIcon:Hide()
        -- ☠ WAS `~= false`, which shows the icon when the key is nil; live tests
        -- it plainly, so a nil key hides it. Config seeds both to true, so the two
        -- only disagree on a profile predating the keys -- exactly where a preview
        -- is most likely to be trusted. Match live. (Audit, 2026-08-07.)
        elseif testData.isMainTank and db.raidRoleIconShowTank then
            DF:SetUpgradedStatusIcon(frame.raidRoleIcon.texture, "Interface\\GroupFrame\\UI-Group-MainTankIcon")
            
            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.raidRoleIcon, db, "raidRoleIcon")
            end
            
            -- Show as text or icon (with font and color settings)
            DF:ShowStatusIconAsText(frame.raidRoleIcon, db.raidRoleIconTextTank or "MT", db.raidRoleIconShowText)
            frame.raidRoleIcon:Show()
            
        elseif testData.isMainAssist and db.raidRoleIconShowAssist then
            DF:SetUpgradedStatusIcon(frame.raidRoleIcon.texture, "Interface\\GroupFrame\\UI-Group-MainAssistIcon")
            
            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.raidRoleIcon, db, "raidRoleIcon")
            end
            
            -- Show as text or icon (with font and color settings)
            DF:ShowStatusIconAsText(frame.raidRoleIcon, db.raidRoleIconTextAssist or "MA", db.raidRoleIconShowText)
            frame.raidRoleIcon:Show()
            
        else
            frame.raidRoleIcon:Hide()
        end
    end
    
    -- ★ NO SECOND ALPHA PASS. DF:ApplyStatusIconSettings (StatusIcons.lua) already
    -- folds DF:GetStatusIconFadeAlpha into each icon's alpha, and every icon above
    -- now goes through it. Re-applying here would square the fade -- the same
    -- mistake the range and health fades made before ef3c56e0.
    -- (Audit, 2026-08-07.)
end

-- ☠ A CORPSE CARRIES NO AURAS, so the preview must not draw any on one. Death
-- strips buffs and debuffs outright, and the defensive icon and missing-buff badge
-- describe things that only mean something on a living unit — a dead frame covered
-- in icons is a shape live play never produces, which makes it a bad reference for
-- judging layout (Krathe, 2026-08-06). The dispel overlay already did this.
--
-- Reads the stamp UpdateTestFrame leaves rather than re-resolving the unit data:
-- the bulk refreshers (UpdateAllTestAuras / MissingBuff / DefensiveBar /
-- AuraDesigner) have no testData to hand, and this has to give them the same
-- answer as the per-frame pass or the two previews drift.
function DF:IsTestFrameDead(frame)
    return (frame and frame.dfTestIsDead) == true
end

-- Test aura preview: drive the real 12.1 container rows on the test frame.
function DF:UpdateTestAuras(frame)
    if not frame then return end

    -- 12.1 (P5): test frames preview through the REAL containers — the drives
    -- create/keep the rows and the game's sample provider + the factory's curated
    -- test paint render them with the user's true layout, borders and fonts. The
    -- drives also hide the legacy hand-painted icon pools (no double render).
    -- Defensives, missing buffs and dispel preview through their own drives.
    if DF.AuraContainer and DF.AuraContainer.IsSupported() then
        local db = DF:GetFrameDB(frame)
        if db then
            -- The test panel's "Show Auras" toggle gates the preview rows on top
            -- of the real row enables. Off -> hide the row frames directly and
            -- keep the drives' shown-caches coherent so re-enabling re-shows.
            local showAuras = db.testShowAuras ~= false and not DF:IsTestFrameDead(frame)
            if db.showBuffs and showAuras and DF.DriveBuffFactory then
                DF:DriveBuffFactory(frame, db)
                -- Test count slider hot-applies (structural: the handle rebuilds).
                if frame.buffFactory and frame.buffFactory.SetTestMax then
                    frame.buffFactory:SetTestMax(db.testBuffCount or 2)
                end
            elseif frame.buffFactory then
                frame.buffFactory:GetFrame():Hide()
                frame.dfBuffFactoryShown = false
            end
            if db.showDebuffs and showAuras and DF.DriveDebuffFactory then
                DF:DriveDebuffFactory(frame, db)
                if frame.debuffFactory and frame.debuffFactory.SetTestMax then
                    frame.debuffFactory:SetTestMax(db.testDebuffCount or 2)
                end
            elseif frame.debuffFactory then
                frame.debuffFactory:GetFrame():Hide()
                frame.dfDebuffFactoryShown = false
            end
        end
        return
    end

end

-- Update test power bar (unified for party and raid)
function DF:UpdateTestPowerBar(frame, testData)
    if not frame then return end
    
    local db = DF:GetFrameDB(frame)
    
    -- Check if resource bar should be shown
    if not db.resourceBarEnabled then
        if frame.dfPowerBar then frame.dfPowerBar:Hide() end
        return
    end
    
    -- Check role-based filtering
    local showBar = true
    local hasAnyRoleFilter = db.resourceBarShowHealer or db.resourceBarShowTank or db.resourceBarShowDPS
    if hasAnyRoleFilter then
        if testData.role == "HEALER" then
            showBar = db.resourceBarShowHealer == true
        elseif testData.role == "TANK" then
            showBar = db.resourceBarShowTank == true
        else
            showBar = db.resourceBarShowDPS == true
        end
    else
        showBar = false
    end

    -- Check class-based filtering
    if showBar then
        local classFilter = db.resourceBarClassFilter
        if classFilter and testData.class and classFilter[testData.class] == false then
            showBar = false
        end
    end

    if not showBar then
        if frame.dfPowerBar then frame.dfPowerBar:Hide() end
        return
    end
    
    -- Power bar should already exist from Frames/Create.lua
    if not frame.dfPowerBar then return end

    -- Shared geometry/appearance (size incl. border inset, anchor, frame level,
    -- background, border) — identical to the live DF:ApplyResourceBarLayout, so the
    -- live and test renders can never drift.
    DF:LayoutResourceBar(frame, db)

    local bar = frame.dfPowerBar

    -- Value (mock — there's no real unit to query).
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(testData.powerPercent or 0.8)

    -- Fill colour: mirror DF:GetResourceBarColor's mode resolution (Power / Class /
    -- Custom) using the mock unit's testData (reads resourceBarColorMode so the
    -- preview reflects a "Class" pick from the Color Mode dropdown).
    local powerToken
    if testData.role == "HEALER" then
        powerToken = "MANA"
    elseif testData.role == "TANK" then
        powerToken = "RAGE"
    else
        powerToken = "ENERGY"
    end
    local mode = db.resourceBarColorMode or (db.resourceBarClassColor and "CLASS" or "POWER_TYPE")
    local classColor = mode == "CLASS" and testData.class and DF:GetClassColor(testData.class)
    if mode == "CUSTOM" then
        local c = db.resourceBarCustomColor or {r = 0, g = 0.5, b = 1}
        bar:SetStatusBarColor(c.r or 0, c.g or 0.5, c.b or 1, 1)
    elseif classColor then
        bar:SetStatusBarColor(classColor.r, classColor.g, classColor.b, 1)
    else
        local powerColor = DF:GetPowerColor(powerToken)
        bar:SetStatusBarColor(powerColor.r, powerColor.g, powerColor.b, 1)
    end

    -- Apply dead / health-based / OOR alpha
    local alpha = 1.0
    if frame.dfTestDeadFadeAlphas and frame.dfTestDeadFadeAlphas.power then
        alpha = frame.dfTestDeadFadeAlphas.power
    elseif frame.dfTestHealthFadeAlphas and frame.dfTestHealthFadeAlphas.power then
        alpha = frame.dfTestHealthFadeAlphas.power
    elseif frame.dfTestOORAlphas and frame.dfTestOORAlphas.power then
        alpha = frame.dfTestOORAlphas.power
    end
    bar:SetAlpha(alpha)
    bar:Show()
end


function DF:ShowTestFrames(silent)
    if InCombatLockdown() then
        DF:Say(L["Cannot enter test mode during combat."])
        return
    end

    -- Respect mode-enable flag: party test requires party frames
    if DF.db and DF.db.partyEnabled == false then
        DF:Say(L["Party frames are disabled. Enable them in General settings to use party test mode."])
        return
    end

    local db = DF:GetDB()
    DF.testMode = true
    -- 12.1 container preview (P5): flip the factory into test mode BEFORE any test
    -- frame renders — handle builds read the flag (sample provider + curated paint).
    if DF.AuraContainer and DF.AuraContainer.SetTestMode then
        DF.AuraContainer.SetTestMode(true)
    end

    -- Ensure test frame pool is created
    if not DF.testFramePoolInitialized then
        DF:CreateTestFramePool()
    end
    
    -- Hide ALL live frames via state drivers (combat-safe)
    -- If combat starts, state drivers auto-show the correct live frames
    DF:SetTestModeStateDrivers()
    
    -- Hide test raid container if showing party test
    if DF.testRaidContainer then
        DF.testRaidContainer:Hide()
    end
    
    -- Position and show test party container
    DF:PositionTestPartyContainer()
    DF.testPartyContainer:Show()
    
    -- Get test frame count
    local testFrameCount = db.testFrameCount or 5
    
    -- Show and update test frames
    for i = 0, 4 do
        local frame = DF.testPartyFrames[i]
        if frame then
            if i < testFrameCount then
                frame:Show()
                DF:ApplyTestFrameLayout(frame)
                DF:UpdateTestFrame(frame, i, true)  -- true = apply layout
            else
                frame:Hide()
            end
        end
    end
    
    -- Position test frames
    DF:LightweightPositionPartyTestFrames(testFrameCount)
    
    -- Start animation if enabled
    if db.testAnimateHealth then
        DF:StartTestAnimation()
    end
    
    -- Initialize and update test pet frames
    if DF.InitializeTestPetFrames then
        DF:InitializeTestPetFrames()
        DF:UpdateAllPetFrames(true)
    end

    -- Update dispel overlays for test mode
    if DF.UpdateAllTestDispelGlow then
        C_Timer.After(0.1, function()
            DF:UpdateAllTestDispelGlow()
        end)
    end
    
    -- Update targeted spells for test mode
    if DF.UpdateAllTestTargetedSpell then
        C_Timer.After(0.1, function()
            DF:UpdateAllTestTargetedSpell()
        end)
    end
    
    if not silent then
        DF:Say(L["Test mode enabled."])
    end

    -- Update permanent mover for party test mode
    C_Timer.After(0.1, function()
        DF:UpdatePermanentMoverVisibility()
        DF:UpdatePermanentMoverAnchor("party")
    end)

    -- Populate enabled boss-mode pinned sets with fake data
    if DF.PinnedFrames and DF.PinnedFrames.EnterTestMode then
        DF.PinnedFrames:EnterTestMode()
    end
end

-- Refresh all test frames (call this when settings change in test mode)
function DF:RefreshTestFrames()
    if not DF.testMode and not DF.raidTestMode then return end
    
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    -- Update party test frames
    if DF.testMode then
        local testFrameCount = db.testFrameCount or 5
        
        for i = 0, 4 do
            local frame = DF.testPartyFrames[i]
            if frame and frame:IsShown() then
                DF:UpdateTestFrame(frame, i)
            end
        end
    end
    
    -- Update raid test frames
    if DF.raidTestMode then
        local testFrameCount = raidDb.raidTestFrameCount or 10
        for i = 1, testFrameCount do
            local frame = DF.testRaidFrames[i]
            if frame and frame:IsShown() then
                DF:UpdateTestFrame(frame, i)
            end
        end
    end

    -- Pinned test frames follow the same settings changes (data/style refresh,
    -- no re-layout) — otherwise they only updated on Test Mode entry / reload.
    if DF.PinnedFrames and DF.PinnedFrames.RefreshTestMode then
        DF.PinnedFrames:RefreshTestMode(false)
    end
end

-- Apply layout/style settings to a test frame (fonts, sizes, textures, borders, etc.)
-- This should be called when visual settings change, not just when data changes
-- ☠ THIS USED TO RE-IMPLEMENT DF:ApplyFrameLayout AND THEN CALL IT. ~80 lines of
-- frame size, health-bar texture/orientation, missing-health orientation, border and
-- resource-bar layout -- every one of them already done inside ApplyFrameLayout,
-- which it invoked at the end via the ApplyFrameStyle alias (Update.lua: that alias
-- is a one-line forward). So the copy ran first and the real thing overwrote it.
--
-- Two things the copy got WRONG while it was there:
--   * raw SetSize instead of DF:SetPixelPerfectSize, and it read db.frameWidth where
--     live reads frame.dfPinnedWidth or db.frameWidth -- so it would have sized a
--     pinned frame by the global width. Inert only because it was never called on one.
--   * a missing-health TEXTURE write, which looked unique but is not: both test
--     update paths already set it (see the SafeSetStatusBarTexture calls in
--     UpdateTestFrame and UpdateTestFrameHealthOnly), as live does inside
--     SetMissingHealthBarValue.
--
-- Kept as a named function rather than deleted because call sites pair it with
-- UpdateTestFrame and the pairing reads clearly. (Audit, 2026-08-07.)
function DF:ApplyTestFrameLayout(frame)
    if not frame then return end
    if DF.ApplyFrameLayout then DF:ApplyFrameLayout(frame) end
end

-- Full refresh with layout application (use on test mode start or when settings change)
function DF:RefreshTestFramesWithLayout()
    if not DF.testMode and not DF.raidTestMode then return end
    
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    -- Update party test frames with full layout
    if DF.testMode then
        local testFrameCount = db.testFrameCount or 5
        
        for i = 0, 4 do
            local frame = DF.testPartyFrames[i]
            if frame then
                -- Apply layout settings first
                DF:ApplyTestFrameLayout(frame)
                
                if frame:IsShown() then
                    DF:UpdateTestFrame(frame, i, true)  -- true = apply aura layout
                end
            end
        end
        
        -- Re-position frames (handles sorting and arrangement)
        DF:LightweightPositionPartyTestFrames(testFrameCount)
    end
    
    -- Update raid test frames with full layout
    if DF.raidTestMode then
        local testFrameCount = raidDb.raidTestFrameCount or 10
        
        for i = 1, 40 do
            local frame = DF.testRaidFrames[i]
            if frame then
                -- Apply layout settings first
                DF:ApplyTestFrameLayout(frame)
                
                if frame:IsShown() then
                    DF:UpdateTestFrame(frame, i, true)
                end
            end
        end
        
        -- Re-position raid frames (LightweightPositionRaidTestFrames handles both group and flat layout)
        DF:LightweightPositionRaidTestFrames(testFrameCount)

        -- Re-anchor group labels to the (potentially re-sorted) first frame of each group
        if raidDb.raidUseGroups and raidDb.groupLabelEnabled and DF.UpdateRaidGroupLabels then
            DF:UpdateRaidGroupLabels()
        end
    end

    -- Pinned test frames follow the same layout changes (re-apply geometry, then
    -- render) — otherwise they only updated on Test Mode entry / reload.
    if DF.PinnedFrames and DF.PinnedFrames.RefreshTestMode then
        DF.PinnedFrames:RefreshTestMode(true)
    end

    -- Update highlights
    if DF.testMode or DF.raidTestMode then
        DF:UpdateAllTestHighlights()
    end

    -- Re-anchor permanent mover to updated test frames
    if DF.testMode then
        DF:UpdatePermanentMoverAnchor("party")
    end
    if DF.raidTestMode then
        DF:UpdatePermanentMoverAnchor("raid")
    end
end

-- Throttled layout refresh for slider changes (avoids flickering)
DF.lastLayoutRefresh = 0

-- Engine-side test-mode teardown: the state that is NOT owned by the test frames
-- themselves -- the global aura data provider, and the pinned-frame preview.
--
-- HideTestFrames / HideRaidTestFrames do this inline, but two OTHER paths tear test
-- mode down by clearing DF.testMode / DF.raidTestMode directly: combat entry
-- (Core.lua, PLAYER_REGEN_DISABLED) and zone change (Frames/Headers.lua,
-- PLAYER_ENTERING_WORLD). Both used to skip it, which left C_UnitAuras on the
-- SAMPLE provider for the rest of the session -- the restore lives only in
-- AuraContainer.SetTestMode's `else` branch. The [combat] state driver shows the
-- LIVE frames the instant combat starts, so they then rendered fake auras, with the
-- identity gate off, aura row caps stuck at the test slider value and missing-buff
-- badges on corpses. The watchdog could not recover it either: ensureProviderWatch
-- returns early while _ownsProviderSwitch is set, and only this path clears it.
--
-- Call AFTER the mode flags are cleared: the provider is shared between party and
-- raid, so it goes back to real data only when NEITHER mode is left running.
-- DF._testModeHandover covers the gap in a party<->raid SWAP. The GUI clears the
-- outgoing mode's flag before it sets the incoming one, so for that instant neither
-- is true and this would tear the engines down and immediately rebuild them — every
-- aura container reconfigured to parse LIVE data that nothing ever renders, plus a
-- full provider reset/switch round-trip. That intermediate state is invisible and
-- pure cost; the swap sets the flag across the hand-over so we simply stay in test
-- mode. The GUI clears it and calls this again, so a Show* that bails (raid frames
-- disabled, combat) still settles correctly.
function DF:TeardownTestModeEngines()
    local stillTesting = (DF.testMode or DF.raidTestMode or DF._testModeHandover) and true or false
    if DF.AuraContainer and DF.AuraContainer.SetTestMode then
        DF.AuraContainer.SetTestMode(stillTesting)
    end
    -- Pinned previews are shared between the two modes exactly like the provider,
    -- so only leave the preview once NEITHER mode is left running. ExitTestMode
    -- carries its own combat guard (it defers via pendingExitTestMode).
    if not stillTesting and DF.PinnedFrames and DF.PinnedFrames.testModeActive
        and DF.PinnedFrames.ExitTestMode then
        DF.PinnedFrames:ExitTestMode()
    end
end

function DF:HideTestFrames(silent)
    DF.testMode = false
    -- Restore the real aura provider only when NEITHER test mode remains active
    -- (party + raid share the global data-provider switch).
    DF:TeardownTestModeEngines()

    -- Stop animation only if raid test mode isn't using it
    local raidDb = DF:GetRaidDB()
    if not (DF.raidTestMode and raidDb.testAnimateHealth) then
        DF:StopTestAnimation()
    end
    
    -- Hide all test party frames and clean up test elements
    local ADEngine = DF.AuraDesigner and DF.AuraDesigner.Engine
    for i = 0, 4 do
        local frame = DF.testPartyFrames[i]
        if frame then
            -- Clear Aura Designer indicators (borders are parented to UIParent
            -- and survive frame:Hide, so they must be explicitly cleared)
            if ADEngine then ADEngine:ClearFrame(frame) end
            frame:Hide()
            -- Clean up test mode visuals
            if frame.absorbAttachedTexture then frame.absorbAttachedTexture:Hide() end
            if frame.healAbsorbAttachedTexture then frame.healAbsorbAttachedTexture:Hide() end
            if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
        end
    end

    -- Hide test container
    if DF.testPartyContainer then
        DF.testPartyContainer:Hide()
    end

    -- Hide test pet frames
    if DF.HideAllTestPetFrames then
        DF:HideAllTestPetFrames()
    end

    -- Hide personal targeted spell test icons
    if DF.HideTestPersonalTargetedSpells then
        DF:HideTestPersonalTargetedSpells()
    end

    -- Hide Targeted List demo bars
    if DF.HideTestTargetedList then
        DF:HideTestTargetedList()
    end
    
    -- Restore live frame visibility
    -- Clear state drivers so UpdateHeaderVisibility manages normally
    DF:ClearTestModeStateDrivers()
    if not InCombatLockdown() then
        if DF.UpdateHeaderVisibility then
            DF:UpdateHeaderVisibility()
        end
    end
    
    -- Update dispel overlays based on real unit data
    if DF.UpdateAllDispelOverlays then
        C_Timer.After(0.2, function()
            DF:UpdateAllDispelOverlays()
        end)
    end
    
    -- Update missing buff icons immediately when leaving test mode
    if not InCombatLockdown() and DF.UpdateAllMissingBuffIcons then
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then
                DF:UpdateAllMissingBuffIcons()
            end
        end)
    end
    
    -- Update pet frames based on real unit data
    if DF.UpdateAllPetFrames then
        C_Timer.After(0.1, function()
            DF:UpdateAllPetFrames(true)
        end)
    end
    
    if not silent then
        DF:Say(L["Test mode disabled."])
    end

    -- Update permanent mover after exiting party test mode
    C_Timer.After(0.1, function()
        DF:UpdatePermanentMoverVisibility()
        DF:UpdatePermanentMoverAnchor("party")
    end)

    -- Exit boss-mode pinned test only if raid test isn't still running
    if DF.PinnedFrames and DF.PinnedFrames.ExitTestMode
        and not DF.raidTestMode then
        DF.PinnedFrames:ExitTestMode()
    end
end

-- Toggle test mode (mode-aware based on GUI.SelectedMode)
function DF:ToggleTestMode()
    -- Cannot toggle test mode during combat (secure frame restrictions)
    if InCombatLockdown() then
        DF:Say(L["Cannot toggle test mode during combat."])
        return
    end

    -- Flip the USER's claim. Unlock holds its own, so this no longer needs to
    -- refuse while frames are unlocked: turning the preview off mid-unlock drops
    -- your claim, unlock keeps the frames it still needs to have something to
    -- drag, and locking then hides them because nobody is left asking.
    --
    -- The old refusal ("Cannot disable test mode while frames are unlocked")
    -- existed only to stop the snapshot going stale, and it never covered the
    -- toolbar button — which closes the PANEL without coming through here at
    -- all. That was the reported repro. See TestMode/Shim.lua.
    local scope = (DF.GUI and DF.GUI.SelectedMode == "raid") and "raid" or "party"
    -- The "frames stay visible while unlocked" line is emitted by SetTestModeOwner,
    -- not here: the toolbar button releases the claim through the panel's OnHide and
    -- never comes through this function, so a message here reached only one of the
    -- two buttons the user thinks of as the same control.
    DF:SetTestModeOwner(scope, "user", not DF:IsTestModeOwnedBy(scope, "user"))
end

-- Show raid test frames
function DF:ShowRaidTestFrames(silent)
    if InCombatLockdown() then
        DF:Say(L["Cannot enter test mode during combat."])
        return
    end

    -- Respect mode-enable flag: raid test requires raid frames
    if DF.db and DF.db.raidEnabled == false then
        DF:Say(L["Raid frames are disabled. Enable them in General settings to use raid test mode."])
        return
    end

    local db = DF:GetRaidDB()
    DF.raidTestMode = true
    -- 12.1 container preview (P5): flip the factory into test mode BEFORE any test
    -- frame renders — handle builds read the flag (sample provider + curated paint).
    if DF.AuraContainer and DF.AuraContainer.SetTestMode then
        DF.AuraContainer.SetTestMode(true)
    end

    -- Ensure test frame pool is created
    if not DF.testFramePoolInitialized then
        DF:CreateTestFramePool()
    end
    
    -- Hide ALL live frames via state drivers (combat-safe)
    -- If combat starts, state drivers auto-show the correct live frames
    DF:SetTestModeStateDrivers()
    
    -- Hide test party container if showing raid test
    if DF.testPartyContainer then
        DF.testPartyContainer:Hide()
    end
    
    -- Hide party pet frames (both live and test)
    if DF.petFrames and DF.petFrames.player then
        DF.petFrames.player:Hide()
    end
    for i = 1, 4 do
        if DF.partyPetFrames and DF.partyPetFrames[i] then
            DF.partyPetFrames[i]:Hide()
        end
    end
    if DF.HideAllTestPetFrames then
        DF:HideAllTestPetFrames()
    end
    
    -- Position and show test raid container
    DF:PositionTestRaidContainer()
    DF.testRaidContainer:Show()
    
    -- Update raid frames with test data
    DF:UpdateRaidTestFrames()
    
    -- Update group labels for test mode
    if DF.UpdateRaidGroupLabels then
        C_Timer.After(0.05, function()
            DF:UpdateRaidGroupLabels()
        end)
    end
    
    -- Start animation if enabled
    if db.testAnimateHealth then
        DF:StartTestAnimation()
    end
    
    -- Initialize and update test raid pet frames
    if DF.InitializeTestRaidPetFrames then
        DF:InitializeTestRaidPetFrames()
        DF:UpdateAllRaidPetFrames(true)
    end

    -- Update dispel overlays for test mode
    if DF.UpdateAllTestDispelGlow then
        C_Timer.After(0.1, function()
            DF:UpdateAllTestDispelGlow()
        end)
    end

    -- Update targeted spells for test mode
    if DF.UpdateAllTestTargetedSpell then
        C_Timer.After(0.1, function()
            DF:UpdateAllTestTargetedSpell()
        end)
    end

    -- Update GUI
    if DF.GUI and DF.GUI.UpdateThemeColors then
        DF.GUI.UpdateThemeColors()
    end

    -- Update permanent mover for raid test mode
    C_Timer.After(0.1, function()
        DF:UpdatePermanentMoverVisibility()
        DF:UpdatePermanentMoverAnchor("raid")
    end)

    -- Populate enabled boss-mode pinned sets with fake data
    if DF.PinnedFrames and DF.PinnedFrames.EnterTestMode then
        DF.PinnedFrames:EnterTestMode()
    end

    -- Same confirmation party mode gives. Raid never announced itself at all, and
    -- did not even take `silent` -- Panel.lua has been passing one to the Hide half
    -- for a while, which quietly did nothing.
    if not silent then
        DF:Say(L["Test mode enabled."])
    end
end

-- Hide raid test frames
function DF:HideRaidTestFrames(silent)
    DF.raidTestMode = false
    -- Restore the real aura provider only when NEITHER test mode remains active
    -- (party + raid share the global data-provider switch).
    DF:TeardownTestModeEngines()

    -- Stop animation if party test mode isn't using it
    local partyDb = DF:GetDB()
    if not (DF.testMode and partyDb.testAnimateHealth) then
        DF:StopTestAnimation()
    end
    
    -- Hide all test raid frames and clean up test elements
    local ADEngine = DF.AuraDesigner and DF.AuraDesigner.Engine
    for i = 1, 40 do
        local frame = DF.testRaidFrames[i]
        if frame then
            -- Clear Aura Designer indicators (borders are parented to UIParent
            -- and survive frame:Hide, so they must be explicitly cleared)
            if ADEngine then ADEngine:ClearFrame(frame) end
            frame:Hide()
            -- Clean up test mode visuals
            if frame.absorbAttachedTexture then frame.absorbAttachedTexture:Hide() end
            if frame.healAbsorbAttachedTexture then frame.healAbsorbAttachedTexture:Hide() end
            if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
        end
    end

    -- Hide test container
    if DF.testRaidContainer then
        DF.testRaidContainer:Hide()
    end

    -- Hide test raid pet frames
    if DF.HideAllTestRaidPetFrames then
        DF:HideAllTestRaidPetFrames()
    end

    -- Hide personal targeted spell test icons
    if DF.HideTestPersonalTargetedSpells then
        DF:HideTestPersonalTargetedSpells()
    end

    -- Hide Targeted List demo bars
    if DF.HideTestTargetedList then
        DF:HideTestTargetedList()
    end

    -- Hide group labels (they will be re-shown by UpdateRaidLayout if needed)
    if DF.raidGroupLabels then
        for g = 1, 8 do
            if DF.raidGroupLabels[g] then
                DF.raidGroupLabels[g]:Hide()
                if DF.raidGroupLabels[g].shadow then
                    DF.raidGroupLabels[g].shadow:Hide()
                end
            end
        end
    end
    
    -- Restore live frame visibility
    -- Clear state drivers so UpdateHeaderVisibility manages normally
    DF:ClearTestModeStateDrivers()
    if not InCombatLockdown() then
        if DF.UpdateHeaderVisibility then
            DF:UpdateHeaderVisibility()
        end
    end
    
    -- Update dispel overlays based on real unit data
    if DF.UpdateAllDispelOverlays then
        C_Timer.After(0.2, function()
            DF:UpdateAllDispelOverlays()
        end)
    end
    
    -- Update raid pet frames based on real unit data
    if DF.UpdateAllRaidPetFrames then
        C_Timer.After(0.1, function()
            DF:UpdateAllRaidPetFrames(true)
        end)
    end
    
    -- Update GUI
    if DF.GUI and DF.GUI.UpdateThemeColors then
        DF.GUI.UpdateThemeColors()
    end

    -- Update permanent mover after exiting raid test mode
    C_Timer.After(0.1, function()
        DF:UpdatePermanentMoverVisibility()
        DF:UpdatePermanentMoverAnchor("party")
    end)

    -- Exit boss-mode pinned test only if party test isn't still running
    if DF.PinnedFrames and DF.PinnedFrames.ExitTestMode
        and not DF.testMode then
        DF.PinnedFrames:ExitTestMode()
    end

    -- Same confirmation party mode gives; see ShowRaidTestFrames.
    if not silent then
        DF:Say(L["Test mode disabled."])
    end
end

-- Update raid test frames with test data
function DF:UpdateRaidTestFrames()
    local db = DF:GetRaidDB()
    local testFrameCount = db.raidTestFrameCount or 10
    
    -- Show/hide test frames (respecting group visibility settings)
    for i = 1, 40 do
        local frame = DF.testRaidFrames[i]
        if frame then
            if i <= testFrameCount then
                -- Check if this frame's group is visible
                local groupNum = math.ceil(i / 5)
                local showGroup = db.raidGroupVisible and db.raidGroupVisible[groupNum]
                if showGroup == nil then showGroup = true end
                if showGroup then
                    frame:Show()
                else
                    frame:Hide()
                end
            else
                frame:Hide()
            end
        end
    end
    
    -- Position test frames
    DF:LightweightPositionRaidTestFrames(testFrameCount)
    
    -- Apply test data to visible frames
    for i = 1, testFrameCount do
        local frame = DF.testRaidFrames[i]
        if frame then
            -- Use unified UpdateTestFrame with layout (true = apply aura layout)
            DF:ApplyTestFrameLayout(frame)
            DF:UpdateTestFrame(frame, i, true)
        end
    end
    
    -- Update group labels if enabled (only in group-based layout)
    if db.raidUseGroups and db.groupLabelEnabled and DF.UpdateRaidGroupLabels then
        DF:UpdateRaidGroupLabels()
    end
    
    -- Handle animation
    if db.testAnimateHealth then
        DF:StartTestAnimation()
    else
        -- Don't stop animation if party test mode is also active and animating
        local partyDb = DF:GetDB()
        if not (DF.testMode and partyDb.testAnimateHealth) then
            DF:StopTestAnimation()
        end
    end
end

-- Lightweight version for frame count changes during dragging
-- Shows/hides frames and repositions them without full layout recalculation
-- Note: This only applies to test mode - frame count slider is only visible in test mode
function DF:LightweightUpdateTestFrameCount()
    local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
    
    -- Only works in test mode
    if isRaidMode then
        if not DF.raidTestMode then return end
    else
        if not DF.testMode then return end
    end
    
    if isRaidMode then
        local db = DF:GetRaidDB()
        local testFrameCount = db.raidTestFrameCount or 10
        
        -- First pass: show/hide test frames (respecting group visibility settings)
        for i = 1, 40 do
            local frame = DF.testRaidFrames[i]
            if frame then
                if i <= testFrameCount then
                    -- Check if this frame's group is visible
                    local groupNum = math.ceil(i / 5)
                    local showGroup = db.raidGroupVisible and db.raidGroupVisible[groupNum]
                    if showGroup == nil then showGroup = true end
                    if showGroup then
                        frame:Show()
                        -- Update test data without layout
                        DF:UpdateTestFrame(frame, i, false)
                    else
                        frame:Hide()
                    end
                else
                    frame:Hide()
                end
            end
        end
        
        -- Second pass: reposition visible frames using layout logic
        DF:LightweightPositionRaidTestFrames(testFrameCount)
    else
        -- Party mode
        local db = DF:GetDB()
        local testFrameCount = db.testFrameCount or 5
        
        -- Test party frames (indices 0-4)
        for i = 0, 4 do
            local frame = DF.testPartyFrames[i]
            if frame then
                if i < testFrameCount then
                    frame:Show()
                    DF:UpdateTestFrame(frame, i, false)
                else
                    frame:Hide()
                end
            end
        end
        
        -- Reposition party frames
        DF:LightweightPositionPartyTestFrames(testFrameCount)
    end
end

-- Lightweight positioning for raid test frames
-- Includes support for groupAnchor, playerAnchor, and groupOrder
function DF:LightweightPositionRaidTestFrames(testFrameCount)
    local db = DF:GetRaidDB()
    if not DF.testRaidContainer then return end
    
    -- Check if using flat grid layout instead of group-based
    if not db.raidUseGroups then
        return DF:LightweightPositionRaidTestFramesFlat(testFrameCount)
    end
    
    -- Use SecureSort's group positioning functions
    local SecureSort = DF.SecureSort
    if not SecureSort then
        DF:Say("Secure sort unavailable", "falling back to flat layout", "WARN")
        return DF:LightweightPositionRaidTestFramesFlat(testFrameCount)
    end
    
    -- Update group layout params from current settings
    SecureSort:UpdateRaidGroupLayoutParams()
    local lp = SecureSort.raidGroupLayoutParams
    -- Signal to PositionRaidFrameToGroupSlot that this is a test-mode call so it
    -- mirrors the live secure snippet's BOTTOMLEFT anchor when playerAnchor=END.
    -- Safe: UpdateRaidGroupLayoutParams replaces the whole table on its next call,
    -- so the flag does not survive into the live-frame positioning path. (#875)
    lp.testMode = true

    -- [LEAK-TEST] Simulates the proposed patch's mutation. Now redundant since
    -- the patch is in place above, but kept opt-in for diagnostic continuity.
    if DF.debugLeakTestSimulate then
        lp.testMode = true
        if DF.debugLeakTest then
            DF:Say("LEAK-TEST: TestMode SIMULATED patch mutation: lp.testMode = true written")
        end
    end

    if DF.debugLeakTest then
        DF:Say(string.format(
            "LEAK-TEST: LightweightPositionRaidTestFrames entered  lp.testMode=%s",
            tostring(lp.testMode)
        ))
    end

    -- Build frame list with test data for sorting
    local frameList = {}
    for i = 1, testFrameCount do
        local frame = DF.testRaidFrames[i]
        if frame and frame:IsShown() then
            local testData = DF:GetTestUnitData(i, true)  -- true = isRaid
            local groupNum = math.ceil(i / 5)  -- Test mode: 5 per group
            table.insert(frameList, {
                frame = frame,
                index = i,
                isPlayer = (i == 1),
                testData = testData,
                groupNum = groupNum
            })
            -- Set frame size
            frame:SetSize(lp.frameWidth, lp.frameHeight)
        end
    end
    
    -- Apply sorting if enabled (mirrors secure sort behavior)
    if db.sortEnabled and DF.Sort and DF.Sort.SortFrameList then
        frameList = DF.Sort:SortFrameList(frameList, db, true)  -- true = isTestMode
    end
    
    -- Build group membership from sorted frame list
    local groupPlayerCounts = {}  -- groupNum -> count of players
    local activeGroups = {}       -- groupNum -> true if has players
    local activeGroupList = {}    -- ordered list of active group numbers
    local groupCurrentPos = {}    -- groupNum -> current position (for sorted placement)
    
    for _, entry in ipairs(frameList) do
        local groupNum = entry.groupNum
        groupPlayerCounts[groupNum] = (groupPlayerCounts[groupNum] or 0) + 1
        
        if not activeGroups[groupNum] then
            activeGroups[groupNum] = true
            table.insert(activeGroupList, groupNum)
        end
    end
    
    -- Sort activeGroupList using custom display order from settings
    local displayOrder = db.raidGroupDisplayOrder or {1, 2, 3, 4, 5, 6, 7, 8}
    -- Build reverse lookup: group number -> display position
    local displayPos = {}
    for pos, groupNum in ipairs(displayOrder) do
        displayPos[groupNum] = pos
    end
    table.sort(activeGroupList, function(a, b)
        return (displayPos[a] or a) < (displayPos[b] or b)
    end)
    
    -- Calculate and set container size
    local totalWidth, totalHeight = SecureSort:CalculateRaidGroupContainerSize(#activeGroupList, lp)
    DF.testRaidContainer:SetSize(totalWidth, totalHeight)
    DF:SyncRaidMoverToContainer()

    -- Track the first AND last frame of each group.
    -- ☠ THE GROUP LABEL ANCHORED TO THE FIRST FRAME. Live anchors it to the group's
    -- separated HEADER, which spans the whole group -- so Label Position = END put the
    -- label past the end of the group live, but only past the FIRST FRAME in the
    -- preview, i.e. inside the group; CENTER centred on the first frame instead of the
    -- group. START happened to agree, which is why it went unnoticed. The preview now
    -- builds a per-group extent frame spanning first..last and anchors to that, so all
    -- three positions read the same geometry live does. (Audit, 2026-08-07.)
    DF.testGroupFirstFrame = DF.testGroupFirstFrame or {}
    DF.testGroupLastFrame = DF.testGroupLastFrame or {}
    wipe(DF.testGroupFirstFrame)
    wipe(DF.testGroupLastFrame)

    -- Position each frame in sorted order (this applies sorting within groups)
    for _, entry in ipairs(frameList) do
        local frame = entry.frame
        local groupNum = entry.groupNum
        local playersInGroup = groupPlayerCounts[groupNum]

        -- Get position within group (increments for each frame in the group)
        local posInGroup = groupCurrentPos[groupNum] or 0
        groupCurrentPos[groupNum] = posInGroup + 1

        -- Store the first and last frame of each group for label anchoring
        if posInGroup == 0 then
            DF.testGroupFirstFrame[groupNum] = frame
        end
        DF.testGroupLastFrame[groupNum] = frame

        -- Position using shared function
        SecureSort:PositionRaidFrameToGroupSlot(
            frame,
            groupNum,
            posInGroup,
            playersInGroup,
            activeGroupList,
            lp,
            DF.testRaidContainer
        )
    end

    DF:UpdateTestGroupExtents()
end

-- One invisible frame per active group, spanning its first slot's TOPLEFT to its last
-- slot's BOTTOMRIGHT. This is the preview's stand-in for a live separated header: the
-- object group labels anchor to. Positions within a group only ever increase in x and
-- decrease in y (PositionRaidFrameToGroupSlot walks posInGroup one way), so first and
-- last really are the two opposite corners in both grow directions.
function DF:UpdateTestGroupExtents()
    if not DF.testRaidContainer then return end
    DF.testGroupExtent = DF.testGroupExtent or {}
    for g = 1, 8 do
        local first = DF.testGroupFirstFrame and DF.testGroupFirstFrame[g]
        local last = DF.testGroupLastFrame and DF.testGroupLastFrame[g]
        local extent = DF.testGroupExtent[g]
        if first and last then
            if not extent then
                extent = CreateFrame("Frame", nil, DF.testRaidContainer)
                DF.testGroupExtent[g] = extent
            end
            extent:ClearAllPoints()
            extent:SetPoint("TOPLEFT", first, "TOPLEFT", 0, 0)
            extent:SetPoint("BOTTOMRIGHT", last, "BOTTOMRIGHT", 0, 0)
            extent:Show()
        elseif extent then
            extent:Hide()
        end
    end
end

-- Lightweight positioning for raid test frames in flat (non-group) layout mode
function DF:LightweightPositionRaidTestFramesFlat(testFrameCount)
    local db = DF:GetRaidDB()
    if not DF.testRaidContainer then return end
    
    -- Use SecureSort's shared positioning function
    local SecureSort = DF.SecureSort
    if SecureSort then
        -- Update raid layout params from current settings
        SecureSort:UpdateRaidLayoutParams()
        
        -- Calculate container size (for max 40 players)
        local lp = SecureSort.raidLayoutParams
        local playersPerRow = lp.playersPerRow or 5
        local maxNumRows, maxNumCols
        if lp.horizontal then
            maxNumCols = playersPerRow
            maxNumRows = math.ceil(40 / playersPerRow)
        else
            maxNumRows = playersPerRow
            maxNumCols = math.ceil(40 / playersPerRow)
        end
        local maxWidth = maxNumCols * lp.frameWidth + (maxNumCols - 1) * lp.hSpacing
        local maxHeight = maxNumRows * lp.frameHeight + (maxNumRows - 1) * lp.vSpacing
        
        -- Size the container
        DF.testRaidContainer:SetSize(maxWidth, maxHeight)
        DF:SyncRaidMoverToContainer()

        -- Build frame list with test data for sorting
        local frameList = {}
        for i = 1, testFrameCount do
            local frame = DF.testRaidFrames[i]
            if frame and frame:IsShown() then
                local testData = DF:GetTestUnitData(i, true)  -- true = isRaid
                table.insert(frameList, {
                    frame = frame,
                    index = i,
                    isPlayer = (i == 1),  -- First frame is "player" in test mode
                    testData = testData
                })
                -- Set frame size
                frame:SetSize(lp.frameWidth, lp.frameHeight)
            end
        end
        
        -- Apply sorting if enabled (mirrors secure sort behavior)
        if db.sortEnabled and DF.Sort and DF.Sort.SortFrameList then
            frameList = DF.Sort:SortFrameList(frameList, db, true)  -- true = isTestMode
        end
        
        -- Position frames in sorted order using SecureSort positioning
        for slotIndex, entry in ipairs(frameList) do
            local slot = slotIndex - 1  -- Convert to 0-based slot
            SecureSort:PositionRaidFrameToSlot(entry.frame, slot, testFrameCount, lp, DF.testRaidContainer)
        end
        return
    end
    
    -- No fallback below: SecureSort owns flat raid test positioning. Without it there is
    -- nothing to place the frames, which is the same behaviour this has always had.
end

-- Lightweight positioning for party test frames
function DF:LightweightPositionPartyTestFrames(testFrameCount)
    local db = DF:GetDB()
    if not DF.testPartyContainer then return end
    
    -- Use SecureSort's shared positioning function
    local SecureSort = DF.SecureSort
    if SecureSort then
        -- Update party layout params from current settings
        SecureSort:UpdateLayoutParams("party")
        local lp = SecureSort.layoutParams
        
        -- Calculate container size (max possible size for 5 frames)
        local containerWidth, containerHeight
        if lp.horizontal then
            containerWidth = 5 * lp.frameWidth + 4 * lp.spacing
            containerHeight = lp.frameHeight
        else
            containerWidth = lp.frameWidth
            containerHeight = 5 * lp.frameHeight + 4 * lp.spacing
        end
        
        -- Update container size
        DF.testPartyContainer:SetSize(containerWidth, containerHeight)
        
        -- Build frame list with test data for sorting
        local frameList = {}
        
        -- Test party frames (indices 0-4)
        for i = 0, 4 do
            local frame = DF.testPartyFrames[i]
            if frame and i < testFrameCount then
                local testData = DF:GetTestUnitData(i, false)  -- false = not raid
                table.insert(frameList, {
                    frame = frame,
                    index = i,
                    isPlayer = (i == 0),
                    testData = testData
                })
                frame:SetSize(lp.frameWidth, lp.frameHeight)
            end
        end
        
        -- Apply sorting if enabled (mirrors secure sort behavior)
        if db.sortEnabled and DF.Sort and DF.Sort.SortFrameList then
            frameList = DF.Sort:SortFrameList(frameList, db, true)  -- true = isTestMode
        end
        
        -- Position frames in sorted order using SecureSort positioning
        for slotIndex, entry in ipairs(frameList) do
            local slot = slotIndex - 1  -- Convert to 0-based slot
            SecureSort:PositionFrameToSlot(entry.frame, slot, #frameList, lp, DF.testPartyContainer)
        end
        return
    end

    -- ☠ A SECOND, UNREACHABLE PARTY LAYOUT USED TO LIVE HERE -- ~76 lines behind
    -- 'Fallback: if SecureSort not available'. Features/SecureSort.lua is
    -- unconditional in the .toc (line 124) and assigns DF.SecureSort at load, so the
    -- branch above always returns and this never ran. It also used a DIFFERENT
    -- growthAnchor formula to CalculateSlotPosition -- a third statement of the same
    -- geometry that no longer had to agree with anything. (Audit, 2026-08-07.)
end

-- Throttled version of UpdateRaidTestFrames for slider callbacks
-- Now integrates with the targeted update system (no timers)
function DF:ThrottledUpdateRaidTestFrames()
    if DF.sliderDragging then
        if DF.sliderLightweightFunc then
            -- During drag, only call the lightweight update function
            DF.sliderLightweightFunc()
        end
        -- If no lightweight func, skip entirely until release
        return
    end
    
    -- Not dragging - update directly
    if DF.raidTestMode then
        DF:UpdateRaidTestFrames()
    end
end

-- ============================================================
-- TEST PRESETS
-- ============================================================
-- Presets are DECLARATIVE and EXHAUSTIVE: each lists only the toggles it turns
-- ON, and applying it forces every other key in TEST_TOGGLE_KEYS OFF. So a new
-- test toggle is OFF in every preset until it's explicitly listed here — and
-- automatically ON in Full, which is built from the key list.
--
-- The old hand-written branches only covered 11 of the 19 panel toggles, so the
-- other 8 (pets, heal prediction, reduced max, Text Designer, Aura Designer,
-- animate targeted list, selection, aggro) kept whatever value they happened to
-- have. "Full" wasn't full, and "Static" wasn't a reproducible baseline.
--
-- Sliders (frame / buff / debuff counts) are deliberately NOT touched: they're a
-- working preference, not part of a preset's visual identity.
-- ============================================================

local TEST_TOGGLE_KEYS = {
    -- General
    "testShowPets", "testAnimateHealth",
    -- Bars & Overlays
    "testShowAbsorbs", "testShowHealPrediction", "testShowOutOfRange",
    "testShowReducedMaxHealth", "testShowTextDesigner",
    -- Auras
    "testShowAuras", "testShowDispelGlow", "testShowMissingBuff", "testShowAuraDesigner",
    -- Indicators & Icons
    "testShowExternalDef", "testShowTargetedList", "testAnimateTargetedList",
    "testShowPersonalTargeted", "testShowStatusIcons",
    -- Highlights
    "testShowSelection", "testShowAggro",
}

-- Toggles for PARTY-ONLY features — a raid preset must not touch them.
--   Targeted List: party-only outright (its keys are stripped from RaidDefaults
--     by PARTY_ONLY_KEYS in Config.lua, so writing them here would create keys
--     that are meant not to exist in the raid db).
-- Personal Targeted has no raid gate and is NOT listed here.
local TEST_PARTY_ONLY_KEYS = {
    testShowTargetedList    = true,
    testAnimateTargetedList = true,
}

local TEST_PRESETS = {
    -- The aura surfaces — the rows, the dispel overlay, the missing-buff badge and
    -- the Aura Designer — on an otherwise quiet frame, for working on aura layout.
    -- ⚠ The only preset that does NOT contain Default: out-of-range fading dims the
    -- whole frame, icons included, which is the one thing you cannot have while
    -- judging icon art.
    AURAS = {
        testShowPets             = true,
        testShowTextDesigner     = true,
        testShowAuras            = true,
        testShowDispelGlow       = true,
        testShowMissingBuff      = true,
        testShowAuraDesigner     = true,
        testShowTargetedList     = true,
        testAnimateTargetedList  = true,
        testShowPersonalTargeted = true,
    },
    -- Default plus what a pull adds: health movement and threat. The aura layers
    -- stay off — this one is for watching the bars move, and Auras is where you go
    -- to look at icons.
    COMBAT = {
        testShowPets             = true,
        testAnimateHealth        = true,
        testShowOutOfRange       = true,
        testShowTextDesigner     = true,
        testShowTargetedList     = true,
        testAnimateTargetedList  = true,
        testShowPersonalTargeted = true,
        testShowAggro            = true,
    },
    -- Default plus the healing-decision layers: absorbs, incoming heals, reduced
    -- max health and the defensive icon. Health stays still so those bars are
    -- readable, and the aura rows stay off so they do not cover them.
    HEALER = {
        testShowPets             = true,
        testShowAbsorbs          = true,
        testShowHealPrediction   = true,
        testShowOutOfRange       = true,
        testShowReducedMaxHealth = true,
        testShowTextDesigner     = true,
        testShowExternalDef      = true,
        testShowTargetedList     = true,
        testAnimateTargetedList  = true,
        testShowPersonalTargeted = true,
    },
}

-- Default = what a fresh profile ships with, and the preset the panel shows as
-- selected on first open. The bars and the frame's own text, with the aura and
-- icon layers off so the frame itself is what you are looking at.
--
-- ☠ testShowTextDesigner IS NOT OPTIONAL IN A MINIMAL PRESET. It does not gate a
-- decorative layer: Render.lua hides EVERY TD font string when it is off, and the
-- unit name and health text are TD elements — so a preset without it previews
-- nameless blank bars. This shipped for a few minutes as an empty "None" for
-- exactly that reason and was unusable (Krathe, 2026-08-06).
-- ⚠ Config.lua's test-mode defaults MIRROR THIS TABLE. Change one, change both.
TEST_PRESETS.DEFAULT = {
    testShowPets             = true,
    testShowOutOfRange       = true,
    testShowTextDesigner     = true,
    testShowTargetedList     = true,
    testAnimateTargetedList  = true,
    testShowPersonalTargeted = true,
}

-- Full = every toggle on. Built from the key list so a newly added toggle is
-- picked up automatically instead of quietly staying off.
TEST_PRESETS.FULL = {}
for _, k in ipairs(TEST_TOGGLE_KEYS) do TEST_PRESETS.FULL[k] = true end

-- Display order of the quick-preset buttons. The matcher below walks this rather than
-- pairs(TEST_PRESETS) so its answer is DETERMINISTIC: pairs order is undefined, and if two
-- presets ever describe the same state the highlight would otherwise flicker between them
-- from one refresh to the next.
local TEST_PRESET_ORDER = { "DEFAULT", "AURAS", "COMBAT", "HEALER", "FULL" }

-- ☠ TOGGLES DO NOT ALL DEFAULT THE SAME WAY WHEN UNSET, and the matcher has to resolve
-- them EXACTLY as the checkboxes do or the highlight will contradict the boxes the user is
-- looking at. These are the keys the panel reads as `db.key ~= false`, i.e. nil means ON;
-- every other key is read plain, so nil means OFF.
--
-- In practice Config.lua seeds all of them explicitly (and its values are exactly the
-- DEFAULT preset, so a fresh profile genuinely matches Default). This exists for the
-- profile that predates a newly added toggle, where the key really is nil.
local TEST_TOGGLE_DEFAULT_ON = {
    testShowPets             = true,
    testShowHealPrediction   = true,
    testShowReducedMaxHealth = true,
    testShowTextDesigner     = true,
    testShowPersonalTargeted = true,
    testShowStatusIcons      = true,
}

local function TestToggleOn(db, key)
    local v = db[key]
    if v == nil then return TEST_TOGGLE_DEFAULT_ON[key] == true end
    return v == true
end

-- Which preset, if any, the CURRENT toggles actually describe -- nil when they describe
-- none of them.
--
-- ☠ DERIVED, NEVER READ FROM db.testPreset. That key records the last preset CLICKED, which
-- stops being true the moment any toggle is flipped afterwards: click Default, turn on
-- Auras, and the panel went on highlighting Default while the settings were no longer
-- Default (Krathe, 2026-08-07). A preset button is a claim about state, so it has to be
-- answered from state. db.testPreset is still written by ApplyTestPreset -- it is a useful
-- record of intent -- but nothing may drive UI from it.
--
-- ⚠ Party-only keys are skipped in raid mode, mirroring ApplyTestPreset, which does not
-- write them there. Comparing keys a raid preset never sets would mean no raid state could
-- ever match anything.
function DF:GetActiveTestPreset()
    local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
    local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
    if not db then return nil end

    for _, name in ipairs(TEST_PRESET_ORDER) do
        local set = TEST_PRESETS[name]
        if set then
            local match = true
            for _, key in ipairs(TEST_TOGGLE_KEYS) do
                if not (isRaidMode and TEST_PARTY_ONLY_KEYS[key]) then
                    if TestToggleOn(db, key) ~= (set[key] == true) then
                        match = false
                        break
                    end
                end
            end
            if match then return name end
        end
    end
    return nil
end

-- Repaint every test surface. The panel's per-checkbox callbacks each poke their
-- own painter, so a preset — which can flip any of them at once — has to run the
-- lot or a toggle only lands once the box is clicked by hand.
local function RefreshAllTestSurfaces()
    if not (DF.testMode or DF.raidTestMode) then return end
    if DF.UpdateAllTestDispelGlow    then DF:UpdateAllTestDispelGlow() end
    if DF.UpdateAllTestMissingBuff   then DF:UpdateAllTestMissingBuff() end
    if DF.UpdateAllTestAuraDesigner  then DF:UpdateAllTestAuraDesigner() end
    if DF.UpdateAllTestDefensiveBar  then DF:UpdateAllTestDefensiveBar() end
    if DF.UpdateAllTestTargetedList  then DF:UpdateAllTestTargetedList() end
    if DF.UpdateAllTestTargetedSpell then DF:UpdateAllTestTargetedSpell() end
    if DF.UpdateAllTestHighlights    then DF:UpdateAllTestHighlights() end
    if DF.UpdateTextDesigner then
        for i = 0, 4 do
            local f = DF.testPartyFrames and DF.testPartyFrames[i]
            if f then DF:UpdateTextDesigner(f, "all") end
        end
        for i = 1, 40 do
            local f = DF.testRaidFrames and DF.testRaidFrames[i]
            if f then DF:UpdateTextDesigner(f, "all") end
        end
    end
end

-- Apply test preset
function DF:ApplyTestPreset(preset)
    local set = TEST_PRESETS[preset]
    if not set then return end

    local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
    local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
    if not db then return end

    for _, key in ipairs(TEST_TOGGLE_KEYS) do
        if not (isRaidMode and TEST_PARTY_ONLY_KEYS[key]) then
            db[key] = set[key] == true
        end
    end

    db.testPreset = preset

    -- Update appropriate frames
    if isRaidMode and DF.raidTestMode then
        DF:UpdateRaidTestFrames()
        if DF.UpdateAllRaidPetFrames then DF:UpdateAllRaidPetFrames(true) end
        RefreshAllTestSurfaces()
    elseif not isRaidMode and DF.testMode then
        DF:StopTestAnimation()
        if db.testAnimateHealth then
            DF:StartTestAnimation()
        end
        DF:UpdateAllFrames()
        if DF.UpdateAllPetFrames then DF:UpdateAllPetFrames(true) end
        RefreshAllTestSurfaces()
    end
end


-- ============================================================
-- TEST MODE HELPER FUNCTIONS
-- ============================================================

-- ☠ REBUILD WITHOUT REPAINT. Each of these bulk refreshers tears down and rebuilds
-- its surface -- the aura-container rows, the AD indicators, the defensive icon, the
-- missing-buff strip -- and the fresh widgets come back at ALPHA 1.0 carrying none of
-- the fade the appearance pass had applied. They run AFTER UpdateTestFrame's appearance
-- pass (ApplyTestPreset: UpdateAllFrames, then RefreshAllTestSurfaces), so flipping a
-- preset left every rebuilt surface at full opacity while the rest of the frame stayed
-- faded -- which is why a faded defensive icon had a full-brightness AD indicator
-- showing through it, and why toggling Out of Range off and on "fixed" it (that path
-- re-runs the appearance pass with nothing rebuilding behind it).
--
-- ★ Whoever rebuilds a surface repaints it, per frame, for that surface only. Putting
-- it here rather than at the call sites means the individual panel toggles (Aura
-- Designer, Defensive Icon, Missing Buff, Dispel Overlay), which rebuild without going
-- through RefreshAllTestSurfaces at all, are covered by the same fix.
-- (Audit follow-up, 2026-08-07.)
local function RepaintTestSurface(frame, which)
    if not frame then return end
    if which == "auras" then
        if DF.UpdateBuffIconsAppearance then DF:UpdateBuffIconsAppearance(frame) end
        if DF.UpdateDebuffIconsAppearance then DF:UpdateDebuffIconsAppearance(frame) end
    elseif which == "missingBuff" then
        if DF.UpdateMissingBuffAppearance then DF:UpdateMissingBuffAppearance(frame) end
    elseif which == "defensive" then
        if DF.UpdateDefensiveIconAppearance then DF:UpdateDefensiveIconAppearance(frame) end
    elseif which == "dispel" then
        if DF.UpdateDispelOverlayAppearance then DF:UpdateDispelOverlayAppearance(frame) end
    elseif which == "auraDesigner" then
        -- Order matters: UpdateAuraDesignerAppearance writes healthbarEffectiveBlend,
        -- which UpdateHealthBarAppearance reads (see UpdateAllElementAppearances).
        if DF.UpdateAuraDesignerAppearance then DF:UpdateAuraDesignerAppearance(frame) end
        if DF.UpdateHealthBarAppearance then DF:UpdateHealthBarAppearance(frame) end
    end
end

function DF:UpdateAllTestDispelGlow()
    -- Safety check - Dispel module may not be loaded yet
    if not DF.UpdateDispelOverlay then return end
    
    -- Update party test frames
    if DF.testMode then
        for i = 0, 4 do
            local frame = DF.testPartyFrames[i]
            if frame then
                DF:UpdateDispelOverlay(frame)
                RepaintTestSurface(frame, "dispel")
            end
        end
    end
    
    -- Update raid test frames
    if DF.raidTestMode then
        for i = 1, 40 do
            local frame = DF.testRaidFrames[i]
            if frame then
                DF:UpdateDispelOverlay(frame)
                RepaintTestSurface(frame, "dispel")
            end
        end
    end
end

-- Update all test frame highlights (selection, aggro, etc.)
function DF:UpdateAllTestHighlights()
    -- Safety check - Highlights module may not be loaded yet
    if not DF.UpdateHighlights then return end
    
    -- Update party test frames
    if DF.testMode then
        for i = 0, 4 do
            local frame = DF.testPartyFrames[i]
            if frame and frame:IsShown() then
                DF:UpdateHighlights(frame)
            end
        end
    end
    
    -- Update raid test frames
    if DF.raidTestMode then
        for i = 1, 40 do
            local frame = DF.testRaidFrames[i]
            if frame and frame:IsShown() then
                DF:UpdateHighlights(frame)
            end
        end
    end
end

-- Test missing buff icon
function DF:UpdateTestMissingBuff(frame)
    if not frame then return end

    local db = DF:GetFrameDB(frame)

    -- 12.1: the live missing-buff display is the factory badge STRIP (one badge
    -- per tracked buff, real spell icons — Auras.lua) — preview through the same
    -- drive so geometry and styling are live-true. Every badge renders "missing"
    -- because the provider bounce leaves missing containers DISABLED for the
    -- test session (empty groups park the badges in their windows); the drive's
    -- unit guards are test-bypassed (fabricated units fail every unit API).
    if DF.FactoryOwnsMissingBuff and DF:FactoryOwnsMissingBuff(db) then
        -- Dead unit: park the strip the same way the toggle-off path does, so
        -- re-showing goes back through the live drive.
        if DF:IsTestFrameDead(frame) then
            if frame.missingBuffStrip and frame.dfMissingStripShown ~= false then
                frame.dfMissingStripShown = false
                frame.missingBuffStrip:Hide()
            end
            return
        end
        DF:DriveMissingBuffFactory(frame, db)
        return
    end

end

-- The buff/debuff sibling of UpdateAllTestMissingBuff / UpdateAllTestDefensiveBar /
-- UpdateAllTestAuraDesigner. Its ABSENCE is why aura settings did not live-update in
-- test mode: every OTHER container surface had one of these and was wired to it, but
-- the buff and debuff rows had no "refresh every test frame" entry point at all. So a
-- slider drag saved the value, re-drove the LIVE frames, and left the preview stale —
-- and Aura Designer appeared to be the only thing that worked.
--
-- The per-frame drive (UpdateTestAuras) already existed and already reads every
-- setting; nothing was missing but the loop over the frames.
function DF:UpdateAllTestAuras()
    if DF.testMode and DF.testPartyFrames then
        for i = 0, 4 do
            local frame = DF.testPartyFrames[i]
            if frame then
                DF:UpdateTestAuras(frame)
                RepaintTestSurface(frame, "auras")
            end
        end
    end
    if DF.raidTestMode and DF.testRaidFrames then
        for i = 1, 40 do
            local frame = DF.testRaidFrames[i]
            if frame then
                DF:UpdateTestAuras(frame)
                RepaintTestSurface(frame, "auras")
            end
        end
    end
end

function DF:UpdateAllTestMissingBuff()
    local function UpdateFrame(frame)
        if not frame then return end
        local db = DF:GetFrameDB(frame)

        if db.testShowMissingBuff then
            DF:UpdateTestMissingBuff(frame)
            RepaintTestSurface(frame, "missingBuff")
        else
            -- 12.1 factory strip: hide via the shown-cache the live drive keys on.
            if frame.missingBuffStrip and frame.dfMissingStripShown ~= false then
                frame.dfMissingStripShown = false
                frame.missingBuffStrip:Hide()
            end
        end
    end
    
    -- Update party test frames
    if DF.testMode then
        for i = 0, 4 do
            local frame = DF.testPartyFrames[i]
            if frame then
                UpdateFrame(frame)
            end
        end
    end
    
    -- Update raid test frames
    if DF.raidTestMode then
        for i = 1, 40 do
            local frame = DF.testRaidFrames[i]
            if frame then
                UpdateFrame(frame)
            end
        end
    end
end

-- Test defensive spell textures (variety for multi-icon display)
-- (Removed) TEST_DEFENSIVE_SPELLS — a four-ID list (Pain Suppression, Ironbark,
-- Blessing of Sacrifice, Life Cocoon) with no readers. The defensive preview drives
-- the real 12.1 container and takes its spell from testData instead.

-- Test defensive preview: drive the real 12.1 defensive container.
function DF:UpdateTestDefensiveBar(frame, testData)
    if not frame then return end

    local db = DF:GetFrameDB(frame)

    -- 12.1: the live defensive row is a container (DriveDefensiveFactory) —
    -- preview through the SAME container (P5 hybrid) so styling, layout and
    -- fonts are live-true; the legacy pool below is a dead pipeline here.
    -- Role-scaled count mirrors the legacy preview shape (tank 3 / healer 1).
    if DF.FactoryOwnsDefensiveRow and DF:FactoryOwnsDefensiveRow(db) then
        local role = testData and testData.role
        local show = db.defensiveIconEnabled and db.testShowExternalDef
            and (role == "TANK" or role == "HEALER")
            and not DF:IsTestFrameDead(frame)
        if show then
            DF:DriveDefensiveFactory(frame, db)
            local h = frame.defensiveFactory
            if h then
                -- ☠ ONE SOURCE FOR THE PREVIEW COUNT. This used to override with a
                -- role-scaled 3-on-tanks / 1-on-everyone-else AFTER the drive had
                -- already applied BuildDefensiveRowConfig's `testMax = testBuffCount`.
                -- Two values fighting: the Buffs count slider appeared to do nothing
                -- on the defensive row, and since SetTestMax rebuilds on any change,
                -- every defensive tweak in test paid an extra container rebuild while
                -- they argued. The config's own comment states the intent -- this is a
                -- HELPFUL row, so the Buffs count is the one the user set for it -- and
                -- wins; the role scaling was a leftover of the legacy preview's shape.
                if h.SetTestMax then
                    h:SetTestMax(math.min(db.testBuffCount or 2, db.defensiveBarMax or 4))
                end
                if frame.dfDefFactoryShown ~= true then
                    frame.dfDefFactoryShown = true
                    h:GetFrame():Show()
                end
            end
        elseif frame.defensiveFactory then
            -- Hide via the shown-cache the live drive keys on, so exiting test
            -- mode (or re-ticking the toggle) re-shows through the normal path.
            if frame.dfDefFactoryShown ~= false then
                frame.dfDefFactoryShown = false
                frame.defensiveFactory:GetFrame():Hide()
            end
        end
        return
    end

end

function DF:UpdateAllTestDefensiveBar()
    local function UpdateFrame(frame, testData)
        if not frame then return end
        local db = DF:GetFrameDB(frame)

        -- Unconditional: the painter reads testShowExternalDef itself and
        -- hides the container row when it's off.
        DF:UpdateTestDefensiveBar(frame, testData)
        RepaintTestSurface(frame, "defensive")
    end
    
    -- Update party test frames
    if DF.testMode then
        for i = 0, 4 do
            local frame = DF.testPartyFrames[i]
            if frame then
                local testData = DF:GetTestUnitData(i, false)
                UpdateFrame(frame, testData)
            end
        end
    end
    
    -- Update raid test frames
    if DF.raidTestMode then
        local raidDb = DF:GetRaidDB()
        local testFrameCount = raidDb.raidTestFrameCount or 10
        for i = 1, testFrameCount do
            local frame = DF.testRaidFrames[i]
            if frame then
                local testData = DF:GetTestUnitData(i, true)
                UpdateFrame(frame, testData)
            end
        end
    end
end


-- (Removed) TEST MODE: TARGETED SPELLS — the on-frame test painter
-- (DF:UpdateTestTargetedSpell). Orphaned once UpdateAllTestTargetedSpell stopped
-- driving it; the group-frame display it previewed is gone.

-- Targeted List demo bars in test mode. This is a single global
-- container (not per-frame), so the update function just toggles the
-- show/hide helpers on the feature module. Safe to call with the
-- feature gate off — both helpers are no-ops on stable builds.
function DF:UpdateAllTestTargetedList()
    local db = DF:GetDB()
    -- Gate the test display on the feature's master Enable too — a disabled
    -- targeted list must not show in test mode even if "show in test" is ticked.
    --
    -- Also PARTY-ONLY. The live path bails on IsInRaid(), but a raid PREVIEW is not a
    -- real raid, so that gate never fires here: without this check the demo list showed
    -- during raid test mode whenever the PARTY profile had it enabled. (Reading the party
    -- db is deliberate — the Targeted List is party-resolved by design; see GetPersonalDB
    -- in Features/TargetedSpells.lua.)
    if not DF.raidTestMode
        and db and db.testShowTargetedList and db.targetedListEnabled and DF.ShowTestTargetedList then
        DF:ShowTestTargetedList()
    elseif DF.HideTestTargetedList then
        DF:HideTestTargetedList()
    end
end

-- ⚠ Despite the name this is NOT group-only, which is why it survives the removal
-- of the group-frame Targeted Spells display. It also drives the PERSONAL preview
-- and the Targeted List demo bars, and is called from four places.
-- (Removed) the group half: the UpdateFrame closure that painted on-frame icons,
-- and the party/raid frame loops that existed only to drive it.
function DF:UpdateAllTestTargetedSpell()
    if DF.testMode then
        -- Update personal targeted spells display in test mode
        local db = DF:GetDB()
        if db.personalTargetedSpellEnabled and db.testShowPersonalTargeted ~= false and DF.ShowTestPersonalTargetedSpells then
            DF:ShowTestPersonalTargetedSpells()
        elseif DF.HideTestPersonalTargetedSpells then
            DF:HideTestPersonalTargetedSpells()
        end

        -- Update Targeted List demo bars in test mode
        if DF.UpdateAllTestTargetedList then
            DF:UpdateAllTestTargetedList()
        end
    end

    if DF.raidTestMode then
        local raidDb = DF:GetRaidDB()
        -- (Removed) the raid frame loop — it only called the group-frame painter, and
        -- group Targeted Spells were party-only anyway (raid was forced off).

        -- Show personal targeted spells in raid test mode. Personal Targeted is a
        -- player-screen overlay with PER-MODE settings, so the raid preview must gate on
        -- the RAID profile — this read DF:GetDB() (party), so the raid panel's toggle was
        -- ignored and the party value decided it instead.
        local db = raidDb
        if db.personalTargetedSpellEnabled and db.testShowPersonalTargeted ~= false and DF.ShowTestPersonalTargetedSpells then
            DF:ShowTestPersonalTargetedSpells()
        elseif DF.HideTestPersonalTargetedSpells then
            DF:HideTestPersonalTargetedSpells()
        end
    end
end


-- ============================================================
-- AURA DESIGNER TEST MODE
-- Iterates all visible test frames and calls the AD Engine's
-- test path to show/hide configured indicators with mock data.
-- ============================================================

function DF:UpdateAllTestAuraDesigner()
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    if not Factory then return end

    -- 12.1: preview through the REAL factory containers (P6 hybrid). The test
    -- provider bounce supplies presence, the shared test paint puts each placed
    -- indicator's OWN configured spell on it (config.testEntries), and frame
    -- effects (health bar / background / border winners) apply exactly as live.
    local function UpdateFrame(frame)
        if not frame or not frame:IsShown() then return end
        local db = DF:GetFrameDB(frame)
        if db and db.testShowAuraDesigner and DF:IsAuraDesignerEnabled(frame)
            and not DF:IsTestFrameDead(frame) then
            Factory:SyncFrame(frame)
        else
            Factory:ClearFrame(frame)
        end
        RepaintTestSurface(frame, "auraDesigner")
    end

    if DF.testMode then
        for i = 0, 4 do
            local frame = DF.testPartyFrames and DF.testPartyFrames[i]
            if frame then UpdateFrame(frame) end
        end
    end

    if DF.raidTestMode then
        local raidDb = DF:GetRaidDB()
        local testFrameCount = raidDb and raidDb.raidTestFrameCount or 10
        for i = 1, testFrameCount do
            local frame = DF.testRaidFrames and DF.testRaidFrames[i]
            if frame then UpdateFrame(frame) end
        end
    end

    -- Pinned test frames carry their OWN AD/TD preset overrides, so refresh their
    -- indicators too (same UpdateFrame path; IsShown-guarded, so hidden pool slots
    -- no-op). Without this an AD change reflects on the main test frames but not
    -- the pinned preview.
    if DF.PinnedFrames and DF.PinnedFrames.IsTestModeActive
        and DF.PinnedFrames:IsTestModeActive() then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local pool = DF.PinnedFrames.testFrames and DF.PinnedFrames.testFrames[setIndex]
            if pool then
                for _, f in ipairs(pool) do UpdateFrame(f) end
            end
        end
    end
end

-- ============================================================
-- FLOATING TEST PANEL
-- ============================================================

function DF:CreateTestPanel()
    if DF.TestPanel then return DF.TestPanel end

    -- ============================================================
    -- COLOUR CONSTANTS
    -- ============================================================
    -- Neutral tones reuse the shared GUI palette (same numeric values, zero
    -- visual change) so they track any future palette change in lockstep. The
    -- mode accent stays driven by GetThemeColor() below (party/raid aware).
    local GUIColors  = DF.GUI.Colors
    local C_PARTY    = GUIColors.accent
    local C_RAID     = GUIColors.raid
    local C_BG       = GUIColors.background
    local C_PANEL    = GUIColors.panel
    local C_ELEMENT  = GUIColors.element
    local C_BORDER   = GUIColors.border
    local C_HOVER    = GUIColors.hover
    local C_TEXT     = GUIColors.text
    local C_TEXT_DIM = GUIColors.textDim

    local PANEL_WIDTH   = 320
    local CONTENT_WIDTH = PANEL_WIDTH - 24  -- 12px padding each side
    local HEADER_TOP    = 108  -- Space used by title + toggle button + description + separator

    local function GetThemeColor()
        local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
        return isRaidMode and C_RAID or C_PARTY
    end

    local function IsTestActive()
        local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
        return isRaidMode and DF.raidTestMode or DF.testMode
    end

    -- ============================================================
    -- MAIN PANEL FRAME
    -- ============================================================
    local panel = CreateFrame("Frame", "DandersFramesTestPanel", UIParent, "BackdropTemplate")
    panel:SetSize(PANEL_WIDTH, 420)
    panel:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:SetFrameLevel(100)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    DF.GUI:CreatePanelBackdrop(panel, { bgAlpha = C_BG.a, borderColor = { r = 0, g = 0, b = 0, a = 1 } })
    panel:Hide()

    local function ApplyScale(self)
        self:SetScale(DF:GetWindowState().scale or 1.0)
    end

    panel:SetScript("OnHide", function()
        -- Closing the panel drops the USER's claim on both scopes -- and only
        -- that. It used to hide the frames itself, but ONLY when locked, which is
        -- exactly how the preview got stranded: close the panel while unlocked and
        -- the frames stayed up with nothing tracking that you had dismissed them.
        -- Now unlock's own claim decides whether they stay, and the later lock
        -- takes them down.
        DF:SetTestModeOwner("party", "user", false)
        DF:SetTestModeOwner("raid", "user", false)
        if DF.GUI and DF.GUI.UpdateTestButtonState then
            DF.GUI.UpdateTestButtonState()
        end
    end)

    tinsert(UISpecialFrames, "DandersFramesTestPanel")

    -- ============================================================
    -- HEADER
    -- ============================================================
    -- Title
    local title = panel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText(L["Test Mode"])
    panel.title = title

    -- Mode badge
    local badge = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    badge:SetSize(40, 18)
    badge:SetPoint("LEFT", title, "RIGHT", 8, 0)
    -- Colours are pushed per mode (party/raid theme) when the panel refreshes.
    DF.GUI:CreateElementBackdrop(badge)
    badge.text = badge:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    badge.text:SetPoint("CENTER", 0, 0)
    badge.text:SetText(L["Party"])
    panel.badge = badge

    -- Close button
    local closeBtn = DF.GUI:CreateCloseButton(panel, {
        size = 22,
        onClick = function() panel:Hide() end,
    })
    closeBtn:SetPoint("TOPRIGHT", -8, -6)

    -- Separator below header
    local headerSep = panel:CreateTexture(nil, "ARTWORK")
    headerSep:SetPoint("TOPLEFT", 0, -32)
    headerSep:SetPoint("TOPRIGHT", 0, -32)
    headerSep:SetHeight(1)
    headerSep:SetColorTexture(1, 1, 1, 0.06)

    -- ============================================================
    -- TOGGLE BUTTON
    -- ============================================================
    local toggleBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    toggleBtn:SetPoint("TOPLEFT", 12, -38)
    -- Full-width toggle. The active/inactive look (accent fill + "Disable Test
    -- Mode" label when on) is driven by SetActive(testActive) in
    -- UpdateStateInternal; here we just set the resting (inactive) label.
    DF.GUI:StyleButton(toggleBtn, {
        width = CONTENT_WIDTH,
        height = 30,
        font = "DFFontHighlight",
        text = L["Enable Test Mode"],
    })
    toggleBtn:SetScript("OnClick", function()
        DF:ToggleTestMode()
        -- This button and the toolbar's test button are the SAME action: turn the
        -- preview off and close the panel. Leaving the panel open with test mode off
        -- was the odd state -- one control closed everything, the other printed a
        -- line and sat there. So an open panel now always means "the user is asking
        -- for a preview", which is also what makes the toggle's label unambiguous.
        --
        -- Hide() runs OnHide, which releases the user's claim on both scopes; that is
        -- idempotent with the release ToggleTestMode just did.
        local scope = (DF.GUI and DF.GUI.SelectedMode == "raid") and "raid" or "party"
        if not DF:IsTestModeOwnedBy(scope, "user") then
            panel:Hide()
        else
            panel:UpdateState()
        end
    end)
    panel.toggleBtn = toggleBtn

    -- Description text
    local desc = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 12, -74)
    desc:SetPoint("TOPRIGHT", -12, -74)
    desc:SetJustifyH("LEFT")
    desc:SetSpacing(2)
    desc:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
    desc:SetText(L["Expand sections to toggle features. Click label text to jump to its settings page."])

    -- ============================================================
    -- THEMED CHECKBOX HELPER
    -- ============================================================
    local function CreateThemedCheckbox(parent, text, dbKey, callback, pageId)
        local container = CreateFrame("Frame", nil, parent)
        container:SetSize(CONTENT_WIDTH / 2 - 4, 22)

        -- Checkbox square + check — uniform look via the shared styler, same as
        -- every other checkbox (default 18/10 size; check square shows/hides).
        local box = CreateFrame("Button", nil, container, "BackdropTemplate")
        box:SetPoint("LEFT", 0, 0)
        local mark = DF.GUI:StyleCheckButton(box, { manualCheck = true })
        container.box = box
        container.mark = mark

        -- State
        container.checked = false
        container.dbKey = dbKey

        container.SetChecked = function(self, val)
            self.checked = val and true or false
            -- Recolour the check to the current (raid/party-aware) theme each time
            -- the panel refreshes, same as every other themed widget here.
            local c = GetThemeColor()
            if self.box.ApplyThemeColor then self.box.ApplyThemeColor(c) end
            self.mark:SetShown(self.checked)
        end

        container.GetChecked = function(self)
            return self.checked
        end

        -- Grey-out-in-place support for sub-toggles whose parent boolean is off.
        -- Disabled: visible but non-interactive (label dimmed, box + container
        -- mouse blocked). Re-applied on every panel refresh and on the parent
        -- toggle. dfDisabled gates the box OnClick so a stray click can't slip
        -- through while greyed.
        container.dfDisabled = false
        container.SetEnabled = function(self, enabled)
            self.dfDisabled = not enabled
            self.box:EnableMouse(enabled)
            -- The CONTAINER keeps its mouse even when greyed, so a disabled row can
            -- still surface a "why is this greyed?" tooltip on hover. Safe: its
            -- OnMouseDown only forwards to the box's OnClick, which bails on
            -- dfDisabled, so the row still can't be toggled.
            self:EnableMouse(true)
            -- The page-link label is its OWN Button with OnEnter/OnLeave that
            -- recolour the text. Leaving it live meant hovering a GREYED toggle lit
            -- it up, and its OnLeave then restored the FULL-brightness colour —
            -- silently undoing the grey. Kill its mouse too, and re-assert both
            -- colours here so a disable landing mid-hover can't leave it stuck lit.
            if self.labelBtn then self.labelBtn:EnableMouse(enabled) end
            if self.labelText then
                if enabled then
                    self.labelText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                else
                    self.labelText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                end
            end
            if self.arrow then
                self.arrow:SetTextColor(0.4, 0.4, 0.4, enabled and 0.6 or 0.25)
            end
        end

        -- Label
        if pageId then
            local labelBtn = CreateFrame("Button", nil, container)
            labelBtn:SetPoint("LEFT", box, "RIGHT", 6, 0)
            labelBtn:SetHeight(18)
            local labelText = labelBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            labelText:SetPoint("LEFT", 0, 0)
            labelText:SetText(text)
            labelText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            local arrow = labelBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            arrow:SetPoint("LEFT", labelText, "RIGHT", 2, 0)
            arrow:SetText("›")
            arrow:SetTextColor(0.4, 0.4, 0.4, 0.6)
            labelBtn:SetWidth(labelText:GetStringWidth() + 14)
            -- Every handler bails when the toggle is greyed: EnableMouse(false)
            -- should already stop them, but a disable applied while the cursor is
            -- inside would otherwise never fire OnLeave and leave the label lit.
            labelBtn:SetScript("OnEnter", function(self)
                if container.dfDisabled then return end
                labelText:SetTextColor(1, 0.82, 0)
                arrow:SetTextColor(1, 0.82, 0)
                DF.GUI:ShowTooltip(self, { title = L["Click to open settings"] })
            end)
            labelBtn:SetScript("OnLeave", function(self)
                DF.GUI:HideTooltip()
                if container.dfDisabled then
                    labelText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                    arrow:SetTextColor(0.4, 0.4, 0.4, 0.25)
                    return
                end
                labelText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                arrow:SetTextColor(0.4, 0.4, 0.4, 0.6)
            end)
            labelBtn:SetScript("OnClick", function()
                if container.dfDisabled then return end
                if DF.GUI and DF.GUI.SelectTab then
                    if DF.GUIFrame and not DF.GUIFrame:IsShown() then DF.GUIFrame:Show() end
                    DF.GUI.SelectTab(pageId)
                end
            end)
            container.labelBtn = labelBtn
            container.arrow = arrow
            container.labelText = labelText
        else
            local labelText = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            labelText:SetPoint("LEFT", box, "RIGHT", 6, 0)
            labelText:SetText(text)
            labelText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            container.labelText = labelText
        end

        -- Click the box to toggle
        box:SetScript("OnClick", function()
            if container.dfDisabled then return end
            container:SetChecked(not container.checked)
            local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
            local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
            db[dbKey] = container.checked
            if callback then callback(container.checked, isRaidMode) end
            if isRaidMode and DF.raidTestMode then
                DF:UpdateRaidTestFrames()
            elseif not isRaidMode and DF.testMode then
                DF:UpdateAllFrames()
                if DF.RefreshTestFrames then DF:RefreshTestFrames() end
            end
            -- Update badge on parent section
            if container.section and container.section.UpdateBadge then
                container.section:UpdateBadge()
            end
            -- ☠ RE-EVALUATE THE PRESET HIGHLIGHT. Flipping a toggle can make the state
            -- stop matching the highlighted preset -- or start matching another one --
            -- and nothing here used to tell the footer that. The full panel refresh is
            -- not usable from inside a checkbox handler (it re-runs SetChecked on every
            -- box, including this one, mid-click), so refresh just the preset row.
            if panel.RefreshPresetHighlight then panel:RefreshPresetHighlight() end
        end)

        -- Hover on whole container toggles too
        container:EnableMouse(true)
        container:SetScript("OnMouseDown", function()
            box:GetScript("OnClick")(box)
        end)

        -- A greyed toggle explains itself: set a disabled tooltip and hovering the
        -- row says WHY it's unavailable (e.g. party-only features in raid). Routed
        -- through the shared GUI tooltip helper like every other tooltip in the addon.
        -- Enabled rows fall through: the box's hover wash and the label's page-link
        -- tooltip stay the only hover effects.
        container.SetDisabledTooltip = function(self, title, lines)
            self.dfDisabledTip = title and { title = title, lines = lines } or nil
        end
        container:SetScript("OnEnter", function(self)
            if not self.dfDisabled then return end
            local tip = self.dfDisabledTip
            if not tip then return end
            -- No tone: an untoned title renders white (ShowTooltip's default), which
            -- is what we want here — the grey-out already carries the "unavailable"
            -- signal, so a coloured title would over-egg it.
            DF.GUI:ShowTooltip(self, { title = tip.title, lines = tip.lines })
        end)
        container:SetScript("OnLeave", function()
            DF.GUI:HideTooltip()
        end)
        -- No row-level border hover: the box's own highlight wash (from the shared
        -- styler) is the sole hover effect, matching every other checkbox. A row-
        -- level border hover here would flash on/off as the cursor crossed from the
        -- label onto the box (container OnLeave fires when entering the child box).

        return container
    end

    -- ============================================================
    -- THEMED MINI-SLIDER HELPER
    -- Matches addon slider style: track + fill + thumb, no Blizzard template
    -- ============================================================
    local function CreateThemedSlider(parent, width, minVal, maxVal, step)
        local container = CreateFrame("Frame", nil, parent)
        container:SetSize(width, 8)

        -- Background track
        local track = CreateFrame("Frame", nil, container, "BackdropTemplate")
        track:SetAllPoints()
        DF.GUI:CreateElementBackdrop(track, {
            bgColor     = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1 },
            borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5 },
        })

        -- Fill track (coloured portion)
        local fill = track:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("LEFT", 1, 0)
        fill:SetHeight(6)
        local c = GetThemeColor()
        fill:SetColorTexture(c.r, c.g, c.b, 0.8)
        fill:SetWidth(1)

        -- Actual slider control (invisible, overlays the track)
        local slider = CreateFrame("Slider", nil, container)
        slider:SetAllPoints()
        slider:SetOrientation("HORIZONTAL")
        slider:SetMinMaxValues(minVal, maxVal)
        slider:SetValueStep(step)
        slider:SetObeyStepOnDrag(true)
        slider:SetHitRectInsets(-4, -4, -8, -8)

        -- Thumb
        local thumb = slider:CreateTexture(nil, "OVERLAY")
        thumb:SetSize(10, 14)
        thumb:SetColorTexture(c.r, c.g, c.b, 1)
        slider:SetThumbTexture(thumb)

        local trackWidth = width - 2  -- Account for border insets

        local function UpdateFill()
            local val = slider:GetValue()
            local pct = (val - minVal) / (maxVal - minVal)
            fill:SetWidth(math.max(1, pct * trackWidth))
        end

        slider:HookScript("OnValueChanged", function()
            UpdateFill()
        end)

        -- Expose for theme updates
        container.slider = slider
        container.fill = fill
        container.thumb = thumb
        container.UpdateFill = UpdateFill

        container.dfDisabled = false
        container.UpdateTheme = function()
            -- While greyed, keep the muted look rather than repainting to accent.
            if container.dfDisabled then
                thumb:SetColorTexture(0.4, 0.4, 0.4, 1)
                fill:SetColorTexture(0.4, 0.4, 0.4, 0.5)
                return
            end
            local nc = GetThemeColor()
            thumb:SetColorTexture(nc.r, nc.g, nc.b, 1)
            fill:SetColorTexture(nc.r, nc.g, nc.b, 0.8)
        end

        -- Grey-out-in-place: disable the slider + mute the fill/thumb when the
        -- parent boolean enable is off. Visible but non-interactive.
        container.SetEnabled = function(self, enabled)
            self.dfDisabled = not enabled
            slider:EnableMouse(enabled)
            self.UpdateTheme()
        end

        -- Forward slider API to container for convenience
        container.SetValue = function(self, v) slider:SetValue(v) end
        container.GetValue = function(self) return slider:GetValue() end
        container.SetMinMaxValues = function(self, lo, hi)
            slider:SetMinMaxValues(lo, hi)
            minVal = lo
            maxVal = hi
            trackWidth = width - 2
        end
        container.SetScript = function(self, event, fn) slider:SetScript(event, fn) end
        container.HookScript = function(self, event, fn) slider:HookScript(event, fn) end

        return container
    end

    -- ============================================================
    -- COLLAPSIBLE SECTION HELPER
    -- ============================================================
    local allSections = {}

    local function CreateSection(parentFrame, sectionTitle, sectionKey)
        local section = CreateFrame("Frame", nil, parentFrame)
        section:SetSize(CONTENT_WIDTH, 30)  -- Height updated by RecalculateLayout
        section.sectionKey = sectionKey
        section.expanded = false  -- Default collapsed
        section.checkboxes = {}
        section.extraWidgets = {}  -- {widget, height}

        -- Header bar
        local header = CreateFrame("Button", nil, section, "BackdropTemplate")
        header:SetSize(CONTENT_WIDTH, 26)
        header:SetPoint("TOPLEFT", 0, 0)
        DF.GUI:CreateElementBackdrop(header, {
            bgColor     = { C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.8 },
            borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.3 },
        })
        section.header = header

        -- Chevron (starts collapsed)
        local chevron = header:CreateTexture(nil, "OVERLAY")
        chevron:SetSize(12, 12)
        chevron:SetPoint("LEFT", 8, 0)
        chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
        chevron:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        section.chevron = chevron

        -- Title
        local titleText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        titleText:SetPoint("LEFT", 26, 0)
        titleText:SetText(string.upper(sectionTitle))
        titleText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        section.titleText = titleText

        -- Active count badge
        local badgeText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        badgeText:SetPoint("RIGHT", -8, 0)
        badgeText:SetText("")
        section.badgeText = badgeText

        -- Content container (starts hidden since collapsed by default)
        local content = CreateFrame("Frame", nil, section)
        content:SetPoint("TOPLEFT", 0, -28)
        content:SetWidth(CONTENT_WIDTH)
        content:Hide()
        section.content = content

        -- Grid for checkboxes (2 columns)
        local gridRow = 0
        local gridCol = 0
        local COL_WIDTH = (CONTENT_WIDTH - 8) / 2

        section.AddCheckbox = function(self, text, dbKey, callback, pageId)
            local cb = CreateThemedCheckbox(content, text, dbKey, callback, pageId)
            cb.section = self
            local xOff = gridCol * COL_WIDTH + 4
            local yOff = -(gridRow * 24 + 4)
            cb:SetPoint("TOPLEFT", content, "TOPLEFT", xOff, yOff)
            table.insert(self.checkboxes, cb)
            -- Advance grid position
            gridCol = gridCol + 1
            if gridCol >= 2 then
                gridCol = 0
                gridRow = gridRow + 1
            end
            return cb
        end

        -- Returns the Y offset below the checkbox grid
        local function GetGridBottom()
            local rows = math.ceil(#section.checkboxes / 2)
            return -(rows * 24 + 4)
        end

        section.AddWidget = function(self, widget, height)
            widget:SetParent(content)
            local yOff = GetGridBottom()
            -- Account for previous extra widgets
            for _, entry in ipairs(self.extraWidgets) do
                yOff = yOff - entry.height
            end
            widget:SetPoint("TOPLEFT", content, "TOPLEFT", 4, yOff - 2)
            widget:SetWidth(CONTENT_WIDTH - 8)
            table.insert(self.extraWidgets, {widget = widget, height = height})
        end

        section.GetContentHeight = function(self)
            local rows = math.ceil(#self.checkboxes / 2)
            local h = rows * 24 + 8  -- Grid height + padding
            for _, entry in ipairs(self.extraWidgets) do
                h = h + entry.height
            end
            return h
        end

        section.GetTotalHeight = function(self)
            if self.expanded then
                return 26 + self:GetContentHeight() + 4  -- header + content + gap
            end
            return 26 + 4  -- Just header + gap
        end

        section.UpdateBadge = function(self)
            local count = 0
            for _, cb in ipairs(self.checkboxes) do
                -- Skip greyed-out toggles: they're unavailable in this mode and
                -- render nothing, so counting them would advertise a feature that
                -- isn't actually on (e.g. Targeted Spells / List in raid).
                if cb.checked and not cb.dfDisabled then count = count + 1 end
            end
            if count > 0 then
                local c = GetThemeColor()
                self.badgeText:SetText(tostring(count))
                self.badgeText:SetTextColor(c.r, c.g, c.b, 0.8)
            else
                self.badgeText:SetText("")
            end
        end

        section.SetExpanded = function(self, expanded)
            self.expanded = expanded
            if self.expanded then
                self.chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
                self.content:Show()
            else
                self.chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
                self.content:Hide()
            end
        end

        section.Toggle = function(self)
            self:SetExpanded(not self.expanded)
            -- Save collapsed state to DB
            if self.sectionKey and DF.db then
                if not DF.db.testPanelSections then DF.db.testPanelSections = {} end
                DF.db.testPanelSections[self.sectionKey] = self.expanded
            end
            panel:RecalculateLayout()
        end

        -- Hover effects on header
        header:SetScript("OnEnter", function(self)
            self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 0.8)
        end)
        header:SetScript("OnLeave", function(self)
            self:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.8)
        end)
        header:SetScript("OnClick", function()
            section:Toggle()
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)

        -- Set content height
        content:SetHeight(1)  -- Will be updated

        table.insert(allSections, section)
        return section
    end

    -- ============================================================
    -- CREATE SECTIONS
    -- ============================================================

    -- --- GENERAL ---
    local secGeneral = CreateSection(panel, L["General"], "general")

    panel.showPetsCheck = secGeneral:AddCheckbox(L["Show Pets"], "testShowPets", function(enabled, isRaidMode)
        if isRaidMode then
            if DF.raidTestMode then
                if enabled then
                    if DF.InitializeTestRaidPetFrames then DF:InitializeTestRaidPetFrames() end
                    if DF.UpdateAllRaidPetFrames then DF:UpdateAllRaidPetFrames(true) end
                else
                    if DF.HideAllTestRaidPetFrames then DF:HideAllTestRaidPetFrames() end
                end
            end
        else
            if DF.testMode then
                if enabled then
                    if DF.InitializeTestPetFrames then DF:InitializeTestPetFrames() end
                    if DF.UpdateAllPetFrames then DF:UpdateAllPetFrames(true) end
                else
                    if DF.HideAllTestPetFrames then DF:HideAllTestPetFrames() end
                end
            end
        end
    end, "display_pets")

    panel.animHealthCheck = secGeneral:AddCheckbox(L["Animate Health"], "testAnimateHealth", function(enabled, isRaidMode)
        if isRaidMode then
            if DF.raidTestMode then
                if enabled then DF:StartTestAnimation()
                else
                    local partyDb = DF:GetDB()
                    if not (DF.testMode and partyDb.testAnimateHealth) then DF:StopTestAnimation() end
                end
            end
        else
            if DF.testMode then
                if enabled then DF:StartTestAnimation()
                else
                    local raidDb = DF:GetRaidDB()
                    if not (DF.raidTestMode and raidDb.testAnimateHealth) then DF:StopTestAnimation() end
                end
            end
        end
    end)

    -- Frame count slider (below checkboxes)
    local fcRow = CreateFrame("Frame", nil, secGeneral.content)
    fcRow:SetHeight(28)
    local fcLabel = fcRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    fcLabel:SetPoint("LEFT", 0, 0)
    fcLabel:SetText(L["Frame Count"])
    fcLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    local fcValue = fcRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    fcValue:SetPoint("LEFT", fcLabel, "RIGHT", 6, 0)
    panel.frameCountValue = fcValue

    local frameCountSlider = CreateThemedSlider(fcRow, 140, 1, 5, 1)
    frameCountSlider:SetPoint("LEFT", fcValue, "RIGHT", 8, 0)

    local frameCountDragging = false
    frameCountSlider:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            frameCountDragging = true
            DF:OnSliderDragStart(function()
                if DF.LightweightUpdateTestFrameCount then DF:LightweightUpdateTestFrameCount() end
            end)
        end
    end)
    frameCountSlider:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and frameCountDragging then
            frameCountDragging = false
            DF:OnSliderDragStop()
        end
    end)
    frameCountSlider:HookScript("OnValueChanged", function(self, value)
        local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
        local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
        local dbKey = isRaidMode and "raidTestFrameCount" or "testFrameCount"
        db[dbKey] = math.floor(value)
        fcValue:SetText(tostring(db[dbKey]))
        if isRaidMode and DF.raidTestMode then
            DF:ThrottledUpdateRaidTestFrames()
            if not DF.sliderDragging and DF.UpdateAllRaidPetFrames then DF:UpdateAllRaidPetFrames(true) end
        elseif not isRaidMode and DF.testMode then
            DF:ThrottledUpdateAll()
            if not DF.sliderDragging and DF.UpdateAllPetFrames then DF:UpdateAllPetFrames(true) end
        end
        -- Re-anchor permanent mover when frame count changes
        C_Timer.After(0.1, function()
            DF:UpdatePermanentMoverAnchor(isRaidMode and "raid" or "party")
        end)
    end)
    panel.frameCountSlider = frameCountSlider
    secGeneral:AddWidget(fcRow, 28)

    -- --- BARS & OVERLAYS ---
    local secBars = CreateSection(panel, L["Bars & Overlays"], "bars")
    panel.showAbsorbsCheck = secBars:AddCheckbox(L["Absorbs"], "testShowAbsorbs", nil, "bars_absorb")
    panel.showHealPredictCheck = secBars:AddCheckbox(L["Heal Prediction"], "testShowHealPrediction", nil, "bars_healpred")
    panel.showOutOfRangeCheck = secBars:AddCheckbox(L["Out of Range"], "testShowOutOfRange", nil, "display_fading")
    panel.showReducedMaxCheck = secBars:AddCheckbox(L["Reduced Max Health"], "testShowReducedMaxHealth", nil, "bars_health")
    -- Text Designer is alpha-gated; only offer the toggle when the module loaded.
    if DF.UpdateTextDesigner then
        -- Default ON: seed any profile that predates the Config default so the
        -- checkbox shows checked (migration timing can otherwise leave it nil).
        local pdb, rdb = DF:GetDB(), DF:GetRaidDB()
        if pdb and pdb.testShowTextDesigner == nil then pdb.testShowTextDesigner = true end
        if rdb and rdb.testShowTextDesigner == nil then rdb.testShowTextDesigner = true end
        panel.showTextDesignerCheck = secBars:AddCheckbox(L["Text Designer"], "testShowTextDesigner", function()
            if DF.UpdateTextDesigner then
                for i = 0, 4 do
                    local f = DF.testPartyFrames and DF.testPartyFrames[i]
                    if f then DF:UpdateTextDesigner(f, "all") end
                end
                for i = 1, 40 do
                    local f = DF.testRaidFrames and DF.testRaidFrames[i]
                    if f then DF:UpdateTextDesigner(f, "all") end
                end
            end
        end, "text_designer")  -- pageId → makes the label a quick link to the TD tab
    end

    -- --- AURAS ---
    local secAuras = CreateSection(panel, L["Auras"], "auras")
    panel.showAurasCheck = secAuras:AddCheckbox(L["Show Auras"], "testShowAuras", function(enabled, isRaidMode)
        -- Refresh on BOTH states: the 12.1 preview rows show/hide through the
        -- UpdateTestAuras seam, so disabling needs a pass too (the old callback
        -- only refreshed on enable, which left the container rows visible).
        if not isRaidMode and DF.testMode then
            if enabled then
                DF:RefreshTestFramesWithLayout()
            elseif DF.testPartyFrames then
                for i = 0, 4 do
                    local f = DF.testPartyFrames[i]
                    if f and f:IsShown() then DF:UpdateTestAuras(f) end
                end
            end
        elseif isRaidMode and DF.raidTestMode and DF.testRaidFrames then
            for i = 1, 40 do
                local f = DF.testRaidFrames[i]
                if f and f:IsShown() then DF:UpdateTestAuras(f) end
            end
        end
        -- Buff/Debuff count sliders only matter while auras are shown; grey them
        -- in place when Show Auras is off.
        if panel.RefreshDependentEnabled then panel.RefreshDependentEnabled() end
    end, "auras_buffs")
    panel.showDispelGlowCheck = secAuras:AddCheckbox(L["Dispel Overlay"], "testShowDispelGlow", function()
        if DF.testMode or DF.raidTestMode then DF:UpdateAllTestDispelGlow() end
    end, "auras_dispel")
    panel.showMissingBuffCheck = secAuras:AddCheckbox(L["Missing Buff"], "testShowMissingBuff", function()
        if DF.testMode or DF.raidTestMode then DF:UpdateAllTestMissingBuff() end
    end, "auras_missingbuffs")
    panel.showADCheck = secAuras:AddCheckbox(L["Aura Designer"], "testShowAuraDesigner", function(enabled)
        if DF.testMode or DF.raidTestMode then DF:UpdateAllTestAuraDesigner() end
    end, "auras_auradesigner")

    -- Buff/Debuff count sliders
    local auraSliderRow = CreateFrame("Frame", nil, secAuras.content)
    auraSliderRow:SetHeight(18)

    local buffLabel = auraSliderRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    buffLabel:SetPoint("LEFT", 0, 0)
    buffLabel:SetText(L["Buffs:"])
    buffLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local buffSlider = CreateThemedSlider(auraSliderRow, 55, 0, 5, 1)
    buffSlider:SetPoint("LEFT", buffLabel, "RIGHT", 5, 0)
    local buffValue = auraSliderRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    buffValue:SetPoint("LEFT", buffSlider, "RIGHT", 4, 0)
    buffValue:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    panel.buffValueText = buffValue

    local debuffLabel = auraSliderRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    debuffLabel:SetPoint("LEFT", buffValue, "RIGHT", 12, 0)
    debuffLabel:SetText(L["Debuffs:"])
    debuffLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local debuffSlider = CreateThemedSlider(auraSliderRow, 55, 0, 5, 1)
    debuffSlider:SetPoint("LEFT", debuffLabel, "RIGHT", 5, 0)
    local debuffValue = auraSliderRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    debuffValue:SetPoint("LEFT", debuffSlider, "RIGHT", 4, 0)
    debuffValue:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    panel.debuffValueText = debuffValue

    -- Buff slider callbacks
    local buffSliderDragging = false
    buffSlider:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            buffSliderDragging = true
            DF:OnSliderDragStart(function() if DF.RefreshTestFrames then DF:RefreshTestFrames() end end)
        end
    end)
    buffSlider:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and buffSliderDragging then
            buffSliderDragging = false
            DF:OnSliderDragStop()
        end
    end)
    buffSlider:HookScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        local isRaidMode = DF.raidTestMode
        local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
        db.testBuffCount = value
        buffValue:SetText(value)
        if DF.raidTestMode then DF:ThrottledUpdateRaidTestFrames()
        elseif DF.testMode then DF:ThrottledUpdateAll() end
    end)
    panel.buffSlider = buffSlider

    -- Debuff slider callbacks
    local debuffSliderDragging = false
    debuffSlider:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            debuffSliderDragging = true
            DF:OnSliderDragStart(function() if DF.RefreshTestFrames then DF:RefreshTestFrames() end end)
        end
    end)
    debuffSlider:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and debuffSliderDragging then
            debuffSliderDragging = false
            DF:OnSliderDragStop()
        end
    end)
    debuffSlider:HookScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        local isRaidMode = DF.raidTestMode
        local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
        db.testDebuffCount = value
        debuffValue:SetText(value)
        if DF.raidTestMode then DF:ThrottledUpdateRaidTestFrames()
        elseif DF.testMode then DF:ThrottledUpdateAll() end
    end)
    panel.debuffSlider = debuffSlider
    -- Stash the slider labels so RefreshDependentEnabled can dim them in step
    -- with the sliders when Show Auras is off.
    panel.buffSliderLabel = buffLabel
    panel.debuffSliderLabel = debuffLabel

    -- Grey the Buff/Debuff count sliders in place when "Show Auras" is off (their
    -- only consumer). Disabled-in-place per the boolean-enable grey rule: visible
    -- but non-interactive, with labels + value texts dimmed. Reads testShowAuras
    -- from the currently active (raid/party) db so mode switches honour it.
    panel.RefreshDependentEnabled = function()
        local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
        local adb = isRaidMode and DF:GetRaidDB() or DF:GetDB()
        local aurasOn = adb and adb.testShowAuras and true or false
        if panel.buffSlider and panel.buffSlider.SetEnabled then
            panel.buffSlider:SetEnabled(aurasOn)
        end
        if panel.debuffSlider and panel.debuffSlider.SetEnabled then
            panel.debuffSlider:SetEnabled(aurasOn)
        end
        local lr, lg, lb = C_TEXT.r, C_TEXT.g, C_TEXT.b
        if not aurasOn then lr, lg, lb = C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b end
        if panel.buffSliderLabel then panel.buffSliderLabel:SetTextColor(lr, lg, lb) end
        if panel.debuffSliderLabel then panel.debuffSliderLabel:SetTextColor(lr, lg, lb) end
        if panel.buffValueText then panel.buffValueText:SetTextColor(lr, lg, lb) end
        if panel.debuffValueText then panel.debuffValueText:SetTextColor(lr, lg, lb) end

        -- Group Targeted Spells and the Targeted List are PARTY-ONLY features:
        -- the group cast detection is fingerprint-based and "Raid is intentionally
        -- unsupported (collisions are near-total)", and the Targeted List bails on
        -- IsInRaid() outright (Features/TargetedSpells.lua). Their test toggles
        -- therefore do nothing in raid mode, so grey them in place instead of
        -- letting them read as available. Personal Targeted has no raid gate and
        -- stays enabled.
        local groupTargetingAvailable = not isRaidMode
        if panel.showTargetedListCheck  then panel.showTargetedListCheck:SetEnabled(groupTargetingAvailable) end
        if panel.animTargetedListCheck  then panel.animTargetedListCheck:SetEnabled(groupTargetingAvailable) end
    end

    secAuras:AddWidget(auraSliderRow, 22)

    -- --- INDICATORS & ICONS ---
    local secIndicators = CreateSection(panel, L["Indicators & Icons"], "indicators")
    panel.showExternalDefCheck = secIndicators:AddCheckbox(L["Defensive Icon"], "testShowExternalDef", function()
        if DF.testMode or DF.raidTestMode then DF:UpdateAllTestDefensiveBar() end
    end, "auras_defensiveicon")
    -- "Targeted Spell" was the old group-frame icon display that
    -- Blizzard's 2026-04-07 hotfix killed. The checkbox slot is now
    -- repurposed for the Targeted List (alpha/beta-only feature).
    panel.showTargetedListCheck = secIndicators:AddCheckbox(L["Targeted List"], "testShowTargetedList", function()
        if DF.testMode or DF.raidTestMode then DF:UpdateAllTestTargetedList() end
    end, "indicators_targetedlist")
    panel.animTargetedListCheck = secIndicators:AddCheckbox(L["Animate Targeted List"], "testAnimateTargetedList", function()
        if DF.testMode or DF.raidTestMode then DF:UpdateAllTestTargetedList() end
    end)
    -- (Removed) the "Targeted Spells" checkbox on testShowTargetedSpell. Its painter
    -- DF:UpdateTestTargetedSpell went with the group-frame display, and
    -- DF:UpdateAllTestTargetedSpell — which survives — never reads that key: it
    -- gates on personalTargetedSpellEnabled + testShowPersonalTargeted and delegates
    -- the list to testShowTargetedList. So the box persisted a value nothing
    -- consumed. The comment here used to justify keeping it "because it drives the
    -- Personal Targeted preview too"; that was wrong — Personal has its own box
    -- immediately below, which is the one that actually drives the preview.
    panel.showPersonalTargetedCheck = secIndicators:AddCheckbox(L["Personal Targeted"], "testShowPersonalTargeted", function()
        if DF.testMode or DF.raidTestMode then DF:UpdateAllTestTargetedSpell() end
    end, "indicators_personal_targeted")

    -- Both are greyed in raid (see RefreshDependentEnabled) — say why on hover
    -- instead of leaving a dead-looking control. Personal Targeted is NOT listed: it
    -- has no raid gate and works fine there.
    do
        local tipLines = { L["The Targeted List is a party-only feature, so it does nothing in raid mode."] }
        if panel.showTargetedListCheck  then panel.showTargetedListCheck:SetDisabledTooltip(L["Party-only feature"], tipLines) end
        if panel.animTargetedListCheck  then panel.animTargetedListCheck:SetDisabledTooltip(L["Party-only feature"], tipLines) end
    end
    -- One unified "Icons" toggle for the whole status/role/leader icon set in test
    -- mode (was split into "Status / Ready" + "Role / Leader"). Keyed on
    -- testShowStatusIcons; the role/leader render gate reads the same key.
    panel.showStatusIconsCheck = secIndicators:AddCheckbox(L["Icons"], "testShowStatusIcons", function()
        if DF.testMode or DF.raidTestMode then DF:RefreshTestFrames() end
    end, "indicators_icons")

    -- --- HIGHLIGHTS ---
    local secHighlights = CreateSection(panel, L["Highlights"], "highlights")
    panel.showSelectionCheck = secHighlights:AddCheckbox(L["Selection"], "testShowSelection", function()
        if DF.UpdateAllTestHighlights then DF:UpdateAllTestHighlights() end
    end, "indicators_highlights")
    panel.showAggroCheck = secHighlights:AddCheckbox(L["Aggro"], "testShowAggro", function()
        if DF.UpdateAllTestHighlights then DF:UpdateAllTestHighlights() end
    end, "indicators_highlights")

    -- ============================================================
    -- PRESETS FOOTER
    -- ============================================================
    local presetsFooter = CreateFrame("Frame", nil, panel)
    presetsFooter:SetPoint("BOTTOMLEFT", 0, 0)
    presetsFooter:SetPoint("BOTTOMRIGHT", 0, 0)
    presetsFooter:SetHeight(58)

    local presetSep = presetsFooter:CreateTexture(nil, "ARTWORK")
    presetSep:SetPoint("TOPLEFT", 0, 0)
    presetSep:SetPoint("TOPRIGHT", 0, 0)
    presetSep:SetHeight(1)
    presetSep:SetColorTexture(1, 1, 1, 0.06)

    local presetLabel = presetsFooter:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    presetLabel:SetPoint("TOPLEFT", 12, -8)
    presetLabel:SetText(L["QUICK PRESETS"])
    presetLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
    panel.presetLabel = presetLabel

    -- Default first — it is the shipped baseline, so it reads as the starting
    -- point the others move away from.
    local presets = {"DEFAULT", "AURAS", "COMBAT", "HEALER", "FULL"}
    local presetNames = {DEFAULT = L["Default"], AURAS = L["Auras"], COMBAT = L["Combat"],
        HEALER = L["Healer"], FULL = L["Full"]}
    local btnSpacing = 4
    local btnCount = #presets
    local btnWidth = math.floor((CONTENT_WIDTH - (btnSpacing * (btnCount - 1))) / btnCount)
    panel.presetBtns = {}

    for i, preset in ipairs(presets) do
        local btn = CreateFrame("Button", nil, presetsFooter, "BackdropTemplate")
        btn:SetPoint("TOPLEFT", 12 + (i - 1) * (btnWidth + btnSpacing), -26)
        -- Segmented quick-preset cell: at most ONE active, and possibly none.
        -- panel:RefreshPresetHighlight derives which from the live toggles, so the
        -- highlight is a statement about the current state rather than about which
        -- button was last pressed. OnClick applies the preset and refreshes.
        DF.GUI:StyleButton(btn, { width = btnWidth, height = 24, text = presetNames[preset] })
        btn.preset = preset
        btn:SetScript("OnClick", function(self)
            DF:ApplyTestPreset(self.preset)
            panel:UpdateState()
        end)
        panel.presetBtns[i] = btn
    end

    -- ============================================================
    -- LAYOUT CALCULATION
    -- ============================================================
    function panel:RecalculateLayout()
        local y = -HEADER_TOP
        for _, sec in ipairs(allSections) do
            sec:ClearAllPoints()
            sec:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, y)
            sec.content:SetHeight(sec:GetContentHeight())
            sec:SetHeight(sec:GetTotalHeight())  -- Section needs valid height for children to render
            y = y - sec:GetTotalHeight()
        end
        -- Set panel height: sections + header + presets footer
        local totalHeight = HEADER_TOP + math.abs(y - (-HEADER_TOP)) + 62  -- 62 = presets footer
        self:SetHeight(math.max(totalHeight, 200))
    end

    -- ============================================================
    -- UPDATE STATE
    -- ============================================================
    local function UpdateStateInternal(self, callbackEnabled)
        local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
        local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
        local themeColor = GetThemeColor()
        -- The toggle is the USER's switch, so it reflects the USER's claim, not
        -- whether a preview is on screen. Those differ while unlocked (unlock holds
        -- its own claim), and using the preview state there left the button stuck on
        -- "Disable Test Mode" after a click that had genuinely worked.
        local scope = isRaidMode and "raid" or "party"
        local testActive = DF.IsTestModeOwnedBy and DF:IsTestModeOwnedBy(scope, "user")
            or (not DF.IsTestModeOwnedBy and IsTestActive())

        -- Title
        self.title:SetText(L["Test Mode"])
        self.title:SetTextColor(themeColor.r, themeColor.g, themeColor.b)

        -- Badge
        local badgeLabel = isRaidMode and L["Raid"] or L["Party"]
        self.badge.text:SetText(badgeLabel)
        self.badge:SetSize(self.badge.text:GetStringWidth() + 14, 18)
        self.badge:SetBackdropColor(themeColor.r * 0.15, themeColor.g * 0.15, themeColor.b * 0.15, 1)
        self.badge:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.3)
        self.badge.text:SetTextColor(themeColor.r, themeColor.g, themeColor.b)

        -- Toggle button: SetActive drives the accent fill/border when test is on;
        -- we set the label + (active) accent text colour to match. SetActive repaints
        -- the resting fill, but the hover wash (the HIGHLIGHT texture) is only re-tinted
        -- by ApplyThemeColor — the toggle's UpdateTheme listener lives on the test panel,
        -- which nothing walks on a mode switch, so refresh it here or the wash stays
        -- frozen at the mode the panel was first opened in.
        if self.toggleBtn.ApplyThemeColor then self.toggleBtn.ApplyThemeColor(themeColor) end
        self.toggleBtn:SetActive(testActive)
        if testActive then
            self.toggleBtn.Text:SetText(L["Disable Test Mode"])
            self.toggleBtn.Text:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
        else
            self.toggleBtn.Text:SetText(L["Enable Test Mode"])
            self.toggleBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        end

        -- Frame count slider
        local maxFrames = isRaidMode and 40 or 5
        local fcKey = isRaidMode and "raidTestFrameCount" or "testFrameCount"
        local currentCount = db[fcKey] or (isRaidMode and 10 or 5)
        self.frameCountSlider:SetMinMaxValues(1, maxFrames)
        self.frameCountSlider:SetValue(currentCount)
        if self.frameCountSlider.UpdateTheme then self.frameCountSlider:UpdateTheme() end
        self.frameCountValue:SetText(tostring(currentCount))
        self.frameCountValue:SetTextColor(themeColor.r, themeColor.g, themeColor.b)

        -- Checkboxes from DB
        self.animHealthCheck:SetChecked(db.testAnimateHealth)
        self.showPetsCheck:SetChecked(db.testShowPets ~= false)
        self.showAbsorbsCheck:SetChecked(db.testShowAbsorbs)
        self.showHealPredictCheck:SetChecked(db.testShowHealPrediction ~= false)
        self.showOutOfRangeCheck:SetChecked(db.testShowOutOfRange)
        self.showReducedMaxCheck:SetChecked(db.testShowReducedMaxHealth ~= false)
        if self.showTextDesignerCheck then
            self.showTextDesignerCheck:SetChecked(db.testShowTextDesigner ~= false)
        end
        self.showAurasCheck:SetChecked(db.testShowAuras)
        self.showDispelGlowCheck:SetChecked(db.testShowDispelGlow)
        self.showMissingBuffCheck:SetChecked(db.testShowMissingBuff)
        self.showADCheck:SetChecked(db.testShowAuraDesigner)
        self.showExternalDefCheck:SetChecked(db.testShowExternalDef)
        -- The Targeted List is party-only, so it can never be "on" in raid — show it
        -- unchecked there regardless of what the raid profile stores (an older
        -- build's preset wrote testShowTargetedList into the raid db, so it would
        -- otherwise read as checked-but-greyed).
        self.showTargetedListCheck:SetChecked(not isRaidMode and db.testShowTargetedList)
        self.animTargetedListCheck:SetChecked(not isRaidMode and db.testAnimateTargetedList)
        self.showPersonalTargetedCheck:SetChecked(db.testShowPersonalTargeted ~= false)
        self.showStatusIconsCheck:SetChecked(db.testShowStatusIcons ~= false)
        self.showSelectionCheck:SetChecked(db.testShowSelection)
        self.showAggroCheck:SetChecked(db.testShowAggro)

        -- Buff/Debuff sliders
        local buffCount = db.testBuffCount or 3
        self.buffSlider:SetValue(buffCount)
        self.buffValueText:SetText(buffCount)
        if self.buffSlider.UpdateTheme then self.buffSlider:UpdateTheme() end
        local debuffCount = db.testDebuffCount or 3
        self.debuffSlider:SetValue(debuffCount)
        self.debuffValueText:SetText(debuffCount)
        if self.debuffSlider.UpdateTheme then self.debuffSlider:UpdateTheme() end

        -- Grey the Buff/Debuff sliders when Show Auras is off (boolean-enable grey
        -- rule). Runs AFTER the value/UpdateTheme set above so the disabled muted
        -- look wins; re-applied here so mode switches + panel opens honour it.
        if self.RefreshDependentEnabled then self.RefreshDependentEnabled() end

        -- Restore section collapsed states from DB and update badges
        local savedSections = DF.db and DF.db.testPanelSections
        for _, sec in ipairs(allSections) do
            if savedSections and sec.sectionKey and savedSections[sec.sectionKey] ~= nil then
                sec:SetExpanded(savedSections[sec.sectionKey])
            end
            sec:UpdateBadge()
        end

        self:RefreshPresetHighlight()

        -- Recalculate layout
        self:RecalculateLayout()

        if callbackEnabled and DF.GUI and DF.GUI.UpdateTestButtonState then
            DF.GUI.UpdateTestButtonState()
        end
    end

-- Light the quick-preset button whose definition the current toggles actually match, and
-- none if they match nothing (accent fill + border via the shared toggle look; the active
-- label takes the accent too).
--
-- ☠ SEPARATE FROM THE FULL REFRESH ON PURPOSE, and it is not an optimisation. A checkbox
-- handler cannot call UpdateState: that re-runs SetChecked on every box in the panel,
-- including the one being clicked, in the middle of its own OnClick. This touches only the
-- footer, so it is safe from inside a toggle -- which is exactly where it is needed, since
-- flipping a toggle is what makes the previous highlight wrong.
    function panel:RefreshPresetHighlight()
        if not self.presetBtns then return end
        local themeColor = GetThemeColor()
        local activePreset = DF.GetActiveTestPreset and DF:GetActiveTestPreset() or nil
        for _, btn in ipairs(self.presetBtns) do
            local isActive = btn.preset == activePreset
            btn:SetActive(isActive)
            if isActive then
                btn.Text:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
            else
                btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end
        end
    end

    function panel:UpdateState()
        UpdateStateInternal(self, true)
    end

    function panel:UpdateStateNoCallback()
        UpdateStateInternal(self, false)
    end

    -- ============================================================
    -- ONSHOW
    -- ============================================================
    panel:SetScript("OnShow", function(self)
        ApplyScale(self)
        self:UpdateState()
    end)

    DF.TestPanel = panel
    return panel
end

function DF:ToggleTestPanel()
    local panel = DF:CreateTestPanel()
    if panel:IsShown() then
        panel:Hide()
    else
        panel:UpdateState()
        panel:Show()

        -- Opening the panel claims the preview for the user (it exists to show
        -- one). Claiming rather than calling Show* directly means the matching
        -- release on close is symmetric, and unlock's claim is untouched either way.
        local scope = (DF.GUI and DF.GUI.SelectedMode == "raid") and "raid" or "party"
        DF:SetTestModeOwner(scope, "user", true)
        panel:UpdateState()
    end
end
