-- ============================================================
-- HEALTH BAR INSETS + PLACEMENT STRIP (Frames/HealthRect.lua, Frames/Bars.lua)
-- The health bar's insets are the padding, or the border band with Keep Health Bar
-- Inside Border. A resource bar Placement strip (Below / Above / Left of / Right of
-- Health Bar) SHRINKS the health bar on its side: the inset there is the strip's seat
-- inset + thickness + inward offset, so the health bar ends exactly at the strip --
-- on frames meant to carry a bar (dfResourceBarWanted) and nowhere else. On Top of
-- Health Bar leaves it full size. Returns are l, r, t, b, the one order every caller uses.
-- HealthRect.lua is loaded REAL; the level resolver and the border overlap are lifted
-- from Bars.lua by text, so this runs the shipped functions.
-- ============================================================

local DF = {
    IsResourceBarDetached = function(_, frame, db)
        return (frame and frame.dfStandalone and db and db.resourceBarDetached) and true or false
    end,
}
load_df_file_into("Frames/HealthRect.lua", DF)
local function lift(file, sig)
    local src = df_file_source(file)
    local a = src:find(sig, 1, true)
    local e = a and src:find("\nend\r?\n", a)
    check(a and e, "setup: lifted " .. sig)
    if not (a and e) then return end
    assert(loadstring("local DF = ...\n" .. src:sub(a, e + 4), "@lift"))(DF)
end
lift("Frames/Bars.lua", "function DF:ResolveResourceBarLevelOffset(frame, db)")
DF.RESOURCE_BAR_ROOM_LEVEL = DF.RESOURCE_BAR_ROOM_LEVEL or 12

local function DB(over)
    local d = {
        framePadding = 1, frameWidth = 120, frameHeight = 50, frameShowBorder = false,
        resourceBarEnabled = true, resourceBarPlacement = "BOTTOM", resourceBarMatchWidth = true,
        resourceBarHeight = 4, resourceBarAnchor = "CENTER", resourceBarX = 0, resourceBarY = 1,
        resourceBarStripX = 0, resourceBarStripY = 0, resourceBarOrientation = "HORIZONTAL",
    }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end
local function Wanted(extra)
    local f = { dfResourceBarWanted = true }
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
end
local wanted = Wanted()
-- l, r, t, b
local function insets(frame, over)
    local l, r, t, b = DF:GetHealthBarInsets(frame, DB(over))
    return table.concat({ l, r, t, b }, ",")
end

print("-- Health bar insets: a strip shrinks the health bar on its side, all four sides")
eq(insets(wanted), "1,1,1,5", "below: padding 1 + thickness 4 at the bottom, padding elsewhere")
eq(insets(wanted, { resourceBarPlacement = "TOP" }), "1,1,5,1", "above: the top")
eq(insets(wanted, { resourceBarPlacement = "LEFT" }), "5,1,1,1", "left of: the left")
eq(insets(wanted, { resourceBarPlacement = "RIGHT" }), "1,5,1,1", "right of: the right")
eq(insets(wanted, { resourceBarPlacement = "RIGHT", resourceBarOrientation = "VERTICAL" }), "1,5,1,1",
   "the side is the Placement, whatever the Orientation")
eq(insets(wanted, { resourceBarPlacement = "TOP", framePadding = 6 }), "6,6,10,6", "the strip seats at the padding")
eq(insets(wanted, { resourceBarPlacement = "OVER" }), "1,1,1,1", "On Top of Health Bar: full size, as before")

print("-- Health bar insets: the strip's own offsets")
eq(insets(wanted, { resourceBarStripY = 2 }), "1,1,1,7", "below, pushed up 2: the stop moves with the strip")
eq(insets(wanted, { resourceBarPlacement = "TOP", resourceBarStripY = -2 }), "1,1,7,1",
   "above, pushed DOWN 2 (negative Y is inward at the top)")
eq(insets(wanted, { resourceBarPlacement = "TOP", resourceBarStripY = 2 }), "1,1,3,1",
   "above, pushed UP 2, half out of the frame: only the part inside is skipped")
eq(insets(wanted, { resourceBarPlacement = "LEFT", resourceBarStripX = 3 }), "8,1,1,1", "left of, pushed right 3")
eq(insets(wanted, { resourceBarPlacement = "RIGHT", resourceBarStripX = -3 }), "1,8,1,1", "right of, pushed left 3")
eq(insets(wanted, { resourceBarStripX = 9 }), "1,1,1,5", "an offset ALONG the side does not move the stop")
eq(insets(wanted, { resourceBarStripY = -10 }), "1,1,1,1", "pushed right out of the frame: the base wins, never less")
eq(insets(wanted, { resourceBarY = 9, resourceBarX = 9 }), "1,1,1,5", "On Top's offsets are not the strip's")
eq(insets(wanted, { resourceBarHeight = 200 }), "1,1,1,48", "absurd thickness: the health bar keeps 1 unit")
eq(insets(wanted, { resourceBarPlacement = "LEFT", resourceBarHeight = 500 }), "118,1,1,1",
   "...across as well as down")

print("-- Health bar insets: a short strip (Match off) still takes the whole side")
eq(insets(wanted, { resourceBarMatchWidth = false, resourceBarWidth = 20 }), "1,1,1,5",
   "Match off: the health bar stops along the whole side, not just beside the bar")
eq(insets(wanted, { resourceBarMatchWidth = false, resourceBarPlacement = "LEFT", resourceBarAnchor = "TOPLEFT" }),
   "5,1,1,1", "...on any side and wherever Anchor puts it")

print("-- Health bar insets: frame border")
local border = { frameShowBorder = true, frameBorderSize = 3 }
local function with(t, base)
    local o = {} for k, v in pairs(base or border) do o[k] = v end
    for k, v in pairs(t or {}) do o[k] = v end return o
end
eq(insets(wanted, with()), "1,1,1,5", "Adjust off: the strip runs under the border; health stops at it")
eq(insets(wanted, with({ resourceBarMatchAdjustFrameBorder = true })), "1,1,1,7",
   "Adjust For Frame Border: the strip seats inside the band, health stops above it")
local inside = with({ healthInsideFrameBorder = true })
eq(insets({}, inside), "3,3,3,3", "Keep Inside Border: the border band on every side")
eq(insets(wanted, inside), "3,3,3,7", "...and the strip inside it too, the health bar above the strip")
eq(insets({}, with({ framePadding = 5 }, inside)), "5,5,5,5", "max, not sum: a padding deeper than the border wins")
eq(insets({}, with({ frameShowBorder = false }, inside)), "1,1,1,1", "no frame border: the padding, as before")
eq(insets({}, with({ healthInsideFrameBorder = false }, inside)), "1,1,1,1", "off: the padding, as before")
local l, r, t, b = DF:GetHealthBarInsets(nil, nil)
eq(table.concat({ l, r, t, b }, ","), "0,0,0,0", "no db: zero insets")

print("-- Health bar insets: pixel perfect snaps what the strip snaps, no more")
do
    local scale = 0.64
    DF.PixelPerfect = function(_, v) return math.floor(v / scale + 0.5) * scale end
    for _, off in ipairs({ 0, 0.3, 2.5 }) do
        local _, _, _, bb = DF:GetHealthBarInsets(wanted, DB({ pixelPerfect = true, resourceBarStripY = off }))
        local expect = DF:PixelPerfect(1) + DF:PixelPerfect(4) + off
        check(math.abs(bb - expect) < 1e-9,
            ("pixel perfect offY=%s: snapped seat + snapped thickness + RAW offset"):format(off))
    end
    local _, _, _, bb = DF:GetHealthBarInsets(wanted, DB({ pixelPerfect = false }))
    eq(bb, 5, "pixel perfect off: raw numbers")
    DF.PixelPerfect = nil
end

print("-- Health bar insets: per frame -- WANTED, not shown")
eq(insets({}, {}), "1,1,1,1", "a frame not meant to carry a bar (role / class / solo gate): full size")
eq(insets({ dfResourceBarWanted = false }), "1,1,1,1", "...wanted = false")
eq(insets(nil), "1,1,1,1", "no frame: full size")
local hiddenBar = Wanted({ dfPowerBar = { IsShown = function() return false end } })
eq(insets(hiddenBar), "1,1,1,5",
   "wanted but the bar is hidden for a moment (death, disconnect, secret power): the rect does NOT move")
eq(insets(wanted, { resourceBarEnabled = false }), "1,1,1,1", "resource bar off: full size")

print("-- Health bar insets: unit frames")
local sa = Wanted({ dfStandalone = true })
eq(insets(sa), "1,1,1,5", "standalone frame: shrinks like a group frame")
eq(insets(sa, { resourceBarDetached = true }), "1,1,1,1", "standalone, detached bar: never shrinks")
eq(insets(wanted, { resourceBarDetached = true }), "1,1,1,5",
   "a group frame ignores a stray resourceBarDetached (detach is standalone only)")
eq(insets(Wanted({ dfPinnedHeight = 20 }), { resourceBarHeight = 40 }), "1,1,1,18",
   "the 1-unit floor reads a pinned frame's own height")

print("-- The strip's inset (where the resource bar sits along its edge)")
eq(DF:GetResourceBarStripInset(DB()), 1, "the padding")
eq(DF:GetResourceBarStripInset(DB({ frameShowBorder = true, frameBorderSize = 3, resourceBarMatchAdjustFrameBorder = true })),
   3, "Adjust For Frame Border: inside the border band")
eq(DF:GetResourceBarStripInset(DB({ frameShowBorder = true, frameBorderSize = 3 })), 1, "Adjust off: under the border")
eq(DF:GetResourceBarStripInset(DB({ frameShowBorder = true, frameBorderSize = 3, healthInsideFrameBorder = true })),
   3, "Keep Health Bar Inside Border keeps the strip inside too")

print("-- Overflow: how far a strip reaches past the health bar's end")
do
    local fr = Wanted({ dfHealthRectL = 1, dfHealthRectR = 1, dfHealthRectT = 1, dfHealthRectB = 5 })
    eq(DF:GetResourceStripReachPast(fr, DB(), "BOTTOM"), 4, "below: the strip's thickness, right past the health end")
    eq(DF:GetResourceStripReachPast(fr, DB(), "RIGHT"), 0, "another side: nothing to skip")
    eq(DF:GetResourceStripReachPast({ dfHealthRectB = 5 }, DB(), "BOTTOM"), 0, "not wanted: nothing")
    eq(DF:GetResourceStripReachPast(fr, DB({ resourceBarPlacement = "OVER" }), "BOTTOM"), 0, "On Top: nothing")
    fr.dfHealthRectB = 1
    eq(DF:GetResourceStripReachPast(fr, DB({ resourceBarStripY = -10 }), "BOTTOM"), 10,
       "pushed out of the frame: up to the strip's far edge")
    fr.dfHealthRectR = 8
    eq(DF:GetResourceStripReachPast(fr, DB({ resourceBarPlacement = "RIGHT", resourceBarStripX = -3 }), "RIGHT"), 4,
       "right of, pushed in: still just its thickness")
end

print("-- The border's overlap on the health bar (absorbs and heals size by it)")
lift("Frames/Bars.lua", "function DF:GetHealthBarBorderOverlap(frame, db)")
lift("Frames/Bars.lua", "function DF:GetAbsorbEdgeInset(frame, db)")
local see = { r = 1, g = 1, b = 1, a = 0.5 }
eq(DF:GetHealthBarBorderOverlap({}, DB({ frameShowBorder = true, frameBorderSize = 2 })), 2, "a border over the bar: its size")
eq(DF:GetHealthBarBorderOverlap({}, DB({ frameShowBorder = false, frameBorderSize = 2 })), 0, "no border: 0")
eq(DF:GetHealthBarBorderOverlap({ dfReducedMaxHealthClipping = true }, DB({ frameShowBorder = true, frameBorderSize = 2 })), 0,
   "a reduced-max clip edge has no border: 0")
eq(DF:GetHealthBarBorderOverlap({}, DB({ frameShowBorder = true, frameBorderSize = 2, healthInsideFrameBorder = true })), 0,
   "Keep Health Bar Inside Border: the bar is clear of the border, 0")
eq(DF:GetAbsorbEdgeInset({}, DB({ frameShowBorder = true, frameBorderSize = 2, frameBorderColor = see })), 2,
   "absorb edge: a see-through border over the bar insets it")
eq(DF:GetAbsorbEdgeInset({}, DB({ frameShowBorder = true, frameBorderSize = 2, frameBorderColor = see,
                                   healthInsideFrameBorder = true })), 0,
   "...not when the bar is kept inside the border (no double inset)")
eq(DF:GetAbsorbEdgeInset({}, DB({ frameShowBorder = true, frameBorderSize = 2 })), 0, "an opaque border: flush")

print("-- Placement edge (shared by the rect, the layout and the options page)")
eq(tostring(DF:GetResourceBarRoomEdge(DB())), "BOTTOM", "settings alone answer for the options page")
eq(tostring(DF:GetResourceBarRoomEdge(DB({ resourceBarPlacement = "LEFT" }))), "LEFT",
   "the side is the Placement, whatever the Orientation")
eq(tostring(DF:GetResourceBarRoomEdge(DB({ resourceBarPlacement = "OVER" }))), "nil", "on top")
eq(tostring(DF:GetResourceBarRoomEdge(DB({ resourceBarEnabled = false }))), "nil", "resource bar off")
eq(tostring(DF:GetResourceBarRoomEdge(DB({ resourceBarDetached = true }), { dfStandalone = true })), "nil",
   "detached frame")
eq(tostring(DF:GetResourceBarRoomEdge(DB({ resourceBarDetached = true }))), "nil",
   "settings alone, detached (a unit page): no strip, so the page greys Placement")
eq(tostring(DF:GetResourceBarRoomEdge(nil)), "nil", "no db")

print("-- Resource bar frame level")
eq(DF:ResolveResourceBarLevelOffset(wanted, DB()), 12, "a strip: under the frame border (+14)")
eq(DF:ResolveResourceBarLevelOffset(wanted, DB({ resourceBarFrameLevel = 40 })), 12,
   "a strip does not read On Top's Frame Level")
eq(DF:ResolveResourceBarLevelOffset(wanted, DB({ resourceBarStripFrameLevel = 18 })), 18,
   "a strip reads its own Frame Level")
eq(DF:ResolveResourceBarLevelOffset(wanted, DB({ resourceBarStripFrameLevel = 0 })), 0,
   "...including 0")
eq(DF:ResolveResourceBarLevelOffset(wanted, DB({ resourceBarPlacement = "OVER", resourceBarStripFrameLevel = 18 })), 20,
   "on top: the strip's level is not read")
eq(DF:ResolveResourceBarLevelOffset(wanted, DB({ resourceBarPlacement = "OVER", resourceBarFrameLevel = 10 })), 10,
   "on top: the user's Frame Level")
eq(DF:ResolveResourceBarLevelOffset(wanted, DB({ resourceBarPlacement = "OVER" })), 20, "default +20")
eq(DF:ResolveResourceBarLevelOffset(nil, nil), 20, "no db: default +20")
