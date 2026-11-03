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
                     "GetSpecialization", "GetSpecializationInfo", "GetShapeshiftFormID", "UnitAffectingCombat",
                     "CreateUnitHealPredictionCalculator", "UnitGetDetailedHealPrediction" }
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
    function f:SetBlendMode(m) self._blend = m end
    function f:SetHorizTile(v) self._hTile = v end
    function f:SetVertTile(v) self._vTile = v end
    function f:SetTexCoord(a, b, c, d) self._coord = { a, b, c, d } end
    if kind == "StatusBar" then
        f._tex = Make("Texture", f)
        f._min, f._max, f._value = 0, 1, 0
        function f:SetStatusBarTexture(path)
            self._path = path
            self._pathSets = (self._pathSets or 0) + 1
            if self._newTexOnSet then self._tex = Make("Texture", self) end
        end
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
eq(pdb.ringSize, 130, "Player: ring size 130")
eq(pdb.ringPortrait3D, "COVER", "a 3D portrait fills the circle, corners covered")
eq(pdb.ringTextDesignerPreset, "Unit Frames Ring", "the ring text template")
local list = pdb.rings
eq(#list, 2, "two rings")
eq(list[1].thickness, 16, "ring 1 (inner): 16 thick")
eq(list[1].gap, 0, "...flush with the portrait")
local hs, ps = list[1].sections[1], list[1].sections[2]
check(hs.bar == "HEALTH" and hs.coverage == "HALF" and hs.position == "LEFT", "...health down the left half")
check(ps.bar == "POWER" and ps.coverage == "HALF" and ps.position == "RIGHT" and ps.reverse == true,
      "...power down the right, filling the other way")
check(list[2].thickness == 5 and list[2].gap == 0 and list[2].sections[1].bar == "CLASSPOWER"
      and list[2].sections[1].coverage == "FULL", "ring 2: class power, 5 thick")
check(list ~= UF.RING_DEFAULTS and list ~= UF:GetUnitDB("target").rings,
      "the default list is copied per unit, never shared")
list[1].thickness = 9
eq(UF.RING_DEFAULTS[1].thickness, 16, "an in-place edit never reaches the defaults")
list[1].thickness = 16
for _, unit in ipairs({ "target", "focus" }) do
    local d = UF:GetUnitDB(unit)
    eq(d.ringSize, 130, unit .. ": ring size 130")
    local health, power = d.rings[1].sections[1], d.rings[1].sections[2]
    -- Target is Player's mirror image; Focus isn't in the default link.
    local healthSide, powerSide = "LEFT", "RIGHT"
    if unit == "target" then healthSide, powerSide = "RIGHT", "LEFT" end
    check(#d.rings == 1 and d.rings[1].thickness == 16 and health.position == healthSide and power.position == powerSide,
          unit .. ": the health and power ring, and no class power ring (it would draw nothing)")
    check((health.reverse == true) == (unit == "target") and (power.reverse == true) == (unit ~= "target"),
          unit .. ": ...the right-hand bar filling the other way")
end
for _, unit in ipairs({ "pet", "targettarget", "focustarget", "boss" }) do
    local d = UF:GetUnitDB(unit)
    eq(d.ringSize, 64, unit .. ": ring size 64")
    check(#d.rings == 1 and d.rings[1].thickness == 8 and d.rings[1].gap == 0 and d.rings[1].sections[1].coverage == "HALF",
          unit .. ": the same ring at half the thickness")
    eq(d.ringPortrait3D, "COVER", unit .. ": COVER")
    eq(d.ringTextDesignerPreset, "Unit Frames Ring", unit .. ": the same text template")
end
for _, unit in ipairs(UF.UNITS) do
    check(R.CoverAllowed(UF:GetUnitDB(unit)), unit .. ": its default layout allows COVER")
    check(not R.RingOverlaps(UF:GetUnitDB(unit).rings[1]), unit .. ": its halves do not overlap")
end
do
    local stored = { units = { player = { rings = { { thickness = 3, gap = 1, sections = {} } }, ringSize = 50 } }, global = { unitLinks = {} } }
    UF.MigrateProfileTable(stored)
    check(stored.units.player.ringSize == 50 and stored.units.player.rings[1].thickness == 3, "stored rings are left as they are")
end

-- The rest of this file checks the maths against a fixed list, not the defaults.
local TWO_RINGS = {
    { thickness = 8, gap = 2, sections = { { bar = "HEALTH", coverage = "FULL", position = "TOP" } } },
    { thickness = 4, gap = 2, sections = { { bar = "POWER", coverage = "FULL", position = "TOP" } } },
}

print("-- Rings: the list, cleaned")
local clean = R.List({ rings = { { thickness = 99, gap = -3, sections = { { bar = "NOPE", coverage = "X", position = "Y",
    feather = 5 } } }, "junk", {}, {}, {}, {}, {}, {}, {}, {}, {} } })
eq(#clean, 8, "at most eight rings (junk skipped)")
eq(clean[1].thickness, 40, "thickness clamped")
eq(clean[1].gap, 0, "gap clamped")
local s = clean[1].sections[1]
check(s.bar == "HEALTH" and s.coverage == "FULL" and s.position == "TOP" and s.feather == 1,
      "unknown section values become the defaults")
eq(#clean[2].sections, 0, "a ring with no sections keeps its place")
eq(#R.List({}), 2, "no list: the default")

print("-- Rings: geometry")
local geo = R.Geometry({ ringSize = 64, rings = TWO_RINGS })
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
a, len = R.Arc({ coverage = "HALF", position = "LEFT" })
local a2, len2 = R.Arc({ coverage = "HALF", position = "RIGHT" })
check(near((a + len) % 1, a2) and near((a2 + len2) % 1, a), "two halves on a ring meet: no gap between them")

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
            do
                local sec = { coverage = cov, position = pos }
                local a0, l0 = R.Arc(sec)
                for _, rev in ipairs({ false, true }) do
                    R.ShapeArcBar(bar, bar, 64, 48, a0, l0, rev, 0)
                    local c = bar:GetStatusBarTexture()._calls
                    local ca, cl = covered(c.SetRadialProgressBarStartOffset, c.SetRadialProgressBarEndOffset, rev)
                    local same = near(cl, l0) and (near(ca, a0 % 1) or near(math.abs(ca - a0 % 1), 1) or l0 >= 1)
                    if not same then
                        all = false
                        print(string.format("    mismatch %s %s rev=%s: want %.3f+%.3f got %.3f+%.3f",
                            cov, pos, tostring(rev), a0, l0, ca, cl))
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
local rdb = { frameStyle = "RING", ringSize = 80, rings = TWO_RINGS }
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
eff.rings = deepcopy(TWO_RINGS)
eff.ringPortrait3D = "FIT"
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

print("-- Rings: each bar's texture setting")
local RK = UF.Elements.Kit
eff.healthTexture, eff.resourceBarTexture = "HealthTex", "PowerTex"
eff.backgroundTexture = "BgTex"
F.dfDB = UF:FrameDB("target")
R:Layout(F)
eq(F.dfUFRingHealth[1]._path, "HealthTex", "a health fill: the health bar's texture")
eq(F.dfUFRingPower[1]._path, "PowerTex", "a power fill: the power bar's texture")
local healthTrack, powerTrack
for _, arc in ipairs(F.dfUFRings.arcs) do
    if arc.fill == F.dfUFRingHealth[1] then healthTrack = arc.track end
    if arc.fill == F.dfUFRingPower[1] then powerTrack = arc.track end
end
eq(healthTrack._path, "BgTex", "a health track: the background texture")
eq(powerTrack._path, RK.WHITE, "a power track stays plain")
local sets = F.dfUFRingHealth[1]._pathSets
R:Layout(F)
eq(F.dfUFRingHealth[1]._pathSets, sets, "the same texture isn't set again")
eff.backgroundTexture = "Solid"
F.dfDB = UF:FrameDB("target")
R:Layout(F)
eq(healthTrack._path, RK.WHITE, "a Solid background: a plain track")
eff.healthTexture, eff.resourceBarTexture, eff.backgroundTexture = nil, nil, nil
F.dfDB = UF:FrameDB("target")

local swapBar = R.NewArcBar(Make("Frame", UIParent))
swapBar._newTexOnSet = true
R.SetArcTexture(swapBar, "Other")
eq(swapBar._path, "Other", "a new file is set")
eq(#swapBar:GetStatusBarTexture()._masks, 2, "a new texture object gets both masks back")

print("-- Rings: shields, heal absorbs and incoming heals")
do
    local sShield, sAbsorb, sMine, sOthers, sAll, sMax =
        Secret("shield"), Secret("absorb"), Secret("mine"), Secret("others"), Secret("all"), Secret("max")
    CreateUnitHealPredictionCalculator = function()
        local calc = setmetatable({}, { __index = function() return function() end end })
        calc.GetDamageAbsorbs = function() return sShield, true end
        calc.GetHealAbsorbs = function() return sAbsorb end
        calc.GetIncomingHeals = function() return sAll, sMine, sOthers, true end
        calc.GetMaximumHealth = function() return sMax end
        return calc
    end
    UnitGetDetailedHealPrediction = function() end

    local saved = eff.rings
    local function One(bar, coverage, position)
        return { thickness = 4, gap = 0, sections = { { bar = bar, coverage = coverage, position = position } } }
    end
    eff.rings = { One("HEALTH", "HALF", "LEFT"), One("SHIELD", "FULL"), One("HEALABSORB", "FULL"),
                  One("INCOMING", "FULL"), One("POWER", "FULL"), One("HEALTH", "FULL"),
                  One("HEALTH", "QUARTER", "TOP"), One("HEALTH", "QUARTER", "BOTTOM") }
    eq(#R.List(eff), 8, "eight rings stay in the list")
    eff.absorbBarTexture, eff.healAbsorbBarTexture, eff.healPredictionTexture = "ShieldTex", "HealAbsorbTex", "IncomingTex"
    eff.absorbBarColor = { r = 0.1, g = 0.2, b = 0.3, a = 0.4 }
    eff.healPredictionShowMode = "MINE"
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)

    local am = F.dfUFRingAmounts
    eq(#F.dfUFRingHealth, 4, "the amounts' rings aren't health fills")
    eq(#F.dfUFRingPower, 1, "...or power fills")
    eq(#am.SHIELD, 5, "shield: its own ring and all four health sections")
    eq(#am.HEALABSORB, 5, "heal absorb: the same")
    eq(#am.INCOMING, 5, "incoming: the same")
    -- Listed in drawing order, outermost ring first: find each ring's own bar by its size.
    local function OwnRing(list)
        for _, bar in ipairs(list) do
            for _, arc in ipairs(F.dfUFRings.arcs) do
                if arc.fill == bar then return bar end
            end
        end
    end
    local shield, healAbsorb, incoming = OwnRing(am.SHIELD), OwnRing(am.HEALABSORB), OwnRing(am.INCOMING)
    eq(shield._path, "ShieldTex", "a shield ring: the absorb bar's texture")
    eq(healAbsorb._path, "HealAbsorbTex", "a heal absorb ring: its texture")
    eq(incoming._path, "IncomingTex", "an incoming ring: heal prediction's texture")
    eq(shield._barColor[1], 0.1, "a shield ring: the absorb bar's colour")
    check(shield._value == sShield and shield._max == sMax, "a secret shield and max passed on unread")
    check(healAbsorb._value == sAbsorb, "heal absorb")
    check(incoming._value == sMine, "incoming: Show mode Mine")

    local function OnHealth(list, own)
        for _, bar in ipairs(list) do
            if bar ~= own then return bar end
        end
    end
    local shieldOver, absorbOver = OnHealth(am.SHIELD, shield), OnHealth(am.HEALABSORB, healAbsorb)
    eq(shieldOver._path, "ShieldTex", "on the health ring: the same texture")
    eq(shieldOver:GetStatusBarTexture()._calls.SetRadialProgressBarReverse, true, "a shield on health fills back from the far end")
    eq(absorbOver:GetStatusBarTexture()._calls.SetRadialProgressBarReverse, false, "a heal absorb fills the same way as the health")

    shield._value = nil
    R:OnUnitEvent(F, "UNIT_ABSORB_AMOUNT_CHANGED")
    check(shield._value == sShield, "the absorb event feeds it")
    shield._value = nil
    R:OnUnitEvent(F, "UNIT_HEALTH")
    check(shield._value == sShield, "...and so does health")

    eff.ringShowShieldOnHealth = false
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
    am = F.dfUFRingAmounts
    eq(#am.SHIELD, 1, "switched off on the health ring: only its own ring")
    eq(#am.HEALABSORB, 5, "...the others stay")
    eff.ringShowHealAbsorbOnHealth, eff.ringShowIncomingOnHealth = false, false
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
    check(not shieldOver._shown, "a bar no longer used hides")
    eff.ringShowShieldOnHealth, eff.ringShowHealAbsorbOnHealth, eff.ringShowIncomingOnHealth = nil, nil, nil

    F.dfUFPreview = true
    F.dfTestData = { absorbPercent = 0.2, healAbsorbPercent = 0.1, healPredictionPercent = 0.3, powerPercent = 0.5 }
    F.dfDB = UF:FrameDB("target")
    R:Preview(F)
    eq(OwnRing(F.dfUFRingAmounts.SHIELD)._value, 0.2, "a preview: the sample's shield")
    eq(OwnRing(F.dfUFRingAmounts.HEALABSORB)._value, 0.1, "a preview: the sample's heal absorb")
    eq(OwnRing(F.dfUFRingAmounts.INCOMING)._value, 0.3, "a preview: the sample's incoming")
    F.dfUFPreview, F.dfTestData = nil, nil

    eff.rings = saved
    eff.absorbBarTexture, eff.healAbsorbBarTexture, eff.healPredictionTexture = nil, nil, nil
    eff.absorbBarColor, eff.healPredictionShowMode = nil, nil
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
end

print("-- Rings: texture layers")
do
    local function LayerKeys(prefix)
        local k = { on = prefix .. "TextureLayersEnabled" }
        for _, n in ipairs({ 2, 3 }) do
            local p = prefix .. "Layer" .. n
            k[n] = { enabled = p .. "Enabled", texture = p .. "Texture", color = p .. "Color",
                     blend = p .. "BlendMode", mirror = p .. "TileMirror" }
        end
        return k
    end
    DF.TEXTURE_LAYER_EXTRA = { 2, 3 }
    DF.TEXTURE_LAYER_KEYS = { health = LayerKeys("health"), resourceBar = LayerKeys("resourceBar"),
                              absorbBar = LayerKeys("absorbBar"), healAbsorbBar = LayerKeys("healAbsorbBar"),
                              healPrediction = LayerKeys("healPrediction") }
    function DF:ResolveBarTexture(path) return path end

    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
    local hf = F.dfUFRingHealth[1]
    eq(#hf.dfLayers, 0, "switch off: no layers")

    eff.healthLayer2Enabled, eff.healthLayer2Texture = true, "Stripes"
    eff.healthLayer2Color = { r = 0.1, g = 0.2, b = 0.3, a = 0.4 }
    eff.healthLayer2BlendMode = "ADD"
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
    eq(#hf.dfLayers, 0, "a ticked layer behind the switch stays off")

    eff.healthTextureLayersEnabled = true
    F.dfDB = UF:FrameDB("target")
    F.healthBar:SetMinMaxValues(0, 100)
    F.healthBar:SetValue(62)
    R:Layout(F)
    eq(#hf.dfLayers, 1, "switch on: one layer")
    local layer = hf.dfLayers[1]
    eq(layer._path, "Stripes", "the layer's texture")
    eq(layer._barColor[1], 0.1, "the layer's colour")
    eq(layer._barColor[4], 0.4, "...and alpha")
    eq(layer:GetStatusBarTexture()._blend, "ADD", "the layer's blend")
    eq(layer._w, hf._w, "the fill's size")
    eq(#layer:GetStatusBarTexture()._masks, 2, "cut to the ring")
    local lc, fc = layer:GetStatusBarTexture()._calls, hf:GetStatusBarTexture()._calls
    eq(lc.SetRadialProgressBarStartOffset, fc.SetRadialProgressBarStartOffset, "the fill's start")
    eq(lc.SetRadialProgressBarEndOffset, fc.SetRadialProgressBarEndOffset, "the fill's end")
    eq(layer:GetFrameLevel(), hf:GetFrameLevel() + 1, "above the fill")
    check(F.dfUFRingAmounts.SHIELD[1]:GetFrameLevel() > layer:GetFrameLevel(), "under what sits on the health ring")
    eq(layer._value, 62, "a new layer starts from the health value")

    local sv2, smax2 = Secret("hp2"), Secret("max2")
    F.healthBar:SetMinMaxValues(0, smax2)
    F.healthBar:SetValue(sv2)
    check(layer._value == sv2 and layer._max == smax2, "health writes reach the layer, secrets unread")
    F.healthBar:GetStatusBarTexture():SetAlpha(0.3)
    eq(layer:GetStatusBarTexture()._alpha, 0.3, "the health fill's fade too")
    F.healthBar:GetStatusBarTexture():SetVertexColor(0.9, 0.9, 0.9)
    eq(layer:GetStatusBarTexture()._vertex, nil, "...but not its colour")
    F.healthBar:GetStatusBarTexture():SetAlpha(1)
    F.healthBar:SetMinMaxValues(0, 100)
    F.healthBar:SetValue(62)

    eff.healthLayer2Color = { r = 0.7, g = 0.2, b = 0.3, a = 0.4 }
    F.dfDB = UF:FrameDB("target")
    R:PaintLayers(F)
    eq(layer._barColor[1], 0.7, "a colour drag repaints the layer")

    eff.resourceBarTextureLayersEnabled, eff.resourceBarLayer3Enabled, eff.resourceBarLayer3Texture = true, true, "PowerStripes"
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
    local pf = F.dfUFRingPower[1]
    eq(pf.dfLayers[1]._path, "PowerStripes", "a power fill has its own layers")
    eq(pf.dfLayers[1]._value, pf._value, "...with the power value")

    eff.healthTextureLayersEnabled, eff.resourceBarTextureLayersEnabled = nil, nil
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
    eq(#hf.dfLayers, 0, "switched off again: no layers")
    check(not layer._shown, "...and the bar hides")
    eff.healthLayer2Enabled, eff.healthLayer2Texture, eff.healthLayer2Color, eff.healthLayer2BlendMode = nil, nil, nil, nil
    eff.resourceBarLayer3Enabled, eff.resourceBarLayer3Texture = nil, nil
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
end

print("-- Rings: the bars' other texture settings")
do
    DF.TILE_SIZE_FIT = -1
    local applied = 0
    function DF:ResolveTileMode(path, override)
        if override == "OFF" then return nil end
        if override then return override end
        return path == "TiledTex" and "BOTH" or nil
    end
    function DF:ApplyBarTextureTiling() applied = applied + 1 end
    function DF:ResolveBarTexture(path, _, mirror) return mirror and (path .. "Mirrored") or path end
    for _, prefix in ipairs({ "health", "resourceBar", "absorbBar", "healAbsorbBar", "healPrediction" }) do
        local k = DF.TEXTURE_LAYER_KEYS[prefix]
        k.tileMode, k.tileSize, k.mirror = prefix .. "TileMode", prefix .. "TileSize", prefix .. "TileMirror"
    end

    local saved = eff.rings
    eff.rings = { { thickness = 10, gap = 0, sections = { { bar = "SHIELD", coverage = "FULL" } } } }
    eff.absorbBarTexture, eff.absorbBarBlendMode = "PlainTex", "ADD"
    eff.ringShowShieldOnHealth = false
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
    local s = F.dfUFRingAmounts.SHIELD[1]
    local tex = s:GetStatusBarTexture()
    eq(tex._blend, "ADD", "Blend Mode reaches the ring")

    eff.absorbBarTileMirror = true
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
    eq(s._path, "PlainTexMirrored", "Mirror picks the twin")
    eff.absorbBarTileMirror = nil

    eff.absorbBarTileMode = "HORIZ"
    F.dfDB = UF:FrameDB("target")
    local before = applied
    R:Layout(F)
    eq(s.dfTileOverride, "HORIZ", "Tile reaches the ring")
    eq(applied, before + 1, "...and is applied")
    R:Layout(F)
    eq(applied, before + 1, "...once, while nothing changes")

    eff.absorbBarTileMode, eff.absorbBarTileSize = nil, 8
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
    local outer = s._w
    check(near(tex._coord[2], outer / 8) and near(tex._coord[4], outer / 8), "Tile Size: repeats measured on the ring")
    eq(tex._texture, "PlainTex", "...with the file re-set to repeat")
    eq(tex._calls.SetRadialProgressBarEndOffset, 0, "...the arc re-applied after it")

    eff.absorbBarTileSize = -1
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
    check(near(tex._coord[2], outer / 10), "Fit to Bar: one repeat is the ring's thickness")

    eff.rings = saved
    eff.absorbBarTexture, eff.absorbBarBlendMode, eff.absorbBarTileSize = nil, nil, nil
    eff.ringShowShieldOnHealth = nil
    F.dfDB = UF:FrameDB("target")
    R:Layout(F)
end

print("-- Rings: every test frame has absorbs to show")
do
    for _, unit in ipairs({ "player", "target", "focus", "pet", "boss" }) do
        local t = UF.Preview:TestData(unit, unit == "boss" and 1 or nil)
        check(t.absorbPercent > 0 and t.healAbsorbPercent > 0 and t.healPredictionPercent > 0, unit .. ": all three")
    end
end

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
check(near(ht.SetRadialProgressBarStartOffset, 0.5), "left half, reversed: starts at its far (top) end")
check(near(ht.SetRadialProgressBarEndOffset, 0.5), "...and cuts off the other half")
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
eff.rings = deepcopy(TWO_RINGS)
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
check(p.masked and p.mask._texture == PO.MASKS.CIRCLE, "the picture and background are cut by the circle mask")
eq(p._level, PP._level + R.LEVEL_PORTRAIT, "under the rings")
check(R.LEVEL_PORTRAIT < R.LEVEL_RINGS and R.LEVEL_RINGS < R.LEVEL_CLASSPOWER, "portrait < rings < class power")

print("-- Rings: a 3D portrait in the middle")
eq(PO:StyleFor(PP.dfDB, "target", nil), "3D", "FIT: the model stays")
local fitInset = math.floor(p._w * PO.MODEL_INSET.CIRCLE + 0.5)
eq(p.dfModelInset, fitInset, "FIT: the square inside the circle")
PO:Paint(p, PP.dfDB, "3D", "target", nil)
check(not (p.cover and p.cover._shown), "FIT: no corner cover")
eq(p.model._level, p._level + 1, "the model just over the portrait (and so under the rings)")
-- COVER with the default gap (2): drawn as FIT
eff.ringPortrait3D = "COVER"
check(not R.CoverAllowed(PP.dfDB), "COVER: not with a gap round the portrait")
eq(R.Portrait3D(PP.dfDB), "FIT", "...so it falls back to FIT")
PO:Layout(PP)
eq(p.dfModelInset, fitInset, "...fitted inside")
PO:Paint(p, PP.dfDB, "3D", "target", nil)
check(not (p.cover and p.cover._shown), "...with no cover")
-- COVER with ring 1 flush against the portrait
eff.rings = deepcopy(TWO_RINGS)
eff.rings[1].gap = 0
check(R.CoverAllowed(PP.dfDB), "COVER: allowed with the innermost Gap at 0")
PO:Layout(PP)
eq(p._w, R.Geometry(PP.dfDB).hole - 2, "the portrait grows into the closed gap")
eq(p.dfModelInset, 0, "COVER: the model fills the circle's square")
PO:Paint(p, PP.dfDB, "3D", "target", nil)
local cv = p.cover
check(cv and cv._shown, "COVER: a corner cover over it")
check(cv.mask._texture == R.HOLE and cv.mask._wrap == "CLAMPTOWHITE", "...cut by the hole mask: only the corners show")
check(cv.tex._masks[1] == cv.mask, "...on the cover's texture")
eq(cv._level, p._level + 2, "...above the model")
PO:Paint(p, PP.dfDB, "2D", "target", nil)
check(not cv._shown, "a 2D picture never gets the cover")
-- 2D
eff.ringPortrait3D = "2D"
eq(PO:StyleFor(PP.dfDB, "target", nil), "2D", "2D: Blizzard's 2D portrait, cut round")
eq(PO:StyleFor({ portraitMode = "CLASS", frameStyle = "RING", ringPortrait3D = "2D" }, "player", "MAGE"), "CLASS",
   "class icons stay icons")
eq(PO:StyleFor({ portraitMode = "3D", ringPortrait3D = "2D" }, "player", "MAGE"), "3D", "Bars: the model whatever the setting")
eq(R.Portrait3D({ frameStyle = "RING", ringPortrait3D = "bogus" }), "FIT", "an unknown value: FIT")
eff.ringPortrait3D, eff.rings = nil, nil
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
eq(Lk.OwnerOf("ringPortrait3D"), "rings", "ringPortrait3D")
eq(Lk.OwnerOf("ringShowShieldOnHealth"), "rings", "the on-health switches")
check(Lk.OwnerOf("frameWidth") ~= "rings", "frameWidth stays the Frame page's")

print("-- Rings: the settings page's list edits")
do
    local src = options_file_source("UnitFrames/Pages.lua"):gsub("\r\n", "\n")
    local s0 = src:find("UFO.RING_MAX = 8", 1, true)
    local s1 = src:find("function UFO.BuildRingsPage", 1, true)
    check(s0 and s1, "the list edits can be cut out of Pages.lua")
    local env = setmetatable({ UFO = {} }, { __index = _G })
    local fn = (loadstring or load)(src:sub(s0, s1 - 1))
    setfenv(fn, env)
    fn()
    local U = env.UFO
    local rings = deepcopy(TWO_RINGS)
    check(U.RingMove(rings, 2, -1) and rings[1].sections[1].bar == "POWER", "move a ring in")
    check(not U.RingMove(rings, 1, -1), "the innermost cannot move further in")
    check(U.RingAdd(rings) and #rings == 3, "add a ring")
    for _ = 4, 8 do U.RingAdd(rings) end
    eq(#rings, 8, "add up to eight")
    check(not U.RingAdd(rings), "at most eight")
    for i = 8, 4, -1 do check(U.RingRemove(rings, i), "remove one") end
    eq(#rings, 3, "back to three")
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
    f.dfUFRingGeom = R.Geometry({ ringSize = 64, rings = TWO_RINGS })
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

print("-- Rings: the Text Designer's static mock")
do
    check(UF.Preview.BuildSample == nil and UF.Preview.PaintSample == nil, "no real unit frame sample any more")
    local held = {}
    local touched = {}
    for _, name in ipairs({ "UnitExists", "UnitPower", "UnitPowerMax", "UnitClass", "UnitHealth",
                            "UnitHealthMax", "UnitHealthPercent", "UnitPowerType" }) do
        held[name] = _G[name]
        _G[name] = function(u) touched[#touched + 1] = name .. "(" .. tostring(u) .. ")" end
    end
    local mock = Make("Frame", UIParent)
    mock._level = 10
    local bd = {}
    function mock:SetBackdropColor(r, g, b, a) bd.bg = { r, g, b, a } end
    function mock:SetBackdropBorderColor(r, g, b, a) bd.border = { r, g, b, a } end
    local art = { Make("Texture", mock), Make("Texture", mock) }
    local chrome = { textures = art, backdrop = { { r = 0.07, g = 0.07, b = 0.07, a = 1 }, { r = 0.27, g = 0.27, b = 0.27, a = 1 } } }
    local mdb = { frameStyle = "RING", ringSize = 64, portraitEnabled = true, portraitBorderSize = 1,
                  rings = { { thickness = 8, gap = 2, sections = { { bar = "HEALTH" } } },
                            { thickness = 4, gap = 2, sections = { { bar = "POWER", coverage = "HALF", position = "LEFT" },
                                                                   { bar = "CLASSPOWER", coverage = "HALF", position = "RIGHT" } } } } }
    R.DecorateMock(mock, mdb, chrome)
    local c = mock.dfUFMockRings
    check(c and c._shown and c._w == 64, "Ring: rings drawn on the mock, at ring size")
    check(not art[1]._shown and not art[2]._shown, "...the mock's bar art hidden")
    eq(bd.bg[4], 0, "...and its square backdrop")
    eq(c._level, 11, "over the mock (under the designer's text)")
    local fills = {}
    for i, a in ipairs(c.arcs) do if a.fill._shown then fills[#fills + 1] = a.fill end end
    eq(#fills, 2 + R.MOCK_PIPS, "health, power and five class power pips")
    eq(fills[1]._value, R.MOCK_FILL.HEALTH, "health: a fixed sample fill")
    eq(fills[2]._value, R.MOCK_FILL.POWER, "power: a fixed sample fill")
    local lit = 0
    for i = 3, #fills do lit = lit + fills[i]._value end
    eq(lit, R.MOCK_PIPS_ON, "three pips lit")
    local pc = c.portrait
    check(pc._shown and pc._w == UF.Portrait.RingSize(mdb) and pc._masks[1] == c.portraitMask,
          "a round portrait placeholder (a masked flat texture)")
    eq(mock.dfTDAnchorSpot, R.AnchorSpot, "the ring spots answer from the static layout")
    eq(select(2, R.AnchorSpot(mock, "RING_ABOVE")), 32, "...above the ring")
    mdb.portraitDimHover = true
    mock.dfHoverHook(mock, true)
    eq(pc._alpha, UF.Portrait.DIM, "Show Hover State dims the placeholder when the unit's portrait dims")
    mock.dfHoverHook(mock, false)
    eq(pc._alpha, 1, "...and back")
    eq(#touched, 0, "nothing on the mock asks a unit anything")
    mdb.frameStyle = "BARS"
    R.DecorateMock(mock, mdb, chrome)
    check(not c._shown and art[1]._shown and bd.bg[4] == 1, "Bars: the plain mock again")
    check(mock.dfTDAnchorSpot == nil and mock.dfUFRingGeom == nil, "...with the frame-edge spots")
    for name, fn in pairs(held) do _G[name] = fn end
end

print("-- Rings: the shipped ring template")
do
    local E = function(t, id) for _, x in ipairs(t.elements) do if x.id == id then return x end end end
    local cfg = UF.BuildRingTextPreset("default")
    eq(UF.RING_TEXT_PRESET, "Unit Frames Ring", "its library name")
    eq(UF.RING_TEXT_PRESETS.default, "Unit Frames Ring", "...made with the other ring templates")
    check(cfg.enabled and cfg.hideLegacyText, "on, with the legacy text hidden")
    eq(cfg.nextElementID, 7, "next id 7")
    eq(cfg.previewScale, 1, "preview scale 1")
    eq(#cfg.elements, 4, "four elements")
    local order = {}
    for i, x in ipairs(cfg.elements) do order[i] = x.id .. x.contentType end
    eq(table.concat(order, ","), "1name,2group,3status_text,6backdrop", "in the saved order, ids and all")
    local g = cfg.globalDefaults
    check(g.font == "DF Roboto SemiBold" and g.fontSize == 10 and g.outline == "SHADOW;NONE" and g.useClassColor == false
          and g.color.r == 1 and g.color.a == 1, "global defaults")
    local full = "color,font,fontSize,outline,useClassColor"
    local function ov(x)
        local k = {}
        for key, v in pairs(x.overrides) do if v == true then k[#k + 1] = key end end
        table.sort(k)
        return table.concat(k, ",")
    end
    local n = E(cfg, 1)
    check(n.anchorTo == "FRAME" and n.anchor == "TOP" and n.offsetX == 0 and n.offsetY == 12 and n.fontSize == 13
          and n.outline == "SHADOW" and n.nameLength == 10 and n.truncateMode == "ELLIPSIS" and n.hoverSlide == 0
          and n.label == "" and n.useClassColor == false and n.color.a == 1, "the name")
    eq(ov(n), full, "...its overrides")
    local h = E(cfg, 2)
    check(h.label == "Health" and h.anchor == "BOTTOM" and h.offsetY == -4 and h.fontSize == 12, "the health group")
    eq(h.groupSeparator, " " .. "|" .. "|" .. " ", "...two literal pipes")
    check(h.groupItems[1].contentType == "hp_current" and h.groupItems[1].abbreviate and h.groupItems[1].hideWhenZero == false
          and h.groupItems[2].contentType == "hp_max" and h.groupItems[2].abbreviate, "...current and max")
    eq(ov(h), full, "...its overrides")
    local st = E(cfg, 3)
    check(st.anchor == "CENTER" and st.offsetY == 0 and st.fontSize == 12 and st.label == "", "the status")
    eq(ov(st), full, "...its overrides")
    local b = E(cfg, 6)
    check(b.anchor == "BOTTOM" and b.offsetY == -8 and b.width == 84 and b.height == 21 and b.shape == "BOX"
          and b.layer == "FRONT" and b.color.a == 0.6 and b.color.r == 0 and b.fontSize == 16 and b.hoverSlide == -3, "the backdrop")
    eq(ov(b), "fontSize", "...its overrides")
    eq(rawget(n, "_skipOverrideIndicators"), nil, "no editor bookkeeping")
    eq(cfg.migratedFromLegacy, nil, "...nor the migration's")
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
    local s0 = src:find("function UFO.ApplyTemplateRequests(unit, name)", 1, true)
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
