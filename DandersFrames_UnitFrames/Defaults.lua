local addonName, UF = ...

-- ============================================================
-- DEFAULTS
-- DF.db.unitframes = {
--     version = 1,
--     global  = { ... },                  -- module-wide
--     units   = { player = {...}, target = {...}, targettarget = {...},
--                 focus = {...}, focustarget = {...}, pet = {...},
--                 boss = {...} },                               -- boss1-5 share one
-- }
-- registered with DandersFrames as a profile-root table, so every profile gets
-- it, and profile copy / reset / import / export carry it.
--
-- The stored unit tables start EMPTY. A unit's defaults live here, in
-- UF.UnitDefaults, and are read through the chain in Core.lua
-- (stored -> UnitDefaults[u] -> DF.PartyDefaults). Keys that mean the same as a
-- DandersFrames party key use that key's name, so DF's updaters read them
-- unchanged. Keys new to unit frames: source, position.
--   source    "DF" (we draw it) | "Blizzard" (Blizzard draws it) | "Hidden"
--             (nobody does). Changing it needs a reload.
--   position  { point, x, y [, anchor] } -- the DandersMover record shape; without
--             the mover only point/x/y are applied.
-- ============================================================

local DF = DandersFrames
if not DF then return end

UF.DB_VERSION = 1

UF.GlobalDefaults = {
    -- DandersFrames' test mode (/df test) shows the unit frame preview too.
    includeInTestMode = true,
}

-- Applied to every unit before its own overrides below.
local COMMON = {
    source = "DF",
    frameScale = 1.0,
    missingBuffIconEnabled = false,
    -- Group-only indicators; Player switches them back on.
    leaderIconEnabled = false,
    readyCheckIconEnabled = false,
    summonIconEnabled = false,
    resurrectionIconEnabled = false,
    phasedIconEnabled = false,
    raidRoleIconEnabled = false,
    roleIconShowTank = false,
    roleIconShowHealer = false,
    roleIconShowDPS = false,
    defensiveIconEnabled = false,
    dispelOverlayEnabled = false,
    -- Visibility page (Units:VisibilityMacro): shown always, hidden in pet battles.
    visAlways = true,
    visCombat = false, visNoCombat = false, visGroup = false, visSolo = false,
    visInstance = false, visHasTarget = false, visHasEnemyTarget = false,
    visHidePetBattle = true,
    visHideVehicle = false, visHideMounted = false, visHideSkyriding = false,
}

-- ============================================================
-- CAST BAR / CLASS POWER / PORTRAIT / UNIT ICONS (keys new to unit frames)
-- Shared by every unit; PER_UNIT below switches them on per unit.
-- Colours are {r,g,b[,a]} tables (copied into the unit's table on first read,
-- Core.lua). Textures are paths and fonts LibSharedMedia names, the same as
-- DandersFrames' own keys.
-- ⚠ The Border cards on these pages use their OWN keys (castbarBorder*,
-- classPowerBorder*, portraitBorder*). The inventory listed the frame's
-- frameBorder* keys there, which would have made the cast bar's border and the
-- frame's border one setting.
-- ============================================================
local BAR = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist"
local FONT = "DF Roboto SemiBold"

local ELEMENTS = {
    -- Cast bar (CastBar.lua)
    castbarEnabled = false,
    castbarHideIdle = true,
    castbarLatency = false,
    castbarEmpower = true,
    castbarKickTick = true,
    castbarImportantGlow = false,
    castbarMatchWidth = true,
    castbarWidth = 220,
    castbarHeight = 18,
    castbarDetached = false,
    castbarSide = "BOTTOM",
    castbarGap = 2,
    castbarX = 0,
    castbarY = 0,
    castbarTexture = BAR,
    castbarBgTexture = BAR,
    castbarBgColor = { r = 0, g = 0, b = 0, a = 0.6 },
    castbarReverse = false,
    castbarSpark = true,
    castbarColor = { r = 1, g = 0.7, b = 0 },
    castbarNonInterruptibleColor = { r = 0.6, g = 0.6, b = 0.6 },
    castbarChannelColor = { r = 0.3, g = 0.7, b = 1 },
    castbarFailedColor = { r = 0.9, g = 0.2, b = 0.2 },
    castbarKickNotReadyColor = { r = 0.9, g = 0.4, b = 0.1 },
    castbarClassColor = false,
    castbarImportantGlowColor = { r = 1, g = 0.2, b = 0.2 },
    castbarShowIcon = true,
    castbarIconSide = "LEFT",
    castbarIconSize = 0,
    castbarBorderEnabled = true,
    castbarBorderSize = 1,
    castbarBorderColor = { r = 0, g = 0, b = 0, a = 1 },
    castbarShowSpell = true,
    castbarSpellFont = FONT,
    castbarSpellFontSize = 11,
    castbarSpellOutline = "OUTLINE",
    castbarSpellAnchor = "LEFT",
    castbarSpellX = 4,
    castbarSpellY = 0,
    castbarSpellColor = { r = 1, g = 1, b = 1 },
    castbarShowTimer = true,
    castbarTimerFormat = "REMAINING",
    castbarTimerDecimals = 1,
    castbarTimerFont = FONT,
    castbarTimerFontSize = 10,
    castbarTimerOutline = "OUTLINE",
    castbarTimerAnchor = "RIGHT",
    castbarTimerX = -4,
    castbarTimerY = 0,
    castbarTimerColor = { r = 1, g = 1, b = 1 },
    castbarShowTarget = false,
    castbarTargetSep = " > ",

    -- Class power (ClassPower.lua; the player only)
    classPowerEnabled = false,
    classPowerMode = "PIPS",
    classPowerHideEmpty = false,
    classPowerHideOOC = false,
    classPowerRunes = true,
    classPowerStagger = true,
    classPowerMatchWidth = true,
    classPowerWidth = 220,
    classPowerHeight = 6,
    classPowerGap = 2,
    classPowerDetached = false,
    classPowerPosition = "TOP",
    classPowerX = 0,
    classPowerY = 2,
    classPowerTexture = BAR,
    classPowerBg = { r = 0, g = 0, b = 0, a = 0.6 },
    classPowerColorMode = "CLASS",
    classPowerColor = { r = 1, g = 0.82, b = 0 },
    classPowerEmptyColor = { r = 0.15, g = 0.15, b = 0.15, a = 0.6 },
    classPowerChargedColor = { r = 0.4, g = 0.8, b = 1 },
    classPowerBorderEnabled = true,
    classPowerBorderSize = 1,
    classPowerBorderColor = { r = 0, g = 0, b = 0, a = 1 },

    -- Portrait (Portrait.lua)
    portraitEnabled = false,
    portraitMode = "3D",
    portraitNpcMode = "3D",
    portraitDesatDead = true,
    portraitSide = "LEFT",
    portraitSize = 0,
    portraitX = 0,
    portraitY = 0,
    portraitAlpha = 1,
    portrait3DZoom = 1,
    portrait3DRotation = 0,
    portraitBgColor = { r = 0, g = 0, b = 0, a = 0.8 },
    portraitMirror = false,
    portraitBorderEnabled = true,
    portraitBorderSize = 1,
    portraitBorderColor = { r = 0, g = 0, b = 0, a = 1 },

    -- Unit icons (Indicators.lua)
    restingIconEnabled = false,
    restingIconSize = 16,
    restingIconAnchor = "TOPLEFT",
    restingIconX = 0,
    restingIconY = 0,
    pvpIconEnabled = false,
    pvpIconSize = 16,
    pvpIconAnchor = "TOPRIGHT",
    pvpIconX = 0,
    pvpIconY = 0,
    classificationEnabled = false,
    classificationStyle = "ICON",
    classificationSize = 16,
    classificationAnchor = "TOPRIGHT",
    classificationX = 0,
    classificationY = 0,
}
for k, v in pairs(ELEMENTS) do COMMON[k] = v end

-- A detached element's position record: anchored to its owner, so the first
-- detach leaves it where the attached one was (DandersMover solves the x/y;
-- without the mover the x/y below are used and the anchor is ignored).
local function Detached(unit, edge, x, y)
    return { point = "CENTER", x = x, y = y,
             anchor = { target = "DandersFrames_UnitFrames:" .. unit, edge = edge,
                        align = "center", offsetX = 0, offsetY = 0 } }
end

-- Beside `owner`'s right edge, past a portrait that sits outside it: anchored to the
-- owner's OUTER rect (Mover.lua, "<unit>.outer"), with the owner frame itself as the
-- fallback (for a mover without outer rects), offset by the default portrait's reach.
local function BesideOuter(owner, x, y, reach)
    return { point = "CENTER", x = x, y = y,
             anchor = { target = "DandersFrames_UnitFrames:" .. owner .. ".outer", edge = "right",
                        align = "start", offsetX = 0, offsetY = 0,
                        fallback = { target = "DandersFrames_UnitFrames:" .. owner, edge = "right",
                                     align = "start", offsetX = reach, offsetY = 0 } } }
end

-- Enemy-frame aura filter: debuffs you cast, buffs shown in full (any caster).
-- Target widens its debuffs to every caster's (PER_UNIT below); Focus and Boss keep
-- yours only. Sated, Exhaustion and the rest of DandersFrames' default debuff
-- blacklist reach every unit through the chain (debuffBlacklist, party defaults).
local ENEMY_AURAS = {
    showDebuffs = true,
    directDebuffShowAll = false,
    debuffFilterMine = true,
    debuffFilterBoss = false,
    debuffFilterRole = false,
    debuffFilterPriority = false,
    debuffFilterCrowdControl = false,
    debuffFilterDispellable = false,
    directBuffShowAll = true,
    directBuffOnlyMine = false,
}

-- ============================================================
-- AURA ROWS
-- Player, Target and Focus put BUFFS ABOVE the frame and DEBUFFS BELOW it, one row
-- each, flush with an outer corner: buffs on a top corner growing sideways then UP,
-- debuffs on a bottom corner growing sideways then DOWN, so extra rows wrap away
-- from the frame. A row that grows away from its edge hangs OUTSIDE it, pinned by its
-- own corner nearest the frame (Elements.lua, AURA ROW PLACEMENT), so its offset is
-- just the gap to the frame (+/- AURA_GAP) at any icon size, and a bigger icon (an
-- important debuff) grows away from the frame.
-- Target from the LEFT edge growing right. Player is its mirror for the link
-- (Links.MirrorDefaults turns Player's anchors and growth into Target's): from the
-- RIGHT edge growing left. Every row key the two share is equal or mirrored, so the
-- default link keeps nothing about the rows apart.
-- ⚠ A debuff row under a frame whose cast bar is attached under it is pushed further
-- down by the cast bar's band at RUN time (CastBar.lua, AURA ROW RESERVE), not here.
-- Size 22 / spacing 1: 8 buffs span 183px (inside Target's 220), 5 debuffs 114px.
-- ============================================================
local AURA_SIZE, AURA_GAP = 22, 1

-- Shared by Player, Target and Focus. Sizes and counts are LOOK keys, which the
-- default link shares rather than mirrors, so Player and Target must agree on them.
local OUTSIDE_FRAME_AURAS = {
    buffSize = AURA_SIZE, buffPaddingX = AURA_GAP, buffPaddingY = AURA_GAP,
    buffMax = 8, buffWrap = 8,
    debuffSize = AURA_SIZE, debuffPaddingX = AURA_GAP, debuffPaddingY = AURA_GAP,
    debuffMax = 5, debuffWrap = 5,
    -- Flush with the frame's edge. Set here, not mirrored: a mirror of 0 is 0, so
    -- MirrorDefaults leaves it and Target would fall back to the party default.
    buffOffsetX = 0, debuffOffsetX = 0,
    -- The gap above / below the frame. Vertical: the mirror leaves it alone.
    buffOffsetY = AURA_GAP, debuffOffsetY = -AURA_GAP,
}
local OUTSIDE_FRAME = { player = true, target = true, focus = true }

-- Boss: debuffs (yours) in one row to the LEFT of the frame, growing left, as tall
-- as the frame (40). Buffs are off; turned on, they sit in one row to the RIGHT.
-- Each hangs outside its side, pinned by the corner nearest the frame, so its
-- offset is the gap and its icons line up on the frame's top.
local BOSS_DEBUFF_SIZE = 40

local PER_UNIT = {
    player = {
        frameWidth = 220, frameHeight = 46,
        healthColorMode = "CLASS",
        resourceBarEnabled = true, resourceBarHeight = 6,
        showBuffs = false, showDebuffs = true,
        -- From the right edge, growing left (AURA ROWS above): debuffs below the
        -- frame, buffs (off) above it.
        debuffAnchor = "BOTTOMRIGHT", debuffGrowth = "LEFT_DOWN",
        buffAnchor = "TOPRIGHT", buffGrowth = "LEFT_UP",
        oorEnabled = false,
        leaderIconEnabled = true, readyCheckIconEnabled = true, summonIconEnabled = true,
        resurrectionIconEnabled = true, phasedIconEnabled = true,
        roleIconShowTank = true, roleIconShowHealer = true, roleIconShowDPS = true,
        defensiveIconEnabled = true,
        dispelOverlayEnabled = true,
        textDesignerPreset = UF.TEXT_PRESET,
        position = { point = "CENTER", x = -280, y = -200 },
        -- Spec Q7: the player cast bar is on (Blizzard's is hidden while it is).
        -- ⚠ DETACHED by default, centred low on the screen where Blizzard's sits:
        -- attached under the frame it would sit on top of the pet frame, which is
        -- anchored to the player's bottom edge.
        castbarEnabled = true,
        castbarLatency = true,
        castbarDetached = true,
        castbarPosition = { point = "CENTER", x = 0, y = -250 },
        classPowerEnabled = true,
        classPowerPositionRecord = Detached("player", "top", -280, -175),
        portraitEnabled = true,
        restingIconEnabled = true,
        pvpIconEnabled = true,
        combatIconEnabled = true,
    },
    target = {
        frameWidth = 220, frameHeight = 46,
        healthColorMode = "CLASS_REACTION",
        resourceBarEnabled = true, resourceBarHeight = 6,
        showBuffs = true,
        -- Every caster's debuffs (ENEMY_AURAS keeps the rest of the enemy filter, for
        -- when Show All is turned off). Buffs above the frame, debuffs below, from the
        -- left edge growing right: Player's rows mirrored, by Links.MirrorDefaults below.
        directDebuffShowAll = true,
        oorEnabled = true,
        -- It IS the target, always: a selection outline would never turn off.
        selectionHighlightMode = "NONE",
        textDesignerPreset = UF.TEXT_PRESET,
        position = { point = "CENTER", x = 280, y = -200 },
        castbarEnabled = true,
        castbarPosition = Detached("target", "bottom", 280, -234),
        portraitEnabled = true,
        pvpIconEnabled = true,
        classificationEnabled = true,
    },
    targettarget = {
        frameWidth = 110, frameHeight = 24,
        healthColorMode = "CLASS_REACTION",
        resourceBarEnabled = false,
        showBuffs = false, showDebuffs = false,
        oorEnabled = true,
        textDesignerPreset = UF.TEXT_PRESET_SMALL,
        -- Beside the target's right edge, past its portrait (Target's sits outside on
        -- the right): anchored to the target's OUTER rect, which takes the portrait in
        -- at whatever size and side it has (Mover.lua, OUTER RECTS). x/y are where the
        -- mover's solve puts it for the default target position and portrait, so it is
        -- right without the mover too; the fallback is a mover without outer rects:
        -- the frame, past the default portrait (2 gap + 46 + 1 border).
        position = BesideOuter("target", 496, -189, 2 + 46 + 1),
    },
    focus = {
        frameWidth = 180, frameHeight = 36,
        healthColorMode = "CLASS_REACTION",
        resourceBarEnabled = true, resourceBarHeight = 4,
        showBuffs = false,
        -- Target's rows (AURA ROWS above): debuffs (yours) below the frame from its
        -- left edge; buffs (off) above it. 7 buffs to a row: 8 would overhang its 180px.
        buffAnchor = "TOPLEFT", buffGrowth = "RIGHT_UP", buffWrap = 7,
        debuffAnchor = "BOTTOMLEFT", debuffGrowth = "RIGHT_DOWN",
        oorEnabled = true,
        textDesignerPreset = UF.TEXT_PRESET,
        position = { point = "CENTER", x = -280, y = -300 },
        castbarEnabled = true,
        castbarHeight = 16,
        castbarPosition = Detached("focus", "bottom", -280, -328),
        portraitEnabled = true,
        classificationEnabled = true,
    },
    -- The focus's target: target of target's look, beside the focus's right edge
    -- (x/y are the mover's solve for the default focus position, as for ToT). Focus's
    -- portrait sits on its LEFT, so nothing is in the way by default; the outer rect
    -- keeps it clear if the portrait is moved to the right.
    focustarget = {
        frameWidth = 110, frameHeight = 24,
        healthColorMode = "CLASS_REACTION",
        resourceBarEnabled = false,
        showBuffs = false, showDebuffs = false,
        oorEnabled = true,
        textDesignerPreset = UF.TEXT_PRESET_SMALL,
        position = BesideOuter("focus", -131, -294, 0),
    },
    pet = {
        frameWidth = 140, frameHeight = 30,
        healthColorMode = "CLASS",
        resourceBarEnabled = false,
        -- A few debuffs (what you would dispel off your pet) in one row under the
        -- frame from its left edge, growing right: 4 x 22px spans 91 of its 140px.
        -- Buffs stay off.
        showBuffs = false, showDebuffs = true,
        debuffSize = AURA_SIZE, debuffPaddingX = AURA_GAP, debuffPaddingY = AURA_GAP,
        debuffMax = 4, debuffWrap = 4,
        debuffAnchor = "BOTTOMLEFT", debuffGrowth = "RIGHT_DOWN",
        debuffOffsetX = 0, debuffOffsetY = -AURA_GAP,
        oorEnabled = false,
        textDesignerPreset = UF.TEXT_PRESET_SMALL,
        castbarHeight = 12,
        castbarPosition = Detached("pet", "bottom", -365, -265),
        -- FREE (no anchor), below-left of the player frame: its top 4px under the
        -- player's bottom, its right edge 11px left of where Player's debuff row
        -- (five 22px icons from the player's right edge) ends.
        position = { point = "CENTER", x = -365, y = -242 },
    },
    boss = {
        frameWidth = 180, frameHeight = 40,
        healthColorMode = "CLASS_REACTION",
        resourceBarEnabled = true, resourceBarHeight = 4,
        showBuffs = false,
        -- Your debuffs in one row LEFT of the frame, growing left, as tall as the
        -- frame; buffs (off) in one row on the RIGHT, growing right. See BOSS_DEBUFF_SIZE.
        debuffSize = BOSS_DEBUFF_SIZE, debuffPaddingX = AURA_GAP, debuffPaddingY = AURA_GAP,
        debuffMax = 4, debuffWrap = 4,
        debuffAnchor = "TOPLEFT", debuffGrowth = "LEFT_DOWN",
        debuffOffsetX = -AURA_GAP, debuffOffsetY = 0,
        buffSize = AURA_SIZE, buffPaddingX = AURA_GAP, buffPaddingY = AURA_GAP,
        buffMax = 4, buffWrap = 4,
        buffAnchor = "TOPRIGHT", buffGrowth = "RIGHT_DOWN",
        buffOffsetX = AURA_GAP, buffOffsetY = 0,
        -- ⚠ Both rows are anchored to a TOP corner, so the attached cast bar under
        -- each boss never pushes them (CastBar.lua, AURA ROW RESERVE).
        oorEnabled = true,
        textDesignerPreset = UF.TEXT_PRESET,
        position = { point = "CENTER", x = 480, y = 120 },
        castbarEnabled = true,
        castbarHeight = 14,
        classificationEnabled = true,
        -- Boss Layout page (Boss.lua). The inventory's Units Per Row and Preview
        -- Frames go up to 8; this build draws UF.BOSS_COUNT (5) slots, so both
        -- default to (and clamp at) that count -- every slot in one line, and all
        -- five sample bosses in the preview.
        bossGrowth = "DOWN",
        bossSpacing = 40,
        bossUnitsPerRow = 5,
        bossRowSpacing = 4,
        bossPreviewCount = true,
        bossPreviewNum = 5,
    },
}

local ENEMY = { target = true, focus = true, boss = true }

-- Frames that usually show a hostile unit. DF's aggro highlight reads the UNIT's
-- own threat, which means nothing on an enemy (the spec's "your threat on the
-- unit" reading is a later runtime change), so it starts off there.
local HOSTILE_SHOWN = { target = true, targettarget = true, focus = true, focustarget = true, boss = true }

UF.UnitDefaults = {}
for _, unit in ipairs(UF.UNITS) do
    local t = {}
    for k, v in pairs(COMMON) do t[k] = v end
    if ENEMY[unit] then
        for k, v in pairs(ENEMY_AURAS) do t[k] = v end
    end
    if HOSTILE_SHOWN[unit] then t.aggroHighlightMode = "NONE" end
    if OUTSIDE_FRAME[unit] then
        for k, v in pairs(OUTSIDE_FRAME_AURAS) do t[k] = v end
    end
    for k, v in pairs(PER_UNIT[unit] or {}) do t[k] = v end
    UF.UnitDefaults[unit] = t
end

-- Target's layout defaults are the MIRROR of Player's for the pieces the default
-- link mirrors (Links.lua, THE DEFAULT LINK): portrait on the right, buffs and
-- debuffs growing the other way, the cast bar's icon and texts swapped. So a
-- fresh profile's default link has nothing to store, and a Reset on either side
-- lands the other on its own default. Keys Target sets above on purpose stay.
if UF.Links and UF.Links.MirrorDefaults then
    UF.Links.MirrorDefaults(UF.UnitDefaults.player, UF.UnitDefaults.target, PER_UNIT.target,
        UF.Links.DEFAULT.elements)
end

-- The profile-root table. Unit tables start empty (sparse; see the header).
UF.ProfileDefaults = { version = UF.DB_VERSION, global = {}, units = {} }
for _, unit in ipairs(UF.UNITS) do UF.ProfileDefaults.units[unit] = {} end

-- Runs on an EXISTING table before the registry's one-level fill. The fill
-- leaves an existing `units` table alone, so a unit added in a later version
-- gets its table here.
function UF.MigrateProfileTable(tbl)
    if type(tbl.global) ~= "table" then tbl.global = {} end
    if type(tbl.units) ~= "table" then tbl.units = {} end
    for _, unit in ipairs(UF.UNITS) do
        if type(tbl.units[unit]) ~= "table" then tbl.units[unit] = {} end
    end
    if type(tbl.version) ~= "number" or tbl.version < UF.DB_VERSION then
        tbl.version = UF.DB_VERSION
    end
    -- Linked frames: the old per-page sync becomes unit links, and a profile that
    -- never had links gets the default one (Links.lua ENSURE). Idempotent.
    if UF.Links and UF.Links.Ensure then UF.Links:Ensure(tbl) end
end

if DF.RegisterProfileRootTable then
    DF:RegisterProfileRootTable("unitframes", {
        defaults = UF.ProfileDefaults,
        migrate = UF.MigrateProfileTable,
        exportable = true,
        exportCategory = "unitframes",
    })
end
