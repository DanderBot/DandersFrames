-- ============================================================
-- PACED CONTAINER BUILDS (Frames/AuraContainer.lua)
-- Container builds spend a per-frame time budget; the rest queue and drain on later
-- frames. These pin: straight-through builds while there is budget, queueing once it is
-- spent, FIFO drain across frames, the combat budget, and skipping a handle that was
-- destroyed or built while it waited. The REAL block is lifted out by its source text.
-- ============================================================

local src = df_file_source("Frames/AuraContainer.lua"):gsub("\r\n", "\n")
local s = src:find("local BUILD_BUDGET_MS_COMBAT", 1, true)
local e = src:find("function AuraContainer:Create(parent, config)", 1, true)
check(s ~= nil and e ~= nil, "setup: found the paced-build block")
local block = src:sub(s, e - 1)

-- A fake clock: GetTime names the frame, debugprofilestop is wall time in ms.
local clock = { frame = 1, ms = 0 }
local drainer
local function FakeFrame()
    local f = { shown = false, scripts = {} }
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:SetScript(n, fn) self.scripts[n] = fn end
    drainer = f
    return f
end

local function load(inCombat)
    drainer = nil
    local DF = { playerInCombat = inCombat }
    function DF:Debug() end
    function DF:DebugWarn() end
    local chunk = assert(loadstring(
        "local DF, DBG, CreateFrame, GetTime, debugprofilestop, AuraContainer = ...\n" .. block .. "\nreturn pacedBuild",
        "@pacedBuild"))
    return chunk(DF, "TEST", FakeFrame, function() return clock.frame end,
        function() return clock.ms end, {})
end

-- A handle whose build costs `cost` ms of wall time and records the order.
local order = {}
local function H(name, cost)
    local h = { name = name, config = {} }
    function h:_build()
        clock.ms = clock.ms + cost
        self.backend = true
        order[#order + 1] = name
    end
    return h
end

local function nextFrame()
    clock.frame = clock.frame + 1
    if drainer and drainer.shown then drainer.scripts.OnUpdate(drainer) end
end

-- ---- idle budget: build straight through, then queue ----------------
do
    local pacedBuild = load(false)
    clock.frame, clock.ms, order = 10, 0, {}
    local a, b, c, d = H("a", 12), H("b", 12), H("c", 12), H("d", 12)
    pacedBuild(a); pacedBuild(b); pacedBuild(c)
    check(a.backend and b.backend and c.backend, "idle: builds run straight through while budget is left")
    pacedBuild(d)
    check(not d.backend, "idle: a build after the budget is spent waits")
    check(drainer and drainer.shown, "idle: the drainer is armed")
    nextFrame()
    check(d.backend, "idle: the queued build lands on the next frame")
    check(not drainer.shown, "idle: the drainer stands down once the queue is empty")
    eq(table.concat(order, ","), "a,b,c,d", "idle: builds keep their order")
end

-- ---- a burst drains across frames, FIFO, behind earlier work ---------
do
    local pacedBuild = load(false)
    clock.frame, clock.ms, order = 20, 0, {}
    local hs = {}
    for i = 1, 10 do hs[i] = H("h" .. i, 10) pacedBuild(hs[i]) end
    eq(#order, 3, "burst: three 10 ms builds fit the 30 ms frame")
    -- A new handle while others wait goes behind them, even on a fresh frame.
    clock.frame = clock.frame + 1
    local late = H("late", 1)
    pacedBuild(late)
    check(not late.backend, "burst: a new build never jumps the queue")
    local frames = 0
    while drainer.shown and frames < 20 do nextFrame(); frames = frames + 1 end
    eq(#order, 11, "burst: every build lands")
    eq(order[11], "late", "burst: the late build lands last")
    check(frames >= 3, "burst: the work spreads over several frames")
end

-- ---- combat uses the smaller budget ---------------------------------
do
    local pacedBuild = load(true)
    clock.frame, clock.ms, order = 40, 0, {}
    local a, b = H("a", 9), H("b", 6)
    pacedBuild(a); pacedBuild(b)
    check(a.backend, "combat: the first build runs")
    check(not b.backend, "combat: the 8 ms budget queues the second")
    nextFrame()
    check(b.backend, "combat: it lands next frame")
end

-- ---- destroyed or already-built handles are skipped ------------------
do
    local pacedBuild = load(false)
    clock.frame, clock.ms, order = 60, 0, {}
    pacedBuild(H("big", 40))
    local gone, rebuilt, ok = H("gone", 1), H("rebuilt", 1), H("ok", 1)
    pacedBuild(gone); pacedBuild(rebuilt); pacedBuild(ok)
    gone._destroyed = true
    rebuilt.backend = "from a Rebuild"
    nextFrame()
    eq(table.concat(order, ","), "big,ok", "skip: a destroyed or already-built handle is not built again")
end

-- ---- slot containers build at once, even with the budget spent ----
do
    local pacedBuild = load(false)
    clock.frame, clock.ms, order = 80, 0, {}
    pacedBuild(H("big", 40))
    local ov, one, row = H("overlay", 1), H("single", 1), H("row", 1)
    ov.config.mode, one.config.singleSlot = "overlay", true
    pacedBuild(ov); pacedBuild(one); pacedBuild(row)
    check(ov.backend and one.backend, "slots: overlay and single-slot builds are never deferred")
    check(not row.backend, "slots: a group row still waits for budget")
    nextFrame()
end

-- ---- a deferred build calls its owner back; an immediate one does not ----
do
    local pacedBuild = load(false)
    clock.frame, clock.ms, order = 70, 0, {}
    local calls = {}
    local now, later = H("now", 40), H("later", 1)
    now.config.onBuilt = function(h) calls[#calls + 1] = h.name end
    later.config.onBuilt = now.config.onBuilt
    pacedBuild(now); pacedBuild(later)
    eq(#calls, 0, "onBuilt: not called for a build that ran inside Create")
    nextFrame()
    eq(table.concat(calls, ","), "later", "onBuilt: called once when the deferred build lands")
end
