local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- RING FRAME STYLE
-- DandersFrames_UnitFrames/Rings.lua (+ the frame view in Core.lua, the preview
-- table in Preview.lua, the ring branches of Portrait.lua and ClassPower.lua)
-- ------------------------------------------------------------
-- Defaults (sparse, copied on first read), the ring list cleaned, the geometry
-- (outermost ring at the frame's edge, gaps inward, the portrait's hole), the arc
-- maths (Start = a, End = 1 - length), sections and pips, the frame view's
-- answers (and none in BARS style), the element: arcs built, the health bar's
-- writes copied onto the health fills (secret values passed on unread), power fed
-- and coloured, BARS style left alone. The portrait's ring size and class power's
-- ring pips. Links ownership. The settings page's pure list edits.
-- Not pixels: whether a radial bar with two masks draws a see-through ring is
-- /dfring's job, in game.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "issecretvalue", "LibStub", "hooksecurefunc",
                     "UnitExists", "UnitPower", "UnitPowerMax", "UnitClass", "UnitIsPlayer", "UnitIsVisible",
                     "UnitIsDeadOrGhost", "GetClassAtlas", "RAID_CLASS_COLORS", "PowerBarColor",
                     "GetSpecialization", "GetSpecializationInfo", "GetShapeshiftFormID", "UnitAffectingCombat" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end
local ENUM_HELD = { StatusBarRenderMode = Enum.StatusBarRenderMode, PowerType = Enum.PowerType }

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local secrets = setmetatable({}, { __mode = "k" })
local function trap(name) return function() error("secret used in " .. name, 2) end end
local SECRET_MT = { __add = trap("+"), __sub = trap("-"), __lt = trap("<"), __le = trap("<="),
                    __eq = trap("=="), __concat = trap("..") }
local function Secret(label)
    local t = setmetatable({ label = label }, SECRET_MT)
    secrets[t] = true
    return t
end
issecretvalue = function(v) return type(v) == "table" and secrets[v] == true end

hooksecurefunc = function(t, name, fn)
    local orig = t[name]
    t[name] = function(...)
        orig(...)
        fn(...)
    end
end

local function Make(kind, parent)
    local f = setmetatable(FakeUIFrame(0, 0), nil)
    f._kind, f._shown, f._calls, f._masks, f._level = kind, true, {}, {}, 1
    f:SetFakeParent(parent)
    function f:SetParent(p) self:SetFakeParent(p) end
    f._events = {}
    function f:RegisterEvent(ev) self._events[ev] = true end
    function f:RegisterUnitEvent(ev) self._events[ev] = true end
    function f:UnregisterEvent(ev) self._events[ev] = nil end
    function f:EnableMouse() end
    function f:CreateTexture() return Make("Texture", self) end
    function f:CreateFontString() return Make("FontString", self) end
    function f:CreateMaskTexture() return Make("MaskTexture", self) end
    function f:AddMaskTexture(m) self._masks[#self._masks + 1] = m end
    function f:RemoveMaskTexture() end
    function f:SetTexture(path, wh, wv) self._texture, self._wrap = path, wh end
    function f:SetFrameLevel(l) self._level = l end
    function f:GetFrameLevel() return self._level end
    function f:SetRenderMode(m) self._render = m end
    for _, m in ipairs({ "SetRadialProgressBarStartOffset", "SetRadialProgressBarEndOffset",
                         "SetRadialProgressBarReverse", "SetRadialProgressBarFeather" }) do
        f[m] = function(self, v) self._calls[m] = v end
    end
    function f:SetVertexColor(r, g, b, a) self._vertex = { r, g, b, a } end
    function f:GetVertexColor() local v = rawget(self, "_vertex") or { 1, 1, 1 }; return v[1], v[2], v[3] end
    function f:SetAlphaFromBoolean(flag, a, b) self._alphaFrom = { flag, a, b } end
    function f:SetDesaturated() end
    if kind == "StatusBar" then
        f._tex = Make("Texture", f)
        f._min, f._max, f._value = 0, 1, 0
        function f:SetStatusBarTexture() end
        function f:GetStatusBarTexture() return self._tex end
        function f:SetMinMaxValues(lo, hi) self._min, self._max = lo, hi end
        function f:GetMinMaxValues() return self._min, self._max end
        function f:SetValue(v, interp) self._value, self._interp = v, interp end
        function f:GetValue() return self._value end
        function f:SetStatusBarColor(r, g, b, a) self._barColor = { r, g, b, a } end
    end
    return f
end
CreateFrame = function(kind, _, parent) return Make(kind, parent) end
Enum.StatusBarRenderMode = { Linear = 0, Radial = 1 }
Enum.PowerType = { ComboPoints = 4, HolyPower = 9 }
LibStub = nil

local power, maxPower = 30, 100
UnitExists = function(u) return u == "player" or u == "target" end
UnitPower = function(u, pt) if pt then return 3 end return power end
UnitPowerMax = function(u, pt) if pt then return 5 end return maxPower end
UnitClass = function() return "x", "PALADIN" end
UnitIsPlayer = function() return true end
UnitIsVisible = function() return true end
UnitIsDeadOrGhost = function() return false end
GetClassAtlas = function(c) return "classicon-" .. c:lower() end
GetSpecialization = function() return 1 end
GetSpecializationInfo = function() return 70 end
GetShapeshiftFormID = function() return 0 end
UnitAffectingCombat = function() return true end
RAID_CLASS_COLORS = { PALADIN = { r = 0.96, g = 0.55, b = 0.73 } }
PowerBarColor = { HOLY_POWER = { r = 0.95, g = 0.9, b = 0.6 } }

local DF = { PartyDefaults = { frameWidth = 125, frameHeight = 40, backgroundColor = { r = 0.2, g = 0.2, b = 0.2, a = 0.7 },
                               resourceBarBackgroundColor = { r = 0, g = 0, b = 0, a = 0.8 } },
             registered = {} }
function DF:Debug() end
function DF:DebugWarn() end
local errs = {}
function DF:DebugError(_, fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
local colorAsked
function DF:GetResourceBarColor(unit, db, class, token)
    colorAsked = { unit, class, token }
    return 0.1, 0.2, 0.9
end
DandersFrames = DF

local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }
load_uf_file_into("Elements.lua", UF)
load_uf_file_into("Rings.lua", UF)
load_uf_file_into("Portrait.lua", UF)
load_uf_file_into("ClassPower.lua", UF)
load_uf_file_into("Preview.lua", UF)
local R = UF.Rings

local function near(a, b) return math.abs(a - b) < 1e-9 end

print("-- Rings: defaults")
for _, unit in ipairs(UF.UNITS) do
    local db = UF:GetUnitDB(unit)
    eq(db.frameStyle, "BARS", unit .. ": Bars by default (nothing changes)")
end
local pdb = UF:GetUnitDB("player")
eq(pdb.ringSize, 64, "ring size 64")
local list = pdb.rings
eq(#list, 2, "two rings")
eq(list[1].sections[1].bar, "HEALTH", "ring 1 (inner): health")
eq(list[1].thickness, 8, "...8 thick")
eq(list[2].sections[1].bar, "POWER", "ring 2: power")
check(list[2].thickness == 4 and list[2].gap == 2, "...4 thick, 2 out")
check(list ~= UF.RING_DEFAULTS and list ~= UF:GetUnitDB("target").rings,
      "the default list is copied per unit, never shared")
list[1].thickness = 9
eq(UF.RING_DEFAULTS[1].thickness, 8, "an in-place edit never reaches the defaults")
list[1].thickness = 8

print("-- Rings: the list, cleaned")
local clean = R.List({ rings = { { thickness = 99, gap = -3, sections = { { bar = "NOPE", coverage = "X", position = "Y",
    feather = 5 } } }, "junk", {}, {}, {}, {} } })
eq(#clean, 4, "at most four rings (junk skipped)")
eq(clean[1].thickness, 40, "thickness clamped")
eq(clean[1].gap, 0, "gap clamped")
local s = clean[1].sections[1]
check(s.bar == "HEALTH" and s.coverage == "FULL" and s.position == "TOP" and s.feather == 1,
      "unknown section values become the defaults")
eq(#clean[2].sections, 0, "a ring with no sections keeps its place")
eq(#R.List({}), 2, "no list: the default")

print("-- Rings: geometry")
local geo = R.Geometry({ ringSize = 64, rings = UF.RING_DEFAULTS })
eq(geo.size, 64, "size")
check(geo.rings[2].outer == 64 and geo.rings[2].inner == 56, "outer ring at the frame's edge: 64 / 56")
check(geo.rings[1].outer == 52 and geo.rings[1].inner == 36, "inner ring 2px in: 52 / 36")
eq(geo.hole, 32, "the portrait's room: inside ring 1, less ring 1's gap")
eq(R.Geometry({ ringSize = 10 }).size, 24, "ring size clamped at 24")
eq(R.Geometry({ ringSize = 30, rings = { { thickness = 40, gap = 5, sections = {} } } }).hole, 0,
   "a ring thicker than its radius leaves no hole (never negative)")

print("-- Rings: arcs (Start = a, End = 1 - length)")
local a, len = R.Arc({ coverage = "FULL", position = "LEFT" })
check(a == 0 and len == 1, "full: the whole circle from the bottom")
eq(select(2, R.Offsets(a, len)), 0, "full: nothing cut off")
a, len = R.Arc({ coverage = "HALF", position = "TOP" })
check(near(a, 0.25) and near(len, 0.5), "top half: 0.25 .. 0.75 (left, top, right)")
local st, en = R.Offsets(a, len)
check(near(st, 0.25) and near(en, 0.5), "top half: Start 0.25, End 0.5 (what /dfring drew)")
a, len = R.Arc({ coverage = "HALF", position = "BOTTOM" })
check(near(a, 0.75) and near(len, 0.5), "bottom half wraps through 0: starts at 0.75")
a, len = R.Arc({ coverage = "HALF", position = "LEFT" })
check(near(a, 0) and near(len, 0.5), "left half: bottom to top, clockwise")
a, len = R.Arc({ coverage = "QUARTER", position = "RIGHT" })
check(near(a, 0.625) and near(len, 0.25), "right quarter: centred on 0.75")
a, len = R.Arc({ coverage = "QUARTER", position = "TOPLEFT" })
check(near(a, 0.25) and near(len, 0.25), "top-left quarter: 9 to 12 o'clock")
a, len = R.Arc({ coverage = "HALF", position = "TOP" }, true)
check(near(a, 0.25 + R.SECTION_GAP) and near(len, 0.5 - 2 * R.SECTION_GAP),
      "two sections on a ring: each pulled in at both ends")

print("-- Rings: reverse keeps the arc where it is (every coverage x position)")
do
    -- What a radial fill covers, as seen in game: forward, Start .. Start + length
    -- clockwise; reversed, Start - length .. Start (counter-clockwise from Start).
    local function covered(st, en, rev)
        local len = 1 - en
        if rev then return (st - len) % 1, len end
        return st % 1, len
    end
    local positions = { "TOP", "BOTTOM", "LEFT", "RIGHT", "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }
    local bar = R.NewArcBar(Make("Frame", UIParent))
    local all, n = true, 0
    for _, cov in ipairs({ "FULL", "HALF", "QUARTER" }) do
        for _, pos in ipairs(positions) do
            for _, multi in ipairs({ false, true }) do
                local sec = { coverage = cov, position = pos }
                local a0, l0 = R.Arc(sec, multi)
                for _, rev in ipairs({ false, true }) do
                    R.ShapeArcBar(bar, bar, 64, 48, a0, l0, rev, 0)
                    local c = bar:GetStatusBarTexture()._calls
                    local ca, cl = covered(c.SetRadialProgressBarStartOffset, c.SetRadialProgressBarEndOffset, rev)
                    local same = near(cl, l0) and (near(ca, a0 % 1) or near(math.abs(ca - a0 % 1), 1) or l0 >= 1)
                    if not same then
                        all = false
                        print(string.format("    mismatch %s %s multi=%s rev=%s: want %.3f+%.3f got %.3f+%.3f",
                            cov, pos, tostring(multi), tostring(rev), a0, l0, ca, cl))
                    end
                    if c.SetRadialProgressBarReverse ~= rev then all = false end
                    n = n + 1
                end
            end
        end
    end
    check(all, "reverse: the same arc, filled from the other end (" .. n .. " combinations)")
    local st = select(1, R.Offsets(0.75, 0.5, true))
    check(near(st, 0.25), "bottom half reversed: Start at 0.25 (its far end), not 0.75")
    local st2, en2 = R.Offsets(0.75, 0.5, false)
    check(near(st2, 0.75) and near(en2, 0.5), "bottom half forward: unchanged")
end

print("-- Rings: pips")
local pips = R.PipArcs(0, 1, 5, 0.01)
eq(#pips, 5, "five pips")
check(near(pips[1].start, 0.01) and near(pips[1].len, 0.18), "pip 1: its fifth, 0.01 clear each end")
check(near(pips[5].start, 0.81), "pip 5: the last fifth")
pips = R.PipArcs(0.25, 0.5, 4, 0.2)
check(near(pips[1].len, 0.125), "a gap too big for the slice is dropped")
eq(#R.PipArcs(0, 1, 0), 0, "no pips: no arcs")

print("-- Rings: the frame view's answers")
check(not R.FrameValue({ frameStyle = "BARS" }, "frameWidth"), "Bars: nothing answered")
local rdb = { frameStyle = "RING", ringSize = 80, rings = UF.RING_DEFAULTS }
local h, v = R.FrameValue(rdb, "frameWidth")
check(h and v == 80, "Ring: the frame is ringSize wide...")
h, v = R.FrameValue(rdb, "frameHeight")
check(h and v == 80, "...and tall")
h, v = R.FrameValue(rdb, "resourceBarEnabled")
check(h and v == false, "the power bar the rings replace is off")
h, v = R.FrameValue(rdb, "healPredictionEnabled")
check(h and v == false, "heal prediction off")
h, v = R.FrameValue(rdb, "portraitShape")
check(h and v == "CIRCLE", "the portrait is round")
check(not R.FrameValue(rdb, "classPowerEnabled"), "class power: the unit's own without a section")
local cpdb = { frameStyle = "RING", rings = { { thickness = 6, gap = 2, sections = { { bar = "CLASSPOWER" } } } } }
h, v = R.FrameValue(cpdb, "classPowerEnabled")
check(h and v == true, "a class power section turns class power on...")
h, v = R.FrameValue(cpdb, "classPowerDetached")
check(h and v == false, "...attached (in the ring)")

print("-- Rings: UF:FrameDB")
local eff = UF:GetUnitDB("target")
check(UF:FrameDB("target") == eff, "Bars: the frames read the unit's table itself")
eff.frameStyle = "RING"
eff.ringSize = 72
local view = UF:FrameDB("target")
check(view ~= eff, "Ring: a view")
eq(view.frameWidth, 72, "the view: width = ring size")
eq(eff.frameWidth, 220, "the unit's own width is untouched (the settings page reads it)")
eq(view.showBuffs, eff.showBuffs, "every other key passes through")
view.portraitAlpha = 0.5
eq(UF:GetStoredUnit("target").portraitAlpha, 0.5, "writes reach the unit's table")
eq(getmetatable(view).__realTable, UF:GetStoredUnit("target"), "__realTable: the stored table")
check(UF:FrameDB("target") == view, "one view per unit")
eff.frameStyle = "BARS"
check(UF:FrameDB("target") == eff, "back to Bars: the table again")

print("-- Rings: the preview's table answers the same")
eff.frameStyle = "RING"
local prev = UF.Preview:PreviewDB("target")
eq(prev.frameWidth, 72, "preview: ring size")
eq(prev.resourceBarEnabled, false, "preview: no power bar")
eff.frameStyle = "BARS"
eq(prev.frameWidth, 220, "preview, Bars: the unit's width")

print("-- Rings: the element (Ring)")
local function Owner(unit)
    local f = Make("Button", UIParent)
    f.dfUFUnit, f.unit = unit, unit
    f.healthBar = Make("StatusBar", f)
    f.background = Make("Texture", f)
    f.missingHealthBar = Make("StatusBar", f)
    return f
end
eff.frameStyle = "RING"
local F = Owner("target")
F.dfDB = UF:FrameDB("target")
R:Attach(F)
check(F.dfUFRings ~= nil and F.dfUFRingHooked, "attach: a container, the health bar hooked")
F.healthBar:SetMinMaxValues(0, 100)
F.healthBar:SetValue(62)
F.healthBar:GetStatusBarTexture():SetVertexColor(0.5, 0.6, 0.7)
R:Layout(F)
local c = F.dfUFRings
check(c._shown and c._w == 72, "layout: the container, ring size square")
eq(#F.dfUFRingHealth, 1, "one health fill")
eq(#F.dfUFRingPower, 1, "one power fill")
local fill = F.dfUFRingHealth[1]
eq(fill._render, 1, "a radial bar")
local tex = fill:GetStatusBarTexture()
eq(#tex._masks, 2, "two masks on the fill")
check(tex._masks[1]._texture == R.DISC and tex._masks[1]._wrap == "CLAMPTOBLACKADDITIVE", "outer: Blizzard's disc, black outside")
check(tex._masks[2]._texture == R.HOLE and tex._masks[2]._wrap == "CLAMPTOWHITE", "inner: the hole, white outside")
eq(fill._w, 60, "the health ring's outer diameter (72, less the power ring and its gap)")
eq(fill._value, 62, "a new fill starts from the health bar's value")
eq(tex._vertex[1], 0.5, "...and its colour")
eq(F.healthBar._alpha, 0, "the health bar goes see-through")
check(not F.background._shown, "the background hides")
eq(fill:GetStatusBarTexture()._calls.SetRadialProgressBarEndOffset, 0, "a full ring: nothing cut off")

print("-- Rings: health writes copied onto the fills")
local sv = Secret("hp")
F.healthBar:SetValue(sv, 3)
check(fill._value == sv and fill._interp == 3, "SetValue: a secret passed on unread, with its interpolation")
local smax = Secret("max")
F.healthBar:SetMinMaxValues(0, smax)
check(fill._max == smax, "SetMinMaxValues passed on")
local sr = Secret("r")
F.healthBar:GetStatusBarTexture():SetVertexColor(sr, 0.2, 0.3)
check(tex._vertex[1] == sr and tex._vertex[4] == nil, "the texture's colour passed on (no alpha: none sent)")
F.healthBar:GetStatusBarTexture():SetAlpha(0.4)
eq(tex._alpha, 0.4, "the texture's alpha passed on (out of range)")
local inRange = Secret("range")
F.healthBar:GetStatusBarTexture():SetAlphaFromBoolean(inRange, 1, 0.2)
check(tex._alphaFrom and tex._alphaFrom[1] == inRange, "SetAlphaFromBoolean passed on")

print("-- Rings: power")
eq(F.dfUFRingPower[1]._value, 30, "fed from UnitPower on layout")
eq(F.dfUFRingPower[1]._barColor[3], 0.9, "coloured by DandersFrames' resource colour")
power = Secret("power")
R:OnUnitEvent(F, "UNIT_POWER_UPDATE")
check(F.dfUFRingPower[1]._value == power, "UNIT_POWER_UPDATE: a secret power passed on")
power = 40
R:OnUnitEvent(F, "UNIT_AURA")
check(F.dfUFRingPower[1]._value ~= 40, "other events leave it alone")
R:Refresh(F)
eq(F.dfUFRingPower[1]._value, 40, "refresh feeds it")

print("-- Rings: sections")
eff.rings = { { thickness = 10, gap = 2, sections = {
    { bar = "HEALTH", coverage = "HALF", position = "LEFT", reverse = true, feather = 0.3 },
    { bar = "POWER", coverage = "HALF", position = "RIGHT" } } } }
R:Layout(F)
eq(#F.dfUFRingHealth, 1, "half health...")
eq(#F.dfUFRingPower, 1, "...half power, one ring")
local ht = F.dfUFRingHealth[1]:GetStatusBarTexture()._calls
check(near(ht.SetRadialProgressBarStartOffset, 0.5 - R.SECTION_GAP), "left half, reversed: starts at its far (top) end, pulled in")
check(near(ht.SetRadialProgressBarEndOffset, 0.5 + 2 * R.SECTION_GAP), "...and cuts off the other half and the gaps")
check(ht.SetRadialProgressBarReverse == true and ht.SetRadialProgressBarFeather == 0.3, "reverse and feather")
check(c.arcs[2].track._shown and c.arcs[2].fill._shown, "two arcs drawn")
eff.rings = { { thickness = 10, gap = 2, sections = { { bar = "HEALTH" } } } }
R:Layout(F)
check(not c.arcs[2].fill._shown and not c.arcs[2].track._shown, "an arc no longer needed hides")

print("-- Rings: back to Bars")
eff.frameStyle = "BARS"
F.dfDB = UF:FrameDB("target")
R:Layout(F)
check(not c._shown, "the rings hide")
eq(F.dfUFRingHealth, nil, "no fills: the hooks do nothing")
eq(F.healthBar._alpha, 1, "the health bar shows again")
check(F.background._shown, "the background too")
F.healthBar:SetValue(5)
eq(fill._value ~= 5, true, "a health write no longer reaches the old fill")

print("-- Rings: a Bars frame is never touched")
local B = Owner("player")
B.dfDB = UF:FrameDB("player")
B.healthBar._alpha = 0.7
R:Attach(B)
R:Layout(B)
eq(B.healthBar._alpha, 0.7, "Bars: the health bar's alpha is left as it was")

print("-- Rings: the preview")
eff.frameStyle = "RING"
eff.rings = deepcopy(UF.RING_DEFAULTS)
local PF = Owner("target")
PF.dfUFPreview, PF.dfPreview = true, true
PF.dfDB = UF.Preview:PreviewDB("target")
PF.dfTestData = { powerPercent = 0.4, class = nil }
R:Attach(PF)
R:Preview(PF)
check(PF.dfUFRings._shown, "preview: rings drawn")
eq(PF.dfUFRingPower[1]._value, 0.4, "preview: the sample's power share")
check(colorAsked[1] == nil and colorAsked[3] == "MANA", "preview: a sample unit's colour by power type")

print("-- Rings: portrait in the middle")
local PO = UF.Portrait
eff.portraitEnabled = true
eff.portraitBorderSize = 1
local PP = Owner("target")
PP.dfDB = UF:FrameDB("target")
PO:Attach(PP)
PO:Layout(PP)
local p = PP.dfUFPortrait
local geoT = R.Geometry(PP.dfDB)
eq(p._w, geoT.hole - 2, "size: the hole inside the inner ring, less its border")
eq(p._points[#p._points][1], "CENTER", "centred")
eq(select(1, PO.OutsideExtent(PP, PP.dfDB)), 0, "reaches nothing outside the frame")
eq(PP.dfDB.portraitShape, "CIRCLE", "round")
eff.frameStyle = "BARS"
PP.dfDB = UF:FrameDB("target")
check(PO.RingSize(PP.dfDB) == nil, "Bars: the normal size")

print("-- Rings: class power in a ring")
local CP = UF.ClassPower
local pdbe = UF:GetUnitDB("player")
pdbe.frameStyle = "RING"
pdbe.rings = { { thickness = 8, gap = 2, sections = { { bar = "HEALTH" } } },
               { thickness = 4, gap = 2, sections = { { bar = "CLASSPOWER", coverage = "HALF", position = "TOP" } } } }
local PL = Owner("player")
PL.dfDB = UF:FrameDB("player")
R:Attach(PL)
CP:Attach(PL)
R:Layout(PL)
CP:Layout(PL)
local cp = PL.dfUFClassPower
check(cp.inRing, "class power drawn in the ring")
eq(#PL.dfUFRingHealth + #PL.dfUFRingPower, 1, "the rings element skips the class power section")
eq(#cp.active, 5, "five holy power pips")
eq(cp.active[1]._render, 1, "...radial")
check(cp.active[3]._min == 2 and cp.active[3]._max == 3, "pip 3 ranged 2..3")
local p1 = cp.active[1]:GetStatusBarTexture()._calls
check(near(p1.SetRadialProgressBarStartOffset, 0.25 + R.PIP_GAP), "pip 1 at the start of the top half")
CP:Update(PL)
eq(cp.active[2]._value, 3, "all fed the same value")
local linearShown = false
for _, pip in ipairs(cp.pips) do if pip._shown then linearShown = true end end
check(not linearShown, "the linear pips hide")
pdbe.rings[2].sections[1].reverse = true
CP:Layout(PL)
local rp1 = cp.active[1]:GetStatusBarTexture()._calls
local rp5 = cp.active[5]:GetStatusBarTexture()._calls
check(near(rp1.SetRadialProgressBarStartOffset, 0.75 - R.PIP_GAP) and rp1.SetRadialProgressBarReverse,
      "reversed: pip 1 at the far end of the top half, filling back from its own far end")
local slice = 0.5 / 5
check(near(rp5.SetRadialProgressBarStartOffset, 0.25 + slice - R.PIP_GAP), "reversed: pip 5 at the start of the arc")
pdbe.rings[2].sections[1].reverse = nil
pdbe.frameStyle = "BARS"
PL.dfDB = UF:FrameDB("player")
CP:Layout(PL)
check(not cp.inRing and not cp.ringPips[1].fill._shown, "Bars: the ring pips hide")
check(cp.active == cp.pips, "...and the linear pips are written again")

print("-- Rings: links")
local Lk = UF.Links
Lk.ResetCaches()
eq(Lk.OwnerOf("frameStyle"), "rings", "frameStyle: the Frame Style element's, not the Frame page's")
eq(Lk.OwnerOf("rings"), "rings", "rings")
eq(Lk.OwnerOf("ringSize"), "rings", "ringSize")
check(Lk.OwnerOf("frameWidth") ~= "rings", "frameWidth stays the Frame page's")

print("-- Rings: the settings page's list edits")
do
    local src = options_file_source("UnitFrames/Pages.lua"):gsub("\r\n", "\n")
    local s0 = src:find("UFO.RING_MAX = 4", 1, true)
    local s1 = src:find("function UFO.BuildRingsPage", 1, true)
    check(s0 and s1, "the list edits can be cut out of Pages.lua")
    local env = setmetatable({ UFO = {} }, { __index = _G })
    local fn = (loadstring or load)(src:sub(s0, s1 - 1))
    setfenv(fn, env)
    fn()
    local U = env.UFO
    local rings = deepcopy(UF.RING_DEFAULTS)
    check(U.RingMove(rings, 2, -1) and rings[1].sections[1].bar == "POWER", "move a ring in")
    check(not U.RingMove(rings, 1, -1), "the innermost cannot move further in")
    check(U.RingAdd(rings) and #rings == 3, "add a ring")
    U.RingAdd(rings)
    check(not U.RingAdd(rings), "at most four")
    check(U.RingRemove(rings, 4) and #rings == 3, "remove one")
    local one = { rings[1] }
    check(not U.RingRemove(one, 1), "the last ring stays")
    check(U.RingSectionAdd(rings[1]) and #rings[1].sections == 2, "add a section")
    for _ = 1, 5 do U.RingSectionAdd(rings[1]) end
    eq(#rings[1].sections, 4, "at most four sections")
    check(U.RingSectionRemove(rings[1], 2) and #rings[1].sections == 3, "remove a section")
end

print("-- Rings: Text Designer spots")
do
    local f = {}
    eq(R.AnchorSpot(f, "RING_ABOVE"), nil, "no ring layout (Bars): no answer, the renderer uses the frame's edges")
    f.dfUFRingGeom = R.Geometry({ ringSize = 64, rings = UF.RING_DEFAULTS })
    local x, y = R.AnchorSpot(f, "RING_ABOVE")
    check(x == 0 and y == 32, "above: the outer ring's top")
    x, y = R.AnchorSpot(f, "RING_BELOW")
    check(x == 0 and y == -32, "below")
    x, y = R.AnchorSpot(f, "RING_CENTER")
    check(x == 0 and y == 0, "centre")
    x = R.AnchorSpot(f, "RING_GAP_RIGHT")
    eq(x, 32, "a full outer ring: the side spot falls back to its edge")
    f.dfUFRingGeom = R.Geometry({ ringSize = 64, rings = {
        { thickness = 8, gap = 2, sections = { { bar = "HEALTH" } } },
        { thickness = 6, gap = 2, sections = { { bar = "POWER", coverage = "HALF", position = "LEFT" } } } } })
    x = R.AnchorSpot(f, "RING_GAP_RIGHT")
    eq(x, (64 + 52) / 4, "right side open: the middle of the outer band there")
    x = R.AnchorSpot(f, "RING_GAP_LEFT")
    eq(x, -32, "left side covered: its edge")
    check(R.Covers({ sections = { { coverage = "QUARTER", position = "BOTTOM" } } }, 0), "a bottom quarter covers the bottom (wraps through 0)")
    check(not R.Covers({ sections = { { coverage = "QUARTER", position = "BOTTOM" } } }, 0.5), "...not the top")
    check(not R.Covers({ sections = {} }, 0.25), "no sections: open")
end

print("-- Rings: portrait dims on hover")
do
    local PO = UF.Portrait
    eq(UF:GetUnitDB("target").portraitDimHover, false, "off by default")
    local H = Owner("target")
    H.dfDB = UF:FrameDB("target")
    PO:Attach(H)
    PO:Layout(H)
    eff.portraitAlpha = 0.8
    UF.OnHover(H, true)
    eq(H.dfUFPortrait._alpha, 0.8, "off: hover leaves it alone")
    eff.portraitDimHover = true
    UF.OnHover(H, true)
    check(math.abs(H.dfUFPortrait._alpha - 0.8 * PO.DIM) < 1e-9, "on: dimmed while hovered")
    UF.OnHover(H, false)
    eq(H.dfUFPortrait._alpha, 0.8, "...and back")
    H.dfIsHovered = true
    PO:Layout(H)
    check(H.dfUFPortrait._alpha < 0.8, "a layout while hovered keeps it dimmed")
    eff.portraitDimHover, eff.portraitAlpha = nil, nil
end

print("-- Rings: a settings sample of a unit (the Text Designer's preview)")
do
    local P = UF.Preview
    eff.frameStyle = "RING"
    local panel = Make("Frame", UIParent)
    local smp = P:BuildSample("target", panel)
    check(smp.dfUFSample and smp.dfUFPreview and smp.dfIsTestFrame, "built as a preview frame, marked a sample")
    check(P.frames.target ~= smp, "never one of the preview's own frames")
    eq(UF.Elements.Kit.DetachedParent(smp), smp.dfUFSampleHold, "its detached pieces go to its hidden holder")
    check(not smp.dfUFSampleHold._shown, "...which never shows")
    smp:SetScale(0.6)
    smp._points = {}
    P:PaintSample(smp)
    check(smp._shown, "painted and shown")
    eq(smp._scale, 0.6, "its owner's scale is kept")
    eq(#smp._points, 0, "never placed on the screen")
    check(smp.dfUFRings._shown, "drawn as the unit really looks: rings")
    eq(smp.dfDB.frameWidth, 72, "...at the ring's size")
    smp._painted = 0
    local paint = P.Paint
    P.Paint = function(self, f) f._painted = (f._painted or 0) + 1 end
    P:RefreshSamples()
    eq(smp._painted, 1, "RefreshSamples repaints a visible sample")
    smp:Hide()
    P:RefreshSamples()
    eq(smp._painted, 1, "...and leaves a hidden one")
    P.Paint = paint
    eff.frameStyle = "BARS"
end

print("-- Rings: Text Designer presets")
do
    local lib = { ["Ring: Side Plate"] = { userEdit = true } }
    DF.GetTextDesignerPresets = function() return lib end
    DF.NewTextDesignerConfig = function() return { elements = { { id = 1, contentType = "name" } } } end
    check(UF:EnsureTextPresets(), "made")
    eq(lib["Ring: Side Plate"].userEdit, true, "an existing one is never overwritten")
    lib["Ring: Side Plate"] = nil
    UF:EnsureTextPresets()
    local function byType(cfg, ct)
        local out = {}
        for _, e in ipairs(cfg.elements) do if e.contentType == ct then out[#out + 1] = e end end
        return out
    end
    local plate = lib["Ring: Side Plate"]
    check(plate and plate.enabled, "Side Plate: made, on")
    local bd = byType(plate, "backdrop")[1]
    check(bd and bd.layer == "BEHIND" and bd.anchorTo == "RING_GAP_RIGHT" and bd.offsetX < 0,
          "Side Plate: a box tucked behind the ring's right side")
    local lines = 0
    for _, e in ipairs(plate.elements) do
        if e.contentType ~= "backdrop" then
            lines = lines + 1
            eq(e.anchorTo, tostring(bd.id), "Side Plate: " .. e.contentType .. " sits on the plate")
        end
    end
    eq(lines, 3, "Side Plate: name / health / power")
    local grp = byType(plate, "group")[1]
    check(grp.groupItems[1].contentType == "hp_current" and grp.groupItems[1].abbreviate
          and grp.groupItems[2].contentType == "hp_percent", "Side Plate: health abbreviated, then percent")
    local tag = lib["Ring: Name and Tag"]
    eq(byType(tag, "name")[1].anchorTo, "RING_ABOVE", "Name and Tag: the name above the ring")
    local pill = byType(tag, "backdrop")[1]
    check(pill.shape == "PILL" and pill.anchorTo == "RING_BELOW", "Name and Tag: a pill below it")
    local tg = byType(tag, "group")[1]
    check(tg.anchorTo == tostring(pill.id) and tg.groupSeparator == " | ", "...with health % | power on it")
    local hv = lib["Ring: Centre on Hover"]
    check(hv.dimPortraitOnHover, "Centre on Hover: asks for the portrait to dim")
    local all = true
    for _, e in ipairs(hv.elements) do if not e.showOnHover then all = false end end
    check(all and #hv.elements == 3, "Centre on Hover: three elements, all shown on hover")
    local pct = byType(hv, "hp_percent")[1]
    check(pct.anchorTo == "RING_CENTER" and pct.fontSize > 12 and pct.overrides.fontSize, "...health % large in the centre")
    local ids = {}
    for _, e in ipairs(hv.elements) do ids[e.id] = true end
    eq(hv.nextElementID, #hv.elements + 1, "element ids run on from 1")

    -- Picking it on a unit's page turns that unit's Dim on Hover on.
    local src = options_file_source("UnitFrames/Pages.lua"):gsub("\r\n", "\n")
    local s0 = src:find("function UFO.ApplyTemplateRequests(unit)", 1, true)
    local s1 = src:find("-- The Text Designer's preview on a unit page", 1, true)
    check(s0 and s1, "the template request can be cut out of Pages.lua")
    local env = setmetatable({ UFO = {}, DF = { UnitFrames = UF, GetTextDesignerPresets = function() return lib end } },
        { __index = _G })
    local fn = (loadstring or load)(src:sub(s0, s1 - 1))
    setfenv(fn, env)
    fn()
    local tdb = UF:GetUnitDB("focus")
    tdb.textDesignerPreset = "Ring: Name and Tag"
    env.UFO.ApplyTemplateRequests("focus")
    eq(tdb.portraitDimHover, false, "a template that asks nothing changes nothing")
    tdb.textDesignerPreset = "Ring: Centre on Hover"
    env.UFO.ApplyTemplateRequests("focus")
    eq(tdb.portraitDimHover, true, "Centre on Hover: the unit's portrait dims on hover")
    check(src:find('if kind == "text" then UFO.ApplyTemplateRequests(unit) end', 1, true) ~= nil,
          "...asked on every text template change on a unit page")
end

eq(#errs, 0, "no element errors")

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
for k, v in pairs(ENUM_HELD) do Enum[k] = v end
