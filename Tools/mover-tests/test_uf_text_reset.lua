local NS = ...

-- ============================================================
-- RESET PAGE ON A UNIT'S TEXT PAGE (bug #1142)
-- The text lives in a shared library template, so clearing the unit's template
-- keys did nothing. UF:ResetTextTemplates resets the template's CONTENTS when
-- only this unit uses it, and never touches a template something else draws:
-- the unit moves instead, and a shared Text link turns its look to own so the
-- partner keeps its text. The real Presets.lua and the companion's Core / Links /
-- Defaults run over a stub DandersFrames.
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
    PartyDefaults = { auraDesigner = { enabled = false, auras = {} }, frameWidth = 120 },
    SECTION_PREFIXES = {},
}
function DF:DeepCopy(t) return deepcopy(t) end
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:RegisterProfileRootTable() return true end
DF.RegisterCallback = function() end
-- Deterministic, as the real one is (element ids count up from 1).
function DF:BuildDefaultTextDesignerConfig()
    return { enabled = true, nextElementID = 4, globalDefaults = { font = "Roboto" },
             elements = { { id = 1, contentType = "name", font = "Roboto" },
                          { id = 2, contentType = "hp_current", font = "Roboto" },
                          { id = 3, contentType = "status_text", font = "Roboto" } } }
end
DandersFrames = DF

DF.db = {
    party = { auraDesignerPreset = "Party", textDesignerPreset = "Party" },
    raid = { auraDesignerPreset = "Raid", textDesignerPreset = "Raid" },
    auraDesignerPresets = { Party = {}, Raid = {} },
    textDesignerPresets = { Party = {}, Raid = {} },
}
function DF:GetDB(mode) return DF.db[mode] end
load_df_file_into("Designer/Presets.lua", DF)

CreateFrame = nil
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
UF.RefreshAll = function() end

local lib = DF.db.textDesignerPresets
local function fresh()
    DF.db.unitframes = deepcopy(UF.ProfileDefaults)
    UF.Links:Ensure(DF.db.unitframes)
    for k in pairs(lib) do if k ~= "Party" and k ~= "Raid" then lib[k] = nil end end
    UF:RebuildUnitDBs()
    UF.Links.ResetCaches()
    UF:EnsureTextPresets()
end
local function aspects(unit)
    return UF.Links:Aspects(UF.Links.LiveRoot(), unit, "text")
end

print("-- The builder is what EnsureTextPresets seeds")
fresh()
check(UF.SameTextContent(lib[UF.TEXT_PRESET], UF.BuildTextPreset(UF.TEXT_PRESET)), "Unit Frames: a fresh build matches the seeded one")
check(UF.SameTextContent(lib[UF.RING_TEXT_PRESET], UF.BuildTextPreset(UF.RING_TEXT_PRESET)), "...and the Ring one")
eq(UF.BuildTextPreset("Party"), nil, "not a built-in: no builder")
eq(#lib[UF.TEXT_PRESET_SMALL].elements, 1, "the small one keeps the name only")
lib[UF.TEXT_PRESET].globalDefaults._skipOverrideIndicators = true
check(UF.SameTextContent(lib[UF.TEXT_PRESET], UF.BuildTextPreset(UF.TEXT_PRESET)), "an underscore key the designer stamps is not an edit")

print("-- Untouched default: nothing to do")
eq((UF:ResetTextTemplates("target")), 0, "target on pristine defaults: no change")
local layout, look = aspects("target")
eq(look, "same", "...and the default Player/Target text link is left alone")

print("-- Own template, nobody else uses it: its contents reset in place")
fresh()
local own = UF:MakeOwnTemplate("focus", "text")
local tbl = lib[own]
tbl.elements[1].font = "Comic"
tbl.elements[4] = { id = 9, contentType = "power" }
local n = UF:ResetTextTemplates("focus")
eq(n, 1, "one style key changed")
check(lib[own] == tbl, "the same table, refilled (a designer holding it keeps it)")
check(UF.SameTextContent(tbl, UF.BuildTextPreset(UF.TEXT_PRESET)), "...back to the unit's default template's contents")
eq(UF:GetUnitDB("focus").textDesignerPreset, own, "...and the unit keeps its template name")

print("-- Edited default shared with the linked partner: the partner is never reset")
fresh()
lib[UF.TEXT_PRESET].elements[1].font = "Comic"
local _, detach = UF:ResetTextTemplates("target", true)
check(detach == true, "dry run: says the link's text look turns own")
eq(lib[UF.TEXT_PRESET].elements[1].font, "Comic", "dry run: changes nothing")
eq(aspects("target"), "mirror", "dry run: the link is untouched")
UF:ResetTextTemplates("target")
eq(lib[UF.TEXT_PRESET].elements[1].font, "Comic", "the shared template is untouched (Player keeps its text)")
eq(UF:GetUnitDB("player").textDesignerPreset, UF.TEXT_PRESET, "Player stays on it")
local tname = UF:GetUnitDB("target").textDesignerPreset
eq(tname, "Target", "Target gets a fresh template of its own")
check(UF.SameTextContent(lib[tname], UF.BuildTextPreset(UF.TEXT_PRESET)), "...with the default contents")
layout, look = aspects("target")
eq(look, "own", "the Text link's look turns own, so the next push cannot undo it")
eq(layout, "mirror", "...its layout (the mirror) stays")
UF.Links:ApplyFrom(UF.Links.LiveRoot(), "player")
eq(UF:GetUnitDB("target").textDesignerPreset, "Target", "a later push from Player leaves Target's template alone")

print("-- On a shared template while the default is untouched: back to the default")
fresh()
UF.Links:Unlink(UF.Links.LiveRoot(), "target")
UF:GetUnitDB("focus").textDesignerPreset = "Party"
UF:ResetTextTemplates("focus")
eq(UF:GetUnitDB("focus").textDesignerPreset, UF.TEXT_PRESET, "focus is back on its default template")
eq(UF:GetStoredUnit("focus").textDesignerPreset, nil, "...stored as the default, not as a name")
check(lib.Party ~= nil and next(lib.Party) == nil, "Party's template is untouched")

print("-- The Ring style's template too")
fresh()
UF.Links:Unlink(UF.Links.LiveRoot(), "target")
lib[UF.RING_TEXT_PRESET].elements[1].fontSize = 30
UF:ResetTextTemplates("focus")
eq(lib[UF.RING_TEXT_PRESET].elements[1].fontSize, 30, "the shared Ring template is untouched")
eq(UF:GetUnitDB("focus").ringTextDesignerPreset, "Focus Ring", "focus gets its own Ring template")

print("-- The page")
local src = options_file_source("UnitFrames/Pages.lua")
check(src:find('if kind == "text" and UF.ResetTextTemplates then', 1, true) ~= nil, "Reset Page on Text resets the template")
check(src:find("local _, detach = UF:ResetTextTemplates(unit, true)", 1, true) ~= nil, "...and the confirmation says when the link changes")

DandersFrames, CreateFrame = saved.DandersFrames, saved.CreateFrame
