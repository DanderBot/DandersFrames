local NS = ...
local R = NS.Registry

-- ============================================================
-- AUTO-APPLY + THE WATCHER (DandersMover/Core.lua)
-- ------------------------------------------------------------
-- A consumer registers and forgets: its elements are applied at login (or on the next
-- frame after it), and a follower keeps up with its target without anyone calling
-- RefreshAnchorTarget. The ticker is driven by hand through NS.Watcher:Tick().
--
-- What is pinned here is what cannot be seen in game without a stopwatch: an idle tick
-- does nothing, an opted-out addon pays nothing, and one bad consumer stays one bad
-- consumer.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. Elements other suites
-- left behind are watched by default, so the registry is swapped for an empty one for
-- this file, and every global and field replaced is restored at the end. The guarded
-- load is for a filtered run of this file alone.
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
local W = NS.Watcher
check(type(W) == "table" and type(W.Tick) == "function", "setup: NS.Watcher:Tick is exposed")

local saved = {
    elements = R.elements, targets = R.targets, addons = R.addons, queue = R.queue, ready = R.ready,
    proxy = NS.Proxy, session = NS.Session, pending = NS.pending, lastRect = NS.lastRect,
    loggedIn = W.loggedIn, ticker = W.ticker, stats = W.stats, flushScheduled = W.flushScheduled,
    timer = C_Timer, handler = geterrorhandler, secret = issecretvalue, clock = debugprofilestop,
    combat = IN_COMBAT,
}

-- Fake timers: After queues, NewTicker counts and never fires by itself.
local timers, tickersMade, lastTicker = {}, 0, nil
local function installTimers()
    C_Timer = {
        After = function(_, fn) timers[#timers + 1] = fn end,
        NewTicker = function(_, fn)
            tickersMade = tickersMade + 1
            lastTicker = { fn = fn, cancelled = false }
            function lastTicker:Cancel() self.cancelled = true end
            return lastTicker
        end,
    }
end
local function runTimers()
    local list = timers
    timers = {}
    for _, fn in ipairs(list) do fn() end
    return #list
end

local reported = {}
geterrorhandler = function() return function(msg) reported[#reported + 1] = tostring(msg) end end

-- A clean slate per scenario. Elements registered before the login pass go through
-- OnLogin; afterwards registration schedules a flush, as in game.
local function fresh()
    W:Flush()
    W:Stop()
    R.elements, R.targets, R.addons, R.queue, R.ready = {}, {}, {}, {}, true
    NS.Proxy, NS.Session, NS.pending, NS.lastRect = nil, nil, {}, {}
    W.loggedIn, W.flushScheduled = false, false
    timers, tickersMade, lastTicker, reported = {}, 0, nil, {}
    W.stats = { measured = 0, ticks = 0, lastMs = 0, maxMs = 0 }
    IN_COMBAT = false
    issecretvalue = saved.secret
    debugprofilestop = saved.clock
    installTimers()
end

-- A frame whose centre follows the SetPoint it is given, the way a real one does.
local function GeoFrame(x, y, w, h, scale)
    local f = FakeFrame(960 + x, 540 + y, w, h, scale)
    f.setPoints = 0
    function f:ClearAllPoints() end
    function f:SetPoint(_, _, _, ox, oy)
        self.setPoints = self.setPoints + 1
        local ratio = self._scale
        self._cx, self._cy = (960 + ox * ratio) / ratio, (540 + oy * ratio) / ratio
    end
    function f:MoveTo(mx, my) self._cx, self._cy = (960 + mx) / self._scale, (540 + my) / self._scale end
    return f
end

local anchorRight = function(target, fallback)
    return { target = target, edge = "right", align = "center", offsetX = 0, offsetY = 0, fallback = fallback }
end
-- Right edge, centre align, Solver.SPACING between: x = target.x + target.w/2 + gap + child.w/2.
local function rightOf(tx, tw, cw) return tx + tw / 2 + NS.Solver.SPACING + cw / 2 end

-- A follower with a recording onChanged.
local function follower(addon, key, target, fallback, opts)
    opts = opts or {}
    local fx = { pos = { point = "CENTER", x = -500, y = -300, anchor = anchorRight(target, fallback) },
                 frame = GeoFrame(-500, -300, opts.w or 20, 10), calls = {} }
    fx.el = Lib:Register(addon, key, { frame = fx.frame, watch = opts.watch,
        getPos = function() return fx.pos end,
        onChanged = function(pos, reason)
            fx.calls[#fx.calls + 1] = reason
            Lib.ApplyPosition(fx.frame, pos)
        end })
    return fx
end

local function ticks(n) for _ = 1, n or 1 do W:Tick() end end
local function settle() W:OnLogin(); runTimers(); ticks(2) end

print("-- IsWatched: the element's own word, then its addon's, then on")
do
    fresh()
    eq(R:IsWatched({ addon = "nobody" }), true, "unknown addon: watched")
    Lib:RegisterAddon("A", { title = "A" })
    Lib:RegisterAddon("B", { title = "B", watch = false })
    Lib:RegisterAddon("C", { title = "C", watch = true })
    eq(R:IsWatched({ addon = "A" }), true, "addon says nothing: watched")
    eq(R:IsWatched({ addon = "B" }), false, "addon opted out")
    eq(R:IsWatched({ addon = "C" }), true, "addon opted in")
    eq(R:IsWatched({ addon = "B", watch = true }), true, "an element's true beats its addon's false")
    eq(R:IsWatched({ addon = "A", watch = false }), false, "an element's false beats its addon's default")
    local frame = FakeFrame(960, 540, 10, 10)
    local el = Lib:Register("A", "el", { frame = frame, watch = false, getPos = function() return {} end })
    eq(el.watch, false, "stored on the element")
    eq(R:GetTarget("A:el").watch, false, "...and on its paired target")
    eq(Lib:RegisterAnchorTarget("A", "t", { frame = frame, watch = false }).watch, false, "stored on a pure target")
end

print("-- login applies what is registered so far, as one pass")
do
    fresh()
    Lib:RegisterAddon("Off", { watch = false })
    local tFrame = GeoFrame(100, 0, 40, 20)
    local pos = { point = "CENTER", x = 100, y = 0 }
    Lib:Register("L", "parent", { frame = tFrame, getPos = function() return pos end })
    local child = follower("L", "child", "L:parent")
    local offEl = follower("L", "offEl", "Off:gone", nil, { watch = false })
    local offAddon = follower("Off", "el", "Off:gone")
    eq(#child.calls, 0, "nothing is applied before login")
    eq(tickersMade, 0, "no ticker before login")
    check(#timers == 0, "...and nothing scheduled")

    W:OnLogin()
    eq(tFrame.setPoints, 1, "login: a watched element is applied")
    eq(child.calls[1], "reapply", "login: with the existing reason")
    eq(child.pos.x, rightOf(100, 40, 20), "login: a follower is solved against the parent")
    eq(#child.calls, 1, "login: one pass, one call per element")
    eq(#offEl.calls, 0, "login: an element with watch = false is skipped")
    eq(#offAddon.calls, 0, "login: an addon with watch = false is skipped")
    eq(tickersMade, 1, "login: the ticker starts")
    eq(W.loggedIn, true, "login is done")
    local src = mover_file_source("Core.lua")
    check(src:find('events:RegisterEvent("PLAYER_LOGIN")', 1, true), "Core registers the login event")
end

print("-- later registrations are coalesced onto the next frame")
do
    fresh()
    W:OnLogin()
    local frames, els = {}, {}
    for i = 1, 3 do
        frames[i] = GeoFrame(0, 0, 10, 10)
        local n = i
        els[i] = Lib:Register("LT", "e" .. i, { frame = frames[i],
            getPos = function() return { point = "CENTER", x = n, y = 0 } end })
    end
    eq(#timers, 1, "three registrations, one timer")
    eq(frames[1].setPoints, 0, "not applied yet")
    Lib:Unregister("LT", "e2")
    eq(runTimers(), 1, "the timer fires")
    eq(frames[1].setPoints, 1, "the first is applied once")
    eq(frames[3].setPoints, 1, "the last is applied once")
    eq(frames[2].setPoints, 0, "unregistered before the flush: skipped, no error")
    eq(#reported, 0, "...and nothing reported")
    Lib:Register("LT", "e4", { frame = GeoFrame(0, 0, 10, 10), getPos = function() return { x = 0, y = 0 } end })
    eq(#timers, 1, "a later registration schedules again")

    -- A re-registration replaces the old element: the new one is what gets applied.
    fresh()
    W:OnLogin()
    local oldF, newF = GeoFrame(0, 0, 10, 10), GeoFrame(0, 0, 10, 10)
    Lib:Register("LT", "same", { frame = oldF, getPos = function() return { x = 0, y = 0 } end })
    Lib:Register("LT", "same", { frame = newF, getPos = function() return { x = 0, y = 0 } end })
    runTimers()
    eq(oldF.setPoints, 0, "replaced before the flush: the old one is not applied")
    eq(newF.setPoints, 1, "...the new one is")

    fresh()
    W:OnLogin()
    local optedOut = GeoFrame(0, 0, 10, 10)
    Lib:Register("LT", "off", { frame = optedOut, watch = false, getPos = function() return { x = 0, y = 0 } end })
    eq(#timers, 0, "watch = false schedules nothing")

    fresh()
    C_Timer = nil
    W.loggedIn = true
    local okNoTimer = pcall(function()
        Lib:Register("LT", "notimer", { frame = GeoFrame(0, 0, 10, 10), getPos = function() return { x = 0, y = 0 } end })
    end)
    check(okNoTimer, "no C_Timer: registering still works")
    eq(W.ticker, nil, "no C_Timer: no ticker")
end

print("-- the library loaded after login applies what its ADDON_LOADED drained")
do
    fresh()
    W.loggedIn = true
    local f = GeoFrame(0, 0, 10, 10)
    R.ready = false
    Lib:Register("LOD", "e", { frame = f, getPos = function() return { x = 0, y = 0 } end })
    eq(#timers, 0, "queued: nothing to schedule yet")
    R:Flush()
    W:OnRegistryFlushed()
    eq(#timers, 1, "the drained queue is scheduled")
    runTimers()
    eq(f.setPoints, 1, "...and applied")
    eq(tickersMade, 1, "...and the ticker runs")
end

print("-- a follower follows a moved watched target")
do
    fresh()
    local tFrame = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("F", "tgt", { frame = tFrame })
    local child = follower("F", "child", "F:tgt")
    settle()
    local settled = #child.calls
    eq(child.pos.x, rightOf(100, 40, 20), "starts on its seat")

    tFrame:MoveTo(200, 30)
    ticks()
    eq(child.pos.x, rightOf(200, 40, 20), "follows on the next tick")
    eq(child.pos.y, 30, "...on both axes")
    eq(#child.calls, settled + 1, "told once")
    eq(child.calls[#child.calls], "parent", "...with the reason RefreshAnchorTarget sends")

    tFrame:MoveTo(200.2, 30)
    ticks()
    eq(#child.calls, settled + 1, "a move inside the epsilon is ignored")
end

print("-- reasons match the existing sweep")
do
    fresh()
    local tFrame = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("RS", "tgt", { frame = tFrame })
    local child = follower("RS", "child", "RS:tgt", nil, { watch = false })
    settle()
    NS:ReapplyDescendants("RS:tgt", "parent")
    wipe(child.calls)
    tFrame:MoveTo(300, 0)
    ticks()
    eq(child.calls[1], "parent", "a dependant is told 'parent'")
    -- An anchored element that resized is solved in its own right, so it hears 'reapply'.
    local resized = follower("RS", "resized", "RS:tgt")
    W:Flush()
    ticks()
    wipe(resized.calls)
    resized.frame._w = 60
    ticks()
    eq(resized.calls[1], "reapply", "an element re-solved for its own size is told 'reapply'")
    eq(child.pos.x, rightOf(300, 40, 20), "an opted-out follower still follows a watched target")
end

print("-- a target with watch = false is only followed when it says so")
do
    fresh()
    local tFrame = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("WF", "tgt", { frame = tFrame, watch = false })
    local child = follower("WF", "child", "WF:tgt")
    settle()
    local seat = child.pos.x
    eq(seat, rightOf(100, 40, 20), "solved at login")

    tFrame:MoveTo(250, 0)
    ticks(3)
    eq(child.pos.x, seat, "the watcher does not measure it")
    Lib:RefreshAnchorTarget("WF", "tgt")
    eq(child.pos.x, rightOf(250, 40, 20), "RefreshAnchorTarget moves the follower, as today")
end

print("-- hiding a target switches to the backup, showing it switches back")
do
    fresh()
    local primary, backup = GeoFrame(100, 0, 40, 20), GeoFrame(-200, 50, 60, 20)
    Lib:RegisterAnchorTarget("B", "p", { frame = primary })
    Lib:RegisterAnchorTarget("B", "b", { frame = backup })
    local child = follower("B", "child", "B:p",
        { target = "B:b", edge = "right", align = "center", offsetX = 0, offsetY = 0 })
    settle()
    eq(child.pos.x, rightOf(100, 40, 20), "starts on the primary")

    primary._shown = false
    ticks()
    eq(child.pos.x, rightOf(-200, 60, 20), "hidden primary: on the backup")
    eq(child.pos.y, 50, "...both axes")
    local atBackup = #child.calls

    -- The backup is measured while it is not the active one, so it is followed here too.
    backup:MoveTo(-150, 50)
    ticks()
    eq(child.pos.x, rightOf(-150, 60, 20), "the backup moving is followed")
    eq(#child.calls, atBackup + 1, "...once")

    primary._shown = true
    ticks()
    eq(child.pos.x, rightOf(100, 40, 20), "shown again: back on the primary")

    primary._shown, backup._shown = false, false
    local holdX = child.pos.x
    ticks()
    eq(child.pos.x, holdX, "nothing available: holds")
    -- And a backup moving while the active primary is fine must not move the child.
    primary._shown, backup._shown = true, true
    ticks()
    local onPrimary = child.pos.x
    backup:MoveTo(-100, 50)
    ticks()
    eq(child.pos.x, onPrimary, "the backup moving does nothing while the primary is active")
end

print("-- a target that resizes re-solves its follower")
do
    fresh()
    local tFrame = GeoFrame(0, 0, 100, 20)
    Lib:RegisterAnchorTarget("RZ", "tgt", { frame = tFrame })
    local child = follower("RZ", "child", "RZ:tgt")
    settle()
    eq(child.pos.x, rightOf(0, 100, 20), "starts on its seat")
    tFrame._w = 300
    ticks()
    eq(child.pos.x, rightOf(0, 300, 20), "the follower moves out with the edge")
end

print("-- an anchored element that resizes re-solves itself")
do
    fresh()
    local tFrame = GeoFrame(0, 0, 100, 20)
    Lib:RegisterAnchorTarget("RS2", "tgt", { frame = tFrame })
    local child = follower("RS2", "child", "RS2:tgt", nil, { w = 20 })
    settle()
    child.frame._w = 80
    ticks()
    eq(child.pos.x, rightOf(0, 100, 80), "its own new width is in the solve")
end

print("-- a scale change applies")
do
    fresh()
    local f = GeoFrame(50, 0, 40, 20, 1)
    local pos = { point = "CENTER", x = 50, y = 0 }
    Lib:Register("SC", "e", { frame = f, getPos = function() return pos end })
    settle()
    local before = f.setPoints
    f._scale = 1.0005
    ticks()
    eq(f.setPoints, before, "a change inside the epsilon is ignored")
    f._scale = 2
    ticks()
    eq(f.setPoints, before + 1, "a real change applies")
    eq(R:GetRect(R:GetTarget("SC:e")).x, 50, "...so it stays where its record says")
    ticks(2)
    eq(f.setPoints, before + 1, "...once")
end

print("-- getFrame: first sighting, appearing, replaced, gone")
do
    fresh()
    local current = GeoFrame(0, 0, 40, 20)
    local calls = 0
    -- No login pass over this one: the first the watcher hears of it is the tick.
    W.loggedIn = true
    local pos = { point = "CENTER", x = 10, y = 0 }
    R:Register("GF", "e", { getFrame = function() return current end,
        getPos = function() return pos end,
        onChanged = function() calls = calls + 1 end })
    ticks()
    eq(calls, 0, "a frame that was already there only stamps")

    local replacement = GeoFrame(0, 0, 40, 20)
    current = replacement
    ticks()
    eq(calls, 1, "a different frame applies")
    ticks()
    eq(calls, 1, "...once")

    current = nil
    ticks()
    eq(calls, 1, "a frame going away has nothing to apply")
    current = replacement
    ticks()
    eq(calls, 2, "coming back from no frame applies")

    fresh()
    W:OnLogin()
    local later
    local el = Lib:Register("GF", "lazy", { getFrame = function() return later end,
        getPos = function() return { point = "CENTER", x = 25, y = 0 } end })
    runTimers()
    ticks()
    later = GeoFrame(0, 0, 40, 20)
    -- Arrives between the flush and the next look: this is the case that must not be
    -- mistaken for a frame that was already there.
    ticks()
    eq(later.setPoints, 1, "getFrame appearing: the default onChanged places it")
    eq(R:GetRect(R:GetTarget(el.id)).x, 25, "...where the record says")

    fresh()
    W:OnLogin()
    local lateOnly
    Lib:Register("GF", "first", { getFrame = function() return lateOnly end,
        getPos = function() return { point = "CENTER", x = 1, y = 0 } end })
    runTimers()
    lateOnly = GeoFrame(0, 0, 40, 20)
    ticks()
    eq(lateOnly.setPoints, 1, "a frame turning up right after the flush, before any tick, applies")
end

print("-- aliases: the id the record names is what is measured")
do
    fresh()
    -- A pure target whose frame IS an element's frame: CanonicalId folds it onto the
    -- element, but the solve reads the alias's own rect, which here differs on purpose.
    local shared = GeoFrame(0, 0, 40, 20)
    local aliasRect = { x = 400, y = 0, w = 10, h = 10 }
    local ownerPos = { point = "CENTER", x = 0, y = 0 }
    Lib:Register("AL", "owner", { frame = shared, getPos = function() return ownerPos end })
    Lib:RegisterAnchorTarget("AL", "alias", { frame = shared, getRect = function() return aliasRect end })
    eq(R:CanonicalId("AL:alias"), "AL:owner", "setup: the alias folds onto its element")

    local viaAlias = follower("AL", "viaAlias", "AL:alias")
    local viaOwner = follower("AL", "viaOwner", "AL:owner")
    settle()
    eq(viaAlias.pos.x, rightOf(400, 10, 20), "the alias's follower solves against the alias's rect")
    eq(viaOwner.pos.x, rightOf(0, 40, 20), "the owner's follower solves against the owner")

    aliasRect.x = 500
    ticks()
    eq(viaAlias.pos.x, rightOf(500, 10, 20), "the alias moving is seen, though its canonical id did not move")

    shared:MoveTo(60, 0)
    ownerPos.x = 60
    ticks()
    eq(viaOwner.pos.x, rightOf(60, 40, 20), "the owner moving reaches the follower named on it")

    -- A follower anchored through an alias is reached when the ELEMENT is what moved
    -- and the alias shares its geometry (no getRect of its own).
    fresh()
    local f = GeoFrame(0, 0, 40, 20)
    local p = { point = "CENTER", x = 0, y = 0 }
    Lib:Register("AL", "o", { frame = f, getPos = function() return p end })
    Lib:RegisterAnchorTarget("AL", "a", { frame = f })
    local child = follower("AL", "c", "AL:a")
    settle()
    f:MoveTo(90, 0)
    p.x = 90
    ticks()
    eq(child.pos.x, rightOf(90, 40, 20), "a plain alias follows its frame")
    check(R._canonMemo == nil, "the canon memo is not left open after a tick")
end

print("-- broken records and unknown targets are skipped")
do
    fresh()
    local bad = Lib:Register("BR", "bad", { frame = GeoFrame(0, 0, 10, 10), getPos = function() return "nope" end,
        onChanged = function() end })
    local unknown = follower("BR", "unknown", "BR:doesNotExist")
    local tFrame = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("BR", "tgt", { frame = tFrame })
    local good = follower("BR", "good", "BR:tgt")
    settle()
    check(bad.recordBroken, "setup: the record is broken")
    eq(#reported, 1, "a broken record reports once, as it always did")
    tFrame:MoveTo(300, 0)
    ticks(2)
    eq(good.pos.x, rightOf(300, 40, 20), "the others carry on")
    eq(unknown.pos.x, -500, "an anchor naming nothing holds")
    eq(#reported, 1, "nothing more is reported")
end

print("-- idle ticks do nothing")
do
    fresh()
    local tFrame = GeoFrame(100, 0, 40, 20)
    local parentPos = { point = "CENTER", x = 100, y = 0 }
    local parentCalls = 0
    Lib:Register("ID", "parent", { frame = tFrame, getPos = function() return parentPos end,
        onChanged = function(pos, reason)
            parentCalls = parentCalls + 1
            Lib.ApplyPosition(tFrame, pos)
        end })
    local a = follower("ID", "a", "ID:parent")
    local b = follower("ID", "b", "ID:a")
    local fired = 0
    local listener = {}
    Lib.RegisterCallback(listener, "PositionChanged", function() fired = fired + 1 end)
    settle()
    local ca, cb, cp, ff, sp = #a.calls, #b.calls, parentCalls, fired, tFrame.setPoints
    ticks(50)
    eq(#a.calls, ca, "no onChanged for a follower over fifty idle ticks")
    eq(#b.calls, cb, "...nor for a chained one")
    eq(parentCalls, cp, "...nor for the parent")
    eq(fired, ff, "no PositionChanged either")
    eq(tFrame.setPoints, sp, "and nothing is re-placed")

    -- Chains settle in one tick rather than one link per tick.
    tFrame:MoveTo(150, 0)
    parentPos.x = 150
    ticks()
    eq(a.pos.x, rightOf(150, 40, 20), "the first link moved")
    eq(b.pos.x, rightOf(a.pos.x, 20, 20), "...and the second, in the same tick")
    local c2 = #b.calls
    ticks(5)
    eq(#b.calls, c2, "...and then it goes quiet")
    Lib.UnregisterCallback(listener, "PositionChanged")
end

print("-- no work while a mover is being dragged")
do
    fresh()
    local tFrame = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("DR", "tgt", { frame = tFrame })
    local child = follower("DR", "child", "DR:tgt")
    settle()
    local measures = 0
    local real = R.GetTarget
    R.GetTarget = function(self, id) measures = measures + 1; return real(self, id) end
    local dragging = true
    NS.Proxy = { IsDragging = function() return dragging end, SyncMany = function() end,
                 Refresh = function() end, Remove = function() end }
    local ticksBefore = Lib:GetWatcherStats().ticks
    tFrame:MoveTo(300, 0)
    ticks(3)
    eq(measures, 0, "a drag in flight: nothing is even looked up")
    eq(child.pos.x, rightOf(100, 40, 20), "...and nothing moves")
    eq(Lib:GetWatcherStats().ticks, ticksBefore, "...and it does not count as a tick")
    dragging = false
    ticks()
    eq(child.pos.x, rightOf(300, 40, 20), "released: it catches up")
    R.GetTarget = real
end

print("-- the sweep's own guard stops a tick")
do
    fresh()
    local tFrame = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("SW", "tgt", { frame = tFrame })
    local nested, nestedTicks = 0, 0
    local pos = { point = "CENTER", x = -500, y = 0, anchor = anchorRight("SW:tgt") }
    Lib:Register("SW", "child", { frame = GeoFrame(-500, 0, 20, 10), getPos = function() return pos end,
        onChanged = function()
            nested = nested + 1
            local before = W.stats.ticks
            W:Tick()    -- a re-solve landing back in the watcher has to stop right there
            if W.stats.ticks == before then nestedTicks = nestedTicks + 1 end
        end })
    W:OnLogin()
    runTimers()
    ticks()
    nested, nestedTicks = 0, 0
    tFrame:MoveTo(300, 0)
    ticks()
    check(nested > 0, "setup: the follower was told")
    eq(nestedTicks, nested, "a tick from inside the sweep does nothing")
end

print("-- the ticker: opted-out addons pay nothing")
do
    fresh()
    Lib:RegisterAddon("Off", { watch = false })
    local p = function() return { point = "CENTER", x = 0, y = 0 } end
    Lib:Register("Off", "a", { frame = GeoFrame(0, 0, 10, 10), getPos = p })
    Lib:RegisterAnchorTarget("Off", "t", { frame = GeoFrame(0, 0, 10, 10) })
    Lib:Register("Mine", "b", { frame = GeoFrame(0, 0, 10, 10), getPos = p, watch = false })
    W:OnLogin()
    eq(tickersMade, 0, "everything opted out: the ticker never exists")
    eq(Lib:GetWatcherStats().running, false, "stats agree")
    eq(Lib:GetWatcherStats().watched, 0, "...and nothing is watched")
    Lib:Register("Off", "c", { frame = GeoFrame(0, 0, 10, 10), getPos = p })
    Lib:Unregister("Off", "c")
    eq(tickersMade, 0, "churn from an opted-out addon does not start it")
    eq(#timers, 0, "...nor schedule anything")

    -- A later watched registration starts it, the last one going stops it.
    Lib:Register("Later", "w", { frame = GeoFrame(0, 0, 10, 10), getPos = p })
    eq(tickersMade, 1, "a watched registration starts it")
    Lib:RegisterAnchorTarget("Later", "t", { frame = GeoFrame(0, 0, 10, 10) })
    eq(tickersMade, 1, "...and only once")
    eq(Lib:GetWatcherStats().running, true, "running")
    Lib:Unregister("Later", "w")
    check(not lastTicker.cancelled, "another watched thing remains: keeps running")
    Lib:Unregister("Later", "t")
    check(lastTicker.cancelled, "the last watched thing going cancels it")
    eq(W.ticker, nil, "...and clears it")

    Lib:RegisterAnchorTarget("Later", "t2", { frame = GeoFrame(0, 0, 10, 10) })
    eq(tickersMade, 2, "a later registration restarts it")
    Lib:UnregisterAddon("Later")
    check(lastTicker.cancelled, "UnregisterAddon cancels it too")

    -- A tick that finds nothing left stops the ticker by itself.
    Lib:RegisterAnchorTarget("Later", "t3", { frame = GeoFrame(0, 0, 10, 10) })
    local running = lastTicker
    R.targets["Later:t3"] = nil
    ticks()
    check(running.cancelled, "a tick with nothing left cancels itself")

    -- An addon opting out after the fact stops it as well.
    Lib:RegisterAnchorTarget("Turn", "t", { frame = GeoFrame(0, 0, 10, 10) })
    running = lastTicker
    Lib:RegisterAddon("Turn", { watch = false })
    check(running.cancelled, "RegisterAddon with watch = false stops it")
    Lib:RegisterAddon("Turn", {})
    check(W.ticker ~= nil, "...and opting back in restarts it")

    -- The real ticker calls the real Tick.
    local before = W.stats.ticks
    lastTicker.fn()
    eq(W.stats.ticks, before + 1, "the ticker's callback runs a tick")
end

print("-- a secret rect is skipped silently, for that tick only")
do
    fresh()
    local SECRET = setmetatable({}, { __tostring = function() return "secret" end })
    issecretvalue = function(v) return v == SECRET end

    local rect = { x = 100, y = 0, w = 40, h = 20 }
    Lib:RegisterAnchorTarget("SE", "byRect", { frame = FakeFrame(0, 0, 1, 1), getRect = function() return rect end })
    local byRect = follower("SE", "byRect2", "SE:byRect")
    local fFrame = GeoFrame(-100, 0, 40, 20)
    Lib:RegisterAnchorTarget("SE", "byFrame", { frame = fFrame })
    local byFrame = follower("SE", "byFrame2", "SE:byFrame")
    local gFrame = GeoFrame(0, 200, 40, 20)
    Lib:RegisterAnchorTarget("SE", "good", { frame = gFrame })
    local good = follower("SE", "good2", "SE:good")
    settle()
    wipe(reported)
    local seatRect, seatFrame = byRect.pos.x, byFrame.pos.x

    local realRect = rect
    rect = { x = SECRET, y = SECRET, w = SECRET, h = SECRET }
    local realCenter = fFrame.GetCenter
    function fFrame:GetCenter() return SECRET, SECRET end
    gFrame:MoveTo(50, 200)
    ticks(3)
    eq(#reported, 0, "nothing is reported")
    eq(good.pos.x, rightOf(50, 40, 20), "the other target is still followed")
    eq(byRect.pos.x, seatRect, "the secret rect's follower holds")
    eq(byFrame.pos.x, seatFrame, "the secret frame's follower holds")
    check(not R:GetTarget("SE:byRect").watchFailed, "and it is not marked as failed")

    rect = realRect
    rect.x = 300
    fFrame.GetCenter = realCenter
    fFrame:MoveTo(-300, 0)
    ticks()
    eq(byRect.pos.x, rightOf(300, 40, 20), "readable again: it is followed")
    eq(byFrame.pos.x, rightOf(-300, 40, 20), "...for a frame as well")

    -- A secret that surfaces as an error (arithmetic inside a consumer's getRect) is the
    -- same event, not a bug.
    fresh()
    local secretThrow = false
    Lib:RegisterAnchorTarget("SE", "t", { frame = FakeFrame(0, 0, 1, 1), getRect = function()
        if secretThrow then error("attempt to perform arithmetic on a secret number value") end
        return { x = 0, y = 0, w = 10, h = 10 }
    end })
    follower("SE", "c", "SE:t")
    settle()
    wipe(reported)
    secretThrow = true
    ticks(3)
    eq(#reported, 0, "an error naming a secret value is not reported")
    check(not R:GetTarget("SE:t").watchFailed, "...and does not mark the target")

    -- A secret scale on an element's frame is skipped too.
    fresh()
    issecretvalue = function(v) return v == SECRET end
    local sf = GeoFrame(0, 0, 10, 10)
    local spos = { point = "CENTER", x = 0, y = 0 }
    Lib:Register("SE", "scaled", { frame = sf, getPos = function() return spos end })
    settle()
    local sp = sf.setPoints
    local realScale = sf.GetEffectiveScale
    function sf:GetEffectiveScale() return SECRET end
    ticks(2)
    eq(sf.setPoints, sp, "a secret scale applies nothing")
    eq(#reported, 0, "...and reports nothing")
    sf.GetEffectiveScale = realScale
end

print("-- a target that throws reports once and stops nobody else")
do
    fresh()
    local goodFrame = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("ER", "good", { frame = goodFrame })
    local good = follower("ER", "goodChild", "ER:good")
    local calls = 0
    local throwing = false
    Lib:RegisterAnchorTarget("ER", "bad", { frame = FakeFrame(0, 0, 1, 1), getRect = function()
        calls = calls + 1
        if throwing then error("boom in getRect") end
        return { x = -100, y = 0, w = 10, h = 10 }
    end })
    local badChild = follower("ER", "badChild", "ER:bad")
    -- Depends on both: the bad primary must not stop it reaching the good backup.
    local both = follower("ER", "both", "ER:bad",
        { target = "ER:good", edge = "right", align = "center", offsetX = 0, offsetY = 0 })
    settle()
    eq(#reported, 0, "setup: clean so far")
    local holdX = badChild.pos.x

    throwing = true
    goodFrame:MoveTo(200, 0)
    ticks()
    eq(#reported, 1, "reported on the first tick")
    check(reported[1]:find("boom in getRect", 1, true), "...with the consumer's own message")
    eq(good.pos.x, rightOf(200, 40, 20), "the good target is still followed in that same tick")
    eq(both.pos.x, rightOf(200, 40, 20), "a bad primary falls through to a good backup")
    eq(badChild.pos.x, holdX, "its own follower holds")

    local callsAfter = calls
    goodFrame:MoveTo(300, 0)
    ticks(10)
    eq(#reported, 1, "still one report after ten more ticks")
    eq(calls, callsAfter, "...and its getRect is never called again")
    eq(good.pos.x, rightOf(300, 40, 20), "the good target keeps being followed")

    -- A re-registration is a clean start.
    throwing = false
    Lib:RegisterAnchorTarget("ER", "bad", { frame = FakeFrame(0, 0, 1, 1),
        getRect = function() return { x = -50, y = 0, w = 10, h = 10 } end })
    ticks()
    eq(badChild.pos.x, rightOf(-50, 10, 20), "registered again: followed again")
end

print("-- an element whose getFrame throws reports once and stops nobody else")
do
    fresh()
    local goodFrame = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("EF", "good", { frame = goodFrame })
    local good = follower("EF", "goodChild", "EF:good")
    local throwing = false
    local okFrame = GeoFrame(0, 0, 10, 10)
    local calls = 0
    Lib:Register("EF", "bad", { getFrame = function()
            if throwing then calls = calls + 1; error("boom in getFrame") end
            return okFrame
        end,
        getPos = function() return { point = "CENTER", x = 0, y = 0 } end, onChanged = function() end })
    settle()
    wipe(reported)
    throwing = true
    goodFrame:MoveTo(250, 0)
    ticks(5)
    eq(#reported, 1, "reported once")
    check(R:Get("EF:bad").watchFailed and R:GetTarget("EF:bad").watchFailed, "the element and its target are one object")
    eq(good.pos.x, rightOf(250, 40, 20), "the alias walk over it does not stop the good target's follower")
    -- A non-table rect and a rect with holes are consumer errors, not crashes.
    fresh()
    Lib:RegisterAnchorTarget("EF", "junk", { frame = FakeFrame(0, 0, 1, 1), getRect = function() return "nope" end })
    Lib:RegisterAnchorTarget("EF", "holes", { frame = FakeFrame(0, 0, 1, 1), getRect = function() return { x = 1 } end })
    follower("EF", "a", "EF:junk")
    follower("EF", "b", "EF:holes")
    W:OnLogin()
    wipe(reported)
    ticks(3)
    eq(#reported, 2, "each reports once")
    check(R:GetTarget("EF:junk").watchFailed and R:GetTarget("EF:holes").watchFailed, "...and each is marked")
end

print("-- an isRelevant that throws fails open and reports once")
do
    fresh()
    local f = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("IR", "t", { frame = f, isRelevant = function() error("boom in isRelevant") end })
    local child = follower("IR", "c", "IR:t")
    W:OnLogin()
    ticks(5)
    eq(#reported, 1, "one report over many ticks")
    f:MoveTo(200, 0)
    ticks()
    eq(child.pos.x, rightOf(200, 40, 20), "still treated as relevant")
end

print("-- a session measures every watched target, so slabs resize")
do
    fresh()
    local lone = GeoFrame(100, 0, 40, 20)
    local pos = { point = "CENTER", x = 100, y = 0 }
    Lib:Register("SS", "lone", { frame = lone, getPos = function() return pos end })
    Lib:Register("SS", "off", { frame = GeoFrame(0, 0, 10, 10), watch = false,
        getPos = function() return { point = "CENTER", x = 0, y = 0 } end })
    settle()
    eq(Lib:GetWatcherStats().measured, 0, "locked: a lone free element costs no measure")

    local synced = {}
    NS.Proxy = { IsDragging = function() return false end, Refresh = function() end, Highlight = function() end,
                 SyncMany = function(_, ids) for _, id in ipairs(ids) do synced[id] = true end end }
    NS.Session = { IsActive = function() return true end, IsSuspended = function() return false end }
    ticks()
    eq(Lib:GetWatcherStats().measured, 1, "unlocked: it is measured, and the opted-out one is not")
    wipe(synced)
    lone._w = 90
    ticks()
    check(synced["SS:lone"], "a resize re-measures its slab")
    wipe(synced)
    ticks(2)
    check(next(synced) == nil, "...and an idle tick does not")
    NS.Session, NS.Proxy = nil, nil
end

print("-- combat: a watched protected frame still defers")
do
    fresh()
    local tFrame = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("CB", "t", { frame = tFrame })
    local child = follower("CB", "c", "CB:t")
    function child.frame:IsProtected() return true end
    settle()
    local n = #child.calls
    IN_COMBAT = true
    tFrame:MoveTo(300, 0)
    ticks(2)
    eq(#child.calls, n, "not told during combat")
    eq(NS.pending["CB:c"], "parent", "...queued")
    IN_COMBAT = false
    NS:FlushPending()
    eq(#child.calls, n + 1, "told when combat ends")
    eq(child.pos.x, rightOf(300, 40, 20), "...at the new seat")
end

print("-- the existing sweep still works, and shares its stamps")
do
    fresh()
    local tFrame = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("SH", "t", { frame = tFrame })
    local child = follower("SH", "c", "SH:t")
    settle()
    tFrame:MoveTo(150, 0)
    eq(Lib:RefreshMovedTargets("SH", { "t" }), 1, "RefreshMovedTargets sees the move")
    eq(child.pos.x, rightOf(150, 40, 20), "...and re-solves")
    local n = #child.calls
    ticks()
    eq(#child.calls, n, "the next tick finds nothing left to do")
end

print("-- stats")
do
    fresh()
    local now = 0
    debugprofilestop = function() now = now + 2; return now end
    local tFrame = GeoFrame(100, 0, 40, 20)
    Lib:RegisterAnchorTarget("ST", "t", { frame = tFrame })
    follower("ST", "c", "ST:t")
    W:OnLogin()
    ticks(3)
    local s = Lib:GetWatcherStats()
    eq(s.running, true, "running")
    eq(s.watched, 2, "a target and an element (with its paired target counted once)")
    eq(s.measured, 2, "the named target and the anchored element")
    eq(s.ticks, 3, "ticks")
    eq(s.lastMs, 2, "lastMs from debugprofilestop")
    eq(s.maxMs, 2, "maxMs")
    debugprofilestop = nil
    ticks()
    eq(Lib:GetWatcherStats().ticks, 4, "works with no debugprofilestop")
end

print("-- no C_Timer at all")
do
    fresh()
    C_Timer = nil
    local ok = pcall(function()
        Lib:RegisterAnchorTarget("NT", "t", { frame = GeoFrame(0, 0, 10, 10) })
        W:OnLogin()
    end)
    check(ok, "login tolerates a missing C_Timer")
    eq(Lib:GetWatcherStats().running, false, "...with no ticker")
end

-- Everything back. W:Flush first so nothing pending leaks into another suite.
installTimers()
W:Flush()
W:Stop()
R.elements, R.targets, R.addons, R.queue, R.ready = saved.elements, saved.targets, saved.addons, saved.queue, saved.ready
NS.Proxy, NS.Session, NS.pending, NS.lastRect = saved.proxy, saved.session, saved.pending, saved.lastRect
W.loggedIn, W.ticker, W.stats, W.flushScheduled = saved.loggedIn, saved.ticker, saved.stats, saved.flushScheduled
C_Timer, geterrorhandler, issecretvalue, debugprofilestop = saved.timer, saved.handler, saved.secret, saved.clock
IN_COMBAT = saved.combat
