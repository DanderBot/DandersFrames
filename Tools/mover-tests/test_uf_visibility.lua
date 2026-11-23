local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- VISIBILITY AND FADES
-- DandersFrames_UnitFrames/Units.lua (VisibilityMacro, ApplyVisibility,
-- SweepFrameFade) and the Visibility page (DandersFrames_Options/UnitFrames).
-- ------------------------------------------------------------
-- Each unit's holder carries a "visibility" state driver built from its
-- Visibility page keys; it is (re)registered only out of combat and only when
-- the string changes. The in-combat / out-of-combat Frame Fade split is swept on
-- the combat edges for these frames, which DandersFrames' own sweep never walks.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "C_Timer", "RegisterUnitWatch", "RegisterStateDriver",
                     "ClickCastFrames", "UnitGUID", "UnitExists", "UnitHasVehicleUI", "IsInInstance", "LibStub" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local appearance = {}
local DF = { PartyDefaults = {}, registered = {} }
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
function DF:InitStandaloneFrame(f, db) f.dfStandalone = true; f.dfDB = db; return f end
function DF:RegisterRangeFrame() end
function DF:UpdateFrameAppearance(f) appearance[f.dfUFUnit] = (appearance[f.dfUFUnit] or 0) + 1 end
for _, name in ipairs({ "FullFrameRefresh", "UpdateTextDesigner", "UpdateRange", "ApplyFrameLayout" }) do
    DF[name] = function() end
end

C_Timer = { After = function(_, fn) fn() end, NewTicker = function() return { Cancel = function() end } end }
RegisterUnitWatch = function() end
local drivers = {}
RegisterStateDriver = function(f, state, cond) drivers[#drivers + 1] = { f = f, state = state, cond = cond } end
ClickCastFrames = {}
UnitGUID = function() return nil end
UnitExists = function(u) return u == "player" end
UnitHasVehicleUI = function() return false end
local inInstance = false
IsInInstance = function() return inInstance end
LibStub = nil

CreateFrame = function(kind, name, parent, template)
    local f = setmetatable(FakeUIFrame(0, 0), nil)
    f._name, f._attrs, f._events, f._hooks = name, {}, {}, {}
    f:SetFakeParent(parent)
    function f:GetName() return self._name end
    function f:SetAttribute(k, v) self._attrs[k] = v end
    function f:RegisterEvent(ev) self._events[ev] = true end
    function f:RegisterUnitEvent(ev) self._events[ev] = true end
    function f:UnregisterEvent(ev) self._events[ev] = nil end
    function f:HookScript() end
    function f:SetScale(s) self._scale = s end
    return f
end

DandersFrames = DF
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("Units.lua", UF)
local Units = UF.Units
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }

local function stored(unit) return UF:GetStoredUnit(unit) end
local function reset(unit)
    local s = stored(unit)
    for k in pairs(s) do if k:sub(1, 3) == "vis" then s[k] = nil end end
end

print("-- The macro: defaults")
for _, unit in ipairs({ "player", "target", "targettarget", "focus", "pet" }) do
    eq(Units:VisibilityMacro(unit), "[petbattle] hide; show", unit .. ": shown, hidden in pet battles")
end

print("-- The macro: Show When conditions")
stored("target").visAlways = false
eq(Units:VisibilityMacro("target"), "[petbattle] hide; hide", "Always off, nothing ticked: never shown")
stored("target").visCombat = true
stored("target").visSolo = true
eq(Units:VisibilityMacro("target"), "[petbattle] hide; [combat] show; [nogroup] show; hide",
   "any ticked condition shows it, everything else hides")
stored("target").visNoCombat, stored("target").visGroup = true, true
eq(Units:VisibilityMacro("target"),
   "[petbattle] hide; [combat] show; [nocombat] show; [group] show; [nogroup] show; hide", "all four")
reset("target")
stored("target").visAlways, stored("target").visInstance = false, true
inInstance = false
eq(Units:VisibilityMacro("target"), "[petbattle] hide; hide", "In an Instance, outside one: hidden")
inInstance = true
eq(Units:VisibilityMacro("target"), "[petbattle] hide; show", "...inside one: shown")
inInstance = false
reset("target")
stored("target").visAlways, stored("target").visHasTarget = false, true
eq(Units:VisibilityMacro("target"), "[petbattle] hide; hide", "Have a Target is the player frame's alone")
stored("player").visAlways, stored("player").visHasTarget, stored("player").visHasEnemyTarget = false, true, true
eq(Units:VisibilityMacro("player"), "[petbattle] hide; [@target,exists] show; [@target,harm] show; hide",
   "player: Have a Target / Have a Hostile Target")
reset("player"); reset("target")

print("-- The macro: Hide When rules come first")
stored("pet").visHidePetBattle = false
eq(Units:VisibilityMacro("pet"), "show", "pet battle unticked: no pet-battle rule")
stored("pet").visHideMounted, stored("pet").visHideSkyriding = true, true
eq(Units:VisibilityMacro("pet"), "[mounted] hide; [bonusbar:5] hide; show", "mounted, skyriding")
stored("pet").visHideVehicle = true
eq(Units:VisibilityMacro("pet"), "[mounted] hide; [bonusbar:5] hide; show", "In a Vehicle is the player's alone")
stored("player").visHideVehicle = true
eq(Units:VisibilityMacro("player"), "[petbattle] hide; [vehicleui] hide; show", "player: In a Vehicle")
reset("pet"); reset("player")

print("-- ApplyVisibility: registered on the unit's holder, once per change")
drivers = {}
Units:Spawn("focus")
local FC = UF.frames.focus
local H = Units.holders.focus
eq(#drivers, 1, "spawn registers the driver")
eq(drivers[1].f, H, "...on the focus holder, not the button (the unit watch owns the button)")
eq(drivers[1].state, "visibility", "...as the visibility state")
Units:ApplyVisibility(FC)
eq(#drivers, 1, "same string: not registered again")
stored("focus").visHideMounted = true
IN_COMBAT = true
Units:ApplyVisibility(FC)
eq(#drivers, 1, "in combat: waits")
check(UF:IsQueued("visibility:focus"), "...queued for combat end")
IN_COMBAT = false
UF:FlushCombatQueue()
eq(#drivers, 2, "combat over: registered")
eq(drivers[2].cond, "[petbattle] hide; [mounted] hide; show", "...with the new string")

print("-- Rebuilt on zone changes (In an Instance) and on every settings refresh")
stored("focus").visAlways, stored("focus").visInstance = false, true
inInstance = true
Units:OnDriverEvent("PLAYER_ENTERING_WORLD")
eq(drivers[#drivers].cond, "[petbattle] hide; [mounted] hide; show", "entering an instance: shown")
inInstance = false
Units:OnDriverEvent("ZONE_CHANGED_NEW_AREA")
eq(drivers[#drivers].cond, "[petbattle] hide; [mounted] hide; hide", "leaving it: hidden")
reset("focus")
UF:RefreshAll()
eq(drivers[#drivers].cond, "[petbattle] hide; show", "a settings refresh applies the page's change")

print("-- Frame Fade split: swept on the combat edges")
FC:Show()
appearance = {}
Units:OnDriverEvent("PLAYER_REGEN_DISABLED")
eq(appearance.focus, nil, "split off: nothing to do")
stored("focus").frameFadeSplitCombat = true
Units:OnDriverEvent("PLAYER_REGEN_DISABLED")
eq(appearance.focus, 1, "split on: the frame's appearance re-applied entering combat")
Units:OnDriverEvent("PLAYER_REGEN_ENABLED")
eq(appearance.focus, 2, "...and leaving it")
FC:Hide()
Units:OnDriverEvent("PLAYER_REGEN_ENABLED")
eq(appearance.focus, 2, "a hidden frame is skipped")
stored("focus").frameFadeSplitCombat = nil

print("-- Defaults: every key the page draws has one")
local UD = UF.UnitDefaults.player
for _, key in ipairs({ "visAlways", "visCombat", "visNoCombat", "visGroup", "visSolo", "visInstance",
                       "visHasTarget", "visHasEnemyTarget", "visHidePetBattle", "visHideVehicle",
                       "visHideMounted", "visHideSkyriding" }) do
    check(UD[key] ~= nil, "default for " .. key)
end
eq(UD.visAlways, true, "Always on by default")
eq(UD.visHidePetBattle, true, "hidden in pet battles by default")

print("-- The page")
local data = {}
load_options_file_into("UnitFrames/PageData.lua", data)
local rec
for _, r in ipairs(DF.UnitFramePageData.pages) do if r.kind == "visibility" then rec = r end end
check(rec ~= nil and not rec.later, "Visibility is a built page now")
eq(rec and rec.units.targettarget, nil, "no Visibility page for target of target")
eq(rec and rec.units.boss, nil, "...nor for boss (its frames come later)")
check(rec and rec.hide.visHasTarget.target, "Have a Target hidden off the player")
local src = options_file_source("UnitFrames/Pages.lua")
check(src:find("function UFO.BuildVisibilityPage", 1, true), "the page has a builder")
check(src:find('rec.kind == "visibility" then', 1, true), "...dispatched from the page builder")
check(not src:find('"visHealthMissing"', 1, true), "Health Below Full is not drawn (secret health)")
check(not src:find('"visHideHousing"', 1, true), "In Player Housing is not drawn (no macro condition)")
check(src:find('w.disableOn = AlwaysOn', 1, true), "Show When conditions grey out while Always is ticked")

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
DandersFrames = G.DandersFrames
IN_COMBAT = false
