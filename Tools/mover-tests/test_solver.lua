local NS = ...
local S = NS.Solver

-- point <-> center
do
    local cx, cy = S.PointToCenter("TOPLEFT", -100, 50, 20, 10)
    eq(cx, -90, "TOPLEFT -> center x"); eq(cy, 45, "TOPLEFT -> center y")
    local x, y = S.CenterToPoint("BOTTOMRIGHT", 0, 0, 20, 10)
    eq(x, 10, "center -> BOTTOMRIGHT x"); eq(y, -5, "center -> BOTTOMRIGHT y")
    local x2, y2 = S.CenterToPoint("CENTER", 7, 8, 20, 10)
    eq(x2, 7, "CENTER passthrough x"); eq(y2, 8, "CENTER passthrough y")
end

-- grid
do
    local x, y = S.SnapToGrid(23, -47, 20)
    eq(x, 20, "grid x"); eq(y, -40, "grid y")
    local x2 = S.SnapToGrid(30, 0, 20)
    eq(x2, 40, "halfway rounds up")
end

-- screen snap: edges and centre lines
do
    local cx, cy, sx, sy, lx, ly = S.SnapToScreen({ x = -946, y = 3, w = 20, h = 10 }, 1920, 1080, 8)
    eq(cx, -950, "left edge snapped"); check(sx, "x snapped")
    eq(cy, 0, "centre line snapped"); check(sy, "y snapped")
    eq(lx, -960, "x line is the left screen edge"); eq(ly, 0, "y line is the screen centre")
    local cx2, _, sx2, sy2, lx2, ly2 = S.SnapToScreen({ x = 300, y = 300, w = 20, h = 10 }, 1920, 1080, 8)
    eq(cx2, 300, "far from edges untouched"); check(not sx2, "x not snapped")
    check(lx2 == nil and ly2 == nil and not sy2, "no lines when nothing snapped")
    -- right edge to the right screen edge, y untouched: only lineX reported
    local cx3, cy3, sx3, sy3, lx3, ly3 = S.SnapToScreen({ x = 947, y = 300, w = 20, h = 10 }, 1920, 1080, 8)
    eq(cx3, 950, "right edge snapped"); check(sx3 and not sy3, "only x snapped")
    eq(lx3, 960, "x line is the right screen edge"); check(ly3 == nil, "no y line")
end

-- resolve
do
    local parent = { x = 0, y = 0, w = 100, h = 40 }
    local cx, cy = S.Resolve({ edge = "right", align = "start" }, 20, 10, parent, 2)
    eq(cx, 62, "right edge x"); eq(cy, 15, "start align on right = top")
    cx, cy = S.Resolve({ edge = "bottom", align = "end", offsetX = 3, offsetY = -4 }, 20, 10, parent, 2)
    eq(cx, 43, "bottom/end x + offset"); eq(cy, -31, "bottom y + offset")
    cx, cy = S.Resolve({ edge = "left", align = "center" }, 20, 10, parent, 2)
    eq(cx, -62, "left x"); eq(cy, 0, "center align y")
    check(S.Resolve({ edge = "top", align = "center" }, 20, 10, nil, 2) == nil, "nil parent -> nil")
    check(S.Resolve({ edge = "top", align = "center" }, 20, 10, { x = 0, y = 0, w = 0, h = 40 }, 2) == nil, "zero-size parent -> nil")
end

-- point mode
do
    local parent = { x = 0, y = 0, w = 100, h = 40 }
    local function pt(point, relPoint, ox, oy)
        return S.Resolve({ mode = "point", point = point, relPoint = relPoint, offsetX = ox, offsetY = oy }, 20, 10, parent, 2)
    end
    local cx, cy = pt("TOPLEFT", "TOPRIGHT")
    eq(cx, 60, "TOPLEFT on TOPRIGHT x"); eq(cy, 15, "TOPLEFT on TOPRIGHT y")
    cx, cy = pt("CENTER", "CENTER")
    eq(cx, 0, "CENTER on CENTER x"); eq(cy, 0, "CENTER on CENTER y")
    cx, cy = pt("BOTTOMRIGHT", "BOTTOMLEFT", 5, -3)
    eq(cx, -55, "BOTTOMRIGHT on BOTTOMLEFT x + offset"); eq(cy, -18, "BOTTOMRIGHT on BOTTOMLEFT y + offset")
    cx, cy = pt("TOP", "BOTTOM")
    eq(cx, 0, "TOP on BOTTOM x"); eq(cy, -25, "TOP on BOTTOM y")
    check(S.Resolve({ mode = "point", point = "CENTER", relPoint = "CENTER" }, 20, 10, { x = 0, y = 0, w = 0, h = 40 }, 2) == nil,
        "zero-size parent -> nil in point mode")
    -- nil mode is still the outside solve
    local ox, oy = S.Resolve({ edge = "right", align = "start" }, 20, 10, parent, 2)
    eq(ox, 62, "nil mode still outside x"); eq(oy, 15, "nil mode still outside y")
end

-- drag deltas
do
    local x, y = S.DragDelta({ x = 100, y = -50 }, 10, 20, 13, 18)
    eq(x, 103, "delta x"); eq(y, -52, "delta y")
    local x2, y2 = S.DragDelta({}, 10, 20, 13, 18)
    eq(x2, 3, "nil start x treated as 0"); eq(y2, -2, "nil start y treated as 0")
end

-- snap zones + best zone
do
    local parent = { x = 0, y = 0, w = 100, h = 40 }
    local zones = S.SnapZones("p", parent, 20, 10, 2, function(edge, align) return edge == "right" and align == "center" end)
    eq(#zones, 12, "12 zones")
    local occupiedCount = 0
    for _, z in ipairs(zones) do if z.occupied then occupiedCount = occupiedCount + 1 end end
    eq(occupiedCount, 1, "one occupied zone")
    local best, area = S.BestZone(62, 15, 20, 10, zones, 0.1)
    check(best and best.edge == "right" and best.align == "start", "right/start wins")
    eq(area, 200, "full overlap area")
    local best2 = S.BestZone(62, 0, 20, 10, zones, 0.1)
    check(best2 == nil or not (best2.edge == "right" and best2.align == "center"), "occupied zone never returned")
    check(S.BestZone(500, 500, 20, 10, zones, 0.1) == nil, "no overlap -> nil")
    check(S.BestZone(81, 15, 20, 10, zones, 0.1) == nil, "tiny overlap rejected")
    eq(#S.SnapZones("z", { x = 0, y = 0, w = 0, h = 0 }, 20, 10, 2), 0, "zero-size target -> no zones")
end

-- nearest zone: fixed edge-to-edge distance, not a fraction of the dragged size
do
    local parent = { x = 0, y = 0, w = 100, h = 40 }
    local zones = S.SnapZones("p", parent, 20, 10, 2, function(edge, align) return edge == "right" and align == "center" end)
    -- 20x10 dragged to (110, 15): the right/start zone sits at (62, 15), so the
    -- rects are level on y and 28 units apart on x.
    local near, gap = S.NearestZone(110, 15, 20, 10, zones, 30)
    check(near and near.edge == "right" and near.align == "start", "nearest zone within distance wins")
    eq(gap, 28, "reports the edge-to-edge gap")
    check(S.NearestZone(110, 15, 20, 10, zones, 20) == nil, "beyond snapDistance -> nil")

    -- occupied zones are not candidates, however close
    local onTop = S.NearestZone(62, 0, 20, 10, zones, 100)
    check(onTop and not (onTop.edge == "right" and onTop.align == "center"), "occupied zone never returned")
    check(S.NearestZone(0, 0, 20, 10, { { target = "a", x = 0, y = 0, occupied = true } }, 100) == nil,
        "only-occupied candidates -> nil")

    -- no candidates at all
    check(S.NearestZone(0, 0, 20, 10, {}, 100) == nil, "no zones -> nil")
    check(S.NearestZone(500, 500, 20, 10, zones, 100) == nil, "everything out of range -> nil")

    -- two overlapping zones both have a gap of 0; the larger overlap breaks the tie,
    -- whichever order they are listed in
    local a = { target = "a", x = 6, y = 0 }     -- 14x10 of the dragged rect
    local b = { target = "b", x = 18, y = 0 }    --  2x10 of it
    check(S.NearestZone(0, 0, 20, 10, { a, b }, 50).target == "a", "gap tie broken by larger overlap")
    check(S.NearestZone(0, 0, 20, 10, { b, a }, 50).target == "a", "tie-break is order-independent")

    -- snapDistance 0 kills the reach but a genuine overlap is still a gap of 0
    local touching = S.NearestZone(62, 12, 20, 10, zones, 0)
    check(touching and touching.edge == "right" and touching.align == "start", "distance 0 still snaps on overlap")
    check(S.NearestZone(62, 30, 20, 10, zones, 0) == nil, "distance 0 does not reach past the overlap")
end

-- cycles & order
do
    local parents = { b = "a", c = "b" }
    local parentOf = function(id) return parents[id] end
    check(S.WouldCreateCycle(parentOf, "a", "c"), "a->c would cycle")
    check(not S.WouldCreateCycle(parentOf, "d", "c"), "d->c fine")
    check(S.WouldCreateCycle(parentOf, "a", "a"), "self-anchor is a cycle")
    local order = S.ResolutionOrder({ "c", "a", "b" }, parentOf)
    eq(table.concat(order, ","), "a,b,c", "parents first")
    local loop = { x = "y", y = "x" }
    local order2 = S.ResolutionOrder({ "x", "y", "z" }, function(id) return loop[id] end)
    eq(table.concat(order2, ","), "z", "cycle members dropped")
end

-- proximity
do
    eq(S.ProximityFactor(0, 100), 1, "at zone = 1")
    eq(S.ProximityFactor(100, 100), 0, "at max = 0")
    eq(S.ProximityFactor(150, 100), 0, "beyond max clamps")
end

-- screen clamp
do
    local cx, cy = S.ClampToScreen(1000, 0, 20, 10, 1920, 1080)
    eq(cx, 950, "right edge clamped"); eq(cy, 0, "y untouched")
    cx, cy = S.ClampToScreen(0, -600, 20, 10, 1920, 1080)
    eq(cy, -535, "bottom edge clamped")
    cx, cy = S.ClampToScreen(5, 5, 20, 10, 1920, 1080)
    eq(cx, 5, "inside untouched x"); eq(cy, 5, "inside untouched y")
    cx = S.ClampToScreen(0, 0, 3000, 10, 1920, 1080)
    eq(cx, 540, "oversize keeps left edge reachable")
end

-- rect-aware grid snap: centre or edge, whichever is closer
do
    -- 30 wide at cx=23: centre->20 (shift -3), left edge 8->0 (shift -8), right edge 38->40 (shift +2) => right edge wins
    local cx, cy = S.SnapRectToGrid(23, 0, 30, 10, 20)
    eq(cx, 25, "right edge snaps to 40 (cx 25)"); eq(cy, 0, "cy untouched when already on grid via centre")
    -- 30 wide at cx=12: centre->20 (+8), left
    -- edge -3->0 (+3), right 27->20 (-7) => left edge wins
    cx = S.SnapRectToGrid(12, 0, 30, 10, 20)
    eq(cx, 15, "left edge snaps to 0 (cx 15)")
    -- exact centre on grid stays
    cx, cy = S.SnapRectToGrid(40, 60, 30, 10, 20)
    eq(cx, 40, "centre on grid x"); eq(cy, 60, "centre on grid y")
    -- gridSize 0 / nil -> passthrough
    cx = S.SnapRectToGrid(7, 0, 30, 10, 0); eq(cx, 7, "grid 0 passthrough")
    -- y axis: 10 tall at cy=57: centre->60 (+3), top 62->60 (-2), bottom 52->60 (+8) => top wins
    local _, y = S.SnapRectToGrid(0, 57, 30, 10, 20)
    eq(y, 55, "top edge snaps to 60 (cy 55)")
end

-- nudge step: Shift x10, Ctrl x100, Ctrl wins when both are held
do
    eq(S.NudgeStep(false, false), 1, "plain nudge = 1")
    eq(S.NudgeStep(true, false), 10, "shift = 10")
    eq(S.NudgeStep(false, true), 100, "ctrl = 100")
    eq(S.NudgeStep(true, true), 100, "shift+ctrl = 100")
    eq(S.NudgeStep(nil, nil), 1, "nil modifiers = 1")
end

-- rect-aware grid snap reports the LINE the winning candidate landed on
do
    -- right edge wins (38 -> 40): the preview belongs on x=40, not the centre
    local cx, cy, lx, ly = S.SnapRectToGrid(23, 0, 30, 10, 20)
    eq(cx, 25, "cx"); eq(lx, 40, "x line = right edge's grid line")
    eq(ly, 0, "y line = centre's grid line (already on it)")
    -- left edge wins (-3 -> 0)
    local _, _, lx2 = S.SnapRectToGrid(12, 0, 30, 10, 20)
    eq(lx2, 0, "x line = left edge's grid line")
    -- top edge wins on y (62 -> 60)
    local _, _, _, ly3 = S.SnapRectToGrid(0, 57, 30, 10, 20)
    eq(ly3, 60, "y line = top edge's grid line")
    -- exactly on a line: zero shift still reports the line
    local _, _, lx4, ly4 = S.SnapRectToGrid(40, 60, 30, 10, 20)
    eq(lx4, 40, "on-grid centre reports its line x"); eq(ly4, 60, "on-grid centre reports its line y")
    -- no grid: no lines
    local _, _, lx5, ly5 = S.SnapRectToGrid(7, 0, 30, 10, 0)
    check(lx5 == nil and ly5 == nil, "grid 0 -> no lines")
end
