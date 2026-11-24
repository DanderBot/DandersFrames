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
