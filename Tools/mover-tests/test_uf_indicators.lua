local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- UNIT ICONS
-- DandersFrames_UnitFrames/Indicators.lua
-- ------------------------------------------------------------
-- Resting / PvP / Elite & Rare: who gets which icon, the answers read with
-- secrets hidden rather than guessed, the classification text through the Text
-- Designer's own resolver (D12), layout from the unit's keys, the combat icon
-- kicked on the combat edges, and the preview.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "issecretvalue", "LibStub", "IsResting",
                     "UnitIsPVP", "UnitIsPVPFreeForAll", "UnitFactionGroup", "UnitClassification", "UnitExists" }
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

local resting, pvp, ffa, faction, class = true, false, false, "Horde", "elite"
IsResting = function() return resting end
UnitIsPVP = function() return pvp end
UnitIsPVPFreeForAll = function() return ffa end
UnitFactionGroup = function() return faction end
UnitClassification = function() return class end
UnitExists = function() return true end
LibStub = nil

local DF = { PartyDefaults = { frameWidth = 125, frameHeight = 40 }, registered = {} }
function DF:Debug() end
function DF:DebugWarn() end
local errs = {}
function DF:DebugError(_, fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
function DF:SafeSetFont(fs, _, size) fs._fontSize = size end
local combatKicks = 0
function DF:UpdateCombatIcon() combatKicks = combatKicks + 1 end
-- The Text Designer's Classification resolver (D12), as DataSource / Resolver expose it.
DF.TextDesigner = { Resolver = { _RESOLVERS = { classification = function(_, source)
    local c = source:GetClassification()
    if c == "elite" then return "+" elseif c == "rare" then return "Rare"
    elseif c == "rareelite" then return "Rare Elite" elseif c == "worldboss" then return "Boss" end
    return ""
end } } }
DandersFrames = DF

-- The REAL resting builder, lifted out of DandersFrames/Frames/Create.lua by its
-- section header (the file builds tooltips at file scope, so not loaded whole).
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
load_uf_file_into("Indicators.lua", UF)
local IN = UF.Indicators

local function Owner(unit)
    local f = Make("Button", UIParent)
    f.dfUFUnit, f.unit = unit, unit
    f.dfDB = UF:GetUnitDB(unit)
    return f
end

print("-- Who gets which icon")
local P, T, PET = Owner("player"), Owner("target"), Owner("pet")
IN:Attach(P); IN:Attach(T); IN:Attach(PET)
check(P.dfUFIcons.resting and P.dfUFIcons.pvp and not P.dfUFIcons.classification, "player: resting, PvP")
check(T.dfUFIcons.pvp and T.dfUFIcons.classification and not T.dfUFIcons.resting, "target: PvP, elite / rare")
eq(PET.dfUFIcons, nil, "pet: none")

print("-- Defaults")
eq(UF:GetUnitDB("player").restingIconEnabled, true, "player: resting on")
eq(UF:GetUnitDB("player").combatIconEnabled, true, "player: DF's combat icon on")
eq(UF:GetUnitDB("target").classificationEnabled, true, "target: elite / rare on")
eq(UF:GetUnitDB("focus").pvpIconEnabled, false, "focus: PvP off")

print("-- Resting")
IN:Layout(P)
check(P.dfUFIcons.resting:IsShown(), "resting: shown")
resting = false
IN:Update(P)
check(not P.dfUFIcons.resting:IsShown(), "not resting: hidden")
resting = Secret("resting")
IN:Update(P)
check(not P.dfUFIcons.resting:IsShown(), "a secret answer: hidden, never guessed")

print("-- Resting: the shared ZZZ, animation, glow, size")
local pdb = UF:GetUnitDB("player")
eq(pdb.restingIconAnimate, true, "default: animated")
eq(pdb.restingIconGlow, false, "default: no glow (loud in every city)")
local R = P.dfUFIcons.resting
eq(#R.zTexts, 3, "the shared builder's three Zs")
check(R.glow ~= nil, "a glow built round the frame")
eq(R.glow._parent, P, "...on the unit button itself (the frame's main rect)")
eq(R.glowStyleName, "OUTER", "the soft outer glow, not the party wash")
eq(#R.glow.pieces, 8, "...eight pieces outside the frame's edges")
eq(pdb.restingIconGlowPortrait, true, "default: Include Portrait on")
resting = true
IN:Layout(P)
check(R:IsShown(), "resting again: shown")
check(not R.glow:IsShown(), "glow off by default")
check(R:GetScript("OnUpdate") ~= nil, "animated: the loop runs")
eq(R.zTexts[3]._fontSize, 14, "size 16 = the party ZZZ (largest Z 14)")
pdb.restingIconGlow = true
IN:Update(P)
check(R.glow:IsShown(), "glow on: shown")
pdb.restingIconAnimate = false
IN:Layout(P)
eq(R:GetScript("OnUpdate"), nil, "still: no OnUpdate")
eq(R.zTexts[1]:GetAlpha(), 1, "still: Zs at full alpha")
eq(R.glow:GetAlpha(), 0.75, "still: glow at a fixed alpha")
pdb.restingIconSize = 32
IN:Layout(P)
eq(R.zTexts[3]._fontSize, 28, "size 32: the Zs scale with it")
local rp = R._points[#R._points]
eq(rp and rp[1], "TOPRIGHT", "anchored at the unit's anchor (player default: top right)")
eq(rp and rp[2], P, "...on the frame")
eq(rp and rp[4], 9, "player default: 9 right")
eq(rp and rp[5], 5, "...5 up")
eq(pdb.restingIconAnchor, "TOPRIGHT", "player default anchor")
eq(pdb.restingIconX, 9, "player default X"); eq(pdb.restingIconY, 5, "player default Y")
resting = false
IN:Update(P)
check(not R:IsShown() and not R.glow:IsShown(), "not resting: ZZZ and glow both hidden")
pdb.restingIconSize, pdb.restingIconAnimate, pdb.restingIconGlow = 16, true, false

print("-- Resting glow: the outline of frame + portrait + class power bar")
local function rstr(rects)
    local out = {}
    for _, r in ipairs(rects) do out[#out + 1] = table.concat(r, ",") end
    return table.concat(out, " | ")
end
local function grects() return rstr(IN.GlowRects(P, pdb)) end
IN:Layout(P)
eq(grects(), "0,0,220,46", "no portrait module, no class power: the frame alone")
check(R.glow.outlineCount == 8, "...traced as one box (eight pieces)")
local rectCalls = 0
UF.Portrait = { OutsideRect = function(f, db) rectCalls = rectCalls + 1; return -52, -8, -2, 54 end }
IN:Layout(P)
eq(grects(), "0,0,220,46 | -52,-8,-2,54", "an outside portrait: its own rect, not one box")
check(rectCalls > 0, "...asked of the portrait module")
check(R.glow.outlineCount > 8, "...the glow follows the step (more than a box's eight pieces)")
pdb.restingIconGlowPortrait = false
IN:Layout(P)
eq(grects(), "0,0,220,46", "Include Portrait off: the frame only")
eq(R.glow.outlineCount, 8, "...one box again")
pdb.restingIconGlowPortrait = nil
UF.Portrait = { OutsideRect = function() return nil end }
eq(grects(), "0,0,220,46", "an inside portrait (no outside rect): the frame only")

-- The attached class power bar: its own rect, border included.
local heldCP, heldBar = UF.ClassPower, P.dfUFClassPower
UF.ClassPower = { IsDetached = function(_, _, d) return d.classPowerDetached and true or false end }
P.dfUFClassPower = {}
local function cbox() return table.concat({ IN.ClassPowerBox(P, pdb) }, ",") end
local heldEnabled = pdb.classPowerEnabled
pdb.classPowerEnabled = false
eq(cbox(), "0,0,0,0", "class power off: nothing")
eq(IN.ClassPowerRect(P, pdb), nil, "...no rect")
pdb.classPowerEnabled = true
eq(rstr({ { IN.ClassPowerRect(P, pdb) } }), "0,-9,220,-1", "on top, matching width: outer edge = the frame's, 2 gap - 1 border to 2 + 6 + 1 up")
eq(cbox(), "0,0,9,0", "matching width: no reach left or right, 9 above")
pdb.classPowerPosition = "BOTTOM"
eq(rstr({ { IN.ClassPowerRect(P, pdb) } }), "0,47,220,55", "below the frame")
eq(cbox(), "0,0,0,9", "below: the reach moves to the bottom")
pdb.classPowerMatchWidth, pdb.classPowerX = false, 4
pdb.classPowerWidth = 240
eq(cbox(), "7,15,0,9", "a set width of frame + 20 (+ border each side), moved right 4")
pdb.classPowerDetached = true
eq(IN.ClassPowerRect(P, pdb), nil, "detached: not part of the frame")
eq(cbox(), "0,0,0,0", "detached: no reach")
pdb.classPowerDetached, pdb.classPowerPosition, pdb.classPowerMatchWidth = nil, nil, nil
pdb.classPowerWidth, pdb.classPowerX = nil, nil
-- the screenshot: portrait on the left, taller; the bar over the frame only
UF.Portrait = { OutsideRect = function() return -52, -3, -2, 49 end }
pdb.classPowerHeight = 12
eq(grects(), "0,0,220,46 | 0,-15,220,-1 | -52,-3,-2,49", "frame, bar and portrait each passed on")
IN:Layout(P)
local pieces = DF.GlowOutlinePieces(IN.GlowRects(P, pdb), R.glow.spread)
eq(R.glow.outlineCount, #pieces, "the glow laid out from the outline")
for _, p in ipairs(pieces) do
    check(not (p[3] < -13 and p[2] < -10), "no glow in the empty corner above the portrait (" .. p[1] .. "," .. p[2] .. "," .. p[3] .. ")")
end
local pool = #R.glow.outlinePool
for _ = 1, 3 do IN:Layout(P) end
eq(#R.glow.outlinePool, pool, "relayout reuses the glow's textures")
pdb.classPowerEnabled, pdb.classPowerHeight = heldEnabled, nil
UF.Portrait = nil
UF.ClassPower, P.dfUFClassPower = heldCP, heldBar
IN:Layout(P)
eq(R.glow.outlineCount, 8, "all off again: the frame's box")
-- a frame resize (the Frame page's sliders) re-traces the outline
local onSize = R.glow:GetScript("OnSizeChanged")
check(type(onSize) == "function", "the glow re-traces on a frame resize")
local heldW = pdb.frameWidth
pdb.frameWidth = 300
if onSize then onSize(R.glow) end
local widest = 0
for i = 1, R.glow.outlineCount do
    local t = R.glow.outlinePool[i]
    local pt = t._points and t._points[1] or t.points and t.points[1]
    if pt and pt[4] > widest then widest = pt[4] end
end
eq(widest, 300, "...to the new width (the right edge's strip at x = 300)")
pdb.frameWidth = heldW
IN:Layout(P)

print("-- PvP")
pvp = true
IN:Update(P)
check(P.dfUFIcons.pvp:IsShown(), "flagged: shown")
eq(P.dfUFIcons.pvp.tex._texture, IN.ART.pvp.Horde.file, "...the faction crest (no atlas: the legacy file)")
do
    local heldCT = C_Texture
    C_Texture = { GetAtlasInfo = function(name) return name == IN.ART.pvp.Horde.atlas and {} or nil end }
    IN:Update(P)
    eq(P.dfUFIcons.pvp.tex._atlas, "UI-HUD-UnitFrame-Player-PVP-HordeIcon", "...the modern crest atlas when the client has it")
    C_Texture = heldCT
end
ffa = true
eq(IN:PvPState("player"), "FFA", "free-for-all wins")
ffa = Secret("ffa")
eq(IN:PvPState("player"), nil, "secret free-for-all: hidden")
ffa, faction = false, Secret("faction")
eq(IN:PvPState("player"), nil, "secret faction: hidden")
faction, pvp = "Alliance", false
eq(IN:PvPState("player"), nil, "not flagged: nothing")

print("-- Elite / Rare")
IN:Layout(T)
local ci = T.dfUFIcons.classification
check(ci:IsShown(), "elite: shown")
eq(ci.tex._atlas, IN.ART.elite, "...the gold dragon")
class = "rare"
IN:Update(T)
eq(ci.tex._atlas, IN.ART.rare, "rare: the silver one")
class = "normal"
IN:Update(T)
check(not ci:IsShown(), "normal: hidden")
class = Secret("classification")
IN:Update(T)
check(not ci:IsShown(), "secret: hidden")
class = "rareelite"
UF:GetUnitDB("target").classificationStyle = "TEXT"
IN:Update(T)
eq(ci.text._text, "Rare Elite", "Text: the Text Designer's own Classification words")
check(not ci.tex:IsShown(), "...no dragon")
eq(IN.ClassificationText("elite"), "+", "elite reads +")
UF:GetUnitDB("target").classificationStyle = nil

print("-- Layout from the unit's keys")
local tdb = UF:GetUnitDB("target")
tdb.classificationSize, tdb.classificationAnchor, tdb.classificationX, tdb.classificationY = 20, "BOTTOMLEFT", 3, -4
IN:Layout(T)
eq(ci._w, 20, "size")
local pt = ci._points[#ci._points]
eq(pt and pt[1], "BOTTOMLEFT", "anchor point")
eq(pt and pt[2], T, "...on the frame")
eq(pt and pt[4], 3, "x")
eq(pt and pt[5], -4, "y")
tdb.classificationAnchor = "nonsense"
IN:Layout(T)
pt = ci._points[#ci._points]
eq(pt and pt[1], "TOPRIGHT", "an unknown anchor: the default")

print("-- Combat icon: DF's, kicked on the edges")
combatKicks = 0
IN:OnUnitEvent(P, "PLAYER_REGEN_DISABLED")
IN:OnUnitEvent(P, "UNIT_FLAGS")
IN:OnUnitEvent(P, "UNIT_AURA")
eq(combatKicks, 2, "combat start and UNIT_FLAGS refresh it; other events do not")

print("-- Preview")
local PV = Owner("focus")
PV.dfUFPreview = true
PV.dfTestData = { classification = "rare" }
IN:Attach(PV)
IN:Preview(PV)
eq(PV.dfUFIcons.classification.tex._atlas, IN.ART.rare, "the sample unit's classification")
check(not PV.dfUFIcons.pvp:IsShown(), "focus PvP off: hidden in the preview too")
local PP = Owner("player")
PP.dfUFPreview = true
PP.dfDB = UF:GetUnitDB("player")
PP.dfDB.restingIconGlow = true
IN:Attach(PP)
IN:Preview(PP)
check(PP.dfUFIcons.resting:IsShown(), "player preview: the resting ZZZ shows")
check(PP.dfUFIcons.resting.glow:IsShown(), "player preview: the glow shows when on")
check(PP.dfUFIcons.resting:GetScript("OnUpdate") ~= nil, "player preview: animated")
PP.dfDB.restingIconGlow = false
eq(#errs, 0, "no element errored (" .. tostring(errs[1]) .. ")")

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
