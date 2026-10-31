local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- PORTRAIT
-- DandersFrames_UnitFrames/Portrait.lua
-- ------------------------------------------------------------
-- Which units get one, the style chosen per unit (3D / 2D / class / spec, the
-- NPC fallback, a secret class), side and size, the model made only when
-- needed, desaturate-when-dead on readable answers only, events per unit while
-- shown, and the preview.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "issecretvalue", "LibStub", "UnitClass", "UnitIsPlayer",
                     "UnitExists", "UnitIsVisible", "UnitIsDeadOrGhost", "SetPortraitTexture", "GetClassAtlas",
                     "GetSpecialization", "GetSpecializationInfo" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local secrets = setmetatable({}, { __mode = "k" })
local function Secret(label) local t = { label = label }; secrets[t] = true; return t end
issecretvalue = function(v) return type(v) == "table" and secrets[v] == true end

local made = {}
local function Make(kind, parent)
    local f = setmetatable(FakeUIFrame(0, 0), nil)
    f._kind, f._shown, f._events, f._calls = kind, true, {}, {}
    f:SetFakeParent(parent)
    function f:SetParent(p) self:SetFakeParent(p) end
    function f:RegisterUnitEvent(ev, ...) self._events[ev] = { ... } end
    function f:RegisterEvent(ev) self._events[ev] = { "*" } end
    function f:UnregisterEvent(ev) self._events[ev] = nil end
    function f:CreateTexture() return Make("Texture", self) end
    function f:CreateFontString() return Make("FontString", self) end
    function f:SetAtlas(a) self._atlas = a end
    function f:SetDesaturated(v) self._desat = v end
    for _, m in ipairs({ "ClearModel", "SetUnit", "SetPortraitZoom", "SetFacing", "SetModel" }) do
        f[m] = function(self, ...) self._calls[m] = { ... } end
    end
    made[#made + 1] = f
    return f
end
CreateFrame = function(kind, _, parent) return Make(kind, parent) end

local units = { player = { class = "MAGE", isPlayer = true }, target = { class = "WARRIOR", isPlayer = false } }
UnitClass = function(u) return "x", units[u] and units[u].class end
UnitIsPlayer = function(u) return units[u] and units[u].isPlayer end
UnitExists = function(u) return units[u] ~= nil end
UnitIsVisible = function() return true end
local dead = false
UnitIsDeadOrGhost = function() return dead end
local portraitSet
SetPortraitTexture = function(tex, u) portraitSet = { tex = tex, unit = u } end
GetClassAtlas = function(c) return "classicon-" .. c:lower() end
GetSpecialization = function() return 2 end
GetSpecializationInfo = function() return 63, "Fire", "", 135810 end
LibStub = nil

local DF = { PartyDefaults = { frameWidth = 125, frameHeight = 40 }, registered = {} }
function DF:Debug() end
function DF:DebugWarn() end
local errs = {}
function DF:DebugError(_, fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
DandersFrames = DF

local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }
load_uf_file_into("Elements.lua", UF)
load_uf_file_into("Portrait.lua", UF)
local PO = UF.Portrait

local function Owner(unit)
    local f = Make("Button", UIParent)
    f.dfUFUnit, f.unit = unit, unit
    f.dfDB = UF:GetUnitDB(unit)
    return f
end

print("-- Defaults")
eq(UF:GetUnitDB("player").portraitEnabled, true, "player: on")
eq(UF:GetUnitDB("target").portraitEnabled, true, "target: on")
eq(UF:GetUnitDB("focus").portraitEnabled, true, "focus: on")
eq(UF:GetUnitDB("pet").portraitEnabled, false, "pet: off (a small frame)")

print("-- Attach")
local TT = Owner("targettarget")
PO:Attach(TT)
eq(TT.dfUFPortrait, nil, "target of target: none")
local P = Owner("player")
PO:Attach(P)
local p = P.dfUFPortrait
check(p ~= nil and p.listener ~= nil, "player: a portrait with its own listener")
eq(p.model, nil, "no model until a 3D style needs one")

print("-- Style per unit")
local db = UF:GetUnitDB("player")
eq(PO:StyleFor({ portraitMode = "CLASS" }, "target", nil), "3D", "class icon for an NPC: the NPC style (3D)")
eq(PO:StyleFor({ portraitMode = "CLASS", portraitNpcMode = "2D" }, "target", nil), "2D", "...or 2D when chosen")
eq(PO:StyleFor({ portraitMode = "SPEC" }, "target", "WARRIOR"), "CLASS", "spec icon on another player: their class icon")
eq(PO:StyleFor({ portraitMode = "SPEC" }, "player", "MAGE"), "SPEC", "spec icon on the player")
eq(PO:StyleFor({ portraitMode = "bogus" }, "player", "MAGE"), "3D", "an unknown stored style: 3D")

print("-- Layout: side and size")
db.frameHeight = 40
PO:Layout(P)
eq(p._w, 40, "size 0: the frame's height")
local pt = p._points[#p._points]
eq(pt and pt[1], "RIGHT", "Left: the portrait's right edge...")
eq(pt and pt[3], "LEFT", "...against the frame's left edge")
db.portraitSide = "INSIDE_RIGHT"
db.portraitSize = 30
PO:Layout(P)
pt = p._points[#p._points]
eq(pt and pt[1], "RIGHT", "Inside Right: right edge...")
eq(pt and pt[3], "RIGHT", "...on the frame's right edge")
eq(p._w, 30, "a set size")
db.portraitSide, db.portraitSize = nil, nil

print("-- Painting")
PO:Update(P)
check(p.model ~= nil, "3D: the model is made")
eq(p.model._calls.SetUnit and p.model._calls.SetUnit[1], "player", "...shows the unit")
eq(p.model._calls.SetPortraitZoom and p.model._calls.SetPortraitZoom[1], 1, "...at the portrait zoom")
db.portraitMode = "2D"
PO:Update(P)
eq(portraitSet and portraitSet.unit, "player", "2D: SetPortraitTexture")
check(not p.model:IsShown(), "...the model hidden")
db.portraitMode = "CLASS"
PO:Update(P)
eq(p.tex._atlas, "classicon-mage", "Class Icon: the class atlas")
db.portraitMode = "SPEC"
PO:Update(P)
eq(p.tex._texture, 135810, "Spec Icon: the player's spec icon")

print("-- A secret class reads as an NPC")
local T = Owner("target")
PO:Attach(T)
local tdb = UF:GetUnitDB("target")
tdb.portraitMode = "CLASS"
units.target = { class = Secret("class"), isPlayer = true }
local ok, err = pcall(PO.Update, PO, T)
check(ok, "no error (" .. tostring(err) .. ")")
check(T.dfUFPortrait.model and T.dfUFPortrait.model:IsShown(), "...the NPC style (3D) instead of a class icon")
units.target = { class = "WARRIOR", isPlayer = Secret("isPlayer") }
PO:Update(T)
check(T.dfUFPortrait.model:IsShown(), "a secret is-player answer: the same")

print("-- Desaturate when dead (readable answers only)")
db.portraitMode = "2D"
dead = true
PO:Update(P)
eq(p.tex._desat, true, "dead: desaturated")
dead = Secret("dead")
PO:OnUnitEvent(P, "UNIT_HEALTH")
eq(p.tex._desat, false, "a secret answer: left in colour")
dead = false

print("-- Unit gone: hidden")
local F = Owner("focus")
PO:Attach(F)
PO:Update(F)
check(not F.dfUFPortrait:IsShown(), "no focus: no portrait")

print("-- Events per unit, only while shown and on")
PO:SetActive(P, true)
eq(p.listener._events.UNIT_PORTRAIT_UPDATE and table.concat(p.listener._events.UNIT_PORTRAIT_UPDATE, ","),
   "player,vehicle", "player: portrait updates for player and vehicle")
PO:SetActive(T, true)
eq(T.dfUFPortrait.listener._events.UNIT_MODEL_CHANGED[1], "target", "target: its own unit")
PO:SetActive(T, false)
eq(next(T.dfUFPortrait.listener._events), nil, "hidden: dropped")
do
    local bdb = UF:GetUnitDB("boss")
    bdb.portraitEnabled = true
    local BS = Owner("boss")
    BS.unit, BS.dfUFSlot = "boss2", 2
    PO:Attach(BS)
    PO:SetActive(BS, true)
    eq(BS.dfUFPortrait.listener._events.UNIT_MODEL_CHANGED and BS.dfUFPortrait.listener._events.UNIT_MODEL_CHANGED[1],
       "boss2", "boss slot 2: its own token")
    PO:SetActive(BS, false)
    bdb.portraitEnabled = nil
end
db.portraitEnabled = false
PO:SetActive(P, false)
PO:SetActive(P, true)
eq(next(p.listener._events), nil, "portrait off: nothing registered")
db.portraitEnabled = nil

print("-- Preview")
local PV = Owner("target")
PV.dfUFPreview = true
PO:Attach(PV)
eq(PV.dfUFPortrait.listener, nil, "no listener on a preview")
PO:Preview(PV)
eq(PV.dfUFPortrait.tex._texture, PO.QUESTION_ICON, "a sample target: a question mark")
check(PV.dfUFPortrait:IsShown(), "...shown")
eq(#errs, 0, "no element errored (" .. tostring(errs[1]) .. ")")

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
