local NS = ...

-- ============================================================
-- RESTED INDICATOR BUILDER -- DandersFrames/Frames/Create.lua
-- ------------------------------------------------------------
-- DF:CreateRestedIndicator is lifted out of Create.lua by its section header
-- and run against tiny recording fakes (Create.lua itself builds tooltips at
-- file scope, so it is not loaded whole). Pins:
--   1. the build: 3 Zs at 8/11/14, offsets, 24x18, hidden, level parent+5,
--      glow only when a host is given;
--   2. animated (default): an OnUpdate is set and drives alpha/size + glow;
--   3. static: no OnUpdate, Zs at alpha 1 and base size, glow at 0.3;
--   4. SetZScale scales sizes, offsets and the container;
--   5. the OUTER style: a frame of eight sliced pieces hanging outside the
--      host, its own pulse range, and SetGlowExtents widening its rect;
--   6. the outline of several rects (DF.GlowOutlinePieces / SetGlowRects):
--      one rect = the old eight pieces, an L / step traced without glowing an
--      empty corner, small gaps bridged, inside corners not drawn twice, and
--      the texture pool not growing on relayout.
-- ============================================================

local src = df_file_source("Frames/Create.lua")
local a = src:find("-- RESTED INDICATOR BUILDER", 1, true)
local b = src:find("-- SAFE UNIT WATCH REGISTRATION", 1, true)
check(a and b and a < b, "rested: builder section found in Create.lua")
if not (a and b) then return end
local body = src:sub(a, b - 1):gsub("%-%- =+%s*$", "")

local function newRegion(kind)
    local r = { kind = kind, points = {}, scripts = {}, shown = true, alpha = 1, level = 0 }
    function r:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function r:ClearAllPoints() self.points = {} end
    function r:SetSize(w, h) self.w, self.h = w, h end
    function r:SetAlpha(v) self.alpha = v end
    function r:GetAlpha() return self.alpha end
    function r:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
    function r:Hide() self.shown = false; if self.scripts.OnHide then self.scripts.OnHide(self) end end
    function r:IsShown() return self.shown end
    function r:SetScript(k, fn) self.scripts[k] = fn end
    function r:GetScript(k) return self.scripts[k] end
    function r:SetFrameLevel(l) self.level = l end
    function r:GetFrameLevel() return self.level end
    function r:SetText(t) self.text = t end
    function r:SetTextColor(...) self.color = { ... } end
    function r:SetTexture(t) self.texture = t end
    function r:SetVertexColor(...) self.vertex = { ... } end
    function r:SetBlendMode(m) self.blend = m end
    function r:SetTexCoord(...) self.coords = { ... } end
    function r:SetWidth(w) self.w = w end
    function r:SetHeight(h) self.h = h end
    function r:CreateFontString(_, layer) local f = newRegion("FontString"); f.layer = layer; return f end
    function r:CreateTexture(_, layer, _, sub) local t = newRegion("Texture"); t.layer = layer; t.sub = sub; return t end
    return r
end

local fakeDF = {}
function fakeDF:SafeSetFont(fs, _, size, flags) fs.fontSize, fs.flags = size, flags end
local function fakeCreateFrame(_, _, parent)
    local f = newRegion("Frame"); f.parent = parent; return f
end

local chunk = assert(loadstring("local DF, CreateFrame, ipairs = ...\n" .. body, "@rested_builder"))
chunk(fakeDF, fakeCreateFrame, ipairs)
check(type(fakeDF.CreateRestedIndicator) == "function", "rested: DF:CreateRestedIndicator defined")
if type(fakeDF.CreateRestedIndicator) ~= "function" then return end

-- ---- 1. build ------------------------------------------------------
local parent = newRegion("Frame"); parent.level = 10
local host = newRegion("Frame")
local ind = fakeDF:CreateRestedIndicator(parent, host)
eq(ind.parent, parent, "rested: parented to the given parent")
eq(ind.level, 15, "rested: frame level parent + 5")
eq(ind.w, 24, "rested: width 24"); eq(ind.h, 18, "rested: height 18")
eq(ind:IsShown(), false, "rested: starts hidden")
eq(#ind.points, 0, "rested: caller anchors (no point set)")
eq(#ind.zTexts, 3, "rested: three Zs")
local SZ, OX, OY = { 8, 11, 14 }, { 0, 5, 12 }, { 0, 3, 7 }
for i = 1, 3 do
    local z = ind.zTexts[i]
    eq(z.text, "Z", "rested: Z" .. i .. " text")
    eq(z.fontSize, SZ[i], "rested: Z" .. i .. " size")
    eq(z.flags, "OUTLINE", "rested: Z" .. i .. " outline")
    eq(z.points[1][4], OX[i], "rested: Z" .. i .. " x offset")
    eq(z.points[1][5], OY[i], "rested: Z" .. i .. " y offset")
    eq(z.alpha, 0, "rested: Z" .. i .. " starts transparent (animated)")
end
check(ind.glow ~= nil, "rested: glow built when a host is given")
eq(ind.glow.blend, "ADD", "rested: glow is additive")
eq(ind.glow.layer, "BACKGROUND", "rested: glow on BACKGROUND")
eq(ind.glow.sub, -8, "rested: glow sublevel -8")
eq(ind.glow.vertex[4], 0.3, "rested: glow vertex alpha 0.3")
eq(ind.glow.points[1][4], -4, "rested: glow 4px outset left")
eq(ind.glow.points[2][4], 4, "rested: glow 4px outset right")
eq(ind.glow.shown, false, "rested: glow starts hidden")

local noGlow = fakeDF:CreateRestedIndicator(parent)
eq(noGlow.glow, nil, "rested: no glow without a host")

-- ---- 2. animated ---------------------------------------------------
local onUpdate = ind:GetScript("OnUpdate")
check(type(onUpdate) == "function", "rested: animated by default (OnUpdate set)")
ind:Show(); ind.glow:Show()
onUpdate(ind, 0.5)   -- progress 0.25: Z1 in its fade-in
check(ind.zTexts[1].alpha > 0 and ind.zTexts[1].alpha < 1, "rested: Z1 mid fade-in after 0.5s")
check(ind.zTexts[1].fontSize < 8, "rested: Z1 scaled down while fading in")
check(ind.glow.alpha >= 0.15 and ind.glow.alpha <= 0.45, "rested: glow pulses within 0.15-0.45")
onUpdate(noGlow, 0.5)  -- no glow: must not error
check(true, "rested: OnUpdate without glow is safe")

-- ---- 3. static -----------------------------------------------------
ind:SetAnimated(false)
eq(ind:GetScript("OnUpdate"), nil, "rested: static stops the OnUpdate")
for i = 1, 3 do
    eq(ind.zTexts[i].alpha, 1, "rested: static Z" .. i .. " full alpha")
    eq(ind.zTexts[i].fontSize, SZ[i], "rested: static Z" .. i .. " base size")
end
eq(ind.glow.alpha, 0.3, "rested: static glow fixed at 0.3")
ind:SetAnimated(true)
check(ind:GetScript("OnUpdate") ~= nil, "rested: animation switches back on")

-- ---- 4. scale ------------------------------------------------------
ind:SetAnimated(false)
ind:SetZScale(2)
eq(ind.w, 48, "rested: scale 2 doubles width"); eq(ind.h, 36, "rested: scale 2 doubles height")
for i = 1, 3 do
    eq(ind.zTexts[i].fontSize, SZ[i] * 2, "rested: scaled Z" .. i .. " size")
    eq(ind.zTexts[i].points[1][4], OX[i] * 2, "rested: scaled Z" .. i .. " x offset")
    eq(ind.zTexts[i].points[1][5], OY[i] * 2, "rested: scaled Z" .. i .. " y offset")
end

-- ---- 5. the OUTER style -------------------------------------------
local oh = newRegion("Frame"); oh.level = 7
local outer = fakeDF:CreateRestedIndicator(parent, oh, { glowStyle = "OUTER" })
local og = outer.glow
eq(outer.glowStyleName, "OUTER", "outer: style recorded")
eq(og.kind, "Frame", "outer: the glow is a frame of pieces")
eq(og.parent, oh, "outer: parented to the host")
eq(og.level, 7, "outer: at the host's level")
eq(og.shown, false, "outer: starts hidden")
eq(#og.pieces, 8, "outer: eight pieces (the centre is never drawn)")
for i, t in ipairs(og.pieces) do
    eq(t.texture, "Interface\\AddOns\\DandersFrames\\Media\\DF_OuterGlow", "outer: piece " .. i .. " art")
    eq(t.blend, "ADD", "outer: piece " .. i .. " additive")
    eq(t.vertex[1], 1, "outer: piece " .. i .. " gold r"); eq(t.vertex[2], 0.82, "outer: piece " .. i .. " gold g")
end
-- the top-left corner hangs off the rect's TOPLEFT by its BOTTOMRIGHT
eq(og.pieces[1].points[1][1], "BOTTOMRIGHT", "outer: corner hangs outside")
eq(og.pieces[1].points[1][3], "TOPLEFT", "...off the rect's corner")
eq(og.pieces[1].w, 10, "outer: default spread 10")
eq(og.pieces[2].h, 10, "outer: top edge 10 tall")
eq(og.points[1][4], 0, "outer: no outset by default (left)")
eq(og.points[1][5], 0, "outer: no outset by default (top)")
outer:SetGlowExtents(30, 5, 2, 3)
eq(og.points[1][2], oh, "extents: anchored to the host")
eq(og.points[1][4], -30, "extents: left widens the rect")
eq(og.points[1][5], 2, "extents: top")
eq(og.points[2][4], 5, "extents: right")
eq(og.points[2][5], -3, "extents: bottom")
og:Show()
outer:GetScript("OnUpdate")(outer, 0.3)
check(og.alpha >= 0.5 and og.alpha <= 1, "outer: pulses within 0.5-1")
outer:SetAnimated(false)
eq(og.alpha, 0.75, "outer: static at 0.75")
local spread = fakeDF:CreateRestedIndicator(parent, oh, { glowStyle = "OUTER", glowSpread = 6 })
eq(spread.glow.pieces[1].w, 6, "outer: glowSpread honoured")
-- FILL keeps its extents path too
ind:SetGlowExtents(10, 0, 0, 0)
eq(ind.glow.points[1][4], -14, "fill: extents add to the 4px outset")
eq(fakeDF:CreateRestedIndicator(parent, host).glowStyleName, "FILL", "fill: the default style")

-- ---- 6. outline of several rects -------------------------------------
local GOP = fakeDF.GlowOutlinePieces
check(type(GOP) == "function", "outline: DF.GlowOutlinePieces exposed")
local function count(pieces, kind)
    local n = 0
    for _, p in ipairs(pieces) do if not kind or p[1] == kind then n = n + 1 end end
    return n
end
local function pstr(p) return table.concat({ p[1], p[2], p[3], p[4], p[5] }, ",") end
local function has(pieces, want)
    for _, p in ipairs(pieces) do if pstr(p) == want then return true end end
    return false
end
local function dump(pieces)
    local t = {}
    for _, p in ipairs(pieces) do t[#t + 1] = pstr(p) end
    return table.concat(t, " | ")
end
-- No piece may sit on a rect the caller passed (the glow stays outside).
local function noneInside(pieces, rects, label)
    for _, p in ipairs(pieces) do
        for _, r in ipairs(rects) do
            local ix = math.min(p[2] + p[4], r[3]) - math.max(p[2], r[1])
            local iy = math.min(p[3] + p[5], r[4]) - math.max(p[3], r[2])
            if ix > 0 and iy > 0 then
                check(false, label .. ": " .. pstr(p) .. " overlaps a rect")
                return
            end
        end
    end
    check(true, label .. ": no piece on the shape")
end
-- Pieces must not overlap each other (ADD blend would double them).
local function noOverlaps(pieces, label)
    for a = 1, #pieces do
        for b = a + 1, #pieces do
            local p, q = pieces[a], pieces[b]
            -- a band (a strip carried past a cut inside corner) may overlap
            -- the step's outside corner by design
            local ix = math.min(p[2] + p[4], q[2] + q[4]) - math.max(p[2], q[2])
            local iy = math.min(p[3] + p[5], q[3] + q[5]) - math.max(p[3], q[3])
            if ix > 0 and iy > 0 and not (p[7] or q[7]) then
                check(false, label .. ": " .. pstr(p) .. " overlaps " .. pstr(q))
                return
            end
        end
    end
    check(true, label .. ": no two pieces overlap")
end
local function nIn(pieces)
    return count(pieces, "IN_TL") + count(pieces, "IN_TR") + count(pieces, "IN_BL") + count(pieces, "IN_BR")
end
local function nOut(pieces)
    return count(pieces, "OUT_TL") + count(pieces, "OUT_TR") + count(pieces, "OUT_BL") + count(pieces, "OUT_BR")
end

-- one rect = the old nine-slice: four strips, four outside corners
local one = GOP({ { 0, 0, 100, 40 } }, 10)
eq(count(one), 8, "one rect: eight pieces")
for _, w in ipairs({ "TOP,0,-10,100,10", "BOTTOM,0,40,100,10", "LEFT,-10,0,10,40", "RIGHT,100,0,10,40",
                     "OUT_TL,-10,-10,10,10", "OUT_TR,100,-10,10,10", "OUT_BL,-10,40,10,10", "OUT_BR,100,40,10,10" }) do
    check(has(one, w), "one rect: " .. w)
end
eq(count(GOP({}, 10)), 0, "no rects: nothing")
eq(count(GOP(nil, 10)), 0, "nil rects: nothing")
eq(count(GOP({ { 5, 5, 5, 20 } }, 10)), 0, "a zero-width rect is ignored")
check(has(GOP({ { 0.4, -0.4, 99.6, 40.4 } }, 10), "TOP,0,-10,100,10"), "fractions round to whole units")

-- The screenshot: portrait on the left, taller than the frame; a class bar
-- across the top of the frame only (2px gap), reaching higher than the portrait.
local frameR, portR, barR = { 0, 0, 200, 40 }, { -62, -6, -2, 46 }, { 0, -20, 200, -2 }
local L = GOP({ frameR, portR, barR }, 10)
noneInside(L, { frameR, portR, barR }, "L")
noOverlaps(L, "L")
for _, p in ipairs(L) do
    if p[3] < -16 and p[2] < -10 then
        check(false, "L: nothing glows in the empty corner above the portrait (" .. pstr(p) .. ")")
    end
end
check(has(L, "TOP,0,-30,200,10"), "L: the bar's top strip spans the bar only")
check(has(L, "TOP,-62,-16,52,10"), "L: the portrait's top strip stops short of the inside corner")
check(has(L, "IN_TL,-10,-16,10,10"), "L: an inside-corner piece where the portrait meets the bar")
check(has(L, "LEFT,-10,-20,10,4"), "L: the bar's left strip stops short of it too")
check(has(L, "OUT_TL,-10,-30,10,10"), "L: the bar's own top-left corner")
check(has(L, "OUT_TL,-72,-16,10,10"), "L: the portrait's top-left corner")
check(has(L, "IN_BR,-2,40,10,6"), "L: inside corner under the frame by the lower portrait, cut to the 6px step")
eq(dump(L):find("BOTTOM,8,40,192,10", 1, true) ~= nil, true, "L: the frame's bottom strip stops short of it")
eq(nIn(L), 2, "L: two inside corners")
for _, p in ipairs(L) do
    if p[1] == "IN_BR" then
        eq(table.concat(p[6], ","), "1,0,1,0.4", "L: the cut corner's art is mirrored and cropped to its 6px")
    end
end
eq(nOut(L), 6, "L: six outside corners")

-- the same with the bar on the BOTTOM: mirrored
local barB = { 0, 42, 200, 60 }
local LB = GOP({ frameR, portR, barB }, 10)
noneInside(LB, { frameR, portR, barB }, "bar below")
noOverlaps(LB, "bar below")
check(has(LB, "BOTTOM,0,60,200,10"), "bar below: its bottom strip spans the bar only")
check(has(LB, "IN_BL,-10,46,10,10"), "bar below: an inside corner under the portrait")
check(has(LB, "IN_TR,0,-16,10,10") == false, "bar below: nothing stray")
eq(nIn(LB), 2, "bar below: two inside corners")

-- a bar wider than frame and portrait together: one straight top edge
local wide = { -90, -20, 230, -2 }
local W = GOP({ frameR, portR, wide }, 10)
noneInside(W, { frameR, portR, wide }, "wide bar")
noOverlaps(W, "wide bar")
eq(count(W, "TOP"), 1, "wide bar: one top strip")
check(has(W, "TOP,-90,-30,320,10"), "wide bar: the bar's full width")

-- portrait shorter than the frame: the frame's own top / bottom run straight
local shortP = { -42, 8, -2, 32 }
local SP = GOP({ frameR, shortP }, 10)
noneInside(SP, { frameR, shortP }, "short portrait")
noOverlaps(SP, "short portrait")
check(has(SP, "TOP,0,-10,200,10") and has(SP, "BOTTOM,0,40,200,10"), "short portrait: the frame's top and bottom whole")
eq(nIn(SP), 2, "short portrait: two inside corners beside it")

-- a small gap is bridged: one shape, as if the rects touched
local gapped = GOP({ { 0, 0, 100, 40 }, { 0, -16, 100, -8 } }, 10)
eq(count(gapped), 8, "8px gap: bridged into one shape (" .. dump(gapped) .. ")")
check(has(gapped, "TOP,0,-26,100,10"), "8px gap: the glow tops the bar")
for _, p in ipairs(gapped) do
    check(not (p[3] > -16 and p[3] < 0 and p[4] > 10), "8px gap: nothing squeezed into the gap (" .. pstr(p) .. ")")
end
eq(count(GOP({ { 0, 0, 100, 40 }, { 0, -10, 100, -2 } }, 10)), 8, "2px gap: one shape")
eq(count(GOP({ { 0, 0, 100, 40 }, { -60, 0, -1, 40 } }, 10)), 8, "a 1px side gap: one shape")
-- a gap wider than two spreads: two shapes, each glowing whole
eq(count(GOP({ { 0, 0, 100, 40 }, { 0, -60, 100, -30 } }, 10)), 16, "30px gap: two separate glows")
-- small jogs (a border poking 1px past its neighbour) snap straight
eq(count(GOP({ { 0, 0, 100, 40 }, { -1, -9, 101, -1 } }, 10)), 8, "1px jog: one straight-edged box")
-- a rect inside another (portrait drawn inside the frame) adds nothing
eq(count(GOP({ frameR, { 2, 2, 38, 38 } }, 10)), 8, "a rect inside another adds nothing")

-- ---- SetGlowRects on the indicator ---------------------------------------
local rh = newRegion("Frame"); rh.level = 3
local ri = fakeDF:CreateRestedIndicator(parent, rh, { glowStyle = "OUTER" })
local rg = ri.glow
ri:SetGlowRects({ frameR, portR, barR })
eq(rg.outlineCount, #L, "rects: one texture per outline piece")
for i = 1, 8 do eq(rg.pieces[i].shown, false, "rects: nine-slice piece " .. i .. " hidden") end
local poolN = #rg.outlinePool
eq(poolN, #L, "rects: pool sized to the outline")
local innerTex = 0
for i = 1, rg.outlineCount do
    local t = rg.outlinePool[i]
    eq(t.shown, true, "rects: piece " .. i .. " shown")
    eq(t.blend, "ADD", "rects: piece " .. i .. " additive")
    eq(t.vertex[2], 0.82, "rects: piece " .. i .. " gold")
    if t.texture == "Interface\\AddOns\\DandersFrames\\Media\\DF_OuterGlowInner" then innerTex = innerTex + 1 end
end
eq(innerTex, 2, "rects: inside corners use the inside-corner art")
eq(rg.points[1][2], rh, "rects: glow frame on the host")
local first = rg.outlinePool[1]
eq(first.points[1][1], "TOPLEFT", "rects: pieces anchor by TOPLEFT")
eq(first.points[1][4], L[1][2], "rects: x offset as computed")
eq(first.points[1][5], -L[1][3], "rects: y down becomes WoW's negative offset")
for _ = 1, 5 do ri:SetGlowRects({ frameR, portR, barR }) end
eq(#rg.outlinePool, poolN, "rects: relayout reuses the pool")
ri:SetGlowRects({ frameR })
eq(#rg.outlinePool, poolN, "rects: a smaller outline keeps the pool")
eq(rg.outlineCount, 8, "rects: one rect = eight pieces")
local shownN = 0
for _, t in ipairs(rg.outlinePool) do if t.shown then shownN = shownN + 1 end end
eq(shownN, 8, "rects: the spares are hidden")
ri:SetGlowExtents(0, 0, 0, 0)
for i = 1, 8 do eq(rg.pieces[i].shown, true, "extents again: nine-slice piece " .. i .. " back") end
shownN = 0
for _, t in ipairs(rg.outlinePool) do if t.shown then shownN = shownN + 1 end end
eq(shownN, 0, "extents again: outline pieces hidden")
eq(rg.points[1][4], 0, "extents again: anchored as before")
ri:SetGlowRects({ frameR, barR })
ri:SetGlowRects(nil)
eq(rg.outlineCount, nil, "rects nil: back to the host's own rect")
rg:Show()
ri:GetScript("OnUpdate")(ri, 0.3)
check(rg.alpha >= 0.5 and rg.alpha <= 1, "rects: pulse unchanged")
-- FILL: the rects' bounding box, outset 4
local fi = fakeDF:CreateRestedIndicator(parent, rh)
fi:SetGlowRects({ frameR, portR, barR })
eq(fi.glow.points[1][4], -66, "fill rects: left = leftmost - 4")
eq(fi.glow.points[1][5], 24, "fill rects: top = topmost + 4 (WoW up)")
eq(fi.glow.w, 270, "fill rects: bounding width + 8")
eq(fi.glow.h, 74, "fill rects: bounding height + 8")

-- ---- party/raid call sites use the builder ---------------------------
local n = 0
for _ in src:gmatch('frame%.restedIndicator = DF:CreateRestedIndicator%(frame%.contentOverlay, frame, { glowStyle = "OUTER" }%)') do n = n + 1 end
eq(n, 2, "rested: both party/raid build sites use the builder, with the OUTER glow")
check(not src:find("DF:CreateRestedIndicator(frame.contentOverlay, frame)", 1, true), "rested: no party/raid site left on the FILL wash")
check(not src:find('frame.restedIndicator = CreateFrame(', 1, true), "rested: no hand-rolled copy left")
