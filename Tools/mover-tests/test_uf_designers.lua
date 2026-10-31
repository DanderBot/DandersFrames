local NS = ...

-- ============================================================
-- PER-UNIT DESIGNER TEMPLATES (phase 1)
-- docs/superpowers/specs/2026-11-01-uf-per-unit-designers.md
--   * DandersFrames' Designer/Presets.lua: the generic OTHER REFERENCE CARRIERS
--     hook -- rename / delete / users list / import reach a registered walker's
--     tables, and a walker that errors costs nothing else
--   * the unit frames companion (Core.lua): every unit names its own Text and
--     Aura Designer template; an unset Aura template follows the Party frames'
--     current one; Make Own Template; the frame stamps
-- The real Presets.lua and the real companion Core / Links / Defaults run over
-- a stub DandersFrames.
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
local errors = {}
function DF:DebugError(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
function DF:RegisterProfileRootTable() return true end
DF.RegisterCallback = function() end
function DF:BuildDefaultTextDesignerConfig() return { enabled = true, elements = {} } end
DF.TextDesigner = nil
DandersFrames = DF

DF.db = {
    party = { auraDesignerPreset = "Party", textDesignerPreset = "Party" },
    raid = { auraDesignerPreset = "Raid", textDesignerPreset = "Raid" },
    auraDesignerPresets = { Party = { tag = "party" }, Raid = { tag = "raid" }, Mine = { tag = "mine" } },
    textDesignerPresets = { Party = {}, Raid = {} },
}
function DF:GetDB(mode) return DF.db[mode] end

load_df_file_into("Designer/Presets.lua", DF)
check(type(DF.RegisterDesignerRefCarrier) == "function", "api: DF:RegisterDesignerRefCarrier")
eq(#DF.DesignerRefCarriers, 0, "no carrier before the companion loads")

CreateFrame = nil        -- the companion's file-scope event wiring is skipped
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
DF.db.unitframes = deepcopy(UF.ProfileDefaults)
DF.db.textDesignerPresets[UF.TEXT_PRESET] = { tag = "uf" }
DF.db.textDesignerPresets[UF.TEXT_PRESET_SMALL] = { tag = "ufsmall" }

print("-- The companion registers its walker")
eq(#DF.DesignerRefCarriers, 1, "one carrier: the unit frames")
DF:RegisterDesignerRefCarrier(UF.DesignerRefWalker)
eq(#DF.DesignerRefCarriers, 1, "...registered once, however often asked")

print("-- Each unit's templates")
eq(UF:UnitTemplate("target", "aura"), "Party", "aura, unset: the Party frames' current template")
DF:SetModeDesignerPreset("aura", "party", "Mine")
eq(UF:UnitTemplate("target", "aura"), "Mine", "...and follows when Party switches")
eq(UF:UnitTemplate("target", "text"), UF.TEXT_PRESET, "text: the unit's default template")
eq(UF:UnitTemplate("pet", "text"), UF.TEXT_PRESET_SMALL, "...the small one on Pet")

local f = { dfStandalone = true, dfDB = UF:GetUnitDB("target") }
UF:StampDesigners(f)
eq(f.dfAuraPresetOverride, "Mine", "stamp: the aura template")
eq(f.dfTextPresetOverride, UF.TEXT_PRESET, "stamp: the text template")
eq(DF:ResolveAuraDesigner(f).tag, "mine", "DandersFrames resolves the stamped template")

print("-- Make Own Template")
local name = UF:MakeOwnTemplate("target", "aura")
eq(name, "Target", "named for the unit")
local lib = DF.db.auraDesignerPresets
check(lib.Target and lib.Target ~= lib.Mine and lib.Target.tag == "mine", "a copy of the template it used")
eq(UF:GetStoredUnit("target").auraDesignerPreset, "Target", "...and the unit points at it")
eq(DF.db.party.auraDesignerPreset, "Mine", "...Party is untouched")
eq(UF:MakeOwnTemplate("focus", "aura"), "Focus", "another unit: its own name")
eq(UF:MakeOwnTemplate("target", "aura"), "Target 2", "a second one: a unique name")
UF:GetStoredUnit("target").auraDesignerPreset = "Target"
eq(UF:MakeOwnTemplate("boss", "text"), "Boss", "text: the same")
eq(DF.db.textDesignerPresets.Boss.tag, "uf", "...copied from the unit's default text template")

print("-- Rename reaches the units")
eq(DF:RenameDesignerPreset("aura", "Target", "Target Auras"), "Target Auras", "rename")
eq(UF:GetStoredUnit("target").auraDesignerPreset, "Target Auras", "...the unit follows")
eq(DF:RenameDesignerPreset("text", UF.TEXT_PRESET, "Big"), "Big", "rename a unit default template")
eq(UF:GetStoredUnit("player").textDesignerPreset, "Big", "...a unit on its default stores the new name")
eq(UF:GetStoredUnit("pet").textDesignerPreset, nil, "...a unit on another template is left alone")
eq(DF.db.party.textDesignerPreset, "Party", "...Party's ref unchanged")

print("-- Also used by")
local users = DF:ListDesignerPresetUsers("text", "Big", "party")
local found = false
for _, u in ipairs(users) do if u == "Player (Unit Frames)" then found = true end end
check(found, "the users list names a unit")
local partyUsers = DF:ListDesignerPresetUsers("aura", "Mine", "raid")
local sawParty, sawUnit = false, false
for _, u in ipairs(partyUsers) do
    if u == "Party" then sawParty = true end
    if u:find("Unit Frames", 1, true) then sawUnit = true end
end
check(sawParty, "...alongside Party")
check(sawUnit, "...and a unit following Party counts as using its template")

print("-- A unit following Party keeps following through a rename")
eq(UF:GetStoredUnit("player").auraDesignerPreset, nil, "(player follows Party)")
eq(DF:RenameDesignerPreset("aura", "Mine", "Mine Renamed"), "Mine Renamed", "rename Party's template")
eq(UF:GetStoredUnit("player").auraDesignerPreset, nil, "...the following unit is not pinned to the name")
eq(UF:UnitTemplate("player", "aura"), "Mine Renamed", "...and draws the renamed template")
DF:RenameDesignerPreset("aura", "Mine Renamed", "Mine")

print("-- Delete clears a unit's ref")
check(DF:DeleteDesignerPreset("aura", "Target Auras"), "delete")
eq(UF:GetStoredUnit("target").auraDesignerPreset, nil, "the unit's ref is cleared...")
eq(UF:UnitTemplate("target", "aura"), "Mine", "...so it follows Party again (not the empty Default)")
eq(DF.db.party.auraDesignerPreset, "Mine", "Party untouched")

print("-- Import repoints inside the payload")
local payload = {
    auraDesignerPresets = { Mine = { tag = "imported" } },
    party = { auraDesignerPreset = "Mine" },
    unitframes = { units = { target = { auraDesignerPreset = "Mine" }, focus = {} } },
}
local renamed = DF:UniquifyImportedDesignerPresets(payload, nil)
eq(renamed and renamed.aura and renamed.aura.Mine, "Mine 2", "a clashing imported template is renamed")
eq(payload.unitframes.units.target.auraDesignerPreset, "Mine 2", "...and the payload's unit ref follows")
eq(payload.party.auraDesignerPreset, "Mine 2", "...as the party ref does")
eq(UF:GetStoredUnit("target").auraDesignerPreset, nil, "...the live profile's units are not touched")

print("-- A walker that errors costs only itself")
DF:RegisterDesignerRefCarrier(function() error("bad walker") end)
DF.db.party.textDesignerPreset = "Raid"
eq(DF:RenameDesignerPreset("text", "Raid", "Raid Text"), "Raid Text", "rename still runs")
eq(DF.db.party.textDesignerPreset, "Raid Text", "...Party's ref repointed")
check(#errors > 0 and errors[#errors]:find("bad walker", 1, true), "...and the error is logged")
table.remove(DF.DesignerRefCarriers)

print("-- Pages: the keys are the page's")
eq(table.concat(UF.Links.KIND_PREFIXES.auradesigner, ","), "auraDesignerEnabled,auraDesignerPreset",
   "Aura Designer page: the enable and the template (Copy, Reset, Links)")
eq(UF.Links.Aspect("auraDesignerPreset"), "look", "...a template is look: a link shares it")
local src = options_file_source("UnitFrames/Pages.lua")
check(src:find('if kind == "auradesigner" then return { "auraDesignerEnabled", "auraDesignerPreset" } end', 1, true),
      "UFO.Prefixes says the same")
check(src:find("function UFO.MakeOwnTemplate", 1, true) and src:find('L["Make Own Template"]', 1, true),
      "the pages offer Make Own Template")
local units = uf_file_source("Units.lua")
local preview = uf_file_source("Preview.lua")
check(units:find("UF:StampDesigners(f, db)", 1, true) and preview:find("UF:StampDesigners(f, db)", 1, true),
      "the live frames and the preview stamp both templates")

DandersFrames, CreateFrame = saved.DandersFrames, saved.CreateFrame
