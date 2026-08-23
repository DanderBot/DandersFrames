local addonName, NS = ...

-- ============================================================
-- SOLVER
-- Pure geometry. No frames, no WoW globals. All coordinates are UIParent
-- units relative to UIParent CENTER. rect = {x=cx, y=cy, w, h}.
-- Snap-zone and resolve maths lifted from DandersCDM UI/Position.lua.
-- ============================================================
local S = {}
NS.Solver = S

local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local ipairs, tinsert = ipairs, table.insert

S.SPACING = 2

-- ============================================================
-- POINT <-> CENTER
-- ============================================================
local H = { LEFT = -1, RIGHT = 1, TOPLEFT = -1, BOTTOMLEFT = -1, TOPRIGHT = 1, BOTTOMRIGHT = 1 }
local V = { TOP = 1, BOTTOM = -1, TOPLEFT = 1, TOPRIGHT = 1, BOTTOMLEFT = -1, BOTTOMRIGHT = -1 }

function S.PointToCenter(point, x, y, w, h)
    return x - (H[point] or 0) * w / 2, y - (V[point] or 0) * h / 2
end

function S.CenterToPoint(point, cx, cy, w, h)
    return cx + (H[point] or 0) * w / 2, cy + (V[point] or 0) * h / 2
end

-- Drag deltas. The record's point/x/y and the element's visible centre can be
-- offset from each other; moving the visible centre by (dx, dy) moves the
-- record by the same (dx, dy), whatever that offset is.
function S.DragDelta(startPos, startCx, startCy, cx, cy)
    return (startPos.x or 0) + (cx - startCx), (startPos.y or 0) + (cy - startCy)
end

-- ============================================================
-- GRID / SCREEN SNAP
-- ============================================================
function S.SnapToGrid(x, y, gridSize)
    if not gridSize or gridSize <= 0 then return x, y end
    return floor(x / gridSize + 0.5) * gridSize, floor(y / gridSize + 0.5) * gridSize
end

-- Grid snap that considers the rect's centre AND its edges per axis, and moves
-- the rect by whichever lands on a grid line with the smallest shift. This is
-- what lets a frame's left edge or top edge sit exactly on the grid, not only
-- its centre. (Behaviour of the legacy DandersFrames mover.)
function S.SnapRectToGrid(cx, cy, w, h, gridSize)
    if not gridSize or gridSize <= 0 then return cx, cy end
    local function best(center, half)
        local candidates = { center, center - half, center + half }
        local bestShift, bestAbs = 0, math.huge
        for _, v in ipairs(candidates) do
            local snapped = floor(v / gridSize + 0.5) * gridSize
            local shift = snapped - v
            if abs(shift) < bestAbs then bestAbs, bestShift = abs(shift), shift end
        end
        return center + bestShift
    end
    return best(cx, w / 2), best(cy, h / 2)
end

-- Snaps the rect's nearest edge or its centre to the screen edges / centre lines.
function S.SnapToScreen(rect, screenW, screenH, threshold)
    local cx, cy = rect.x, rect.y
    local hw, hh = rect.w / 2, rect.h / 2
    local halfW, halfH = screenW / 2, screenH / 2
    local sx, sy = false, false
    local candX = { { cx, 0 }, { cx - hw, -halfW }, { cx + hw, halfW } }
    local candY = { { cy, 0 }, { cy - hh, -halfH }, { cy + hh, halfH } }
    local bestD = threshold
    for _, c in ipairs(candX) do
        local d = abs(c[1] - c[2])
        if d <= bestD then bestD = d; cx = rect.x + (c[2] - c[1]); sx = true end
    end
    bestD = threshold
    for _, c in ipairs(candY) do
        local d = abs(c[1] - c[2])
        if d <= bestD then bestD = d; cy = rect.y + (c[2] - c[1]); sy = true end
    end
    return cx, cy, sx, sy
end

-- Keeps the rect inside the screen (UIParent units). Elements larger than the
-- screen are pinned so their top-left corner stays reachable.
function S.ClampToScreen(cx, cy, w, h, screenW, screenH)
    local hw, hh, halfW, halfH = w / 2, h / 2, screenW / 2, screenH / 2
    if cx + hw > halfW then cx = halfW - hw end
    if cx - hw < -halfW then cx = -halfW + hw end
    if cy + hh > halfH then cy = halfH - hh end
    if cy - hh < -halfH then cy = -halfH + hh end
    return cx, cy
end

-- ============================================================
-- ANCHOR RESOLUTION
-- ============================================================
function S.Resolve(anchor, childW, childH, parent, spacing)
    if not parent or not parent.w or not parent.h or parent.w <= 0 or parent.h <= 0 then return nil end
    -- Point mode: child:SetPoint(point, target, relPoint, offsetX, offsetY).
    if anchor.mode == "point" then
        local pt, rel = anchor.point or "CENTER", anchor.relPoint or "CENTER"
        local tx = parent.x + (H[rel] or 0) * parent.w / 2
        local ty = parent.y + (V[rel] or 0) * parent.h / 2
        return tx - (H[pt] or 0) * childW / 2 + (anchor.offsetX or 0),
               ty - (V[pt] or 0) * childH / 2 + (anchor.offsetY or 0)
    end
    spacing = spacing or S.SPACING
    local hpw, hph = parent.w / 2, parent.h / 2
    local hcw, hch = childW / 2, childH / 2
    local edge, align = anchor.edge or "right", anchor.align or "center"
    local x, y = parent.x, parent.y
    if edge == "right" then x = parent.x + hpw + spacing + hcw
    elseif edge == "left" then x = parent.x - hpw - spacing - hcw
    elseif edge == "top" then y = parent.y + hph + spacing + hch
    elseif edge == "bottom" then y = parent.y - hph - spacing - hch end
    if edge == "right" or edge == "left" then
        if align == "start" then y = parent.y + hph - hch
        elseif align == "end" then y = parent.y - hph + hch end
    else
        if align == "start" then x = parent.x - hpw + hcw
        elseif align == "end" then x = parent.x + hpw - hcw end
    end
    return x + (anchor.offsetX or 0), y + (anchor.offsetY or 0)
end

-- ============================================================
-- SNAP ZONES
-- 12 per target: 4 edges x start/center/end. isOccupied(edge, align) -> bool.
-- ============================================================
local EDGES = { "right", "left", "top", "bottom" }
local ALIGNS = { "start", "center", "end" }

function S.SnapZones(targetId, target, dragW, dragH, spacing, isOccupied)
    local zones = {}
    if not target or target.w <= 0 or target.h <= 0 then return zones end
    for _, edge in ipairs(EDGES) do
        for _, align in ipairs(ALIGNS) do
            local x, y = S.Resolve({ edge = edge, align = align }, dragW, dragH, target, spacing)
            tinsert(zones, {
                target = targetId, edge = edge, align = align, x = x, y = y,
                occupied = (isOccupied and isOccupied(edge, align)) or false,
            })
        end
    end
    return zones
end

function S.BestZone(cx, cy, w, h, zones, minFraction)
    local hw, hh = w / 2, h / 2
    local dl, dr, dt, db = cx - hw, cx + hw, cy + hh, cy - hh
    local best, bestArea = nil, 0
    for _, z in ipairs(zones) do
        if not z.occupied then
            local ol, orr = max(dl, z.x - hw), min(dr, z.x + hw)
            local ob, ot = max(db, z.y - hh), min(dt, z.y + hh)
            if orr > ol and ot > ob then
                local area = (orr - ol) * (ot - ob)
                if area > bestArea then best, bestArea = z, area end
            end
        end
    end
    if best and bestArea >= w * h * (minFraction or 0.1) then return best, bestArea end
    return nil, 0
end

-- ============================================================
-- GRAPH
-- ============================================================
function S.WouldCreateCycle(parentOf, childId, targetId)
    local cur, seen = targetId, {}
    while cur do
        if cur == childId then return true end
        if seen[cur] then return false end
        seen[cur] = true
        cur = parentOf(cur)
    end
    return false
end

-- Parents before children. Ids whose ancestry loops are dropped.
function S.ResolutionOrder(ids, parentOf)
    local set = {}
    for _, id in ipairs(ids) do set[id] = true end
    local order, state = {}, {}   -- 1 visiting, 2 done, 3 cyclic
    local function visit(id)
        if state[id] == 2 then return true end
        if state[id] == 1 or state[id] == 3 then return false end
        state[id] = 1
        local p = parentOf(id)
        local ok = true
        if p and set[p] then ok = visit(p) end
        if ok then state[id] = 2; tinsert(order, id) else state[id] = 3 end
        return ok
    end
    for _, id in ipairs(ids) do visit(id) end
    return order
end

function S.ProximityFactor(dist, maxDist)
    if dist >= maxDist then return 0 end
    return 1 - dist / maxDist
end
