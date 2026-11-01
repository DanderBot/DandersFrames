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

-- ============================================================
-- CLASSIFICATION DRAGON / BORDER / COMBAT ICON BORDER
-- ============================================================
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end
local REF = 46 / 136.35

print("-- Dragon: defaults per unit")
eq(UF:GetUnitDB("target").classDragonEnabled, true, "target: dragon on")
eq(UF:GetUnitDB("focus").classDragonEnabled, true, "focus: dragon on")
eq(UF:GetUnitDB("boss").classDragonEnabled, false, "boss: off (every boss frame is a boss)")
eq(UF:GetUnitDB("player").classDragonEnabled, false, "player: off (no classification)")
eq(UF:GetUnitDB("pet").classDragonEnabled, false, "pet: off")
eq(UF:GetUnitDB("target").classDragonSize, 80, "target: size 80% (sized for its 46px portrait)")
eq(UF:GetUnitDB("focus").classDragonSize, 65, "focus: 65% (the same reach on its 36px portrait)")
eq(UF:GetUnitDB("boss").classDragonSize, 80, "boss: 80% (clear of the boss above's cast bar)")
eq(UF:GetUnitDB("boss").classDragonShowTail, true, "boss: the tail shows (its cast bar draws over it)")
eq(UF:GetUnitDB("target").classDragonShowTail, true, "target: the tail shows")
eq(UF:GetUnitDB("target").classDragonSide, "OUTER", "side: outer")
eq(UF:GetUnitDB("target").classDragonAnchor, "PORTRAIT", "anchored to the portrait")
eq(UF:GetUnitDB("boss").classDragonAnchor, "PORTRAIT", "...on every unit (falls back to the frame)")
eq(UF:GetUnitDB("target").classBorderEnabled, false, "class border: off")
eq(UF:GetUnitDB("player").combatIconBorderEnabled, false, "combat icon border: off")
for _, sfx in ipairs({ "Elite", "Rare", "RareElite", "Boss" }) do
    eq(UF:GetUnitDB("target")["classDragon" .. sfx], true, sfx .. ": on")
    eq(type(UF:GetUnitDB("target")["classDragon" .. sfx .. "Color"]), "table", sfx .. ": a colour")
end
check(T.dfUFIcons.dragon and T.dfUFIcons.classBorder, "target: a dragon and a class border built")
check(not P.dfUFIcons.dragon and not P.dfUFIcons.classBorder, "player: neither")

print("-- Dragon: the pieces, size 100")
local function byPiece(list)
    local o = {}
    for _, e in ipairs(list) do o[e.side .. e.piece] = e end
    return o
end
local L100 = byPiece(IN.DragonLayout({ classDragonSize = 100 }))
local top, bot = L100.RIGHTTOP, L100.RIGHTBOTTOM
check(top and bot and not L100.LEFTTOP, "RIGHT: two pieces, right end only")
check(near(top.w, 197 * REF) and near(top.h, 61 * REF), "top: the used art (197x61) at 46/136.35")
eq(math.floor(top.w + 0.5) .. "x" .. math.floor(top.h + 0.5), "66x21", "...~66x21")
check(near(bot.w, 176 * REF) and near(bot.h, 41 * REF), "bottom: 176x41 at the same scale")
eq(math.floor(bot.w + 0.5) .. "x" .. math.floor(bot.h + 0.5), "59x14", "...~59x14")
eq(top.point .. ">" .. top.relPoint, "BOTTOMRIGHT>TOPRIGHT", "top: its bottom-right on the frame's top-right")
eq(top.x .. "," .. top.y, "0,0", "...flush")
eq(bot.point .. ">" .. bot.relPoint, "TOPRIGHT>BOTTOMRIGHT", "bottom: its top-right on the frame's bottom-right")
eq(bot.x, -2, "...2px INSIDE the frame's right edge")
check(near(top.coords[2], 197 / 256) and near(top.coords[4], 61 / 128) and top.coords[1] == 0, "top: texcoords crop the used art")
check(near(bot.coords[2], 176 / 256) and near(bot.coords[4], 41 / 128), "bottom: likewise")
local fh = IN.DragonLayout({ classDragonSize = 100, frameHeight = 80 })
check(near(fh[1].w, top.w), "the pieces never follow the frame's height")

print("-- Dragon: size 150, clamps")
local L150 = byPiece(IN.DragonLayout({ classDragonSize = 150 }))
check(near(L150.RIGHTTOP.w, 197 * 1.5 * REF) and near(L150.RIGHTBOTTOM.h, 41 * 1.5 * REF), "150%: both pieces 1.5x")
eq(L150.RIGHTBOTTOM.x, -2, "...the tail inset stays 2px")
check(near(byPiece(IN.DragonLayout({ classDragonSize = 10 })).RIGHTTOP.w, 197 * 0.5 * REF), "below 50: 50")
check(near(byPiece(IN.DragonLayout({ classDragonSize = 900 })).RIGHTTOP.w, 197 * 2 * REF), "above 200: 200")

print("-- Dragon: offsets, tail")
local LO = byPiece(IN.DragonLayout({ classDragonX = 4, classDragonY = -3, classDragonTailX = -5 }))
eq(LO.RIGHTTOP.x .. "," .. LO.RIGHTTOP.y, "4,-3", "X / Y move the top piece")
eq(LO.RIGHTBOTTOM.x .. "," .. LO.RIGHTBOTTOM.y, "-3,-3", "...and the bottom, plus its own tail X (4 - 5 - 2)")

print("-- Dragon: Show Tail off")
local NT = byPiece(IN.DragonLayout({ classDragonShowTail = false, classDragonSide = "BOTH" }))
check(NT.RIGHTTOP and NT.LEFTTOP and not NT.RIGHTBOTTOM and not NT.LEFTBOTTOM, "the top pieces only")
eq(#IN.DragonLayout({ classDragonShowTail = false }), 1, "...one piece on one end")

print("-- Dragon: the boss defaults fit the boss frame")
do
    -- Measured from the real defaults: the frame, its attached cast bar and the
    -- gap to the next boss. The top piece rises into that gap, whose upper part is
    -- the boss above's cast bar band.
    local bd = UF:GetUnitDB("boss")
    local band = bd.castbarGap + bd.castbarHeight + bd.castbarBorderSize
    eq(band, 17, "boss: the cast bar band under each frame is 17px")
    eq(bd.castbarDetached, false, "...attached")
    eq(bd.castbarMatchWidth, true, "...as wide as the frame, so no side clears a tail")
    local free = bd.bossSpacing - band
    local list = IN.DragonLayout(bd)
    eq(#list, 2, "boss: the top piece and the tail")
    local top, tail
    for _, e in ipairs(list) do
        if e.piece == "BOTTOM" then tail = e else top = e end
    end
    check(top.h < free - 4, "boss: the top piece clears the boss above's cast bar by over 4px")
    check(top.w < bd.frameWidth / 3, "...and takes under a third of the frame's width")
    check(tail.h < band, "boss: the tail sits wholly inside its own cast bar band (the bar draws over it)")
end

print("-- Dragon: LEFT mirrors")
local LL = byPiece(IN.DragonLayout({ classDragonSide = "LEFT", classDragonX = -4, classDragonTailX = 5 }))
check(LL.LEFTTOP and LL.LEFTBOTTOM and not LL.RIGHTTOP, "LEFT: the left end only")
eq(LL.LEFTTOP.point .. ">" .. LL.LEFTTOP.relPoint, "BOTTOMLEFT>TOPLEFT", "top: bottom-left on the frame's top-left")
eq(LL.LEFTBOTTOM.point .. ">" .. LL.LEFTBOTTOM.relPoint, "TOPLEFT>BOTTOMLEFT", "bottom: top-left on the frame's bottom-left")
check(near(LL.LEFTTOP.coords[1], 197 / 256) and LL.LEFTTOP.coords[2] == 0, "top: flipped by texcoord (left > right)")
check(near(LL.LEFTBOTTOM.coords[1], 176 / 256) and LL.LEFTBOTTOM.coords[2] == 0, "bottom: flipped too")
-- The mirror of { RIGHT, X 4, tail -5 } (what a mirrored link stores) is its exact mirror image.
eq(LL.LEFTTOP.x, -LO.RIGHTTOP.x, "a mirrored link's top piece: the mirror image")
eq(LL.LEFTBOTTOM.x, -LO.RIGHTBOTTOM.x, "...and its bottom piece (inset inward on the left)")

print("-- Dragon: BOTH")
local LB = byPiece(IN.DragonLayout({ classDragonSide = "BOTH", classDragonX = 3, classDragonTailX = -1 }))
check(LB.RIGHTTOP and LB.RIGHTBOTTOM and LB.LEFTTOP and LB.LEFTBOTTOM, "both ends: four pieces")
eq(LB.RIGHTTOP.x .. "," .. LB.RIGHTBOTTOM.x, "3,0", "right end: X 3, tail 3 - 1 - 2")
eq(LB.LEFTTOP.x .. "," .. LB.LEFTBOTTOM.x, "-3,0", "left end: its mirror image")

print("-- Dragon: OUTER")
do
    local function sides(db, anchor)
        local o = {}
        for _, e in ipairs(IN.DragonLayout(db, anchor)) do if e.piece == "TOP" then o[#o + 1] = e.side end end
        return table.concat(o, ",")
    end
    eq(sides({}), "RIGHT", "no anchor: the right end")
    eq(sides({ classDragonSide = "OUTER" }, { kind = "FRAME" }), "RIGHT", "frame, no outside portrait: right")
    eq(sides({ classDragonSide = "OUTER" }, { kind = "FRAME", outer = "LEFT" }), "LEFT",
       "frame, portrait on the left: the frame's left end")
    eq(sides({ classDragonSide = "OUTER" }, { kind = "FRAME", outer = "RIGHT" }), "RIGHT", "...on the right: right")
    eq(sides({}, { kind = "PORTRAIT", outer = "LEFT", rect = { -47, 0, -2, 46 }, fw = 220 }), "LEFT",
       "portrait on the left: its left (outer) edge")
    eq(sides({ classDragonSide = "RIGHT" }, { kind = "FRAME", outer = "LEFT" }), "RIGHT", "an explicit side wins")
    eq(sides({ classDragonSide = "BOTH" }, { kind = "FRAME", outer = "LEFT" }), "RIGHT,LEFT", "...BOTH too")
end

print("-- Dragon: the portrait anchor (pure)")
do
    -- A 220x46 frame, a portrait on its RIGHT: 2px gap, 44 + 1px border each side.
    local A = { kind = "PORTRAIT", outer = "RIGHT", rect = { 222, 0, 267, 46 }, fw = 220 }
    local LP = byPiece(IN.DragonLayout({ classDragonSize = 100 }, A))
    local t, b = LP.RIGHTTOP, LP.RIGHTBOTTOM
    eq(t.point .. ">" .. t.relPoint .. ":" .. t.x .. "," .. t.y, "BOTTOMRIGHT>TOPRIGHT:47,0",
       "top: its bottom-right on the portrait's top-right (47 past the frame's right edge)")
    eq(b.point .. ">" .. b.relPoint .. ":" .. b.x .. "," .. b.y, "TOPRIGHT>TOPRIGHT:45,-46",
       "bottom: its top-right on the portrait's bottom edge, 2px inside its right edge")
    check(t.x - t.w < 2, "the overhang falls inward, over the gap and the frame")
    -- Offsets add on top.
    LP = byPiece(IN.DragonLayout({ classDragonX = 3, classDragonY = 2, classDragonTailX = -1 }, A))
    eq(LP.RIGHTTOP.x .. "," .. LP.RIGHTTOP.y .. "/" .. LP.RIGHTBOTTOM.x .. "," .. LP.RIGHTBOTTOM.y, "50,2/47,-44",
       "X / Y / tail X on top of the portrait's edges")
    -- A taller portrait (size +10, centred): its own top / bottom.
    A.rect = { 222, -5, 277, 51 }
    LP = byPiece(IN.DragonLayout({}, A))
    eq(LP.RIGHTTOP.y .. "," .. LP.RIGHTBOTTOM.y, "5,-51", "a taller portrait: the pieces follow its edges")
    -- A portrait on the LEFT: measured from the frame's TOPLEFT, flipped.
    local AL = { kind = "PORTRAIT", outer = "LEFT", rect = { -47, 0, -2, 46 }, fw = 220 }
    LP = byPiece(IN.DragonLayout({}, AL))
    eq(LP.LEFTTOP.point .. ">" .. LP.LEFTTOP.relPoint .. ":" .. LP.LEFTTOP.x .. "," .. LP.LEFTTOP.y,
       "BOTTOMLEFT>TOPLEFT:-47,0", "left portrait: top on its top-left (outer) corner")
    eq(LP.LEFTBOTTOM.point .. ">" .. LP.LEFTBOTTOM.relPoint .. ":" .. LP.LEFTBOTTOM.x .. "," .. LP.LEFTBOTTOM.y,
       "TOPLEFT>TOPLEFT:-45,-46", "...bottom 2px inside its left edge")
    check(LP.LEFTTOP.coords[2] == 0, "...flipped, head facing in over the frame")
    -- BOTH on the portrait: both of its edges.
    LP = byPiece(IN.DragonLayout({ classDragonSide = "BOTH" }, AL))
    eq(LP.RIGHTTOP.x .. "," .. LP.LEFTTOP.x, "-2,-47", "BOTH: the portrait's right and left edges")
end

print("-- Dragon: IN.DragonAnchor")
do
    local saved = UF.Portrait
    local rect
    UF.Portrait = { OutsideRect = function() if rect then return rect[1], rect[2], rect[3], rect[4] end end }
    local Fr = Owner("target")
    local db = { frameWidth = 220, frameHeight = 46, portraitSide = "RIGHT" }
    rect = { 222, 0, 267, 46 }
    local a = IN.DragonAnchor(Fr, db)
    eq(a.kind .. ":" .. a.outer .. ":" .. table.concat(a.rect, ","), "PORTRAIT:RIGHT:222,0,267,46",
       "an outside portrait: its rect (PO.OutsideRect)")
    db.classDragonAnchor = "FRAME"
    a = IN.DragonAnchor(Fr, db)
    eq(a.kind .. ":" .. tostring(a.outer) .. ":" .. tostring(a.rect), "FRAME:RIGHT:nil",
       "Anchor To Frame: the frame, Outer still the portrait's side")
    db.classDragonAnchor = nil
    rect = nil
    a = IN.DragonAnchor(Fr, db)
    eq(a.kind .. ":" .. tostring(a.outer), "FRAME:nil", "portrait off / inside (no outside rect): the frame, silently")
    db.portraitSide = "LEFT"; rect = { -47, 0, -2, 46 }
    eq(IN.DragonAnchor(Fr, db).outer, "LEFT", "portrait on the left: outer = LEFT")
    UF.Portrait = saved
end

print("-- Dragon: on the frame")
class = "elite"
local tdbD = UF:GetUnitDB("target")
tdbD.classificationStyle = nil
IN:Layout(T)
local D = T.dfUFIcons.dragon
check(D:IsShown(), "elite: shown")
check(D.tex.RIGHT.TOP:IsShown() and D.tex.RIGHT.BOTTOM:IsShown(), "...the right end's pieces")
check(not D.tex.LEFT.TOP:IsShown() and not D.tex.LEFT.BOTTOM:IsShown(), "...not the left end's")
eq(D.tex.RIGHT.TOP._texture, IN.DRAGON.TOP.file, "...the top art")
eq(D.tex.RIGHT.BOTTOM._texture, IN.DRAGON.BOTTOM.file, "...the bottom art")
local tp = D.tex.RIGHT.TOP._points[#D.tex.RIGHT.TOP._points]
eq(tp and tp[1], "BOTTOMRIGHT", "anchored on the frame:"); eq(tp and tp[2], T, "...the unit button")
eq(tp and tp[3], "TOPRIGHT", "...its top-right")
local v = D.tex.RIGHT.TOP._vertex
check(v and v.r == 1 and near(v.g, 0.80) and near(v.b, 0.32), "elite: gold")
eq(D:GetFrameLevel() - T:GetFrameLevel(), IN.DRAGON_LEVEL, "one level above the class border")
eq(T.dfUFIcons.classBorder:GetFrameLevel() - T:GetFrameLevel(), IN.CLASS_BORDER_LEVEL, "the class border above DF's (+14)")
check(IN.DRAGON_LEVEL > IN.CLASS_BORDER_LEVEL and IN.CLASS_BORDER_LEVEL > 14, "dragon > class border > DF's frame border")
do
    -- Cast bars always draw over a dragon (CastBar.lua CB.LEVEL).
    local fh = io.open("DandersFrames_UnitFrames/CastBar.lua", "r")
    local src = fh and fh:read("*a") or ""
    if fh then fh:close() end
    local cbLevel = tonumber(src:match("CB%.LEVEL = (%d+)"))
    check(cbLevel ~= nil and cbLevel > IN.DRAGON_LEVEL, "the cast bar sits above the dragon")
    check(cbLevel ~= nil and cbLevel + 6 < 25, "...and its shield/text stay under the +25 text overlay")
end
local function tint() local x = D.tex.RIGHT.TOP._vertex; return x and string.format("%.2f,%.2f,%.2f", x.r, x.g, x.b) end
class = "rare"; IN:Update(T)
eq(tint(), "0.88,0.90,0.94", "rare: silver")
class = "rareelite"; IN:Update(T)
eq(tint(), "0.45,0.70,1.00", "rare elite: blue")
class = "worldboss"; IN:Update(T)
check(D:IsShown(), "worldboss: shown (counts as boss)")
eq(tint(), "0.95,0.43,0.28", "...boss red")
tdbD.classDragonBossColor = { r = 0.1, g = 0.2, b = 0.3 }
IN:Update(T)
eq(tint(), "0.10,0.20,0.30", "a colour of the user's own")
tdbD.classDragonBossColor = nil
tdbD.classDragonBoss = false
IN:Update(T)
check(not D:IsShown(), "Boss ticked off: hidden")
tdbD.classDragonBoss = nil
class = "rare"; tdbD.classDragonRare = false; IN:Update(T)
check(not D:IsShown(), "Rare ticked off: hidden")
tdbD.classDragonRare = nil
class = "normal"; IN:Update(T)
check(not D:IsShown(), "normal: hidden")
class = Secret("classification"); IN:Update(T)
check(not D:IsShown(), "secret classification: hidden, never guessed")
class = "elite"
tdbD.classificationEnabled = false; IN:Update(T)
check(D:IsShown(), "the Elite / Rare icon off: the dragon is its own switch")
tdbD.classificationEnabled = nil
tdbD.classDragonEnabled = false; IN:Update(T)
check(not D:IsShown(), "dragon off: hidden")
tdbD.classDragonEnabled = nil
tdbD.classDragonSide = "BOTH"; IN:Layout(T)
check(D.tex.LEFT.TOP:IsShown() and D.tex.RIGHT.TOP:IsShown(), "BOTH: both ends drawn")
eq(D.tex.LEFT.TOP._texCoord and D.tex.LEFT.TOP._texCoord[2], 0, "...the left end flipped")
tdbD.classDragonSide = "LEFT"; IN:Layout(T)
check(D.tex.LEFT.TOP:IsShown() and not D.tex.RIGHT.TOP:IsShown(), "LEFT: the right end's pieces hidden")
tdbD.classDragonSide = nil
tdbD.classDragonSize = 150; IN:Layout(T)
check(near(D.tex.RIGHT.TOP._w, 197 * 1.5 * REF), "size 150 on the frame")
tdbD.classDragonSize = nil
IN:Layout(T)
do
    -- With an outside portrait the live pieces go on it.
    local saved = UF.Portrait
    UF.Portrait = { OutsideRect = function() return 222, 0, 267, 46 end }
    tdbD.portraitSide = "RIGHT"
    IN:Layout(T)
    local pp = D.tex.RIGHT.TOP._points[#D.tex.RIGHT.TOP._points]
    eq(pp and (pp[1] .. ">" .. pp[3] .. ":" .. pp[4] .. "," .. pp[5]), "BOTTOMRIGHT>TOPRIGHT:47,0",
       "portrait on the right: the top piece on the portrait's top-right corner")
    eq(pp and pp[2], T, "...placed from the unit button's corner")
    tdbD.classDragonAnchor = "FRAME"; IN:Layout(T)
    pp = D.tex.RIGHT.TOP._points[#D.tex.RIGHT.TOP._points]
    eq(pp and (pp[3] .. ":" .. pp[4]), "TOPRIGHT:0", "Anchor To Frame: back on the frame's end")
    tdbD.classDragonAnchor, tdbD.portraitSide = nil, nil
    UF.Portrait = saved
    IN:Layout(T)
end

print("-- Classification border")
local CB = T.dfUFIcons.classBorder
check(not CB:IsShown(), "off by default")
tdbD.classBorderEnabled = true
IN:Layout(T)
check(CB:IsShown(), "on: shown")
eq(CB.edges.top._h, 2, "default thickness 2")
local bv = CB.edges.left._vertex
check(bv and bv.r == 1 and near(bv.g, 0.80), "...in the elite colour (the shared Classification Colors)")
local ep = CB.edges.top._points[1]
eq(ep and ep[1] .. ">" .. ep[3] .. ":" .. ep[4] .. "," .. ep[5], "TOPLEFT>TOPLEFT:0,0", "inside the frame's edge, where DF draws its border")
tdbD.classBorderSize = 4; IN:Layout(T)
eq(CB.edges.bottom._h, 4, "thickness follows the setting")
tdbD.frameShowBorder = false; IN:Layout(T)
check(CB:IsShown(), "the frame's own border hidden: the class border still shows")
tdbD.frameShowBorder = nil
class = "normal"; IN:Update(T)
check(not CB:IsShown(), "normal: hidden")
class = Secret("c"); IN:Update(T)
check(not CB:IsShown(), "secret: hidden")
class = "elite"; tdbD.classDragonElite = false; IN:Update(T)
check(not CB:IsShown() and not D:IsShown(), "the per-type tick hides both")
tdbD.classDragonElite = nil
tdbD.classDragonEnabled = false; IN:Update(T)
check(CB:IsShown() and not D:IsShown(), "dragon off, border on: the border alone")
tdbD.classDragonEnabled, tdbD.classBorderEnabled, tdbD.classBorderSize = nil, nil, nil
IN:Layout(T)

print("-- Combat icon border")
local pdbC = UF:GetUnitDB("player")
P.combatIcon = Make("Frame", P)
IN:Layout(P)
eq(P.combatIcon.dfUFBorder, nil, "off: no edges ever built")
pdbC.combatIconBorderEnabled = true
pdbC.combatIconBorderSize = 2
pdbC.combatIconBorderColor = { r = 1, g = 0, b = 0, a = 1 }
IN:Layout(P)
local cbd = P.combatIcon.dfUFBorder
check(cbd and cbd.top:IsShown() and cbd.right:IsShown(), "on: four edges shown")
eq(cbd and cbd.top._h, 2, "...its thickness")
local cp = cbd and cbd.top._points[1]
eq(cp and cp[4] .. "," .. cp[5], "-2,2", "...drawn OUTSIDE the icon (K.Border)")
eq(cbd and cbd.left._vertex.r, 1, "...its colour")
pdbC.combatIconBorderEnabled = false
IN:Layout(P)
check(not cbd.top:IsShown(), "off again: hidden")
local PETf = Owner("pet")
PETf.combatIcon = Make("Frame", PETf)
UF:GetUnitDB("pet").combatIconBorderEnabled = true
IN:Layout(PETf)
check(PETf.combatIcon.dfUFBorder and PETf.combatIcon.dfUFBorder.top:IsShown(), "pet (no unit icons of its own): bordered too")
UF:GetUnitDB("pet").combatIconBorderEnabled = nil
pdbC.combatIconBorderEnabled, pdbC.combatIconBorderSize, pdbC.combatIconBorderColor = nil, nil, nil
eq(UF.LIVE_KEYS.combatIconBorderSize[1], "Indicators", "the thickness slider drags live through this module")

print("-- Dragon: preview")
local TP = Owner("target")
TP.dfUFPreview = true
TP.dfTestData = { classification = "rareelite" }
IN:Attach(TP)
IN:Preview(TP)
check(TP.dfUFIcons.dragon:IsShown(), "target preview: the test panel's classification")
eq(string.format("%.2f", TP.dfUFIcons.dragon.tex.RIGHT.TOP._vertex.r), "0.45", "...rare elite blue")
TP.dfTestData = { classification = nil }
IN:Preview(TP)
check(not TP.dfUFIcons.dragon:IsShown(), "Classification: Normal -- no dragon")
check(PV.dfUFIcons.dragon:IsShown(), "focus preview: the sample rare")
TP.dfTestData = { classification = nil }
IN:Preview(TP)
check(not TP.dfUFIcons.classification:IsShown(), "Classification: Normal -- no Elite / Rare icon either")
TP.dfTestData = nil
IN:Preview(TP)
check(TP.dfUFIcons.classification:IsShown(), "no sample data at all: the elite sample icon")
eq(TP.dfUFIcons.classification.tex._atlas, IN.ART.elite, "...elite")
local BP = Owner("boss")
BP.dfUFPreview = true
BP.dfTestData = { classification = "worldboss" }
IN:Attach(BP)
IN:Preview(BP)
check(BP.dfUFIcons.classification:IsShown(), "boss preview: the boss icon still shows")
eq(BP.dfUFIcons.classification.tex._atlas, IN.ART.elite, "...the elite art (a boss is drawn as elite)")
check(not BP.dfUFIcons.dragon:IsShown(), "boss preview: off by default")
UF:GetUnitDB("boss").classDragonEnabled = true
IN:Preview(BP)
check(BP.dfUFIcons.dragon:IsShown(), "...on: the world boss shows it")
UF:GetUnitDB("boss").classDragonEnabled = nil
eq(#errs, 0, "no element errored (" .. tostring(errs[1]) .. ")")

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
