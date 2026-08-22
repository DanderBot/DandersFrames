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
    local cx, cy, sx, sy = S.SnapToScreen({ x = -946, y = 3, w = 20, h = 10 }, 1920, 1080, 8)
    eq(cx, -950, "left edge snapped"); check(sx, "x snapped")
    eq(cy, 0, "centre line snapped"); check(sy, "y snapped")
    local cx2, _, sx2 = S.SnapToScreen({ x = 300, y = 300, w = 20, h = 10 }, 1920, 1080, 8)
    eq(cx2, 300, "far from edges untouched"); check(not sx2, "x not snapped")
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
