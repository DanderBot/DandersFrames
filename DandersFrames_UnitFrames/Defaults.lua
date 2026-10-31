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

UF.GlobalDefaults = {}

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
}

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
    },
    pet = {
        frameWidth = 110, frameHeight = 24,
        healthColorMode = "CLASS",
        resourceBarEnabled = false,
        showBuffs = false, showDebuffs = false,
        oorEnabled = false,
        textDesignerPreset = UF.TEXT_PRESET_SMALL,
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
