local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- CLASS POWER
-- DandersFrames_UnitFrames/ClassPower.lua
-- ------------------------------------------------------------
-- The class / spec / form resource map, one StatusBar per pip with min/max
-- (i-1, i) all fed the SAME raw value (secret or not), Destruction's fragments,
-- charged combo points, runes off duration objects, stagger hidden while secret,
-- a spec change rebuilding the pips, events for the player only, attach /
-- detach and the preview's half-full sample.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "C_Timer", "issecretvalue", "LibStub", "UnitClass",
                     "GetSpecialization", "GetSpecializationInfo", "GetShapeshiftFormID", "UnitPower",
                     "UnitPowerMax", "GetUnitChargedPowerPoints", "GetRuneCooldown", "UnitStagger",
                     "UnitHealthMax", "C_DurationUtil", "GetTime", "RAID_CLASS_COLORS", "PowerBarColor",
                     "C_CurveUtil", "UnitAffectingCombat", "InCombatLockdown" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end
local ENUM_HELD = { PowerType = Enum.PowerType, StatusBarTimerDirection = Enum.StatusBarTimerDirection,
                    StatusBarInterpolation = Enum.StatusBarInterpolation }

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local secrets = setmetatable({}, { __mode = "k" })
local function trap(name) return function() error("secret used in " .. name, 2) end end
local SECRET_MT = { __add = trap("+"), __sub = trap("-"), __mul = trap("*"), __div = trap("/"),
                    __lt = trap("<"), __le = trap("<="), __concat = trap(".."), __len = trap("#") }
local function Secret(label)
    local t = setmetatable({ label = label }, SECRET_MT)
    secrets[t] = true
    return t
end
issecretvalue = function(v) return type(v) == "table" and secrets[v] == true end

local RECORDED = { "SetMinMaxValues", "SetValue", "SetStatusBarTexture", "SetStatusBarColor", "SetTimerDuration" }
local function Make(kind, parent)
    local f = setmetatable(FakeUIFrame(0, 0), nil)
    f._kind, f._shown, f._last, f._events = kind, true, {}, {}
    f:SetFakeParent(parent)
    for _, name in ipairs(RECORDED) do
        f[name] = function(self, ...) self._last[name] = { ... } end
    end
    function f:SetParent(p) self:SetFakeParent(p) end
    function f:RegisterUnitEvent(ev, ...) self._events[ev] = { ... } end
    function f:RegisterEvent(ev) self._events[ev] = { "*" } end
    function f:UnregisterEvent(ev) self._events[ev] = nil end
    function f:CreateTexture() return Make("Texture", self) end
    function f:CreateFontString() return Make("FontString", self) end
    return f
end
CreateFrame = function(kind, _, parent) return Make(kind, parent) end
C_Timer = { After = function(_, fn) fn() end }
GetTime = function() return 50 end

Enum.PowerType = { ComboPoints = 4, HolyPower = 9, SoulShards = 7, Essence = 19, Chi = 12, ArcaneCharges = 16, Runes = 5 }
Enum.StatusBarTimerDirection = { ElapsedTime = 0, RemainingTime = 1 }
Enum.StatusBarInterpolation = { Immediate = 0 }
local class, spec, form = "ROGUE", 259, 0
UnitClass = function() return "x", class end
GetSpecialization = function() return 1 end
GetSpecializationInfo = function() return spec end
GetShapeshiftFormID = function() return form end
local power, maxPower, powerArgs = 3, 5, nil
UnitPower = function(u, pt, frag) powerArgs = { u, pt, frag }; return power end
UnitPowerMax = function() return maxPower end
local charged = nil
GetUnitChargedPowerPoints = function() return charged end
local runes = {}
GetRuneCooldown = function(i) local r = runes[i] or { 0, 0, true }; return r[1], r[2], r[3] end
local stagger, hpMax = 0, 100
UnitStagger = function() return stagger end
UnitHealthMax = function() return hpMax end
RAID_CLASS_COLORS = { ROGUE = { r = 1, g = 0.96, b = 0.41 }, DEATHKNIGHT = { r = 0.77, g = 0.12, b = 0.23 } }
PowerBarColor = { COMBO_POINTS = { r = 1, g = 0.9, b = 0 } }
C_DurationUtil = { CreateDuration = function()
    return { SetTimeFromStart = function(self, s, d) self.s, self.d = s, d end }
end }
C_CurveUtil = { EvaluateColorValueFromBoolean = function(flag, t, f)
    if issecretvalue(flag) then return Secret("picked") end
    return flag and t or f
end }
LibStub = nil

local DF = { PartyDefaults = { frameWidth = 125, frameHeight = 40 }, registered = {} }
function DF:Debug() end
function DF:DebugWarn() end
local errs = {}
function DF:DebugError(_, fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec2) self.registered[key] = spec2; return true end
function DF:SafeSetFont() end
DandersFrames = DF

local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }
load_uf_file_into("Elements.lua", UF)
load_uf_file_into("ClassPower.lua", UF)
local CP = UF.ClassPower
UF.Units = { InVehicle = function() return false end, holders = {} }

print("-- The resource map")
local function R(c, s, cat) local r = CP:Resolve(c, s, cat); return r and (r.kind .. ":" .. tostring(r.power)) or "none" end
eq(R("ROGUE", 259), "pips:ComboPoints", "Rogue: combo points")
eq(R("DRUID", 103, true), "pips:ComboPoints", "Druid in Cat Form: combo points")
eq(R("DRUID", 102, false), "none", "Druid out of Cat Form: nothing")
eq(R("PALADIN", 70), "pips:HolyPower", "Paladin: holy power")
eq(R("MONK", 269), "pips:Chi", "Windwalker: chi")
eq(R("MONK", 268), "stagger:nil", "Brewmaster: stagger")
eq(R("MONK", 270), "none", "Mistweaver: nothing")
eq(R("MAGE", 62), "pips:ArcaneCharges", "Arcane: arcane charges")
eq(R("MAGE", 63), "none", "Fire: nothing")
eq(R("EVOKER", 1467), "pips:Essence", "Evoker: essence")
eq(R("DEATHKNIGHT", 250), "runes:nil", "Death Knight: runes")
eq(R("WARLOCK", 265), "pips:SoulShards", "Warlock: soul shards")
eq(CP:Resolve("WARLOCK", 267).fragments, true, "Destruction: shard fragments")
eq(CP:Resolve("WARLOCK", 265).fragments, false, "...not Affliction")
eq(R("WARRIOR", 71), "none", "Warrior: nothing")
eq(R("HUNTER", 253), "none", "Hunter: nothing")
eq(CP:Resolve("DEATHKNIGHT", 250, nil, { classPowerRunes = false }), nil, "Death Knight Runes off: nothing")
eq(CP:Resolve("MONK", 268, nil, { classPowerStagger = false }), nil, "Brewmaster Stagger off: nothing")

print("-- Defaults")
eq(UF:GetUnitDB("player").classPowerEnabled, true, "player: class power on")
eq(UF:GetUnitDB("target").classPowerEnabled, false, "others: off (player only)")

print("-- Attach: the player only")
local function Owner(unit)
    local f = Make("Button", UIParent)
    f.dfUFUnit, f.unit = unit, unit
    f.dfDB = UF:GetUnitDB(unit)
    return f
end
local T = Owner("target")
CP:Attach(T)
eq(T.dfUFClassPower, nil, "target: none")
local P = Owner("player")
CP:Attach(P)
local cp = P.dfUFClassPower
check(cp ~= nil and cp.listener ~= nil, "player: class power with its own listener")

print("-- Pips: one StatusBar each, min/max (i-1, i), the same value into all")
local db = UF:GetUnitDB("player")
db.frameWidth = 208
local secretPower = Secret("power")
power = secretPower
local ok, err = pcall(CP.Layout, CP, P)
check(ok, "a secret power value lays out and fills without being read (" .. tostring(err) .. ")")
eq(cp.count, 5, "five combo points (UnitPowerMax)")
for i = 1, 5 do
    local pip = cp.pips[i]
    eq(pip._kind, "StatusBar", "pip " .. i .. " is a StatusBar")
    eq(pip._last.SetMinMaxValues[1], i - 1, "pip " .. i .. ": min i-1")
    eq(pip._last.SetMinMaxValues[2], i, "pip " .. i .. ": max i")
    eq(pip._last.SetValue[1], secretPower, "pip " .. i .. ": the raw (secret) value")
end
eq(cp.pips[1]._w, (208 - 2 * 1 - 2 * 4) / 5,
    "pip width shares the frame width less the gaps, and less the 1px border drawn outside each end")
check(cp:IsShown(), "shown")
eq(powerArgs[2], 4, "read as Enum.PowerType.ComboPoints")
maxPower = Secret("max")
CP:Layout(P)
eq(cp.count, 5, "a secret max: the map's count")
maxPower = 7
CP:Layout(P)
eq(cp.count, 7, "seven when the client says seven")
for i = 6, 7 do check(cp.pips[i]:IsShown(), "pip " .. i .. " added") end
maxPower = 5
CP:Layout(P)
check(not cp.pips[6]:IsShown() and not cp.pips[7]:IsShown(), "...and dropped again")

print("-- Charged combo points")
power = 2
charged = { 2, 4 }
CP:Update(P)
eq(cp.pips[2]._last.SetStatusBarColor[1], 0.4, "pip 2 charged colour")
eq(cp.pips[4]._last.SetStatusBarColor[1], 0.4, "pip 4 charged colour")
eq(cp.pips[1]._last.SetStatusBarColor[1], 1, "pip 1 class colour")
charged = nil

print("-- Hide When Empty: only on a readable zero")
db.classPowerHideEmpty = true
power = 0
CP:Update(P)
check(not cp:IsShown(), "a plain 0: hidden")
power = Secret("zero?")
CP:Update(P)
check(cp:IsShown(), "a secret value: shown (never compared)")
db.classPowerHideEmpty = nil

print("-- Destruction: fragments")
class, spec = "WARLOCK", 267
power = Secret("fragments")
CP:Layout(P)
eq(cp.pips[1]._last.SetMinMaxValues[2], 10, "pip 1: 0..10 fragments")
eq(cp.pips[3]._last.SetMinMaxValues[1], 20, "pip 3: 20..30")
eq(powerArgs[3], true, "UnitPower asked for fragments")
eq(cp.pips[3]._last.SetValue[1], power, "the same raw value into every pip")

print("-- A spec change re-resolves")
CP:SetActive(P, true)
check(cp.listener._events.PLAYER_SPECIALIZATION_CHANGED ~= nil, "listens for spec changes")
eq(cp.listener._events.UNIT_POWER_FREQUENT and cp.listener._events.UNIT_POWER_FREQUENT[1], "player", "power: the player only")
class, spec = "MAGE", 63
CP:OnEvent(cp, "PLAYER_SPECIALIZATION_CHANGED", "player")
eq(cp.res, nil, "Fire: no resource")
check(not cp:IsShown(), "...hidden")
spec = 62
CP:OnEvent(cp, "PLAYER_SPECIALIZATION_CHANGED", "player")
eq(cp.count, 5, "Arcane: back, re-laid out")
CP:SetActive(P, false)
eq(next(cp.listener._events), nil, "frame hidden: events dropped")

print("-- Druid forms")
class, spec, form = "DRUID", 103, 0
CP:Layout(P)
check(not cp:IsShown(), "caster form: nothing")
form = 1
CP:OnEvent(cp, "UPDATE_SHAPESHIFT_FORM")
check(cp:IsShown(), "Cat Form: combo points")

print("-- Runes")
class, spec = "DEATHKNIGHT", 250
runes = { { 0, 0, true }, { 45, 10, false }, { Secret("s"), Secret("d"), Secret("ready") } }
ok, err = pcall(CP.Layout, CP, P)
check(ok, "runes lay out (" .. tostring(err) .. ")")
eq(cp.count, 6, "six runes")
eq(cp.pips[1]._last.SetValue[1], 1, "a ready rune: full")
local d = cp.pips[2]._last.SetTimerDuration and cp.pips[2]._last.SetTimerDuration[1]
check(d and d.s == 45 and d.d == 10, "a recharging rune: its own duration object (start, duration)")
check(issecretvalue(cp.pips[3]._last.SetValue[1]), "a secret rune: filled from its ready flag, picked by the client")

print("-- Stagger: a bar, hidden while secret")
class, spec = "MONK", 268
stagger, hpMax = 30, 100
CP:Layout(P)
check(cp.isSingle, "one bar")
check(cp:IsShown(), "plain values: shown")
eq(cp.single._last.SetValue[1], 30, "the stagger amount")
eq(cp.single._last.SetStatusBarColor[1], 1.0, "30% of max health: the moderate colour")
stagger = Secret("stagger")
ok, err = pcall(CP.Update, CP, P)
check(ok, "secret stagger: no maths (" .. tostring(err) .. ")")
check(not cp:IsShown(), "secret stagger: hidden")
stagger = 0

print("-- Single Bar mode")
class, spec, power, maxPower = "PALADIN", 70, Secret("hp"), 5
db.classPowerMode = "BAR"
CP:Layout(P)
check(cp.isSingle and not cp.pips[1]:IsShown(), "one bar, no pips")
eq(cp.single._last.SetMinMaxValues[2], 5, "0..max")
eq(cp.single._last.SetValue[1], power, "the raw value")
db.classPowerMode = nil

print("-- Attached / detached")
power = 3
CP:Layout(P)
local pt = cp._points[#cp._points]
eq(cp:GetParent(), P, "attached: on the frame")
eq(pt and pt[1], "BOTTOM", "...over it (Top)")
eq(pt and pt[3], "TOP", "...at its top edge")
local placed
UF.Units.holders.player = Make("Frame", UIParent)
UF.Units.PlaceAt = function(_, el, rec) placed = { el = el, rec = rec } end
db.classPowerDetached = true
CP:Layout(P)
eq(cp:GetParent(), UF.Units.holders.player, "detached: in the unit's holder")
eq(placed and placed.rec, db.classPowerPositionRecord, "...at its own record")
eq(db.classPowerPositionRecord.anchor and db.classPowerPositionRecord.anchor.edge, "top",
   "...which starts anchored over the player frame")
db.classPowerDetached = nil

print("-- In a vehicle: hidden")
UF.Units.InVehicle = function() return true end
CP:Update(P)
check(not cp:IsShown(), "vehicle: no class power")
UF.Units.InVehicle = function() return false end
CP:Update(P)
check(cp:IsShown(), "out of the vehicle: back")

print("-- Hide Out of Combat follows the PLAYER's combat, not lockdown")
-- PLAYER_REGEN_DISABLED fires before lockdown starts: reading InCombatLockdown
-- there kept the bar hidden through the pull.
db.classPowerHideOOC = true
local fighting = false
UnitAffectingCombat = function(u) return u == "player" and fighting end
InCombatLockdown = function() return false end
CP:Update(P)
check(not cp:IsShown(), "out of combat: hidden")
fighting = true
CP:Update(P)
check(cp:IsShown(), "pull (in combat, lockdown not yet on): shown")
fighting = false
InCombatLockdown = function() return true end
CP:Update(P)
check(not cp:IsShown(), "combat over, lockdown lingering: hidden")
db.classPowerHideOOC = nil
UnitAffectingCombat, InCombatLockdown = G.UnitAffectingCombat, G.InCombatLockdown

print("-- Preview: half full")
local PV = Owner("player")
PV.dfUFPreview = true
CP:Attach(PV)
eq(PV.dfUFClassPower.listener, nil, "no listener on a preview")
class, spec = "PALADIN", 70
CP:Preview(PV)
local pcp = PV.dfUFClassPower
eq(pcp.count, 5, "the player's own resource")
eq(pcp.pips[1]._last.SetValue[1], 3, "...3 of 5 filled")
check(pcp:IsShown(), "...shown")
class = "WARRIOR"
CP:Preview(PV)
eq(pcp.count, 5, "a class without one: five sample pips")
eq(#errs, 0, "no element errored (" .. tostring(errs[1]) .. ")")

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
for k, v in pairs(ENUM_HELD) do Enum[k] = v end
