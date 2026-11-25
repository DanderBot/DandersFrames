-- ============================================================
-- HEALTH BAR INSETS + PLACEMENT STRIP (Frames/HealthRect.lua, Frames/Bars.lua)
-- The health bar's insets are the padding, or the border band with Keep Health Bar
-- Inside Border. A resource bar Placement strip (Below / Above / Left of / Right of
-- Health Bar) takes its side of where health is SEEN: the inset there is the strip's
-- seat inset + thickness + inward offset, so health ends exactly at the strip -- on
-- frames meant to carry a bar (dfResourceBarWanted) and nowhere else. Where the bar
-- SITS follows only for a strip across the fill; one along the fill is cut out of a
-- full-size health bar instead. On Top of Health Bar leaves it full size. Returns are
-- l, r, t, b, the one order every caller uses.
-- HealthRect.lua is loaded REAL; the level resolver, the border overlap and the cut-out
-- are lifted from Bars.lua by text, so this runs the shipped functions.
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
-- Where health is seen: the strip's side taken whichever way the bar fills.
local function insets(frame, over)
    local l, r, t, b = DF:GetHealthVisibleInsets(frame, DB(over))
    return table.concat({ l, r, t, b }, ",")
end

print("-- Health bar insets: a strip takes its side of the seen health, all four sides")
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
l, r, t, b = DF:GetHealthVisibleInsets(nil, nil)
eq(table.concat({ l, r, t, b }, ","), "0,0,0,0", "no db: zero seen insets")

print("-- Health bar insets: pixel perfect snaps what the strip snaps, no more")
do
    local scale = 0.64
    DF.PixelPerfect = function(_, v) return math.floor(v / scale + 0.5) * scale end
    for _, off in ipairs({ 0, 0.3, 2.5 }) do
        local _, _, _, bb = DF:GetHealthVisibleInsets(wanted, DB({ pixelPerfect = true, resourceBarStripY = off }))
        local expect = DF:PixelPerfect(1) + DF:PixelPerfect(4) + off
        check(math.abs(bb - expect) < 1e-9,
            ("pixel perfect offY=%s: snapped seat + snapped thickness + RAW offset"):format(off))
    end
    local _, _, _, bb = DF:GetHealthVisibleInsets(wanted, DB({ pixelPerfect = false }))
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

print("-- Where the health bar SITS: a strip along the fill is cut, one across it takes the room")
local function sits(frame, over)
    local l, r, t, b = DF:GetHealthBarInsets(frame, DB(over))
    return table.concat({ l, r, t, b }, ",")
end
eq(sits(wanted), "1,1,1,1", "horizontal bar, below: the health bar keeps its full rect (cut out instead)")
eq(sits(wanted, { resourceBarPlacement = "TOP" }), "1,1,1,1", "...above too")
eq(sits(wanted, { resourceBarPlacement = "LEFT" }), "5,1,1,1",
   "horizontal bar, left of: the strip sits at the fill's end, so the health bar stops at it")
eq(sits(wanted, { resourceBarPlacement = "RIGHT" }), "1,5,1,1", "...right of too")
eq(sits(wanted, { healthOrientation = "HORIZONTAL_INV" }), "1,1,1,1", "a reversed horizontal bar: the same")
eq(sits(wanted, { healthOrientation = "VERTICAL" }), "1,1,1,5", "vertical bar, below: across the fill, takes the room")
eq(sits(wanted, { healthOrientation = "VERTICAL_INV", resourceBarPlacement = "TOP" }), "1,1,5,1", "...above, reversed")
eq(sits(wanted, { healthOrientation = "VERTICAL", resourceBarPlacement = "LEFT" }), "1,1,1,1",
   "vertical bar, left of: along the fill, cut out")
eq(sits({}, { resourceBarPlacement = "LEFT" }), "1,1,1,1", "not wanted: full size either way")
eq(insets(wanted), "1,1,1,5", "where health is SEEN still stops at a cut strip (the dispel wash keeps to it)")
eq(tostring(DF:GetResourceBarCutEdge(DB())), "BOTTOM", "cut edge: horizontal, below")
eq(tostring(DF:GetResourceBarCutEdge(DB({ resourceBarPlacement = "RIGHT" }))), "nil", "...not right of")
eq(tostring(DF:GetResourceBarCutEdge(DB({ resourceBarPlacement = "RIGHT", healthOrientation = "VERTICAL_INV" }))),
   "RIGHT", "...right of a vertical bar")
eq(tostring(DF:GetResourceBarCutEdge(DB({ resourceBarPlacement = "OVER" }))), "nil", "...on top: no strip")
eq(tostring(DF:GetResourceBarCutEdge(DB({ resourceBarDetached = true }), { dfStandalone = true })), "nil",
   "...detached: no strip")

print("-- The resource bar's cut-out")
do
    local src = df_file_source("Frames/Bars.lua"):gsub("\r\n", "\n")
    local a = src:find("\nlocal RESOURCE_HOLE_TEX", 1, true)
    local e = a and src:find("\nfunction DF:MaskBarToHealthBar(", a, true)
    check(a and e, "setup: lifted the cut-out block")
    assert(loadstring("local DF = ...\n" .. src:sub(a, e), "@hole"))(DF)
end
local function Tex(kind)
    local t = { kind = kind or "Texture", masks = {} }
    function t:GetObjectType() return self.kind end
    function t:AddMaskTexture(m) self.masks[m] = true end
    function t:RemoveMaskTexture(m) self.masks[m] = nil end
    return t
end
local function count(t) local n = 0 for _ in pairs(t.masks) do n = n + 1 end return n end
local masksMade = 0
local function Bar(fill, ...)
    local bar = { regs = { ... }, fill = fill }
    function bar:GetRegions() return unpack(self.regs) end
    if fill then function bar:GetStatusBarTexture() return self.fill end end
    function bar:CreateMaskTexture()
        local m = { owner = self }
        function m:SetTexture(path, h, v, filter) self.path, self.h, self.v, self.filter = path, h, v, filter end
        function m:SetAllPoints(to) self.to = to end
        masksMade = masksMade + 1
        return m
    end
    return bar
end
local function HoleFrame()
    local fr = { dfPowerBar = {}, dfResourceBarWanted = true }
    local fill, bg, text, other = Tex(), Tex(), Tex("FontString"), Tex("MaskTexture")
    fr.healthBar = Bar(fill, fill, bg, text, other)
    fr.healthBar.dfTextureLayers = { textures = { Tex(), Tex() } }
    fr.missingHealthBar = Bar(Tex())
    fr.dfOverhealHost = Bar(nil, Tex())
    return fr, fill, bg, text, other
end
local function holeOf(bar) return bar.dfResourceHoleTex end

local fr, fill, bg, text, other = HoleFrame()
DF:SyncResourceBarHole(fr, DB())
local hole = holeOf(fr.healthBar)
check(hole ~= nil, "a strip along the fill: the health bar gets a cut-out")
eq(hole.owner, fr.healthBar, "...made on the bar itself, so it moves with the bar when it is reparented")
eq(hole.to, fr.dfPowerBar, "...the resource bar's rect")
eq(hole.h .. "," .. hole.v .. "," .. hole.filter, "CLAMPTOWHITE,CLAMPTOWHITE,NEAREST",
   "...clear inside, white outside, hard edge")
check(fill.masks[hole] and bg.masks[hole], "the health fill and the bar's own textures are cut")
check(fr.healthBar.dfTextureLayers.textures[1].masks[hole], "...and its texture layers")
local mh = holeOf(fr.missingHealthBar)
check(mh and mh ~= hole and mh.owner == fr.missingHealthBar, "the missing-health bar gets its own cut-out")
check(fr.missingHealthBar.fill.masks[mh], "...and is cut by it")
check(fr.dfOverhealHost.regs[1].masks[holeOf(fr.dfOverhealHost)], "a host frame's textures are cut by the host's mask")
eq(count(text) + count(other), 0, "font strings and other masks are left alone")
eq(fr.healthBar.dfHoleMask, hole, "the bar records its cut-out for texture layers made later")

local made = masksMade
DF:SyncResourceBarHole(fr, DB())
eq(masksMade, made, "a second sync makes no second mask")
eq(count(fill), 1, "...and adds nothing twice")

-- A bar made after the sync is cut the first time it is masked or created.
fr.dfAbsorbBar = Bar(Tex())
DF:HoleBarToResourceBar(fr, fr.dfAbsorbBar)
local ab = holeOf(fr.dfAbsorbBar)
check(ab and fr.dfAbsorbBar.fill.masks[ab], "a bar made later, with its own cut-out")
local late = Tex()
fr.dfOverhealHost.regs[2] = late
DF:HoleBarToResourceBar(fr, fr.dfOverhealHost)
eq(count(late), 0, "a texture added to a cut bar waits for a forced walk (cached)")
DF:HoleBarToResourceBar(fr, fr.dfOverhealHost, true)
check(late.masks[holeOf(fr.dfOverhealHost)], "...which the creation sites ask for")
local newFill = Tex()
fr.missingHealthBar.fill = newFill
DF:HoleBarToResourceBar(fr, fr.missingHealthBar)
check(newFill.masks[mh], "a replaced fill is cut without forcing")

DF:SyncResourceBarHole(fr, DB({ resourceBarPlacement = "RIGHT" }))
eq(count(fill) + count(bg) + count(late) + count(fr.dfAbsorbBar.fill), 0,
   "a strip across the fill (right of a horizontal bar): no cut-out, the health bar stops at it")
DF:SyncResourceBarHole(fr, DB({ resourceBarPlacement = "RIGHT", healthOrientation = "VERTICAL" }))
check(fill.masks[hole], "...but right of a vertical bar runs along the fill: cut")
DF:SyncResourceBarHole(fr, DB({ resourceBarPlacement = "OVER" }))
eq(count(fill) + count(bg) + count(late) + count(fr.dfAbsorbBar.fill), 0,
   "on top of the health bar: every cut is restored")
eq(fr.healthBar.dfHoleMask, nil, "...and new texture layers are not cut")
made = masksMade
DF:SyncResourceBarHole(fr, DB())
check(fill.masks[hole] and fr.dfAbsorbBar.fill.masks[ab], "back to a strip: cut again")
eq(masksMade, made, "...with the masks each bar already has")
fr.dfResourceBarWanted = false
DF:SyncResourceBarHole(fr, DB())
eq(count(fill), 0, "a frame not meant to carry a bar: no cut-out")
fr.dfResourceBarWanted = true
DF:SyncResourceBarHole(fr, DB({ resourceBarEnabled = false }))
eq(count(fill), 0, "resource bar off: no cut-out")
made = masksMade
local fr2 = HoleFrame()
fr2.dfResourceBarWanted = false
DF:SyncResourceBarHole(fr2, DB())
eq(masksMade, made, "a frame that never needs a cut-out never makes one")
local pet = { healthBar = Bar(Tex()) }
DF:SyncResourceBarHole(pet, DB())
eq(holeOf(pet.healthBar), nil, "a frame with no resource bar (pets) is skipped")
DF:SyncResourceBarHole(nil, DB())

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
