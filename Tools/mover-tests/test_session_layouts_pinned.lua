local NS = ...
local R = NS.Registry
local Solver = NS.Solver

-- ============================================================
-- THE MOVER WITH AUTO LAYOUTS AND PINNED FRAMES, END TO END
-- ------------------------------------------------------------
-- Runs the REAL code, headless:
--   * the DandersMover lib (Registry, Solver, Core's resolver/sweep, Session's drag and
--     Discard);
--   * DandersFrames' bridge (Features/MoverBridge.lua), registered with the real lib;
--   * DF's raid position funnel and container placement, cut out of Frames/Position.lua
--     (GetPositionRecord / SetPositionRecord / UpdateRaidContainerPosition and the
--     layout-record helpers);
--   * the auto-layout routing primitives, cut out of Core/AutoProfiles.lua
--     (SetActiveLayoutRaidPair / ...Position / ...Record, NormalizeLayoutPositionRecord).
-- Around them: an anchor-resolving frame model, a raid DB with the same proxy shape as
-- DF:WrapDB, a stand-in for ApplyRuntimeProfile (overlay + FullProfileRefresh), and a
-- minimal raid pinned set. ⚠ The pinned set is a STUB of PinnedFrames' accessors, not the
-- real file: this suite checks how the lib, the bridge and the routing treat a pinned
-- set, not PinnedFrames' own growth-corner maths.
--
-- What is asserted is what a user sees or what lands in their saved data:
--   * the frames end up where the slab was dropped, with and without a layout;
--   * a layout switch puts the frames at that layout's position, and back;
--   * nothing is written into a layout unless the user moved something in it;
--   * the profile's position is never changed by a move made inside a layout;
--   * anchors follow the right owner (profile vs layout) and a pinned set follows the
--     raid frames without its position ever entering a layout;
--   * re-applying and sweeping repeatedly moves nothing (no ping-pong).
--
-- ☠ ONE LUA RUNTIME IS SHARED BY EVERY SUITE. Everything replaced here is put back.
-- ⚠ AND THE FILE NAME IS LOAD-BEARING. test_registry_events.lua is the suite that first
-- loads the lib's Core.lua (with its own UI-host stub), and every later suite only loads
-- it when missing. Named test_session_*, this sorts after it -- sorted earlier, it would
-- install a different stub first and break the suites that follow.
-- ============================================================

local saved = {
    CreateFrame = CreateFrame, C_Timer = C_Timer, hooksecurefunc = hooksecurefunc,
    IsInRaid = IsInRaid, debugprofilestop = debugprofilestop, InCombatLockdown = InCombatLockdown,
    GetTime = GetTime,
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
-- FRAME MODEL (the anchor-resolving model of test_session_party_drop.lua)
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

local moves = 0          -- every container placement that actually changed where it is

local function GeoFrame(parent, name)
    local f = { _parent = parent, _scale = 1, _w = 0, _h = 0, _shown = true, _name = name }
    function f:SetScale(s) self._scale = s end
    function f:GetScale() return self._scale end
    function f:GetEffectiveScale()
        local p = self._parent
        return ((p and p ~= UIParent) and p:GetEffectiveScale() or 1) * self._scale
    end
    function f:SetSize(w, h) self._w, self._h = w, h end
    function f:GetSize() return self._w, self._h end
    function f:GetWidth() return self._w end
    function f:GetHeight() return self._h end
    function f:ClearAllPoints() self._prev = rawget(self, "_pt"); self._pt = nil end
    function f:SetPoint(point, rel, relPoint, x, y)
        if type(rel) == "number" then rel, relPoint, x, y = nil, point, rel, relPoint end
        if rawget(self, "_pt") then return end
        self._pt = { point, rel or self._parent or UIParent, relPoint or point, x or 0, y or 0 }
        local p = rawget(self, "_prev")
        if not p or math.abs(p[4] - self._pt[4]) > 0.01 or math.abs(p[5] - self._pt[5]) > 0.01 then
            moves = moves + 1
        end
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

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = deepcopy(x) end
    return t
end

local function near(a, b) return math.abs((a or 1e9) - (b or -1e9)) < 0.01 end

-- ============================================================
-- A DF NAMESPACE: raid DB + proxy, the real position funnel, the real routing
-- ============================================================
local DFt = {}
DFt.L = setmetatable({}, { __index = function(_, k) return k end })
local real = {}                                     -- DandersFramesDB_v2.profiles[cur].raid
DFt._realRaidDB = real
local proxy = setmetatable({}, {
    __index = function(_, k)
        local ov = DFt.raidOverrides
        if ov and ov[k] ~= nil then return ov[k] end
        return real[k]
    end,
    __newindex = function(_, k, v) real[k] = v end,
})
local pdb = { frameScale = 1 }
function DFt:GetRaidDB() return proxy end
function DFt:GetDB(mode) if mode == "raid" then return proxy end return pdb end
function DFt:Debug() end
function DFt:DebugWarn() end
function DFt:DebugActive() return false end
function DFt:MakeDebugPrinter() return function() end end
function DFt:DeepCopy(v) return deepcopy(v) end
function DFt:IsTestModeActive() return false end
function DFt:ComputeRaidContainerCompensation() return 0, 0 end
function DFt:ComputeRaidMainGroupAnchorOffset() return 0, 0 end
-- Hook targets MoverBridge installs on. Bodies are irrelevant here.
function DFt:UpdateContainerPosition() end
function DFt:SyncRaidMoverToContainer() end
function DFt:UpdateRaidLayout_Now() end
function DFt:FullProfileRefresh() end
function DFt:RefreshTestFramesWithLayout() end
function DFt:LightweightPositionRaidTestFrames() end
function DFt:LightweightPositionPartyTestFrames() end

InCombatLockdown = function() return false end
GetTime = GetTime or function() return 0 end

-- The position funnel and the raid container placement, as they ship.
do
    local src = df_file_source("Frames/Position.lua"):gsub("\r\n", "\n")
    local s = src:find("local RECORD_SPECS = {", 1, true)
    local e = src:find("function DF:UnlockFrames()", 1, true)
    check(s and e, "setup: the position funnel can be cut out of Position.lua")
    local chunk = assert(loadstring("local DF, Mover, ShortCaller = ...\n" .. src:sub(s, e - 1), "@Position.lua(cut)"))
    chunk(DFt, Mover, function() return "?" end)
end

-- The auto-layout routing primitives, as they ship, on a stand-in AutoProfilesUI.
local apu = { activeRuntimeProfile = nil }
function apu:IsEditing() return false end
DFt.AutoProfilesUI = apu
do
    local src = df_file_source("Core/AutoProfiles.lua"):gsub("\r\n", "\n")
    local function body(header)
        local s = src:find(header, 1, true)
        check(s ~= nil, "setup: found " .. header)
        local e = src:find("\nend\n", s)
        return src:sub(s, e + 4)
    end
    local code = "local AutoProfilesUI, DF = ...\n"
        .. body("local function DeepCopyValue(value)")
        .. body("local function NormalizeLayoutPositionRecord(overrides, base, key, xKey, yKey)")
        .. body("function AutoProfilesUI:SetActiveLayoutRaidPair(xKey, yKey, x, y)")
        .. body("function AutoProfilesUI:SetActiveLayoutRaidRecord(rec, key, xKey, yKey)")
        .. body("function AutoProfilesUI:SetActiveLayoutRaidPosition(x, y)")
    local chunk = assert(loadstring(code, "@AutoProfiles.lua(cut)"))
    local env = setmetatable({ DF = DFt }, { __index = _G })
    setfenv(chunk, env)
    chunk(apu, DFt)
end

-- ============================================================
-- THE WORLD: a raid container reserved larger than the 10 frames inside it
-- ============================================================
DFt.container = GeoFrame(UIParent, "container")       -- party; the real party apply needs it
DFt.container:SetSize(120, 258)
DFt.raidContainer = GeoFrame(UIParent, "raidContainer")
DFt.raidContainer:SetSize(600, 300)
DFt.unitFrameMap = {}
for i = 1, 10 do
    local f = GeoFrame(DFt.raidContainer, "raid" .. i)
    f:SetSize(100, 40)
    local col, row = (i - 1) % 5, math.floor((i - 1) / 5)
    f:SetPoint("TOPLEFT", DFt.raidContainer, "TOPLEFT", col * 102, -row * 42)
    DFt.unitFrameMap["raid" .. i] = f
end
for i = 11, 40 do DFt.unitFrameMap["raid" .. i] = nil end

-- The frames' visible centre, straight off the model, in UIParent units from centre.
local function framesCentre()
    local l, b, r, t
    for i = 1, 10 do
        local fl, fb, fw, fh = DFt.unitFrameMap["raid" .. i]:ScreenRect()
        fl, fb = fl - SW / 2, fb - SH / 2
        l = l and math.min(l, fl) or fl
        b = b and math.min(b, fb) or fb
        r = r and math.max(r, fl + fw) or fl + fw
        t = t and math.max(t, fb + fh) or fb + fh
    end
    return (l + r) / 2, (b + t) / 2
end

-- A raid pinned set (stub of PinnedFrames' accessors; see the header).
local pinnedSet = { enabled = true, position = { point = "CENTER", x = 0, y = 250 } }
local pinnedContainer = GeoFrame(UIParent, "pinned1")
pinnedContainer:SetSize(100, 84)
local function placePinned()
    local p = pinnedSet.position
    pinnedContainer:ClearAllPoints()
    pinnedContainer:SetPoint(p.point or "CENTER", UIParent, "CENTER", p.x or 0, p.y or 0)
end
DFt.PinnedFrames = {
    MAX_SETS = 1,
    GetSetForMode = function(_, i, isRaid) return (i == 1 and isRaid) and pinnedSet or nil end,
    EnsureSetUid = function(_, i, mode) return (i == 1 and mode == "raid") and "u1" or nil end,
    GetContainerForMode = function(_, i, isRaid) return (i == 1 and isRaid) and pinnedContainer or nil end,
    GetContainerRect = function(_, i, isRaid)
        if not (i == 1 and isRaid) then return nil end
        local cx, cy = pinnedContainer:GetCenter()
        return { x = cx - SW / 2, y = cy - SH / 2, w = 100, h = 84 }
    end,
    GetPositionRecord = function(_, i, isRaid) return (i == 1 and isRaid) and pinnedSet.position or nil end,
    CommitSetPosition = function(_, i, isRaid, pos)
        if not (i == 1 and isRaid) then return end
        local rec = pinnedSet.position
        if pos ~= rec then rec.point, rec.x, rec.y, rec.anchor = pos.point, pos.x, pos.y, deepcopy(pos.anchor) end
        placePinned()
    end,
}

-- A foreign anchor target whose rect the test moves (registered once the registry is
-- ready, below -- before that a registration only queues).
local box = { x = -500, y = 300, w = 160, h = 40 }

-- Timers queue; the test drains them.
local timers = {}
local function drain()
    local n = 0
    while #timers > 0 and n < 50 do table.remove(timers, 1)(); n = n + 1 end
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

local P = { dragZones = {}, zones = {}, zoneCount = 0,
            RefreshAll = function() end, Highlight = function() end, Refresh = function() end,
            ShowToast = function() end, SnapTether = function() end, Remove = function() end,
            RemoveAddon = function() end, UpdateTethers = function() end,
            SyncMany = function() return true end,
            DismissAll = function() end, Rebuild = function() end, EndLinkVisual = function() end,
            GetUnlockFrame = function() return permissive() end }
NS.Proxy = P
R.ready = true
R:RegisterAddon("MLT", { title = "MLT" })
Mover:RegisterAnchorTarget("MLT", "box", { title = "box", frame = FakeFrame(380, 840, 160, 40),
    getRect = function() return box end })
check(R:GetTarget("MLT:box") ~= nil, "setup: the foreign anchor target is registered")
load_df_file_into("Features/MoverBridge.lua", DFt)
local Bridge = DFt.MoverBridge
check(Bridge ~= nil, "setup: MoverBridge loaded against the real lib")

NS.db = { snapToFrames = false, snapToGrid = false, snapToScreen = false, snapDistance = 25, addons = {} }
NS.Grid = setmetatable({}, { __index = function() return function() end end })
do
    local prevTimer = C_Timer
    C_Timer = { After = function() end }
    load_addon_file("Session.lua")
    C_Timer = prevTimer
end
local Sess = NS.Session

-- ============================================================
-- HELPERS
-- ============================================================
local function resetProfile(rec)
    wipe(real)
    real.frameScale = 1
    real.position = deepcopy(rec)
    real.raidAnchorX, real.raidAnchorY = rec.x, rec.y
    DFt.raidOverrides, apu.activeRuntimeProfile = nil, nil
    pinnedSet.position = { point = "CENTER", x = 0, y = 250 }
    placePinned()
    DFt:UpdateRaidContainerPosition()
end

-- ApplyRuntimeProfile / RemoveRuntimeProfile, as far as positions are concerned: the
-- overlay is a deep copy of the layout's overrides, then a full refresh (the bridge's
-- FullProfileRefresh hook re-applies every DandersMover element).
local function activate(layout)
    apu.activeRuntimeProfile = layout
    DFt.raidOverrides = layout and deepcopy(layout.overrides) or nil
    DFt:FullProfileRefresh()
    DFt:UpdateRaidContainerPosition()
    drain()
end

local function sweep()
    Mover:RefreshMovedTargets("DandersFrames", { "raid", "group" })
    drain()
end

local raid
local pinnedEl

local function dragTo(el, tx, ty)
    Sess:BeginDrag(el)
    local r0 = R:GetRect(el)
    local fx, fy, zone
    for step = 1, 4 do
        local f = step / 4
        fx, fy, zone = Sess:DragTo(el, r0.x + (tx - r0.x) * f, r0.y + (ty - r0.y) * f)
    end
    Sess:EndDrag(el, fx, fy, zone)
    drain()
    return fx, fy
end

Bridge:Init()
drain()
raid = R:Get("DandersFrames:raid")
check(raid ~= nil and raid.visibleOffset ~= nil, "setup: the raid element is registered with a visibleOffset")
pinnedEl = R:Get("DandersFrames:raid.pinned.u1")
check(pinnedEl ~= nil, "setup: the raid pinned set is registered")

-- ============================================================
-- 1. NO LAYOUT: a drag lands under the slab and writes the profile.
-- ============================================================
do
    resetProfile({ point = "CENTER", x = 0, y = -25 })
    Sess.active = true
    Sess.undo = LibStub("DandersUndo-1.0"):New({ limit = 50 })
    local fx, fy = dragTo(raid, 250, 120)
    local cx, cy = framesCentre()
    check(near(cx, fx) and near(cy, fy), string.format("no layout: frames under the slab (slab %.1f,%.1f frames %.1f,%.1f)", fx, fy, cx, cy))
    check(not near(real.raidAnchorX, 0), "no layout: the profile's X moved")
    eq(real.raidAnchorX, real.position.x, "no layout: record and scalar mirror agree")
end

-- ============================================================
-- 2. AN X/Y-ONLY LAYOUT (every pre-record layout)
-- ============================================================
local L1 = { name = "Mythic", overrides = { raidAnchorX = -300, raidAnchorY = 100, frameWidth = 90 } }
do
    resetProfile({ point = "CENTER", x = 0, y = -25 })
    local cxBase, cyBase = framesCentre()
    activate(L1)
    eq(R:GetPos(raid).x, -300, "x/y layout: on activation the frames take the layout's X")
    check(L1.overrides.position == nil, "x/y layout: activation writes no record into the layout")
    local cx1, cy1 = framesCentre()
    check(not near(cx1, cxBase), "x/y layout: the frames moved to the layout position")

    -- A drag inside the layout writes the LAYOUT, never the profile.
    local fx, fy = dragTo(raid, -100, 200)
    local cx, cy = framesCentre()
    check(near(cx, fx) and near(cy, fy), "x/y layout: a drag lands under the slab")
    check(not near(L1.overrides.raidAnchorX, -300), "x/y layout: the drag moved the layout's X")
    eq(real.raidAnchorX, 0, "x/y layout: the profile's X is untouched by the drag")
    eq(real.position.x, 0, "x/y layout: ...and so is the profile's record")
    check(L1.overrides.position == nil, "x/y layout: a plain drag adds no record (nothing an X/Y cannot say)")

    -- Off again: the frames return exactly to the profile position.
    activate(nil)
    local cx2, cy2 = framesCentre()
    check(near(cx2, cxBase) and near(cy2, cyBase), "x/y layout: deactivating puts the frames back exactly")
end

-- ============================================================
-- 3. A LAYOUT THAT LEAVES POSITION TO THE PROFILE: activation stamps nothing
-- ============================================================
do
    resetProfile({ point = "CENTER", x = 40, y = -60 })
    local L2 = { name = "Heroic", overrides = { frameWidth = 80 } }
    local cx0, cy0 = framesCentre()
    activate(L2)
    for _ = 1, 3 do activate(L2); sweep() end
    check(L2.overrides.raidAnchorX == nil and L2.overrides.position == nil,
          "profile-following layout: repeated activations stamp no position into it")
    local cx, cy = framesCentre()
    check(near(cx, cx0) and near(cy, cy0), "profile-following layout: the frames stay at the profile position")
end

-- ============================================================
-- 4. ANCHORS: owned by the layout vs owned by the profile
-- ============================================================
do
    -- The profile is anchored under the box; the X/Y-only layout is not.
    resetProfile({ point = "CENTER", x = 0, y = 0,
                   anchor = { target = "MLT:box", edge = "bottom", align = "center", offsetX = 0, offsetY = 0 } })
    Mover:Apply("DandersFrames", "raid"); drain()
    local bx0, by0 = framesCentre()
    check(near(bx0, box.x), string.format("anchors: the profile is really seated under the box (frames x %.1f, box x %.1f)", bx0, box.x))
    activate(L1)
    local lx, ly = framesCentre()
    box.x = box.x + 120                                -- the profile's anchor target moves
    Mover:RefreshAnchorTarget("MLT", "box"); sweep()
    local lx2, ly2 = framesCentre()
    check(near(lx, lx2) and near(ly, ly2), "anchors: an X/Y-only layout is not pulled by the profile's anchor")
    check(L1.overrides.position == nil, "anchors: ...and gains no record from the profile's re-solve")
    activate(nil)
    local bx1, by1 = framesCentre()
    check(near(bx1, bx0 + 120) and near(by1, by0), "anchors: with the layout off, the profile follows its anchor")
    check(R:GetPos(raid).anchor ~= nil, "anchors: the profile's anchor survived the layout")
    box.x = -500

    -- Anchor INSIDE a layout: the layout stores it, the profile does not get it.
    resetProfile({ point = "CENTER", x = 0, y = -25 })
    local L3 = { name = "M+", overrides = { raidAnchorX = 200, raidAnchorY = -200 } }
    activate(L3)
    Sess.active = true
    Sess:Anchor(raid, "MLT:box", "bottom", "center")
    drain()
    check(L3.overrides.position and L3.overrides.position.anchor and L3.overrides.position.anchor.target == "MLT:box",
          "anchors: anchoring inside a layout stores the anchor in that layout")
    check(real.position.anchor == nil, "anchors: ...and leaves the profile unanchored")
    local ax, ay = framesCentre()
    check(near(ax, box.x), "anchors: the layout's anchor really seats the frames under the box")
    activate(nil)
    local px, py = framesCentre()
    check(not near(px, ax) or not near(py, ay), "anchors: layout off -> the profile position, not the anchored one")
    activate(L3)
    local ax2, ay2 = framesCentre()
    check(near(ax2, ax) and near(ay2, ay), "anchors: layout back on -> anchored again, same place")
end

-- ============================================================
-- 5. DISCARD inside an active layout restores the layout exactly
-- ============================================================
do
    resetProfile({ point = "CENTER", x = 0, y = -25 })
    local L4 = { name = "Raid", overrides = { frameWidth = 90 } }    -- no position of its own
    activate(L4)
    local cx0, cy0 = framesCentre()
    -- Open a session the way Session:Unlock does (snapshots, then the Unlocked callback).
    Sess.snapshots = {}
    for _, el in ipairs(R:SortedElements()) do
        if R:IsInSession(nil, el) then Sess.snapshots[el.id] = NS.CopyPos(R:GetPos(el)) end
    end
    Sess.undo = LibStub("DandersUndo-1.0"):New({ limit = 50 })
    Sess.active, Sess.suspended, Sess.dirty = true, false, false
    Mover.callbacks:Fire("Unlocked")
    dragTo(raid, 300, 250)
    check(L4.overrides.raidAnchorX ~= nil, "discard: the drag was routed into the layout (precondition)")
    Sess:Finish("discard")
    drain()
    check(L4.overrides.raidAnchorX == nil and L4.overrides.raidAnchorY == nil and L4.overrides.position == nil,
          "discard: the layout has no position again, exactly as before the session")
    local cx, cy = framesCentre()
    check(near(cx, cx0) and near(cy, cy0), "discard: the frames are back where they were")
    eq(real.raidAnchorX, 0, "discard: the profile was never touched")
end

-- ============================================================
-- 6. PINNED SET anchored to the raid frames
-- ============================================================
do
    resetProfile({ point = "CENTER", x = 0, y = -25 })
    pinnedSet.position = { point = "CENTER", x = 0, y = 0,
                           anchor = { target = "DandersFrames:raid", edge = "right", align = "start", offsetX = 0, offsetY = 0 } }
    Mover:Apply("DandersFrames", "raid.pinned.u1"); drain()
    local p0x = pinnedSet.position.x
    activate(L1)                                         -- raid frames jump to the layout position
    sweep()
    check(not near(pinnedSet.position.x, p0x), "pinned: the set follows the raid frames to the layout position")
    check(L1.overrides.position == nil and L1.overrides["pinned.1.position"] == nil,
          "pinned: the set's position never enters the layout")
    local lx = pinnedSet.position.x
    activate(nil); sweep()
    check(near(pinnedSet.position.x, p0x), "pinned: layout off -> the set is back beside the profile position")
    activate(L1); sweep()
    check(near(pinnedSet.position.x, lx), "pinned: layout on again -> same place as before")
    check(pinnedSet.position.anchor and pinnedSet.position.anchor.target == "DandersFrames:raid",
          "pinned: the set keeps its anchor through every switch")
end

-- ============================================================
-- 7. STABILITY: nothing moves on repeated re-applies and sweeps
-- ============================================================
do
    for _, case in ipairs({
        { "no layout", nil },
        { "x/y layout", L1 },
    }) do
        resetProfile({ point = "CENTER", x = 0, y = -25,
                       anchor = { target = "MLT:box", edge = "bottom", align = "center", offsetX = 0, offsetY = 0 } })
        activate(case[2])
        Mover:Apply("DandersFrames", "raid"); sweep()
        moves = 0
        for _ = 1, 6 do
            Mover:Apply("DandersFrames", "raid")
            Mover:Apply("DandersFrames", "raid.pinned.u1")
            DFt:FullProfileRefresh()
            sweep()
            DFt:UpdateRaidContainerPosition()
        end
        eq(moves, 0, "stability (" .. case[1] .. "): repeated re-applies and sweeps move nothing")
    end
end

-- ============================================================
-- RESTORE
-- ============================================================
-- The Session loaded here listens on the SHARED lib (RegistryChanged); left active it
-- would rebuild proxies inside the next suite's registry churn.
Sess.active, Sess.suspended = false, false
Mover.UnregisterCallback(Sess, "RegistryChanged")
for _, ev in ipairs({ "Unlocked", "Locked", "Discarded", "Saved" }) do Mover.UnregisterCallback(Bridge, ev) end
Mover:UnregisterAddon("MLT")
Mover:UnregisterAddon("DandersFrames")
CreateFrame, C_Timer, hooksecurefunc = saved.CreateFrame, saved.C_Timer, saved.hooksecurefunc
IsInRaid, debugprofilestop, InCombatLockdown, GetTime = saved.IsInRaid, saved.debugprofilestop, saved.InCombatLockdown, saved.GetTime
NS.Proxy, NS.Session, NS.Grid, NS.db, R.ready = saved.Proxy, saved.Session, saved.Grid, saved.db, saved.ready
