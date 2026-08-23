local addonName, NS = ...

-- ============================================================
-- SOLVER
-- Pure geometry. No frames, no WoW globals. All coordinates are UIParent
-- units relative to UIParent CENTER. rect = {x=cx, y=cy, w, h}.
-- Snap-zone and resolve maths lifted from DandersCDM UI/Position.lua.
-- ============================================================
local S = {}
NS.Solver = S

local floor, abs, max, min, sqrt, huge = math.floor, math.abs, math.max, math.min, math.sqrt, math.huge
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

-- Nudge distance for one arrow press / click. Ctrl wins over Shift so
-- Shift+Ctrl is still x100, not an undefined mix.
function S.NudgeStep(shift, ctrl)
    if ctrl then return 100 end
    if shift then return 10 end
    return 1
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
--
-- Returns cx, cy, lineX, lineY: the snapped centre plus, per axis, the grid
-- line the winning candidate (centre or edge) now sits on -- the line a snap
-- preview should draw, which is NOT the centre when an edge is what snapped.
-- A candidate already on a line wins with a zero shift and still reports its
-- line. Both lines are nil when there is no grid to snap to.
function S.SnapRectToGrid(cx, cy, w, h, gridSize)
    if not gridSize or gridSize <= 0 then return cx, cy, nil, nil end
    local function best(center, half)
        local candidates = { center, center - half, center + half }
        local bestShift, bestAbs, bestLine = 0, math.huge, nil
        for _, v in ipairs(candidates) do
            local snapped = floor(v / gridSize + 0.5) * gridSize
            local shift = snapped - v
            if abs(shift) < bestAbs then bestAbs, bestShift, bestLine = abs(shift), shift, snapped end
        end
        return center + bestShift, bestLine
    end
    local nx, lineX = best(cx, w / 2)
    local ny, lineY = best(cy, h / 2)
    return nx, ny, lineX, lineY
end

-- Snaps the rect's nearest edge or its centre to the screen edges / centre lines.
-- Returns cx, cy, sx, sy, lineX, lineY: the snapped centre, whether each axis
-- snapped, and the screen line (0 or +-half the screen) it snapped to -- nil on
-- an axis that did not snap.
function S.SnapToScreen(rect, screenW, screenH, threshold)
    local cx, cy = rect.x, rect.y
    local hw, hh = rect.w / 2, rect.h / 2
    local halfW, halfH = screenW / 2, screenH / 2
    local sx, sy = false, false
    local lineX, lineY
    local candX = { { cx, 0 }, { cx - hw, -halfW }, { cx + hw, halfW } }
    local candY = { { cy, 0 }, { cy - hh, -halfH }, { cy + hh, halfH } }
    local bestD = threshold
    for _, c in ipairs(candX) do
        local d = abs(c[1] - c[2])
        if d <= bestD then bestD = d; cx = rect.x + (c[2] - c[1]); sx = true; lineX = c[2] end
    end
    bestD = threshold
    for _, c in ipairs(candY) do
        local d = abs(c[1] - c[2])
        if d <= bestD then bestD = d; cy = rect.y + (c[2] - c[1]); sy = true; lineY = c[2] end
    end
    return cx, cy, sx, sy, lineX, lineY
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

-- Area of the intersection of two centre-based rects; 0 when they only touch
-- or are apart.
function S.RectOverlapArea(a, b)
    local w = min(a.x + a.w / 2, b.x + b.w / 2) - max(a.x - a.w / 2, b.x - b.w / 2)
    local h = min(a.y + a.h / 2, b.y + b.h / 2) - max(a.y - a.h / 2, b.y - b.h / 2)
    if w > 0 and h > 0 then return w * h end
    return 0
end

-- ============================================================
-- PANEL DOCKING
-- ============================================================
-- Candidate panel positions beside a proxy rect, in tie-break priority order
-- (right > left > below > above). right/left hang from the proxy's TOP edge --
-- the panel's historical dock -- while above/below centre on it.
function S.DockCandidates(proxy, panelW, panelH, gap)
    local top = proxy.y + proxy.h / 2
    return {
        { side = "right", x = proxy.x + proxy.w / 2 + gap + panelW / 2, y = top - panelH / 2 },
        { side = "left",  x = proxy.x - proxy.w / 2 - gap - panelW / 2, y = top - panelH / 2 },
        { side = "below", x = proxy.x, y = proxy.y - proxy.h / 2 - gap - panelH / 2 },
        { side = "above", x = proxy.x, y = proxy.y + proxy.h / 2 + gap + panelH / 2 },
    }
end

-- The dock side that covers the least: each fully-on-screen candidate is scored
-- by its total overlap area against the obstacle rects, smallest wins. Ties
-- keep the earlier candidate, so DockCandidates' order IS the tie-break.
-- nil when no candidate fits on screen (the caller falls back to an edge flip).
function S.BestDockSide(proxy, panelW, panelH, gap, obstacles, screenW, screenH)
    local halfW, halfH = screenW / 2, screenH / 2
    local best, bestOverlap
    for _, c in ipairs(S.DockCandidates(proxy, panelW, panelH, gap)) do
        if c.x - panelW / 2 >= -halfW and c.x + panelW / 2 <= halfW
        and c.y - panelH / 2 >= -halfH and c.y + panelH / 2 <= halfH then
            local rect = { x = c.x, y = c.y, w = panelW, h = panelH }
            local overlap = 0
            for _, o in ipairs(obstacles) do overlap = overlap + S.RectOverlapArea(rect, o) end
            if overlap == 0 then return c.side end     -- nothing beats zero at this priority
            if not bestOverlap or overlap < bestOverlap then best, bestOverlap = c.side, overlap end
        end
    end
    return best
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

-- Largest rectangle overlap with a minimum-fraction floor. No longer what the
-- drag uses (see NearestZone) -- kept because it is public surface and its
-- overlap maths is the tie-break NearestZone falls back to.
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

-- The hit test the drag actually uses: a FIXED radius in screen units, not a
-- fraction of the dragged element. BestZone's overlap rule made the snap radius
-- scale with the frame -- a 500px-wide raid container caught a zone from 250px
-- away while a 60px icon had to be almost on top of it. Here the measure is the
-- edge-to-edge gap between the dragged rect and the zone rect (0 while they
-- overlap), and one setting means the same distance for every element.
--
-- Ties (every overlapping candidate has a gap of 0) fall back to the larger
-- overlap area, which is BestZone's ordering, so a drop that sits over several
-- zones still picks the one it covers most.
local EPSILON = 1e-9

-- The zone whose landing position is nearest to where the element is now,
-- measured centre to centre (= how far the element would jump on drop), and
-- only within snapDistance. Size-independent: a 400-wide container and a
-- 20-wide icon both snap from the same distance. Ties go to the larger overlap.
function S.NearestZone(cx, cy, w, h, zones, snapDistance)
    snapDistance = snapDistance or 0
    local hw, hh = w / 2, h / 2
    local dl, dr, dt, db = cx - hw, cx + hw, cy + hh, cy - hh
    local best, bestDist, bestArea = nil, huge, -1
    for _, z in ipairs(zones) do
        if not z.occupied then
            local dx, dy = cx - z.x, cy - z.y
            local dist = sqrt(dx * dx + dy * dy)
            if dist <= snapDistance + EPSILON then
                local ol, orr = max(dl, z.x - hw), min(dr, z.x + hw)
                local ob, ot = max(db, z.y - hh), min(dt, z.y + hh)
                local area = (orr > ol and ot > ob) and (orr - ol) * (ot - ob) or 0
                if dist < bestDist - EPSILON or (dist <= bestDist + EPSILON and area > bestArea) then
                    best, bestDist, bestArea = z, dist, area
                end
            end
        end
    end
    if best then return best, bestDist, bestArea end
    return nil
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

-- ============================================================
-- ANCHOR TETHER
-- Pull-out thresholds for dragging an anchored element, as multiples of the
-- snapDistance setting: within HOLD x snapDistance of the RESOLVED anchor
-- position the anchor is kept (the drop springs back), between HOLD x and
-- SNAP x the tether strains, and past SNAP x it snaps -- the element detaches
-- mid-drag. Multiples of the one reach setting the user already tunes, so a
-- bigger snap radius also means a longer tether.
-- ============================================================
S.TETHER_HOLD = 3
S.TETHER_SNAP = 4

-- "held" | "strained" | "snapped" for a drag `dist` px out from the resolved
-- anchor position. snapDistance 0 turns frame snapping's reach off entirely,
-- so the tether is unbreakable there rather than hair-triggered.
function S.TetherState(dist, snapDistance)
    if not snapDistance or snapDistance <= 0 then return "held" end
    if dist <= snapDistance * S.TETHER_HOLD then return "held" end
    if dist <= snapDistance * S.TETHER_SNAP then return "strained" end
    return "snapped"
end

-- How hard the tether is being pulled: 0 up to the strain threshold, rising to
-- 1 at the snap point. Drives the strain colour lerp.
function S.TetherStrain(dist, snapDistance)
    if not snapDistance or snapDistance <= 0 then return 0 end
    local a, b = snapDistance * S.TETHER_HOLD, snapDistance * S.TETHER_SNAP
    if dist <= a then return 0 end
    if dist >= b then return 1 end
    return (dist - a) / (b - a)
end
