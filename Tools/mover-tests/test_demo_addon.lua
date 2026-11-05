-- ============================================================
-- THE DEV-ONLY DEMO ADDON (DandersMoverDemo/Core.lua, Easy.lua)
-- ------------------------------------------------------------
-- It never ships and the suite's parse gate does not walk it, so this is the only thing
-- that notices it no longer loads. It also runs /mdemo selftest against the REAL library
-- on a fake clock, because a selftest that has only ever been run in game is a selftest
-- nobody knows can fail.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE, and this name sorts ahead
-- of the first suite that loads DandersMover/Core.lua. Loading the shared copy here would
-- change what every later suite gets, so each scenario builds a PRIVATE library behind a
-- private LibStub with its own namespace, and every global is put back at the end.
-- ============================================================
local realPrint, realLibStub, realLoadstring = print, LibStub, loadstring
local sourceOf = mover_file_source

local savedGlobals = {}
for k, v in pairs(_G) do savedGlobals[k] = v end
local savedUiScale = UIParent._scale

local UI_W, UI_H = 960, 540     -- UIParent's fake centre

-- ============================================================
-- A FAKE WORLD: clock, frames that follow their SetPoint, events
-- ============================================================
local world, output, errors

local H = { LEFT = -1, RIGHT = 1, TOPLEFT = -1, BOTTOMLEFT = -1, TOPRIGHT = 1, BOTTOMRIGHT = 1 }
local V = { TOP = 1, BOTTOM = -1, TOPLEFT = 1, TOPRIGHT = 1, BOTTOMLEFT = -1, BOTTOMRIGHT = -1 }

local function newFrame(kind, name, parent, template)
    local f = FakeUIFrame()
    f._shown = true
    f._kind, f._name, f._template = kind, name, template
    f._events = {}
    if parent then f:SetFakeParent(parent) end
    function f:ClearAllPoints() self._point = nil end
    function f:SetPoint(point, _, _, x, y) self._point, self._ox, self._oy = point, x or 0, y or 0 end
    -- As in game: offsets are in the frame's own scale, and with no points there is no centre.
    function f:GetCenter()
        local point = rawget(self, "_point")
        if not point then return nil end
        local s = self:GetEffectiveScale()
        local ue = UIParent:GetEffectiveScale()
        return UI_W * ue / s + self._ox - (H[point] or 0) * self._w / 2,
               UI_H * ue / s + self._oy - (V[point] or 0) * self._h / 2
    end
    function f:IsProtected()
        if rawget(self, "_template") == "SecureUnitButtonTemplate" then return true, false end
        return false, false
    end
    function f:RegisterEvent(event) self._events[event] = true end
    function f:UnregisterEvent(event) self._events[event] = nil end
    world.frames[#world.frames + 1] = f
    return f
end

local function fire(event, ...)
    for _, f in ipairs(world.frames) do
        local script = f._scripts.OnEvent
        if f._events[event] and script then script(f, event, ...) end
    end
end

local function advance(seconds)
    local stop = world.now + seconds
    while world.now < stop do
        world.now = world.now + 0.05
        for _, t in ipairs(world.tickers) do
            if not t.cancelled and world.now >= t.nextAt then
                t.nextAt = t.nextAt + t.interval
                t.fn()
            end
        end
        local due = {}
        for i = #world.afters, 1, -1 do
            if world.now >= world.afters[i].at then
                table.insert(due, 1, world.afters[i])
                table.remove(world.afters, i)
            end
        end
        for _, a in ipairs(due) do a.fn() end
    end
end

local function privateLibStub(preload)
    local libs = { ["CallbackHandler-1.0"] = realLibStub("CallbackHandler-1.0") }
    local minors = {}
    local noop = setmetatable({}, { __index = function() return function() end end })
    libs["DandersUI-1.0"] = { NewHost = function() return noop end }
    local stub = {}
    function stub:NewLibrary(major, minor)
        if minors[major] and minors[major] >= minor then return nil end
        minors[major] = minor
        libs[major] = libs[major] or {}
        return libs[major]
    end
    if preload then libs[preload.major], minors[preload.major] = preload.lib, preload.minor end
    return setmetatable(stub, { __call = function(_, major, silent)
        if not libs[major] and not silent then error("no library " .. major) end
        return libs[major], minors[major]
    end })
end

local function run(path, name, ns)
    local fn = assert(realLoadstring(sourceOf(path), "@" .. path))
    return fn(name, ns)
end

local function moverCommand(msg) SlashCmdList.DANDERSMOVERDEMO(msg) end

-- mode: "lib" (the real library), "none" (no LibStub at all), or a number (an older library).
local function newWorld(mode, opts)
    opts = opts or {}
    world = { frames = {}, afters = {}, tickers = {}, now = 0 }
    output, errors = {}, {}
    UIParent._scale = opts.uiScale or 1
    IN_COMBAT = false
    SlashCmdList = {}
    -- The shim's check() prints through this global too, and those have to get out.
    print = function(msg)
        msg = tostring(msg)
        if msg:sub(1, 7) == "  FAIL:" then realPrint(msg) else output[#output + 1] = msg end
    end
    geterrorhandler = function() return function(msg) errors[#errors + 1] = tostring(msg) end end
    CreateFrame = newFrame
    UnitAffectingCombat = function() return IN_COMBAT end
    C_Timer = {
        After = function(delay, fn) world.afters[#world.afters + 1] = { at = world.now + delay, fn = fn } end,
        NewTicker = function(interval, fn)
            local t = { interval = interval, fn = fn, nextAt = world.now + interval, cancelled = false }
            function t:Cancel() self.cancelled = true end
            world.tickers[#world.tickers + 1] = t
            return t
        end,
    }
    DandersMoverDB, DandersMoverDemoDB, DandersMover = nil, opts.db, nil

    world.pns = { L = setmetatable({}, { __index = function(_, k) return k end }) }
    if mode == "lib" then
        LibStub = privateLibStub()
        run("Solver.lua", "DandersMover", world.pns)
        run("Registry.lua", "DandersMover", world.pns)
        run("Core.lua", "DandersMover", world.pns)
        fire("ADDON_LOADED", "DandersMover")
        world.R, world.Lib = world.pns.Registry, world.pns.Lib
    elseif mode == "none" then
        LibStub = nil
    else
        local older = setmetatable({ registered = {} }, { __index = function() return function() end end })
        function older:Register(addon, key) self.registered[addon .. ":" .. key] = true end
        older.ApplyPosition = function(frame, pos)
            frame:ClearAllPoints()
            frame:SetPoint(pos.point or "CENTER", UIParent, "CENTER", pos.x, pos.y)
        end
        world.older = older
        LibStub = privateLibStub({ major = "DandersMover-1.0", lib = older, minor = mode })
    end

    world.ns = {}
    run("../DandersMoverDemo/Core.lua", "DandersMoverDemo", world.ns)
    run("../DandersMoverDemo/Easy.lua", "DandersMoverDemo", world.ns)
    fire("ADDON_LOADED", "DandersMoverDemo")
    return world
end

local function login() fire("PLAYER_LOGIN") end

local function rect(frame)
    return world.ns.insetRect(frame, 0)
end

local function said(text)
    for _, line in ipairs(output) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

local function countSaid(text)
    local n = 0
    for _, line in ipairs(output) do
        if line:find(text, 1, true) then n = n + 1 end
    end
    return n
end

-- Failed lines go to the real print, so a red run says why.
local function showFails()
    for _, line in ipairs(output) do
        if line:find("FAIL", 1, true) then realPrint("    " .. line) end
    end
end

local function selftest()
    output = {}
    moverCommand("selftest")
    advance(12)
end

-- Records and frame state a selftest must leave exactly as it found them.
local function snapshot()
    local db = DandersMoverDemoDB.easy
    local out = {}
    for _, key in ipairs({ "leader", "follower", "backup", "manualLeader", "manualFollower" }) do
        local rec = db[key]
        local r = rect(world.ns.easyFrames[key])
        local w, h = world.ns.easyFrames[key]:GetSize()
        out[key] = { x = rec.x, y = rec.y, target = rec.anchor and rec.anchor.target,
                     fallback = rec.anchor and rec.anchor.fallback and rec.anchor.fallback.target,
                     fx = r.x, fy = r.y, w = w, h = h,
                     scale = world.ns.easyFrames[key]:GetScale(),
                     shown = world.ns.easyFrames[key]:IsShown() }
    end
    return out
end

local function sameSnapshot(a, b, label)
    for key, s in pairs(a) do
        for field, v in pairs(s) do
            local other = b[key][field]
            local same = v == other or (type(v) == "number" and type(other) == "number" and math.abs(v - other) < 0.01)
            check(same, string.format("%s: %s.%s (%s then %s)", label, key, field, tostring(v), tostring(other)))
        end
    end
end

-- ============================================================
-- SCENARIOS
-- ============================================================
realPrint("-- the TOC lists Easy.lua straight after Core.lua")
do
    local toc = sourceOf("../DandersMoverDemo/DandersMoverDemo.toc")
    check(toc:find("\nCore.lua\r?\nEasy.lua\r?\n"), "both files are listed, in order")
end

realPrint("-- registration: all short form, nothing placed before login")
do
    newWorld("lib")
    local R, db = world.R, DandersMoverDemoDB.easy
    for _, key in ipairs({ "healthbar", "buffrow", "iconstrip", "tinybadge", "combatonly", "secure" }) do
        check(R:Get("DandersMoverDemo:" .. key), "long form still registers: " .. key)
    end
    for _, key in ipairs({ "leader", "follower", "backup", "easySecure", "easyLazy" }) do
        local el = R:Get("DandersMoverDemoEasy:" .. key)
        check(el, "registered: " .. key)
        check(el and el.secure == nil, "no secure field: " .. key)
        check(type(db[key]) == "table", "record seeded: " .. key)
    end
    check(R.addons.DandersMoverDemoEasy.title == "Mover Demo: Easy", "the Easy addon's title")
    eq(R.addons.DandersMoverDemoManual.watch, false, "Manual opts out of the watcher")
    check(R:Get("DandersMoverDemoManual:manualFollower"), "manualFollower registered")
    eq(R:IsSecure(R:Get("DandersMoverDemoEasy:easySecure")), true, "easySecure is detected as secure")
    eq(R:IsSecure(R:Get("DandersMoverDemoEasy:leader")), false, "leader is not")
    check(R:Get("DandersMoverDemoEasy:easyLate") == nil, "easyLate is not registered yet")
    check(rect(world.ns.easyFrames.leader) == nil, "leader has no position before login")
    eq(#errors, 0, "no errors reported")
end

realPrint("-- login: the library places the short-form frames, late ones follow")
do
    newWorld("lib")
    login()
    local db, frames = DandersMoverDemoDB.easy, world.ns.easyFrames
    for _, key in ipairs({ "leader", "follower", "backup", "easySecure", "manualLeader", "manualFollower" }) do
        local r = rect(frames[key])
        check(r and r.x == db[key].x and r.y == db[key].y, "at its record after login: " .. key)
    end
    check(frames.easyLate == nil, "easyLate: not yet")
    advance(3.1)
    check(frames.easyLate, "easyLate: created at login + 3s")
    check(rect(frames.easyLate) and rect(frames.easyLate).x == db.easyLate.x, "easyLate: placed on the next frame")
    check(world.Lib:GetWatcherStats().running, "the watcher runs")
    check(frames.easyLazy == nil, "easyLazy: no frame yet")
    advance(2.2)
    check(frames.easyLazy, "easyLazy: created at login + 5s")
    check(rect(frames.easyLazy) and rect(frames.easyLazy).y == db.easyLazy.y, "easyLazy: placed by the watcher")
    eq(#errors, 0, "no errors reported")
end

realPrint("-- selftest: passes against the real library, and puts everything back")
for _, uiScale in ipairs({ 1, 0.8 }) do
    newWorld("lib", { uiScale = uiScale })
    login()
    advance(6)
    local before = snapshot()
    selftest()
    showFails()
    check(said("selftest: "), "summary printed at UI scale " .. uiScale)
    eq(countSaid("FAIL"), 0, "no FAIL lines at UI scale " .. uiScale)
    check(countSaid("PASS") >= 15, "it checked things (" .. countSaid("PASS") .. " PASS lines)")
    check(said(" 0 failed"), "the summary says 0 failed")
    sameSnapshot(before, snapshot(), "restored")
    advance(2)
    sameSnapshot(before, snapshot(), "still restored after the watcher has had its ticks")
    eq(#errors, 0, "no errors reported")
end

realPrint("-- selftest: starting from a messy state")
do
    newWorld("lib")
    login()
    advance(6)
    for _, c in ipairs({ "link", "move", "size", "toggle" }) do moverCommand(c) end
    advance(1)
    moverCommand("scale")
    advance(1)
    moverCommand("move")
    advance(1)
    local before = snapshot()
    selftest()
    showFails()
    eq(countSaid("FAIL"), 0, "no FAIL lines")
    sameSnapshot(before, snapshot(), "restored")
    advance(2)
    sameSnapshot(before, snapshot(), "still restored after the watcher has had its ticks")
    eq(#errors, 0, "no errors reported")
end

realPrint("-- selftest: can fail, and still restores")
do
    newWorld("lib")
    login()
    advance(6)
    local before = snapshot()
    -- A library whose watcher never ticks: everything that relies on it has to go red.
    for _, t in ipairs(world.tickers) do t.cancelled = true end
    selftest()
    check(said("|cffff4040FAIL|r move: follower's record"), "a follower that did not follow is a FAIL")
    check(said("|cffff4040FAIL|r hide: follower"), "...as is one that did not switch to the backup")
    check(not said(" 0 failed"), "and the summary says so")
    check(said("|cff40ff40PASS|r manual: manualFollower did NOT follow"), "the rest of the test still ran")
    sameSnapshot(before, snapshot(), "restored after failures")
end

realPrint("-- selftest: too early says to wait")
do
    newWorld("lib")
    -- The selftest itself takes about as long as easyLazy's five seconds, so an early run
    -- is only pinned down by holding that frame back.
    local realAfter = C_Timer.After
    C_Timer.After = function(delay, fn) if delay < 5 then realAfter(delay, fn) end end
    login()
    C_Timer.After = realAfter
    selftest()
    check(said("easyLazy: not there yet, wait a few seconds after login"), "the hint is printed")
    check(said("selftest: "), "the summary still comes")
end

realPrint("-- selftest: refusals and being interrupted")
do
    newWorld("lib")
    login()
    advance(6)
    IN_COMBAT = true
    output = {}
    moverCommand("selftest")
    check(said("refused: in combat"), "refused in combat")
    check(#world.afters == 0, "...before scheduling anything")
    IN_COMBAT = false

    world.pns.Session = { IsActive = function() return true end, IsSuspended = function() return false end }
    output = {}
    moverCommand("selftest")
    check(said("refused: the editor is unlocked"), "refused while unlocked")
    world.pns.Session = nil

    local before = snapshot()
    output = {}
    moverCommand("selftest")
    advance(1.2)
    moverCommand("move")
    check(said("selftest is running"), "other commands wait for it")
    IN_COMBAT = true
    advance(2)
    IN_COMBAT = false
    check(said("stopped early: combat started"), "combat stops it")
    advance(2)
    check(said("selftest: "), "with a summary")
    sameSnapshot(before, snapshot(), "restored after being interrupted")
    output = {}
    moverCommand("stats")
    check(said("watcher: running=true"), "stats prints")
end

realPrint("-- commands")
do
    newWorld("lib")
    login()
    advance(6)
    local db, frames = DandersMoverDemoDB.easy, world.ns.easyFrames
    local leaderRec = { x = db.leader.x, y = db.leader.y }

    moverCommand("link")
    check(db.follower.anchor.target == "DandersMoverDemoEasy:leader", "link: follower's anchor")
    check(db.follower.anchor.fallback.target == "DandersMoverDemoEasy:backup", "link: follower's fallback")
    check(db.manualFollower.anchor.target == "DandersMoverDemoManual:manualLeader", "link: manualFollower's anchor")

    local fy, my = db.follower.y, db.manualFollower.y
    moverCommand("move")
    advance(0.5)
    eq(db.leader.x, leaderRec.x, "move: leader's record is untouched")
    eq(rect(frames.leader).x, leaderRec.x + 140, "move: leader's frame moved")
    eq(db.follower.y, fy + 60, "move: the watcher brought follower along")
    eq(db.manualFollower.y, my, "move: manualFollower stayed")
    moverCommand("move")
    advance(0.5)
    eq(rect(frames.leader).x, leaderRec.x, "move again: back at the record")

    moverCommand("size")
    eq(frames.leader:GetWidth(), 270, "size: leader is bigger")
    eq(frames.manualLeader:GetHeight(), 58, "size: manualLeader is bigger")
    moverCommand("size")
    eq(frames.leader:GetWidth(), 190, "size again: back")

    moverCommand("scale")
    eq(frames.leader:GetScale(), 1.3, "scale: 1.3")
    advance(0.5)
    eq(rect(frames.leader).x, leaderRec.x, "scale: still at its record")
    moverCommand("scale")
    eq(frames.leader:GetScale(), 1, "scale again: 1")

    moverCommand("toggle")
    check(not frames.leader:IsShown() and not frames.manualLeader:IsShown(), "toggle: both hidden")
    moverCommand("toggle")
    check(frames.leader:IsShown() and frames.manualLeader:IsShown(), "toggle again: both shown")

    moverCommand("unlink")
    check(db.follower.anchor == nil and db.manualFollower.anchor == nil, "unlink: both detached")

    output = {}
    moverCommand("nonsense")
    check(said("selftest") and said("stress"), "the usage line lists the new commands")
    eq(#errors, 0, "no errors reported")
end

realPrint("-- stress")
do
    newWorld("lib")
    login()
    advance(6)
    local R, Lib = world.R, world.Lib
    local before = Lib:GetWatcherStats().watched
    moverCommand("stress")
    eq(Lib:GetWatcherStats().watched, before + 40, "default 40")
    advance(0.5)
    local s1 = R:Get("DandersMoverDemoStress:s1")
    local s40 = R:Get("DandersMoverDemoStress:s40")
    check(R:GetPos(s1).anchor.target == "DandersMoverDemoEasy:leader", "the chain starts at leader")
    check(R:GetPos(s40).anchor.target == "DandersMoverDemoStress:s39", "each link anchors to the one before")
    local y40 = R:GetPos(s40).y
    moverCommand("move")
    advance(0.5)
    eq(R:GetPos(s40).y, y40 + 60, "a leader move reaches the far end of the chain")
    moverCommand("move")
    advance(0.5)

    moverCommand("stress 999")
    eq(Lib:GetWatcherStats().watched, before + 200, "capped at 200")
    moverCommand("stress 5")
    eq(Lib:GetWatcherStats().watched, before + 5, "a second run replaces the first")
    check(not world.frames[#world.frames]:IsShown(), "frames beyond the new count are hidden")
    output = {}
    moverCommand("stress off")
    check(R.addons.DandersMoverDemoStress == nil, "off: the addon is gone")
    eq(Lib:GetWatcherStats().watched, before, "off: the watcher dropped them")
    check(DandersMoverDemoDB.stress == nil and DandersMoverDemoDB.easy.s1 == nil, "nothing was saved")
    output = {}
    moverCommand("stress lots")
    check(said("usage: /mdemo stress"), "a bad count gets the usage line")
    eq(#errors, 0, "no errors reported")
end

realPrint("-- a link saved across a reload")
do
    newWorld("lib")
    login()
    advance(6)
    moverCommand("link")
    local saved = DandersMoverDemoDB
    local seat = saved.easy.follower.y
    local manualSeat = saved.easy.manualFollower.y
    newWorld("lib", { db = saved })
    login()
    eq(saved.easy.follower.y, seat, "follower re-solved at login")
    eq(rect(world.ns.easyFrames.follower).y, seat, "...and placed")
    eq(rect(world.ns.easyFrames.manualFollower).y, manualSeat, "manualFollower too")
    eq(#errors, 0, "no errors reported")
end

realPrint("-- no library: frames appear from their records, nothing else")
do
    newWorld("none")
    check(said("not installed: easy API section skipped"), "one line says so")
    eq(countSaid("skipped"), 1, "...only one")
    local frames, db = world.ns.easyFrames, DandersMoverDemoDB.easy
    eq(rect(frames.leader).x, db.leader.x, "leader is placed")
    eq(rect(frames.easySecure).y, db.easySecure.y, "easySecure is placed")
    eq(rect(world.ns.frames.healthbar).x, -320, "the long-form frames still are too")
    login()
    advance(5.5)
    eq(rect(frames.easyLate).y, db.easyLate.y, "easyLate is placed")
    eq(rect(frames.easyLazy).y, db.easyLazy.y, "easyLazy is placed")
    output = {}
    moverCommand("selftest")
    check(said("needs DandersMover minor 9"), "commands explain themselves")
    moverCommand("status")
    check(said("NOT installed"), "the old commands still work")
    eq(#errors, 0, "no errors reported")
end

realPrint("-- an older library: the new section stays out of its way")
do
    newWorld(8)
    check(said("minor 8 is older than 9"), "one line says so")
    check(world.older.registered["DandersMoverDemo:healthbar"], "long form registers with it")
    check(not world.older.registered["DandersMoverDemoEasy:leader"], "short form does not")
    eq(rect(world.ns.easyFrames.leader).x, DandersMoverDemoDB.easy.leader.x, "the frames are still placed")
    login()
    advance(5.5)
    check(world.ns.easyFrames.easyLazy, "late frames still arrive")
    eq(#errors, 0, "no errors reported")
end

-- ============================================================
-- EVERYTHING BACK
-- ============================================================
UIParent._scale = savedUiScale
local added = {}
for k in pairs(_G) do
    if savedGlobals[k] == nil then added[#added + 1] = k end
end
for _, k in ipairs(added) do _G[k] = nil end
for k, v in pairs(savedGlobals) do _G[k] = v end
