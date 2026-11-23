local NS = ...
local R = NS.Registry
local S = NS.Solver

-- ============================================================
-- ANCHOR MIRRORING (Solver.lua MIRROR, Core.lua ResolveElement, Session.lua MIRROR)
-- ------------------------------------------------------------
-- An anchored child can mirror its parent on X and/or Y: on a mirrored axis the
-- child's CENTRE is the parent's CENTRE reflected across a centre line at
-- mirrorPosX / mirrorPosY (0 = screen centre). Moving either half moves the other
-- the opposite way; the line only moves through the Mirror Position setting.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. Core.lua loads once
-- (test_registry_events owns that); the guarded load below is for a filtered run.
-- The file NAME matters: it must sort after test_registry_events, because loading
-- Core.lua earlier swaps NS.Lib for the real lib under test_proxy, whose session
-- then subscribes for real and crashes a later suite. Everything replaced is put back.
-- ============================================================

local function near(a, b, msg) check(math.abs((a or 0/0) - b) < 1e-6, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end

print("-- solver: reflection of centres")
do
    local parent = { x = -500, y = 100, w = 200, h = 50 }
    local a = { edge = "right", align = "center", offsetX = 0, offsetY = 7, mirrorX = true }
    local x, y = S.Resolve(a, 100, 80, parent, 2)
    eq(x, 500, "mirror X, line 0: the child's centre is the parent's centre reflected")
    eq(y, 107, "mirror X only: Y keeps the seat + offset")
    -- Different sizes, same reflection: centres, not edges.
    local x2 = S.Resolve(a, 30, 80, parent, 2)
    eq(x2, 500, "a narrower child reflects to the same centre")
    -- The line moves with mirrorPosX.
    a.mirrorPosX = 50
    eq((S.Resolve(a, 100, 80, parent, 2)), 600, "mirrorPosX 50: line at screen centre + 50")
    a.mirrorPosX = -25
    eq((S.Resolve(a, 100, 80, parent, 2)), 450, "mirrorPosX -25: line at screen centre - 25")
    -- Mirror Y only: X keeps the seat (right edge), Y reflects.
    local b = { edge = "right", align = "center", offsetX = 5, offsetY = 0, mirrorY = true, mirrorPosY = -20 }
    local bx, by = S.Resolve(b, 100, 80, parent, 2)
    eq(bx, -500 + 100 + 2 + 50 + 5, "mirror Y only: X keeps the seat + offset")
    eq(by, -140, "mirror Y, line -20: 2 * -20 - 100")
    -- Both axes, point mode.
    local c = { mode = "point", point = "TOPLEFT", relPoint = "BOTTOMRIGHT", mirrorX = true, mirrorY = true }
    local cx, cy = S.Resolve(c, 10, 10, parent, 2)
    eq(cx, 500, "both axes, point mode: X reflected"); eq(cy, -100, "both axes, point mode: Y reflected")
end

print("-- solver: old records resolve exactly as before")
do
    local parent = { x = 200, y = 0, w = 100, h = 40 }
    local x, y = S.Resolve({ edge = "right", align = "center", offsetX = 3, offsetY = -4 }, 60, 30, parent, 2)
    eq(x, 200 + 50 + 2 + 30 + 3, "outside: unchanged maths"); eq(y, -4, "outside: unchanged maths (y)")
    local px, py = S.Resolve({ mode = "point", point = "TOPLEFT", relPoint = "BOTTOMRIGHT", offsetX = 1, offsetY = 2 },
        60, 30, parent, 2)
    eq(px, 250 + 30 + 1, "point: unchanged maths"); eq(py, -20 - 15 + 2, "point: unchanged maths (y)")
    check(S.Resolve({ edge = "right" }, 10, 10, { x = 0, y = 0, w = 0, h = 10 }, 2) == nil, "zero-size parent still holds")
    local rx, ry = S.Readout({ point = "CENTER", x = 0, y = 0, anchor = { offsetX = 12.4, offsetY = -3.6 } })
    eq(rx, 12, "readout: offsets on an unmirrored anchor"); eq(ry, -4, "readout: offsets (y)")
end

print("-- solver: offsets that reproduce a centre, line, pair clamp, readout")
do
    local parent = { x = -500, y = 100, w = 200, h = 50 }
    local a = { edge = "bottom", align = "start", mirrorX = true }
    local ox, oy = S.OffsetsFor(a, 100, 80, parent, 2, 333, -7)
    local plain = { edge = "bottom", align = "start", offsetX = ox, offsetY = oy }
    local x, y = S.Resolve(plain, 100, 80, parent, 2)
    near(x, 333, "OffsetsFor inverts Resolve (x)"); near(y, -7, "OffsetsFor inverts Resolve (y)")
    eq(S.MirrorLine(-500, 300), -100, "the line two centres mirror around is their midpoint")
    eq(S.Reflect(-500, -100), 300, "...and reflecting one across it gives the other")
    -- Pair clamp: screen half 960, element half 100, partner half 50.
    eq(S.MirrorClampAxis(-400, 100, 50, 0, 960), -400, "in range on both sides: untouched")
    eq(S.MirrorClampAxis(-900, 100, 50, 100, 960), -710, "the partner would leave the right edge: pair pulled in")
    eq(S.MirrorClampAxis(900, 100, 50, 0, 960), 860, "the element itself would leave: its own edge")
    eq(S.MirrorClampAxis(0, 100, 50, 2000, 960), 0, "no range fits both: untouched, the caller's clamp applies")
    local rx, ry = S.Readout({ point = "CENTER", x = 0, y = 0,
        anchor = { offsetX = 99, offsetY = 3, mirrorX = true, mirrorPosX = 40.6 } })
    eq(rx, 41, "readout: a mirrored axis shows its Mirror Position"); eq(ry, 3, "readout: the other axis its offset")
end

-- ============================================================
-- SESSION / CORE: real Registry, Core and Session, stubbed Proxy and Grid
-- ============================================================
local savedCreateFrame = CreateFrame
if not LibStub("DandersMover-1.0", true) then
    local function stubFrame()
        local f = { _scripts = {} }
        function f:SetScript(name, fn) self._scripts[name] = fn end
        function f:GetScript(name) return self._scripts[name] end
        return setmetatable(f, { __index = function() return function() end end })
    end
    CreateFrame = function() return stubFrame() end
    SlashCmdList = SlashCmdList or {}
    local uiLib = LibStub:NewLibrary("DandersUI-1.0", 1)
    if uiLib then uiLib.NewHost = function() return stubFrame() end end
    load_addon_file("Core.lua")
    CreateFrame = savedCreateFrame
end

local wasReady = R.ready
R.ready = true
local prevDb = NS.db
NS.db = { showHiddenMovers = true, snapToFrames = false, snapToGrid = false, snapToScreen = false,
          snapDistance = 25, addons = {} }
local prevProxy, prevGrid, prevSession = NS.Proxy, NS.Grid, NS.Session
NS.Proxy = { dragZones = {}, RefreshAll = function() end, Highlight = function() end,
             Refresh = function() end, ShowToast = function() end, SyncMany = function() end,
             DismissAll = function() end, SnapTether = function() end }
NS.Grid = { Hide = function() end, HidePreview = function() end, ShowPreview = function() end,
            ShowMeasure = function() end }
NS.Session = nil
local prevTimer = C_Timer
C_Timer = { After = function() end }
load_addon_file("Session.lua")
C_Timer = prevTimer
local Sess = NS.Session
Sess.EnableKeyboard = function() end

local function startSession()
    Sess.undo = LibStub("DandersUndo-1.0"):New({ limit = 50 })
    Sess.active, Sess.suspended, Sess.filter, Sess.dirty = true, false, nil, false
end

-- Elements whose visible rect IS their record (CENTER point), so moving the record
-- moves what other elements see -- the shape a real consumer's getRect gives.
local recs = {}
local function element(key, x, y, w, h)
    local pos = { point = "CENTER", x = x, y = y }
    recs[key] = pos
    return R:Register("MI", key, { title = key, frame = FakeFrame(960 + x, 540 + y, w, h),
        getSize = function() return w, h end, getPos = function() return pos end,
        getRect = function() return { x = pos.x, y = pos.y, w = w, h = h } end,
        onChanged = function() end })
end
R:RegisterAddon("MI", { title = "MI" })
local P = element("p", -500, 100, 200, 50)
local C = element("c", -290, 110, 100, 80)
local pp, cp = recs.p, recs.c

-- Drive a drag the way Proxy does: BeginDrag, one DragTo per step, EndDrag at the last.
local function drag(el, dx, dy)
    local pos = R:GetPos(el)
    local sx, sy = pos.x, pos.y
    Sess:BeginDrag(el)
    local fx, fy, zone = Sess:DragTo(el, sx + dx / 2, sy + dy / 2)
    fx, fy, zone = Sess:DragTo(el, sx + dx, sy + dy)
    Sess:EndDrag(el, fx, fy, zone)
end

startSession()

print("-- turning mirror on keeps the child where it is")
check(Sess:Anchor(C, "MI:p", "right", "center"), "c anchors to p's right edge")
local cx0, cy0 = cp.x, cp.y
eq(cx0, -500 + 100 + 2 + 50, "c seated right of p")
Sess:SetMirror(C, "X", true)
check(cp.anchor.mirrorX == true, "mirrorX is on")
eq(cp.anchor.mirrorPosX, (cx0 + -500) / 2, "the line is the midpoint of the two centres")
near(cp.x, cx0, "the child did not move (x)"); eq(cp.y, cy0, "the child did not move (y)")
check(cp.anchor.mirrorY == nil, "mirror Y stays off")
check(Sess.undo:CanUndo(), "turning it on is an undo step")

print("-- dragging the parent: the child moves the opposite way on the mirrored axis")
local line = cp.anchor.mirrorPosX
drag(P, -100, 30)
eq(pp.x, -600, "p moved left 100"); eq(pp.y, 130, "p moved up 30")
near(cp.x, 2 * line - (-600), "c is p reflected across the line")
near(cp.x - cx0, 100, "...i.e. it moved right 100")
eq(cp.y, cy0 + 30, "Y is not mirrored: c follows p up like any anchored child")
check(cp.anchor and cp.anchor.mirrorX, "c is still anchored and mirrored")
near(S.Resolve({ edge = "right", align = "center", offsetX = cp.anchor.offsetX, offsetY = cp.anchor.offsetY },
    100, 80, { x = pp.x, y = pp.y, w = 200, h = 50 }, S.SPACING), cp.x,
    "the stored offsetX is kept in sync: a reader that ignores mirroring places c where it is")

print("-- dragging the child: the parent moves the opposite way, one undo step for both")
local px1, cx1 = pp.x, cp.x
drag(C, -60, 0)
near(cp.x, cx1 - 60, "c moved left 60")
near(pp.x, px1 + 60, "p moved right 60")
check(cp.anchor and cp.anchor.mirrorX and cp.anchor.target == "MI:p", "c kept its mirrored anchor")
near(cp.anchor.mirrorPosX, line, "the centre line did not move")
Sess:Undo()
near(pp.x, px1, "undo: p back"); near(cp.x, cx1, "undo: c back")
Sess:Redo()
near(pp.x, px1 + 60, "redo: p moved again"); near(cp.x, cx1 - 60, "redo: c moved again")

print("-- dragging the child on its unmirrored axis keeps today's tether")
local px2, py2, cy2 = pp.x, pp.y, cp.y
drag(C, 0, 20)          -- inside the hold radius (2 x 25)
eq(cp.y, cy2, "a short pull on Y springs back")
eq(pp.x, px2, "...and the parent did not move"); eq(pp.y, py2, "...on either axis")
drag(C, 40, 0)          -- a long pull on the MIRRORED axis never strains the tether
check(cp.anchor ~= nil, "a long pull along the mirrored axis keeps the anchor")
near(pp.x, px2 - 40, "...and drags the parent the other way")

print("-- nudging")
local px3, cx3, oy3 = pp.x, cp.x, cp.anchor.offsetY
Sess:Nudge(C, 10, 0)
near(cp.x, cx3 + 10, "nudge c right 10"); near(pp.x, px3 - 10, "p goes left 10")
Sess:Nudge(C, 0, 5)
eq(cp.anchor.offsetY, oy3 + 5, "nudge on the unmirrored axis is the offset, as always")
near(pp.x, px3 - 10, "...and leaves the parent alone")
Sess:Nudge(P, -10, 0)
near(cp.x, cx3 + 20, "nudging the parent left moves the child right")

print("-- Mirror Position box")
Sess:SetXY(C, 40, cp.anchor.offsetY)
eq(cp.anchor.mirrorPosX, 40, "the X box writes the line on a mirrored axis")
near(cp.x, 80 - pp.x, "c reflects across the new line")
local oyKeep = cp.anchor.offsetY
cp.anchor.mirrorPosX = 40.4
Sess:SetXY(C, 40, oyKeep)
eq(cp.anchor.mirrorPosX, 40.4, "an unchanged (rounded) box does not round the line")

print("-- pair clamp: neither half is pushed off screen")
Sess:SetXY(C, 100, oyKeep)
drag(P, -2000, 0)
eq(pp.x, 2 * 100 - 960 + 50, "p stops where c reaches the right edge")
near(cp.x + 50, 960, "c sits exactly on the right edge")
drag(C, 3000, 0)
near(cp.x + 50, 960, "dragging c past the edge stops at the edge")
near(pp.x, 2 * 100 - cp.x, "...and p is still its reflection")

print("-- turning mirror off keeps the child where it is")
local cxOff, cyOff = cp.x, cp.y
Sess:SetMirror(C, "X", false)
check(cp.anchor.mirrorX == nil and cp.anchor.mirrorPosX == nil, "the mirror fields are cleared")
near(cp.x, cxOff, "the child did not move (x)"); eq(cp.y, cyOff, "the child did not move (y)")
local pxOff = pp.x
drag(P, 50, 0)
near(cp.x, cxOff + 50, "unmirrored again: c follows p the same way")
Sess:Undo(); Sess:Undo()
check(cp.anchor.mirrorX == true, "undo brings the mirror back")
near(pp.x, pxOff, "...with p where it was")

print("-- a long pull on the unmirrored axis detaches and puts the parent back")
Sess:SetMirror(C, "X", false)
Sess:SetMirror(C, "Y", true)
check(cp.anchor.mirrorY and not cp.anchor.mirrorX, "mirror Y only")
local px5, py5 = pp.x, pp.y
drag(C, -300, 0)    -- X is held now: past 4 x 25 the tether snaps
check(cp.anchor == nil, "the child is detached")
eq(pp.x, px5, "the parent is back where it started (x)"); eq(pp.y, py5, "...and (y)")
Sess:Undo()
check(cp.anchor and cp.anchor.mirrorY, "undo re-attaches with the mirror")

print("-- a parent that cannot follow holds the mirrored axis")
local tgt = FakeFrame(960 + 300, 540 - 200, 80, 40)
R:RegisterAnchorTarget("MI", "fixed", { title = "fixed", frame = tgt })
local G = element("g", 0, 0, 40, 40)
local gp = recs.g
check(Sess:Anchor(G, "MI:fixed", "left", "center"), "g anchors to a plain anchor target")
Sess:SetMirror(G, "X", true)
local gx = gp.x
Sess:Nudge(G, 25, 0)
eq(gp.x, gx, "nudge on the mirrored axis is a no-op when the parent cannot move")
drag(G, 30, 0)
check(gp.anchor and gp.anchor.mirrorX, "a short drag keeps the anchor")
near(gp.x, gx, "...and springs back on the mirrored axis")

print("-- effective scale: reflection is in screen space")
local scaled = FakeFrame(1160, 340, 100, 40, 0.5)   -- UIParent units: centre (-380, -370), 50 x 20
R:RegisterAnchorTarget("MI", "scaled", { title = "scaled", frame = scaled })
local H = element("h", 0, 0, 40, 40)
check(Sess:Anchor(H, "MI:scaled", "right", "center"), "h anchors to a half-scale target")
Sess:SetXY(H, 0, 0)
Sess:SetMirror(H, "X", true)
Sess:SetXY(H, 0, 0)
near(recs.h.x, 380, "line 0: h sits at the target's SCREEN centre reflected")

print("-- chains: a mirrored child's own children follow it as normal")
local K = element("k", 0, 0, 20, 20)
check(Sess:Anchor(K, "MI:c", "bottom", "center"), "k anchors under c")
Sess:SetMirror(C, "Y", false)
Sess:SetMirror(C, "X", true)
local kx = recs.k.x
local cxK = cp.x
drag(P, 50, 0)
near(cp.x - cxK, -50, "c mirrors p")
near(recs.k.x - kx, -50, "k follows c")

print("-- old saved data: no mirror fields, nothing changes")
local old = { point = "CENTER", x = 0, y = 0,
              anchor = { target = "MI:p", edge = "left", align = "start", offsetX = 1, offsetY = 2 } }
local copy = NS.CopyPos(old)
check(copy.anchor.mirrorX == nil and copy.anchor.mirrorY == nil
      and copy.anchor.mirrorPosX == nil and copy.anchor.mirrorPosY == nil, "CopyPos adds no mirror fields")
local O = R:Register("MI", "o", { title = "o", frame = FakeFrame(960, 540, 30, 30),
    getSize = function() return 30, 30 end, getPos = function() return old end, onChanged = function() end })
NS:ResolveElement(O)
local ex, ey = S.Resolve({ edge = "left", align = "start", offsetX = 1, offsetY = 2 }, 30, 30,
    { x = pp.x, y = pp.y, w = 200, h = 50 }, S.SPACING)
eq(old.x, ex, "an old record solves to the unmirrored seat (x)"); eq(old.y, ey, "...(y)")
eq(old.anchor.offsetX, 1, "...and its offsets are untouched"); eq(old.anchor.offsetY, 2, "...(y)")
check(NS.CopyPos({ anchor = { target = "MI:p", mirrorX = true, mirrorPosX = 5,
    fallback = { target = "MI:fixed", mirrorX = true } } }).anchor.fallback.mirrorX == nil,
    "a backup block never carries a mirror")

-- ============================================================
-- RESTORE
-- ============================================================
Sess.active, Sess.suspended = false, false
Sess.undo = nil
NS.Session = prevSession
NS.Proxy, NS.Grid = prevProxy, prevGrid
R:UnregisterAddon("MI")
R.ready = wasReady
NS.db = prevDb
