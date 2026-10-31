local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- UNITS
-- DandersFrames_UnitFrames/Units.lua
-- ------------------------------------------------------------
-- Spawning (standalone init, unit attributes, unit watch, click-casting, range),
-- per-unit event registration while shown, dispatch into DF's updaters, the
-- target-of-target ticker, the vehicle swap and the no-mover position fallback.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "C_Timer", "RegisterUnitWatch", "RegisterStateDriver",
                     "ClickCastFrames", "UnitGUID", "UnitExists", "UnitHasVehicleUI", "issecretvalue",
                     "LibStub" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- ---- DF stub: every updater counts its calls per frame ----
local count = {}
local function bump(name, f)
    local key = name .. ":" .. tostring(f and f.dfUFUnit)
    count[key] = (count[key] or 0) + 1
end
local function n(name, unit) return count[name .. ":" .. unit] or 0 end

local DF = { PartyDefaults = { frameWidth = 125 }, registered = {}, standalone = {}, ranged = {} }
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
function DF:InitStandaloneFrame(f, db) self.standalone[f] = db; f.dfStandalone = true; f.dfDB = db; return f end
function DF:RegisterRangeFrame(f) self.ranged[f] = true end
for _, name in ipairs({ "FullFrameRefresh", "UpdateHealthFast", "UpdatePower", "UpdateAbsorb", "UpdateHealAbsorb",
                        "UpdateHealPrediction", "UpdateAuras", "UpdateDefensiveBar", "UpdateDispelOverlay",
                        "UpdateName", "UpdateFrameBorderUnitColor", "UpdateUnitFrame", "UpdateHighlights",
                        "UpdateRaidTargetIcon", "UpdateRange", "ApplyFrameLayout", "ApplyResourceBarLayout",
                        "UpdateReducedMaxHealth" }) do
    DF[name] = function(_, f) bump(name, f) end
end
local tdHints = {}
function DF:UpdateTextDesigner(f, hint)
    bump("TD", f)
    tdHints[#tdHints + 1] = tostring(f.dfUFUnit) .. ":" .. tostring(hint)
end

-- ---- client stubs ----
local timers, tickers = {}, {}
C_Timer = {
    After = function(_, fn) timers[#timers + 1] = fn end,
    NewTicker = function(interval, fn)
        local t = { interval = interval, fn = fn, cancelled = false }
        function t:Cancel() self.cancelled = true end
        tickers[#tickers + 1] = t
        return t
    end,
}
local function runTimers()
    local list = timers
    timers = {}
    for _, fn in ipairs(list) do fn() end
end

local watched, drivers = {}, {}
RegisterUnitWatch = function(f) watched[f] = true end
RegisterStateDriver = function(f, state, cond) drivers[#drivers + 1] = { f = f, state = state, cond = cond } end
ClickCastFrames = {}
local guids = {}
UnitGUID = function(u) return guids[u] end
local exists = { player = true }
UnitExists = function(u) return exists[u] and true or false end
local inVehicle = false
UnitHasVehicleUI = function() return inVehicle end
local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
issecretvalue = function(v) return v == SECRET end
LibStub = nil     -- no DandersMover: the fallback position path

local created = {}
CreateFrame = function(kind, name, parent, template)
    -- FakeUIFrame's methods, WITHOUT its catch-all __index: a real frame answers nil
    -- for a field nobody set, and this module tests plenty of them (f.unit,
    -- f.dfUFTicker, ...). A missing method errors here instead of passing silently.
    local f = setmetatable(FakeUIFrame(0, 0), nil)
    f._kind, f._name, f._template, f._shown = kind, name, template, true
    f._attrs, f._events, f._hooks = {}, {}, {}
    f:SetFakeParent(parent)
    function f:GetName() return self._name end
    function f:SetAttribute(k, v) self._attrs[k] = v end
    function f:GetAttribute(k) return self._attrs[k] end
    function f:RegisterEvent(ev) self._events[ev] = { "*" } end
    function f:RegisterUnitEvent(ev, ...) self._events[ev] = { ... } end
    function f:UnregisterEvent(ev) self._events[ev] = nil end
    function f:HookScript(name2, fn)
        self._hooks[name2] = self._hooks[name2] or {}
        table.insert(self._hooks[name2], fn)
    end
    local function fire(self, name2)
        for _, fn in ipairs(self._hooks[name2] or {}) do fn(self) end
    end
    function f:Show() if not self._shown then self._shown = true; fire(self, "OnShow") end end
    function f:Hide() if self._shown then self._shown = false; fire(self, "OnHide") end end
    function f:SetScale(s) self._scale = s end
    created[#created + 1] = f
    return f
end

DandersFrames = DF
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("Units.lua", UF)
local Units = UF.Units

DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }

print("-- Driver")
check(Units.driver ~= nil, "a shared listener for unitless events")
check(Units.driver._events.PLAYER_TARGET_CHANGED ~= nil, "...PLAYER_TARGET_CHANGED")
eq(Units.driver._events.UNIT_TARGET and table.concat(Units.driver._events.UNIT_TARGET, ","), "target,focus",
   "...UNIT_TARGET, for the target and the focus only")
do
    local UNITS = uf_file_source("Units.lua"):gsub("\r\n", "\n")
    local drv = UNITS:match("local driver = CreateFrame%(\"Frame\"%)(.-)driver:SetScript")
    check(drv and not drv:find("driver:RegisterEvent(", 1, true) and drv:find("pcall(driver.RegisterEvent, driver, ev)", 1, true),
          "every unitless event registers through its own pcall (a client without one loses only that one)")
end

print("-- Spawn: not in combat")
IN_COMBAT = true
eq(Units:Spawn("player"), nil, "in combat: no secure frame made")
eq(UF.frames.player, nil, "...none recorded")
IN_COMBAT = false

print("-- Spawn: source")
UF:GetUnitDB("targettarget").source = "Blizzard"
Units:SpawnAll()
check(UF.frames.player and UF.frames.target, "player and target spawned")
eq(UF.frames.targettarget, nil, "a Blizzard-sourced unit is not spawned")
UF:GetUnitDB("targettarget").source = "Hidden"
Units:SpawnAll()
eq(UF.frames.targettarget, nil, "nor a hidden one")
UF:GetUnitDB("targettarget").source = nil
Units:SpawnAll()
check(UF.frames.targettarget ~= nil, "back to DF: spawned")
local before = #created
Units:SpawnAll()
eq(#created, before, "spawning twice makes nothing new")

local P, T, TT = UF.frames.player, UF.frames.target, UF.frames.targettarget

print("-- Standalone init")
for unit, f in pairs({ player = P, target = T, targettarget = TT }) do
    eq(DF.standalone[f], UF:GetUnitDB(unit), unit .. ": InitStandaloneFrame with the unit's own table")
    eq(f.dfDB, UF:GetUnitDB(unit), unit .. ": GetFrameDB answers the unit table")
    eq(f._template, "DandersUnitButtonTemplate,SecureUnitButtonTemplate", unit .. ": DF's button template")
    eq(f._attrs.unit, unit, unit .. ": unit attribute")
    eq(f.unit, unit, unit .. ": .unit")
    eq(f.dfUFUnit, unit, unit .. ": knows its unit")
    eq(ClickCastFrames[f], true, unit .. ": registered for click-casting")
    eq(f.dfTextPresetOverride, UF:GetUnitDB(unit).textDesignerPreset, unit .. ": text preset stamped")
    check(n("ApplyFrameLayout", unit) >= 1, unit .. ": laid out from its own table")
end
eq(P._attrs.toggleForVehicle, true, "player: clicks follow the vehicle")
eq(T._attrs.toggleForVehicle, nil, "target: no vehicle toggle")
eq(watched[P], nil, "player: no unit watch")
eq(watched[T], true, "target: unit watch")
eq(watched[TT], true, "target of target: unit watch")
eq(DF.ranged[T], true, "target: in the range tick")
eq(DF.ranged[TT], true, "target of target: in the range tick")
eq(DF.ranged[P], nil, "player: not (always in range)")
eq(P:GetParent(), Units.holders.player, "parented to the unit's own holder")
eq(Units.holders.player:GetParent(), Units.parent, "...which sits in the unit-frames parent")
local vis = {}
for _, d in ipairs(drivers) do if d.f == Units.holders.player then vis[#vis + 1] = d end end
eq(vis[1] and vis[1].cond, "[petbattle] hide; show", "the player's holder: hidden in pet battles, else shown")
eq(vis[1] and vis[1].state, "visibility", "...as a visibility state driver")

print("-- Position without DandersMover")
local pt = P._points[#P._points]
check(pt ~= nil, "player positioned")
if pt then
    eq(pt[1], "CENTER", "point from the record")
    eq(pt[2], UIParent, "relative to UIParent")
    eq(pt[3], "CENTER", "...its centre")
    eq(pt[4], -280, "x from the record")
    eq(pt[5], -200, "y from the record")
end
local tpt = TT._points[#TT._points]
eq(tpt and tpt[4], 496, "target of target: the record's x, anchor ignored")

print("-- Events: registered only while shown")
local evs = Units:EventsFor("player")
eq(P._events.UNIT_HEALTH and table.concat(P._events.UNIT_HEALTH, ","), "player,vehicle", "player: player and vehicle")
for _, ev in ipairs(evs) do
    check(P._events[ev] ~= nil, "player registered " .. ev)
end
check(P._events.UNIT_ENTERED_VEHICLE ~= nil, "player: vehicle events")
eq(next(T._events), nil, "target hidden at spawn: no events")
T:Show()
eq(T._events.UNIT_HEALTH and table.concat(T._events.UNIT_HEALTH, ","), "target", "target shown: its own unit only")
eq(T._events.UNIT_ENTERED_VEHICLE, nil, "...no vehicle events")
check(n("FullFrameRefresh", "target") >= 1, "shown: full repaint")
T:Hide()
eq(next(T._events), nil, "hidden again: unregistered")
eq(#Units:EventsFor("targettarget"), 0, "target of target has no events")

print("-- Dispatch")
T:Show()
count = {}
tdHints = {}
Units.OnEvent(T, "UNIT_HEALTH", "target")
eq(n("UpdateHealthFast", "target"), 1, "UNIT_HEALTH -> UpdateHealthFast")
eq(tdHints[1], "target:health", "...and Text Designer health")
Units.OnEvent(T, "UNIT_POWER_UPDATE", "target")
eq(n("UpdatePower", "target"), 1, "power -> UpdatePower")
Units.OnEvent(T, "UNIT_AURA", "target")
eq(n("UpdateAuras", "target"), 1, "aura -> UpdateAuras")
eq(n("UpdateDispelOverlay", "target"), 1, "...dispel overlay")
Units.OnEvent(T, "UNIT_ABSORB_AMOUNT_CHANGED", "target")
eq(n("UpdateAbsorb", "target"), 1, "absorb")
Units.OnEvent(T, "UNIT_FACTION", "target")
eq(n("UpdateUnitFrame", "target"), 1, "faction -> colours")
count = {}
Units.OnEvent(T, "UNIT_MAXHEALTH", "target")
eq(n("UpdateHealthFast", "target"), 1, "max health: painted now")
runTimers()
eq(n("UpdateHealthFast", "target"), 2, "...and again one frame later")
count = {}
T._shown = false
Units.OnEvent(T, "UNIT_HEALTH", "target")
eq(n("UpdateHealthFast", "target"), 0, "a hidden frame ignores events")
T._shown = true
count = {}
Units.OnEvent(P, "UNIT_HEALTH", "vehicle")
eq(n("UpdateHealthFast", "player"), 0, "player frame: vehicle events ignored while showing the player")

print("-- Vehicle")
inVehicle, exists.vehicle = true, true
Units.OnEvent(P, "UNIT_ENTERED_VEHICLE", "player")
eq(P.unit, "vehicle", "entering a vehicle: the frame shows it")
count = {}
runTimers()
eq(n("FullFrameRefresh", "player"), 1, "...repainted once")
Units.OnEvent(P, "UNIT_HEALTH", "vehicle")
eq(n("UpdateHealthFast", "player"), 1, "...and follows the vehicle's events")
inVehicle, exists.vehicle = true, false
Units:UpdateVehicle(P)
eq(P.unit, "player", "a vehicle UI with no vehicle unit (furniture): stays on the player")
inVehicle = false
Units:UpdateVehicle(P)
eq(P.unit, "player", "out of the vehicle: the player")

print("-- Target of target ticker")
tickers = {}
guids.targettarget = "G1"
count = {}
TT:Show()
eq(#tickers, 1, "shown: a ticker starts")
eq(tickers[1] and tickers[1].interval, UF.TOT_INTERVAL, "...at the polling interval")
check(UF.TOT_INTERVAL >= 0.2 and UF.TOT_INTERVAL <= 0.5, "interval within 0.2-0.5 s")
eq(n("FullFrameRefresh", "targettarget"), 1, "shown: ONE full repaint (the ticker start's; OnShow does not add a second)")
count = {}
tickers[1].fn()
eq(n("FullFrameRefresh", "targettarget"), 0, "same GUID: no full repaint")
eq(n("UpdateHealthFast", "targettarget"), 1, "...values only")
eq(n("UpdatePower", "targettarget"), 1, "...values only")
guids.targettarget = "G2"
count = {}
tickers[1].fn()
eq(n("FullFrameRefresh", "targettarget"), 1, "GUID changed: full repaint")
guids.targettarget = SECRET
count = {}
tickers[1].fn()
tickers[1].fn()
eq(n("FullFrameRefresh", "targettarget"), 0, "a secret GUID: no full repaint (no portrait reset / aura rebuild per tick)")
eq(n("UpdateUnitFrame", "targettarget"), 2, "...but name / health / colours repaint every tick")
count = {}
Units:OnDriverEvent("UNIT_TARGET", "target")
eq(n("FullFrameRefresh", "targettarget"), 1, "secret GUID + a real change signal (UNIT_TARGET): full repaint")
count = {}
tickers[1].fn()
eq(n("FullFrameRefresh", "targettarget"), 0, "...and the next secret tick is light again")
guids.targettarget = "G2"
count = {}
tickers[1].fn()
eq(n("FullFrameRefresh", "targettarget"), 1, "readable again: compared afresh, full repaint")
count = {}
tickers[1].fn()
eq(n("FullFrameRefresh", "targettarget"), 0, "...then values only")
TT:Show()
eq(#tickers, 1, "showing again does not start a second ticker")
TT:Hide()
eq(tickers[1].cancelled, true, "hidden: ticker cancelled")
eq(TT.dfUFTicker, nil, "...and dropped")
guids.targettarget = "G3"
count = {}
TT:Show()
eq(#tickers, 2, "shown again: a fresh ticker")
check(n("FullFrameRefresh", "targettarget") >= 1, "...with an identity repaint")

print("-- Unitless events")
count = {}
Units:OnDriverEvent("PLAYER_TARGET_CHANGED")
eq(n("FullFrameRefresh", "target"), 1, "target changed: target repainted")
eq(n("FullFrameRefresh", "targettarget"), 1, "...and target of target")
eq(n("UpdateHighlights", "player"), 1, "...selection highlight on every shown frame")
count = {}
Units:OnDriverEvent("UNIT_TARGET", "target")
eq(n("FullFrameRefresh", "targettarget"), 1, "the target's target changed: target of target repainted")
count = {}
Units:OnDriverEvent("UNIT_TARGET", "party1")
eq(n("FullFrameRefresh", "targettarget"), 0, "someone else's target: ignored")
count = {}
Units:OnDriverEvent("RAID_TARGET_UPDATE")
eq(n("UpdateRaidTargetIcon", "player"), 1, "raid marks: every shown frame")

print("-- Layout")
UF:GetUnitDB("player").frameScale = 1.5
IN_COMBAT = true
P._scale = nil
Units:ApplyLayout(P)
eq(P._scale, nil, "in combat: layout skipped (callers queue it)")
IN_COMBAT = false
Units:ApplyLayout(P)
eq(P._scale, 1.5, "scale from the unit's table")

print("-- Focus and pet: spawned like the others")
local FC, PT = UF.frames.focus, UF.frames.pet
check(FC ~= nil and PT ~= nil, "focus and pet spawned")
eq(FC and FC._name, "DandersUnitFrameFocus", "focus: its global name")
eq(PT and PT._name, "DandersUnitFramePet", "pet: its global name")
eq(FC._attrs.unit, "focus", "focus: unit attribute")
eq(PT._attrs.unit, "pet", "pet: unit attribute")
eq(watched[FC], true, "focus: unit watch (shown only while you have one)")
eq(watched[PT], true, "pet: unit watch")
eq(DF.ranged[FC], true, "focus: in the range tick")
eq(DF.ranged[PT], true, "pet: in the range tick")
eq(FC._attrs.toggleForVehicle, nil, "focus: no vehicle toggle")
eq(PT._attrs.toggleForVehicle, true, "pet: clicks follow the vehicle swap")
eq(FC:GetParent(), Units.holders.focus, "focus: its own holder")
eq(PT:GetParent(), Units.holders.pet, "pet: its own holder")
eq(ClickCastFrames[FC], true, "focus: click-casting")
eq(DF.standalone[PT], UF:GetUnitDB("pet"), "pet: standalone on its own table")

print("-- Focus: events and PLAYER_FOCUS_CHANGED")
FC:Show()
eq(FC._events.UNIT_HEALTH and table.concat(FC._events.UNIT_HEALTH, ","), "focus", "focus shown: its own unit only")
eq(FC._events.UNIT_PET, nil, "...no pet events")
check(Units.driver._events.PLAYER_FOCUS_CHANGED ~= nil, "the driver listens for focus changes")
count = {}
Units:OnDriverEvent("PLAYER_FOCUS_CHANGED")
eq(n("FullFrameRefresh", "focus"), 1, "focus changed: focus repainted")
eq(n("FullFrameRefresh", "target"), 0, "...the target is not")
FC:Hide()
eq(next(FC._events), nil, "focus hidden: unregistered")

print("-- Focus target (v1.1): target of target's pattern on focus")
local FT = UF.frames.focustarget
check(FT ~= nil, "focus target spawned")
eq(FT and FT._name, "DandersUnitFrameFocusTarget", "focus target: its global name")
eq(FT._attrs.unit, "focustarget", "focus target: unit attribute")
eq(watched[FT], true, "focus target: unit watch (shown only while the focus has a target)")
eq(DF.ranged[FT], true, "focus target: in the range tick")
eq(FT:GetParent(), Units.holders.focustarget, "focus target: its own holder")
eq(DF.standalone[FT], UF:GetUnitDB("focustarget"), "focus target: standalone on its own table")
eq(#Units:EventsFor("focustarget"), 0, "focus target: no events of its own (polled)")
check(UF:GetUnitDB("focustarget").position.anchor.target == "DandersFrames_UnitFrames:focus.outer",
      "focus target: anchored to the focus frame (portrait included) by default")
tickers = {}
guids.focustarget = "F1"
count = {}
FT:Show()
eq(#tickers, 1, "focus target shown: a ticker starts")
eq(next(FT._events), nil, "...and no unit events are registered")
count = {}
tickers[1].fn()
eq(n("FullFrameRefresh", "focustarget"), 0, "same GUID: no full repaint")
eq(n("UpdateHealthFast", "focustarget"), 1, "...values only")
guids.focustarget = "F2"
count = {}
tickers[1].fn()
eq(n("FullFrameRefresh", "focustarget"), 1, "GUID changed: full repaint")
count = {}
Units:OnDriverEvent("PLAYER_FOCUS_CHANGED")
eq(n("FullFrameRefresh", "focustarget"), 1, "focus changed: the focus target is re-polled at once")
count = {}
Units:OnDriverEvent("UNIT_TARGET", "focus")
eq(n("FullFrameRefresh", "focustarget"), 1, "the focus's target changed: focus target repainted")
eq(n("FullFrameRefresh", "targettarget"), 0, "...not the target of target")
count = {}
Units:OnDriverEvent("UNIT_TARGET", "target")
eq(n("FullFrameRefresh", "focustarget"), 0, "the target's target changed: the focus target is left alone")
FT:Hide()
eq(tickers[1].cancelled, true, "focus target hidden: ticker cancelled")
eq(FT.dfUFTicker, nil, "...and dropped")

print("-- Pet: events and the vehicle swap")
inVehicle, exists.vehicle = false, false
PT:Show()
eq(PT._events.UNIT_HEALTH and table.concat(PT._events.UNIT_HEALTH, ","), "pet,player", "pet: pet and player")
eq(PT._events.UNIT_PET and table.concat(PT._events.UNIT_PET, ","), "pet,player", "pet: UNIT_PET (owner's)")
check(PT._events.UNIT_ENTERED_VEHICLE ~= nil, "pet: vehicle events")
eq(PT.unit, "pet", "out of a vehicle: the pet frame shows the pet")
eq(Units:DisplayUnit("pet"), "pet", "DisplayUnit(pet) = pet")
count = {}
Units.OnEvent(PT, "UNIT_HEALTH", "player")
eq(n("UpdateHealthFast", "pet"), 0, "...the player's events are ignored then")
inVehicle, exists.vehicle = true, true
eq(Units:DisplayUnit("player"), "vehicle", "in a vehicle: player shows the vehicle")
eq(Units:DisplayUnit("pet"), "player", "...and pet shows the player (Blizzard's swap)")
eq(Units:DisplayUnit("target"), "target", "...other units are untouched")
Units.OnEvent(PT, "UNIT_ENTERED_VEHICLE", "player")
eq(PT.unit, "player", "entering a vehicle: the pet frame shows the player")
count = {}
runTimers()
eq(n("FullFrameRefresh", "pet"), 1, "...repainted once")
Units.OnEvent(PT, "UNIT_HEALTH", "player")
eq(n("UpdateHealthFast", "pet"), 1, "...and follows the player's events")
Units.OnEvent(P, "UNIT_ENTERED_VEHICLE", "player")
eq(P.unit, "vehicle", "the player frame swaps on the same event")
inVehicle, exists.vehicle = false, false
Units.OnEvent(PT, "UNIT_EXITED_VEHICLE", "player")
Units.OnEvent(P, "UNIT_EXITED_VEHICLE", "player")
eq(PT.unit, "pet", "out again: pet frame back on the pet")
eq(P.unit, "player", "...player frame back on the player")
runTimers()
count = {}
Units.OnEvent(PT, "UNIT_PET", "player")
runTimers()
eq(n("FullFrameRefresh", "pet"), 1, "a new pet: full repaint")
count = {}
Units.OnEvent(PT, "UNIT_PET", "party1")
runTimers()
eq(n("FullFrameRefresh", "pet"), 0, "someone else's pet: ignored")
PT:Hide()

print("-- Elements: the frame's lifecycle reaches them (Elements.lua)")
local calls = {}
UF.Elements = { Call = function(_, method, f, ...)
    local extra = (select("#", ...) > 0) and (":" .. tostring((...))) or ""
    calls[#calls + 1] = method .. ":" .. tostring(f and f.dfUFUnit) .. extra
end }
UF.frames.focus = nil      -- spawned again, now with the elements in place
local F2 = Units:Spawn("focus")
check(table.concat(calls, ","):find("Attach:focus", 1, true) == 1, "spawn: Attach first")
check(table.concat(calls, ","):find("Layout:focus", 1, true), "...then Layout")
calls = {}
F2:Show()
local seq = table.concat(calls, ",")
check(seq:find("SetActive:focus:true", 1, true), "shown: SetActive(true)")
check(seq:find("Refresh:focus", 1, true), "...and a full refresh reaches Refresh")
calls = {}
Units.OnEvent(F2, "UNIT_FACTION", "focus")
eq(calls[1], "OnUnitEvent:focus:UNIT_FACTION", "a unit event reaches OnUnitEvent")
calls = {}
F2:Hide()
eq(calls[1], "SetActive:focus:false", "hidden: SetActive(false)")
calls = {}
Units:OnDriverEvent("PLAYER_REGEN_DISABLED")
local regen = false
for _, c in ipairs(calls) do if c == "OnUnitEvent:player:PLAYER_REGEN_DISABLED" then regen = true end end
check(regen, "combat edges reach the shown frames' elements")
UF.Elements = nil

-- By NAME, not pairs(G): a global that was nil before is skipped by pairs and
-- would leak this file's stub into every later suite.
for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
IN_COMBAT = false
