local NS = ...

-- ============================================================
-- ROUNDED SURFACE -- DandersUI/Round.lua
-- ------------------------------------------------------------
-- A rounded surface is 15 textures pretending to be one shape, and every way it
-- can be wrong is invisible from inside the game until you look at it:
--
--   * an arc pointing the wrong way (one baked orientation serves four corners,
--     turned with SetTexCoord's 8-argument form -- so three of the four are only
--     as right as eight numbers in a table)
--   * a ring drawn UNDER its own fill (both live on BACKGROUND sublevels)
--   * a strip anchored so it overlaps or falls short of the corner box it butts
--     against, which is a seam at some frame widths and not at others
--   * a repaint that misses some of the 7 fill or 8 border textures, so a hover
--     leaves part of the plate in the previous colour
--
-- All four are questions about recorded calls, which is what this file asserts.
-- What it CANNOT answer is the only question the prototype exists for -- whether
-- the curve reads crisp at a real UI scale -- so nothing here is a substitute
-- for opening the demo.
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
-- Recorded rather than silenced: the factory's "that is not a frame" guard is
-- asserted below and has to be observable.
local errors = {}
if not UI.Error then
    function UI:Error(msg) errors[#errors + 1] = tostring(msg) end
end

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
    -- axis in the layout shows up as an obviously wrong anchor rather than as a
    -- square that happens to still look square.
    return FakeUIFrame(200, 40, 0, 0)
end

-- The first SetPoint recorded for a texture, as point/relPoint/x/y. Every
-- texture in the surface is ClearAllPoints'd then re-pointed, so #_points is
-- also an assertion: 1 for a sized corner, 2 for a stretched strip.
local function pt(tex, i)
    local p = tex._points[i]
    if not p then return nil end
    return p[1], p[3], p[4], p[5]
end

print("-- Round: assembly")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, { radius = 6 })
    check(s ~= nil, "factory returns a handle")
    eq(#f._textures, 15, "15 textures: 4 corner fills + 3 fill rects + 4 arcs + 4 strips")
    eq(#s.textures, 15, "the handle knows all 15")
    eq(#s.borderTextures, 8, "8 of them are the ring")
    eq(s:GetRadius(), 6, "radius as asked")
    local _, w = s:GetRadius()
    eq(w, 1, "border width defaults to 1")

    -- The surface is idempotent per frame: a second call re-uses rather than
    -- stacking a second set of 15 on top, which would double every colour's
    -- alpha and look like a tinting bug.
    UI:CreateRoundedSurface(f, { radius = 8 })
    eq(#f._textures, 15, "a second call on the same frame creates nothing new")
    eq(UI:GetRoundedSurface(f), s, "...and hands back the same handle")
    eq(s:GetRadius(), 8, "...re-issued with the new radius")
end

print("-- Round: draw order")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, { radius = 6 })
    local fills, rings = 0, 0
    for _, t in ipairs(s.textures) do
        eq(t._layer, "BACKGROUND", "every texture is on BACKGROUND")
    end
    for i = 1, 7 do
        if s.textures[i]._sublevel == -4 then fills = fills + 1 end
    end
    for i = 8, 15 do
        if s.textures[i]._sublevel == -2 then rings = rings + 1 end
    end
    eq(fills, 7, "the 7 fill textures sit at sublevel -4")
    eq(rings, 8, "the 8 ring textures sit at sublevel -2, ABOVE the fills")
    -- Both negative, so a square backdrop left on the frame (bgFile lands at
    -- sublevel 0) would paint over the whole surface. That is deliberate: it
    -- makes a forgotten SetBackdrop(nil) look like nothing happened rather than
    -- like the corners half-working.
    check(s.textures[1]._sublevel < 0 and s.textures[15]._sublevel < 0,
          "both sublevels are below a backdrop's bgFile")
end

print("-- Round: corner orientation")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, { radius = 6 })

    -- The baked file is the TOP-LEFT corner, so tl is the identity mapping and
    -- the other three are mirrors of it.
    local want = {
        tl = { 0, 0, 0, 1, 1, 0, 1, 1 },
        tr = { 1, 0, 1, 1, 0, 0, 0, 1 },
        bl = { 0, 1, 0, 0, 1, 1, 1, 0 },
        br = { 1, 1, 1, 0, 0, 1, 0, 0 },
    }
    for _, k in ipairs({ "tl", "tr", "bl", "br" }) do
        for _, set in ipairs({ s.cornerFill, s.cornerEdge }) do
            local tc = set[k]._texCoord
            eq(tc and #tc, 8, k .. ": the 8-argument SetTexCoord form was used")
            local ok = true
            for i = 1, 8 do if tc[i] ~= want[k][i] then ok = false end end
            check(ok, k .. ": texcoords face the right corner")
        end
    end

    -- Every corner is a DISTINCT turn. A copy-paste that left two corners sharing
    -- one mapping would still pass the per-corner check above if the table were
    -- wrong in the same way twice.
    local seen = {}
    for _, k in ipairs({ "tl", "tr", "bl", "br" }) do
        local tc = s.cornerFill[k]._texCoord
        local key = table.concat(tc, ",")
        check(not seen[key], k .. ": its turn is unique")
        seen[key] = true
    end
end

print("-- Round: art per radius and width")
do
    for _, r in ipairs({ 4, 6, 8 }) do
        for _, w in ipairs({ 1, 2 }) do
            local f = surfaceFrame()
            local s = UI:CreateRoundedSurface(f, { radius = r, borderWidth = w })
            eq(s.cornerFill.tl._texture, ROUND .. "corner_fill_r" .. r,
               "r" .. r .. ": fill art")
            eq(s.cornerEdge.br._texture, ROUND .. "corner_edge_r" .. r .. "_w" .. w,
               "r" .. r .. " w" .. w .. ": arc art")
            eq(#f._textures, 15, "r" .. r .. ": the count does not move with the radius")
        end
    end

    -- SetRadius is a REBUILD of the same textures, never a new set -- that is
    -- what makes a demo's cycle button cheap enough to drive on every click.
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, { radius = 4, borderWidth = 1 })
    s:SetRadius(8, 2)
    eq(#f._textures, 15, "SetRadius creates nothing")
    eq(s.cornerFill.tl._texture, ROUND .. "corner_fill_r8", "SetRadius re-points the fill art")
    eq(s.cornerEdge.tl._texture, ROUND .. "corner_edge_r8_w2", "SetRadius re-points the arc art")
    eq(s.cornerFill.tl._w, 8, "...and re-sizes the corner box")
end

print("-- Round: unsupported radius snaps to the nearest that has art")
do
    local f = surfaceFrame()
    -- Not a clamp: 5 is nearer 4 than 6, so it must land on 4 rather than on the
    -- bottom of the range or on the default. A radius with no file is an
    -- INVISIBLE corner, which is why this cannot be left to the caller.
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

print("-- Round: geometry")
do
    local f = surfaceFrame()
    local R, BW = 6, 2
    local s = UI:CreateRoundedSurface(f, { radius = R, borderWidth = BW })

    -- Corner boxes: R x R, one anchor each, hung off the matching frame corner.
    local corners = { tl = "TOPLEFT", tr = "TOPRIGHT", bl = "BOTTOMLEFT", br = "BOTTOMRIGHT" }
    for k, point in pairs(corners) do
        for _, set in ipairs({ s.cornerFill, s.cornerEdge }) do
            local t = set[k]
            eq(#t._points, 1, k .. ": one anchor")
            local p, rel, x, y = pt(t, 1)
            eq(p, point, k .. ": anchored by its own " .. point)
            eq(rel, point, k .. ": ...to the frame's " .. point)
            eq(x, 0, k .. ": flush in x")
            eq(y, 0, k .. ": flush in y")
            eq(t._w, R, k .. ": R wide")
            eq(t._h, R, k .. ": R tall")
        end
    end

    -- THE TILING. Top strip and bottom strip run BETWEEN the corner boxes; the
    -- centre band runs the full width, inset R top and bottom. Every number is a
    -- constant offset from the frame, so nothing here can round badly.
    local _, _, tx = pt(s.fillTop, 1)
    eq(tx, R, "top strip starts R in from the left")
    local _, _, tx2 = pt(s.fillTop, 2)
    eq(tx2, -R, "top strip stops R short of the right")
    eq(s.fillTop._h, R, "top strip is R tall -- exactly the corner box")

    local p1, r1, x1, y1 = pt(s.fillMid, 1)
    eq(p1, "TOPLEFT", "centre band hangs off TOPLEFT")
    eq(x1, 0, "centre band runs the FULL width...")
    eq(y1, -R, "...and starts where the corner boxes stop")
    local p2, r2, x2, y2 = pt(s.fillMid, 2)
    eq(p2, "BOTTOMRIGHT", "centre band stretches to BOTTOMRIGHT")
    eq(x2, 0, "centre band: full width at the bottom too")
    eq(y2, R, "centre band stops R above the bottom")

    local bp, br_, bx, by = pt(s.fillBottom, 1)
    eq(bp, "BOTTOMLEFT", "bottom strip hangs off BOTTOMLEFT")
    eq(bx, R, "bottom strip starts R in")
    eq(s.fillBottom._h, R, "bottom strip is R tall")

    -- The ring's straight runs: same spans, thickness BW. A strip that ran the
    -- full width would double up over the arc and read as a heavier corner.
    eq(s.borderTop._h, BW, "top border is BW thick")
    eq(s.borderBottom._h, BW, "bottom border is BW thick")
    eq(s.borderLeft._w, BW, "left border is BW thick")
    eq(s.borderRight._w, BW, "right border is BW thick")
    local _, _, btx = pt(s.borderTop, 1)
    eq(btx, R, "top border starts where the top-left arc stops")
    local _, _, _, bly = pt(s.borderLeft, 1)
    eq(bly, -R, "left border starts where the top-left arc stops")
end

print("-- Round: repaint")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, {
        fill   = { 0.1, 0.2, 0.3, 0.4 },
        border = { r = 0.5, g = 0.6, b = 0.7, a = 0.8 },
    })

    -- Both colour shapes the rest of the kit accepts -- {r,g,b,a} and the array
    -- form -- have to land the same way, because the two are used side by side
    -- across the consumers.
    local function fillIs(r, g, b, a, why)
        for _, t in ipairs({ s.fillTop, s.fillMid, s.fillBottom }) do
            local c = t._color
            check(c and c.r == r and c.g == g and c.b == b and c.a == a, why .. " (flat)")
        end
        for _, k in ipairs({ "tl", "tr", "bl", "br" }) do
            local v = s.cornerFill[k]._vertex
            check(v and v.r == r and v.g == g and v.b == b and v.a == a, why .. " (" .. k .. ")")
        end
    end
    local function borderIs(r, g, b, a, why)
        for _, t in ipairs({ s.borderTop, s.borderBottom, s.borderLeft, s.borderRight }) do
            local c = t._color
            check(c and c.r == r and c.g == g and c.b == b and c.a == a, why .. " (flat)")
        end
        for _, k in ipairs({ "tl", "tr", "bl", "br" }) do
            local v = s.cornerEdge[k]._vertex
            check(v and v.r == r and v.g == g and v.b == b and v.a == a, why .. " (" .. k .. ")")
        end
    end

    fillIs(0.1, 0.2, 0.3, 0.4, "array-form fill reaches all 7")
    borderIs(0.5, 0.6, 0.7, 0.8, "table-form border reaches all 8")

    -- THE HOVER PATH. A plate lighting up under the cursor drives SetFillColor on
    -- every OnEnter and OnLeave; anything it misses is a corner stuck in the
    -- previous colour while the middle of the plate has moved on.
    s:SetFillColor(1, 0, 0, 0.5)
    fillIs(1, 0, 0, 0.5, "SetFillColor repaints every fill texture")
    borderIs(0.5, 0.6, 0.7, 0.8, "...and leaves the ring alone")

    s:SetBorderColor(0, 1, 0, 1)
    borderIs(0, 1, 0, 1, "SetBorderColor repaints every ring texture")
    fillIs(1, 0, 0, 0.5, "...and leaves the fill alone")

    -- The accent path takes a colour TABLE (that is what GetAccent hands back),
    -- so the setters accept one in place of four numbers.
    s:SetBorderColor({ r = 0.45, g = 0.45, b = 0.95, a = 1 })
    borderIs(0.45, 0.45, 0.95, 1, "a colour table works in place of four numbers")

    local fr, fg, fb, fa = s:GetFillColor()
    eq(fr, 1, "GetFillColor reads back r")
    eq(fa, 0.5, "GetFillColor reads back a")
end

print("-- Round: defaults come from the kit palette")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f)
    local c = s.fillMid._color
    eq(c.r, UI.Colors.element.r, "fill defaults to Colors.element")
    local b = s.borderTop._color
    eq(b.r, UI.Colors.border.r, "border defaults to Colors.border")
end

print("-- Round: show, hide and the ring's own switch")
do
    local f = surfaceFrame()
    local s = UI:CreateRoundedSurface(f, { border = false })
    local shownFills, shownRing = 0, 0
    for i = 1, 7 do if s.textures[i]:IsShown() then shownFills = shownFills + 1 end end
    for i = 8, 15 do if s.textures[i]:IsShown() then shownRing = shownRing + 1 end end
    eq(shownFills, 7, "border=false still draws the fill")
    eq(shownRing, 0, "border=false draws no ring at all")

    -- ⚠ A repaint must NOT resurrect a ring the caller said it did not want: a
    -- consumer sweeping every state's colours in one pass would otherwise give a
    -- fill-only surface an edge it never asked for.
    s:SetBorderColor(1, 1, 1, 1)
    eq(s.borderTop:IsShown(), false, "SetBorderColor does not bring the ring back")
    s:SetBorderShown(true)
    eq(s.borderTop:IsShown(), true, "SetBorderShown(true) is the way back")

    -- Hide/Show is the whole surface. This is the path a caller switching BACK to
    -- a square backdrop takes -- the textures are ours, so nothing else would
    -- take them down.
    s:Hide()
    eq(s:IsShown(), false, "Hide takes the surface down")
    eq(s.fillMid:IsShown(), false, "...including the fill")
    eq(s.borderTop:IsShown(), false, "...and the ring")
    s:Show()
    eq(s.fillMid:IsShown(), true, "Show brings the fill back")
    eq(s.borderTop:IsShown(), true, "...and the ring it had when it went down")

    -- ...but a fill-only surface stays fill-only across a Hide/Show round trip.
    local s2 = UI:CreateRoundedSurface(surfaceFrame(), { border = false })
    s2:Hide()
    s2:Show()
    eq(s2.borderTop:IsShown(), false, "a fill-only surface does not sprout a ring when re-shown")
    eq(s2.fillMid:IsShown(), true, "...and its fill still comes back")
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

print("-- Round: the published constants match the art on disk")
do
    -- The demo cycles UI.Round.radii rather than carrying its own copy, so a
    -- radius listed here with no generated file would be an invisible corner in
    -- the workbench with nothing to explain it.
    eq(#UI.Round.radii, 3, "three radii are published")
    eq(UI.Round.radii[1], 4, "4")
    eq(UI.Round.radii[3], 8, "8")
    eq(UI.Round.defaultRadius, 6, "the default is one of them")
    eq(#UI.Round.widths, 2, "two border widths")
end
