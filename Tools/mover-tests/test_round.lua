local NS = ...

-- ============================================================
-- ROUNDED SURFACE -- DandersUI/Round.lua
-- ------------------------------------------------------------
-- ☠ REWRITTEN with the module. This file used to assert a FIFTEEN-TEXTURE
-- assembly: four corner quarter-discs, four quarter-arcs, seven flat strips, and
-- the eight-argument texcoords that turned one baked orientation into four
-- corners. All of that is gone -- the assembly's butt joints flickered open
-- during the popout's scale animation ("I can see gaps when the popout animates
-- in and out"), which no amount of correct anchor arithmetic fixes, because two
-- independently-rasterised quads sharing an edge at a fractional scale can round
-- apart. The surface is now ONE nine-sliced texture per layer.
--
-- So the ways it can be wrong have changed completely, and they are:
--
--   * the SLICE MARGINS not matching the radius -- the corner then renders at
--     some other size, or the art is cut in the wrong place and the curve is
--     squashed into a band
--   * the wrong SHAPE FILE -- a title strip drawn from the all-four art rounds
--     its bottom corners off the panel it is supposed to join
--   * a tint landing on the wrong texture, or on only one of the two
--   * a ring drawn UNDER its own fill (both live on BACKGROUND sublevels)
--   * the surface not being its own rect -- SetAllPoints against the wrong region
--   * an unsupported corner combination silently drawing something, instead of
--     saying it has no art for it
--
-- All are questions about recorded calls, which is what this file asserts. What
-- it CANNOT answer is the only question the prototype exists for -- whether the
-- curve reads crisp at a real UI scale, and whether the gaps are actually gone
-- during the animation -- so nothing here is a substitute for opening the demo.
--
-- ☠ ONE RUNTIME, SHARED LIBRARY TABLE. run.py loads every test_*.lua into the
-- same LuaRuntime in alphabetical order, so the popout suites have normally
-- already installed their half of the kit onto NS.__DandersUI. Everything below
-- ADDS rather than replaces, and UI.MEDIA is restored at the end -- Round.lua
-- captures its media path at ITS file scope, so a later restore cannot reach it.
-- ============================================================

local UI = NS.__DandersUI

-- ---- what the other suites would have installed --------------------
UI.Colors = UI.Colors or {}
UI.Colors.element = UI.Colors.element or { r = 0.18, g = 0.18, b = 0.18, a = 1 }
UI.Colors.border  = UI.Colors.border  or { r = 0.25, g = 0.25, b = 0.25, a = 1 }
-- Core.lua is never loaded headless, so the library's error funnel is not there.
-- Recorded rather than silenced: the factory's "that is not a frame" guard and
-- the "no art for those corners" refusal are both asserted below and both have to
-- be observable.
local errors = {}
if not UI.Error then
    function UI:Error(msg) errors[#errors + 1] = tostring(msg) end
end
local function lastError() return errors[#errors] or "" end

-- A path with something in it, so an assertion reads as a whole filename rather
-- than as a bare basename that would also match an empty prefix.
local savedMedia = UI.MEDIA
UI.MEDIA = "MEDIA\\"
load_ui_file("Round.lua")
UI.MEDIA = savedMedia

local ROUND = "MEDIA\\Round\\"

-- ---- helpers -------------------------------------------------------
local function surfaceFrame()
    -- 200 x 40: a plausible row plate, and wider than it is tall so a swapped
    -- axis shows up as an obviously wrong anchor rather than as a square that
    -- happens to still look square.
    return FakeUIFrame(200, 40, 0, 0)
end

local ALL   = { tl = true, tr = true, bl = true, br = true }
local TOP   = { tl = true, tr = true }

print("-- Round: the surface is two textures")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, { radius = 6 })
    check(s ~= nil, "factory returns a handle")
    -- THE HEADLINE. Fifteen quads was fourteen joints that could flicker apart
    -- mid-animation; two textures have none, and neither of them touches the
    -- other. If this number ever climbs back up, the gaps come with it.
    eq(#f._textures, 2, "two textures: one fill, one ring -- no joints to open")
    eq(#s.textures, 2, "the handle knows both")
    eq(#s.borderTextures, 1, "one of them is the ring")
    eq(s.textures[1], s.fill, "...and the fill is first")
    eq(s.borderTextures[1], s.ring, "...the ring is the border one")
    eq(s:GetRadius(), 6, "radius as asked")
    local _, w = s:GetRadius()
    eq(w, 1, "border width defaults to 1")
    check(s.sliced, "the harness client supports SetTextureSliceMargins")

    -- The surface is idempotent per frame: a second call re-uses rather than
    -- stacking a second pair on top, which would double every colour's alpha and
    -- look like a tinting bug.
    UI:CreateRoundedSurface(f, { radius = 8 })
    eq(#f._textures, 2, "a second call on the same frame creates nothing new")
    eq(UI:GetRoundedSurface(f), s, "...and hands back the same handle")
    eq(s:GetRadius(), 8, "...re-issued with the new radius")
end

print("-- Round: draw order")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, { radius = 6 })
    eq(s.fill._layer, "BACKGROUND", "the fill is on BACKGROUND")
    eq(s.ring._layer, "BACKGROUND", "so is the ring")
    eq(s.fill._sublevel, -4, "the fill sits at sublevel -4")
    eq(s.ring._sublevel, -2, "the ring sits at -2, ABOVE it")
    -- Both negative, so a square backdrop left on the frame (bgFile lands at
    -- sublevel 0) would paint over the whole surface. That is deliberate: it
    -- makes a forgotten SetBackdrop(nil) look like nothing happened rather than
    -- like the corners half-working.
    check(s.fill._sublevel < 0 and s.ring._sublevel < 0,
          "both sublevels are below a backdrop's bgFile")
end

-- ============================================================
-- THE SLICE CONTRACT -- the module's half of the generator's bargain.
--
-- SetTextureSliceMargins takes TEXTURE PIXELS. The engine holds each corner cell
-- at that many pixels of art mapped to the same count of UI units, so passing
-- `radius` as all four margins only means "radius UI units of curve" because
-- Tools/generate_rounded.py bakes at ONE TEXEL PER UI UNIT.
--
-- That density lives in two places (a Python script and a Lua module) and nothing
-- at runtime can compare them, so this is where they are pinned. Change the bake
-- density and every consumer's radius silently changes meaning with nothing to
-- notice it -- these assertions are the notice.
-- ============================================================
print("-- Round: slice margins are the radius, on both textures")
do
    for _, R in ipairs({ 4, 6, 8 }) do
        local s = UI:CreateRoundedSurface(surfaceFrame(), { radius = R })
        for _, pair in ipairs({ { s.fill, "fill" }, { s.ring, "ring" } }) do
            local t, name = pair[1], pair[2]
            local m = t._sliceMargins
            eq(m and #m, 4, "r" .. R .. " " .. name .. ": all four margins were set")
            eq(m[1], R, "r" .. R .. " " .. name .. ": left margin is the radius")
            eq(m[2], R, "r" .. R .. " " .. name .. ": top margin is the radius")
            eq(m[3], R, "r" .. R .. " " .. name .. ": right margin is the radius")
            eq(m[4], R, "r" .. R .. " " .. name .. ": bottom margin is the radius")
            -- Stretched, not Tiled: the edge bands are a constant run of colour,
            -- so stretching is exact and tiling would repeat a 4px band across
            -- 400 units for no visible difference.
            eq(t._sliceMode, Enum.UITextureSliceMode.Stretched,
               "r" .. R .. " " .. name .. ": stretched, not tiled")
        end
    end

    -- SetRadius has to re-state the MARGINS as well as the file. Re-pointing only
    -- the texture would cut the new art at the old radius, which is the one way
    -- this can be wrong that still puts a curve on screen.
    local s = UI:CreateRoundedSurface(surfaceFrame(), { radius = 6 })
    eq(s.fill._sliceMargins[1], 6, "the surface starts on r6's margins")
    s:SetRadius(8)
    eq(s.fill._sliceMargins[1], 8, "SetRadius re-cuts the fill")
    eq(s.ring._sliceMargins[4], 8, "...and the ring")
end

print("-- Round: the surface IS its rect")
do
    -- A sliced texture has no internal geometry to get wrong -- it is stretched
    -- over the whole rect and the engine holds the corners. So "where is it" is
    -- one question per texture.
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, { radius = 6 })
    eq(s.fill._allPoints, f, "the fill covers the frame")
    eq(s.ring._allPoints, f, "so does the ring")
    eq(#s.fill._points, 0, "...with no per-edge anchors of its own")
end

print("-- Round: art per shape, radius and width")
do
    for _, r in ipairs({ 4, 6, 8 }) do
        for _, w in ipairs({ 1, 2 }) do
            local f = surfaceFrame()
            local s = UI:CreateRoundedSurface(f, { radius = r, borderWidth = w })
            eq(s.fill._texture, ROUND .. "rect_r" .. r, "r" .. r .. ": fill art")
            eq(s.ring._texture, ROUND .. "ring_r" .. r .. "_w" .. w,
               "r" .. r .. " w" .. w .. ": ring art")
            eq(#f._textures, 2, "r" .. r .. ": the count does not move with the radius")
        end
    end

    -- SetRadius is a RE-POINT of the same two textures, never a new pair -- that
    -- is what makes a demo's cycle button cheap enough to drive on every click.
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, { radius = 4, borderWidth = 1 })
    s:SetRadius(8, 2)
    eq(#f._textures, 2, "SetRadius creates nothing")
    eq(s.fill._texture, ROUND .. "rect_r8", "SetRadius re-points the fill art")
    eq(s.ring._texture, ROUND .. "ring_r8_w2", "SetRadius re-points the ring art")
end

print("-- Round: unsupported radius snaps to the nearest that has art")
do
    local f = surfaceFrame()
    -- Not a clamp: 5 is nearer 4 than 6, so it must land on 4 rather than on the
    -- bottom of the range or on the default. A radius with no file is an
    -- INVISIBLE surface, which is why this cannot be left to the caller.
    eq(UI:CreateRoundedSurface(f, { radius = 5 }):GetRadius(), 4, "5 -> 4")
    eq(UI:CreateRoundedSurface(surfaceFrame(), { radius = 7.5 }):GetRadius(), 8, "7.5 -> 8")
    -- 7 is exactly between 6 and 8. Pinned rather than left to chance: the scan
    -- keeps the first of an equal pair, so a tie resolves DOWN -- the safer half,
    -- since a corner that came out bigger than asked is the one a caller notices.
    eq(UI:CreateRoundedSurface(surfaceFrame(), { radius = 7 }):GetRadius(), 6, "7 ties, and ties go down")
    eq(UI:CreateRoundedSurface(surfaceFrame(), { radius = 99 }):GetRadius(), 8, "99 -> 8")
    eq(UI:CreateRoundedSurface(surfaceFrame(), { radius = 0 }):GetRadius(), 4, "0 -> 4")
    local _, w = UI:CreateRoundedSurface(surfaceFrame(), { borderWidth = 9 }):GetRadius()
    eq(w, 2, "border width 9 -> 2")
    eq(UI:CreateRoundedSurface(surfaceFrame()):GetRadius(), 6, "no radius -> the default 6")
end

print("-- Round: repaint")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, {
        fill   = { 0.1, 0.2, 0.3, 0.4 },
        border = { r = 0.5, g = 0.6, b = 0.7, a = 0.8 },
    })

    -- The art is flat white with the shape in its alpha, so BOTH layers tint with
    -- SetVertexColor -- and both colour shapes the rest of the kit accepts
    -- ({r,g,b,a} and the array form) have to land the same way, because the two
    -- are used side by side across the consumers.
    local function fillIs(r, g, b, a, why)
        local v = s.fill._vertex
        check(v and v.r == r and v.g == g and v.b == b and v.a == a, why)
    end
    local function borderIs(r, g, b, a, why)
        local v = s.ring._vertex
        check(v and v.r == r and v.g == g and v.b == b and v.a == a, why)
    end

    fillIs(0.1, 0.2, 0.3, 0.4, "array-form fill tints the fill texture")
    borderIs(0.5, 0.6, 0.7, 0.8, "table-form border tints the ring")

    -- THE HOVER PATH. A plate lighting up under the cursor drives SetFillColor on
    -- every OnEnter and OnLeave. The failure to guard against is the two tints
    -- crossing: a fill repaint that also wrote the ring would drag the border
    -- colour along with every hover.
    s:SetFillColor(1, 0, 0, 0.5)
    fillIs(1, 0, 0, 0.5, "SetFillColor repaints the fill")
    borderIs(0.5, 0.6, 0.7, 0.8, "...and leaves the ring alone")

    s:SetBorderColor(0, 1, 0, 1)
    borderIs(0, 1, 0, 1, "SetBorderColor repaints the ring")
    fillIs(1, 0, 0, 0.5, "...and leaves the fill alone")

    -- The accent path takes a colour TABLE (that is what GetAccent hands back),
    -- so the setters accept one in place of four numbers.
    s:SetBorderColor({ r = 0.45, g = 0.45, b = 0.95, a = 1 })
    borderIs(0.45, 0.45, 0.95, 1, "a colour table works in place of four numbers")

    local fr, fg, fb, fa = s:GetFillColor()
    eq(fr, 1, "GetFillColor reads back r")
    eq(fa, 0.5, "GetFillColor reads back a")
    local brr, _, _, bra = s:GetBorderColor()
    eq(brr, 0.45, "GetBorderColor reads back r")
    eq(bra, 1, "GetBorderColor reads back a")
end

print("-- Round: defaults come from the kit palette")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f)
    eq(s.fill._vertex.r, UI.Colors.element.r, "fill defaults to Colors.element")
    eq(s.ring._vertex.r, UI.Colors.border.r, "border defaults to Colors.border")
end

print("-- Round: show, hide and the ring's own switch")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, { border = false })
    eq(s.fill:IsShown(), true, "border=false still draws the fill")
    eq(s.ring:IsShown(), false, "border=false draws no ring at all")

    -- ⚠ A repaint must NOT resurrect a ring the caller said it did not want: a
    -- consumer sweeping every state's colours in one pass would otherwise give a
    -- fill-only surface an edge it never asked for.
    s:SetBorderColor(1, 1, 1, 1)
    eq(s.ring:IsShown(), false, "SetBorderColor does not bring the ring back")
    s:SetBorderShown(true)
    eq(s.ring:IsShown(), true, "SetBorderShown(true) is the way back")

    -- Hide/Show is the whole surface. This is the path a caller switching BACK to
    -- a square backdrop takes -- the textures are ours, so nothing else would
    -- take them down.
    s:Hide()
    eq(s:IsShown(), false, "Hide takes the surface down")
    eq(s.fill:IsShown(), false, "...including the fill")
    eq(s.ring:IsShown(), false, "...and the ring")
    s:Show()
    eq(s.fill:IsShown(), true, "Show brings the fill back")
    eq(s.ring:IsShown(), true, "...and the ring it had when it went down")

    -- ...but a fill-only surface stays fill-only across a Hide/Show round trip.
    local s2 = UI:CreateRoundedSurface(surfaceFrame(), { border = false })
    s2:Hide()
    s2:Show()
    eq(s2.ring:IsShown(), false, "a fill-only surface does not sprout a ring when re-shown")
    eq(s2.fill:IsShown(), true, "...and its fill still comes back")
end

print("-- Round: the not-a-frame guard")
do
    local before = #errors
    check(UI:CreateRoundedSurface({}) == nil, "a bare table is refused")
    check(UI:CreateRoundedSurface(nil) == nil, "nil is refused")
    check(#errors > before, "...and it says so rather than failing silently")
    check(UI:GetRoundedSurface(nil) == nil, "GetRoundedSurface tolerates nil")
    check(UI:GetRoundedSurface(FakeUIFrame(10, 10)) == nil, "...and an unrounded frame")
end

-- ============================================================
-- THE TWO BAKED SHAPES
--
-- The old assembly could round any subset of the four corners, because a square
-- corner was simply an arc it did not draw. One sliced texture cannot: the shape
-- is baked in, so every combination is a FILE, and v1 bakes two -- all four
-- round, and tl+tr for a title strip.
--
-- The corner TABLE keeps its old reading (an absent key is square, a wholly
-- absent table is all four), because that is what every consumer already writes.
-- What is new is that a combination with no art is REFUSED and says so, rather
-- than drawing whatever happened to be nearest.
-- ============================================================

print("-- Round: corners default to all four")
do
    local s = UI:CreateRoundedSurface(surfaceFrame(), { radius = 6 })
    eq(s:GetShape(), "all", "no opts.corners -> the all-four shape")
    eq(s.fill._texture, ROUND .. "rect_r6", "...drawn from the all-four fill art")
    eq(s.ring._texture, ROUND .. "ring_r6_w1", "...and its ring")
    local c = s:GetCorners()
    check(c.tl and c.tr and c.bl and c.br, "GetCorners agrees")
    -- The getter must hand back a COPY: poking the returned table would otherwise
    -- look like a re-shape while nothing re-textured.
    c.tl = false
    check(s:GetCorners().tl, "GetCorners hands back a copy, not the live table")
end

print("-- Round: an absent key means SQUARE, and tl+tr is the strip shape")
do
    -- The one surprising rule in the file, and the one a title strip depends on:
    -- {tl=true, tr=true} has to mean TOP CORNERS ONLY. If an absent key read as
    -- true, that line would silently produce a fully rounded surface.
    local s = UI:CreateRoundedSurface(surfaceFrame(), { radius = 6, corners = { tl = true, tr = true } })
    local c = s:GetCorners()
    check(c.tl and c.tr, "the two named corners are round")
    check(not c.bl and not c.br, "...and the two that were not named are square")
    eq(s:GetShape(), "top", "...which is the top-only shape")
    -- THE POINT OF THE WHOLE SHAPE SPLIT. A strip drawn from the all-four art
    -- would round its lower corners off the panel it is joining.
    eq(s.fill._texture, ROUND .. "rect_top_r6", "...drawn from the top-only fill art")
    eq(s.ring._texture, ROUND .. "ring_top_r6_w1", "...and the top-only ring art")
    eq(#s.textures, 2, "the surface is still two textures")
    -- Margins do not change with the shape: the square bottom is BAKED into the
    -- bottom band of the file, so the bottom margin still has to be the radius or
    -- that band never gets drawn at 1:1.
    eq(s.fill._sliceMargins[4], 6, "the bottom margin is still the radius")
end

print("-- Round: every radius and width has a top-only file too")
do
    for _, r in ipairs({ 4, 6, 8 }) do
        for _, w in ipairs({ 1, 2 }) do
            local s = UI:CreateRoundedSurface(surfaceFrame(),
                                              { radius = r, borderWidth = w, corners = TOP })
            eq(s.fill._texture, ROUND .. "rect_top_r" .. r, "top r" .. r .. ": fill art")
            eq(s.ring._texture, ROUND .. "ring_top_r" .. r .. "_w" .. w,
               "top r" .. r .. " w" .. w .. ": ring art")
        end
    end
end

print("-- Round: a combination with no art is refused, loudly")
do
    -- ☠ THE REGRESSION THIS EXISTS FOR. The old module could draw any subset, so
    -- a consumer written against it may still ask for one -- and the honest answer
    -- is a message naming the generator, not a surface that quietly rounds the
    -- wrong corners or draws nothing at all.
    local combos = {
        { {},                              "all four square" },
        { { tl = true },                   "one corner" },
        { { bl = true, br = true },        "bottom only" },
        { { tl = true, bl = true },        "left only" },
        { { tl = true, tr = true, bl = true }, "three of four" },
    }
    for _, pair in ipairs(combos) do
        local before = #errors
        local s = UI:CreateRoundedSurface(surfaceFrame(), { radius = 6, corners = pair[1] })
        check(#errors > before, pair[2] .. ": refused with a message")
        check(lastError():find("generate_rounded", 1, true) ~= nil,
              pair[2] .. ": ...and the message says where to add the shape")
        -- Refused, but still a usable surface: an addon that returned nil here
        -- would turn a cosmetic miss into a nil-index error at the call site.
        check(s ~= nil, pair[2] .. ": a handle still comes back")
        eq(s:GetShape(), "all", pair[2] .. ": ...falling back to all four")
        local c = s:GetCorners()
        check(c.tl and c.tr and c.bl and c.br,
              pair[2] .. ": ...and GetCorners reports what it actually drew")
    end
end

print("-- Round: SetCorners re-shapes in place")
do
    local s = UI:CreateRoundedSurface(surfaceFrame(), { radius = 6 })
    s:SetCorners(TOP)
    eq(s:GetShape(), "top", "SetCorners swaps to the strip shape")
    eq(s.fill._texture, ROUND .. "rect_top_r6", "...and re-points the fill art")
    eq(s.ring._texture, ROUND .. "ring_top_r6_w1", "...and the ring art")
    eq(#s.textures, 2, "SetCorners creates nothing")

    -- ...and back. A strip whose corners could only be turned OFF would trap the
    -- demo's Square restore.
    s:SetCorners(ALL)
    eq(s:GetShape(), "all", "and back to all four")
    eq(s.fill._texture, ROUND .. "rect_r6", "...with the all-four art again")

    -- SetCorners takes the same refusal path as the factory.
    local before = #errors
    s:SetCorners({ br = true })
    check(#errors > before, "SetCorners refuses an unbaked combination too")
    eq(s:GetShape(), "all", "...and leaves a drawable shape behind")
end

print("-- Round: the shape survives a hide/show round trip")
do
    -- The demo cycles Square -> R4 -> R6 -> R8 by HIDING the surface and re-showing
    -- it, so a Show that re-derived the shape from scratch could bring a title
    -- strip back fully rounded.
    local s = UI:CreateRoundedSurface(surfaceFrame(), { radius = 6, corners = TOP })
    s:Hide()
    eq(s.fill:IsShown(), false, "Hide takes the strip down")
    s:Show()
    eq(s.fill:IsShown(), true, "Show brings it back")
    eq(s:GetShape(), "top", "...still the top-only shape")
    eq(s.fill._texture, ROUND .. "rect_top_r6", "...and still the top-only art")
end

-- ============================================================
-- TWO SURFACES ON ONE FRAME -- the title strip's other requirement.
--
-- The strip has to draw ABOVE the panel's fill and BELOW the panel's ring, and a
-- texture is only below that ring if it is on the SAME frame (a child frame's
-- regions draw above every layer of its parent). So one frame carries two
-- surfaces, told apart by the sublevel they sit at -- which is also what forces
-- them to differ, since two surfaces sharing a sublevel would have no defined
-- order and the order is the entire point.
-- ============================================================
print("-- Round: a second surface at another sublevel")
do
    local f = surfaceFrame()
    local bar = FakeUIFrame(200, 20, 0, 0)
    local panel = UI:CreateRoundedSurface(f, { radius = 6 })
    local strip = UI:CreateRoundedSurface(f, {
        radius = 6, sublevel = -3, border = false,
        corners = TOP, anchorTo = bar,
    })
    check(panel ~= strip, "a different sublevel is a different surface")
    eq(#f._textures, 4, "...with its own pair of textures")
    eq(UI:GetRoundedSurface(f), panel, "the default lookup still finds the panel")
    eq(UI:GetRoundedSurface(f, -3), strip, "...and the sublevel names the strip")

    -- THE STACK, which is the whole reason the option exists.
    eq(strip.fill._sublevel, -3, "the strip's fill sits above the panel's -4...")
    eq(panel.ring._sublevel, -2, "...and below the panel's ring at -2")
    check(panel.fill._sublevel < strip.fill._sublevel,
          "panel fill, then strip fill, then ring")
    check(strip.fill._sublevel < panel.ring._sublevel,
          "the strip cannot cover the ring")

    -- Re-issuing at the same sublevel is still idempotent -- the demo's cycle
    -- button re-calls the factory on every click.
    UI:CreateRoundedSurface(f, { radius = 8, sublevel = -3, anchorTo = bar })
    eq(#f._textures, 4, "re-issuing the strip creates nothing")
    eq(strip:GetRadius(), 8, "...and takes the new radius")
    eq(strip:GetShape(), "top", "...while keeping the shape it already had")
    eq(strip.fill._texture, ROUND .. "rect_top_r8", "...at the new radius's art")
end

print("-- Round: anchorTo stretches over another rect")
do
    -- The strip's textures belong to the panel FRAME but its geometry belongs to
    -- the title BAR. A surface stretched over its own frame would cover the whole
    -- panel in strip colour.
    local f = surfaceFrame()
    local bar = FakeUIFrame(200, 20, 0, 0)
    local s = UI:CreateRoundedSurface(f, { radius = 6, corners = TOP, anchorTo = bar })
    eq(s.frame, f, "the textures still live on the frame")
    eq(s.fill._allPoints, bar, "the fill covers the BAR, not the frame")
    eq(s.ring._allPoints, bar, "...and so does the ring")
end

-- ============================================================
-- NO SLICE SUPPORT -- the degrade path.
--
-- SetTextureSliceMargins arrived around 10.0. On anything older -- and in any
-- harness whose texture stub does not carry it -- there is no way to draw the
-- art, so the surface becomes a plain SetColorTexture rectangle with NO ring and
-- flags itself. Visibly square on purpose: a degraded surface that still LOOKED
-- rounded would hide the fact that the art is not drawing at all.
--
-- ⚠ Reaching this headlessly needs the method taken AWAY, and the frame stub's
-- __index answers any unset key with a truthy no-op function -- so the only way
-- to make the probe see "absent" is to rawset a non-function over it, which is
-- exactly what this stub does.
-- ============================================================
print("-- Round: a client with no nine-slice degrades to a square fill")
do
    local f = surfaceFrame()
    local realCreate = f.CreateTexture
    f.CreateTexture = function(self, name, layer, template, sublevel)
        local t = realCreate(self, name, layer, template, sublevel)
        rawset(t, "SetTextureSliceMargins", false)
        rawset(t, "SetTextureSliceMode", false)
        return t
    end

    local before = #errors
    local s = UI:CreateRoundedSurface(f, { radius = 6, fill = { 0.1, 0.2, 0.3, 0.4 } })
    check(s ~= nil, "a handle still comes back")
    eq(s.sliced, false, "...flagged as unsliced")
    -- Said once per session, not once per surface: a client without slice support
    -- has EVERY surface fall back, and two hundred identical lines would bury
    -- whatever else went wrong.
    check(#errors > before, "...and the library says so, once")
    local after = #errors
    UI:CreateRoundedSurface(surfaceFrame(), { radius = 6 })
    eq(#errors, after, "a later surface does not repeat the warning")

    -- No art, so no tint -- the fill becomes a flat colour quad instead.
    -- rawget, for the __index reason above: an unset `_texture` answers a truthy
    -- no-op function, so a plain `== nil` here would pass whatever happened.
    check(rawget(s.fill, "_texture") == nil, "no fill art is pointed at")
    local c = s.fill._color
    check(c and c.r == 0.1 and c.a == 0.4, "the fill is a plain colour texture")
    check(rawget(s.fill, "_sliceMargins") == nil, "no margins were attempted")
    eq(s.ring:IsShown(), false, "and there is no ring at all")

    -- The handle still works: a consumer's hover path must not error just because
    -- the client is old.
    s:SetFillColor(1, 0, 0, 1)
    eq(s.fill._color.r, 1, "SetFillColor still repaints the flat fill")
    s:SetBorderShown(true)
    eq(s.ring:IsShown(), false, "SetBorderShown cannot conjure a ring it cannot draw")
    s:Hide()
    eq(s.fill:IsShown(), false, "Hide still works")
    s:Show()
    eq(s.fill:IsShown(), true, "...and Show")
end

print("-- Round: the published constants match the art on disk")
do
    -- The demo cycles UI.Round.radii rather than carrying its own copy, so a
    -- radius listed here with no generated file would be an invisible surface in
    -- the workbench with nothing to explain it.
    eq(#UI.Round.radii, 3, "three radii are published")
    eq(UI.Round.radii[1], 4, "4")
    eq(UI.Round.radii[3], 8, "8")
    eq(UI.Round.defaultRadius, 6, "the default is one of them")
    eq(#UI.Round.widths, 2, "two border widths")
    eq(#UI.Round.shapes, 2, "two baked shapes")
    eq(UI.Round.shapes[1], "all", "all four round")
    eq(UI.Round.shapes[2], "top", "...and top-only")
end

-- ============================================================
-- RING ONLY -- opts.fill = false
--
-- A surface laid OVER something that has to stay visible (the popout shell's
-- source outline, traced round a row plate that is already painted) must draw no
-- interior at all. "A fill at alpha zero" looks the same and is not the same: it
-- is still a texture in the stack, and one SetFillColor from a caller repainting
-- every state's colours in one sweep away from covering the thing it outlines.
-- ============================================================
print("-- Round: a ring-only surface draws no interior")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, { radius = 8, fill = false,
                                           border = { 1, 0, 0, 1 } })
    eq(s.hasFill, false, "the surface is flagged fill-less")
    eq(s.fill:IsShown(), false, "the fill texture is down")
    eq(s.ring:IsShown(), true, "...and the ring is up, which is the whole point")

    -- The colour path still works, it is just not DRAWN -- so a caller that
    -- repaints every state's colours in one sweep cannot resurrect the fill.
    s:SetFillColor(1, 1, 1, 1)
    eq(s.fill:IsShown(), false, "SetFillColor does not bring it back")

    -- ...and a Hide/Show round trip must not either, for the same reason a
    -- fill-only surface's ring must stay down through one.
    s:Hide(); s:Show()
    eq(s.fill:IsShown(), false, "a hide/show round trip does not bring it back")
    eq(s.ring:IsShown(), true, "and the ring survives it")

    s:SetFillShown(true)
    eq(s.fill:IsShown(), true, "SetFillShown is the one thing that does")
end

print("-- Round: a fill-only and a ring-only surface are mirror images")
do
    local fillOnly = UI:CreateRoundedSurface(surfaceFrame(), { radius = 8, border = false })
    eq(fillOnly.hasFill, true, "fill-only: interior drawn")
    eq(fillOnly.ring:IsShown(), false, "fill-only: no ring")
    local ringOnly = UI:CreateRoundedSurface(surfaceFrame(), { radius = 8, fill = false })
    eq(ringOnly.hasBorder, true, "ring-only: ring drawn")
    eq(ringOnly.fill:IsShown(), false, "ring-only: no interior")
end

-- ============================================================
-- THE CHROME MOVES
--
-- Three helpers that exist because each of the three reads as a one-liner and
-- was got wrong at least once during the in-game trial: the square backdrop that
-- does not come down on its own, the title strip that paints over the corners it
-- is supposed to follow, and the cross standing in the corner box.
-- ============================================================
print("-- Round: ApplyRoundedChrome takes the square backdrop down first")
do
    local f = surfaceFrame()
    local cleared = false
    f.SetBackdrop = function(_, v) cleared = (v == nil) end
    local s = UI:ApplyRoundedChrome(f, { radius = 8, borderWidth = 2 })
    check(s ~= nil, "a surface comes back")
    -- ☠ THIS IS THE TRAP THE HELPER EXISTS FOR: the rounded fill sits at a
    -- NEGATIVE BACKGROUND sublevel, UNDER a backdrop's bgFile at 0, so a frame
    -- that keeps its backdrop renders the SQUARE in front of a rounded surface
    -- that is drawing perfectly.
    check(cleared, "the backdrop was cleared")
    check(rawget(f, "_pxHidden") == true, "...and the pixel border taken down with it")
    eq(s:GetRadius(), 8, "at the radius asked for")

    UI:RemoveRoundedChrome(f)
    eq(s:IsShown(), false, "RemoveRoundedChrome hides it")
    -- HIDDEN, not discarded: the textures are ours and nothing else takes them
    -- down, so the same handle comes back on the next apply.
    local again = UI:ApplyRoundedChrome(f, { radius = 8, borderWidth = 2 })
    check(again == s, "...and the next apply re-uses the same surface")
end

print("-- Round: RemoveRoundedChrome on a frame that never had one is a no-op")
do
    local f = surfaceFrame()
    UI:RemoveRoundedChrome(f)
    UI:RemoveRoundedStrip(f)
    check(UI:GetRoundedSurface(f) == nil, "nothing was created by asking it to go away")
end

print("-- Round: the title strip is a top-corners surface at its own sublevel")
do
    local f = surfaceFrame()
    local bar = FakeUIFrame(200, 26, 0, 0)
    UI:ApplyRoundedChrome(f, { radius = 8, borderWidth = 2 })
    local strip = UI:ApplyRoundedStrip(f, bar, 8, { 0.12, 0.12, 0.12, 0.9 })
    check(strip ~= nil, "a strip comes back")
    eq(strip:GetShape(), "top", "with only its top corners round")
    eq(strip.hasBorder, false, "and no ring of its own -- it is a fill, not an outlined thing")
    -- ☠ IT HAS TO INTERLEAVE. Panel fill at -4, strip at -3, panel ring at -2:
    -- above the fill so it reads as a raised band, BELOW the ring or it eats the
    -- border along the top exactly the way a square texture did.
    eq(strip.sublevel, UI.RoundStripSublevel, "at the strip sublevel")
    check(strip.sublevel > UI:GetRoundedSurface(f).sublevel,
          "...which is ABOVE the panel's fill")
    check(strip ~= UI:GetRoundedSurface(f), "so the two are different surfaces on one frame")
    -- WHOSE TEXTURES and WHOSE RECT are two questions: the textures are the
    -- panel's (only there can they land under its ring) and the rect is the bar's.
    eq(strip.anchorTo, bar, "stretched over the BAR, while living on the panel")

    UI:RemoveRoundedStrip(f)
    eq(strip:IsShown(), false, "RemoveRoundedStrip takes it down")
    check(UI:GetRoundedSurface(f):IsShown(), "...and leaves the panel alone")
end

print("-- Round: the corner inset is half the radius, rounded")
do
    eq(UI.SurfaceEdgeInset(nil), 0, "no radius, no inset")
    eq(UI.SurfaceEdgeInset(4), 2, "r4 -> 2")
    eq(UI.SurfaceEdgeInset(6), 3, "r6 -> 3")
    eq(UI.SurfaceEdgeInset(8), 4, "r8 -> 4")
end

print("-- Round: InsetTitleButton remembers the ORIGINAL offset, once")
do
    local parent = FakeUIFrame(200, 26, 0, 0)
    local btn = FakeUIFrame(18, 18)
    -- Underscore fields must read nil on this one: the helper tests
    -- `_dfSquareX == nil` to decide whether it has already remembered.
    setmetatable(btn, { __index = function(_, k)
        if type(k) == "string" and k:byte(1) == 95 then return nil end
        return function() end
    end })
    btn:SetPoint("RIGHT", parent, "RIGHT", -6, 0)

    local function anchorX()
        local pt = btn._points[#btn._points]
        return pt and pt[4]
    end

    UI:InsetTitleButton(btn, 4)
    eq(anchorX(), -6 - 2, "r4: inboard by half the radius")
    -- ☠ SHIFTED FROM THE ORIGINAL EACH TIME, NEVER COMPOUNDED. A second radius
    -- measured from the last shift walks the button across the bar -- slowly
    -- enough that three presses look fine and ten do not.
    UI:InsetTitleButton(btn, 8)
    eq(anchorX(), -6 - 4, "r8: still measured from the original")
    UI:InsetTitleButton(btn, nil)
    eq(anchorX(), -6, "square: exactly the offset it started on")
    eq(btn:GetNumPoints(), 1, "...and one anchor, not a stack of them")
end

print("-- Round: InsetTitleButton refuses a button it cannot read back")
do
    -- GetPoint always answers the 5-value shape in-game, so this is really a
    -- guard against being handed something anchored another way -- and refusing
    -- is right, because re-issuing a point from values that do not mean what this
    -- thinks they mean would MOVE the button somewhere arbitrary.
    local unanchored = FakeUIFrame(18, 18)
    UI:InsetTitleButton(unanchored, 8)      -- must not error
    check(true, "an unanchored button is left alone rather than moved")
    UI:InsetTitleButton(nil, 8)
    UI:InsetTitleButton("not a frame", 8)
    check(true, "...and a non-frame is refused rather than indexed")
end

-- ============================================================
-- THE SURFACE STYLE -- Theme.lua's token and its host opt-in.
--
-- ☠ THE TOKEN ROUNDS NOTHING ON ITS OWN, and that is the whole design: two
-- addons share one copy of this kit and only one of them is round. Declaring the
-- style is a HOST act, and a host that never declares one is square -- which is
-- what keeps DandersMover square while the settings shell is not.
-- ============================================================
print("-- Round: the surface-style token")
do
    local TOKEN = UI.SurfaceStyle
    check(TOKEN ~= nil, "Theme.lua publishes one")
    eq(TOKEN.style, "rounded", "the shell's style is rounded")
    eq(TOKEN.radius, 8, "at R8 -- what the in-game trial settled on")
    -- TWO WIDTHS, ONE TOKEN. The popout takes borderWidth and the row takes
    -- rowBorderWidth, so a consumer hands the same table to every shell and each
    -- picks its own -- rather than two near-identical tables at the call sites.
    eq(TOKEN.borderWidth, 2, "panels take two units")
    eq(TOKEN.rowBorderWidth, 1, "row plates take one")
    -- Both have to be art that exists, or the surface is invisible.
    local hasR, hasW = false, false
    for _, r in ipairs(UI.Round.radii) do if r == TOKEN.radius then hasR = true end end
    for _, w in ipairs(UI.Round.widths) do if w == TOKEN.borderWidth then hasW = true end end
    check(hasR, "the radius is one the generator baked")
    check(hasW, "...and so is the border width")
end

print("-- Round: the host opt-in, and what it means to decline it")
do
    local host = setmetatable({}, { __index = UI })
    check(host:GetSurfaceStyle() == nil, "a fresh host has declared nothing")
    -- ☠ AND THAT MUST NOT FALL THROUGH TO THE TOKEN. The host's __index IS the
    -- library, so a plain field read would find UI.SurfaceStyle and round every
    -- consumer in the game; the opt-in is stored under a private name the library
    -- itself never sets, and read with rawget.
    check(UI.ResolveSurfaceStyle(host, nil) == nil,
          "so it resolves to SQUARE, which is what DandersMover gets")

    host:SetSurfaceStyle(UI.SurfaceStyle)
    eq(host:GetSurfaceStyle(), UI.SurfaceStyle, "after opting in it declares the token")
    eq(UI.ResolveSurfaceStyle(host, nil), UI.SurfaceStyle, "and an absent opt takes it")

    -- false is the OVERRIDE, and it is the only way to be square on a round host
    -- -- which is exactly what the chrome workbench needs to hold its baseline.
    check(UI.ResolveSurfaceStyle(host, false) == nil, "false forces square")
    local own = { style = "rounded", radius = 4, borderWidth = 1 }
    eq(UI.ResolveSurfaceStyle(host, own), own, "an explicit table wins over the host's")

    -- The `style` field is there so a second style can be added without every
    -- reader growing a branch. Until then anything that is not "rounded" is square.
    check(UI.ResolveSurfaceStyle(host, { style = "square", radius = 8 }) == nil,
          "an unknown style is square rather than a guess")

    host:SetSurfaceStyle(nil)
    check(host:GetSurfaceStyle() == nil, "and it can be taken back off")
end
