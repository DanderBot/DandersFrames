-- ============================================================
-- HEALTH BAR INSETS + PLACEMENT STRIP (Frames/Update.lua, Frames/Bars.lua)
-- A Placement strip leaves the health bar its full rect and cuts the resource bar out of
-- every health-family texture instead, on frames meant to carry a bar and nowhere else.
-- The health bar's insets are the padding, or the border band with Keep Health Bar Inside
-- Border. A strip draws under the frame border. Lifted from source by text, so this runs
-- the shipped functions.
-- ============================================================

local DF = {
    IsResourceBarDetached = function(_, frame, db)
        return (frame and frame.dfStandalone and db and db.resourceBarDetached) and true or false
    end,
    PixelPerfect = function(_, v) return v end,
}
local function lift(file, sig)
    local src = df_file_source(file)
    local a = src:find(sig, 1, true)
    local e = a and src:find("\nend\r?\n", a)
    check(a and e, "setup: lifted " .. sig)
    assert(loadstring("local DF = ...\n" .. src:sub(a, e + 4), "@lift"))(DF)
end
lift("Frames/Update.lua", "function DF:GetResourceBarRoomEdge(db, frame)")
lift("Frames/Update.lua", "function DF:BarsInsideFrameBorder(db)")
lift("Frames/Update.lua", "function DF:GetFrameBorderBandInset(db)")
lift("Frames/Update.lua", "function DF:GetResourceBarStripInset(db)")
lift("Frames/Update.lua", "function DF:GetHealthBarInsets(frame, db)")
lift("Frames/Bars.lua", "function DF:ResolveResourceBarLevelOffset(frame, db)")
DF.RESOURCE_BAR_ROOM_LEVEL = DF.RESOURCE_BAR_ROOM_LEVEL or 12

local function DB(over)
    local d = {
        framePadding = 1, frameWidth = 120, frameHeight = 50, frameShowBorder = false,
        resourceBarEnabled = true, resourceBarPlacement = "BOTTOM", resourceBarMatchWidth = false,
        resourceBarHeight = 4, resourceBarAnchor = "CENTER", resourceBarX = 0, resourceBarY = 1,
        resourceBarOrientation = "HORIZONTAL",
    }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end
local wanted = { dfResourceBarWanted = true }
local function insets(frame, over)
    local l, t, r, b = DF:GetHealthBarInsets(frame, DB(over))
    return table.concat({ l, t, r, b }, ",")
end

print("-- Health bar insets: a Placement strip never shrinks the health bar")
eq(insets(wanted), "1,1,1,1", "below: the padding on every side")
eq(insets(wanted, { resourceBarPlacement = "TOP", framePadding = 6 }), "6,6,6,6", "above")
eq(insets(wanted, { resourceBarPlacement = "LEFT" }), "1,1,1,1", "left of")
eq(insets(wanted, { resourceBarPlacement = "RIGHT", resourceBarOrientation = "VERTICAL" }), "1,1,1,1", "right of")
eq(insets(wanted, { frameShowBorder = true, frameBorderSize = 3, resourceBarMatchAdjustFrameBorder = true }),
   "1,1,1,1", "Adjust For Frame Border moves the strip, never the health bar")

print("-- Health bar insets: Keep Health Bar Inside Border")
local inside = { frameShowBorder = true, frameBorderSize = 3, healthInsideFrameBorder = true }
local function with(t) local o = {} for k, v in pairs(inside) do o[k] = v end for k, v in pairs(t or {}) do o[k] = v end return o end
eq(insets({}, with()), "3,3,3,3", "the border band on every side")
eq(insets(wanted, with()), "3,3,3,3", "...with a strip too")
eq(insets({}, with({ framePadding = 5 })), "5,5,5,5", "max, not sum: a padding deeper than the border wins")
eq(insets({}, with({ frameShowBorder = false })), "1,1,1,1", "no frame border: the padding, as before")
eq(insets({}, with({ healthInsideFrameBorder = false })), "1,1,1,1", "off: the padding, as before")
local l, t, r, b = DF:GetHealthBarInsets(nil, nil)
eq(table.concat({ l, t, r, b }, ","), "0,0,0,0", "no db: zero insets")

print("-- The strip's inset (where the resource bar sits along its edge)")
eq(DF:GetResourceBarStripInset(DB()), 1, "the padding")
eq(DF:GetResourceBarStripInset(DB({ frameShowBorder = true, frameBorderSize = 3, resourceBarMatchAdjustFrameBorder = true })),
   3, "Adjust For Frame Border: inside the border band")
eq(DF:GetResourceBarStripInset(DB({ frameShowBorder = true, frameBorderSize = 3 })), 1, "Adjust off: under the border")
eq(DF:GetResourceBarStripInset(DB({ frameShowBorder = true, frameBorderSize = 3, healthInsideFrameBorder = true })),
   3, "Keep Health Bar Inside Border keeps the strip inside too")

print("-- The resource bar's hole")
do
    local src = df_file_source("Frames/Bars.lua"):gsub("\r\n", "\n")
    local a = src:find("\nlocal RESOURCE_HOLE_TEX", 1, true)
    local e = a and src:find("\nfunction DF:MaskBarToHealthBar(", a, true)
    check(a and e, "setup: lifted the hole block")
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
local function Frame()
    local fr = { dfPowerBar = {}, dfResourceBarWanted = true }
    local fill, bg, text, other = Tex(), Tex(), Tex("FontString"), Tex("MaskTexture")
    fr.healthBar = Bar(fill, fill, bg, text, other)
    fr.healthBar.dfTextureLayers = { textures = { Tex(), Tex() } }
    fr.missingHealthBar = Bar(Tex())
    fr.dfOverhealHost = Bar(nil, Tex())
    return fr, fill, bg, text, other
end
local function holeOf(bar) return bar.dfResourceHoleTex end

local fr, fill, bg, text, other = Frame()
DF:SyncResourceBarHole(fr, DB())
local hole = holeOf(fr.healthBar)
check(hole ~= nil, "a strip: the health bar gets a hole")
eq(hole.owner, fr.healthBar, "...made on the bar itself, so it moves with the bar when it is reparented")
eq(hole.to, fr.dfPowerBar, "...the resource bar's rect")
eq(hole.h .. "," .. hole.v .. "," .. hole.filter, "CLAMPTOWHITE,CLAMPTOWHITE,NEAREST",
   "...clear inside, white outside, hard edge")
check(fill.masks[hole] and bg.masks[hole], "the health fill and the bar's own textures are cut")
check(fr.healthBar.dfTextureLayers.textures[1].masks[hole], "...and its texture layers")
local mh = holeOf(fr.missingHealthBar)
check(mh and mh ~= hole and mh.owner == fr.missingHealthBar, "the missing-health bar gets its own hole")
check(fr.missingHealthBar.fill.masks[mh], "...and is cut by it")
check(fr.dfOverhealHost.regs[1].masks[holeOf(fr.dfOverhealHost)], "a host frame's textures are cut by the host's hole")
eq(count(text) + count(other), 0, "font strings and other masks are left alone")
eq(fr.healthBar.dfHoleMask, hole, "the bar records its hole for texture layers made later")

local made = masksMade
DF:SyncResourceBarHole(fr, DB())
eq(masksMade, made, "a second sync makes no second mask")
eq(count(fill), 1, "...and adds nothing twice")

-- A bar made after the sync is cut the first time it is masked or created.
fr.dfAbsorbBar = Bar(Tex())
DF:HoleBarToResourceBar(fr, fr.dfAbsorbBar)
local ab = holeOf(fr.dfAbsorbBar)
check(ab and fr.dfAbsorbBar.fill.masks[ab], "a bar made later, with its own hole")
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
eq(count(fill), 0, "a frame not meant to carry a bar: no hole")
fr.dfResourceBarWanted = true
DF:SyncResourceBarHole(fr, DB({ resourceBarEnabled = false }))
eq(count(fill), 0, "resource bar off: no hole")
made = masksMade
local fr2 = Frame()
fr2.dfResourceBarWanted = false
DF:SyncResourceBarHole(fr2, DB())
eq(masksMade, made, "a frame that never needs a hole never makes one")
local pet = { healthBar = Bar(Tex()) }
DF:SyncResourceBarHole(pet, DB())
eq(holeOf(pet.healthBar), nil, "a frame with no resource bar (pets) is skipped")
DF:SyncResourceBarHole(nil, DB())

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

print("-- Placement edge (shared by the layout and the options page)")
eq(tostring(DF:GetResourceBarRoomEdge(DB())), "BOTTOM", "settings alone answer for the options page")
eq(tostring(DF:GetResourceBarRoomEdge(DB({ resourceBarPlacement = "LEFT" }))), "LEFT",
   "the side is the Placement, whatever the Orientation")
eq(tostring(DF:GetResourceBarRoomEdge(DB({ resourceBarPlacement = "OVER" }))), "nil", "on top")
eq(tostring(DF:GetResourceBarRoomEdge(DB({ resourceBarEnabled = false }))), "nil", "resource bar off")
eq(tostring(DF:GetResourceBarRoomEdge(DB({ resourceBarDetached = true }), { dfStandalone = true })), "nil",
   "detached frame")
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
