local NS = ...
local R = NS.Registry
local Solver = NS.Solver

-- ============================================================
-- OFF-SCREEN RESCUE -- Core.lua's KeepOnScreen, /mover reset, and the stale
-- zone gate in Session:EndDrag
-- ------------------------------------------------------------
-- The one report in #1118 that could leave a user STUCK: a drop onto a snap zone
-- whose target rect was stale (a party frame whose container was hidden still
-- answers GetCenter) solved the element off screen, and the slab went with it,
-- so nothing was left to click. Three answers, each tested here:
--
--   1. THE ANCHORED SOLVE IS CLAMPED -- but only when NOTHING of the element
--      would be visible. A deliberate overhang keeps its seat exactly.
--   2. /mover reset all | <addon> puts positions back to their declared
--      defaults from the chat line, with no slab to click. In a live session it
--      goes through Session (undoable); outside one it applies directly.
--   3. A drop onto a zone whose target stopped being available mid-drag is a
--      plain move to where the preview showed, never a solve against the stale
--      rect. (The slab's own clamp is asserted in test_proxy.)
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. Core.lua loads
-- exactly once, and test_registry_events must be the one to load it (it reads
-- back the frames that load creates) -- which the filename ordering gives it.
-- The guarded load below is for a FILTERED run of this file alone, and mirrors
-- test_registry_resize's. Everything replaced here is restored at the end.
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

local Lib = LibStub("DandersMover-1.0", true)
check(Lib ~= nil, "setup: the library object is available")
check(type(NS.KeepOnScreen) == "function", "setup: KeepOnScreen is published on the namespace")
check(type(NS.ResetPositions) == "function", "setup: ResetPositions is published on the namespace")

-- UIParent is the shim's 1920x1080 fake: the screen runs -960..960 by -540..540
-- in UIParent-centre units.
local SW, SH = UIParent:GetWidth(), UIParent:GetHeight()

-- ------------------------------------------------------------
-- 1. KeepOnScreen
-- ------------------------------------------------------------
do
    -- Fully off the right edge: pulled back to the nearest fully-visible spot.
    local x, y = NS.KeepOnScreen(2000, 0, 100, 40)
    eq(x, SW / 2 - 50, "clamp: an element wholly past the right edge lands flush against it")
    eq(y, 0, "clamp: ...on the axis that was fine, nothing moves")
    -- Fully off the bottom.
    x, y = NS.KeepOnScreen(0, -900, 100, 40)
    eq(x, 0, "clamp: bottom case leaves x alone")
    eq(y, -SH / 2 + 20, "clamp: an element wholly below the screen lands flush against the bottom")
    -- Overhanging: HALF of it visible. Left exactly where it was.
    x, y = NS.KeepOnScreen(SW / 2, 0, 100, 40)
    eq(x, SW / 2, "overhang: an element half over the right edge keeps its seat")
    -- A single visible pixel is still visible.
    x, y = NS.KeepOnScreen(SW / 2 + 49, 0, 100, 40)
    eq(x, SW / 2 + 49, "overhang: one visible pixel is enough to leave it alone")
    -- Touching the edge from outside counts as off screen (no overlap area).
    x, y = NS.KeepOnScreen(SW / 2 + 50, 0, 100, 40)
    eq(x, SW / 2 - 50, "clamp: an element sitting exactly outside the edge is pulled in")
    -- Missing geometry: hands the solve back untouched.
    x, y = NS.KeepOnScreen(5000, 5000, nil, nil)
    eq(x, 5000, "clamp: no size means no clamp")
end

-- ------------------------------------------------------------
-- 1b. ...through ResolveElement, which is where the report went wrong.
-- ------------------------------------------------------------
do
    local wasReady = R.ready
    R.ready = true
    R:RegisterAddon("KS", { title = "KS" })
    -- Target parked well off the right edge, as a stale rect would be.
    local farFrame = FakeFrame(960 + 3000, 540, 40, 40)
    R:RegisterAnchorTarget("KS", "far", { title = "far", frame = farFrame })
    local pos = { point = "CENTER", x = 0, y = 0,
                  anchor = { target = "KS:far", edge = "right", align = "center", offsetX = 0, offsetY = 0 } }
    local el = R:Register("KS", "el", { title = "el", frame = FakeFrame(960, 540, 100, 40),
        getSize = function() return 100, 40 end,
        getPos = function() return pos end, onChanged = function() end })
    check(NS:ResolveElement(el), "resolve: the anchored element re-solved")
    eq(pos.point, "CENTER", "resolve: solved records are centre-based")
    check(pos.x + 50 <= SW / 2 and pos.x - 50 >= -SW / 2, "resolve: a solve that would leave the screen is clamped onto it")
    check(pos.anchor ~= nil and pos.anchor.target == "KS:far", "resolve: the anchor record itself is untouched")

    -- The target comes back to a sane place: the element follows it as normal.
    farFrame._cx = 960 + 300
    NS:ResolveElement(el)
    local want = 300 + 20 + Solver.SPACING + 50
    eq(pos.x, want, "resolve: with the target on screen the plain solve is used")

    -- A target at the edge whose seat only OVERHANGS: the plain solve stands.
    farFrame._cx = 960 + (SW / 2 - 20)          -- right edge exactly at the screen edge
    NS:ResolveElement(el)
    local ex, ey = Solver.Resolve(pos.anchor, 100, 40, R:GetRect(R:GetTarget("KS:far")), Solver.SPACING)
    -- 100 wide, seated 2 past the edge: wholly off, so this one IS clamped...
    check(pos.x ~= ex, "resolve: wholly off after a right-edge seat -> clamped")
    -- ...whereas a target whose right edge is 60 inside leaves 38px visible.
    farFrame._cx = 960 + (SW / 2 - 60 - 20)
    NS:ResolveElement(el)
    ex, ey = Solver.Resolve(pos.anchor, 100, 40, R:GetRect(R:GetTarget("KS:far")), Solver.SPACING)
    eq(pos.x, ex, "resolve: a partial overhang keeps the plain solve")
    R:UnregisterAddon("KS")
    R.ready = wasReady
end

-- ------------------------------------------------------------
-- 2. /mover reset
-- ------------------------------------------------------------
do
    local wasReady = R.ready
    R.ready = true
    local notified = {}
    local function def(pos, default)
        return { title = "x", frame = FakeFrame(960, 540, 50, 50), default = default,
                 getPos = function() return pos end,
                 onChanged = function(p, reason) notified[#notified + 1] = { p = p, reason = reason } end }
    end
    local a = { point = "TOPLEFT", x = 400, y = -300,
                anchor = { target = "RS:b", edge = "left", align = "start", offsetX = 0, offsetY = 0 } }
    local b = { point = "CENTER", x = 123, y = 456 }
    local c = { point = "CENTER", x = 9, y = 9 }
    R:RegisterAddon("RS", { title = "Reset Me" })
    R:RegisterAddon("RO", { title = "Other" })
    R:Register("RS", "a", def(a, { point = "CENTER", x = 10, y = 20 }))     -- default: free
    R:Register("RS", "b", def(b, nil))                                       -- no default at all
    R:Register("RO", "c", def(c, { point = "CENTER", x = -5, y = -5 }))

    -- One addon: only its elements move.
    local n = NS:ResetPositions("RS")
    eq(n, 2, "reset: counts the elements it reset")
    eq(a.x, 10, "reset: a declared default is restored (x)")
    eq(a.y, 20, "reset: ...(y)")
    eq(a.point, "CENTER", "reset: ...(point)")
    check(a.anchor == nil, "reset: a default with no anchor clears the anchor")
    eq(b.point, "CENTER", "reset: no default -> the centre of the screen (point)")
    eq(b.x, 0, "reset: no default -> x 0")
    eq(b.y, 0, "reset: no default -> y 0")
    eq(c.x, 9, "reset: the other addon is untouched")
    check(#notified == 2 and notified[1].reason == "reset" and notified[2].reason == "reset",
        "reset: each element's consumer is told, with the reset reason")

    -- Everything.
    n = NS:ResetPositions(nil)
    eq(n, 3, "reset all: every element")
    eq(c.x, -5, "reset all: the other addon's element too")

    -- In a live session the reset goes through Session, so it is undoable and
    -- Discard can still put it back.
    local viaSession = {}
    local prevSession = NS.Session
    NS.Session = { filter = nil,
                   IsActive = function() return true end, IsSuspended = function() return false end,
                   Reset = function(_, el) viaSession[#viaSession + 1] = el.id end }
    c.x = 77
    NS:ResetPositions("RO")
    eq(#viaSession, 1, "reset in session: routed through Session:Reset")
    eq(viaSession[1], "RO:c", "reset in session: ...for the element")
    eq(c.x, 77, "reset in session: the direct path did not also run")
    -- Suspended for combat: the direct path (Notify defers secure writes itself).
    NS.Session.IsSuspended = function() return true end
    NS:ResetPositions("RO")
    eq(c.x, -5, "reset while suspended: applied directly")
    NS.Session = prevSession

    -- The slash verb. Output is captured off NS:Print -- not the global print,
    -- which is also how a failed check reports itself.
    local lines = {}
    local prevPrint = NS.Print
    NS.Print = function(_, msg) lines[#lines + 1] = tostring(msg) end
    local function said(fragment)
        for _, l in ipairs(lines) do if l:find(fragment, 1, true) then return true end end
        return false
    end
    c.x = 1; a.x = 1
    SlashCmdList.DANDERSMOVER("reset all")
    eq(c.x, -5, "/mover reset all: resets")
    eq(a.x, 10, "/mover reset all: ...everything")
    check(said("3"), "/mover reset all: reports the count")
    a.x = 1; c.x = 1
    wipe(lines)
    SlashCmdList.DANDERSMOVER("reset RS")          -- the slash line is lowercased before dispatch
    eq(a.x, 10, "/mover reset <addon>: matches the registry name case-blind")
    eq(c.x, 1, "/mover reset <addon>: ...and only that addon")
    wipe(lines)
    SlashCmdList.DANDERSMOVER("reset nope")
    eq(c.x, 1, "/mover reset unknown: resets nothing")
    check(said("nope"), "/mover reset unknown: names what it could not find")
    check(said("RO") and said("RS"), "/mover reset unknown: ...and lists what is registered")
    wipe(lines)
    SlashCmdList.DANDERSMOVER("reset")
    eq(c.x, 1, "/mover reset (bare): resets nothing by surprise")
    check(said("RO") and said("RS"), "/mover reset (bare): lists what is registered")
    wipe(lines)
    SlashCmdList.DANDERSMOVER("bogus")
    check(said("reset"), "/mover usage: names the reset verb")
    NS.Print = prevPrint

    R:UnregisterAddon("RS")
    R:UnregisterAddon("RO")
    R.ready = wasReady
end

-- ------------------------------------------------------------
-- 3. A drop onto a stale zone (Session:EndDrag)
-- ------------------------------------------------------------
do
    local wasReady = R.ready
    R.ready = true
    NS.db = { showHiddenMovers = true, snapToFrames = true, addons = {} }
    -- Session.lua reads Proxy at load and calls into it on every apply. In the
    -- full run that is the real module test_proxy loaded; a filtered run of
    -- this file has none, so the surface the drop path touches is stubbed.
    local ownProxy = NS.Proxy == nil
    if ownProxy then
        NS.Proxy = { dragZones = {}, RefreshAll = function() end, Highlight = function() end,
                     Refresh = function() end, ShowToast = function() end }
    end
    -- Session's RegistryChanged handler defers through C_Timer; nothing below
    -- registers while a session is active, but the load must not see a
    -- run-at-once timer some earlier suite left on the global either.
    local prevTimer = C_Timer
    C_Timer = { After = function() end }
    StaticPopupDialogs = StaticPopupDialogs or {}
    local prevSession = NS.Session
    load_addon_file("Session.lua")
    C_Timer = prevTimer
    local Sess = NS.Session
    Sess.undo = LibStub("DandersUndo-1.0"):New({ limit = 10 })

    local targetFrame = FakeFrame(1160, 540, 100, 40)          -- rel (200, 0)
    local pos = { point = "CENTER", x = 0, y = 0 }
    R:RegisterAddon("SZ", { title = "SZ" })
    local target = R:RegisterAnchorTarget("SZ", "tgt", { title = "t", frame = targetFrame })
    local el = R:Register("SZ", "el", { title = "el", frame = FakeFrame(960, 540, 60, 30),
        getSize = function() return 60, 30 end,
        getPos = function() return pos end, onChanged = function() end })
    Sess.active = true

    -- The zone exactly as Proxy:ShowZones would have built it at drag start.
    local zones = Solver.SnapZones(target.id, R:GetRect(target), 60, 30, Solver.SPACING, function() return false end)
    local zone
    for _, z in ipairs(zones) do if z.edge == "right" and z.align == "center" then zone = z end end
    check(zone ~= nil, "stale zone: the target offered a right-edge seat at drag start")

    -- Mid-drag the target went away. The preview still showed the zone; the
    -- drop lands there as a plain move.
    targetFrame._shown = false
    Sess:BeginDrag(el)
    pos.x, pos.y = zone.x, zone.y          -- what DragTo had written by the drop
    Sess:EndDrag(el, zone.x, zone.y, zone)
    check(pos.anchor == nil, "stale zone: the drop does not anchor to a target that is no longer available")
    eq(pos.x, zone.x, "stale zone: ...and commits where the preview showed")
    check(Sess.undo:CanUndo(), "stale zone: the move is still an undo step")

    -- The same drop with the target still there anchors, as before.
    targetFrame._shown = true
    Sess:BeginDrag(el)
    Sess:EndDrag(el, zone.x, zone.y, zone)
    check(pos.anchor ~= nil and pos.anchor.target == "SZ:tgt", "live zone: the drop anchors")
    eq(pos.x, zone.x, "live zone: ...where the preview showed")

    -- A target that was UNREGISTERED mid-drag is the same case. (Free before
    -- the drag: an element still anchored at drag start would spring back to
    -- that anchor on a refused zone, which is the other, older rule.)
    pos.anchor = nil
    Sess:BeginDrag(el)
    local ghost = { target = "SZ:gone", edge = "right", align = "center", x = 500, y = 0 }
    pos.x, pos.y = 500, 0
    Sess:EndDrag(el, 500, 0, ghost)
    check(pos.anchor == nil, "unregistered zone: refused too")
    eq(pos.x, 500, "unregistered zone: ...plain move")

    Sess.active = false
    Sess.undo = nil
    NS.Session = prevSession
    if ownProxy then NS.Proxy = nil end
    R:UnregisterAddon("SZ")
    R.ready = wasReady
    NS.db = nil
end
