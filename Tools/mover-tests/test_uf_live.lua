local NS = ...

-- ============================================================
-- UNIT FRAMES -- LIVE SLIDER DRAGS
-- DandersFrames_UnitFrames/Core.lua UF:LiveApply, under recording stubs.
-- A drag tick re-applies ONE element of ONE unit: a unit-frame element's own
-- Layout (+ Preview on a preview frame), DandersFrames' per-frame layout for
-- its pieces (skipped on a live frame in combat: the unit button is secure),
-- the aura layout version for auras, the boss container for Boss Layout. Never
-- another unit's frames, never a full UF:RefreshAll.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "InCombatLockdown" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local DF = { PartyDefaults = {}, registered = {} }
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return t end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
DandersFrames = DF
CreateFrame = nil
local combat = false
InCombatLockdown = function() return combat end

local UF = {}
load_uf_file_into("Core.lua", UF)
check(type(UF.LiveApply) == "function", "UF:LiveApply published")

-- ---- recording stubs ---------------------------------------------------------
local log = {}
local function rec(s) log[#log + 1] = s end
local function Frame(name, unit)
    return { name = name, dfUFUnit = unit, shown = true,
             IsShown = function(self) return self.shown end,
             IsVisible = function(self) return self.shown end }
end
local P1, T1, B1, B2 = Frame("player", "player"), Frame("target", "target"), Frame("boss1", "boss"), Frame("boss2", "boss")
UF.frames = { player = P1, target = T1, boss1 = B1, boss2 = B2 }
local PP = Frame("playerPreview", "player")
UF.Preview = { shown = false, frames = { player = PP },
               Paint = function(_, f) rec("paint:" .. f.name) end }
UF.Units = { ApplyLayout = function(_, f) rec("applyLayout:" .. f.name) end,
             RepaintValues = function(_, f) rec("values:" .. f.name) end }
local function Mod(name)
    return { Layout = function(_, f) rec(name .. ".layout:" .. f.name) end,
             Preview = function(_, f) rec(name .. ".preview:" .. f.name) end }
end
UF.CastBar, UF.ClassPower, UF.Portrait, UF.Indicators = Mod("CastBar"), Mod("ClassPower"), Mod("Portrait"), Mod("Indicators")
UF.Boss = { container = {}, frames = {}, previewShown = false,
            LayoutContainer = function() rec("boss.container") end,
            PreviewRefresh = function() rec("boss.preview") end }
local owners = { castbarWidth = "castbar", portraitSize = "portrait", restingIconX = "unitIcons",
                 frameWidth = "frame", healthTexture = "health", buffSize = "buffs",
                 highlightThickness = "highlights", rangeAlpha = "fading", bossSpacing = "bosslayout",
                 tooltipX = "tooltips" }
UF.Links = { OwnerOf = function(k) return owners[k] end }
function DF:ApplyFrameLayout(f) rec("dfLayout:" .. f.name) end
function DF:InvalidateAuraLayout() rec("auras") end
function DF:UpdateHighlights(f) rec("highlights:" .. f.name) end
function DF:UpdateRange(f) rec("range:" .. f.name) end
function DF:UpdateHealthFade(f) rec("fade:" .. f.name) end
UF.RefreshAll = function() rec("REFRESHALL") end

local function run(unit, key, kind)
    log = {}
    UF:LiveApply(unit, key, kind)
    return table.concat(log, ",")
end

print("-- A unit-frame element: its own layout, on that unit only")
eq(run("player", "castbarWidth"), "CastBar.layout:player", "cast bar: only the cast bar, only the player")
eq(run("player", "portraitSize"), "Portrait.layout:player,Indicators.layout:player",
   "portrait: the portrait, and the resting glow that wraps it")
combat = true
eq(run("player", "restingIconX"), "Indicators.layout:player", "in combat too: plain frames")
combat = false

print("-- DandersFrames' pieces: the one frame's layout")
eq(run("target", "healthTexture"), "dfLayout:target,values:target", "health: DF's per-frame layout + values")
eq(run("target", "frameWidth"), "applyLayout:target,values:target", "Frame page: the frame's whole layout (size, scale)")
combat = true
eq(run("target", "frameWidth"), "", "in combat: a live unit button is never resized")
eq(run("target", "healthTexture"), "", "...nor laid out")
combat = false
eq(run("player", "highlightThickness"), "highlights:player", "highlights: their own updater")
eq(run("player", "rangeAlpha"), "range:player,fade:player", "fading: range and health fade")
eq(run("player", "buffSize"), "auras", "auras: the layout version, once")
eq(run("player", "tooltipX"), "", "tooltips: nothing to draw")
eq(run("player", nil, "health"), "dfLayout:player,values:player", "no key: the page's element answers")

print("-- The boss slots and the boss container")
run("boss", "healthTexture")
table.sort(log)
eq(table.concat(log, ","), "dfLayout:boss1,dfLayout:boss2,values:boss1,values:boss2", "boss: every slot")
eq(run("boss", "bossSpacing"), "boss.container", "Boss Layout: the container")
combat = true
eq(run("boss", "bossSpacing"), "", "...secure: skipped in combat")
combat = false

print("-- The preview, while it is up")
UF.Preview.shown = true
eq(run("player", "castbarWidth"), "CastBar.layout:player,CastBar.layout:playerPreview,CastBar.preview:playerPreview",
   "element: the preview frame gets its sample repaint")
combat = true
eq(run("player", "frameWidth"), "paint:playerPreview", "in combat the preview (not secure) still follows")
combat = false
UF.Boss.previewShown = true
eq(run("boss", "bossSpacing"), "boss.container,boss.preview", "Boss Layout: the preview container too")
UF.Preview.shown, UF.Boss.previewShown = false, false

print("-- Hidden frames still lay out; values only when shown")
T1.shown = false
eq(run("target", "healthTexture"), "dfLayout:target", "a hidden frame: layout, no values")
T1.shown = true
check(not table.concat(log, ","):find("REFRESHALL", 1, true), "never a full refresh")

-- ============================================================
-- PAINTERS: one setting repaints only its own part (LivePaint.lua)
-- ============================================================
print("-- A key with a painter: that painter, nothing else")
UF.Elements = { Kit = {} }
load_uf_file_into("LivePaint.lua", UF)
local LP = UF.LivePaint
check(LP ~= nil, "LivePaint loaded")
UF.UNITS = { "player", "target" }
UF.FrameDB = function() return {} end
UF.Rings = { PaintTracks = function(_, f) rec("tracks:" .. f.name) end,
             FeedPower = function(_, f) rec("feed:" .. f.name) end }
for _, name in ipairs({ "UpdateHealthBarAppearance", "UpdateBackgroundAppearance", "UpdateFrameAppearance",
                        "UpdateAbsorb", "UpdateHealAbsorb", "UpdateHealPrediction", "UpdateReducedMaxHealth",
                        "UpdatePower", "UpdateAllElementAppearances", "UpdateRoleIcon", "UpdateRoleIconAppearance",
                        "UpdateCombatIcon", "UpdateAllStatusIcons", "RefreshUnhealableFade", "DriveUnhealableFade",
                        "UpdateColorCurve" }) do
    DF[name] = function(_, f) rec(name .. (f and (":" .. f.name) or "")) end
end
function DF:ApplyFrameBorder(f) rec("ApplyFrameBorder:" .. f.name) end
function DF:LayoutResourceBar(f) rec("LayoutResourceBar:" .. f.name) end
function DF:AnchorHealthBarsToPadding(f) rec("Anchor:" .. f.name) end
DF.DriveFactoryRowsNow = function(f) rec("rows:" .. f.name) end
owners.buffBorderColor = "buffs"
owners.backgroundColor, owners.healthColor = "health", "health"

eq(run("target", "backgroundColor", "health"), "UpdateBackgroundAppearance:target,tracks:target",
   "background colour: the background and the ring tracks")
eq(run("target", "healthColor", "health"), "UpdateHealthBarAppearance:target", "health colour: the fill's colour")
eq(run("player", "frameBorderColor", "frame"), "ApplyFrameBorder:player,UpdateAbsorb:player,UpdateHealAbsorb:player",
   "border: the border, and the absorbs inset by it")
eq(run("player", "frameFadeAlpha", "frame"), "UpdateFrameAppearance:player", "frame fade: its own updater")
eq(run("player", "framePadding", "frame"), "Anchor:player,LayoutResourceBar:player", "padding re-anchors the bars")
eq(run("player", "resourceBarBackgroundColor", "resource"), "LayoutResourceBar:player,tracks:player",
   "resource bar background: the bar and the ring tracks")
eq(run("player", "oorPortraitAlpha", "fading"), "UpdateAllElementAppearances:player", "a fade: every part's alpha")
eq(run("player", "fadeUnhealableAlpha", "fading"), "RefreshUnhealableFade,DriveUnhealableFade:player",
   "unhealable: its settings version, then this frame")
eq(run("player", "roleIconScale", "icons"), "UpdateRoleIcon:player", "a status icon: its own updater")
eq(run("player", "roleIconAlpha", "icons"), "UpdateRoleIconAppearance:player", "...and its alpha twin")
eq(run("player", "combatIconAlpha", "icons"), "UpdateCombatIcon:player", "the combat icon too")
eq(run("player", "combatIconBorderColor", "icons"), "Indicators.layout:player", "...its border is Indicators'")
eq(run("player", "statusIconFontSize", "icons"), "UpdateAllStatusIcons:player", "the shared status font: all icons")
eq(run("player", "color", "health"),
   "UpdateColorCurve,UpdateHealthBarAppearance:player,UpdateBackgroundAppearance:player,tracks:player",
   "a gradient stop: the curves, then what paints from them")
eq(run("player", nil, "frame"), "ApplyFrameBorder:player,UpdateAbsorb:player,UpdateHealAbsorb:player",
   "no key on the Frame page: Border Alpha")
eq(run("player", "rangeUpdateInterval", "fading"), "", "nothing to show mid-drag")

print("-- Profile-wide colours: every unit")
eq(run("target", "hostile", "health"), "UpdateHealthBarAppearance:player,UpdateHealthBarAppearance:target",
   "a reaction colour repaints every unit")
eq(run("player", "RUNIC_POWER", "resource"),
   "UpdatePower:player,feed:player,UpdatePower:target,feed:target", "a power colour too")

print("-- In combat: plain paint carries on, secure sizing doesn't")
combat = true
eq(run("target", "backgroundColor", "health"), "UpdateBackgroundAppearance:target,tracks:target", "a colour in combat")
eq(run("target", "frameWidth"), "", "the frame's size in combat: nothing")
eq(run("player", "buffSize"), "auras,rows:player", "aura rows in combat")
combat = false

print("-- Auras and the boss container")
eq(run("player", "buffSize"), "auras,rows:player", "aura sliders: the version, then this frame's rows")
eq(run("player", "buffBorderColor", "buffs"), "auras,rows:player", "aura colours the same")
run("boss", "frameScale", "frame")
eq(log[1], "boss.container", "Boss: the frame's scale reaches the container")

print("-- The preview takes its own path, never a live painter")
UF.Preview.shown = true
eq(run("player", "healthColor", "health"), "UpdateHealthBarAppearance:player,paint:playerPreview",
   "a colour: the live frame's painter, the preview's repaint")
eq(run("player", "castbarColor", "castbar"),
   "CastBar.layout:playerPreview,CastBar.preview:playerPreview", "a cast bar colour on the preview")
UF.Preview.shown = false

print("-- A linked partner follows the one key")
UF.Links.LiveRoot = function() return {} end
local pushed
UF.Links.PushKey = function(_, _, from, key) pushed = from .. ":" .. key; return "target" end
eq(run("player", "healthColor", "health"), "UpdateHealthBarAppearance:player,UpdateHealthBarAppearance:target",
   "the partner repaints too")
eq(pushed, "player:healthColor", "...after the key is pushed")
UF.Links.PushKey = function() return nil end
eq(run("player", "healthColor", "health"), "UpdateHealthBarAppearance:player", "unchanged or unlinked: only this unit")
check(not table.concat(log, ","):find("REFRESHALL", 1, true), "never a full refresh")

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
