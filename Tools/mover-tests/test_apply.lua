local NS = ...

-- ============================================================
-- APPLY SCHEDULER -- DandersFrames/Core/ApplyScheduler.lua
-- ------------------------------------------------------------
-- The sink every heavy settings sweep now funnels into. What is worth testing
-- headless is exactly what is hardest to see in game:
--
--   1. COALESCING. N requests for one kind inside one rendered frame must run
--      the real body ONCE. In game that is invisible -- the result looks the
--      same either way, only the frame time differs.
--   2. THE FIXED DRAIN ORDER. headers -> raidLayout -> frames -> visible -> all
--      encodes two load-bearing orderings from the settings pages (notably
--      ApplyHeaderSettings before UpdateRaidLayout, PR #134). A reordering
--      regression shows up in game as "one raid setting silently stops
--      applying", months later.
--   3. COMBAT. The drain re-checks lockdown at FIRE time and must re-queue
--      rather than drop -- the failure mode is a settings change that looks
--      half-applied until something unrelated wanders past.
--   4. RE-ARM SEMANTICS. A real body that ends up calling one of the public
--      stubs must not re-enter the drain it is inside. Getting this wrong is an
--      infinite ping-pong or a double sweep, neither of which is obvious.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. Every global
-- this file replaces (CreateFrame, InCombatLockdown) is restored at the end.
--
-- The module is loaded fresh per block: its dirty set and drain frame are
-- file-locals, so a new load IS a clean scheduler.
-- ============================================================

local savedCreateFrame     = CreateFrame
local savedInCombatLockdown = InCombatLockdown

-- ---- fake frame ----------------------------------------------------
-- Not shim.lua's FakeUIFrame: this test has to READ BACK the event
-- registrations (the combat re-queue is only observable as one), and the shared
-- stub answers RegisterEvent through its no-op fallback.
local created
local function FakeSchedulerFrame()
    local f = { _shown = false, _scripts = {}, _events = {} }
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:IsShown() return self._shown end
    function f:SetScript(name, fn) self._scripts[name] = fn end
    function f:GetScript(name) return self._scripts[name] end
    function f:RegisterEvent(e) self._events[e] = true end
    function f:UnregisterEvent(e) self._events[e] = nil end
    return f
end

-- ---- DF stub -------------------------------------------------------
-- The five `_Now` bodies are counters that also record the order they ran in,
-- because "did each kind run once" and "in which order" are the two questions.
local function newDF()
    local df = { counts = {}, order = {} }
    df.Debug = function() end
    df.DebugWarn = function() end
    df.DebugError = function() end
    local function recorder(kind)
        df.counts[kind] = 0
        return function()
            df.counts[kind] = df.counts[kind] + 1
            df.order[#df.order + 1] = kind
        end
    end
    df.ApplyHeaderSettings_Now     = recorder("headers")
    df.UpdateRaidLayout_Now        = recorder("raidLayout")
    df.UpdateAllFrames_Now         = recorder("frames")
    df.RefreshAllVisibleFrames_Now = recorder("visible")
    df.UpdateAll_Now               = recorder("all")
    return df
end

local function loadScheduler()
    created = nil
    local df = newDF()
    load_df_file_into("Core/ApplyScheduler.lua", df)
    return df, created
end

local function joined(list)
    return table.concat(list, ",")
end

CreateFrame = function()
    created = FakeSchedulerFrame()
    return created
end
InCombatLockdown = function() return false end

-- ---- loads headless, exposes the sink ------------------------------
do
    local df, frame = loadScheduler()
    check(df.Apply ~= nil, "DF.Apply installed")
    check(type(df.Apply.Request) == "function", "Request exists")
    check(type(df.Apply.Flush) == "function", "Flush exists")
    check(type(df.Apply.IsPending) == "function", "IsPending exists")
    check(type(df.UpdateAll) == "function", "UpdateAll stub installed")
    check(type(df.UpdateAllFrames) == "function", "UpdateAllFrames stub installed")
    check(type(df.RefreshAllVisibleFrames) == "function", "RefreshAllVisibleFrames stub installed")
    check(type(df.ApplyHeaderSettings) == "function", "ApplyHeaderSettings stub installed")
    check(type(df.UpdateRaidLayout) == "function", "UpdateRaidLayout stub installed")
    check(frame ~= nil, "drain frame created when CreateFrame exists")
    check(frame:IsShown() == false, "drain frame starts disarmed")
    check(frame:GetScript("OnUpdate") ~= nil, "drain frame has an OnUpdate")
end

-- ---- the module tolerates a world with no CreateFrame ---------------
do
    CreateFrame = nil
    local df = newDF()
    load_df_file_into("Core/ApplyScheduler.lua", df)
    df:UpdateAllFrames()
    check(df.Apply:IsPending("frames"), "no CreateFrame: Request still marks dirty")
    df.Apply:Flush()
    eq(df.counts.frames, 1, "no CreateFrame: Flush still drains")
    CreateFrame = function()
        created = FakeSchedulerFrame()
        return created
    end
end

-- ---- N requests, one run -------------------------------------------
do
    local df, frame = loadScheduler()
    check(df.Apply:IsPending("frames") == false, "nothing pending at rest")
    for _ = 1, 25 do df:UpdateAllFrames() end
    check(df.Apply:IsPending("frames"), "request marks the kind pending")
    check(frame:IsShown(), "a request arms the drain frame")
    eq(df.counts.frames, 0, "nothing runs until the drain")
    df.Apply:Flush()
    eq(df.counts.frames, 1, "25 requests in one frame = 1 run")
    check(df.Apply:IsPending("frames") == false, "kind cleared after the drain")
    check(frame:IsShown() == false, "drain disarms the frame")
end

-- ---- the OnUpdate path is the same drain ---------------------------
do
    local df, frame = loadScheduler()
    df:UpdateAll()
    df:UpdateAll()
    frame:GetScript("OnUpdate")(frame)
    eq(df.counts.all, 1, "OnUpdate drains once")
    check(frame:IsShown() == false, "OnUpdate hides the frame again")
end

-- ---- the fixed drain order -----------------------------------------
do
    -- Requested in exactly the reverse of the drain order, so nothing but the
    -- ORDER table can be producing the result below.
    local df = loadScheduler()
    df:UpdateAll()
    df:RefreshAllVisibleFrames()
    df:UpdateAllFrames()
    df:UpdateRaidLayout()
    df:ApplyHeaderSettings()
    df.Apply:Flush()
    eq(joined(df.order), "headers,raidLayout,frames,visible,all", "drain runs in the fixed order")
    eq(df.counts.headers, 1, "headers once")
    eq(df.counts.raidLayout, 1, "raidLayout once")
    eq(df.counts.frames, 1, "frames once")
    eq(df.counts.visible, 1, "visible once")
    eq(df.counts.all, 1, "all once")
end

-- ---- the two load-bearing orderings --------------------------------
do
    -- (b) PR #134: ApplyHeaderSettings must precede UpdateRaidLayout, whichever
    -- order the call site happened to ask in.
    local df = loadScheduler()
    df:UpdateRaidLayout()
    df:ApplyHeaderSettings()
    df.Apply:Flush()
    eq(joined(df.order), "headers,raidLayout", "raidLayout requested first still drains after headers")
end

do
    -- "all" does NOT contain ApplyHeaderSettings (UpdateAll never calls it), so
    -- headers must still run, and must run first.
    local df = loadScheduler()
    df:UpdateAll()
    df:ApplyHeaderSettings()
    df.Apply:Flush()
    eq(joined(df.order), "headers,all", "all requested first still drains after headers")
end

do
    -- ☠ NO SUPERSEDE-DROPPING. Every kind requested alongside "all" still runs.
    local df = loadScheduler()
    df:UpdateAll()
    df:UpdateAllFrames()
    df:RefreshAllVisibleFrames()
    df.Apply:Flush()
    eq(joined(df.order), "frames,visible,all", "all does not swallow the other kinds")
end

-- ---- unknown kind ---------------------------------------------------
do
    local df, frame = loadScheduler()
    local ok = pcall(function() df.Apply:Request("bogus") end)
    check(ok, "unknown kind does not error")
    check(df.Apply:IsPending("bogus") == false, "unknown kind is not pending")
    check(frame:IsShown() == false, "unknown kind arms nothing")
    df.Apply:Flush()
    eq(joined(df.order), "", "unknown kind runs nothing")
    local ok2 = pcall(function() df.Apply:Request(nil) end)
    check(ok2, "nil kind does not error")
end

-- ---- combat: re-queue, don't drop ----------------------------------
do
    local df, frame = loadScheduler()
    InCombatLockdown = function() return true end
    df:UpdateAllFrames()
    df:ApplyHeaderSettings()
    df.Apply:Flush()
    eq(df.counts.frames, 0, "in combat: frames held")
    eq(df.counts.headers, 0, "in combat: headers held")
    check(df.Apply:IsPending("frames"), "in combat: frames still queued")
    check(df.Apply:IsPending("headers"), "in combat: headers still queued")
    check(frame._events["PLAYER_REGEN_ENABLED"], "in combat: regen replay armed")

    -- A second drain while still in combat must not lose anything either.
    df.Apply:Flush()
    eq(df.counts.frames, 0, "second in-combat drain still runs nothing")
    check(df.Apply:IsPending("frames"), "second in-combat drain keeps the queue")

    InCombatLockdown = function() return false end
    frame:GetScript("OnEvent")(frame, "PLAYER_REGEN_ENABLED")
    eq(joined(df.order), "headers,frames", "regen replays the held work, in drain order")
    eq(df.counts.frames, 1, "regen replay runs frames exactly once")
    check(frame._events["PLAYER_REGEN_ENABLED"] == nil, "regen listener unregisters itself")
    check(df.Apply:IsPending("frames") == false, "queue empty after the replay")
end

-- ---- Flush ----------------------------------------------------------
do
    local df = loadScheduler()
    df.Apply:Flush()
    eq(joined(df.order), "", "Flush with nothing pending is a no-op")

    df:UpdateRaidLayout()
    df.Apply:Flush()
    eq(df.counts.raidLayout, 1, "Flush runs pending work synchronously")
    df.Apply:Flush()
    eq(df.counts.raidLayout, 1, "a second Flush runs nothing")
end

-- ---- re-arm semantics: a body that calls the public stub ------------
do
    -- The echo guard. UpdateAllFrames_Now asks for its OWN kind again while the
    -- drain that invoked it is still running: that must land in the NEXT drain,
    -- not re-enter this one (which would be an unbounded loop).
    local df = loadScheduler()
    local inner = 0
    df.UpdateAllFrames_Now = function()
        inner = inner + 1
        df.order[#df.order + 1] = "frames"
        df:UpdateAllFrames()          -- the public stub, from inside the drain
    end
    df:UpdateAllFrames()
    df.Apply:Flush()
    eq(inner, 1, "self re-request does not re-enter the same drain")
    check(df.Apply:IsPending("frames"), "self re-request is left pending for the next drain")
    df.Apply:Flush()
    eq(inner, 2, "the next drain picks it up, once")
end

do
    -- Same guard across kinds, and in the direction that would otherwise slip
    -- through: headers runs FIRST, and asks for a kind that comes LATER in the
    -- drain order. The snapshot is what stops it joining this pass.
    local df = loadScheduler()
    df.ApplyHeaderSettings_Now = function()
        df.order[#df.order + 1] = "headers"
        df:UpdateAllFrames()
    end
    df:ApplyHeaderSettings()
    df.Apply:Flush()
    eq(joined(df.order), "headers", "a later kind requested mid-drain does not join this pass")
    check(df.Apply:IsPending("frames"), "it is pending for the next drain")
    df.Apply:Flush()
    eq(joined(df.order), "headers,frames", "and runs on the next drain")
end

-- ---- a missing _Now body is reported, not silent -------------------
do
    local df = loadScheduler()
    local errs = 0
    df.DebugError = function() errs = errs + 1 end
    df.UpdateAllFrames_Now = nil
    df:UpdateAllFrames()
    local ok = pcall(function() df.Apply:Flush() end)
    check(ok, "missing _Now body does not error")
    eq(errs, 1, "missing _Now body is reported once")
end

CreateFrame = savedCreateFrame
InCombatLockdown = savedInCombatLockdown
