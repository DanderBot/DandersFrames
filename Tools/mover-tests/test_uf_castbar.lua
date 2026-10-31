local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- CAST BAR
-- DandersFrames_UnitFrames/CastBar.lua (+ the Elements.lua kit, Mover.lua's
-- child elements)
-- ------------------------------------------------------------
-- Event registration per unit (only while shown and on), the fill handed to
-- StatusBar:SetTimerDuration (cast / channel / empower duration objects, the
-- channel draining), the timer text bound to the duration (a numeric rule
-- formatter, C-side), the not-interruptible shield on a FRAME alpha'd by
-- SetAlphaFromBoolean and the colour picked by EvaluateColorValueFromBoolean,
-- the kick tick's two invisible bars, the interrupted flash, the player-only
-- maths (latency, empower stages), attach / detach with and without the mover,
-- and a source check that nothing outside the player-only section does maths
-- on cast times or formats them with a decimal format in Lua.
--
-- ☠ SECRETS ARE TRAPS HERE: a stand-in secret errors on arithmetic, ordering
-- and concatenation, so a run that completes proves none of that happened.
-- (A boolean test cannot be trapped in Lua; the source checks cover what they can.)
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "C_Timer", "issecretvalue", "LibStub",
                     "UnitCastingInfo", "UnitChannelInfo", "UnitCastingDuration", "UnitChannelDuration",
                     "UnitEmpoweredChannelDuration", "UnitEmpoweredStagePercentages", "C_CurveUtil",
                     "C_DurationUtil", "C_StringUtil", "C_Spell", "C_SpellBook", "UnitClass", "GetNetStats",
                     "GetTime", "UnitSpellTargetName", "RAID_CLASS_COLORS", "IsPlayerSpell", "UnitExists" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end
local ENUM_HELD = { StatusBarTimerDirection = Enum.StatusBarTimerDirection,
                    StatusBarInterpolation = Enum.StatusBarInterpolation,
                    DurationTextBindingProperty = Enum.DurationTextBindingProperty }

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- ---- secret stand-ins ---------------------------------------------------------
local secrets = setmetatable({}, { __mode = "k" })
local function trap(name) return function() error("secret used in " .. name, 2) end end
local SECRET_MT = { __add = trap("+"), __sub = trap("-"), __mul = trap("*"), __div = trap("/"),
                    __unm = trap("unary -"), __lt = trap("<"), __le = trap("<="), __concat = trap(".."),
                    __len = trap("#") }
local function Secret(label)
    local t = setmetatable({ label = label }, SECRET_MT)
    secrets[t] = true
    return t
end
issecretvalue = function(v) return type(v) == "table" and secrets[v] == true end

-- ---- frames that record what they are told ------------------------------------
local RECORDED = { "SetMinMaxValues", "SetValue", "SetStatusBarTexture", "SetStatusBarColor", "SetReverseFill",
                   "SetTimerDuration", "SetAlphaFromBoolean", "SetFormattedText", "SetJustifyH", "SetBlendMode",
                   "SetAtlas", "SetDesaturated", "SetTextColor", "SetDrawLayer" }
local created = {}
local function Make(kind, parent)
    local f = setmetatable(FakeUIFrame(0, 0), nil)
    f._kind, f._shown, f._calls, f._last, f._events = kind, true, {}, {}, {}
    f:SetFakeParent(parent)
    for _, name in ipairs(RECORDED) do
        f[name] = function(self, ...)
            self._calls[name] = (self._calls[name] or 0) + 1
            self._last[name] = { ... }
        end
    end
    local alpha = f.SetAlpha
    function f:SetAlpha(a) self._calls.SetAlpha = (self._calls.SetAlpha or 0) + 1; alpha(self, a) end
    function f:SetParent(p) self:SetFakeParent(p) end
    function f:SetFormattedText(fmt, ...) self._last.SetFormattedText = { fmt, ... }; self._text = "<fmt>" end
    function f:RegisterUnitEvent(ev, ...) self._events[ev] = { ... } end
    function f:RegisterEvent(ev) self._events[ev] = { "*" } end
    function f:UnregisterEvent(ev) self._events[ev] = nil end
    function f:CreateTexture() local t = Make("Texture", self); return t end
    function f:CreateFontString() local t = Make("FontString", self); return t end
    local tex
    function f:GetStatusBarTexture() tex = tex or Make("Texture", self); return tex end
    created[#created + 1] = f
    return f
end
CreateFrame = function(kind, _, parent) return Make(kind, parent) end

-- ---- client stubs ---------------------------------------------------------------
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function runTimers()
    local list = timers
    timers = {}
    for _, fn in ipairs(list) do fn() end
end
local NOW = 100
GetTime = function() return NOW end
Enum.StatusBarTimerDirection = { ElapsedTime = 0, RemainingTime = 1 }
Enum.StatusBarInterpolation = { Immediate = 0 }
Enum.DurationTextBindingProperty = { RemainingDuration = 0, ElapsedDuration = 2, TotalDuration = 4 }

local function Duration(total, elapsed, secret)
    local d = { total = total, elapsed = elapsed, secret = secret }
    function d:GetTotalDuration() return self.secret and Secret("total") or self.total end
    function d:GetElapsedDuration() return self.secret and Secret("elapsed") or self.elapsed end
    function d:GetRemainingDuration() return self.secret and Secret("remaining") or (self.total - self.elapsed) end
    function d:SetTimeFromStart(s, t) self.start, self.total, self.elapsed = s, t, NOW - s end
    function d:IsZero() return self.zero end
    return d
end

local bindings = {}
C_DurationUtil = {
    CreateDuration = function() return Duration(0, 0, false) end,
    CreateDurationTextBinding = function()
        local b = { calls = {} }
        for _, m in ipairs({ "SetFontString", "SetTextFormat", "SetDuration", "SetEnabled", "SetUpdateInterval" }) do
            b[m] = function(self, ...) self.calls[m] = { ... } end
        end
        bindings[#bindings + 1] = b
        return b
    end,
}
local formatters = {}
C_StringUtil = { CreateNumericRuleFormatter = function()
    local f = { SetBreakpoints = function(self, bp) self.bp = bp end }
    formatters[#formatters + 1] = f
    return f
end }
local evaluated = {}
C_CurveUtil = { EvaluateColorValueFromBoolean = function(flag, t, f)
    evaluated[#evaluated + 1] = flag
    if issecretvalue(flag) then return Secret("channel") end
    return flag and t or f
end }

local cast, channel, castDur, chanDur, empDur = nil, nil, nil, nil, nil
UnitCastingInfo = function() if cast then return unpack(cast) end end
UnitChannelInfo = function() if channel then return unpack(channel) end end
UnitCastingDuration = function() return castDur end
UnitChannelDuration = function() return chanDur end
local empArgs
UnitEmpoweredChannelDuration = function(u, hold) empArgs = { u, hold }; return empDur end
UnitEmpoweredStagePercentages = function() return { 0.2, 0.3, 0.3, 0.2 } end
UnitSpellTargetName = function() return nil end
UnitExists = function() return true end
local class = "ROGUE"
UnitClass = function() return "Rogue", class end
RAID_CLASS_COLORS = { ROGUE = { r = 1, g = 0.96, b = 0.41 } }
local known = { [1766] = true }
C_SpellBook = { IsSpellKnownOrInSpellBook = function(id) return known[id] and true or false end }
local cd
C_Spell = { GetSpellCooldownDuration = function(id, ignoreGCD) return cd end }
GetNetStats = function() return 0, 0, 0, 200 end
LibStub = nil

-- ---- DF + the companion ---------------------------------------------------------
local DF = { PartyDefaults = { frameWidth = 125, frameHeight = 40 }, registered = {} }
function DF:Debug() end
function DF:DebugWarn() end
local errs = {}
function DF:DebugError(_, fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
function DF:SafeSetFont() end
DF.L = setmetatable({}, { __index = function(_, k) return k end })
DandersFrames = DF

local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }
load_uf_file_into("Elements.lua", UF)
load_uf_file_into("CastBar.lua", UF)
local CB, K = UF.CastBar, UF.Elements.Kit
UF.frames = {}

-- A unit frame stand-in: the owner the cast bar hangs off.
local function Owner(unit)
    local f = Make("Button", UIParent)
    f.dfUFUnit, f.unit = unit, unit
    f.dfDB = UF:GetUnitDB(unit)
    return f
end

print("-- Attach: the units that have a cast bar")
check(UF.Elements.list[1] == CB, "the cast bar registers itself as an element")
local T = Owner("target")
CB:Attach(T)
local cb = T.dfUFCastBar
check(cb ~= nil, "target: a cast bar")
eq(cb.owner, T, "...knowing its frame")
local TT = Owner("targettarget")
CB:Attach(TT)
eq(TT.dfUFCastBar, nil, "target of target: none")
check(cb.listener ~= nil, "a live frame's cast bar has its own event listener")
check(cb.positioner and cb.kickBar and cb.kickTick, "...and the kick tick's two bars")
eq(cb.shield._kind, "Frame", "the not-interruptible shield is a FRAME (alpha from a boolean)")

print("-- Defaults (spec Q7)")
eq(UF:GetUnitDB("player").castbarEnabled, true, "player cast bar on by default")
eq(UF:GetUnitDB("target").castbarEnabled, true, "target on")
eq(UF:GetUnitDB("focus").castbarEnabled, true, "focus on")
eq(UF:GetUnitDB("pet").castbarEnabled, false, "pet off")
eq(UF:GetUnitDB("player").castbarDetached, true, "player detached by default (the pet frame hangs under the player)")
eq(UF:GetUnitDB("target").castbarDetached, false, "target attached")

print("-- Layout: attached")
local db = UF:GetUnitDB("target")
db.frameWidth = 200
CB:Layout(T)
eq(cb:GetParent(), T, "attached: parented to the frame")
eq(cb._w, 200, "width matches the frame")
eq(cb._h, 18, "height from castbarHeight")
local pt = cb._points[#cb._points]
eq(pt and pt[1], "TOP", "under the frame: its top...")
eq(pt and pt[3], "BOTTOM", "...at the frame's bottom")
eq(pt and pt[5], -2, "...a gap below")
eq(cb.barWidth, 182, "the icon takes a square at one end (200 - 18)")
db.castbarSide = "TOP"
CB:Layout(T)
pt = cb._points[#cb._points]
eq(pt and pt[1], "BOTTOM", "Top: over the frame")
db.castbarSide = nil

print("-- Events: per unit, only while shown and on")
CB:SetActive(T, true)
for _, ev in ipairs(CB.EVENTS) do
    eq(cb.listener._events[ev] and cb.listener._events[ev][1], "target", "target registers " .. ev .. " for target only")
end
CB:SetActive(T, false)
eq(next(cb.listener._events), nil, "hidden: every cast event dropped")
db.castbarEnabled = false
CB:SetActive(T, true)
eq(next(cb.listener._events), nil, "cast bar off: nothing registered")
db.castbarEnabled = nil
local P = Owner("player")
CB:Attach(P)
CB:SetActive(P, true)
eq(P.dfUFCastBar.listener._events.UNIT_SPELLCAST_START and table.concat(P.dfUFCastBar.listener._events.UNIT_SPELLCAST_START, ","),
   "player,vehicle", "player: player and vehicle (the frame shows the vehicle in one)")
CB:SetActive(T, true)

print("-- Boss slots: the slot's own token, never detached")
local BS = Owner("boss")
BS.unit, BS.dfUFSlot = "boss3", 3
CB:Attach(BS)
check(BS.dfUFCastBar ~= nil, "boss: a cast bar")
CB:SetActive(BS, true)
eq(BS.dfUFCastBar.listener._events.UNIT_SPELLCAST_START and table.concat(BS.dfUFCastBar.listener._events.UNIT_SPELLCAST_START, ","),
   "boss3", "boss slot 3 registers for boss3, not the settings unit")
UF:GetUnitDB("boss").castbarDetached = true
eq(CB:IsDetached(BS), false, "a boss slot's cast bar never detaches (one record, five bars)")
UF:GetUnitDB("boss").castbarDetached = nil
CB:SetActive(BS, false)

print("-- A secret enemy cast: the client owns the fill, the text and the colour")
local nameS, texS, niS, spellS = Secret("name"), Secret("texture"), Secret("notInterruptible"), Secret("spellID")
cast = { nameS, nil, texS, Secret("start"), Secret("end"), false, Secret("castID"), niS, spellS }
castDur = Duration(2.5, 1, true)
known = {}   -- no interrupt yet: the kick tick comes later
CB:ForgetInterrupt()
local ok, err = pcall(CB.OnEvent, CB, cb, "UNIT_SPELLCAST_START", "target")
check(ok, "a secret cast starts without touching a secret (" .. tostring(err) .. ")")
eq(cb.bar._last.SetTimerDuration and cb.bar._last.SetTimerDuration[1], castDur, "fill: SetTimerDuration(UnitCastingDuration)")
eq(cb.bar._last.SetTimerDuration and cb.bar._last.SetTimerDuration[3], 0, "...elapsed direction (fills)")
eq(cb.text._last.SetFormattedText and cb.text._last.SetFormattedText[1], "%s", "name: SetFormattedText(\"%s\")")
eq(cb.text._last.SetFormattedText and cb.text._last.SetFormattedText[2], nameS, "...with the name as given")
eq(cb.icon._texture, texS, "icon: the texture as given")
local sh = cb.shield._last.SetAlphaFromBoolean
eq(sh and sh[1], niS, "shield: SetAlphaFromBoolean(notInterruptible)")
eq(sh and sh[2], 1, "...1 when not interruptible")
eq(sh and sh[3], 0, "...0 when it can be")
local picked = false
for _, flag in ipairs(evaluated) do if flag == niS then picked = true end end
check(picked, "colour: EvaluateColorValueFromBoolean(notInterruptible, ...)")
check(issecretvalue(cb.bar._last.SetStatusBarColor[1]), "...the picked (secret) channels go straight to SetStatusBarColor")
local b = bindings[#bindings]
eq(b and b.calls.SetDuration and b.calls.SetDuration[1], castDur, "timer: a DurationTextBinding on the cast's duration")
eq(b and b.calls.SetEnabled and b.calls.SetEnabled[1], true, "...enabled")
eq(b and b.calls.SetTextFormat and b.calls.SetTextFormat[1], "{}", "...Remaining by default")
eq(b and b.calls.SetTextFormat and b.calls.SetTextFormat[2][1].property, 0, "...the remaining duration")
local fm = formatters[#formatters]
eq(fm and fm.bp and fm.bp[1].format, "%.1f", "...formatted C-side, one decimal by default")
eq(fm and fm.bp and fm.bp[1].step, 0.1, "...rounded to tenths")
check(cb:IsShown(), "the bar shows")
check(not cb.latency:IsShown(), "no latency on an enemy cast")

print("-- Channel: the duration drains")
cast, channel = nil, { "Drain", nil, 136, 1, 2, false, false, 5, false }
chanDur = Duration(3, 1, true)
CB:OnEvent(cb, "UNIT_SPELLCAST_CHANNEL_START", "target")
eq(cb.bar._last.SetTimerDuration[1], chanDur, "fill: SetTimerDuration(UnitChannelDuration)")
eq(cb.bar._last.SetTimerDuration[3], 1, "...remaining direction (drains)")
eq(cb.channel, true, "a channel")

print("-- Empowered (the player)")
local pcb = P.dfUFCastBar
CB:Layout(P)
channel = { "Fire Breath", nil, 136, 1000, 3000, false, false, 357208, true }
empDur = Duration(2, 0.5, false)
CB:OnEvent(pcb, "UNIT_SPELLCAST_EMPOWER_START", "player")
eq(pcb.bar._last.SetTimerDuration and pcb.bar._last.SetTimerDuration[1], empDur, "fill: UnitEmpoweredChannelDuration")
eq(empArgs and empArgs[2], true, "...including the hold at max")
eq(pcb.bar._last.SetTimerDuration[3], 0, "...fills (an empower is not a drain)")
local stages = 0
for _, t in ipairs(pcb.stages) do if t:IsShown() then stages = stages + 1 end end
eq(stages, 3, "three stage marks (the last share is the hold)")
channel = nil

print("-- Player latency (plain times only)")
cast = { "Fireball", nil, 135812, 1000, 3000, false, 7, false, 133 }
castDur = Duration(2, 0, false)
UF:GetUnitDB("player").castbarLatency = true
CB:OnEvent(pcb, "UNIT_SPELLCAST_START", "player")
check(pcb.latency:IsShown(), "player: latency shown")
eq(pcb.latency._w, pcb.barWidth * 0.1, "...200 ms of a 2 s cast = a tenth of the bar")
cast = { Secret("n"), nil, 1, Secret("s"), Secret("e"), false, 1, false, 1 }
ok, err = pcall(CB.OnEvent, CB, pcb, "UNIT_SPELLCAST_START", "player")
check(ok, "secret player times: no maths (" .. tostring(err) .. ")")
check(not pcb.latency:IsShown(), "...and no latency")

print("-- Kick tick: two invisible bars, the client compares")
class, known = "ROGUE", { [1766] = true }
CB:ForgetInterrupt()
local readyS, remS = Secret("isZero"), Secret("cdRemaining")
cd = { IsZero = function() return readyS end, GetRemainingDuration = function() return remS end }
cast = { nameS, nil, texS, 1, 2, false, 1, niS, spellS }
castDur = Duration(2.5, 1, true)
ok, err = pcall(CB.OnEvent, CB, cb, "UNIT_SPELLCAST_START", "target")
check(ok, "kick set up on a secret cast (" .. tostring(err) .. ")")
eq(CB.interruptID, 1766, "the rogue's Kick")
eq(cb.kickOn, true, "kick tick armed")
check(issecretvalue(cb.positioner._last.SetMinMaxValues[2]), "positioner: 0..total (secret into a sink)")
eq(cb.kickBar._last.SetValue and cb.kickBar._last.SetValue[1], remS, "kick bar: the interrupt's remaining cooldown")
local ka = cb.kickHost._last.SetAlphaFromBoolean
eq(ka and ka[1], readyS, "tick alpha: SetAlphaFromBoolean(cooldown:IsZero())")
eq(ka and ka[2], 0, "...hidden when the kick is ready")
eq(ka and ka[3], 1, "...shown otherwise: a plain number, never one picked from a secret")
local ca = cb.clip._last.SetAlphaFromBoolean
eq(ca and ca[1], niS, "not interruptible: the clip frame's own SetAlphaFromBoolean on the flag")
check(ca and ca[2] == 0 and ca[3] == 1, "...hidden on a cast it cannot interrupt, plain numbers")
ok, err = pcall(CB.OnUpdate, CB, cb, 0.2)
check(ok, "per frame: no maths (" .. tostring(err) .. ")")
check(issecretvalue(cb.positioner._last.SetValue[1]), "positioner follows the cast's elapsed time")
local kickPicked = false
for _, flag in ipairs(evaluated) do if flag == readyS then kickPicked = true end end
check(kickPicked, "kick not ready: the colour is picked from IsZero too")
CB:ForgetInterrupt()
class, known = "PRIEST", {}
CB:OnEvent(cb, "UNIT_SPELLCAST_START", "target")
eq(cb.kickOn, false, "no interrupt known: no tick")
eq(cb.kickHost._alpha, 0, "...the tick stays hidden")
class, known = "ROGUE", { [1766] = true }
CB:ForgetInterrupt()
UF:GetUnitDB("player").castbarKickTick = true
CB:OnEvent(pcb, "UNIT_SPELLCAST_START", "player")
eq(pcb.kickOn, false, "never on the player's own cast bar")

print("-- Not interruptible / interruptible events")
CB:OnEvent(cb, "UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "target")
eq(cb.shield._alpha, 1, "NOT_INTERRUPTIBLE: shield shown")
CB:OnEvent(cb, "UNIT_SPELLCAST_INTERRUPTIBLE", "target")
eq(cb.shield._alpha, 0, "INTERRUPTIBLE: shield hidden")

print("-- Interrupted: a held flash")
CB:OnEvent(cb, "UNIT_SPELLCAST_INTERRUPTED", "target")
eq(cb.holding, true, "held")
eq(cb.text._text, "Interrupted", "the word on the bar")
eq(cb.bar._last.SetStatusBarColor[1], 0.9, "in the failed colour")
cast = nil
CB:OnEvent(cb, "UNIT_SPELLCAST_STOP", "target")
eq(cb.holding, true, "the STOP after it does not cut the flash short")
runTimers()
eq(cb.holding, false, "released after the hold")
check(not cb:IsShown(), "...and hidden (Hide When Not Casting)")
db.castbarHideIdle = false
CB:Finish(cb)
check(cb:IsShown(), "Hide When Not Casting off: an empty bar stays")
db.castbarHideIdle = nil

print("-- A stop that arrives after the next cast started")
cast = { "Next", nil, 1, 1, 2, false, 1, false, 1 }
castDur = Duration(2, 0, false)
CB:OnEvent(cb, "UNIT_SPELLCAST_START", "target")
local token = cb.token
CB:OnEvent(cb, "UNIT_SPELLCAST_STOP", "target")
check(cb.active, "the new cast keeps running")
check(cb.token ~= token, "...re-read, not ended")

print("-- The duration arrives a frame late")
castDur = nil
timers = {}
CB:OnEvent(cb, "UNIT_SPELLCAST_START", "target")
eq(#timers, 1, "no duration yet: a retry is queued")
castDur = Duration(2, 0, true)
runTimers()
eq(cb.bar._last.SetTimerDuration[1], castDur, "...and the retry takes it")

print("-- Timer text without the binding API: never a secret through Lua")
CB.noBinding = true
cb.binding = nil
cast = { "Sec", nil, 1, 1, 2, false, 1, false, 1 }
castDur = Duration(2, 1, true)
CB:OnEvent(cb, "UNIT_SPELLCAST_START", "target")
eq(cb.textFallback, true, "fallback text path")
ok, err = pcall(CB.OnUpdate, CB, cb, 0.2)
check(ok, "secret remaining: no error (" .. tostring(err) .. ")")
eq(cb.timer._text, "", "...and no text")
castDur = Duration(2, 0.74, false)
CB:OnEvent(cb, "UNIT_SPELLCAST_START", "target")
CB:OnUpdate(cb, 0.2)
eq(cb.timer._text, "1.3", "plain remaining: formatted in Lua (1.26 -> 1.3)")
CB.noBinding = nil

print("-- Detached without DandersMover: the record's point / x / y")
local placed
UF.Units = { holders = { target = Make("Frame", UIParent) },
             PlaceAt = function(_, el, rec) placed = { el = el, rec = rec } end }
db.castbarDetached = true
CB:Layout(T)
eq(cb:GetParent(), UF.Units.holders.target, "detached: parented to the unit's holder (its Visibility rule)")
eq(placed and placed.el, cb, "...placed at its own record")
eq(placed and placed.rec, db.castbarPosition, "...the unit's castbarPosition")
eq(db.castbarPosition.anchor and db.castbarPosition.anchor.target, "DandersFrames_UnitFrames:target",
   "...which starts anchored to its frame (a first detach moves nothing)")
db.castbarDetached = false
CB:Layout(T)
eq(cb:GetParent(), T, "attached again: back on the frame")

print("-- Detached with DandersMover: its own element")
local lib = { defs = {}, unregistered = {}, applied = {}, anchors = {}, detached = {} }
function lib:RegisterAddon() end
function lib:Register(addon, key, def) self.defs[addon .. ":" .. key] = def end
function lib:Unregister(addon, key) self.defs[addon .. ":" .. key] = nil; self.unregistered[#self.unregistered + 1] = key end
function lib:Apply(addon, key) self.applied[#self.applied + 1] = key end
function lib:SetAnchor(addon, key, spec) self.anchors[key] = spec; return true end
function lib:Detach(addon, key) self.detached[#self.detached + 1] = key; return true end
LibStub = function(name) if name == "DandersMover-1.0" then return lib end end
local createFrame = CreateFrame
CreateFrame = nil
load_uf_file_into("Mover.lua", UF)
CreateFrame = createFrame
UF.frames.target = T
UF.Mover:Init()
eq(lib.defs["DandersFrames_UnitFrames:target.castbar"], nil, "attached: no element")
db.castbarDetached = true
CB:Layout(T)
local def = lib.defs["DandersFrames_UnitFrames:target.castbar"]
check(def ~= nil, "detached: registered as target.castbar")
eq(def and def.getPos(), db.castbarPosition, "...its record is the unit's castbarPosition, mutated in place")
eq(def and def.getFrame(), cb, "...standing for the cast bar")
eq(def and def.secure, nil, "...not secure (a plain frame; moves in combat)")
eq(def and def.default and def.default.anchor and def.default.anchor.edge, "bottom", "...default: under its frame")
check(UF.Mover:IsChildFollowing("target", "castbar"), "Follow the Frame: on (anchored)")
UF.Mover:SetChildFollowing("target", "castbar", false)
eq(lib.detached[1], "target.castbar", "...off: Lib:Detach")
UF.Mover:SetChildFollowing("target", "castbar", true)
eq(lib.anchors["target.castbar"] and lib.anchors["target.castbar"].target, "DandersFrames_UnitFrames:target",
   "...on: Lib:SetAnchor to the frame")
eq(lib.anchors["target.castbar"] and lib.anchors["target.castbar"].edge, "bottom", "...its bottom edge")
db.castbarDetached = false
CB:Layout(T)
eq(lib.defs["DandersFrames_UnitFrames:target.castbar"], nil, "attached again: unregistered")
db.castbarDetached = true
db.castbarEnabled = false
CB:Layout(T)
eq(lib.defs["DandersFrames_UnitFrames:target.castbar"], nil, "a cast bar switched off is no element either")
db.castbarEnabled, db.castbarDetached = nil, nil

print("-- Preview: a fake cast, mid-way")
local PV = Owner("focus")
PV.dfUFPreview = true
CB:Attach(PV)
eq(PV.dfUFCastBar.listener, nil, "a preview cast bar has no event listener")
CB:Preview(PV)
local pdur = PV.dfUFCastBar.bar._last.SetTimerDuration and PV.dfUFCastBar.bar._last.SetTimerDuration[1]
check(pdur and pdur.total == CB.PREVIEW_TOTAL, "...driven by a plain sample duration")
eq(pdur and pdur.start, NOW - CB.PREVIEW_ELAPSED, "...started part-way through")
check(PV.dfUFCastBar:IsShown(), "...shown")
local PI = Owner("boss")
PI.dfUFPreview, PI.dfUFPreviewIdle = true, true
CB:Attach(PI)
UF:GetUnitDB("boss").castbarHideIdle = true
CB:Preview(PI)
check(not PI.dfUFCastBar:IsShown(), "an idle preview (a sample boss but the first) shows no cast")
UF:GetUnitDB("boss").castbarHideIdle = nil

print("-- Source: no maths or decimal formats on cast times outside PLAYER ONLY")
local src = uf_file_source("CastBar.lua")
local cut = src:find("\n%-%- PLAYER ONLY\n")
check(cut ~= nil, "the PLAYER ONLY section is marked")
local shared = cut and src:sub(1, cut) or src
local playerOnly = cut and src:sub(cut) or ""
check(not shared:find("%%%.%d"), "no literal decimal format (%.0f / %.1f ...) outside PLAYER ONLY")
check(not shared:find("%f[%w][Ss]tart[Tt]ime%f[%W]") and not shared:find("%f[%w][Ee]nd[Tt]ime%f[%W]")
      and not shared:find("[Ss]tartMs") and not shared:find("[Ee]ndMs"),
      "no cast start / end times read outside PLAYER ONLY")
check(not shared:find("Duration%(%)%s*[%+%-%*/]") and not shared:find("[%+%-%*/]%s*[%w%.]+:Get%a+Duration%("),
      "no arithmetic on a duration getter's answer")
check(shared:find("bar%.SetTimerDuration") or shared:find("SetTimerDuration, bar"), "the fill is SetTimerDuration")
check(shared:find("UnitCastingDuration") and shared:find("UnitChannelDuration") and shared:find("UnitEmpoweredChannelDuration"),
      "...from the three duration APIs")
check(shared:find("local shield = CreateFrame%(\"Frame\"") and shared:find("AlphaFrom%(cb%.shield"),
      "the shield is a frame, alpha'd from the flag")
check(not src:find("[Tt]ex:SetAlphaFromBoolean"), "never a texture-level SetAlphaFromBoolean")
check(playerOnly:find("IsSecret%(s%)") and playerOnly:find("IsSecret%(e%)"), "PLAYER ONLY checks its times for secrets")
local fb = src:match("function CB:FallbackText.-\nend")
check(fb and fb:find("IsSecret%(v%)") and fb:find("IsSecret%(v%).-format%("), "fallback text: secret check before any Lua format")
local kit = uf_file_source("Elements.lua")
check(kit:find("EvaluateColorValueFromBoolean") and kit:find("frame:SetAlphaFromBoolean"),
      "the kit picks colours with EvaluateColorValueFromBoolean and frame alpha with SetAlphaFromBoolean")
eq(#errs, 0, "no element errored (" .. tostring(errs[1]) .. ")")

-- By NAME, not pairs(G): a global that was nil before is skipped by pairs and
-- would leak this file's stub into every later suite.
for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
for k, v in pairs(ENUM_HELD) do Enum[k] = v end
