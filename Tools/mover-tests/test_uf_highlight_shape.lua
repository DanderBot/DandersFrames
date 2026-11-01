local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- HIGHLIGHT OUTLINE
-- DandersFrames_UnitFrames/Indicators.lua (IN.HighlightShape / RefreshHighlights)
-- ------------------------------------------------------------
-- Every unit button, live and preview, hands DandersFrames' highlights the
-- outline of the frame + an attached class power bar + an outside portrait
-- (frame.dfHighlightShape); the outline follows the settings, and a highlight
-- that is up re-traces whenever those settings lay the frame out (live slider
-- drags included). The drawing itself is test_highlight_shape.lua's.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "issecretvalue", "LibStub" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

issecretvalue = function() return false end

local function Make(kind, parent)
    local f = setmetatable(FakeUIFrame(0, 0), nil)
    f._kind, f._shown = kind, true
    f:SetFakeParent(parent)
    function f:SetParent(p) self:SetFakeParent(p) end
    function f:RegisterEvent() end
    function f:CreateTexture() return Make("Texture", self) end
    function f:CreateFontString() return Make("FontString", self) end
    function f:SetAtlas(a) self._atlas = a end
    function f:SetTextColor() end
    function f:SetBlendMode(m) self._blend = m end
    return f
end
CreateFrame = function(kind, _, parent) return Make(kind, parent) end
LibStub = nil

local DF = { PartyDefaults = { frameWidth = 125, frameHeight = 40 }, registered = {} }
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
function DF:SafeSetFont() end
function DF:UpdateCombatIcon() end
DF.TextDesigner = { Resolver = { _RESOLVERS = { classification = function() return "" end } } }
DandersFrames = DF

do
    local src = df_file_source("Frames/Create.lua")
    local a = src:find("-- RESTED INDICATOR BUILDER", 1, true)
    local b = src:find("-- SAFE UNIT WATCH REGISTRATION", 1, true)
    assert(a and b, "rested builder section in Create.lua")
    assert(loadstring("local DF, CreateFrame, ipairs = ... " .. src:sub(a, b - 1), "@rested_builder"))(DF, CreateFrame, ipairs)
end

local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }
load_uf_file_into("Elements.lua", UF)
load_uf_file_into("Rings.lua", UF)
load_uf_file_into("Indicators.lua", UF)
local IN = UF.Indicators

local function Owner(unit)
    local f = Make("Button", UIParent)
    f.dfUFUnit, f.unit = unit, unit
    f.dfDB = UF:GetUnitDB(unit)
    f.dfHighlightShape = IN.HighlightShape
    return f
end

local function rstr(rects)
    if not rects then return "nil" end
    local out = {}
    for _, r in ipairs(rects) do out[#out + 1] = table.concat(r, ",") end
    return table.concat(out, " | ")
end

print("-- The outline: frame, attached class power, outside portrait")
check(type(IN.HighlightShape) == "function", "IN.HighlightShape exposed")
local P = Owner("player")
local pdb = P.dfDB
local w, h = pdb.frameWidth, pdb.frameHeight
eq(rstr(P:dfHighlightShape()), "0,0," .. w .. "," .. h, "no portrait, no class power: the frame alone")

UF.Portrait = { OutsideRect = function() return -52, -8, -2, 54 end }
eq(rstr(P:dfHighlightShape()), "0,0," .. w .. "," .. h .. " | -52,-8,-2,54", "an outside portrait joins it")
pdb.restingIconGlowPortrait = false
eq(rstr(P:dfHighlightShape()), "0,0," .. w .. "," .. h .. " | -52,-8,-2,54",
    "...always: Include Portrait is the resting glow's switch, not the highlights'")
eq(rstr(IN.GlowRects(P, pdb)), "0,0," .. w .. "," .. h, "...while the resting glow still honours it")
pdb.restingIconGlowPortrait = nil
UF.Portrait = { OutsideRect = function() return nil end }
eq(rstr(P:dfHighlightShape()), "0,0," .. w .. "," .. h, "an inside / off portrait: not part of it")

UF.ClassPower = { IsDetached = function(_, _, d) return d.classPowerDetached and true or false end }
P.dfUFClassPower = {}
local heldEnabled = pdb.classPowerEnabled
pdb.classPowerEnabled = true
eq(rstr(P:dfHighlightShape()), "0,0," .. w .. "," .. h .. " | " .. rstr({ { IN.ClassPowerRect(P, pdb) } }),
    "an attached class power bar joins it")
pdb.classPowerDetached = true
eq(rstr(P:dfHighlightShape()), "0,0," .. w .. "," .. h, "a detached one does not")
pdb.classPowerDetached = nil

print("-- The outline follows the settings")
pdb.frameWidth = 300
check(rstr(P:dfHighlightShape()):find("^0,0,300," .. h) ~= nil, "a wider frame: a wider outline")
pdb.frameWidth = w
pdb.classPowerEnabled = heldEnabled
UF.ClassPower, P.dfUFClassPower = nil, nil

print("-- A highlight that is up re-traces when the frame is laid out")
local calls = 0
DF.UpdateHighlights = function(_, f) calls = calls + 1 end
IN:Layout(P)
eq(calls, 0, "nothing up: no repaint (the shape is in the style signature for later)")
P.dfSelectionHighlight = Make("Frame", UIParent)
P.dfSelectionHighlight:Hide()
IN:Layout(P)
eq(calls, 0, "a hidden highlight: still none")
P.dfSelectionHighlight:Show()
IN:Layout(P)
eq(calls, 1, "a shown highlight: re-applied")
P.dfSelectionHighlight:Hide()
P.dfAggroHighlight = Make("Frame", UIParent)
IN:Layout(P)
eq(calls, 2, "aggro too")
local plain = Make("Button", UIParent)
plain.dfUFUnit, plain.dfDB = "player", pdb
plain.dfSelectionHighlight = Make("Frame", UIParent)
IN:Layout(plain)
eq(calls, 2, "a frame without an outline is left to its own updates")
DF.UpdateHighlights = nil

print("-- Every route a frame / portrait / class power setting takes lays this element out")
for _, elem in ipairs({ "portrait", "classpower" }) do
    local has = false
    for _, m in ipairs(UF.LIVE_ELEMENTS[elem] or {}) do if m == "Indicators" then has = true end end
    check(has, "a live " .. elem .. " drag re-lays Indicators")
end
do
    local src = uf_file_source("Units.lua")
    local a = src:find("function Units:ApplyLayout", 1, true)
    local b = src:find("\nend", a, true)
    check(a and src:sub(a, b):find('Elements("Layout", f)', 1, true) ~= nil,
        "the frame's own layout (Frame page drags, RefreshAll) re-lays the elements")
end

print("-- Live and preview buttons both carry the outline")
local function inBody(file, from, to)
    local src = uf_file_source(file)
    local a = src:find(from, 1, true)
    local b = a and src:find(to, a, true)
    return a and b and src:sub(a, b):find("f.dfHighlightShape = UF.Indicators and UF.Indicators.HighlightShape", 1, true) ~= nil
end
check(inBody("Units.lua", "function Units:Build", "function Units:Spawn"), "Units:Build (live, boss slots too)")
check(inBody("Preview.lua", "function P:Build", "function P:Acquire"), "P:Build (the previews, boss previews too)")

print("-- A Ring frame: the outline and the rested glow are a circle")
do
    local eff = UF:GetUnitDB("focus")
    eff.frameStyle = "RING"
    eff.ringSize = 80
    local F = Owner("focus")
    F.dfDB = UF:FrameDB("focus")
    local spec = F:dfHighlightShape()
    check(spec and spec.circle and #spec == 0, "the highlight shape is a circle spec, no rects")
    check(spec.circle.x == 40 and spec.circle.y == 40 and spec.circle.d == 80, "centred, the outer ring's diameter")
    eq(spec.hole, UF.Rings.HOLE, "cut hollow with the ring hole mask")
    local glow = IN.GlowRects(F, F.dfDB)
    check(glow and glow.circle and glow.circle.d == 80, "the rested glow follows the same circle")
    eff.rings = { { thickness = 6, gap = 2, sections = { { bar = "HEALTH" } } } }
    eq(F:dfHighlightShape().circle.d, 80, "one ring: still the frame's edge")
    eff.frameStyle = "BARS"
    F.dfDB = UF:FrameDB("focus")
    check(F:dfHighlightShape().circle == nil and #F:dfHighlightShape() >= 1, "Bars: rects again")
    eff.ringSize, eff.rings = nil, nil
end

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
