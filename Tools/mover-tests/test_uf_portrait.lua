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
eq(p._w, 38, "size 0: the frame's height, its 1px border (drawn outside) included")
local pt = p._points[#p._points]
eq(pt and pt[1], "RIGHT", "Left: the portrait's right edge...")
eq(pt and pt[3], "LEFT", "...against the frame's left edge")
db.portraitSide = "INSIDE_RIGHT"
db.portraitSize = -10
PO:Layout(P)
pt = p._points[#p._points]
eq(pt and pt[1], "RIGHT", "Inside Right: right edge...")
eq(pt and pt[3], "RIGHT", "...on the frame's right edge")
eq(p._w, 28, "size -10: 10 smaller than the frame, border included")
db.portraitSide, db.portraitSize = nil, nil

print("-- Reach outside the frame (the outer rect a frame beside it clears)")
do
    local function reach(f) local l, r = PO.OutsideExtent(f); return l .. "," .. r end
    eq(reach(P), "41,0", "Left, size = height (40, border included): 2 gap + 38 + 1 border")
    db.portraitSide = "RIGHT"
    eq(reach(P), "0,41", "Right: the same on the right")
    db.portraitSize = 20
    eq(reach(P), "0,61", "20 bigger reaches further")
    db.portraitX = 5
    eq(reach(P), "0,66", "...and moved out by X")
    db.portraitX = -70
    eq(reach(P), "0,0", "...moved back over the frame: nothing (never negative)")
    db.portraitX = nil
    db.portraitBorderEnabled = false
    eq(reach(P), "0,62", "no border: the whole 60 is portrait")
    db.portraitBorderEnabled, db.portraitBorderSize = nil, 3
    eq(reach(P), "0,59", "a 3px border comes off the size")
    db.portraitBorderSize = nil
    for _, side in ipairs({ "INSIDE_LEFT", "INSIDE_RIGHT" }) do
        db.portraitSide = side
        eq(reach(P), "0,0", side .. ": inside the frame, reaches nothing")
    end
    db.portraitSide = "RIGHT"
    db.portraitEnabled = false
    eq(reach(P), "0,0", "off: nothing")
    db.portraitEnabled, db.portraitSide, db.portraitSize = nil, nil, nil
    -- The portrait's own rect (the resting glow's Include Portrait), border
    -- included, from the frame's TOPLEFT with y down. The frame is 220 x 40.
    local function rect(f) local l, t, r, b = PO.OutsideRect(f); return l and table.concat({ l, t, r, b }, ",") or "nil" end
    eq(rect(P), "-41,0,-1,40", "rect: size = height, border included, left of a 2px gap")
    db.portraitSize = 20
    eq(rect(P), "-61,-10,-1,50", "rect: 20 bigger than a 40 frame pokes 10 each way")
    db.portraitY = 4
    eq(rect(P), "-61,-14,-1,46", "rect: moved up 4")
    db.portraitSize, db.portraitY = -20, nil
    eq(rect(P), "-21,10,-1,30", "rect: a short portrait, centred")
    db.portraitSide = "RIGHT"
    eq(rect(P), "221,10,241,30", "rect: on the right")
    db.portraitSide = "INSIDE_LEFT"
    eq(rect(P), "nil", "rect: an inside portrait is not outside anything")
    db.portraitSide, db.portraitSize = nil, nil
    -- Target's portrait is Player's mirrored by the link (Links.lua, not loaded here).
    local T = Owner("target")
    local tdb = UF:GetUnitDB("target")
    tdb.portraitSide = "RIGHT"
    eq(reach(T), "0,47", "target (46 high, portrait on the right): 47 past its right edge")
    tdb.portraitSide = nil
    eq(UF:GetUnitDB("focus").portraitSide or "LEFT", "LEFT", "focus: its portrait on the left (out of a focus target's way)")
end

print("-- Old absolute portrait sizes become relative, once")
if UF.MigrateProfileTable then
    local t = { global = {}, units = { player = { portraitSize = 60, frameHeight = 40 },
                                       target = { portraitSize = 0 },
                                       focus = { portraitSize = 30, frameHeight = 30, portraitBorderEnabled = false } } }
    UF.MigrateProfileTable(t)
    eq(t.units.player.portraitSize, 22, "60 + its 1px border each side on a 40 frame: 22 bigger")
    eq(t.units.target.portraitSize, 0, "0 (frame height) stays 0")
    eq(t.units.focus.portraitSize, 0, "no border: 30 on a 30 frame is 0")
    eq(t.global.portraitSizeRelative, true, "marked done")
    UF.MigrateProfileTable(t)
    eq(t.units.player.portraitSize, 22, "a second run changes nothing")
else
    check(false, "UF.MigrateProfileTable is loaded")
end

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
