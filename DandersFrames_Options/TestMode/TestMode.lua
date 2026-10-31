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
        -- ☠ isAFK LIVES HERE, NOT ON THE OUT-OF-RANGE UNIT. The AFK icon carries a TICKING
        -- TIMER, and the one element that exists to be READ must not sit on the one frame that
        -- is deliberately dimmed.
        -- ⇒ RULE: a TIMED or ANIMATED element must not share a frame with the range fade
        -- or the dead state. This unit's other states are all static badges (leader
        -- crown, skull marker, combat flag), so nothing competes with a countdown.
        -- ★ ONE JOB PER FRAME. Each of the five demonstrates a distinct set and nothing doubles
        -- up: this one is the AFK TIMER plus the leader badges. Both icon strips are off — the
        -- defensive row would show here by default (TANK role) and the missing-buff strip shows
        -- everywhere by default, and between them they crowd the timer. They live on Healsworth
        -- and Xx respectively.
        -- ⚠ This unit KEEPS its debuff row; only the IMPORTANT (enlarged + badged) debuff is
        -- off (`showImportantDebuff = false`), so the row renders plain and the countdown has
        -- the space to itself.
        -- ☠ showReadyCheck = false, AND THIS ONE IS NOT COSMETIC. The ready-check demo is
        -- gated on isLeader, which is this unit — and readyCheckIcon and afkIcon share
        -- anchor CENTER, offset 0,0 AND frame level 30, i.e. the same point. The ready check
        -- lives on Мишок instead: it is a static icon and survives being faded.
        -- ⚠ THE LIVE COLLISION IS UNFIXED — a real unit that is AFK during a real ready
        -- check still gets both at the same point, draw order by creation order. That is
        -- a defaults/precedence decision; this only moves the preview.
        {name = "Tankerino", class = "WARRIOR", role = "TANK", specID = 73, health = 1.0, maxHealth = 100000, absorb = 0.20, healAbsorb = 0, healPrediction = 0.15, status = nil, outOfRange = false, isLeader = true, raidTarget = 8, dispelType = nil, centerStatus = nil, isMainTank = true, isAFK = true, isPhased = false, inVehicle = false, isBGCarrier = false, isInCombat = true, reducedMaxPct = 0.20, showDefensive = false, showMissingBuff = false, showReadyCheck = false, showImportantDebuff = false},  -- AFK timer, skull marker, leader, main tank, has HoT, in combat (BG carrier lives on Xx — this frame's centre belongs to the AFK countdown)
        -- The DEFENSIVE ICON + summon frame (HEALER, so the defensive row shows by the
        -- role rule — no override needed). The missing-buff strip is off: with both, this
        -- became the busiest frame of the five and the two strips sat in the same region.
        -- ☠ health 0.70 IS LOAD-BEARING, NOT A COSMETIC CHOICE — DO NOT PUT IT BACK TO 0.95.
        -- Heal prediction and an attached absorb can only render into EMPTY bar, and
        -- "Show Overheal" is off by default, so at 0.95 there were five percent of bar for
        -- both to share: raising healPrediction did nothing at all, because the ceiling was
        -- the headroom, not the value. Reported as "hard to notice".
        -- ⇒ A preview value is only visible if the frame has ROOM for it. Same trap on
        -- Tankerino above, which is at health 1.0 and therefore cannot show its
        -- healPrediction at all.
        {name = "Healsworth", class = "PRIEST", role = "HEALER", specID = 257, health = 0.70, maxHealth = 85000, absorb = 0.20, healAbsorb = 0, healPrediction = 0.22, status = nil, outOfRange = false, isAssist = true, raidTarget = nil, dispelType = "Magic", centerStatus = "summon", isMainAssist = true, isAFK = false, isPhased = false, inVehicle = false, reducedMaxPct = 0, showMissingBuff = false},  -- Assistant, main assist, summon pending, defensive icon
        -- THE out-of-range unit, and the only one — so the fade has a subject with
        -- plenty to dim: 60% health, a HoT, a dispel type, a raid marker. ⚠ Keep TIMED
        -- elements off it (see the note on Tankerino); it also carries the threat-2
        -- aggro colour, which is deliberate — range has nothing to do with threat.
        -- ⚠ showDefensive = true OVERRIDES the role rule (this is a DAMAGER, so the row
        -- would not show here otherwise) and showMissingBuff = false swaps the badge
        -- strip out for it — one surface per frame rather than both stacked on the one
        -- unit that is also faded.
        -- ☠ NETTING IS ASYMMETRIC (Blizzard's model, see the heal-absorb calculator in
        -- Frames/Bars.lua): the WASH renders at its FULL amount, the incoming HEAL
        -- renders NET of it — full wash + shortened heal is what makes the interplay
        -- visible. (A symmetric build shipped briefly and one side was always zero.)
        -- Coverage: ★ Xx IS THE INTERPLAY DEMO — 15% wash INTO health, its 25% heal
        -- showing only the surviving 10%, shield chained after: all three at once.
        -- THIS unit is the full-consumption contrast: a 0.30 wash that eats its 0.15
        -- HoT entirely, so a big wash renders with NO heal beside it.
        {name = "Мишок", class = "MAGE", role = "DAMAGER", specID = 63, health = 0.60, maxHealth = 75000, absorb = 0, healAbsorb = 0.30, healPrediction = 0.15, status = nil, outOfRange = true, raidTarget = 1, dispelType = "Curse", centerStatus = nil, isAFK = false, isPhased = false, inVehicle = false, reducedMaxPct = 0, showDefensive = true, showMissingBuff = false, showReadyCheck = true},  -- Star marker, out of range, heavy consuming wash over its HoT, defensive icon, ready check (no missing-buff strip)
        {name = "Alexandrosthegreat", class = "PALADIN", role = "DAMAGER", specID = 70, health = 0, maxHealth = 90000, absorb = 0, healAbsorb = 0, healPrediction = 0, status = "Dead", outOfRange = false, raidTarget = nil, dispelType = nil, centerStatus = "resurrect", isAFK = false, isPhased = false, inVehicle = false, reducedMaxPct = 0},  -- Dead unit, being resurrected
        -- ★ THE ONLY MISSING-BUFF FRAME now (it shows here by default — no field needed).
        -- ⚠ If this unit ever gains showMissingBuff = false, the strip is previewed
        -- NOWHERE. Check the other four before turning it off here.
        -- ★ ALSO THE ONLY BG-CARRIER FRAME in party. bgCarrierIcon sat on the CENTRE BUS,
        -- and all five party frames already have their centre claimed, so it was fixed at
        -- the SOURCE, not in the preview: the icon's live default is TOPRIGHT -2,-2
        -- (Config.lua). It has its own lane on every frame, here and in game alike — no
        -- preview-only offset, which would have broken "previews differ in DATA, never
        -- RENDERING". This frame's centre still belongs to phasedIcon.
        -- ⚠ Nothing draws until the user opts in — bgCarrierIconEnabled defaults false.
        {name = "Xx", class = "ROGUE", role = "DAMAGER", specID = 260, health = 0.30, maxHealth = 70000, absorb = 0.16, healAbsorb = 0.15, healPrediction = 0.25, status = nil, outOfRange = false, raidTarget = nil, dispelType = "Poison", centerStatus = nil, isAFK = false, isPhased = true, inVehicle = true, isBGCarrier = true, reducedMaxPct = 0.45, showPing = true},  -- Missing buffs, phased, in vehicle, BG carrier, ping, has HoT
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
    --     6-10 PALADIN PRIEST DRUID SHAMAN WARRIOR
    -- Every window of 5 therefore holds five DIFFERENT classes, so no override can merge
    -- two of them. Verified for every offset the rotation produces.
    -- ⚠ Adding an entry breaks the arithmetic. Keep the pool at 10 and swap, or redo the
    -- spacing for the new size.
    buffs = {
        {icon = "Interface\\Icons\\Spell_Holy_BlessingOfProtection", name = "Blessing of Protection", duration = 10, stacks = 0, spellID = 1022},
        -- Stacks are REAL here (charges remaining), which is why PoM keeps its slot: the
        -- previous stack case was "Heal" with 2 stacks, a spell that applies no aura.
        {icon = "Interface\\Icons\\spell_holy_prayerofmending", name = "Prayer of Mending", duration = 30, stacks = 5, spellID = 41635},
        {icon = "Interface\\Icons\\Spell_Nature_Rejuvenation", name = "Rejuvenation", duration = 12, stacks = 0, spellID = 774},
        {icon = "Interface\\Icons\\Spell_Nature_Riptide", name = "Riptide", duration = 8, stacks = 0, spellID = 61295},
        -- ☠ EVERY icon path in this file MUST use DOUBLE backslashes. Lua 5.1 passes an
        -- unknown escape through WITHOUT the backslash (\I -> I), so the single-backslash
        -- form of a path silently collapses to "InterfaceIconsSpell_Foo" -- it parses, it
        -- never loads ("\a" is a KNOWN escape, BEL, and garbles the path differently).
        -- ⚠ These paths are a FALLBACK: _paintTestSlot prefers the game's own texture for the
        -- resolved spell ID and only reaches for `icon` when the client cannot resolve the
        -- spell, so a broken path here stays invisible on most clients.
        -- Do NOT "tidy" any of these back to single backslashes.
        {icon = "Interface\\Icons\\ability_monk_renewingmists", name = "Renewing Mist", duration = 20, stacks = 0, spellID = 119611},
        -- duration = 0 is the PERMANENT case, and it drives "Hide Duration on Permanent
        -- Auras". Beacon holds until the paladin moves it, so it is a real one rather
        -- than a made-up zero. ⚠ If a patch ever gives Beacon a timer this stops
        -- exercising that setting — the pool then needs another duration-less buff.
        {icon = "Interface\\Icons\\Ability_Paladin_BeaconofLight", name = "Beacon of Light", duration = 0, stacks = 0, spellID = 53563},
        -- ☠ NO RAID BUFFS IN THIS POOL. Spells in `DF.RaidBuffs` (Frames/Bars.lua) are what
        -- MISSING BUFFS tracks, and `missingBuffHideFromBar` DEFAULTS TO TRUE, which unions every
        -- RaidBuffs id into the row's `excludeSpellIDs` (Features/Auras.lua). So on a default
        -- profile a live buff row can never show them, and a preview that did would be a
        -- test-vs-live divergence.
        -- ⇒ Anything added here must NOT appear in `DF.RaidBuffs`. Check it.
        {icon = "Interface\\Icons\\Spell_Holy_Renew", name = "Renew", duration = 15, stacks = 0, spellID = 139},
        {icon = "Interface\\Icons\\Spell_Nature_Regenerate", name = "Regrowth", duration = 12, stacks = 0, spellID = 8936},
        -- ★ THE ONE LONG BUFF, and the pool needs exactly one: it is the only entry that
        -- exercises the minutes side of the countdown formats and a duration bar that
        -- barely moves. 10 minutes is Earth Shield's real duration — durations here are
        -- honest, per the Beacon note above. ⚠ Nothing crosses the HOUR boundary, so that
        -- format is unpreviewed — deliberate, since an hour-long buff on a party frame
        -- only ever means a raid buff.
        {icon = "Interface\\Icons\\Spell_Nature_SkinofEarth", name = "Earth Shield", duration = 600, stacks = 0, spellID = 974},
        {icon = "Interface\\Icons\\Ability_Warrior_RallyingCry", name = "Rallying Cry", duration = 10, stacks = 0, spellID = 97463},
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
        -- WARRIOR at 1/6 (Rend, Mortal Wounds).
        -- ★ THE ONLY Bleed ENTRY, and it has to live in slot 1. DF ships five dispel
        -- colours (Border.lua: Magic, Curse, Disease, Poison, Bleed, with Enrage sharing
        -- Bleed's red) and the pool had no Bleed at all, so that colour could be set on
        -- the Colors page and never previewed. Slot 1 is a TYPED slot, and Rend is WARRIOR
        -- like its 5-apart partner (Mortal Wounds at 6), so the class spacing holds. Typing
        -- one of the four untyped slots instead would have been simpler and was rejected:
        -- they set the 60% density.
        {icon = "Interface\\Icons\\Ability_Gouge", name = "Rend", duration = 15, stacks = 0, debuffType = "Bleed", spellID = 772},
        {icon = "Interface\\Icons\\Spell_DeathKnight_FrostFever", name = "Frost Fever", duration = 24, stacks = 0, debuffType = "Disease", spellID = 55095},
        {icon = "Interface\\Icons\\Spell_Shadow_CurseOfSargeras", name = "Curse of Tongues", duration = 30, stacks = 0, debuffType = "Curse", spellID = 1714},
        -- 2818 = the DoT. NOT 2823, which is the weapon imbue of the same name, and the
        -- reason a party frame once previewed "Requires One-Handed Melee Weapon".
        -- Deadly Poison genuinely stacks to 5, so this is an honest stack case.
        {icon = "Interface\\Icons\\Spell_Nature_NullifyPoison", name = "Deadly Poison", duration = 12, stacks = 5, debuffType = "Poison", spellID = 2818},
        {icon = "Interface\\Icons\\Spell_Holy_RemoveCurse", name = "Forbearance", duration = 30, stacks = 0, debuffType = nil, spellID = 25771},
        {icon = "Interface\\Icons\\Ability_Warrior_SavageBlow", name = "Mortal Wounds", duration = 10, stacks = 0, debuffType = nil, spellID = 115804},
        {icon = "Interface\\Icons\\Spell_Shadow_ShadowWordPain", name = "Shadow Word: Pain", duration = 18, stacks = 0, debuffType = "Magic", spellID = 589},
        {icon = "Interface\\Icons\\Spell_Shaman_Hex", name = "Hex", duration = 8, stacks = 0, debuffType = "Curse", spellID = 51514},
        {icon = "Interface\\Icons\\Ability_CheapShot", name = "Dazed", duration = 4, stacks = 0, debuffType = nil, spellID = 1604},
        {icon = "Interface\\Icons\\Spell_Holy_Resurrection", name = "Resurrection Sickness", duration = 600, stacks = 0, debuffType = nil, spellID = 15007},
    },
    -- Defensive externals for the 12.1 container preview (config.testPool =
    -- "defensives" on the defensive row). Same spells the legacy test painter
    -- cycled; icons are the fallback when the spell ID doesn't validate.
    defensives = {
        {icon = "Interface\\Icons\\Spell_Holy_PainSupression", name = "Pain Suppression", duration = 8, stacks = 0, spellID = 33206},
        {icon = "Interface\\Icons\\spell_druid_ironbark", name = "Ironbark", duration = 12, stacks = 0, spellID = 102342},
        {icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice", name = "Blessing of Sacrifice", duration = 12, stacks = 0, spellID = 6940},
        {icon = "Interface\\Icons\\ability_monk_chicocoon", name = "Life Cocoon", duration = 12, stacks = 0, spellID = 116849},
        -- ★ THE STACKED SAMPLE. Every other entry is stacks = 0, so the stack text never
        -- drew and the Stack Count controls on the Defensive Icons page could only be
        -- judged on a live aura in combat.
        -- ☠ It has to be a spell that GENUINELY stacks. A first cut put a fake 12 on Pain
        -- Suppression, which does not — a preview that shows something the game never
        -- shows is the same class of lie as a test path that renders differently from
        -- live. Sentinel is the right sample twice over: it is the exact spell in the
        -- report behind these controls ("since the patch the number is quite huge"), and
        -- SpellDB already carries it as a defensive (389539, cats.defensives).
        -- ⚠ The value is for WIDTH, not accuracy — nobody has checked the real cap, and
        -- the point is that two digits reveal the overflow a single digit hides.
        -- No hand-maintained icon needed: _paintTestSlot prefers the GAME's texture for a
        -- validated spellID and only falls back to this path.
        {icon = "Interface\\Icons\\Spell_Holy_AuraOfLight", name = "Sentinel", duration = 15, stacks = 12, spellID = 389539},
    },
    animationTimer = nil,
    animationPhase = 0,
}

-- ============================================================
-- ★ THE RAID PREVIEW ALLOCATION
-- ============================================================
-- Which raid frame demonstrates WHAT, as explicit lists rather than index arithmetic
-- (`i % 4 == 3` for range, `i == 3` for AFK, ...): two modulo rules can silently land
-- on the same frame, and nobody can see it without evaluating them by hand. That is
-- how the AFK countdown once ended up on a deliberately faded frame.
--
-- ★ THE RULES THESE SETS ENCODE (same as the party table, checkable at a glance):
--   1. A TIMED or ANIMATED element never shares a frame with the range fade or death.
--   2. At most ONE centre-region element per frame — afkIcon, readyCheckIcon,
--      summon/resurrect all draw at CENTER 0,0, so two on one frame
--      is a guaranteed overlap, not a near miss.
--   3. The missing-buff strip and the defensive row never share a frame: they occupy
--      the same band.
--   4. A dead frame carries the resurrect marker and nothing else.
--   5. An out-of-range frame carries STATIC badges only.
--
-- ⚠ COVERAGE IS FRONT-LOADED, because raidTestFrameCount is user-driven (1-40).
-- Frames 1-10 cover every primary indicator; the three secondary status icons (summon,
-- phased, vehicle) start at 11. Everything appears by 20. Below 10 frames the
-- preview is necessarily partial — that is a property of the slider, not a gap here.
--
-- ⚠ 21-40 MIRROR 1-20 (+20) via inRaidSet, so a full 40-frame raid repeats the spread
-- instead of trailing off into 20 identical frames. Add an index ≤ 20 and the upper
-- half inherits it automatically.
local RAID_ALLOC = {
    OOR        = { [6] = true, [14] = true, [19] = true },
    DEAD       = { [9] = true, [17] = true },
    -- Centre-region — see rule 2. These five sets must stay mutually disjoint.
    AFK        = { [2] = true },
    READYCHECK = { [8] = true },
    -- Ping icon: a centre-region element (rule 2). 5 carries only the defensive row.
    PING       = { [5] = true },
    -- Three frames, because summon has THREE live states and each has its own
    -- user-editable text key. 12 was the documented free slot (it held DND until that
    -- state was dropped); 15 carries only the missing-buff STRIP, which is not a
    -- centre-region element, so rule 2 is intact.
    SUMMON     = { [11] = true, [12] = true, [15] = true },
    -- Static badges
    LEADER     = { [1] = true },
    ASSIST     = { [3] = true },
    MAINTANK   = { [1] = true },
    MAINASSIST = { [3] = true },
    COMBAT     = { [1] = true },
    BGCARRIER  = { [10] = true },
    PHASED     = { [13] = true },
    VEHICLE    = { [16] = true },
    -- Icon strips — see rule 3, these two must stay disjoint from each other.
    MISSINGBUF = { [4] = true, [15] = true },
    DEFENSIVE  = { [5] = true, [18] = true },
    -- The enlarged + badged important debuff. ⚠ Deliberately sparse and deliberately NOT
    -- on frame 2: it carries the AFK countdown, and an oversized badged
    -- icon lands on the same region — the party tank hit exactly that.
    IMPORTANTDEBUFF = { [7] = true, [16] = true },
    -- Healer bars. Deliberately sparse: heal prediction on most frames reads as "every
    -- frame is being healed" rather than as an example of the bar.
    ABSORB     = { [7] = true, [20] = true },
    HEALABSORB = { [10] = true, [20] = true },
    HEALPRED   = { [7] = true, [20] = true },
    REDUCEDMAX = { [10] = true, [18] = true },
}
-- Which summon state each SUMMON frame demonstrates. Live has three -- Pending,
-- Accepted and Declined -- each with its own texture AND its own user-editable text
-- key, and only Pending was ever previewable, so two settings existed that nobody
-- could see in order to judge them.
--
-- ☠ AN EXPLICIT LIST, NOT `index % 3`. That is the whole lesson of the note above:
-- modulo allocation shipped the same class of bug twice here. A modulo would also be
-- wrong on these particular indices -- 11, 12 and 15 mod 3 give 2, 0, 0, so Accepted
-- would never render and Pending would render twice.
--
-- Anything not listed (including party mode, whose single summon frame is Healsworth)
-- falls through to Pending, which is the state that was previewed before.
local RAID_SUMMON_STATE = { [11] = "pending", [12] = "accepted", [15] = "declined" }

-- Raid target markers: which frame gets which marker index (1-8). Five of forty, so a
-- marker still reads as a marker; it was every frame 1-8 before, i.e. a solid band.
local RAID_MARKERS = { [1] = 8, [3] = 7, [7] = 1, [13] = 4, [20] = 6 }

-- 21-40 inherit 1-20's allocation. Keeps the upper half populated without a second
-- table to keep in sync, and guarantees the rules above hold there too by construction.
local function inRaidSet(key, i)
    local set = RAID_ALLOC[key]
    if not set then return false end
    return set[i] == true or (i > 20 and set[i - 20] == true)
end

-- ☠ FILE SCOPE, NOT PER CALL. These were built fresh inside GetTestUnitData on
-- every call -- six 40-entry raid tables (plus the boss names) per frame per call,
-- and the animation ticker calls it for every test frame 20 times a second, so an
-- animating raid preview threw away hundreds of these tables a second. They are
-- read-only; nothing below writes to them.
local bossNames = {
    "Fiery Treant", "Charred Bramble", "Smoldering Sapling", "Ember Root",
    "Blazing Thorn", "Ashen Oak", "Cinder Vine", "Glowing Grove",
}

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

-- Get test unit data for a frame index
-- For party: index 0 = player, 1-4 = party members
-- For raid: index 1-40 = raid members
function DF:GetTestUnitData(index, isRaid, isBoss)
    local db = isRaid and DF:GetRaidDB() or DF:GetDB()

    -- Friendly Boss NPC test data (for pinned frame boss mode).
    -- Boss NPCs don't have classes or roles — we return a minimal fake unit
    -- so the frame renders a health bar with a readable name.
    if isBoss then
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
            isPhased = false,
            inVehicle = false,
            -- Text Designer: a boss shows a hidden level ("??") and the Boss tag.
            level = -1,
            classification = "worldboss",
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
        local i = index
        local baseHealth = testHealthPercents[i] or 0.75
        local basePower = testPowerPercents[i] or 0.80
        
        -- Dead frames come from RAID_ALLOC.DEAD (9, 17 and their +20 mirrors).
        local isDead = inRaidSet("DEAD", i)
        
        -- ☠ THE OVERLAY NAMES A DEBUFF THAT IS ACTUALLY ON THE FRAME. Ask the engine which
        -- types the frame's own debuff window holds rather than picking a type by index, or a
        -- unit shows a Poison overlay over three debuffs, none of them Poison. nil when it holds
        -- none, which is how the pool's untyped entries set how often an overlay appears at all.
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
            absorbPercent = (not isDead and inRaidSet("ABSORB", i)) and 0.15 or 0,
            reducedMaxPct = (not isDead and inRaidSet("REDUCEDMAX", i)) and 0.30 or 0,
            healAbsorbPercent = (not isDead and inRaidSet("HEALABSORB", i)) and 0.15 or 0,
            healPredictionPercent = (not isDead and inRaidSet("HEALPRED", i)) and 0.12 or 0,
            status = isDead and "Dead" or nil,
            outOfRange = inRaidSet("OOR", i),
            isLeader = inRaidSet("LEADER", i),
            isAssist = inRaidSet("ASSIST", i),
            raidTarget = RAID_MARKERS[i] or (i > 20 and RAID_MARKERS[i - 20]) or nil,
            dispelType = dispelType,
            -- Centre region: resurrect wins on a dead frame, otherwise the summon set.
            -- RAID_ALLOC keeps SUMMON off every dead frame, so this `or` never hides one.
            centerStatus = isDead and "resurrect" or (inRaidSet("SUMMON", i) and "summon" or nil),
            -- Which of live's three summon states this frame demonstrates. Mirrors
            -- inRaidSet's 21-40 wrap so the upper half of a full raid shows the spread
            -- too. nil (and party mode) falls through to Pending.
            summonState = RAID_SUMMON_STATE[i] or (i > 20 and RAID_SUMMON_STATE[i - 20]) or nil,
            isMainTank = inRaidSet("MAINTANK", i),
            isMainAssist = inRaidSet("MAINASSIST", i),
            -- ☠ THE AFK ICON CARRIES A TICKING COUNTDOWN. It must never land on an
            -- out-of-range or dead frame -- see rule 1 on RAID_ALLOC.
            isAFK = inRaidSet("AFK", i) and not isDead,
            isPhased = inRaidSet("PHASED", i),
            inVehicle = inRaidSet("VEHICLE", i),
            isBGCarrier = inRaidSet("BGCARRIER", i),
            isInCombat = inRaidSet("COMBAT", i),
            -- Text Designer's target name: healers target the first tank, everyone
            -- else the boss; the dead target nothing.
            targetName = (not isDead) and ((testRoles[i] == "HEALER") and testNames[1] or bossNames[1]) or nil,
            -- ☠ WHITELIST -- see the party branch's note. These four are the per-frame
            -- overrides; without them the raid preview ignores the unit allocation and drives the
            -- missing-buff strip on EVERY frame.
            -- Written as hard true/false rather than left nil: the fallback rules are
            -- "missing buff shows everywhere" and "defensive shows for TANK/HEALER", and
            -- both are exactly what we are overriding.
            showMissingBuff = inRaidSet("MISSINGBUF", i),
            showDefensive   = inRaidSet("DEFENSIVE", i),
            showReadyCheck  = inRaidSet("READYCHECK", i),
            showPing        = inRaidSet("PING", i),
            showDebuffs     = nil,   -- every frame keeps its debuff row...
            -- ...but only two of twenty get the IMPORTANT treatment. Enlarged + badged on
            -- every frame read as the default state of a raid rather than as an alert
            -- ("it looks too heavy on raid"), which is the opposite of what the styling is
            -- for. Two is enough to judge it against its plain neighbours.
            showImportantDebuff = inRaidSet("IMPORTANTDEBUFF", i),
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
        isPhased = data.isPhased,
        inVehicle = data.inVehicle,
        isBGCarrier = data.isBGCarrier,
        isInCombat = data.isInCombat,
        -- Text Designer's target name: healers target the first unit, everyone else
        -- the boss; dead and offline units target nothing.
        targetName = (not data.status) and ((data.role == "HEALER") and units[1].name or bossNames[1]) or nil,
        -- ☠ THIS TABLE IS A WHITELIST, NOT A COPY. Every field a consumer reads has to
        -- be listed here or it is silently dropped between DF.TestData.units and the
        -- drives — adding a field to a unit row alone does NOTHING, with no error to say
        -- so. That is exactly how showDefensive/showMissingBuff first shipped inert:
        -- the units table said one thing and the preview ignored it.
        -- ⇒ ADD ANY NEW PER-UNIT FIELD HERE TOO, and check it arrives.
        -- Both are tri-state; nil must survive as nil so the fallback rule still applies.
        showDefensive = data.showDefensive,
        showMissingBuff = data.showMissingBuff,
        showReadyCheck = data.showReadyCheck,
        showPing = data.showPing,
        showDebuffs = data.showDebuffs,
        showImportantDebuff = data.showImportantDebuff,
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
    -- Animate Health on erased the five frames' distinct levels (100 / 70 / 60 / 30)
    -- and switching it off brought them back. The raid and boss branches always did
    -- this correctly -- `baseHealth + wave * 0.15` -- and this now matches them, so
    -- the three agree and the scenarios survive the toggle.
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
    -- A frame that carries its own test data (frame.dfTestData) paints that; every
    -- pooled frame gets the shared lookup, exactly as before.
    local testData = DF:GetTestDataForFrame(frame, index, isRaid, isBoss)
    if not testData then return end
    
    local db = DF:GetFrameDB(frame)
    
    -- Dead or offline units should always show 0 health - no animation
    if testData.status then
        DF.SetBarValueSmoothed(frame.healthBar, 0, db and db.smoothBars)
        frame.testAnimatedHealth = 0
        if frame.healthText and frame.healthText:IsShown() then
            frame.healthText:SetText("")
        end
        return
    end
    
    -- ☠ NO SECOND WAVE HERE. GetTestUnitData applies the animation itself (see its
    -- party/raid/boss branches), so testData.healthPercent arrives animated. Adding another
    -- sine at a different phase would sum to a bar that clamps flat once per cycle, and
    -- because any settings change re-renders through GetTestUnitData alone, the bar would
    -- jump between the two. The ticker advances animationPhase and simply RENDERS what
    -- GetTestUnitData produced.
    local health = testData.healthPercent or testData.health or 0.75

    -- Store animated health for bar updates
    frame.testAnimatedHealth = health

    -- ☠ THE ANIMATION TICKER WAS THE ONE SITE WITH A BARE SetValue. Every other health
    -- write -- live, the full test render, and the missing-health companion five lines
    -- below -- goes through the smoothed setter, so with Smooth Bar Animation on the two
    -- halves of an animated preview bar moved on different rules and the setting read as
    -- having no effect in test mode. Interpolation and a 20 Hz ticker
    -- compose: each tick eases toward the new target instead of snapping to it, which is
    -- exactly what live does when health events arrive.
    DF.SetBarValueSmoothed(frame.healthBar, health, db and db.smoothBars)

    -- ☠ A THIRD HEALTH-FADE RULE LIVED HERE and it disagreed with the real one on
    -- both counts: it crossed at `>= threshold - 0.5` where DF:ApplyHealthFadeAlpha
    -- crosses at `>` (matching the curve's threshold/100 -/+ 0.001 points), and its
    -- below-threshold alpha was a flat 1.0, ignoring rangeFadeAlpha -- so an
    -- out-of-range unit under the threshold dimmed live and did not in the preview.
    -- Stamping the ANIMATED fraction and calling the real function fixes both, and
    -- keeps every other dfHealthPct consumer honest mid-animation.
    frame.dfHealthPct = health
    frame.dfTestMaxHealth = testData.maxHealth
    frame.dfTestCurrentHealth = math.floor((testData.maxHealth or 100000) * health)
    if DF.ApplyHealthFadeAlpha then DF:ApplyHealthFadeAlpha(frame) end

    -- ☠ THE BAR COLOUR HAS TO BE RE-RUN TOO. Live pairs every health change with the
    -- colour applier -- Frames/Update.lua does SetHealthBarValue then
    -- UpdateHealthBarAppearance, twice -- because in "Health Gradient" (PERCENT) mode
    -- the colour IS a function of health. This ticker set the value and the stamps but
    -- never the colour, so an animated preview kept whatever colour the last full
    -- render happened to leave: the bars moved and stayed green. CLASS and CUSTOM hid
    -- the bug, since their colour does not depend on health.
    --   Must run AFTER the dfHealthPct stamp above -- that is the DATA the test fork
    -- inside UpdateHealthBarAppearance reads instead of UnitHealthPercent.
    --   Safe next to ApplyHealthFadeAlpha: the fade writes the FRAME's alpha
    -- (HealthFade.lua `frame:SetAlpha`) and this writes the TEXTURE's, so neither
    -- clobbers the other regardless of order.
    if DF.UpdateHealthBarAppearance then DF:UpdateHealthBarAppearance(frame) end

    -- ★ LIVE'S MISSING-HEALTH RENDERER, not a copy of it. DF.SetMissingHealthBarValue
    -- reads the frame stamps, so there is one renderer; it also owns the BACKGROUND-mode
    -- hide, so no branch is needed here.
    if frame.missingHealthBar then
        DF.SetMissingHealthBarValue(frame.missingHealthBar, frame.unit, frame)
    end

    -- ★ Live's formatter, driven by the stamps above -- the preview kept two of its
    -- own, both of which disagreed with live.
    DF:ApplyHealthText(frame, db, DF.IsLegacyTextHidden and DF:IsLegacyTextHidden(frame))

    -- Update bars to follow animated health (use animated health value).
    -- ⚠ NOT COPIED. testData is this call's own fresh table (GetTestUnitData builds a
    -- new one per call and keeps no reference), so writing into it is safe and saves a
    -- ~40-field throwaway table per frame per 20 Hz tick.
    testData.healthPercent = health
    local animatedTestData = testData
    
    -- ☠ REDUCED MAX HEALTH MUST RE-RUN ON EVERY HEALTH CHANGE. Live's UpdateHealthFast
    -- calls it explicitly for exactly that reason; this ticker never did, so with
    -- Reduced Max Health + Clip Health Bar on, the clipped edge was set once by
    -- UpdateTestFrame and then stayed put while the bar animated underneath it.
    if DF.UpdateReducedMaxHealth then DF:UpdateReducedMaxHealth(frame) end

    -- ☠ LIVE'S ORDER — heal absorb, prediction, absorb LAST. The absorb chains to the
    -- prediction's tail and reads its stamps, so it must run after it; see the same
    -- note at the UpdateTestFrame drive, which is where the one-pass version of this
    -- ordering bug was field-caught. The ticker repeats every tick, so it self-healed
    -- one tick late here — but a painter that is only accidentally correct is the
    -- second-pathway class, and the two drive sites must stay identical.
    if db.testShowAbsorbs then
        DF:UpdateHealAbsorb(frame, animatedTestData)
    end
    if db.testShowHealPrediction ~= false then
        DF:UpdateHealPrediction(frame, animatedTestData)
    end
    if db.testShowAbsorbs then
        DF:UpdateAbsorb(frame, animatedTestData)
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
    -- A frame that carries its own test data (frame.dfTestData) paints that; every
    -- pooled frame gets the shared lookup, exactly as before.
    local testData = DF:GetTestDataForFrame(frame, index, isRaid, isBoss)
    if not testData then return end

    -- Stamped rather than re-resolved: the aura drives below (and their bulk
    -- refresh siblings, which do NOT receive testData) all need it, and
    -- GetTestUnitData rebuilds the raid class/role/name arrays on every call.
    -- Index -> data is fixed for a pooled frame's whole life, so it cannot go
    -- stale. See DF:IsTestFrameDead.
    frame.dfTestIsDead = (testData.status == "Dead") or nil

    -- ★ PER-UNIT SURFACE OVERRIDES. Both are TRI-STATE and both default to nil, which
    -- means "use the normal rule" — so a unit that says nothing behaves exactly as
    -- before and only the units that opt in differ.
    --   showDefensive   nil = the role rule (TANK/HEALER only) · true/false = force
    --   showMissingBuff nil = shown (the live default) · false = hidden
    -- These exist because both surfaces were decided by a RULE with no per-unit say, so
    -- the only way to move one off a crowded frame was to change that unit's ROLE —
    -- which drags the role icon, sorting and role colours with it. The units table is
    -- meant to be the single description of what each frame demonstrates; this keeps it
    -- that way. Assigning nil deliberately CLEARS a previous frame's value.
    frame.dfTestShowDefensive = testData.showDefensive
    frame.dfTestShowMissingBuff = testData.showMissingBuff
    frame.dfTestShowDebuffs = testData.showDebuffs
    -- Keeps the debuff ROW but drops the enlarged + badged IMPORTANT treatment. Read by
    -- DF:DriveDebuffFactory, which shadows debuffImportantHighlight for this frame only.
    -- ⚠ Structural (recStyleSig serialises the per-record style), so a change here
    -- rebuilds that frame's container rather than restyling in place — expected, and why
    -- it lands on a refresh rather than instantly.
    frame.dfTestShowImportantDebuff = testData.showImportantDebuff

    -- ★ THE SHARED STAMPS ElementAppearance's helpers prefer. Test frames carry REAL
    -- unit tokens ("raid1", "player"), so in an actual group UnitIsDeadOrGhost /
    -- UnitClass would answer about a real player standing next to you rather than
    -- about this scenario -- which is what forced those helpers to be walled off from
    -- test mode in the first place. Stamping is what lets the live appearance code run
    -- on a preview frame at all.
    frame.dfIsDead = (testData.status == "Dead") or (testData.status == "Offline") or false
    frame.dfIsOffline = (testData.status == "Offline") or false
    frame.dfClassToken = testData.class
    -- Reaction / tapped, for the REACTION health colours (nil on group test units:
    -- assigning nil clears a previous frame's value). See Frames/Colors.lua.
    frame.dfTestReaction = testData.reaction
    frame.dfTestTapped = testData.isTapped or nil
    -- The health fraction, so the three curve-driven appearance functions can run
    -- on a preview frame. Live gets this from UnitHealthPercent(unit, true, curve),
    -- which is secret-safe and needs a REAL unit; the preview has a plain number.
    frame.dfHealthPct = testData.healthPercent or 1
    -- Absolute health, for the current / current-max / deficit text formats.
    frame.dfTestMaxHealth = testData.maxHealth
    frame.dfTestCurrentHealth = testData.currentHealth

    local db = DF:GetFrameDB(frame)

    -- Set dfInRange for test mode - consumed by the range/alpha systems
    local isTestOutOfRange = db.testShowOutOfRange and testData.outOfRange and not testData.status
    frame.dfInRange = not isTestOutOfRange
    
    -- Update health bar (use 0-1 range for test mode)
    frame.healthBar:SetMinMaxValues(0, 1)
    local healthValue = testData.healthPercent
    
    DF.SetBarValueSmoothed(frame.healthBar, healthValue, db.smoothBars)

    -- ★ LIVE'S INSET, not a restatement of it. UpdateReducedMaxHealth below may re-clip
    -- the right edge after.
    DF:AnchorHealthBarsToPadding(frame, db)

    if db.testShowReducedMaxHealth ~= false then
        frame.dfTestReducedMaxPct = testData.reducedMaxPct or 0
    else
        frame.dfTestReducedMaxPct = 0
    end
    if DF.UpdateReducedMaxHealth then DF:UpdateReducedMaxHealth(frame) end

    -- ★ LIVE'S MISSING-HEALTH RENDERER, not a copy of it. DF.SetMissingHealthBarValue
    -- reads the frame stamps, so there is one renderer; it also owns the BACKGROUND-mode
    -- hide, so no branch is needed here.
    if frame.missingHealthBar then
        DF.SetMissingHealthBarValue(frame.missingHealthBar, frame.unit, frame)
    end

    DF:ApplyHealthText(frame, db, DF.IsLegacyTextHidden and DF:IsLegacyTextHidden(frame))

    -- Name through the LIVE renderer, supplying only the fabricated name.
    DF:UpdateName(frame, testData.name)
    
    -- ☠ (Removed) THE PER-ELEMENT ALPHA BLOCK, and the three tables it existed to fill:
    -- frame.dfTestOORAlphas, frame.dfTestDeadFadeAlphas and frame.dfTestHealthFadeAlphas.
    --
    -- ~95 lines computing out-of-range, dead-fade and health-fade alphas. Their ONLY
    -- reader was the alpha chain at the end of DF:UpdateTestPowerBar, and that chain was
    -- overwritten on every render by DF:UpdatePowerBarAppearance (via the
    -- UpdateAllElementAppearances pass further down), which handles test frames itself.
    -- So the whole block computed values nothing could observe -- including a `.dispel`
    -- and an `.auras` entry that never had a reader at all, in any build.
    --
    -- ⚠ THIS IS THE SAME LESSON THE SURVIVING NOTES IN THIS FILE ALREADY TEACH, one
    -- level up. Each of those notes records pruning ONE element's hand-mirrored alpha
    -- after it shipped a bug (the squared range fade, the squared health fade, the six
    -- wrong OOR fallbacks, the icons). Every prune was correct and none of them asked
    -- the next question: if every individual element belongs to ElementAppearance, what
    -- is the block still for? Nothing -- only the power bar was left, and live owned
    -- that too. The right unit of removal was the block, not another element.
    --
    -- Nothing here is lost: live resolves all three fades from db + the dfTestIsDead
    -- stamp (set well above, at the top of this function) and the range stamp, which is
    -- why DF:UpdatePowerBarAppearance can pass test frames straight through.
    --
    -- ⚠ Do not reintroduce a per-element alpha here for a NEW element either. That is
    -- the move that produced every bug listed above.

    -- Name text colour + alpha: DF:UpdateNameTextAppearance owns both (it deliberately
    -- writes colour at alpha 1.0 and controls opacity through SetAlpha, so that
    -- SetAlphaFromBoolean keeps working). Applied by the shared pass further down.
    
    -- ☠ HEALTH-BAR AND BACKGROUND COLOUR are not set here: DF:UpdateHealthBarAppearance
    -- and DF:UpdateBackgroundAppearance accept test frames, so the shared appearance pass
    -- at the end of this function applies them. A preview copy would drift (live REPLACES
    -- the base alpha with the OOR alpha where a copy is easily written to multiply it).

    -- ☠ NO FRAME-LEVEL ALPHA HERE. The shared appearance pass below owns frame alpha
    -- outright, and it runs LAST, so a preview reimplementation could only be overwritten or
    -- disagree -- and worse, it hides live-path bugs: a second pathway does not fail loudly,
    -- it fails by looking handled.
    -- ⇒ Preview differs from live in DATA (dfHealthPct, dfIsDead, the dfTestShow* stamps),
    -- never in RENDERING. If a live appearance function cannot run on a preview frame,
    -- teach it the data fork — do not copy it here.


    -- Health text colour + alpha: DF:UpdateHealthTextAppearance owns both, same as the
    -- name text. Applied by the shared pass below.
    
    -- ☠ LIVE'S ORDER — heal absorb, PREDICTION, absorb LAST — because the absorb DEPENDS
    -- on the prediction: it chains to the prediction's tail (ResolveAbsorbChainAnchor)
    -- and its clamp reads the netted-heal stamps UpdateHealPrediction writes
    -- (dfTotalHeals). Absorb first would compute the shield against a prediction that does
    -- not exist yet. Entry's After(0) repaint would converge it, but the panel-toggle path
    -- (RefreshTestFrames) runs ONE pass, leaving cross-dependent frames wrong until the next
    -- repaint. ApplyFrameLayout carries the same ordering note.
    if db.testShowAbsorbs then
        DF:UpdateHealAbsorb(frame, testData)
    else
        if frame.dfHealAbsorbBar then frame.dfHealAbsorbBar:Hide() end
        if frame.healAbsorbOvershieldGlow then frame.healAbsorbOvershieldGlow:Hide() end
        if frame.healAbsorbAttachedTexture then frame.healAbsorbAttachedTexture:Hide() end
    end

    -- Heal prediction (check test mode setting) — BEFORE the absorb, which chains to it.
    if db.testShowHealPrediction ~= false then
        DF:UpdateHealPrediction(frame, testData)
    else
        -- ☠ BOTH SEGMENTS. ChainEndKey tests seg2 FIRST, so hiding only segment 1 would leave
        -- the preview's shield chained behind a segment the user just switched off. The toggle
        -- has to leave the same rendered state the live pathway would.
        if frame.dfHealPredictionBar then frame.dfHealPredictionBar:Hide() end
        if frame.dfHealPredictionBar2 then frame.dfHealPredictionBar2:Hide() end
        if frame.dfOverhealSpark then frame.dfOverhealSpark:Hide() end
    end

    -- Damage absorb LAST — reads the prediction's chain tail and stamps.
    if db.testShowAbsorbs then
        DF:UpdateAbsorb(frame, testData)
    else
        if frame.dfAbsorbBar then frame.dfAbsorbBar:Hide() end
        if frame.absorbOvershieldGlow then frame.absorbOvershieldGlow:Hide() end
        if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
        -- Hide attached texture used for ATTACHED mode test display
        if frame.absorbAttachedTexture then frame.absorbAttachedTexture:Hide() end
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
            frame.buffFactory:SetIntentShown(false)
            frame.dfBuffFactoryShown = false
        end
        if frame.debuffFactory then
            frame.debuffFactory:SetIntentShown(false)
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
        -- ★ Row fades through the live functions. They compose the same three inputs
        -- (row opacity x dead fade x out-of-range) and use the row's own opacity as the
        -- BASE. One implementation, so the slider cannot mean two things.
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
    
    -- Update defensive icons. Unconditional: the painter decides for itself whether the
    -- row shows (defensiveIconEnabled + testDefensiveCount > 0 + role), and it must be
    -- able to HIDE the 12.1 container row, not just skip painting a legacy icon.
    DF:UpdateTestDefensiveBar(frame, testData)

    -- ★ FADES COME FROM THE LIVE FUNCTIONS. ElementAppearance's own functions accept test
    -- frames: every unit read they make goes through GetInRange / IsDeadOrOffline, both of
    -- which prefer the stamps set at the top of this function. One policy, one place -- a
    -- hand-mirrored copy here silently stops fading each time an oor*Alpha key is added.
    --
    -- ⚠ AFTER the two drives above, not before: both widgets are created LAZILY by
    -- those drives, so earlier in the pass they are still nil on a frame's first
    -- paint. Neither drive touches alpha, so setting it here sticks.
    -- Update Aura Designer test indicators through the factory containers — the
    -- SAME path as the bulk DF:UpdateAllTestAuraDesigner, so the per-frame and
    -- bulk previews can't drift.
    --
    -- ☠ THIS MUST RUN *BEFORE* THE APPEARANCE PASS, NOT AFTER. SyncFrame re-styles
    -- each indicator, which resets its alpha host to the indicator's BASE alpha --
    -- so after the pass it wipes every out-of-range AD fade the pass just applied. It is
    -- signature-gated, so that bug looks intermittent: a setting that changes nothing
    -- structural makes SyncFrame a no-op and the fade survives, while a fresh Test Mode
    -- open or a Quick Preset swap re-styles and drops the AD indicator back to full opacity.
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
    -- the four bars, missing buff, defensive and the Aura Designer.
    --
    -- ☠ ADD NOTHING HERE THAT ElementAppearance ALREADY APPLIES, and ADD NOTHING BELOW IT
    -- that touches alpha: a copy here misses each new oor*Alpha or fadeDead* key and the
    -- preview quietly stops matching live.
    -- ⚠ BEFORE the appearance pass, not after. UpdateHealthFade's job here is to set
    -- frame.dfHealthFadeActive, and UpdateFrameAppearance (inside the pass below) gates
    -- its health-fade branch on that flag — so a call afterwards would set the flag one
    -- pass too late and the frame would render opaque until something else refreshed it.
    -- ★ The LIVE driver, not a preview copy: it resolves the same alpha through
    -- ApplyHealthFadeAlpha, which forks only on DATA (dfHealthPct vs UnitHealthPercent).
    if DF.UpdateHealthFade then
        DF:UpdateHealthFade(frame)
    end

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
    --
    -- ★ THE LIVE UPDATER, fed test DATA. DF:UpdateRoleIcon takes a role override, so
    -- the per-role visibility filter, the texture pick, the positioning and the
    -- MemTest gate are one implementation.
    --
    -- ☠ (Removed) a copy of the roleIconShowTank/Healer/DPS filter that also omitted
    -- live's DF:MemTestDisabled("enableRoleLeaderIcons") gate -- so running the Memory
    -- Test panel with role and leader icons unticked left them lit on every test frame
    -- while live hid them. The preview was showing a state the addon cannot be in.
    --
    -- ⚠ roleIconHideInCombat needs no special handling: live reads DF.playerInCombat,
    -- and test mode is torn down on PLAYER_REGEN_DISABLED, so the preview is never on
    -- screen in combat and live's gate resolves the same way the old comment here
    -- reasoned it would.
    if frame.roleIcon then
        DF:UpdateRoleIcon(frame, "testmode", testData.role)
    end
    
    -- Leader Icon
    if frame.leaderIcon then
        if not db.leaderIconEnabled then
            frame.leaderIcon:Hide()
        elseif testData.isLeader or testData.isAssist then
            DF:SetUpgradedStatusIcon(frame.leaderIcon.texture, testData.isLeader
                and "Interface\\GroupFrame\\UI-Group-LeaderIcon"
                or "Interface\\GroupFrame\\UI-Group-AssistantIcon")
            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.leaderIcon, db, "leaderIcon")
            end
            frame.leaderIcon:Show()
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
            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.raidTargetIcon, db, "raidTargetIcon")
            end
            frame.raidTargetIcon:Show()
        else
            frame.raidTargetIcon:Hide()
        end
    end
    
    -- ☠ (Removed) THE READY CHECK BLOCK. It was a byte-identical 24-line twin of the one
    -- in DF:UpdateTestStatusIcons, carrying a "change one, change the other" warning --
    -- and the hand-syncing it asked for was never needed, because the copy could not
    -- affect anything. DF:UpdateTestFrame calls UpdateTestIcons (gated on
    -- testShowStatusIcons) and then calls UpdateTestStatusIcons UNCONDITIONALLY nine
    -- lines later, so the surviving block recomputed the identical result over the top
    -- on every single render. The copy also re-tested `testShowStatusIcons == false`
    -- inside a branch its own caller had already gated on that key.
    --
    -- ⚠ There is now ONE ready-check implementation, in DF:UpdateTestStatusIcons. Do not
    -- reinstate a copy here: a second pathway does not fail loudly, it fails by looking
    -- handled (the same reasoning as the ★ note at the top of UpdateTestFrame).

    -- ★ NO SECOND ALPHA PASS — matching the other status-icon updater.
    --
    -- DF:ApplyStatusIconSettings folds DF:GetStatusIconFadeAlpha into each icon's
    -- alpha, and all four icons above now go through it. Re-applying here would
    -- SQUARE the fade, the same mistake the range and health fades made before
    -- ef3c56e0.
    --
    -- ☠ AND IT WAS OVERWRITING, NOT COMPOUNDING. This pass ended with a bare
    -- SetAlpha(alpha), so it discarded whatever the applier had computed -- including
    -- the per-icon `<prefix>Alpha` setting, which the four hand-rolled blocks never
    -- read in the first place. Set roleIconAlpha to 0.5 and live dimmed the icon while
    -- the preview drew it solid.
    --
    -- The health-fade arm went further and previewed something live does not do at
    -- all: HealthFade.lua touches no status icon, so `dfTestHealthFadeAlphas.icons`
    -- described a behaviour that exists only in test mode. Dead and out-of-range fade
    -- are both real and both live in GetStatusIconFadeAlpha, which reads the same
    -- dfTestIsDead stamp the preview already sets.
end

-- ★ ShowTestIconAsText and ApplyTestIconTimerFont are GONE. The first restated
-- live's ShowIconAsText and then re-applied the font and text colour on top --
-- work DF:ApplyStatusIconSettings already does, and doing it a second time AFTERWARDS
-- clobbered any per-state tint. The second was already a one-line forward to
-- DF:ApplyTimerTextSettings, which ApplyStatusIconSettings also calls. The preview now
-- uses DF:ShowStatusIconAsText, which IS live's function.

-- ☠ (Removed) FormatTestAFKTime and testAFKStartTimes, the last two pieces of the
-- preview's private AFK implementation.
--
-- Worth recording how this ended, because the first pass stopped a level too early:
-- the formatter was a verbatim copy of a StatusIcons.lua file-local, so it was fixed
-- by publishing DF:FormatAFKTime and forwarding to it. That was correct but small --
-- the ~50 lines AROUND the formatter were still a copy, and one of them had already
-- dropped live's afkIconHideInCombat gate. Sharing the leaf made the duplication
-- look handled while the drift stayed. The whole block now calls DF:UpdateAFKIcon
-- with an isAFK override, and the start times live in live's own table.

-- Update only status icons (ready check, center status) - separated from role/leader icons
function DF:UpdateTestStatusIcons(frame, testData)
    if not frame then return end
    if not testData then return end
    
    local db = DF:GetFrameDB(frame)
    
    -- Ready Check Icon. Per-unit `showReadyCheck` first, "the leader frame" as the
    -- fallback — see the note on the Tankerino/Мишок rows in DF.TestData for why it does
    -- not ride the leader.
    -- ★ THE ONLY ready-check block: this function runs unconditionally after
    -- DF:UpdateTestIcons, so a twin there would always be overwritten.
    if frame.readyCheckIcon then
        local wantReady = testData.showReadyCheck
        if wantReady == nil then wantReady = testData.isLeader end
        if not db.readyCheckIconEnabled or db.testShowStatusIcons == false then
            frame.readyCheckIcon:Hide()
        elseif wantReady then
            DF:SetUpgradedStatusIcon(frame.readyCheckIcon.texture, "Interface\\RaidFrame\\ReadyCheck-Ready")
            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.readyCheckIcon, db, "readyCheckIcon")
            end
            frame.readyCheckIcon:Show()
        else
            frame.readyCheckIcon:Hide()
        end
    end

    -- Ping Icon (Features/PingMirror.lua). Real atlas, live geometry applier.
    if frame.pingIcon then
        if not db.pingIconEnabled or db.testShowStatusIcons == false then
            frame.pingIcon:Hide()
        elseif testData.showPing then
            if DF.SetPingIconKit then DF:SetPingIconKit(frame.pingIcon, "Warning") end
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.pingIcon, db, "pingIcon")
            end
            frame.pingIcon:Show()
        else
            frame.pingIcon:Hide()
        end
    end
    
    -- Summon Icon
    if frame.summonIcon then
        if not db.summonIconEnabled or db.testShowStatusIcons == false then
            frame.summonIcon:Hide()
        elseif testData.centerStatus == "summon" then
            -- ☠ ONLY PENDING WAS PREVIEWABLE. Live renders three summon states, each
            -- with its own texture AND its own user-editable text key -- Accepted and
            -- Declined both have seeded defaults, edit boxes on the Modules page and
            -- profile export, so two settings existed that a user could never see in
            -- order to judge them. Alternate by frame so all three are on screen at
            -- once, the same fix the resurrection icon and the phased LFG eye already
            -- use below.
            --
            -- ⚠ Keep these in the same order as live's Pending/Accepted/Declined
            -- branches: texture and text key are paired per state, and swapping one
            -- without the other is the drift this preview exists to catch.
            local summonTexture, summonText
            if testData.summonState == "accepted" then
                summonTexture = "Interface\\RaidFrame\\Raid-Icon-SummonAccepted"
                summonText    = db.summonIconTextAccepted or "Accepted"
            elseif testData.summonState == "declined" then
                summonTexture = "Interface\\RaidFrame\\Raid-Icon-SummonDeclined"
                summonText    = db.summonIconTextDeclined or "Declined"
            else
                summonTexture = "Interface\\RaidFrame\\Raid-Icon-SummonPending"
                summonText    = db.summonIconTextPending or "Summon"
            end
            DF:SetUpgradedStatusIcon(frame.summonIcon.texture, summonTexture)

            -- Geometry, base alpha and frame level from the LIVE applier.
            if DF.ApplyStatusIconSettings then
                DF:ApplyStatusIconSettings(frame.summonIcon, db, "summonIcon")
            end

            -- Show as text or icon (with font and color settings)
            DF:ShowStatusIconAsText(frame.summonIcon, summonText, db.summonIconShowText)
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
            DF:SetCombatStatusIcon(frame.combatIcon.texture)

            -- ☠ THE LIVE APPLIER, like the other seven icons. ApplyStatusIconSettings carries
            -- combatIconAlpha, combatIconFrameLevel and the out-of-range/dead fade (via
            -- GetStatusIconFadeAlpha); a hand-rolled scale/anchor block would lose all three and
            -- disagree with live's defaults (CENTER/0/0).
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
    --
    -- ★ THE LIVE UPDATER, fed test DATA. DF:UpdateAFKIcon takes an isAFK override, so
    -- the enabled gate, the combat gate, the geometry applier, the elapsed-timer
    -- bookkeeping and the text-vs-icon-mode split are all live's single implementation.
    --
    -- ☠ (Removed) ~50 lines restating that function, comments and all. Only the leaf
    -- formatter had been shared before; the block around it was still a copy, and it
    -- had already lost live's afkIconHideInCombat gate -- so the preview kept the icon
    -- up in combat while live hid it, and that setting could not be judged from the
    -- preview at all. It also kept its own testAFKStartTimes table keyed by
    -- tostring(frame); live keys by GetAFKKey, which falls back to the unit token for
    -- exactly this case.
    if frame.afkIcon then
        if db.testShowStatusIcons == false then
            frame.afkIcon:Hide()
            if frame.afkIcon.timerText then frame.afkIcon.timerText:Hide() end
        else
            -- ⚠ ART FIRST, and it is NOT a duplicate of live: live sets this texture
            -- once at frame creation and UpdateAFKIcon never re-sets it, so the preview
            -- has to assert it on the pooled test frame itself.
            -- ☠ ESCAPED BACKSLASHES. A single-backslash path here rendered NOTHING while
            -- live was fine — `\F` and `\S` are not escapes Lua recognises and the path
            -- collapses. Every SetUpgradedStatusIcon call in this file uses \\.
            if testData.isAFK then
                DF:SetUpgradedStatusIcon(frame.afkIcon.texture, "Interface\\FriendsFrame\\StatusIcon-Away")
            end
            DF:UpdateAFKIcon(frame, testData.isAFK and true or false)
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
        -- is most likely to be trusted. Match live.
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
end

-- ☠ A CORPSE CARRIES NO AURAS, so the preview must not draw any on one. Death
-- strips buffs and debuffs outright, and the defensive icon and missing-buff badge
-- describe things that only mean something on a living unit — a dead frame covered
-- in icons is a shape live play never produces, which makes it a bad reference for
-- judging layout. The dispel overlay already did this.
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
            -- ☠ A COUNT OF 0 MEANS "DON'T PREVIEW THIS ROW", AND HAS TO HIDE IT.
            -- `testSlotCount` floors at 1 — a container with no slots is a degenerate
            -- thing to declare — so a 0 that reaches the drive comes back as ONE sample
            -- icon. Gate it HERE, before the drive, and let the existing else-branch hide the
            -- row: that reuses the same shown-cache path as "Show Auras" off, so
            -- re-raising the slider re-shows correctly. Do NOT instead teach the
            -- container to build zero slots — slots are add-only and a 0-slot rebuild
            -- would strand frames for the session.
            -- ⚠ THE LIVE MAX IS THE OTHER WAY IN. The container resolves a preview count as
            -- min(testMax, max) and only THEN floors the slot count at 1, so Max Buffs / Max
            -- Debuffs = 0 would arrive as one sample icon too. Clamp by both here so either zero
            -- hides the row. Mirrors the defensive bar's min(testDefensiveCount, defensiveBarMax).
            local buffCount = math.min(db.testBuffCount or 2, db.buffMax or 4)
            local debuffCount = math.min(db.testDebuffCount or 2, db.debuffMax or 5)
            if db.showBuffs and showAuras and buffCount > 0 and DF.DriveBuffFactory then
                DF:DriveBuffFactory(frame, db)
                -- Test count slider hot-applies (structural: the handle rebuilds).
                if frame.buffFactory and frame.buffFactory.SetTestMax then
                    frame.buffFactory:SetTestMax(buffCount)
                end
            elseif frame.buffFactory then
                frame.buffFactory:SetIntentShown(false)
                frame.dfBuffFactoryShown = false
            end
            -- ⚠ `~= false` so nil (every unit that does not opt out) still shows the row.
            -- Per-unit opt-out; see the stamps in UpdateTestFrame.
            if db.showDebuffs and showAuras and debuffCount > 0
                and frame.dfTestShowDebuffs ~= false and DF.DriveDebuffFactory then
                DF:DriveDebuffFactory(frame, db)
                if frame.debuffFactory and frame.debuffFactory.SetTestMax then
                    frame.debuffFactory:SetTestMax(debuffCount)
                end
            elseif frame.debuffFactory then
                frame.debuffFactory:SetIntentShown(false)
                frame.dfDebuffFactoryShown = false
            end
        end
        return
    end

end

-- The mock unit's primary resource, for DF:GetResourceBarColor's powerTokenOverride.
--
-- ⚠ DERIVED FROM CLASS, NOT ROLE. The raid roster carries all thirteen classes, and
-- FOCUS, RUNIC_POWER and FURY are all editable on the Colors page with no other way
-- to see them. Role is still consulted, but only where a class genuinely splits by
-- spec role.
--
-- ⚠ KNOWN LIMIT, deliberately not faked: the roster models class and role, not spec,
-- so the spec-only resources -- LUNAR_POWER (Balance), MAELSTROM (Elemental/Enhance),
-- INSANITY (Shadow), PAIN (Vengeance) -- still have no preview. Inventing a spec per
-- frame to reach them would be the preview showing something live does not, which is
-- the fault this whole pass exists to remove.
local TEST_POWER_TOKEN = {
    WARRIOR = "RAGE",       PALADIN = "MANA",  HUNTER  = "FOCUS",
    ROGUE   = "ENERGY",     PRIEST  = "MANA",  SHAMAN  = "MANA",
    MAGE    = "MANA",       WARLOCK = "MANA",  EVOKER  = "MANA",
    DEATHKNIGHT = "RUNIC_POWER",
}
local function TestPowerTokenFor(class, role)
    if class == "DRUID" then
        -- Guardian rages, Feral energises, Balance/Resto cast. Role is the only
        -- discriminator the test roster has.
        if role == "TANK" then return "RAGE" end
        if role == "DAMAGER" then return "ENERGY" end
        return "MANA"
    elseif class == "MONK" then
        return role == "HEALER" and "MANA" or "ENERGY"
    elseif class == "DEMONHUNTER" then
        -- Vengeance uses PAIN, but the roster cannot say which spec this is; FURY is
        -- the Havoc default and at least makes the token previewable at all.
        return "FURY"
    end
    return TEST_POWER_TOKEN[class or ""] or "MANA"
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
    
    -- ★ THE LIVE GATE, fed test DATA. DF:ShouldShowResourceBar takes an optional role
    -- override precisely so the preview can drive it without a real unit -- a test path
    -- that is a PARAMETER of the live function, not a copy of it.
    --
    -- ☠ Do not add a local copy of the role logic: it would lose the live function's solo
    -- arms (`inSoloMode and db.resourceBarShowInSoloMode`) and make that setting
    -- unpreviewable. Role AND class are both handed over as data, so the ENTIRE gate is the
    -- live one.
    --
    -- ★ WHO THE SOLO BYPASS APPLIES TO is the fourth piece of data the gate needs, and
    -- without it the solo arm would apply to all five previews.
    -- The two arms of live's own scope, mirrored: your own frame -- the FIRST slot in
    -- either container (party is 0-based, raid 1-based) -- and any pinned frame, which
    -- keeps the bypass live because the user pinned that unit by hand. Live resolves the
    -- first arm with UnitIsUnit and the second off frame.isPinnedFrame; a preview slot
    -- carries a real token belonging to somebody else, so it must answer as DATA.
    local selfIndex = frame.isRaidFrame and 1 or 0
    local soloScoped = (frame.isPinnedFrame and true) or (testData.index == selfIndex)
    local showBar = DF:ShouldShowResourceBar(nil, db, testData.role, testData.class, soloScoped)

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

    -- ★ THE LIVE COLOUR RESOLVER, fed test DATA. DF:GetResourceBarColor takes class and
    -- power-token overrides for exactly this, so the Power / Class / Custom mode
    -- resolution, the CLASS-to-power fallthrough and every default are live's.
    --
    -- ☠ Do not reinstate a local copy. The one that was here had drifted three ways --
    -- one-arg GetPowerColor, missing fallbacks, and a power token fabricated from ROLE
    -- rather than class, which left FOCUS, RUNIC_POWER, FURY and the rest unpreviewable
    -- even though they are editable on the Colors page. See the note on the live
    -- function.
    local r, g, b = DF:GetResourceBarColor(nil, db, testData.class,
        TestPowerTokenFor(testData.class, testData.role))
    bar:SetStatusBarColor(r, g, b, 1)

    -- ★ NO ALPHA PASS HERE — DF:UpdatePowerBarAppearance owns it, and always did.
    --
    -- ☠ (Removed) a dead/health/OOR alpha chain reading three test-only tables. It could
    -- not have any effect: DF:UpdateTestFrame calls this function, then ~170 lines later
    -- calls DF:UpdateAllElementAppearances, which calls DF:UpdatePowerBarAppearance --
    -- and that function explicitly passes test frames through and writes
    -- frame.dfPowerBar:SetAlpha() unconditionally. `bar` here IS frame.dfPowerBar, so
    -- live overwrote this on every single render.
    --
    -- It had also DRIFTED, which is why this matters beyond tidiness: the dead-fade
    -- fallback was `or 0.4` against live's `or 0`, and the chain had a health-fade arm
    -- that live does not have at all (UpdatePowerBarAppearance has no health-fade
    -- branch). It was a strict elseif chain, so dead and OOR could never combine, while
    -- live layers OOR on top of the dead alpha via ApplyOORAlpha. None of that showed
    -- on screen only because the result was thrown away -- exactly the failure mode the
    -- ★ note at the top of UpdateTestFrame describes: a second pathway does not fail
    -- loudly, it fails by looking handled.
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
    -- ☠ NEW SESSION TOKEN. Test frames are POOLED and their per-frame layout caches
    -- survive a toggle, so a cache that only compares db settings sees "nothing changed"
    -- and short-circuits on the very first pass -- with anchors left over from a layout
    -- that was torn down. That is why absorbs were missing on some units until you
    -- toggled test mode off and on again. Bumping this invalidates those caches once per
    -- session (see AbsorbLayoutStateChanged). Must be set BEFORE any test frame renders.
    DF.testSessionId = (DF.testSessionId or 0) + 1
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
    -- ☠ ONE REPAINT NEXT TICK, AND IT IS GEOMETRY, NOT A WORKAROUND. On the FIRST entry
    -- after a /reload the frames were created THIS tick, and healthBar is sized by
    -- anchors (SetAllPoints) — an anchor-derived rect resolves at the end of the frame's
    -- layout pass, so healthBar:GetWidth() is 0 for the whole entry pass. Every bar that
    -- sizes itself from it (heal prediction, heal absorb, attached absorb) painted with
    -- width 0: the forensics showed correct values and healthy anchors with fillW=0 on
    -- every frame. Later entries reuse pooled frames with resolved rects, which is why
    -- only the first entry per reload was broken and any toggle fixed it. Repainting on
    -- the next tick, when rects exist, goes through the SAME UpdateTestFrame pathway —
    -- no second painter.
    C_Timer.After(0, function()
        if DF.testMode and DF.RefreshTestFrames then DF:RefreshTestFrames() end
    end)
    
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
    if DF.NotifyTestModeChanged then DF:NotifyTestModeChanged("party") end
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

    -- Section labels re-place LAST and one tick later: they measure the rows they
    -- label, and a row rebuilt during this pass has a zero rect until the layout
    -- settles (the creation-tick rule). A stale label is worse than a late one — it points
    -- at where an element used to be.
    if DF.UpdateTestLabels then
        C_Timer.After(0, function() if DF.UpdateTestLabels then DF:UpdateTestLabels() end end)
    end
end

-- Apply layout/style settings to a test frame (fonts, sizes, textures, borders, etc.)
-- This should be called when visual settings change, not just when data changes.
-- ☠ A THIN FORWARD to DF:ApplyFrameLayout (via the ApplyFrameStyle alias). Do not
-- re-implement frame size, textures, borders or resource-bar layout here: the live
-- function does all of it (pixel-perfect, pinned-width aware), and a copy would run
-- first only to be overwritten.
-- Kept as a named function because call sites pair it with UpdateTestFrame and the
-- pairing reads clearly.
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

-- Engine-side test-mode teardown: the state that is NOT owned by the test frames
-- themselves -- the global aura data provider, and the pinned-frame preview.
--
-- HideTestFrames / HideRaidTestFrames do this inline, but two OTHER paths tear test
-- mode down by clearing DF.testMode / DF.raidTestMode directly: combat entry
-- (Core.lua, PLAYER_REGEN_DISABLED) and zone change (Frames/Headers.lua,
-- PLAYER_ENTERING_WORLD). Skipping this would leave C_UnitAuras on the SAMPLE provider
-- for the rest of the session -- the restore lives only in AuraContainer.SetTestMode's
-- `else` branch. The [combat] state driver shows the LIVE frames the instant combat
-- starts, so they would render fake auras, with the identity gate off, aura row caps
-- stuck at the test slider value and missing-buff badges on corpses. The watchdog
-- cannot recover it either: ensureProviderWatch returns early while
-- _ownsProviderSwitch is set, and only this path clears it.
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

-- ☠ FRAME-SIDE TEST-MODE TEARDOWN — the twin of TeardownTestModeEngines above, and it
-- exists for the same reason: THREE paths end test mode, and only one of them was doing
-- the whole job.
--
--   HideTestFrames / HideRaidTestFrames  — the ordinary exit, did all of it
--   combat entry   (Core.lua, PLAYER_REGEN_DISABLED)   — absorbs + personal targeted only
--   zone change    (Headers.lua, PLAYER_ENTERING_WORLD) — frame:Hide() and nothing else
--
-- ⚠ frame:Hide() IS NOT ENOUGH, which is what made this survivable for so long. The
-- Aura Designer's borders are parented to UIParent, not to the unit frame, so hiding the
-- frame leaves them on screen: zone into a raid with the preview up and the AD indicators
-- stayed floating over live frames until something else happened to clear them. The
-- absorb textures are the same shape (HideTestFrames hides all three by hand), and the
-- pet / personal-targeted / Targeted List previews are separate frame sets that no
-- amount of hiding the party frames reaches.
--
-- Safe in combat, which is why the combat path can call it: ClearFrame only tears down
-- textures and tables, and the test pet frames are deliberately plain Buttons and NOT
-- SecureUnitButtonTemplate (see DF:CreateTestPetFrame) precisely so they can be hidden
-- under lockdown.
--
-- Call it from any new teardown path too — do not hand-copy a subset of it.
function DF:TeardownTestFrameVisuals()
    local ADEngine = DF.AuraDesigner and DF.AuraDesigner.Engine
    local function cleanFrame(frame)
        if not frame then return end
        if ADEngine then ADEngine:ClearFrame(frame) end
        if frame.absorbAttachedTexture then frame.absorbAttachedTexture:Hide() end
        if frame.healAbsorbAttachedTexture then frame.healAbsorbAttachedTexture:Hide() end
        if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
    end

    if DF.testPartyFrames then
        for i = 0, 4 do cleanFrame(DF.testPartyFrames[i]) end
    end
    if DF.testRaidFrames then
        for i = 1, 40 do cleanFrame(DF.testRaidFrames[i]) end
    end
    -- ☠ AND THE PINNED POOLS — the paragraph above is about them too and they were the one
    -- set it never reached. Pinned test frames run the same AD preview, so their indicators
    -- are parented to UIParent by the same mechanism and survive the frame being hidden.
    -- The pools are per-set and sparse, so walk what exists rather than a fixed range.
    if DF.PinnedFrames and DF.PinnedFrames.testFrames then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local pool = DF.PinnedFrames.testFrames[setIndex]
            if pool then
                for _, f in pairs(pool) do cleanFrame(f) end
            end
        end
    end

    if DF.HideAllTestPetFrames then DF:HideAllTestPetFrames() end
    if DF.HideAllTestRaidPetFrames then DF:HideAllTestRaidPetFrames() end
    if DF.HideTestPersonalTargetedSpells then DF:HideTestPersonalTargetedSpells() end
    if DF.HideTestTargetedList then DF:HideTestTargetedList() end
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
    
    -- Labels first: the region registry must be wiped before a pooled frame goes back
    -- to live rendering, or real spell tooltips keep getting "Buff Bar" appended.
    if DF.ClearTestLabels then DF:ClearTestLabels() end

    -- Hide all test party frames
    for i = 0, 4 do
        local frame = DF.testPartyFrames[i]
        if frame then frame:Hide() end
    end

    -- Hide test container
    if DF.testPartyContainer then
        DF.testPartyContainer:Hide()
    end

    -- AD indicators, absorb textures, pet / personal-targeted / Targeted List previews.
    -- Shared with the combat and zone teardowns — see TeardownTestFrameVisuals.
    DF:TeardownTestFrameVisuals()


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
    if DF.UpdateAllMissingBuffIcons then
        C_Timer.After(0.1, function() DF:UpdateAllMissingBuffIcons() end)
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
    if DF.NotifyTestModeChanged then DF:NotifyTestModeChanged("party") end
end

-- Toggle test mode (mode-aware based on GUI.SelectedMode)
function DF:ToggleTestMode()
    -- Cannot toggle test mode during combat (secure frame restrictions)
    if InCombatLockdown() then
        DF:Say(L["Cannot toggle test mode during combat."])
        return
    end

    -- Flip the USER's claim. Unlock holds its own, so this need not refuse while frames
    -- are unlocked: turning the preview off mid-unlock drops your claim, unlock keeps the
    -- frames it still needs to have something to drag, and locking then hides them
    -- because nobody is left asking.
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
    -- ☠ NEW SESSION TOKEN. Test frames are POOLED and their per-frame layout caches
    -- survive a toggle, so a cache that only compares db settings sees "nothing changed"
    -- and short-circuits on the very first pass -- with anchors left over from a layout
    -- that was torn down. That is why absorbs were missing on some units until you
    -- toggled test mode off and on again. Bumping this invalidates those caches once per
    -- session (see AbsorbLayoutStateChanged). Must be set BEFORE any test frame renders.
    DF.testSessionId = (DF.testSessionId or 0) + 1
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
    -- Same next-tick repaint as the party entry (see the note there): freshly created
    -- frames have anchor-derived rects that are 0 for this whole tick, so the first
    -- paint sizes every fill-anchored bar to width 0. Repaint once when rects exist.
    C_Timer.After(0, function()
        if DF.raidTestMode then DF:UpdateRaidTestFrames() end
    end)
    
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

    -- Same confirmation party mode gives.
    if not silent then
        DF:Say(L["Test mode enabled."])
    end
    if DF.NotifyTestModeChanged then DF:NotifyTestModeChanged("raid") end
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
    
    -- Labels first — see the party exit for why the hit areas must go before the
    -- frames return to the pool.
    if DF.ClearTestLabels then DF:ClearTestLabels() end

    -- Hide all test raid frames
    for i = 1, 40 do
        local frame = DF.testRaidFrames[i]
        if frame then frame:Hide() end
    end

    -- Hide test container
    if DF.testRaidContainer then
        DF.testRaidContainer:Hide()
    end

    -- AD indicators, absorb textures, pet / personal-targeted / Targeted List previews.
    -- Shared with the combat and zone teardowns — see TeardownTestFrameVisuals.
    DF:TeardownTestFrameVisuals()

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
    if DF.NotifyTestModeChanged then DF:NotifyTestModeChanged("raid") end
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
    
    -- ☠ PINNED TEST FRAMES FOLLOW RAID SETTINGS CHANGES TOO. This function is the
    -- RAID arm of what DF:RefreshTestFrames does for party — every raid-side test
    -- control lands here (the panel checkboxes, the Quick Presets, the sliders via
    -- ThrottledUpdateRaidTestFrames, and DF:UpdateAll's raid branch) — and it was the
    -- only one of the three refresh entry points that never touched the pinned pools.
    -- So in RAID test mode a pinned set kept whatever it rendered at Test Mode entry:
    -- unticking Show Auras / Missing Buff / Aura Designer emptied the raid grid and
    -- left the pinned preview fully dressed. `true` because this pass applies layout
    -- to each raid frame (ApplyTestFrameLayout above), so the pinned frames get the
    -- same treatment their raid siblings just had.
    if DF.PinnedFrames and DF.PinnedFrames.RefreshTestMode then
        DF.PinnedFrames:RefreshTestMode(true)
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

    -- Indicator Info marks label the rows this pass just rebuilt, so they re-place
    -- LAST and one tick later — same reason and same shape as DF:RefreshTestFrames.
    if DF.UpdateTestLabels then
        C_Timer.After(0, function() if DF.UpdateTestLabels then DF:UpdateTestLabels() end end)
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
    -- ☠ DEBUG-ONLY FLAG. Placement does not read it: the END mirror comes from playerAnchor
    -- itself, in both the snippet and the calculator, which is why the preview matches live
    -- without it. The only reads are the LEAK-TEST print and two params-swap log lines.
    -- Kept because the leak test prints it and is the tripwire for test params reaching
    -- live frames. Safe either way: UpdateRaidGroupLayoutParams replaces the whole table
    -- on its next call, so the flag cannot survive into the live path.
    -- ⚠ Do not build placement behaviour on this. A geometry fork keyed on mode is the
    -- exact thing test-mode parity forbids.
    lp.testMode = true

    -- ☠ (Removed) the [LEAK-TEST] simulate block, which was gated on
    -- DF.debugLeakTestSimulate -- a flag NOTHING writes, in either addon and in no
    -- documented /run toggle, so the branch could not be entered. Its own comment
    -- already called it "redundant since the patch is in place above", and its whole
    -- body was `lp.testMode = true`, which the line above does unconditionally.
    -- (DF.debugLeakTest, used just below, is different: it IS a documented manual
    -- toggle -- see /run DandersFrames.debugLeakTest = true in SecureSort.lua.)
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
            DF:SetPixelPerfectSize(frame, lp.frameWidth, lp.frameHeight, db)
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
    
    -- ☠ ONE PRODUCER. This was a third hand-rolled copy of the ordering and it was the
    -- weakest: it read raidGroupDisplayOrder raw, so it ignored My Group First entirely
    -- and skipped the per-entry validation, meaning the PREVIEW showed a different group
    -- order from live whenever My Group First was on. Invisible solo, because
    -- DF.cachedPlayerGroup is nil there. Use the shared helper the live paths use.
    DF:SortActiveGroupListByDisplayOrder(activeGroupList, db)
    
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
    -- three positions read the same geometry live does.
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
        -- ⚠ lp is nil only if UpdateRaidLayoutParams bailed on a missing raid db, in
        -- which case there is nothing to lay out.
        local lp = SecureSort.raidLayoutParams
        if not lp then return end
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
                DF:SetPixelPerfectSize(frame, lp.frameWidth, lp.frameHeight, db)
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
                DF:SetPixelPerfectSize(frame, lp.frameWidth, lp.frameHeight, db)
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
-- automatically ON in Full, which is built from the key list. That is what makes
-- "Full" full and "Static" a reproducible baseline.
--
-- Sliders are deliberately NOT touched: they're a working preference, not part of a
-- preset's visual identity.
--
-- ☠ ONE EXCEPTION — `testDefensiveCount`. It is a count, but it is also the defensive
-- row's ONLY on/off, so a preset has to be able to turn that row on or off. It is
-- declared in TEST_TOGGLE_KEYS like any toggle and listed `= true` in the presets that
-- want it; the apply/match helpers translate that to 1 / 0. The frame, buff and debuff
-- counts stay untouched — they only change HOW MUCH of a row shows, never whether it does.

local TEST_TOGGLE_KEYS = {
    -- General
    "testShowPets", "testAnimateHealth",
    -- Bars & Overlays
    "testShowAbsorbs", "testShowHealPrediction", "testShowOutOfRange",
    "testShowReducedMaxHealth", "testShowTextDesigner",
    -- Auras
    "testShowAuras", "testShowDispelGlow", "testShowMissingBuff", "testShowAuraDesigner",
    -- Indicators & Icons
    -- ⚠ `testShowExternalDef` is gone; `testDefensiveCount` replaced it. It lives in this
    -- list because it is the defensive row's on/off, but it is COUNT-shaped — see
    -- TEST_COUNT_KEYS below, which is what makes `= true` in a preset mean 1.
    "testDefensiveCount",
    "testShowTargetedList", "testAnimateTargetedList",
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
        -- Count-shaped (written as 1, see TEST_COUNT_KEYS): the defensive icon IS an
        -- aura surface, and a preset that omits a key zeroes it.
        testDefensiveCount       = true,
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
        -- The defensive icon, as this preset's comment promises. Count-shaped, so this
        -- `true` is written as 1 — see TEST_COUNT_KEYS. It is the only preset besides
        -- Full that turns the defensive row on, which is how it worked when this was
        -- the testShowExternalDef checkbox.
        testDefensiveCount       = true,
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
-- exactly that reason and was unusable.
-- ⚠ Config.lua's test-mode defaults MIRROR THIS TABLE. Change one, change both.
TEST_PRESETS.DEFAULT = {
    testShowPets             = true,
    testShowOutOfRange       = true,
    testShowTextDesigner     = true,
    testShowTargetedList     = true,
    testAnimateTargetedList  = true,
    testShowPersonalTargeted = true,
    -- ☠ Count-shaped, so this `true` is written as 1 (see TEST_COUNT_KEYS). Present because
    -- Config.lua's testDefensiveCount now defaults to 1 and the two MUST mirror — and
    -- because a preset that omits a key ZEROES it, so without this the three presets that
    -- left it out re-zeroed the row on every click. That is how the defensive preview came
    -- to look as though it never worked at all (Aphoex 6).
    testDefensiveCount       = true,
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

-- ☠ COUNT-SHAPED TOGGLE KEYS. These live in TEST_TOGGLE_KEYS and are written `= true` in
-- a preset like any other, but they store a NUMBER: >0 is on, 0 is off. `testDefensiveCount`
-- is one because it is simultaneously the defensive row's on/off and how many icons it
-- previews — one control, two jobs.
-- Anything added here must read as off at 0 and on above it, or the matcher will lie.
local TEST_COUNT_KEYS = {
    testDefensiveCount = true,
}

local function TestToggleOn(db, key)
    local v = db[key]
    if TEST_COUNT_KEYS[key] then
        -- nil means the profile predates the key. Off, matching the checkbox this
        -- replaced (testShowExternalDef defaulted to false).
        return (tonumber(v) or 0) > 0
    end
    if v == nil then return TEST_TOGGLE_DEFAULT_ON[key] == true end
    return v == true
end

-- Which preset, if any, the CURRENT toggles actually describe -- nil when they describe
-- none of them.
--
-- ☠ DERIVED, NEVER READ FROM db.testPreset. That key records the last preset CLICKED, which
-- stops being true the moment any toggle is flipped afterwards. A preset button is a claim
-- about state, so it has to be answered from state. db.testPreset is still written by
-- ApplyTestPreset -- it is a useful record of intent -- but nothing may drive UI from it.
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
            if TEST_COUNT_KEYS[key] then
                -- Count-shaped: a preset says on/off, so write 1 or 0. ⚠ Turning one ON
                -- resets it to 1 rather than restoring whatever the user had dialled in —
                -- deliberate, and the same promise every other preset key makes: a preset
                -- is a reproducible state, not a partial merge.
                db[key] = (set[key] == true) and 1 or 0
            else
                db[key] = set[key] == true
            end
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
        -- ⚠ _Now, not the arm-stub: RefreshAllTestSurfaces below repaints the
        -- surfaces this pass rebuilds, so the layout pass has to be finished
        -- first. A one-frame deferral would invert the two.
        DF:UpdateAllFrames_Now()
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

    -- Missing raid-buff icons are off on WoW Forever (see DF:UseFactoryForMissingBuff),
    -- so test mode must not preview a feature that never draws there.
    if DF.IS_FOREVER then
        if frame.missingBuffStrip and frame.dfMissingStripShown ~= false then
            frame.dfMissingStripShown = false
            frame.missingBuffStrip:Hide()
        end
        return
    end

    local db = DF:GetFrameDB(frame)

    -- 12.1: the live missing-buff display is the factory badge STRIP (one badge
    -- per tracked buff, real spell icons — Auras.lua) — preview through the same
    -- drive so geometry and styling are live-true. Every badge renders "missing"
    -- because the provider bounce leaves missing containers DISABLED for the
    -- test session (empty groups park the badges in their windows); the drive's
    -- unit guards are test-bypassed (fabricated units fail every unit API).
    if DF.FactoryOwnsMissingBuff and DF:FactoryOwnsMissingBuff(db) then
        -- Dead unit, or a unit that opts out (dfTestShowMissingBuff == false): park the
        -- strip the same way the toggle-off path does, so re-showing goes back through
        -- the live drive. ⚠ `== false` deliberately, not `not x` — nil means "show",
        -- which is the default for every unit that does not opt out.
        if DF:IsTestFrameDead(frame) or frame.dfTestShowMissingBuff == false then
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
-- UpdateAllTestAuraDesigner: the "refresh every test frame" entry point for the buff
-- and debuff rows. Without it a slider drag re-drives the LIVE frames and leaves the
-- preview stale. The per-frame drive (UpdateTestAuras) already reads every setting;
-- this is only the loop over the frames.
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

-- Test defensive preview: drive the real 12.1 defensive container.
function DF:UpdateTestDefensiveBar(frame, testData)
    if not frame then return end

    local db = DF:GetFrameDB(frame)

    -- 12.1: the live defensive row is a container (DriveDefensiveFactory) —
    -- preview through the SAME container (P5 hybrid) so styling, layout and
    -- fonts are live-true.
    if DF.FactoryOwnsDefensiveRow and DF:FactoryOwnsDefensiveRow(db) then
        local role = testData and testData.role
        -- The COUNT is the on/off: 0 hides the row outright — same rule as the buff and
        -- debuff rows, and the same reason (testSlotCount floors at 1, so a 0 reaching
        -- the drive would draw one icon). There is no separate test toggle any more.
        -- Per-unit override first, the role rule as the fallback. testData wins when it
        -- is present (both callers pass it); the frame stamp covers any path that does
        -- not. See the stamps in UpdateTestFrame.
        local wantDef = testData and testData.showDefensive
        if wantDef == nil then wantDef = frame.dfTestShowDefensive end
        if wantDef == nil then wantDef = (role == "TANK" or role == "HEALER") end
        local show = db.defensiveIconEnabled
            and (db.testDefensiveCount or 0) > 0
            and wantDef
            and not DF:IsTestFrameDead(frame)
        if show then
            DF:DriveDefensiveFactory(frame, db)
            local h = frame.defensiveFactory
            if h then
                -- ☠ ONE SOURCE FOR THE PREVIEW COUNT: `testDefensiveCount` (its own panel slider,
                -- default 1). A second value here would fight BuildDefensiveRowConfig's testMax, and
                -- since SetTestMax rebuilds on any change, every defensive tweak would pay an extra
                -- container rebuild. This line and BuildDefensiveRowConfig in Features/Auras.lua are the
                -- two writers -- keep them in step.
                -- ⚠ Still clamped by `defensiveBarMax`: the slider goes to 5 and the row's own cap can
                -- be lower, in which case the row honours its own Max Icons.
                if h.SetTestMax then
                    h:SetTestMax(math.min(db.testDefensiveCount or 0, db.defensiveBarMax or 4))
                end
                if frame.dfDefFactoryShown ~= true then
                    frame.dfDefFactoryShown = true
                    h:SetIntentShown(true)
                end
            end
        elseif frame.defensiveFactory then
            -- Hide via the shown-cache the live drive keys on, so exiting test
            -- mode (or re-ticking the toggle) re-shows through the normal path.
            if frame.dfDefFactoryShown ~= false then
                frame.dfDefFactoryShown = false
                frame.defensiveFactory:SetIntentShown(false)
            end
        end
        return
    end

end

function DF:UpdateAllTestDefensiveBar()
    local function UpdateFrame(frame, testData)
        if not frame then return end
        local db = DF:GetFrameDB(frame)

        -- Unconditional: the painter decides for itself and hides the container row
        -- when the count is 0 or the feature is off.
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
    -- ☠ AND TEST MODE MUST ACTUALLY BE ON. This gate checked testShowTargetedList and
    -- targetedListEnabled but never DF.testMode — and testShowTargetedList DEFAULTS TRUE.
    -- So ticking the feature's own Enable on the Indicators page called straight through
    -- and showed the demo list on screen with test mode off entirely; it then stayed up,
    -- because the only routes to HideTestTargetedList are this else-branch (which needs
    -- the feature turned back off) and the main test-mode teardown.
    -- ⚠ A "show X in test mode" flag is a filter on test mode, never a trigger for it.
    if DF.testMode and not DF.raidTestMode
        and db and db.testShowTargetedList and db.targetedListEnabled and DF.ShowTestTargetedList then
        DF:ShowTestTargetedList()
    elseif DF.HideTestTargetedList then
        DF:HideTestTargetedList()
    end
end

-- ⚠ Despite the name this is NOT group-only, which is why it survives the removal
-- of the group-frame Targeted Spells display. It also drives the PERSONAL preview
-- and the Targeted List demo bars.
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

        -- Show personal targeted spells in raid test mode. Personal Targeted is a
        -- player-screen overlay with PER-MODE settings, so the raid preview must gate on
        -- the RAID profile.
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

-- ============================================================
-- TEST PANEL WIDGET KIT (legacy)
-- ⚠ The party / raid test popup below no longer uses this: it is built from
-- the mode registry and DandersUI's row list. Kept, behaviour unchanged, for
-- panels still built on it; new work should register a test mode instead
-- (DandersFrames/TestMode/Modes.lua).
--
-- Themed checkbox (two to a row, its label optionally a link to a settings
-- page), mini slider, collapsible section with a count badge. The panel
-- supplies where a checkbox writes and what follows a write:
--   opts.contentWidth        the panel's content width
--   opts.themeColor()        -> { r, g, b } accent for checks, sliders, badges
--   opts.getDB()             -> the table a checkbox writes its key into
--   opts.callbackArg()       optional: second argument to a checkbox's callback
--   opts.afterToggle(cb)     optional: after the write and the callback
--   opts.saveSection(key, expanded)  optional: a section folded / unfolded
--   opts.relayout()          optional: ...and the panel re-lays itself out
-- Returns { Checkbox = fn, Slider = fn, Section = fn, sections = { ... } } with
-- the signatures the old party / raid panel used:
--   Checkbox(parent, text, dbKey, callback, pageId, setValue)
--   Slider(parent, width, min, max, step)
--   Section(parentFrame, title, sectionKey)  -- :AddCheckbox / :AddWidget / ...
-- ============================================================
function DF:CreateTestPanelKit(opts)
    local kit = { sections = {} }
    local GUIColors  = DF.GUI.Colors
    local C_PANEL    = GUIColors.panel
    local C_ELEMENT  = GUIColors.element
    local C_BORDER   = GUIColors.border
    local C_HOVER    = GUIColors.hover
    local C_TEXT     = GUIColors.text
    local C_TEXT_DIM = GUIColors.textDim
    local CONTENT_WIDTH = opts.contentWidth
    local GetThemeColor = opts.themeColor

    -- ============================================================
    -- THEMED CHECKBOX HELPER
    -- ============================================================
    -- `setValue` (optional): overrides the plain `db[dbKey] = checked` write for a key
    -- whose stored shape is not a boolean. Only the Defensives box uses it -- that key
    -- is a COUNT, where 0 means off (see TEST_COUNT_KEYS), so writing `false` into it
    -- would put a boolean where every reader expects a number.
    -- ⚠ The box still owns exactly ONE db key either way. This is a different WRITE for
    -- the same value, not a second value; the moment a checkbox gets its own storage
    -- beside a slider, the two can disagree and the display starts lying.
    local function CreateThemedCheckbox(parent, text, dbKey, callback, pageId, setValue)
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
                self.arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b,
                    enabled and 0.9 or 0.35)
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
            -- ☠ A TEXTURE, NOT A TEXT GLYPH -- Media\Icons\chevron_right, the same icon the Aura
            -- Designer card headers and this panel's section headers use. A "›" glyph in the small
            -- font is nearly invisible, and `DFFontHighlightSmall` is not known to cover U+203A
            -- (AutoProfiles.lua records it missing "→"); a missing glyph renders as nothing.
            -- The icons are white masks, so vertex colour tints them exactly as SetTextColor
            -- would; every recolour site below uses SetVertexColor.
            --
            -- ⚠ 8, NOT 10. What tips the weight is the REPETITION — the section header carries one
            -- 12px chevron, a section body carries five of these, so the same per-icon weight reads
            -- far heavier in the list. 8 sits below the label's cap height, so it reads as a hint
            -- rather than a peer, while staying in the section chevrons' tonal family. Change size
            -- OR colour, not both at once.
            local arrow = labelBtn:CreateTexture(nil, "OVERLAY")
            arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right.png")
            arrow:SetSize(8, 8)
            arrow:SetPoint("LEFT", labelText, "RIGHT", 2, 0)
            arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.9)
            labelBtn:SetWidth(labelText:GetStringWidth() + 14)
            -- Every handler bails when the toggle is greyed: EnableMouse(false)
            -- should already stop them, but a disable applied while the cursor is
            -- inside would otherwise never fire OnLeave and leave the label lit.
            labelBtn:SetScript("OnEnter", function(self)
                if container.dfDisabled then return end
                labelText:SetTextColor(1, 0.82, 0)
                arrow:SetVertexColor(1, 0.82, 0, 1)
                -- ☠ THE STANDARD DF SHAPE IS "label as TITLE, explanation as a BODY
                -- line" — that is what GUI:AttachTooltip produces for every settings
                -- widget (ResolveTooltipSpec defaults the title to the control's label
                -- and puts the caller's string in `lines`). This passed the hint as the
                -- TITLE with no body, so it rendered as one large white header with
                -- nothing under it, which reads as a stray game tooltip rather than one
                -- of ours.
                -- ⚠ Still hand-rolled rather than converted to GUI:AttachTooltip: that
                -- helper builds its own mouse-enabled hit frame OVER the label, and this
                -- label is a Button you click to open the page — the hit frame would
                -- swallow the click. The shared ShowTooltip/HideTooltip primitives are
                -- the part that has to be common, and they are.
                DF.GUI:ShowTooltip(self, {
                    title = text,
                    lines = { L["Click to open settings"] },
                })
            end)
            labelBtn:SetScript("OnLeave", function(self)
                DF.GUI:HideTooltip()
                if container.dfDisabled then
                    labelText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.35)
                    return
                end
                labelText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.9)
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
            local db = opts.getDB()
            if setValue then
                setValue(db, container.checked)
            elseif db then
                db[dbKey] = container.checked
            end
            if callback then callback(container.checked, opts.callbackArg and opts.callbackArg()) end
            if opts.afterToggle then opts.afterToggle(container) end
            -- Update badge on parent section
            if container.section and container.section.UpdateBadge then
                container.section:UpdateBadge()
            end
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
    local allSections = kit.sections

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
        chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right.png")
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

        section.AddCheckbox = function(self, text, dbKey, callback, pageId, setValue)
            local cb = CreateThemedCheckbox(content, text, dbKey, callback, pageId, setValue)
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
                self.chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more.png")
                self.content:Show()
            else
                self.chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right.png")
                self.content:Hide()
            end
        end

        section.Toggle = function(self)
            self:SetExpanded(not self.expanded)
            -- Save collapsed state (the panel's own store)
            if self.sectionKey and opts.saveSection then opts.saveSection(self.sectionKey, self.expanded) end
            if opts.relayout then opts.relayout() end
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

    kit.Checkbox = CreateThemedCheckbox
    kit.Slider = CreateThemedSlider
    kit.Section = CreateSection
    return kit
end

-- ============================================================
-- TEST MODE POPUP
-- The floating test panel: a slim popout with an icon rail down its left edge
-- and the active section's settings beside it.
--
--   rail     the MODES at the top (Party, Raid, any registered mode), filled
--            with the mode's accent while active; a hairline; then the active
--            mode's SECTIONS, the current one marked with the accent bar
--   header   the section's title, the preview on/off and the close X
--   chips    the active mode's presets; the chip the current toggles match
--            is lit (derived from state, never from the last click)
--   list     the section's settings, one compact row each (DandersUI's row
--            list); it scrolls once it is taller than the room the rail leaves
--
-- Every mode comes through the registry in DandersFrames/TestMode/Modes.lua
-- (DF:RegisterTestMode) -- Party and Raid register at the bottom of this file.
-- The popup only draws and routes: what a mode stores, what a write sets off
-- and what entering or leaving it means are the mode's own.
--
-- Kept from the old panel: DF.TestPanel / DF:CreateTestPanel /
-- DF:ToggleTestPanel, panel:UpdateState() / UpdateStateNoCallback(), the
-- global frame name (Escape closes it, Edit Mode closes it), the drag, and the
-- rule that closing it releases the user's preview claim.
-- The last section is remembered per mode (account window state, testPopup).
-- ============================================================

local POPUP_WIDTH  = 272
local RAIL_WIDTH   = 52
local PANE_PAD     = 8
local HEADER_H     = 30   -- the title row, measured from the popup's top edge
local CHIP_H       = 18
local CHIP_GAP     = 4
local MIN_HEIGHT   = 200
local TEST_ICONS   = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"

-- A mode's callbacks can come from another addon: an error in one is reported
-- through the normal handler and the popup carries on.
local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        if geterrorhandler then geterrorhandler()(a) end
        return nil
    end
    return a, b, c
end

local function ResolveValue(v)
    if type(v) == "function" then return (SafeCall(v)) end
    return v
end

-- Where the popup keeps what it remembers: the last mode and each mode's last
-- section. UI state, not profile content -- the settings window's own place
-- lives in the same table.
local function PopupMemory()
    local ws = DF.GetWindowState and DF:GetWindowState()
    if type(ws) ~= "table" then
        DF._testPopupMemory = DF._testPopupMemory or {}
        ws = { testPopup = DF._testPopupMemory }
    end
    if type(ws.testPopup) ~= "table" then ws.testPopup = {} end
    if type(ws.testPopup.sections) ~= "table" then ws.testPopup.sections = {} end
    return ws.testPopup
end

-- A row label that opens a DandersFrames settings page:
--   spec.link, spec.linkHint = DandersFrames:TestModeSettingsLink("bars_absorb")
function DF:TestModeSettingsLink(pageId)
    local function open()
        local GUI = DF.GUI
        if not (GUI and GUI.SelectTab) then return end
        if not DF.GUIFrame then
            if DF.ToggleGUI then DF:ToggleGUI() end
        elseif not DF.GUIFrame:IsShown() then
            DF.GUIFrame:Show()
        end
        GUI.SelectTab(pageId)
    end
    return open, L["Click to open settings"]
end

function DF:CreateTestPanel()
    if DF.TestPanel then return DF.TestPanel end

    local GUI = DF.GUI
    local C_BG, C_PANEL, C_BORDER = GUI.Colors.background, GUI.Colors.panel, GUI.Colors.border
    local C_TEXT, C_TEXT_DIM = GUI.Colors.text, GUI.Colors.textDim

    -- ============================================================
    -- FRAME
    -- ============================================================
    local panel = CreateFrame("Frame", "DandersFramesTestPanel", UIParent, "BackdropTemplate")
    panel:SetSize(POPUP_WIDTH, 320)
    panel:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:SetFrameLevel(100)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    GUI:CreatePanelBackdrop(panel, { bgAlpha = C_BG.a, borderColor = { r = 0, g = 0, b = 0, a = 1 } })
    panel:Hide()
    tinsert(UISpecialFrames, "DandersFramesTestPanel")

    -- modeId / sectionId: what is on screen. builtFor: the mode|section the
    -- list was last built for (a rebuild only when it changes). entered: the
    -- current mode has had its onEnter for this opening. switching: a switch
    -- is running its mode callbacks, so a re-entrant refresh must not re-decide
    -- the mode underneath it.
    local state = { modeId = nil, sectionId = nil, builtFor = nil, entered = false, switching = false }
    panel.state = state

    local function CurrentMode() return state.modeId and DF:GetTestMode(state.modeId) or nil end

    local function ModeAccent(def)
        local c = def and ResolveValue(def.accent)
        if type(c) ~= "table" then c = GUI:GetAccent() end
        return c
    end

    -- ============================================================
    -- RAIL -- the settings window's own rail widget, at a compact size
    -- ============================================================
    local rail = GUI:CreateIconRail(panel, {
        width = RAIL_WIDTH, itemHeight = 40, iconSize = 16, iconTop = 6,
        labelGap = 3, labelInset = 1, spacing = 1, paddingTop = 6, paddingBottom = 6,
        onSelect = function(id) panel:OnRailPick(id) end,
    })
    rail:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
    rail:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 1, 1)
    local railBg = rail:CreateTexture(nil, "BACKGROUND", nil, -1)
    railBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    railBg:SetAllPoints(rail)
    railBg:SetVertexColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.35)
    local railEdge = rail:CreateTexture(nil, "BORDER")
    railEdge:SetTexture("Interface\\Buttons\\WHITE8x8")
    railEdge:SetPoint("TOPRIGHT", rail, "TOPRIGHT", 0, 0)
    railEdge:SetPoint("BOTTOMRIGHT", rail, "BOTTOMRIGHT", 0, 0)
    railEdge:SetWidth(1)
    railEdge:SetVertexColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.6)
    -- The rail's gaps move the popup, like the rest of its chrome.
    rail:EnableMouse(true)
    rail:RegisterForDrag("LeftButton")
    rail:SetScript("OnDragStart", function() panel:StartMoving() end)
    rail:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)
    panel.rail = rail

    local paneX = RAIL_WIDTH + 1 + PANE_PAD
    local contentW = POPUP_WIDTH - paneX - PANE_PAD - 1

    -- ============================================================
    -- HEADER -- section title, preview on/off, close
    -- ============================================================
    local closeBtn = GUI:CreateCloseButton(panel, {
        size = 18,
        onClick = function() panel:Hide() end,
    })
    closeBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)
    panel.closeBtn = closeBtn

    local previewBtn = GUI:CreateGlyphButton(panel, {
        size = 18, iconSize = 14,
        texture = TEST_ICONS .. "preview.png",
        tooltip = function()
            local def = CurrentMode()
            local on = def and def.isPreviewOn and SafeCall(def.isPreviewOn)
            return { title = on and L["Disable Test Mode"] or L["Enable Test Mode"] }
        end,
        onClick = function() panel:TogglePreview() end,
    })
    previewBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    panel.previewBtn = previewBtn

    local title = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", paneX, -10)
    title:SetPoint("RIGHT", previewBtn, "LEFT", -6, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    panel.title = title

    -- ============================================================
    -- PRESET CHIPS
    -- ============================================================
    local chips = CreateFrame("Frame", nil, panel)
    chips:SetPoint("TOPLEFT", panel, "TOPLEFT", paneX, -HEADER_H)
    chips:SetSize(contentW, 1)
    local chipPool, chipCount, chipsHeight = {}, 0, 0
    panel.chips = chipPool

    -- ============================================================
    -- THE LIST -- DandersUI's row list, bound to the current mode's store
    -- ============================================================
    local list = GUI:CreateRowList(panel, {
        width = contentW,
        store = function()
            local def = CurrentMode()
            return def and ResolveValue(def.store) or nil
        end,
        accent = function() return ModeAccent(CurrentMode()) end,
        onWrite = function(spec, value)
            local def = CurrentMode()
            if def and def.onChanged then SafeCall(def.onChanged, spec.key, value, spec) end
            -- A toggle can make the lit preset wrong, or another one right.
            panel:RefreshPresetHighlight()
        end,
    })
    panel.list = list

    -- ============================================================
    -- MODE / SECTION RESOLUTION
    -- ============================================================
    -- Does this mode agree it is the current one? A mode with no isCurrent
    -- never objects (it is current while the user keeps it picked).
    local function ReportsCurrent(def)
        if not def.isCurrent then return true end
        return SafeCall(def.isCurrent) and true or false
    end

    -- Which mode the popup should show:
    --   1. the one on screen, while it still agrees (a mode that SAYS it is
    --      current stays even when unavailable: it is what the settings show)
    --   2. on a fresh open, the one picked last time, if it agrees
    --   3. the first mode that says it is current
    --   4. the first available mode
    function panel:ResolveMode()
        local cur = CurrentMode()
        if cur and ReportsCurrent(cur) and (cur.isCurrent or DF:IsTestModeAvailable(cur.id)) then
            return cur.id
        end
        local modes = DF:GetTestModeList()
        if not cur then
            local remembered = DF:GetTestMode(PopupMemory().mode or "")
            if remembered and DF:IsTestModeAvailable(remembered.id) and ReportsCurrent(remembered) then
                return remembered.id
            end
        end
        for _, def in ipairs(modes) do
            if def.isCurrent and ReportsCurrent(def) then return def.id end
        end
        for _, def in ipairs(modes) do
            if DF:IsTestModeAvailable(def.id) then return def.id end
        end
        if cur then return cur.id end
        return modes[1] and modes[1].id or nil
    end

    -- The section to show for a mode: the one on screen, else the one
    -- remembered for that mode, else its first.
    local function ResolveSection(modeId)
        local secs = DF:GetTestModeSections(modeId)
        local want = state.sectionId or PopupMemory().sections[modeId]
        for _, sec in ipairs(secs) do
            if sec.id == want then return sec end
        end
        return secs[1]
    end
    panel.ResolveSection = function(_, modeId) return ResolveSection(modeId) end

    -- ============================================================
    -- BUILD
    -- ============================================================
    local function RailItems()
        local items = {}
        local modes = DF:GetTestModeList()
        for i, def in ipairs(modes) do
            items[#items + 1] = {
                id = "mode:" .. def.id, icon = def.icon, label = def.label, slot = "top",
                accent = function() return ModeAccent(def) end,
                tooltip = function()
                    local name = ResolveValue(def.title) or ResolveValue(def.label)
                    local ok, why, lines = DF:IsTestModeAvailable(def.id)
                    if ok then return { title = name } end
                    local body = {}
                    if why then body[#body + 1] = why end
                    for _, line in ipairs(type(lines) == "table" and lines or {}) do body[#body + 1] = line end
                    return { title = name, lines = body }
                end,
                dividerAfter = (i == #modes),
            }
        end
        local cur = CurrentMode()
        if cur then
            for _, sec in ipairs(DF:GetTestModeSections(cur.id)) do
                items[#items + 1] = {
                    id = "sec:" .. sec.id, icon = sec.icon, label = sec.label, slot = "top",
                    tooltip = sec.title or sec.label,
                    accent = function() return ModeAccent(CurrentMode()) end,
                }
            end
        end
        return items
    end

    local function PaintRailModes()
        for _, def in ipairs(DF:GetTestModeList()) do
            local id = "mode:" .. def.id
            local isCur = def.id == state.modeId
            rail:SetFilled(id, isCur)
            -- The current mode stays live even if it went unavailable: greying
            -- the thing on screen would leave nothing to click away from.
            rail:SetDisabled(id, (not isCur) and not DF:IsTestModeAvailable(def.id))
        end
    end

    -- Lay the chips out left to right, wrapping when a row is full.
    function panel:LayoutChips()
        local x, y = 0, 0
        for i = 1, chipCount do
            local btn = chipPool[i]
            local w = math.max(28, math.ceil((btn.Text:GetStringWidth() or 0) + 12))
            btn:SetWidth(w)
            if x > 0 and x + w > contentW then
                x = 0
                y = y + CHIP_H + CHIP_GAP
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", chips, "TOPLEFT", x, -y)
            x = x + w + CHIP_GAP
        end
        chipsHeight = chipCount > 0 and (y + CHIP_H) or 0
        chips:SetHeight(math.max(chipsHeight, 1))
    end

    function panel:BuildChips()
        local def = CurrentMode()
        local presets = def and ResolveValue(def.presets)
        chipCount = 0
        for i, preset in ipairs(type(presets) == "table" and presets or {}) do
            local btn = chipPool[i]
            if not btn then
                btn = CreateFrame("Button", nil, chips, "BackdropTemplate")
                -- fitText off: LayoutChips sizes every chip to its label itself.
                GUI:StyleButton(btn, { height = CHIP_H, text = "", font = "DFFontHighlightSmall", fitText = false })
                btn:SetScript("OnClick", function(self) panel:ApplyPreset(self.presetId) end)
                chipPool[i] = btn
            end
            btn.presetId = preset.id
            btn.Text:SetText(ResolveValue(preset.label) or tostring(preset.id))
            btn:Show()
            chipCount = i
        end
        for i = chipCount + 1, #chipPool do chipPool[i]:Hide() end
        self:LayoutChips()
    end

    -- Height: the rail's own, so the list is what scrolls, never the popup.
    function panel:Relayout()
        local h = math.max(math.ceil(rail:GetContentHeight()) + 2, MIN_HEIGHT)
        local top = HEADER_H + chipsHeight + (chipsHeight > 0 and 8 or 0)
        list:ClearAllPoints()
        list:SetPoint("TOPLEFT", panel, "TOPLEFT", paneX, -top)
        list:SetMaxHeight(math.max(h - top - PANE_PAD, 40))
        self:SetHeight(h)
    end

    function panel:RefreshPresetHighlight()
        local def = CurrentMode()
        local active = def and def.activePreset and SafeCall(def.activePreset)
        local c = ModeAccent(def)
        for i = 1, chipCount do
            local btn = chipPool[i]
            local isActive = active ~= nil and btn.presetId == active
            -- The hover wash is only re-tinted by ApplyThemeColor; a mode switch
            -- changes the accent under it.
            if btn.ApplyThemeColor then btn.ApplyThemeColor(c) end
            btn:SetActive(isActive)
            if isActive then
                btn.Text:SetTextColor(c.r, c.g, c.b)
            else
                btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end
        end
    end

    function panel:RefreshHeader(sec)
        local def = CurrentMode()
        sec = sec or (def and ResolveSection(def.id))
        title:SetText(sec and (ResolveValue(sec.title) or ResolveValue(sec.label)) or L["Test Mode"])
        local c = ModeAccent(def)
        title:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        if def and def.isPreviewOn then
            local on = SafeCall(def.isPreviewOn) and true or false
            previewBtn:SetGlyph(TEST_ICONS .. (on and "preview.png" or "preview_off.png"),
                on and c or C_TEXT_DIM)
            previewBtn:Show()
        else
            previewBtn:Hide()
        end
    end

    -- Everything for the current mode and section, from scratch.
    function panel:Rebuild()
        local def = CurrentMode()
        rail:SetItems(RailItems())
        PaintRailModes()
        local sec = def and ResolveSection(def.id) or nil
        state.sectionId = sec and sec.id or nil
        rail:Select(sec and ("sec:" .. sec.id) or nil, true)
        self:BuildChips()
        list:Clear()
        if sec then SafeCall(sec.build, list, def) end
        self:Relayout()
        list:Refresh()
        self:RefreshHeader(sec)
        self:RefreshPresetHighlight()
        state.builtFor = (state.modeId or "") .. "|" .. (state.sectionId or "")
        -- Chip widths read the font, which can measure 0 on the frame it was
        -- set; settle them on the next one.
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if panel:IsShown() then panel:LayoutChips(); panel:Relayout() end
            end)
        end
    end

    -- Values, greys, accents -- no rebuild.
    function panel:RefreshView()
        PaintRailModes()
        rail:Refresh(true)
        list:Refresh()
        self:RefreshHeader()
        self:RefreshPresetHighlight()
    end

    -- ============================================================
    -- SWITCHING
    -- ============================================================
    -- Run the leave / enter pair for a mode change. Re-entrant refreshes (a
    -- mode's onEnter can switch the settings window, which refreshes this
    -- popup) see `switching` and leave the mode alone.
    local function RunSwitch(fromDef, fromId, toId)
        state.switching = true
        if fromDef then SafeCall(fromDef.onExit, toId) end
        local toDef = toId and DF:GetTestMode(toId)
        if toDef then SafeCall(toDef.onEnter, fromId) end
        state.switching = false
    end

    function panel:SelectMode(id)
        if id == state.modeId or not DF:GetTestMode(id) then return end
        if not DF:IsTestModeAvailable(id) then return end
        local fromId, fromDef = state.modeId, CurrentMode()
        state.modeId, state.sectionId = id, nil
        PopupMemory().mode = id
        if state.entered then RunSwitch(fromDef, fromId, id) end
        self:UpdateState()
    end

    function panel:SelectSection(id)
        if id == state.sectionId then return end
        state.sectionId = id
        if state.modeId then PopupMemory().sections[state.modeId] = id end
        self:UpdateState()
    end

    function panel:OnRailPick(id)
        local kind, key = tostring(id):match("^(%a+):(.+)$")
        if kind == "mode" then
            self:SelectMode(key)
        elseif kind == "sec" then
            self:SelectSection(key)
        end
    end

    function panel:ApplyPreset(presetId)
        local def = CurrentMode()
        if not (def and def.applyPreset) then return end
        SafeCall(def.applyPreset, presetId)
        self:UpdateState()
    end

    -- The header's preview toggle. Turning the preview OFF closes the popup:
    -- an open popup means "show me a preview" (the toolbar's Test button does
    -- the same thing from the other side).
    function panel:TogglePreview()
        local def = CurrentMode()
        if not (def and def.togglePreview) then return end
        SafeCall(def.togglePreview)
        if def.isPreviewOn and not SafeCall(def.isPreviewOn) then
            self:Hide()
        else
            self:UpdateState()
        end
    end

    -- The popup was opened by the user: the current mode is entered.
    function panel:EnterCurrentMode()
        if state.entered then return end
        state.entered = true
        local def = CurrentMode()
        if def then
            state.switching = true
            SafeCall(def.onEnter, nil)
            state.switching = false
        end
    end

    -- ============================================================
    -- UPDATE STATE
    -- ============================================================
    local function UpdateStateInternal(self, callbackEnabled)
        if not state.switching then
            local want = self:ResolveMode()
            if want ~= state.modeId then
                -- Following a change made elsewhere (the settings window's
                -- Party / Raid): the same leave / enter a click would run.
                local fromId, fromDef = state.modeId, CurrentMode()
                state.modeId, state.sectionId = want, nil
                if want then PopupMemory().mode = want end
                if state.entered then RunSwitch(fromDef, fromId, want) end
            end
        end
        local def = CurrentMode()
        local sec = def and ResolveSection(def.id)
        local key = (state.modeId or "") .. "|" .. (sec and sec.id or "")
        if key ~= state.builtFor then
            self:Rebuild()
        else
            self:RefreshView()
        end
        if callbackEnabled and GUI.UpdateTestButtonState then
            GUI.UpdateTestButtonState()
        end
    end

    function panel:UpdateState()
        UpdateStateInternal(self, true)
    end

    function panel:UpdateStateNoCallback()
        UpdateStateInternal(self, false)
    end

    -- A mode registered or removed while the popup exists: rebuild on the
    -- next look (now, if it is open).
    DF:OnTestModesChanged(function()
        state.builtFor = nil
        if panel:IsShown() then panel:UpdateStateNoCallback() end
    end)

    -- ============================================================
    -- SHOW / HIDE
    -- ============================================================
    panel:SetScript("OnShow", function(self)
        self:SetScale(DF:GetWindowState().scale or 1.0)
        self:UpdateState()
    end)

    panel:SetScript("OnHide", function()
        -- Leaving: the current mode's onExit(nil), then the user's claim on
        -- both group scopes is dropped -- and only that; closing must not hide
        -- frames itself. Unlock's own claim decides whether they stay up, and
        -- the later lock takes them down.
        local def = CurrentMode()
        if state.entered and def then
            state.switching = true
            SafeCall(def.onExit, nil)
            state.switching = false
        end
        state.entered = false
        state.modeId, state.sectionId, state.builtFor = nil, nil, nil
        DF:SetTestModeOwner("party", "user", false)
        DF:SetTestModeOwner("raid", "user", false)
        if GUI.UpdateTestButtonState then GUI.UpdateTestButtonState() end
    end)

    DF.TestPanel = panel
    return panel
end

function DF:ToggleTestPanel()
    local panel = DF:CreateTestPanel()
    if panel:IsShown() then
        panel:Hide()
        return
    end
    panel:UpdateState()
    panel:Show()
    -- Opening the popup claims the current mode's preview for the user (it
    -- exists to show one): Party / Raid claim their scope. Claiming rather than
    -- calling Show* directly means the release on close is symmetric, and
    -- unlock's claim is untouched either way.
    panel:EnterCurrentMode()
    panel:UpdateState()
end

-- ============================================================
-- PARTY AND RAID TEST MODES
-- The two group modes, registered like any other. One set of section
-- builders serves both; `scope` is "party" or "raid". Every control writes
-- the same profile key the old panel did.
-- ============================================================

local GROUP_SCOPES = { party = true, raid = true }

local function GroupDB(scope)
    return scope == "raid" and DF:GetRaidDB() or DF:GetDB()
end

local function GroupIsRaidView()
    return DF.GUI and DF.GUI.SelectedMode == "raid" or false
end

-- The settings window shows a module with a test mode of its own (its def's
-- testModeId -- Unit Frames' Units): Party / Raid are not current there, so
-- the popup lands on that mode, and picking Party / Raid leaves the module.
local function ModuleOwnsTestMode()
    local GUI = DF.GUI
    local def = GUI and GUI.GetModule and GUI:GetModule()
    local id = def and def.testModeId
    if type(id) == "function" then id = id() end
    return type(id) == "string" and DF:GetTestMode(id) ~= nil
end

-- Put the settings window on this scope, through the one path every Party /
-- Raid switch takes (GUI:SelectModule): the Party/Raid sync, locking the mode
-- left behind, carrying a running preview across -- which is what keeps party
-- and raid test mode from ever running at once.
-- ⚠ With the window never opened (/df test), it is built hidden first: the
-- switch needs it. Rare, and the same frame the first open would build.
local function SwitchGroupScope(scope)
    local GUI = DF.GUI
    if not GUI then return end
    local cur = GroupIsRaidView() and "raid" or "party"
    if cur == scope and not ModuleOwnsTestMode() then return end
    if not DF.GUIFrame and DF.CreateGUI then DF:CreateGUI() end
    if GUI.SelectModule then GUI:SelectModule("group", scope) end
end

-- What follows a toggle: repaint the running preview.
local function RepaintGroupPreview(scope)
    if scope == "raid" then
        if DF.raidTestMode then
            DF:UpdateRaidTestFrames()
            -- ☠ SECOND PASS NEXT TICK. A toggle flipped on for the first time this
            -- session CREATES its bars during this pass, and an anchor-derived rect
            -- is 0 for the whole creation tick -- so anything anchored to a new
            -- bar's own texture (the absorb chained to the brand-new prediction
            -- fill) paints at width 0 and stays invisible until another toggle
            -- pass. The painter order fixes the within-pass dependency; this fixes
            -- the rects. It goes through the SAME UpdateTestFrame pathway -- no
            -- second painter.
            C_Timer.After(0, function()
                if DF.raidTestMode and DF.UpdateRaidTestFrames then
                    DF:UpdateRaidTestFrames()
                end
            end)
        end
    elseif DF.testMode then
        -- ⚠ _Now, not the arm-stub: the RefreshTestFrames right below and the
        -- After(0) "second pass over settled rects" both depend on this rebuild
        -- having already happened this tick.
        DF:UpdateAllFrames_Now()
        if DF.RefreshTestFrames then DF:RefreshTestFrames() end
        C_Timer.After(0, function()
            if DF.testMode and DF.RefreshTestFrames then DF:RefreshTestFrames() end
        end)
    end
end

-- A count slider's repaint while it moves.
local function ThrottledGroupRepaint()
    if DF.raidTestMode then DF:ThrottledUpdateRaidTestFrames()
    elseif DF.testMode then DF:ThrottledUpdateAll() end
end

local function CountDragStart()
    DF:OnSliderDragStart(function() if DF.RefreshTestFrames then DF:RefreshTestFrames() end end)
end
local function CountDragStop() DF:OnSliderDragStop() end

-- One on / off row. `after(value)` is the toggle's own follow-up; the preview
-- repaint runs after it for every toggle, as the old panel's afterToggle did.
-- The default mirrors how the preset matcher reads an unset key
-- (TEST_TOGGLE_DEFAULT_ON), so the switch and the lit preset never disagree.
local function GroupSwitch(rows, scope, label, key, pageId, after, extra)
    local spec = {
        label = label, key = key,
        default = TEST_TOGGLE_DEFAULT_ON[key] == true,
        onChanged = function(value)
            if after then after(value) end
            RepaintGroupPreview(scope)
        end,
    }
    if pageId then spec.link, spec.linkHint = DF:TestModeSettingsLink(pageId) end
    if extra then for k, v in pairs(extra) do spec[k] = v end end
    return rows:AddSwitch(spec)
end

-- The Defensives switch is a VIEW of testDefensiveCount, not a key of its own:
--   on  == (count > 0)
--   off -> remember the count, write 0
--   on  -> restore the remembered count (1 if there is nothing to restore)
-- They cannot disagree because there is only one value; the count row below
-- it moves with it, and dragging the count to 0 turns the switch off. The
-- preset system still sees one count key (TEST_COUNT_KEYS). Remembered per
-- scope, so a Party value never lands in a Raid restore.
local lastDefensiveCount = {}

local function BuildGeneral(rows, scope)
    GroupSwitch(rows, scope, L["Show Pets"], "testShowPets", "display_pets", function(on)
        if scope == "raid" then
            if not DF.raidTestMode then return end
            if on then
                if DF.InitializeTestRaidPetFrames then DF:InitializeTestRaidPetFrames() end
                if DF.UpdateAllRaidPetFrames then DF:UpdateAllRaidPetFrames(true) end
            elseif DF.HideAllTestRaidPetFrames then
                DF:HideAllTestRaidPetFrames()
            end
        else
            if not DF.testMode then return end
            if on then
                if DF.InitializeTestPetFrames then DF:InitializeTestPetFrames() end
                if DF.UpdateAllPetFrames then DF:UpdateAllPetFrames(true) end
            elseif DF.HideAllTestPetFrames then
                DF:HideAllTestPetFrames()
            end
        end
    end)
    GroupSwitch(rows, scope, L["Animate Health"], "testAnimateHealth", nil, function(on)
        local running = (scope == "raid") and DF.raidTestMode or DF.testMode
        if not running then return end
        if on then
            DF:StartTestAnimation()
        else
            -- The animation driver is shared: keep it while the OTHER scope's
            -- preview still wants it.
            local otherOn
            if scope == "raid" then
                otherOn = DF.testMode and DF:GetDB().testAnimateHealth
            else
                otherOn = DF.raidTestMode and DF:GetRaidDB().testAnimateHealth
            end
            if not otherOn then DF:StopTestAnimation() end
        end
    end)
    -- Marks whichever element the cursor is over, on any visible preview frame
    -- (Labels.lua). OFF by default -- test mode is also how people pixel-tune
    -- spacing. One toggle for both halves (highlight + naming).
    GroupSwitch(rows, scope, L["Indicator Info"], "testShowLabels", nil, function()
        if DF.UpdateTestLabels then DF:UpdateTestLabels() end
    end)

    local isRaid = scope == "raid"
    local fcKey = isRaid and "raidTestFrameCount" or "testFrameCount"
    rows:AddSlider({
        label = L["Frame Count"], key = fcKey,
        min = 1, max = isRaid and 40 or 5, step = 1,
        default = isRaid and 10 or 5,
        set = function(v) GroupDB(scope)[fcKey] = math.floor(v) end,
        onDragStart = function()
            DF:OnSliderDragStart(function()
                if DF.LightweightUpdateTestFrameCount then DF:LightweightUpdateTestFrameCount() end
            end)
        end,
        onDragStop = CountDragStop,
        onChanged = function()
            if isRaid and DF.raidTestMode then
                DF:ThrottledUpdateRaidTestFrames()
                if not DF.sliderDragging and DF.UpdateAllRaidPetFrames then DF:UpdateAllRaidPetFrames(true) end
            elseif not isRaid and DF.testMode then
                DF:ThrottledUpdateAll()
                if not DF.sliderDragging and DF.UpdateAllPetFrames then DF:UpdateAllPetFrames(true) end
            end
            -- Re-anchor the permanent mover when the frame count changes.
            C_Timer.After(0.1, function() DF:UpdatePermanentMoverAnchor(scope) end)
        end,
    })
end

local function BuildBars(rows, scope)
    GroupSwitch(rows, scope, L["Absorbs"], "testShowAbsorbs", "bars_absorb")
    GroupSwitch(rows, scope, L["Heal Prediction"], "testShowHealPrediction", "bars_healpred")
    GroupSwitch(rows, scope, L["Out of Range"], "testShowOutOfRange", "display_fading")
    GroupSwitch(rows, scope, L["Reduced Max Health"], "testShowReducedMaxHealth", "bars_health")
    -- Only offered when the Text Designer module is loaded.
    if DF.UpdateTextDesigner then
        GroupSwitch(rows, scope, L["Text Designer"], "testShowTextDesigner", "text_designer", function()
            if not DF.UpdateTextDesigner then return end
            for i = 0, 4 do
                local f = DF.testPartyFrames and DF.testPartyFrames[i]
                if f then DF:UpdateTextDesigner(f, "all") end
            end
            for i = 1, 40 do
                local f = DF.testRaidFrames and DF.testRaidFrames[i]
                if f then DF:UpdateTextDesigner(f, "all") end
            end
        end)
    end
end

local function BuildAuras(rows, scope)
    GroupSwitch(rows, scope, L["Show Auras"], "testShowAuras", "auras_buffs", function(on)
        -- Refresh on BOTH states: the 12.1 preview rows show / hide through the
        -- UpdateTestAuras seam, so turning them off needs a pass too.
        if scope == "party" and DF.testMode then
            if on then
                DF:RefreshTestFramesWithLayout()
            elseif DF.testPartyFrames then
                for i = 0, 4 do
                    local f = DF.testPartyFrames[i]
                    if f and f:IsShown() then DF:UpdateTestAuras(f) end
                end
            end
        elseif scope == "raid" and DF.raidTestMode and DF.testRaidFrames then
            for i = 1, 40 do
                local f = DF.testRaidFrames[i]
                if f and f:IsShown() then DF:UpdateTestAuras(f) end
            end
        end
    end)
    -- The Buff / Debuff counts only matter while auras are shown: grey them in
    -- place when Show Auras is off. Test Mode's OWN flag -- never a live
    -- profile setting, which nothing here would hear change.
    local function aurasOff() return not GroupDB(scope).testShowAuras end
    rows:AddSlider({
        label = L["Buffs"], key = "testBuffCount", min = 0, max = 5, step = 1, default = 3,
        disabled = aurasOff,
        onDragStart = CountDragStart, onDragStop = CountDragStop,
        onChanged = ThrottledGroupRepaint,
    })
    rows:AddSlider({
        label = L["Debuffs"], key = "testDebuffCount", min = 0, max = 5, step = 1, default = 3,
        disabled = aurasOff,
        onDragStart = CountDragStart, onDragStop = CountDragStop,
        onChanged = ThrottledGroupRepaint,
    })
    GroupSwitch(rows, scope, L["Dispel Overlay"], "testShowDispelGlow", "auras_dispel", function()
        if DF.testMode or DF.raidTestMode then DF:UpdateAllTestDispelGlow() end
    end)
    GroupSwitch(rows, scope, L["Missing Buff"], "testShowMissingBuff", "auras_missingbuffs", function()
        if DF.testMode or DF.raidTestMode then DF:UpdateAllTestMissingBuff() end
    end)
    GroupSwitch(rows, scope, L["Aura Designer"], "testShowAuraDesigner", "auras_auradesigner", function()
        if DF.testMode or DF.raidTestMode then DF:UpdateAllTestAuraDesigner() end
    end)
end

local function BuildIcons(rows, scope)
    -- ☠ THE DEFENSIVES PAIR IS DELIBERATELY UNGATED. It used to grey whenever the
    -- profile's defensiveIconEnabled was off -- but nothing tells this popup that
    -- setting changed, so the grey outlived its cause, and a greyed switch also
    -- swallowed its own click-through to the page that would fix it. The preview
    -- already no-ops while the feature is off (bug #1118 item 1).
    rows:AddHeading(L["Defensive Icon"])
    local link, hint = DF:TestModeSettingsLink("auras_defensiveicon")
    rows:AddSwitch({
        label = L["Defensives"], key = "testDefensiveCount", link = link, linkHint = hint,
        get = function() return (GroupDB(scope).testDefensiveCount or 0) > 0 end,
        set = function(on)
            local db = GroupDB(scope)
            if on then
                local restore = lastDefensiveCount[scope]
                if not restore or restore <= 0 then restore = 1 end
                db.testDefensiveCount = restore
            else
                -- Remember what to come back to, but never 0 -- the next switch
                -- on would then be a no-op.
                local cur = db.testDefensiveCount or 0
                if cur > 0 then lastDefensiveCount[scope] = cur end
                db.testDefensiveCount = 0
            end
        end,
        onChanged = ThrottledGroupRepaint,
    })
    -- ⚠ Fallback 0 here while Config seeds 1 -- the fallback only shows on a db
    -- with no key at all, as before.
    rows:AddSlider({
        label = L["Max Icons"], key = "testDefensiveCount", min = 0, max = 5, step = 1, default = 0,
        onDragStart = CountDragStart, onDragStop = CountDragStop,
        onChanged = ThrottledGroupRepaint,
    })

    rows:AddHeading(L["Targeted Spells"])
    -- The Targeted List is PARTY-ONLY (the list bails on IsInRaid() outright and
    -- its keys are stripped from the raid profile), so Raid does not offer it.
    if scope == "party" then
        GroupSwitch(rows, scope, L["Targeted List"], "testShowTargetedList", "indicators_targetedlist", function()
            if DF.testMode or DF.raidTestMode then DF:UpdateAllTestTargetedList() end
        end)
        GroupSwitch(rows, scope, L["Animate Targeted List"], "testAnimateTargetedList", nil, function()
            if DF.testMode or DF.raidTestMode then DF:UpdateAllTestTargetedList() end
        end)
    end
    -- Personal Targeted has no raid gate and is offered in both.
    GroupSwitch(rows, scope, L["Personal Targeted"], "testShowPersonalTargeted", "indicators_personal_targeted", function()
        if DF.testMode or DF.raidTestMode then DF:UpdateAllTestTargetedSpell() end
    end)

    rows:AddHeading(L["Status Icons"])
    -- One toggle for the whole status / role / leader icon set; the role and
    -- leader render gates read the same key.
    GroupSwitch(rows, scope, L["Icons"], "testShowStatusIcons", "indicators_icons", function()
        if DF.testMode or DF.raidTestMode then DF:RefreshTestFrames() end
    end)
end

local function BuildHighlights(rows, scope)
    local function repaint() if DF.UpdateAllTestHighlights then DF:UpdateAllTestHighlights() end end
    GroupSwitch(rows, scope, L["Selection"], "testShowSelection", "indicators_highlights", repaint)
    GroupSwitch(rows, scope, L["Aggro"], "testShowAggro", "indicators_highlights", repaint)
end

local function GroupSections(scope)
    return {
        { id = "general", label = function() return L["General"] end,
          icon = TEST_ICONS .. "tune.png",
          build = function(rows) BuildGeneral(rows, scope) end },
        { id = "bars", label = function() return L["Bars"] end,
          title = function() return L["Bars & Overlays"] end,
          icon = TEST_ICONS .. "favorite.png",
          build = function(rows) BuildBars(rows, scope) end },
        { id = "auras", label = function() return L["Auras"] end,
          icon = TEST_ICONS .. "auto_awesome.png",
          build = function(rows) BuildAuras(rows, scope) end },
        { id = "icons", label = function() return L["Icons"] end,
          title = function() return L["Indicators & Icons"] end,
          icon = TEST_ICONS .. "widget_small.png",
          build = function(rows) BuildIcons(rows, scope) end },
        { id = "highlights", label = function() return L["Highlights"] end,
          icon = TEST_ICONS .. "border_style.png",
          build = function(rows) BuildHighlights(rows, scope) end },
    }
end

local GROUP_PRESETS = {
    { id = "DEFAULT", label = function() return L["Default"] end },
    { id = "AURAS",   label = function() return L["Auras"] end },
    { id = "COMBAT",  label = function() return L["Combat"] end },
    { id = "HEALER",  label = function() return L["Healer"] end },
    { id = "FULL",    label = function() return L["Full"] end },
}

-- Text Designer previews default ON: seed a profile that predates the Config
-- default (migration timing can leave it nil), or the switch and the preview
-- disagree. Both scopes, on every open, as the old panel did on its build.
local function SeedGroupDefaults()
    if not DF.UpdateTextDesigner then return end
    local pdb, rdb = DF:GetDB(), DF:GetRaidDB()
    if pdb and pdb.testShowTextDesigner == nil then pdb.testShowTextDesigner = true end
    if rdb and rdb.testShowTextDesigner == nil then rdb.testShowTextDesigner = true end
end

local function RegisterGroupTestMode(scope, order)
    local isRaid = scope == "raid"
    DF:RegisterTestMode(scope, {
        label = function() return isRaid and L["Raid"] or L["Party"] end,
        icon = TEST_ICONS .. (isRaid and "grid_view.png" or "groups.png"),
        order = order,
        accent = function()
            local GUI = DF.GUI
            if GUI and GUI.GetThemeColorFor then return GUI.GetThemeColorFor(isRaid) end
            return nil
        end,
        isAvailable = function()
            local db = DF.db
            if isRaid and db and db.raidEnabled == false then
                return false, L["Raid frames are disabled. Enable them in General settings to use raid test mode."]
            elseif not isRaid and db and db.partyEnabled == false then
                return false, L["Party frames are disabled. Enable them in General settings to use party test mode."]
            end
            local GUI = DF.GUI
            if GUI and GUI.IsModulePickLocked and GUI:IsModulePickLocked("group", scope) then return false end
            return true
        end,
        -- Party / Raid follow the settings window's own Party / Raid: the popup
        -- is a view of the tab the user is on, exactly as the old panel was.
        isCurrent = function() return GroupIsRaidView() == isRaid and not ModuleOwnsTestMode() end,
        onEnter = function(fromId)
            SeedGroupDefaults()
            SwitchGroupScope(scope)
            -- Opening the popup, or arriving from a mode that is not a group
            -- one: the user is asking for this scope's preview. Party <-> Raid
            -- needs nothing more -- the switch carries a running preview over.
            if not GROUP_SCOPES[fromId or ""] then
                DF:SetTestModeOwner(scope, "user", true)
            end
        end,
        onExit = function(toId)
            -- To another kind of mode: the group preview goes. Party <-> Raid is
            -- the switch's to carry, and closing releases both (OnHide).
            if toId ~= nil and not GROUP_SCOPES[toId] then
                DF:SetTestModeOwner("party", "user", false)
                DF:SetTestModeOwner("raid", "user", false)
            end
        end,
        store = function() return GroupDB(scope) end,
        presets = GROUP_PRESETS,
        applyPreset = function(id) DF:ApplyTestPreset(id) end,
        activePreset = function() return DF:GetActiveTestPreset() end,
        isPreviewOn = function() return DF:IsTestModeOwnedBy(scope, "user") end,
        togglePreview = function() DF:ToggleTestMode() end,
        sections = GroupSections(scope),
    })
end

RegisterGroupTestMode("party", 10)
RegisterGroupTestMode("raid", 20)
