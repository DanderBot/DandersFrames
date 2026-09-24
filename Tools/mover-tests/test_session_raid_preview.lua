local NS = ...
local R = NS.Registry

-- ============================================================
-- THE RAID MOVER PREVIEW (DandersFrames/Features/MoverBridge.lua + DandersMover)
-- ------------------------------------------------------------
-- Three field reports against v5.4.0-alpha.12 (Aphoex):
--   1. The raid preview is always the size of FORTY frames, whatever the test-mode
--      count or roster, and it stays on screen while the frames do not.
--   2. With Groups Before Wrap below 8, Center Left / Center Right "don't work".
--   3. The coordinates on the mover disagree with the panel's.
--
-- This suite runs the REAL maths end to end, headless:
--   * MoverBridge.lua itself, registered with the real DandersMover lib;
--   * SecureSort.lua (the grouped and flat positioners test mode uses);
--   * the real bodies of DF:UpdateRaidContainerPosition (Position.lua),
--     DF:ComputeRaidMainGroupAnchorOffset / ComputeRaidContainerCompensation
--     (Headers.lua) and DF:LightweightPositionRaidTestFrames[Flat]
--     (TestMode.lua), lifted out of their files by name;
--   * a small anchor-resolving frame model, so a SetPoint chain from UIParent
--     through the test container to each test frame produces real centres.
-- Nothing below restates the layout maths it checks except the plain
-- closed-form sizes in section 1, which are the independent expectation.
--
-- ☠ ONE LUA RUNTIME IS SHARED BY EVERY SUITE. This file sorts after the
-- registry suites (which load Core.lua and must get there first), loads what it
-- needs only when a filtered run has not, and puts back every global and
-- namespace field it replaces.
-- ============================================================

local saved = {
    CreateFrame = CreateFrame, C_Timer = C_Timer, hooksecurefunc = hooksecurefunc,
    IsInRaid = IsInRaid, debugprofilestop = debugprofilestop, StaticPopupDialogs = StaticPopupDialogs,
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
-- FRAME MODEL
-- One anchor per frame (all this layout ever uses), resolved on read. Offsets are
-- in the frame's own scaled units and sizes are scaled by the effective scale,
-- exactly as the client does, so a frameScale other than 1 means something.
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
        if rawget(self, "_pt") then return end                      -- the model keeps the first anchor
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

-- A frame's rect in UIParent units from UIParent CENTER -- the lib's space.
local function uiRect(f)
    local l, b, w, h = f:ScreenRect()
    return { l = l - SW / 2, b = b - SH / 2, r = l + w - SW / 2, t = b + h - SH / 2 }
end

-- Independent union of the visible test frames, straight off the model.
local function framesUnion(DFt)
    local acc
    for i = 1, 40 do
        local f = DFt.testRaidFrames[i]
        if f and f:IsVisible() then
            local r = uiRect(f)
            if not acc then acc = { l = r.l, b = r.b, r = r.r, t = r.t }
            else
                acc.l, acc.r = math.min(acc.l, r.l), math.max(acc.r, r.r)
                acc.b, acc.t = math.min(acc.b, r.b), math.max(acc.t, r.t)
            end
        end
    end
    return acc
end

local function near(a, b, msg) check(math.abs((a or 1e9) - (b or -1e9)) < 0.01, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end

-- ============================================================
-- A DF NAMESPACE WITH THE REAL LAYOUT BODIES
-- ============================================================
local DFt = {}
DFt.L = setmetatable({}, { __index = function(_, k) return k end })
local rdb, pdb = {}, {}
local RDB_DEFAULTS = {
    frameWidth = 80, frameHeight = 40, frameSpacing = 2, frameScale = 1,
    raidGroupSpacing = 10, raidRowColSpacing = 30, raidGroupsPerRow = 8,
    growDirection = "HORIZONTAL", raidGroupAnchor = "START", raidPlayerAnchor = "START",
    raidGroupRowGrowth = "START", raidGroupCenterMode = "ALL", raidUseGroups = true,
    sortEnabled = false, raidPlayersPerRow = 5,
    raidFlatHorizontalSpacing = 2, raidFlatVerticalSpacing = 2,
}
local function resetRaidDB(over)
    wipe(rdb)
    for k, v in pairs(RDB_DEFAULTS) do rdb[k] = v end
    for k, v in pairs(over or {}) do rdb[k] = v end
end
resetRaidDB()
local records = {
    raid = { point = "CENTER", x = 0, y = -25 },
    party = { point = "CENTER", x = 0, y = -325 },
}
function DFt:GetRaidDB() return rdb end
function DFt:GetDB(mode) if mode == "raid" then return rdb end return pdb end
function DFt:GetFrameDB() return rdb end
function DFt:GetPositionRecord(mode)
    records[mode] = records[mode] or { point = "CENTER", x = 0, y = 0 }
    return records[mode]
end
function DFt:SetPositionRecord(mode, pos)
    -- The lib mutates the live record in place; DF only normalises it.
    local rec = self:GetPositionRecord(mode)
    if rec ~= pos then rec.point, rec.x, rec.y = pos.point, pos.x, pos.y end
end
function DFt:Debug() end
function DFt:MakeDebugPrinter() return function() end end
function DFt:DebugActive() return false end
function DFt:Say() end
function DFt:SnapPointToPixelGrid() end
function DFt:SetPixelPerfectSize(frame, w, h) frame:SetSize(w, h) end
function DFt:GetTestUnitData() return {} end
function DFt:SortActiveGroupListByDisplayOrder(list) table.sort(list) end
function DFt:IsTestModeActive(scope) return scope == "raid" end
-- Hook targets MoverBridge installs on. Bodies are irrelevant here.
function DFt:SyncRaidMoverToContainer() end
function DFt:UpdateContainerPosition() end
function DFt:UpdateRaidLayout_Now() end
function DFt:FullProfileRefresh() end
function DFt:RefreshTestFramesWithLayout() end
function DFt:LightweightPositionPartyTestFrames() end

-- Lift one `function DF:Name(...)` body out of an addon file, by its header line.
local function lift(src, header)
    local s = src:find(header, 1, true)
    check(s ~= nil, "setup: found " .. header)
    if not s then return end
    local e = src:find("\nend\r?\n", s)
    local body = src:sub(s, e + 4)
    local chunk = assert(loadstring("local DF, ShortCaller = ...\n" .. body, "@" .. header))
    chunk(DFt, function() return "" end)
end
local headers = df_file_source("Frames/Headers.lua")
lift(headers, "function DF:ComputeRaidContainerCompensation()")
lift(headers, "function DF:ComputeRaidMainGroupAnchorOffset()")
lift(df_file_source("Frames/Position.lua"), "function DF:UpdateRaidContainerPosition()")
local testMode = options_file_source("TestMode/TestMode.lua")
lift(testMode, "function DF:LightweightPositionRaidTestFrames(testFrameCount)")
lift(testMode, "function DF:UpdateTestGroupExtents()")
lift(testMode, "function DF:LightweightPositionRaidTestFramesFlat(testFrameCount)")

-- The frames: a live container (hidden behind the preview, as in a session) and the
-- test container with its forty-frame pool.
DFt.raidContainer = GeoFrame(UIParent, "raidContainer")
DFt.raidContainer:SetSize(600, 400)
DFt.testRaidContainer = GeoFrame(UIParent, "testRaidContainer")
DFt.testRaidContainer:SetSize(600, 400)
DFt.testRaidFrames = {}
for i = 1, 40 do DFt.testRaidFrames[i] = GeoFrame(DFt.testRaidContainer, "test" .. i) end

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
IsInRaid = function() return true end
debugprofilestop = debugprofilestop or function() return 0 end
hooksecurefunc = hooksecurefunc or function(t, name, fn)
    local orig = t[name]
    t[name] = function(...)
        local a, b, c, d = orig(...)
        fn(...)
        return a, b, c, d
    end
end
-- The hooksecurefunc above is only used when the harness has none; remember whether
-- this suite put it there so it is removed again.
local ownHook = saved.hooksecurefunc == nil

-- SecureSort (real) with its two event frames swallowed by the permissive stub.
load_df_file_into("Features/SecureSort.lua", DFt)
check(DFt.SecureSort and DFt.SecureSort.CalculateRaidGroupPosition, "setup: SecureSort loaded")

-- The bridge. Proxy is replaced by a recorder so the sweep's re-measure calls are
-- observable; the lib reads NS.Proxy at call time.
local synced = {}
NS.Proxy = {
    SyncMany = function(_, ids) for _, id in ipairs(ids) do synced[id] = (synced[id] or 0) + 1 end return true end,
    Refresh = function() end, RefreshAll = function() end, Highlight = function() end,
    dragZones = {}, ShowToast = function() end, Remove = function() end, RemoveAddon = function() end,
}
R.ready = true
-- MoverBridge caches CreateFrame at load, and Init makes the roster-event frame
-- with it: record what it makes so that frame can be found and fired.
local made = {}
CreateFrame = function() local f = permissive(); made[#made + 1] = f; return f end
load_df_file_into("Features/MoverBridge.lua", DFt)
local Bridge = DFt.MoverBridge
check(Bridge ~= nil, "setup: MoverBridge loaded against the real lib")

-- Lay the preview out for `count` test frames: the frame visibility half of
-- DF:UpdateRaidTestFrames, then the real positioner.
local function layout(count)
    for i = 1, 40 do DFt.testRaidFrames[i]:SetShown(i <= count) end
    DFt:UpdateRaidContainerPosition()
    DFt:LightweightPositionRaidTestFrames(count)
end
layout(20)
Bridge:Init()
local rosterFrame
for _, f in ipairs(made) do if f._events.GROUP_ROSTER_UPDATE then rosterFrame = f end end
check(rosterFrame ~= nil, "setup: found the bridge's GROUP_ROSTER_UPDATE frame")
drain()
local raid = R:Get("DandersFrames:raid")
check(raid ~= nil and raid.getRect ~= nil, "setup: the raid element is registered with a getRect")
check(raid and raid.visibleOffset ~= nil, "setup: ...and a visibleOffset")

-- ============================================================
-- 1. THE PREVIEW IS THE FRAMES THAT SHOW
-- Closed-form expectation for full groups: horizontal growth stacks a group's five
-- frames DOWN and lines groups up ACROSS, wrapping into rows; vertical growth is the
-- transpose. Before the fix the rect was the container, which is sized for all eight
-- groups whatever the count -- every n < 40 row below failed.
-- ============================================================
local function expectedGrouped(n, wrap, horizontal)
    local g = n / 5
    local along = math.min(g, wrap)
    local across = math.ceil(g / wrap)
    if horizontal then
        local groupH = 5 * 40 + 4 * 2
        return along * 80 + (along - 1) * 10, across * groupH + (across - 1) * 30
    else
        local groupW = 5 * 80 + 4 * 2
        return across * groupW + (across - 1) * 30, along * 40 + (along - 1) * 10
    end
end

for _, grow in ipairs({ "HORIZONTAL", "VERTICAL" }) do
    for _, wrap in ipairs({ 8, 5, 2 }) do
        for _, n in ipairs({ 10, 20, 40 }) do
            resetRaidDB({ growDirection = grow, raidGroupsPerRow = wrap })
            layout(n)
            local r = R:GetRect(raid)
            local w, h = R:GetSize(raid)
            local ew, eh = expectedGrouped(n, wrap, grow == "HORIZONTAL")
            local tag = string.format("size %s wrap %d, %d frames", grow, wrap, n)
            near(r and r.w, ew, tag .. ": preview width is the frames'")
            near(r and r.h, eh, tag .. ": preview height is the frames'")
            near(w, ew, tag .. ": GetSize (the drag clamp's size) agrees")
            local u = framesUnion(DFt)
            near(r and r.x, (u.l + u.r) / 2, tag .. ": preview sits on the frames (x)")
            near(r and r.y, (u.b + u.t) / 2, tag .. ": preview sits on the frames (y)")
        end
    end
end

-- Flat layout: five per row, rows grow down. Same rule, different positioner.
for _, n in ipairs({ 10, 20, 40 }) do
    resetRaidDB({ raidUseGroups = false })
    layout(n)
    local r = R:GetRect(raid)
    local rows = math.ceil(n / 5)
    local tag = string.format("size flat, %d frames", n)
    near(r and r.w, 5 * 80 + 4 * 2, tag .. ": preview width is the frames'")
    near(r and r.h, rows * 40 + (rows - 1) * 2, tag .. ": preview height is the frames'")
end

-- A frame scale other than 1: the rect is in UIParent units, so it scales.
resetRaidDB({ frameScale = 0.5 })
layout(20)
do
    local r = R:GetRect(raid)
    local ew, eh = expectedGrouped(20, 8, true)
    near(r and r.w, ew * 0.5, "size at scale 0.5: width in UIParent units")
    near(r and r.h, eh * 0.5, "size at scale 0.5: height in UIParent units")
end

-- ============================================================
-- 2. THE PREVIEW FOLLOWS WHILE THE MOVER IS OPEN
-- A test-count change re-runs the positioner, which MoverBridge hooks; the next
-- frame's sweep re-measures the raid rect and re-syncs its slab. A roster change
-- moves nothing through a hooked function at all, so the roster door has to ask.
-- ============================================================
resetRaidDB()
layout(20)
drain()
wipe(synced)
Mover:RefreshMovedTargets("DandersFrames", { "raid" })     -- stamp the 20-frame rect
wipe(synced)
for i = 1, 40 do DFt.testRaidFrames[i]:SetShown(i <= 10) end
DFt:LightweightPositionRaidTestFrames(10)
drain()
check((synced["DandersFrames:raid"] or 0) > 0, "follow: a test-count change re-syncs the raid slab next frame")
near(R:GetRect(raid).w, expectedGrouped(10, 8, true), "follow: ...to the 10-frame width")

wipe(synced)
for i = 1, 40 do DFt.testRaidFrames[i]:SetShown(i <= 15) end     -- nothing hooked runs
rosterFrame._scripts.OnEvent(rosterFrame, "GROUP_ROSTER_UPDATE")
drain()
check((synced["DandersFrames:raid"] or 0) > 0, "follow: a roster change (frames shown/hidden, no layout call) re-syncs the raid slab")
near(R:GetRect(raid).w, expectedGrouped(15, 8, true), "follow: ...to the 15-frame width")

-- ============================================================
-- 3. ANCHORING PUTS THE FRAMES ON THE SEAT, EVERY GROUPS ANCHOR, EVERY WRAP
-- The raid record places the CONTAINER; the frames sit inside it. A solve used to
-- write the seat's centre straight into the record, so the container -- not the
-- frames -- landed there, off by the frames' offset inside it (and by Center Mode
-- Fixed's anchor shift on top). Every Groups Anchor cell, wrap 1-8, both growth
-- directions, both Center Modes: the frames' top-left must sit exactly under the
-- box's bottom-left with the lib's 2px spacing.
-- ============================================================
R:RegisterAddon("RPT", { title = "RPT" })
local box = { x = -500, y = 300, w = 120, h = 40 }
Mover:RegisterAnchorTarget("RPT", "box", { title = "box", frame = FakeFrame(960, 540, 10, 10),
    getRect = function() return box end })

local cells = {
    { "START", "START" }, { "CENTER", "START" }, { "END", "START" },
    { "START", "END" }, { "CENTER", "END" }, { "END", "END" },
}
local bad = 0
local checked = 0
for _, grow in ipairs({ "HORIZONTAL", "VERTICAL" }) do
    for wrap = 1, 8 do
        for _, cell in ipairs(cells) do
            for _, mode in ipairs({ "ALL", "MAIN" }) do
                for _, n in ipairs({ 10, 20, 40 }) do
                    resetRaidDB({ growDirection = grow, raidGroupsPerRow = wrap,
                                  raidGroupAnchor = cell[1], raidGroupRowGrowth = cell[2],
                                  raidGroupCenterMode = mode })
                    records.raid.point, records.raid.x, records.raid.y = "CENTER", 0, -25
                    records.raid.anchor = { target = "RPT:box", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 }
                    layout(n)
                    Mover:Apply("DandersFrames", "raid")
                    local u = framesUnion(DFt)
                    checked = checked + 1
                    local okL = math.abs(u.l - (box.x - box.w / 2)) < 0.01
                    local okT = math.abs(u.t - (box.y - box.h / 2 - 2)) < 0.01
                    if not (okL and okT) then
                        bad = bad + 1
                        if bad <= 3 then
                            check(false, string.format("anchor %s wrap %d %s/%s %s n=%d: frames at l=%.2f t=%.2f, seat l=%.2f t=%.2f",
                                grow, wrap, cell[1], cell[2], mode, n, u.l, u.t, box.x - box.w / 2, box.y - box.h / 2 - 2))
                        end
                    end
                    -- A second solve is a no-op: the offset does not drift the record.
                    local x0, y0 = records.raid.x, records.raid.y
                    Mover:Apply("DandersFrames", "raid")
                    if math.abs(records.raid.x - x0) > 0.01 or math.abs(records.raid.y - y0) > 0.01 then
                        bad = bad + 1
                        if bad <= 3 then check(false, "anchor: a repeat solve moved the record") end
                    end
                end
            end
        end
    end
end
eq(bad, 0, string.format("anchor: the frames land on the seat in all %d layouts", checked))
records.raid.anchor = nil

-- ============================================================
-- 4. CENTER LEFT / CENTER RIGHT (Rows growth, centre align) AT WRAP < 8
-- With the preview measuring the frames, the preview IS where the frames are for
-- every cell. What the cells themselves do (Headers.lua / SecureSort maths, which
-- this fix did not touch) is pinned here so a regression in either shows up:
--   * the frames stay inside the reserved container, both cells, every wrap;
--   * Default: the populated block is centred, and the wrap cell sets which side
--     the FIRST group starts on (left for Center Left, right for Center Right);
--   * Fixed: the first group's column is nailed to the anchor (the record's x), and
--     the overflow extends to the side the cell names.
-- ============================================================
local function groupCentreX(g)          -- group g's frames, Rows growth: one row of five
    local l, r
    for i = (g - 1) * 5 + 1, g * 5 do
        local fr = uiRect(DFt.testRaidFrames[i])
        l = l and math.min(l, fr.l) or fr.l
        r = r and math.max(r, fr.r) or fr.r
    end
    return (l + r) / 2
end
local inside, sides, pinned = 0, 0, 0
local total = 0
for wrap = 1, 7 do
    for _, rowGrowth in ipairs({ "START", "END" }) do
        for _, mode in ipairs({ "ALL", "MAIN" }) do
            for _, n in ipairs({ 10, 20, 40 }) do
                resetRaidDB({ growDirection = "VERTICAL", raidGroupsPerRow = wrap, raidGroupAnchor = "CENTER",
                              raidGroupRowGrowth = rowGrowth, raidGroupCenterMode = mode })
                records.raid.point, records.raid.x, records.raid.y = "CENTER", 37, -25
                layout(n)
                total = total + 1
                local c = uiRect(DFt.testRaidContainer)
                local u = framesUnion(DFt)
                if u.l >= c.l - 0.01 and u.r <= c.r + 0.01 and u.b >= c.b - 0.01 and u.t <= c.t + 0.01 then
                    inside = inside + 1
                end
                local groups = n / 5
                local cols = math.ceil(groups / wrap)
                local first, last = groupCentreX(1), groupCentreX(groups)
                if cols > 1 then
                    -- START = first group on the left of the last; END = on the right.
                    if (rowGrowth == "START") == (first < last) then sides = sides + 1 end
                else
                    sides = sides + 1   -- one column: no side to pick
                end
                if mode == "MAIN" then
                    if math.abs(first - 37) < 0.01 then pinned = pinned + 1 end
                else
                    pinned = pinned + 1
                end
            end
        end
    end
end
eq(inside, total, "center L/R: the frames stay inside the reserved area, every wrap < 8")
eq(sides, total, "center L/R: the wrap cell decides which side the first group starts on")
eq(pinned, total, "center L/R Fixed: the first group's column sits on the anchor")

-- ============================================================
-- 5. CLAMPING: THE DRAG CLAMP HOLDS THE FRAMES, NOT THE RESERVED BOX
-- DragTo clamps the element's visible rect (GetSize). With the old container rect a
-- drag into the bottom-right corner stopped the forty-frame box at the edge and left
-- a 20-frame raid (top-left of the box) far from it; now the frames themselves go
-- flush to the corner and no further.
-- ============================================================
do
    NS.db = { snapToFrames = false, snapToGrid = false, snapToScreen = false, addons = {} }
    NS.Grid = setmetatable({}, { __index = function() return function() end end })
    StaticPopupDialogs = StaticPopupDialogs or {}
    local prevTimer = C_Timer
    C_Timer = { After = function() end }
    load_addon_file("Session.lua")
    C_Timer = prevTimer
    local Sess = NS.Session
    Sess.undo = LibStub("DandersUndo-1.0"):New({ limit = 10 })
    Sess.active = true

    resetRaidDB()
    records.raid.point, records.raid.x, records.raid.y, records.raid.anchor = "CENTER", 0, -25, nil
    layout(20)
    Sess:BeginDrag(raid)
    Sess:DragTo(raid, 5000, -5000)
    local u = framesUnion(DFt)
    near(u.r, SW / 2, "clamp: a drag to the corner puts the frames' right edge on the screen edge")
    near(u.b, -SH / 2, "clamp: ...and their bottom edge on the screen edge")
    Sess:EndDrag(raid, 5000, -5000, nil)

    -- ============================================================
    -- 6. THE 9-POINT PICKER DOES NOT MOVE THE FRAMES
    -- Re-expressing the record from a new point must leave the frames where they
    -- are. The size-based conversion assumed the record's point was a point OF the
    -- visible rect, which the raid container (bigger than its frames) is not.
    -- ============================================================
    records.raid.point, records.raid.x, records.raid.y = "CENTER", 0, -25
    layout(20)
    local before = framesUnion(DFt)
    for _, pt in ipairs({ "LEFT", "TOPRIGHT", "BOTTOM", "CENTER" }) do
        Sess:SetAnchorPoint(raid, pt)
        local after = framesUnion(DFt)
        eq(records.raid.point, pt, "point: the record takes the new point " .. pt)
        near(after.l, before.l, "point " .. pt .. ": the frames did not move (left)")
        near(after.t, before.t, "point " .. pt .. ": the frames did not move (top)")
    end

    Sess.active = false
    Sess.undo = nil
end

-- ============================================================
-- TEARDOWN
-- ============================================================
Mover.UnregisterCallback(Bridge, "Unlocked")
Mover.UnregisterCallback(Bridge, "Locked")
Mover:UnregisterAddon("DandersFrames")
Mover:UnregisterAddon("RPT")
CreateFrame, C_Timer, IsInRaid = saved.CreateFrame, saved.C_Timer, saved.IsInRaid
debugprofilestop, StaticPopupDialogs = saved.debugprofilestop, saved.StaticPopupDialogs
if ownHook then hooksecurefunc = nil end
NS.Proxy, NS.Session, NS.Grid, NS.db = saved.Proxy, saved.Session, saved.Grid, saved.db
R.ready = saved.ready
