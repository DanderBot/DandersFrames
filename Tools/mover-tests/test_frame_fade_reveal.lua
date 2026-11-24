local NS = ...

-- ============================================================
-- FRAME FADE: 0%, STATUS ICONS, AND WHAT OVERRIDES IT
-- DandersFrames/Features/ElementAppearance.lua, Features/HealthFade.lua
-- ------------------------------------------------------------
-- The resolvers are LIFTED OUT OF THE SHIPPED SOURCE (not copied here) and run
-- on stubs, so a change to the engine is a change to what this file drives:
--   * GetFrameBaseAlpha / GetFrameRevealAlpha / GetStatusIconBaseAlpha
--   * GetStatusIconFadeAlpha (the status icons ignore their parent's alpha, so
--     Frame Fade has to be multiplied in explicitly)
-- ============================================================

local SRC = df_file_source("Features/ElementAppearance.lua"):gsub("\r\n", "\n")

-- A top-level function's text, from its header to the first `end` at column 0.
local function lift(header)
    local a = SRC:find(header, 1, true)
    check(a ~= nil, "source: " .. header)
    if not a then return "" end
    local b = SRC:find("\nend\n", a, true)
    check(b ~= nil, "source: ..." .. header .. " closes")
    return SRC:sub(a, (b or a) + 4)
end

local S = { combat = false, instance = false }
local DF = {}
local chunk
do
    local body = table.concat({
        lift("function DF:GetFrameBaseAlpha(db, frame)"),
        lift("function DF:GetFrameRevealAlpha(db)"),
        lift("function DF:GetStatusIconBaseAlpha(db, frame)"),
        lift("function DF:GetStatusIconFadeAlpha(frame, prefix)"),
    }, "\n")
    chunk = table.concat({
        "local S, DF = ...",
        "local function AnyFrameHovered() return DF._frameFadeHoveredFrame ~= nil and DF._frameFadeHoveredFrame.dfIsHovered == true end",
        "local function UnitAffectingCombat() return S.combat end",
        "local function IsInInstance() return S.instance end",
        "local function GetDB(frame) return frame.db end",
        "local function IsDeadOrOffline(frame) return frame.dead == true end",
        "local function GetInRange(frame) return frame.inRange ~= false end",
        "local STATUS_ICON_NO_OOR_FADE = { summonIcon = true, resurrectionIcon = true }",
        "local issecretvalue = function() return false end",
        body,
        "return DF",
    }, "\n")
end
local mk, err = (loadstring or load)(chunk, "@FrameFadeResolvers")
check(mk ~= nil, "the lifted resolvers compile on their own" .. (err and (": " .. err) or ""))
if mk then mk(S, DF) end

local function db(extra)
    local d = {
        frameFadeEnabled = true, frameFadeAlpha = 1, frameFadeSplitCombat = false,
        frameFadeAlphaOutOfCombat = 1, frameFadeAlphaInCombat = 1,
        frameFadeHoverUsesCombat = false, frameFadeHoverScope = "ALL",
        rangeFadeAlpha = 0.4, fadeDeadFrames = false, fadeDeadIcons = 0.5,
        healthFadeEnabled = false, healthFadeRevealsFrame = false,
    }
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end
local function frame(d, extra)
    local f = { db = d, unit = "party1" }
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
end

-- ============================================================
-- 1. 0% IS A VALUE, NOT "UNSET"
-- ============================================================
print("-- Frame Fade: 0% resolves to 0, not the 1 a missing value falls back to")
if DF.GetFrameBaseAlpha then
    eq(DF:GetFrameBaseAlpha(db({ frameFadeAlpha = 0 }), nil), 0, "global 0 -> 0")
    eq(DF:GetFrameBaseAlpha(db({ frameFadeSplitCombat = true, frameFadeAlphaOutOfCombat = 0 }), nil), 0,
       "split, out of combat 0 -> 0")
    S.combat = true
    eq(DF:GetFrameBaseAlpha(db({ frameFadeSplitCombat = true, frameFadeAlphaInCombat = 0 }), nil), 0,
       "split, in combat 0 -> 0")
    S.combat = false
end

-- ============================================================
-- 2. THE REVEAL VALUE
-- ============================================================
print("-- Frame Fade: the reveal value is what the frame shows in combat")
if DF.GetFrameRevealAlpha then
    eq(DF:GetFrameRevealAlpha(db({ frameFadeAlpha = 0 })), 1, "split off: full")
    eq(DF:GetFrameRevealAlpha(db({ frameFadeSplitCombat = true, frameFadeAlphaInCombat = 0.8,
                                   frameFadeAlphaOutOfCombat = 0 })), 0.8, "split on: the in-combat value")
    eq(DF:GetFrameRevealAlpha(db({ frameFadeEnabled = false, frameFadeSplitCombat = true,
                                   frameFadeAlphaInCombat = 0.3 })), 1, "Frame Fade off: full")
    eq(DF:GetFrameRevealAlpha(nil), 1, "no settings: full")
end

-- ============================================================
-- 3. STATUS ICONS DIM WITH FRAME FADE
-- ============================================================
print("-- Status icons: Frame Fade is multiplied in (they ignore their parent's alpha)")
if DF.GetStatusIconFadeAlpha then
    eq(DF:GetStatusIconFadeAlpha(frame(db()), "afkIcon"), 1, "no fade: full")
    eq(DF:GetStatusIconFadeAlpha(frame(db({ frameFadeAlpha = 0.5 })), "afkIcon"), 0.5, "Frame Fade 0.5 -> icon 0.5")
    eq(DF:GetStatusIconFadeAlpha(frame(db({ frameFadeAlpha = 0 })), "pingIcon"), 0, "Frame Fade 0 -> icon hidden (ping too)")
    eq(DF:GetStatusIconFadeAlpha(frame(db({ frameFadeAlpha = 0.5 }), { inRange = false }), "afkIcon"), 0.2,
       "...times the range fade (0.5 x 0.4)")
    eq(DF:GetStatusIconFadeAlpha(frame(db({ frameFadeAlpha = 0.5 }), { inRange = false }), "summonIcon"), 0.5,
       "...summon still skips the range fade, but not Frame Fade")
    eq(DF:GetStatusIconFadeAlpha(frame(db({ frameFadeAlpha = 0.5, fadeDeadFrames = true }), { dead = true }), "afkIcon"), 0.25,
       "...times the dead fade")
    eq(DF:GetStatusIconFadeAlpha(frame(db({ frameFadeEnabled = false, frameFadeAlpha = 0 })), "afkIcon"), 1,
       "Frame Fade switched off: icons untouched")
    -- With Health Fade's reveal on, the frame may be shown by SECRET health the icons
    -- cannot follow: they take the reveal value, so they never vanish from a hurt frame.
    eq(DF:GetStatusIconFadeAlpha(frame(db({ frameFadeSplitCombat = true, frameFadeAlphaOutOfCombat = 0,
                                            healthFadeEnabled = true, healthFadeRevealsFrame = true })), "afkIcon"), 1,
       "health reveal on: icons take the reveal value, not the hidden base")
    eq(DF:GetStatusIconFadeAlpha(frame(db({ frameFadeSplitCombat = true, frameFadeAlphaOutOfCombat = 0,
                                            healthFadeEnabled = false, healthFadeRevealsFrame = true })), "afkIcon"), 0,
       "...only while Health Fade itself is on")
end

print("-- Sweeps refresh the icons as well as the frame")
do
    local fn = SRC:match("local function RefreshFrameFadeOn%(f%)\n(.-)\nend\n")
    check(fn ~= nil and fn:find("UpdateFrameAppearance", 1, true) and fn:find("UpdateStatusIconsAppearance", 1, true),
          "one refresh writes the frame and its status icons")
    local sweep = SRC:match("local function SweepFrameFade%(%)\n(.-)\nend\n") or ""
    local _, n = sweep:gsub("RefreshFrameFadeOn%(", "")
    eq(n, 3, "the combat / hover sweep uses it for all three frame walks")
    check(uf_file_source("Units.lua"):find("DF.RefreshFrameFadeOn(f)", 1, true) ~= nil,
          "the unit frames' own combat sweep uses it too")
end

-- ============================================================
-- 4. HEALTH FADE: "SHOW BELOW THRESHOLD THROUGH FRAME FADE"
-- HealthFade.lua loaded for real, on stubs of the engine curve, with the lifted
-- resolvers above as its Frame Fade source.
-- ============================================================
local HELD = {}
for _, k in ipairs({ "C_CurveUtil", "CreateColor", "UnitHealthPercent", "UnitExists", "issecretvalue", "Enum" }) do
    HELD[k] = _G[k]
end
local enginePct = 1
C_CurveUtil = { CreateColorCurve = function()
    local c = { points = {} }
    function c:SetType() end
    function c:AddPoint(x, col) self.points[#self.points + 1] = { x, col } end
    return c
end }
Enum = Enum or {}
Enum.LuaCurveType = Enum.LuaCurveType or { Linear = 0 }
CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
-- The engine answers the step the curve encodes: above at full health, below otherwise.
UnitHealthPercent = function(_, _, curve)
    local below, above = curve.points[1][2].a, curve.points[#curve.points][2].a
    local a = (enginePct > 0.999) and above or below
    return { GetRGBA = function() return 1, 1, 1, a end }
end
UnitExists = function() return true end
issecretvalue = function() return false end

function DF:GetFrameDB(f) return f.db end
function DF:FrameInTestScope() return false end
function DF:MemTestDisabled() return false end
load_df_file_into("Features/HealthFade.lua", DF)
check(type(DF.ApplyHealthFadeAlpha) == "function", "HealthFade.lua loaded")

local function hfdb(extra)
    local d = db({ healthFadeEnabled = true, healthFadeAlpha = 1, healthFadeThreshold = 100,
                   frameFadeSplitCombat = true, frameFadeAlphaOutOfCombat = 0, frameFadeAlphaInCombat = 1 })
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end
local function liveFrame(d, extra)
    local f = { db = d, unit = "party1" }
    function f:SetAlpha(a) self.alpha = a end
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
end
local function alphaAt(pct, d, extra)
    enginePct = pct
    local f = liveFrame(d, extra)
    DF:InvalidateHealthFadeCurve()
    local applied = DF:ApplyHealthFadeAlpha(f)
    return f.alpha, applied
end

print("-- Health reveal off: today's maths (below = base, above = alpha x base)")
eq(alphaAt(1, hfdb()), 0, "out of combat, full health: hidden (above x base 0)")
eq(alphaAt(0.5, hfdb()), 0, "out of combat, hurt: STILL hidden -- the base 0 is multiplied in")

print("-- Health reveal on: the recipe -- hidden when healthy out of combat, shown when hurt")
local R = { healthFadeRevealsFrame = true }
eq(alphaAt(1, hfdb(R)), 0, "out of combat, full health: hidden")
eq(alphaAt(0.5, hfdb(R)), 1, "out of combat, hurt: shown at the in-combat value")
S.combat = true
eq(alphaAt(1, hfdb(R)), 1, "in combat, full health: shown")
eq(alphaAt(0.5, hfdb(R)), 1, "in combat, hurt: shown")
S.combat = false
eq(alphaAt(0.5, hfdb({ healthFadeRevealsFrame = true, frameFadeAlphaInCombat = 0.8 })), 0.8,
   "the reveal is the in-combat value, not always full")
eq(alphaAt(0.5, hfdb({ healthFadeRevealsFrame = true, frameFadeSplitCombat = false, frameFadeAlpha = 0 })), 1,
   "split off: revealed at full")
eq(alphaAt(0.5, hfdb(R), { dfInRange = false }), 0.4, "out of range, hurt: the range fade still applies (0.4 x 1)")
eq(alphaAt(0.5, hfdb({ healthFadeRevealsFrame = true, oorEnabled = true }), { dfInRange = false }), 1,
   "element range mode: range left to the elements, frame revealed")

print("-- Dispel cancel with the reveal on shows the frame instead of dropping to the base")
local function overlay(shown) return { dfDispelOverlay = { IsShown = function() return shown end } } end
local a, applied = alphaAt(1, hfdb({ healthFadeRevealsFrame = true, hfCancelOnDispel = true }), overlay(true))
eq(a, 1, "dispellable debuff, full health, reveal on: shown")
eq(applied, true, "...and the health fade stays the frame's alpha owner")
local _, appliedOff = alphaAt(1, hfdb({ hfCancelOnDispel = true }), overlay(true))
eq(appliedOff, false, "reveal off: the cancel still hands back to the plain appearance (unchanged)")

print("-- Test frames: the stamped-health fork takes the same values")
eq(alphaAt(1, hfdb(R), { dfIsTestFrame = true, dfHealthPct = 0.5 }), 1, "test frame, hurt: shown")
eq(alphaAt(1, hfdb(R), { dfIsTestFrame = true, dfHealthPct = 1 }), 0, "test frame, full: hidden")

print("-- Pet frames: the same reveal")
do
    local pet = liveFrame(hfdb(R))
    enginePct = 0.5
    DF:InvalidateHealthFadeCurve()
    DF:UpdatePetHealthFade(pet)
    eq(pet.alpha, 1, "hurt pet, reveal on: shown")
    local pet2 = liveFrame(hfdb())
    DF:InvalidateHealthFadeCurve()
    DF:UpdatePetHealthFade(pet2)
    eq(pet2.alpha, 0, "hurt pet, reveal off: the base (unchanged)")
end

print("-- Element range mode keeps an active health fade instead of pinning the base")
do
    local body = SRC:match("function DF:UpdateFrameAppearance%(frame%)\n(.-)\nend\n") or ""
    local oorAt = body:find("if db.oorEnabled then", 1, true)
    local hfAt = oorAt and body:find("frame.dfHealthFadeActive", oorAt, true)
    local pinAt = oorAt and body:find("ApplyOORAlpha(frame, true, base, base)", oorAt, true)
    check(oorAt and hfAt and pinAt and hfAt < pinAt, "element mode asks the health fade before pinning the base")
end

for k, v in pairs(HELD) do _G[k] = v end

-- ============================================================
-- 5. HOVER REVEAL WITHOUT THE COMBAT SPLIT
-- ============================================================
print("-- Hover: with the split off, a hovered frame shows at full")
do
    local d = db({ frameFadeAlpha = 0, frameFadeHoverUsesCombat = true, frameFadeHoverScope = "FRAME" })
    eq(DF:GetFrameBaseAlpha(d, { dfIsHovered = true }), 1, "scope FRAME: the hovered frame lifts to full")
    eq(DF:GetFrameBaseAlpha(d, { dfIsHovered = false }), 0, "...the others keep the global value")
    S.combat = true
    eq(DF:GetFrameBaseAlpha(d, { dfIsHovered = true }), 1, "...in combat too (the global value holds in combat)")
    S.combat = false
    local all = db({ frameFadeAlpha = 0.2, frameFadeHoverUsesCombat = true, frameFadeHoverScope = "ALL" })
    DF._frameFadeHoveredFrame = { dfIsHovered = true }
    eq(DF:GetFrameBaseAlpha(all, {}), 1, "scope ALL: every frame lifts while one is hovered")
    DF._frameFadeHoveredFrame = nil
    eq(DF:GetFrameBaseAlpha(all, {}), 0.2, "...and drops back when none is")
    eq(DF:GetFrameBaseAlpha(db({ frameFadeAlpha = 0.2 }), { dfIsHovered = true }), 0.2,
       "hover option off: no lift")
    eq(DF:GetFrameBaseAlpha(db({ frameFadeSplitCombat = true, frameFadeAlphaOutOfCombat = 0, frameFadeAlphaInCombat = 0.7,
                                 frameFadeHoverUsesCombat = true, frameFadeHoverScope = "FRAME" }), { dfIsHovered = true }), 0.7,
       "split on: still the in-combat value (unchanged)")
end

print("-- Hover: the edge handler and the settings no longer require the split")
do
    local fn = SRC:match("function DF:RefreshFrameFadeForHover%(frame%)\n(.-)\nend\n") or ""
    check(fn:find("db.frameFadeHoverUsesCombat", 1, true) and not fn:find("db.frameFadeSplitCombat and db.frameFadeHoverUsesCombat", 1, true),
          "the hover edge is gated on the hover option alone")
    check(fn:find("skipInCombat and UnitAffectingCombat", 1, true) ~= nil,
          "...and skips combat only when the split is on")
    local page = options_file_source("GUI/Pages/Options.lua")
    check(page:find("ffHover.disableOn", 1, true) == nil, "the hover checkbox no longer greys without the split")
    check(page:find("ffHoverScope.disableOn = function(d) return not d.frameFadeHoverUsesCombat end", 1, true) ~= nil,
          "the scope dropdown greys only with the hover option off")
end

-- ============================================================
-- 6. WOW FOREVER: SHOW WHEN PET IS NOT HAPPY
-- ============================================================
print("-- Unhappy pet: your pet's frame takes the reveal value while not Happy")
do
    DF.PetHappiness = { fadeMood = nil, IsOwnPetFrame = function(f) return f.unit == "pet" end }
    local d = db({ frameFadeSplitCombat = true, frameFadeAlphaOutOfCombat = 0, frameFadeAlphaInCombat = 0.9,
                   frameFadeRevealUnhappyPet = true })
    local pet, other = { unit = "pet" }, { unit = "party1" }
    eq(DF:GetFrameBaseAlpha(d, pet), 0, "no cached mood (option off elsewhere / no pet): the base")
    DF.PetHappiness.fadeMood = 3
    eq(DF:GetFrameBaseAlpha(d, pet), 0, "Happy: the base")
    DF.PetHappiness.fadeMood = 2
    eq(DF:GetFrameBaseAlpha(d, pet), 0.9, "Content: the reveal (in-combat) value")
    DF.PetHappiness.fadeMood = 1
    eq(DF:GetFrameBaseAlpha(d, pet), 0.9, "Unhappy: the reveal value")
    eq(DF:GetFrameBaseAlpha(d, other), 0, "...never another unit's frame")
    d.frameFadeRevealUnhappyPet = false
    eq(DF:GetFrameBaseAlpha(d, pet), 0, "option off on this frame's settings: the base")
    d.frameFadeRevealUnhappyPet, d.frameFadeEnabled = true, false
    eq(DF:GetFrameBaseAlpha(d, pet), 1, "Frame Fade off: full, as ever")
    DF.PetHappiness = nil
end
