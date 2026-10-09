local NS = ...
local R = NS.Registry
local Solver = NS.Solver

-- ============================================================
-- THE PARTY DROP (DandersFrames/Features/MoverBridge.lua + MoverTargets.lua + DandersMover)
-- ------------------------------------------------------------
-- Field report against v5.4.0-alpha.12: party frames, Column layout, "Snap to
-- frames" on -- on release the frames teleport somewhere other than where they
-- were dragged, never the same place twice.
--
-- The cause: the party element was offered snap zones on ITS OWN FRAMES. "My
-- Party Frame", "First Party Frame" and "Last Party Frame" (MoverTargets.lua)
-- are frames INSIDE the party container, and the lib only recognised a target
-- as "the element itself" when it was the very same frame (Registry:
-- CanonicalId). So a drag near one of those seats snapped, and the drop
-- anchored the party frames to one of the party frames. The solve then read
-- that frame where the drag had ALREADY carried it and put the container beside
-- it again -- one drag-length further on -- and every later re-solve (the
-- container move re-solves everything anchored to the party frames) pushed it
-- again. Column layout makes the side seats a frame-width away, so an ordinary
-- sideways drag hits one.
--
-- This suite runs the REAL code, headless:
--   * MoverBridge.lua and MoverTargets.lua, registered with the real lib;
--   * the real Session drag (BeginDrag / DragTo / EndDrag);
--   * the real Proxy:ShowZones body (cut out of Proxy.lua by name), so the
--     zones a drag can snap to are the ones the game would build;
--   * the real DF:UpdateContainerPosition (Position.lua) and
--     DF:LightweightPositionPartyTestFrames (TestMode.lua), and SecureSort;
--   * the anchor-resolving frame model from test_session_raid_preview.lua, so
--     frameScale means something.
-- Every drop asserts the one thing the user sees: the frames end up exactly
-- under the slab where it was released, and stay there.
--
-- ☠ ONE LUA RUNTIME IS SHARED BY EVERY SUITE. Everything replaced here is put
-- back at the end.
-- ============================================================

local saved = {
    CreateFrame = CreateFrame, C_Timer = C_Timer, hooksecurefunc = hooksecurefunc,
    IsInRaid = IsInRaid, debugprofilestop = debugprofilestop,
    Proxy = NS.Proxy, Session = NS.Session, Grid = NS.Grid, db = NS.db, ready = R.ready,
}

local function permissive()
    local f = { _scripts = {}, _events = {} }
    function f:SetScript(name, fn) self._scripts[name] = fn end
    function f:GetScript(name) return self._scripts[name] end
    function f:RegisterEvent(e) self._events[e] = true end
    return setmetatable(f, { __index = function() return function() end end })
end

if not LibStub("DandersMover-1.0", true) then
    CreateFrame = function() return permissive() end
    SlashCmdList = SlashCmdList or {}
    local uiLib = LibStub:NewLibrary("DandersUI-1.0", 1)
    if uiLib then uiLib.NewHost = function() return permissive() end end
    load_addon_file("Core.lua")
    CreateFrame = saved.CreateFrame
end
local Mover = LibStub("DandersMover-1.0", true)
check(Mover ~= nil, "setup: the mover library is loaded")

-- ============================================================
-- FRAME MODEL (same model as test_session_raid_preview.lua)
-- ============================================================
local PX = { TOPLEFT = 0, LEFT = 0, BOTTOMLEFT = 0, TOP = 0.5, CENTER = 0.5, BOTTOM = 0.5,
             TOPRIGHT = 1, RIGHT = 1, BOTTOMRIGHT = 1 }
local PY = { TOPLEFT = 1, TOP = 1, TOPRIGHT = 1, LEFT = 0.5, CENTER = 0.5, RIGHT = 0.5,
             BOTTOMLEFT = 0, BOTTOM = 0, BOTTOMRIGHT = 0 }
local SW, SH = UIParent:GetWidth(), UIParent:GetHeight()

local function screenRectOf(f)
    if f == UIParent then return 0, 0, SW, SH end
    return f:ScreenRect()
end

local function GeoFrame(parent, name)
    local f = { _parent = parent, _scale = 1, _w = 0, _h = 0, _shown = true, _name = name }
    function f:SetScale(s) self._scale = s end
    function f:GetScale() return self._scale end
    function f:GetEffectiveScale()
        local p = self._parent
        return ((p and p ~= UIParent) and p:GetEffectiveScale() or 1) * self._scale
    end
    function f:SetSize(w, h) self._w, self._h = w, h end
    function f:SetWidth(w) self._w = w end
    function f:SetHeight(h) self._h = h end
    function f:GetSize() return self._w, self._h end
    function f:GetWidth() return self._w end
    function f:GetHeight() return self._h end
    function f:ClearAllPoints() self._pt = nil end
    function f:SetPoint(point, rel, relPoint, x, y)
        if type(rel) == "number" then rel, relPoint, x, y = nil, point, rel, relPoint end
        if rawget(self, "_pt") then return end
        self._pt = { point, rel or self._parent or UIParent, relPoint or point, x or 0, y or 0 }
    end
    function f:GetPoint()
        local p = rawget(self, "_pt")
        if not p then return nil end
        return p[1], p[2], p[3], p[4], p[5]
    end
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:SetShown(v) self._shown = v and true or false end
    function f:IsShown() return self._shown end
    function f:IsVisible()
        if not self._shown then return false end
        local p = self._parent
        if p and p ~= UIParent then return p:IsVisible() end
        return true
    end
    function f:ScreenRect()
        local p = rawget(self, "_pt")
        local e = self:GetEffectiveScale()
        local w, h = self._w * e, self._h * e
        if not p then return nil end
        local rl, rb, rw, rh = screenRectOf(p[2])
        if not rl then return nil end
        local ax = rl + PX[p[3]] * rw + p[4] * e
        local ay = rb + PY[p[3]] * rh + p[5] * e
        return ax - PX[p[1]] * w, ay - PY[p[1]] * h, w, h
    end
    function f:GetCenter()
        local l, b, w, h = self:ScreenRect()
        if not l then return nil end
        local e = self:GetEffectiveScale()
        return (l + w / 2) / e, (b + h / 2) / e
    end
    return setmetatable(f, { __index = function() return function() end end })
end

-- Independent union of the shown party test frames, straight off the model, in
-- UIParent units from UIParent CENTER (the lib's space).
local DFt = {}
local function framesCentre()
    local l, b, r, t
    for i = 0, 4 do
        local f = DFt.testPartyFrames[i]
        if f and f:IsShown() then
            local fl, fb, fw, fh = f:ScreenRect()
            fl, fb = fl - SW / 2, fb - SH / 2
            local fr, ft = fl + fw, fb + fh
            l = l and math.min(l, fl) or fl
            b = b and math.min(b, fb) or fb
            r = r and math.max(r, fr) or fr
            t = t and math.max(t, ft) or ft
        end
    end
    return (l + r) / 2, (b + t) / 2
end

-- ============================================================
-- A DF NAMESPACE WITH THE REAL PARTY BODIES
-- ============================================================
DFt.L = setmetatable({}, { __index = function(_, k) return k end })
local pdb, rdb = {}, { frameScale = 1 }
local PDB_DEFAULTS = {
    frameWidth = 120, frameHeight = 50, frameSpacing = 2, frameScale = 1,
    growDirection = "VERTICAL", growthAnchor = "START", sortEnabled = false,
}
local function resetPartyDB(over)
    wipe(pdb)
    for k, v in pairs(PDB_DEFAULTS) do pdb[k] = v end
    for k, v in pairs(over or {}) do pdb[k] = v end
end
resetPartyDB()
local records = {
    party = { point = "CENTER", x = 0, y = -325 },
    raid = { point = "CENTER", x = 0, y = -25 },
}
function DFt:GetRaidDB() return rdb end
function DFt:GetDB(mode) if mode == "raid" then return rdb end return pdb end
function DFt:GetFrameDB() return pdb end
function DFt:GetPositionRecord(mode)
    records[mode] = records[mode] or { point = "CENTER", x = 0, y = 0 }
    return records[mode]
end
function DFt:SetPositionRecord(mode, pos)
    local rec = self:GetPositionRecord(mode)
    if rec ~= pos then rec.point, rec.x, rec.y = pos.point, pos.x, pos.y end
end
function DFt:Debug() end
function DFt:MakeDebugPrinter() return function() end end
function DFt:DebugActive() return false end
function DFt:SnapPointToPixelGrid() end
function DFt:SetPixelPerfectSize(frame, w, h) frame:SetSize(w, h) end
function DFt:GetTestUnitData() return {} end
function DFt:IsTestModeActive(scope) return scope == "party" end
-- Hook targets MoverBridge installs on. Bodies are irrelevant here.
function DFt:UpdateRaidContainerPosition() end
function DFt:SyncRaidMoverToContainer() end
function DFt:UpdateRaidLayout_Now() end
function DFt:FullProfileRefresh() end
function DFt:RefreshTestFramesWithLayout() end
function DFt:LightweightPositionRaidTestFrames() end

local function lift(src, header)
    local s = src:find(header, 1, true)
    check(s ~= nil, "setup: found " .. header)
    if not s then return end
    local e = src:find("\nend\r?\n", s)
    local body = src:sub(s, e + 4)
    local chunk = assert(loadstring("local DF = ...\n" .. body, "@" .. header))
    chunk(DFt)
end
lift(df_file_source("Frames/Position.lua"), "function DF:UpdateContainerPosition()")
lift(options_file_source("TestMode/TestMode.lua"), "function DF:LightweightPositionPartyTestFrames(testFrameCount)")

-- The live container (empty behind the preview, as in a session) and the test
-- container with its five-frame pool, [0] = the player.
DFt.container = GeoFrame(UIParent, "container")
DFt.container:SetSize(120, 258)
DFt.testPartyContainer = GeoFrame(UIParent, "testPartyContainer")
DFt.testPartyFrames = {}
for i = 0, 4 do DFt.testPartyFrames[i] = GeoFrame(DFt.testPartyContainer, "party" .. i) end

-- Timers are QUEUED and drained by the test that wants them.
local timers = {}
local function drain()
    local n = 0
    while #timers > 0 and n < 50 do
        local t = table.remove(timers, 1)
        t()
        n = n + 1
    end
end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end,
            NewTicker = function() return { Cancel = function() end } end }
CreateFrame = function() return permissive() end
IsInRaid = function() return false end
debugprofilestop = debugprofilestop or function() return 0 end
hooksecurefunc = hooksecurefunc or function(t, name, fn)
    local orig = t[name]
    t[name] = function(...)
        local a, b, c, d = orig(...)
        fn(...)
        return a, b, c, d
    end
end
local ownHook = saved.hooksecurefunc == nil

load_df_file_into("Features/SecureSort.lua", DFt)
check(DFt.SecureSort and DFt.SecureSort.PositionFrameToSlot, "setup: SecureSort loaded")

-- The real Proxy:ShowZones, cut out of Proxy.lua. Its two file-local helpers
-- (the zone highlight frames) are handed in as no-ops: this suite reads the
-- zones it builds, not how they are painted.
local P = { dragZones = {}, zones = {}, zoneCount = 0,
            RefreshAll = function() end, Highlight = function() end, Refresh = function() end,
            ShowToast = function() end, SnapTether = function() end, Remove = function() end,
            RemoveAddon = function() end, UpdateTethers = function() end,
            SyncMany = function() return true end }
do
    local src = mover_file_source("Proxy.lua")
    local header = "function P:ShowZones(el)"
    local s = src:find(header, 1, true)
    check(s ~= nil, "setup: found " .. header)
    local e = src:find("\nend\r?\n", s)
    local chunk = assert(loadstring("local P, NS, Registry, Solver, zoneFrame, clearZone = ...\n"
        .. src:sub(s, e + 4), "@" .. header))
    chunk(P, NS, R, Solver, function() return permissive() end, function() end)
end
NS.Proxy = P
R.ready = true
load_df_file_into("Features/MoverBridge.lua", DFt)
local Bridge = DFt.MoverBridge
check(Bridge ~= nil, "setup: MoverBridge loaded against the real lib")
load_df_file_into("Features/MoverTargets.lua", DFt)
check(DFt.MoverTargets ~= nil, "setup: MoverTargets loaded against the real lib")

local function layout(n)
    for i = 0, 4 do DFt.testPartyFrames[i]:SetShown(i < n) end
    DFt:UpdateContainerPosition()
    DFt:LightweightPositionPartyTestFrames(n)
end
layout(5)
Bridge:Init()
drain()
local party = R:Get("DandersFrames:party")
check(party ~= nil and party.visibleOffset ~= nil, "setup: the party element is registered with a visibleOffset")
check(R:GetTarget("DandersFrames:party.me") ~= nil, "setup: the party's own-frame targets are registered")

-- A foreign target to snap to, so a LEGITIMATE snap is checked at every scale too.
R:RegisterAddon("PDT", { title = "PDT" })
local box = { x = -520, y = 260, w = 160, h = 40 }
Mover:RegisterAnchorTarget("PDT", "box", { title = "box", frame = FakeFrame(440, 800, 160, 40),
    getRect = function() return box end })

NS.db = { snapToFrames = false, snapToGrid = false, snapToScreen = false, snapDistance = 25, addons = {} }
NS.Grid = setmetatable({}, { __index = function() return function() end end })
do
    local prevTimer = C_Timer
    C_Timer = { After = function() end }
    load_addon_file("Session.lua")
    C_Timer = prevTimer
end
local Sess = NS.Session
Sess.undo = LibStub("DandersUndo-1.0"):New({ limit = 50 })
Sess.active = true

local function near(a, b) return math.abs((a or 1e9) - (b or -1e9)) < 0.01 end

local SCALES = { 1, 0.8, 1.3 }
local LAYOUTS = { { "Column", "VERTICAL" }, { "Row", "HORIZONTAL" } }

-- One drag: pick up the slab, move it through a few points to (tx, ty), let go.
-- Returns where the slab was released and whether it snapped.
local function dragTo(tx, ty)
    Sess:BeginDrag(party)
    P:ShowZones(party)
    local sx, sy = R:GetRect(party).x, R:GetRect(party).y
    local fx, fy, zone
    for step = 1, 4 do
        local f = step / 4
        fx, fy, zone = Sess:DragTo(party, sx + (tx - sx) * f, sy + (ty - sy) * f)
    end
    Sess:EndDrag(party, fx, fy, zone)
    drain()
    -- Whatever re-solves after the drop -- the layout sweep, a roster refresh --
    -- must not move the frames either.
    Mover:RefreshMovedTargets("DandersFrames", Bridge:SubTargetKeys("party"))
    Mover:Apply("DandersFrames", "party")
    drain()
    return fx, fy, zone
end

-- ============================================================
-- 1. FREE DROPS: scale 1 / 0.8 / 1.3, Column and Row, 5 and 3 frames
-- The frames land exactly under the released slab. (Hypotheses "scale
-- conversion" and "Row size applied to Column": neither reproduces.)
-- ============================================================
do
    local bad, total = 0, 0
    local targets = { { 300, 100 }, { -400, -200 }, { 37, -411 }, { 610, 330 } }
    for _, lay in ipairs(LAYOUTS) do
        for _, scale in ipairs(SCALES) do
            for _, n in ipairs({ 5, 3 }) do
                resetPartyDB({ growDirection = lay[2], frameScale = scale })
                records.party.point, records.party.x, records.party.y, records.party.anchor = "CENTER", 0, -325, nil
                layout(n)
                NS.db.snapToFrames = false
                for _, t in ipairs(targets) do
                    local fx, fy = dragTo(t[1], t[2])
                    local cx, cy = framesCentre()
                    total = total + 1
                    if not (near(cx, fx) and near(cy, fy)) then
                        bad = bad + 1
                        if bad <= 3 then
                            check(false, string.format("free drop %s scale %.1f n=%d: slab (%.2f, %.2f), frames (%.2f, %.2f)",
                                lay[1], scale, n, fx, fy, cx, cy))
                        end
                    end
                end
            end
        end
    end
    eq(bad, 0, string.format("free drop: the frames land under the slab in all %d drops", total))
end

-- ============================================================
-- 2. SNAP ON: every zone the drag offers, Column and Row, every scale
-- Drive the slab onto each zone ShowZones built and drop it there. Before the
-- fix the party's own frames offered zones, and a drop on one of them sent the
-- frames a drag-length (or several) past the slab.
-- ============================================================
do
    local bad, total, own, foreign = 0, 0, 0, 0
    for _, lay in ipairs(LAYOUTS) do
        for _, scale in ipairs(SCALES) do
            resetPartyDB({ growDirection = lay[2], frameScale = scale })
            records.party.point, records.party.x, records.party.y, records.party.anchor = "CENTER", 0, -325, nil
            layout(5)
            NS.db.snapToFrames = true
            -- The zones as the drag would see them from the start position.
            P:ShowZones(party)
            local zones = {}
            for i, z in ipairs(P.dragZones) do
                zones[i] = { target = z.target, edge = z.edge, align = z.align, x = z.x, y = z.y }
            end
            for _, z in ipairs(zones) do
                if z.target:find("^DandersFrames:party") then own = own + 1 else foreign = foreign + 1 end
                records.party.point, records.party.x, records.party.y, records.party.anchor = "CENTER", 0, -325, nil
                layout(5)
                local fx, fy, zone = dragTo(z.x, z.y)
                local cx, cy = framesCentre()
                total = total + 1
                if not (zone and near(cx, fx) and near(cy, fy)) then
                    bad = bad + 1
                    if bad <= 3 then
                        check(false, string.format("snap drop %s scale %.1f onto %s %s/%s: slab (%.2f, %.2f), frames (%.2f, %.2f)",
                            lay[1], scale, z.target, z.edge, z.align, fx or 0, fy or 0, cx, cy))
                    end
                end
            end
        end
    end
    check(foreign > 0, "snap drop: the foreign box offered zones (the check below is not vacuous)")
    eq(own, 0, "snap drop: the party is never offered a zone on its own frames")
    eq(bad, 0, string.format("snap drop: the frames land under the slab on all %d zones", total))
    NS.db.snapToFrames = false
end

-- ============================================================
-- 3. EVERY OTHER WAY IN IS CLOSED TOO
-- The picker, link-drag, EndDrag and the Anchor verb all ask WouldCreateCycle.
-- ============================================================
for _, key in ipairs({ "party.me", "party.first", "party.last", "party.slot1", "party.slot5" }) do
    check(R:WouldCreateCycle("DandersFrames:party", "DandersFrames:" .. key),
        "cycle: anchoring the party frames to " .. key .. " is refused")
end
check(not R:WouldCreateCycle("DandersFrames:party", "PDT:box"), "cycle: a foreign target is still allowed")
check(not R:WouldCreateCycle("DandersFrames:raid", "DandersFrames:party.me"),
    "cycle: the RAID frames may still anchor to a party frame")

-- A record that already carries the self-anchor (saved by an affected build)
-- holds where it is instead of running away on every re-solve.
do
    resetPartyDB({ growDirection = "VERTICAL", frameScale = 0.8 })
    records.party.point, records.party.x, records.party.y = "CENTER", 100, -200
    records.party.anchor = { target = "DandersFrames:party.me", edge = "right", align = "start", offsetX = 0, offsetY = 0 }
    layout(5)
    local cx0, cy0 = framesCentre()
    for _ = 1, 3 do
        Mover:Apply("DandersFrames", "party")
        Mover:RefreshMovedTargets("DandersFrames", Bridge:SubTargetKeys("party"))
        drain()
    end
    local cx1, cy1 = framesCentre()
    check(near(cx0, cx1) and near(cy0, cy1),
        string.format("self-anchor: a saved self-anchor holds (was %.2f, %.2f; now %.2f, %.2f)", cx0, cy0, cx1, cy1))
    records.party.anchor = nil
end

-- ============================================================
-- 4. MEASURING A TARGET ALLOCATES NOTHING (MoverTargets' rect reuse)
-- The lib measures every DF target on every layout sweep, twice, and a party
-- drag runs that sweep every frame. Each target now measures into ITS OWN rect
-- table, overwritten in place. Safe only because the lib never holds the raw
-- return -- pinned here against the real lib, not just asserted in a comment.
-- ============================================================
do
    resetPartyDB({ growDirection = "VERTICAL", frameScale = 1 })
    records.party.point, records.party.x, records.party.y, records.party.anchor = "CENTER", 0, -325, nil
    layout(5)
    local id2 = "DandersFrames:party.slot2"
    local slot2 = R:GetTarget(id2)
    local slot3 = R:GetTarget("DandersFrames:party.slot3")
    local me = R:GetTarget("DandersFrames:party.me")
    local a, b = slot2.getRect(), slot2.getRect()
    check(a ~= nil and a == b, "rect reuse: a target hands back its own rect table every measure")
    check(slot3.getRect() ~= a and me.getRect() ~= a, "rect reuse: ...one table per target, never shared")

    -- The lib copies before it keeps anything.
    local copy = R:GetRect(slot2)
    check(copy ~= a and near(copy.x, a.x) and near(copy.y, a.y) and near(copy.w, a.w),
          "rect reuse: Registry:GetRect hands the lib a COPY")
    Mover:RefreshMovedTargets("DandersFrames", Bridge:SubTargetKeys("party"))
    local stamp = NS.lastRect[id2]
    check(stamp ~= nil and stamp ~= a, "rect reuse: the sweep's stamp is its own table")
    local sx, sy = stamp.x, stamp.y

    -- A real move: wider spacing pushes slot 2 down. The reused table follows, the
    -- COPY taken earlier does not, and the sweep still sees the move.
    pdb.frameSpacing = 40
    layout(5)
    local moved = Mover:RefreshMovedTargets("DandersFrames", Bridge:SubTargetKeys("party"))
    check(moved > 0, "rect reuse: the sweep still sees a slot move")
    check(not near(a.y, sy), "rect reuse: ...the target's own table now holds the new rect")
    check(near(copy.y, sy), "rect reuse: ...while the copy the lib took earlier is untouched")
    check(near(NS.lastRect[id2].y, a.y) and near(NS.lastRect[id2].x, sx),
          "rect reuse: ...and the sweep re-stamped the new position")
    eq(Mover:RefreshMovedTargets("DandersFrames", Bridge:SubTargetKeys("party")), 0,
       "rect reuse: ...and goes quiet on the next pass")

    -- ALLOCATION: N measures of every party target, against a baseline that does
    -- the same frame lookups and method calls without building a rect. The excess
    -- is what the rects cost; a fresh 4-field table per measure is ~100 bytes.
    local ids = {}
    for _, key in ipairs(Bridge:SubTargetKeys("party")) do
        local t = R:GetTarget("DandersFrames:" .. key)
        if t and t.getRect() then ids[#ids + 1] = t end
    end
    check(#ids >= 8, "rect reuse: (the allocation check measures " .. #ids .. " live targets)")
    local N = 500
    collectgarbage("collect")
    collectgarbage("stop")
    local k0 = collectgarbage("count")
    for _ = 1, N do
        for _, t in ipairs(ids) do
            local f = t.getFrame()
            if f then f:IsShown(); f:GetCenter(); f:GetSize(); f:GetEffectiveScale() end
            UIParent:GetEffectiveScale(); UIParent:GetCenter()
        end
    end
    local base = collectgarbage("count") - k0
    k0 = collectgarbage("count")
    for _ = 1, N do
        for _, t in ipairs(ids) do t.getRect() end
    end
    local used = collectgarbage("count") - k0
    collectgarbage("restart")
    check(used - base < 16, string.format(
        "rect reuse: %d measures allocate no rect tables (excess %.1f KB over baseline)",
        N * #ids, used - base))

    -- The per-GROUP measure (raid, live only -- not modelled here) is table-free too.
    local mt = df_file_source("Features/MoverTargets.lua")
    check(mt:find("return { x =", 1, true) == nil and mt:find("union(acc", 1, true) == nil,
          "rect reuse: no measure in MoverTargets builds a rect or union table")
    pdb.frameSpacing = PDB_DEFAULTS.frameSpacing
    layout(5)
end

-- ============================================================
-- TEARDOWN
-- ============================================================
Sess.active = false
Sess.undo = nil
Mover.UnregisterCallback(Bridge, "Unlocked")
Mover.UnregisterCallback(Bridge, "Locked")
Mover:UnregisterAddon("DandersFrames")
Mover:UnregisterAddon("PDT")
CreateFrame, C_Timer, IsInRaid = saved.CreateFrame, saved.C_Timer, saved.IsInRaid
debugprofilestop = saved.debugprofilestop
if ownHook then hooksecurefunc = nil end
NS.Proxy, NS.Session, NS.Grid, NS.db = saved.Proxy, saved.Session, saved.Grid, saved.db
R.ready = saved.ready
