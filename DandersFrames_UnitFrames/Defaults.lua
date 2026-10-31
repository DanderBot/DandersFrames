local addonName, UF = ...

-- ============================================================
-- DEFAULTS
-- DF.db.unitframes = {
--     version = 1,
--     global  = { ... },                  -- module-wide
--     units   = { player = {...}, target = {...}, targettarget = {...},
--                 focus = {...}, pet = {...}, boss = {...} },   -- boss1-5 share one
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

-- Enemy-frame aura filter: debuffs you cast, buffs shown in full.
local ENEMY_AURAS = {
    showDebuffs = true,
    directDebuffShowAll = false,
    debuffFilterMine = true,
    debuffFilterBoss = false,
    debuffFilterRole = false,
    debuffFilterPriority = false,
    debuffFilterCrowdControl = false,
    debuffFilterDispellable = false,
}

local PER_UNIT = {
    player = {
        frameWidth = 220, frameHeight = 46,
        healthColorMode = "CLASS",
        resourceBarEnabled = true, resourceBarHeight = 6,
        showBuffs = false, showDebuffs = true,
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
        showBuffs = true, directBuffShowAll = true, directBuffOnlyMine = false,
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
        -- Beside the target's right edge. x/y are where the mover's solve puts it
        -- for the default target position, so it is right without the mover too.
        position = { point = "CENTER", x = 449, y = -189,
                     anchor = { target = "DandersFrames_UnitFrames:target", edge = "right",
                                align = "start", offsetX = 0, offsetY = 0 } },
    },
    focus = {
        frameWidth = 180, frameHeight = 36,
        healthColorMode = "CLASS_REACTION",
        resourceBarEnabled = true, resourceBarHeight = 4,
        showBuffs = false,
        oorEnabled = true,
        textDesignerPreset = UF.TEXT_PRESET,
        position = { point = "CENTER", x = -280, y = -300 },
        castbarEnabled = true,
        castbarHeight = 16,
        castbarPosition = Detached("focus", "bottom", -280, -328),
        portraitEnabled = true,
        classificationEnabled = true,
    },
    pet = {
        frameWidth = 110, frameHeight = 24,
        healthColorMode = "CLASS",
        resourceBarEnabled = false,
        showBuffs = false, showDebuffs = false,
        oorEnabled = false,
        textDesignerPreset = UF.TEXT_PRESET_SMALL,
        castbarHeight = 12,
        castbarPosition = Detached("pet", "bottom", -335, -260),
        -- Under the player frame, left edges aligned.
        position = { point = "CENTER", x = -335, y = -239,
                     anchor = { target = "DandersFrames_UnitFrames:player", edge = "bottom",
                                align = "start", offsetX = 0, offsetY = 0 } },
    },
    boss = {
        frameWidth = 180, frameHeight = 40,
        healthColorMode = "CLASS_REACTION",
        resourceBarEnabled = true, resourceBarHeight = 4,
        showBuffs = false,
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
local HOSTILE_SHOWN = { target = true, targettarget = true, focus = true, boss = true }

UF.UnitDefaults = {}
for _, unit in ipairs(UF.UNITS) do
    local t = {}
    for k, v in pairs(COMMON) do t[k] = v end
    if ENEMY[unit] then
        for k, v in pairs(ENEMY_AURAS) do t[k] = v end
    end
    if HOSTILE_SHOWN[unit] then t.aggroHighlightMode = "NONE" end
    for k, v in pairs(PER_UNIT[unit] or {}) do t[k] = v end
    UF.UnitDefaults[unit] = t
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
end

if DF.RegisterProfileRootTable then
    DF:RegisterProfileRootTable("unitframes", {
        defaults = UF.ProfileDefaults,
        migrate = UF.MigrateProfileTable,
        exportable = true,
        exportCategory = "unitframes",
    })
end
