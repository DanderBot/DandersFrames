local NS = ...

-- ============================================================
-- GLOBAL FONTS REACH THE UNIT FRAMES (bug #1142)
-- General > Fonts "Apply to All" used to write the party and raid tables only.
-- UF:ApplyGlobalFont (the companion's Core.lua) is the unit frames' half: every
-- unit's font keys, and every Text Designer template a unit frame draws with.
-- The real companion Core / Links / Defaults run over a stub DandersFrames.
-- ============================================================

local saved = { DandersFrames = DandersFrames, CreateFrame = CreateFrame }

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local DF = {
    L = setmetatable({}, { __index = function(_, k) return k end }),
    PartyDefaults = { frameWidth = 120, nameFont = "Party Default", nameTextOutline = "OUTLINE" },
    SECTION_PREFIXES = {},
}
function DF:DeepCopy(t) return deepcopy(t) end
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:RegisterProfileRootTable() return true end
DF.RegisterCallback = function() end
DandersFrames = DF

local lib = {}
DF.db = { party = {}, raid = {}, textDesignerPresets = lib }
function DF:GetDB(mode) return DF.db[mode] end
function DF:GetTextDesignerPresets() return lib end

CreateFrame = nil
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
DF.db.unitframes = deepcopy(UF.ProfileDefaults)

local function tpl(font) return { elements = { { font = font }, { font = font } }, globalDefaults = { font = font } } end
lib[UF.TEXT_PRESET] = tpl("old")
lib[UF.TEXT_PRESET_SMALL] = tpl("old")
for _, n in pairs(UF.RING_TEXT_PRESETS) do lib[n] = tpl("old") end
lib.Mine = { elements = { { font = "old" } } }          -- no globalDefaults table yet
lib.Party = tpl("party")                                -- no unit frame uses it
UF:GetUnitDB("focus").ringTextDesignerPreset = "Mine"

local refreshed = 0
UF.RefreshAll = function() refreshed = refreshed + 1 end

print("-- UF:ApplyGlobalFont")
check(UF:ApplyGlobalFont("New Font", "THICKOUTLINE") == true, "applies")
eq(refreshed, 1, "...and repaints the unit frames once")
for _, unit in ipairs(UF.UNITS) do
    local stored = UF:GetStoredUnit(unit)
    eq(stored.nameFont, "New Font", unit .. ": name font")
    eq(stored.debuffDurationOutline, "THICKOUTLINE", unit .. ": aura outline")
    eq(stored.castbarSpellFont, "New Font", unit .. ": cast bar spell font")
    eq(stored.castbarTimerOutline, "THICKOUTLINE", unit .. ": cast bar timer outline")
end
for _, n in ipairs({ UF.TEXT_PRESET, UF.TEXT_PRESET_SMALL, UF.RING_TEXT_PRESET, "Ring: Side Plate" }) do
    eq(lib[n].elements[1].font, "New Font", n .. ": its elements")
    eq(lib[n].globalDefaults.font, "New Font", n .. ": its defaults (what a NEW element follows)")
    eq(lib[n].globalDefaults.outline, "THICKOUTLINE", n .. ": ...and outline")
end
eq(lib.Mine.elements[1].font, "New Font", "a unit's own template (its Ring one) is written too")
eq(lib.Mine.globalDefaults and lib.Mine.globalDefaults.font, "New Font", "...its defaults created when missing")
eq(lib.Party.elements[1].font, "party", "a template no unit frame uses is left alone")
eq(DF.db.party.nameFont, nil, "the party table is not this function's business")

print("-- Bad input")
check(UF:ApplyGlobalFont(nil, "OUTLINE") == false, "no font: nothing happens")
eq(refreshed, 1, "...and no repaint")

print("-- The Fonts page offers it")
local src = options_file_source("GUI/Pages/Frames.lua")
check(src:find('scopeOptions.unitframes = L["Unit Frames"]', 1, true) ~= nil, "a Unit Frames choice, when the module is installed")
check(src:find('if (scope == "all" or scope == "unitframes") and UF and UF.ApplyGlobalFont then', 1, true) ~= nil,
      "...and All includes the unit frames")

DandersFrames, CreateFrame = saved.DandersFrames, saved.CreateFrame
