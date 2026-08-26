local NS = ...
local R = NS.Registry

-- ============================================================
-- MOVED-TARGET SWEEP -- Lib:RefreshMovedTargets (DandersMover/Core.lua)
-- ------------------------------------------------------------
-- The half of anchoring nothing announced. RefreshAnchorTarget is what a
-- consumer calls when it MOVED something -- it knows, it just ran the function
-- that moved it. Nothing tells it when a target changed SIZE: its own layout
-- code has no idea an anchor exists. So a child snapped to a container's right
-- edge kept the absolute x/y it was solved to at the OLD width, which in game
-- read as "anchor locations don't update at all when adjusting frame widths".
--
-- What is worth testing headless is exactly what is invisible in game:
--
--   1. A RESIZED TARGET RE-SOLVES ITS CHILDREN, and the consumer's apply
--      callback is handed the NEW position. That is the bug.
--   2. A RESIZED ELEMENT RE-SOLVES ITSELF. Solver.Resolve takes the child's own
--      w/h, so an anchored element that changed size is stale even though its
--      target never moved.
--   3. NO CHURN. The sweep is called every rendered frame while a slider is
--      held, so "nothing moved" and "moved by less than the epsilon" must both
--      cost nothing and notify nobody. Rects are recomputed from live geometry,
--      so exact equality would make sub-pixel jitter re-solve forever.
--   4. THE RE-ENTRANCY GUARD. A re-solve notifies the consumer, whose apply path
--      can land straight back in the sweep. Guarding it to a no-op is what makes
--      that a stop instead of a loop.
--   5. COMBAT. A secure element's move defers to PLAYER_REGEN_ENABLED like every
--      other move the lib makes -- the sweep adds no new combat path.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE, and this one
-- needs Core.lua (the sweep and the public API live there). test_registry_events
-- loads it too and reads back the frames that load created, so it must get there
-- first -- which the filename ordering gives it ("registry_events" < "registry_
-- resize"). The guarded load below is for a FILTERED run of this file alone.
-- Every global and namespace field replaced here is restored at the end.
-- ============================================================

local savedCreateFrame = CreateFrame
local savedInCombat    = InCombatLockdown

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
check(type(Lib.RefreshMovedTargets) == "function", "setup: RefreshMovedTargets is public")

-- Proxy is a UI module; test_proxy.lua may have loaded it into this same runtime
-- and the sweep pokes it on a self-resolve. Nothing here is testing proxies.
local savedProxy = NS.Proxy
NS.Proxy = nil

-- Register* queues until the client's ADDON_LOADED drains it; these blocks build
-- their fixtures directly, the way test_registry_events does.
local wasReady = R.ready
R.ready = true

-- ============================================================
-- FIXTURE
-- A box (the anchor target) and a child snapped to its right edge, both
-- reporting a rect the test can move. The child's rect is DERIVED from its own
-- record, so it behaves like a real frame: solve it and its rect follows.
-- ============================================================
-- Right edge / centre align, with Solver.SPACING = 2:
--   x = box.x + box.w/2 + 2 + child.w/2
local function expectedX(box, childW) return box.x + box.w / 2 + 2 + childW / 2 end

local function newFixture(addon)
    local fx = {
        box   = { x = 0, y = 0, w = 100, h = 50 },
        childW = 20, childH = 10,
        boxPos   = { point = "CENTER", x = 0, y = 0 },
        childPos = { point = "CENTER", x = -999, y = -999,
                     anchor = { target = addon .. ":box", edge = "right", align = "center" } },
        applied = {},        -- every onChanged the child saw, in order
    }
    Lib:Register(addon, "box", {
        title    = "box",
        frame    = FakeFrame(0, 0, 100, 50),
        getRect  = function() return fx.box end,
        getPos   = function() return fx.boxPos end,
        onChanged = function() end,
    })
    Lib:Register(addon, "child", {
        title    = "child",
        frame    = FakeFrame(0, 0, 20, 10),
        getRect  = function() return { x = fx.childPos.x, y = fx.childPos.y, w = fx.childW, h = fx.childH } end,
        getPos   = function() return fx.childPos end,
        onChanged = function(pos, reason)
            fx.applied[#fx.applied + 1] = { x = pos.x, y = pos.y, reason = reason }
        end,
    })
    fx.keys = { "box", "child" }
    fx.sweep = function() return Lib:RefreshMovedTargets(addon, fx.keys) end
    fx.done  = function() Lib:UnregisterAddon(addon) end
    return fx
end

-- ============================================================
-- 1. A RESIZED TARGET RE-SOLVES ITS CHILDREN
-- ============================================================
do
    local fx = newFixture("RZ1")

    -- First sweep: nothing has been measured yet, so both keys read as changed
    -- and the child settles onto its anchor for the first time.
    eq(fx.sweep(), 2, "first sweep measures every key as changed")
    eq(#fx.applied, 1, "the child is solved onto its anchor once")
    eq(fx.childPos.x, expectedX(fx.box, fx.childW), "child sits off the box's right edge")
    eq(fx.applied[1].x, fx.childPos.x, "onChanged was handed the solved position")
    -- The child is in the swept key list AND a descendant of the box, so the
    -- self-resolve gets to it first and the descendant pass then finds nothing
    -- left to do. One apply, not two -- which is the whole reason ResolveElement
    -- returns "did this actually move it".
    eq(fx.applied[1].reason, "reapply", "a key that is swept in its own right reports 'reapply'")

    -- THE BUG. The box gets wider; nothing moved it, and nothing told the lib.
    -- Swept by the BOX's key alone from here, so the child can only be reached as
    -- a descendant -- which is the path a real consumer's buff row takes.
    fx.keys = { "box" }
    fx.box.w = 200
    eq(fx.sweep(), 1, "the widened box is the one target that moved")
    eq(#fx.applied, 2, "the child is re-solved for the new width")
    eq(fx.childPos.x, expectedX(fx.box, fx.childW), "child tracks the box's new right edge")
    eq(fx.applied[2].x, fx.childPos.x, "onChanged carries the new x")
    eq(fx.applied[2].reason, "parent", "a descendant re-solve reports the existing 'parent' reason")

    -- A target that moves without resizing is the same path.
    fx.box.x = 300
    fx.sweep()
    eq(fx.childPos.x, expectedX(fx.box, fx.childW), "child follows a target that moved rather than resized")

    fx.done()
end

-- ============================================================
-- 2. A RESIZED ELEMENT RE-SOLVES ITSELF
-- Solver.Resolve takes the CHILD's w/h, so growing the child moves its own
-- solved centre even though the box never budged. RefreshAnchorTarget alone
-- would not catch this: it only walks descendants.
-- ============================================================
do
    local fx = newFixture("RZ2")
    fx.sweep()
    local before = fx.childPos.x

    fx.childW = 40
    eq(fx.sweep(), 1, "the child's own rect is what changed")
    eq(fx.childPos.x, expectedX(fx.box, 40), "the child re-solves against its own new width")
    check(fx.childPos.x ~= before, "and that is a different position")
    eq(fx.applied[#fx.applied].reason, "reapply", "a self re-solve reports the existing 'reapply' reason")

    fx.done()
end

-- ============================================================
-- 3. NO CHURN
-- ============================================================
do
    local fx = newFixture("RZ3")
    fx.sweep()
    local settled = #fx.applied

    eq(fx.sweep(), 0, "a sweep with nothing changed reports no movement")
    eq(#fx.applied, settled, "and notifies nobody")
    eq(fx.sweep(), 0, "still nothing on the next tick")

    -- Sub-pixel jitter: below the epsilon on every axis at once.
    fx.box.x, fx.box.y = fx.box.x + 0.4, fx.box.y - 0.4
    fx.box.w, fx.box.h = fx.box.w + 0.4, fx.box.h + 0.4
    eq(fx.sweep(), 0, "a sub-epsilon wobble is not a move")
    eq(#fx.applied, settled, "and re-solves nothing")

    -- ...and the wobble was NOT stamped, so it cannot mask a real change that
    -- happens to land just the other side of the same threshold.
    fx.box.w = fx.box.w + 0.4
    eq(fx.sweep(), 1, "wobble accumulating past the epsilon is a move")
    eq(#fx.applied, settled + 1, "and re-solves the child once")

    -- ☠ THE REGRESSION THIS BLOCK EXISTS FOR. The pass MOVED the child, so the
    -- child's own rect is no longer what was measured at the top of it. Stamping
    -- only the targets that read as moved left the child looking changed on the
    -- next tick -- a redundant pass every single tick, forever, which is exactly
    -- the "update loop" this whole mechanism must not become.
    eq(fx.sweep(), 0, "the tick after a real re-solve is quiet again")
    eq(#fx.applied, settled + 1, "and applies nothing more")

    fx.done()
end

-- ============================================================
-- 3b. NOTHING ANCHORED
-- A target can resize with no children at all -- the common case for a consumer
-- whose user has never anchored anything. The sweep reports the movement (that
-- is what it counts) and must apply nothing.
-- ============================================================
do
    local seen = 0
    Lib:Register("RZ4", "lonely", {
        title = "lonely", frame = FakeFrame(0, 0, 10, 10),
        getRect = function() return { x = 0, y = 0, w = 10, h = 10 } end,
        getPos  = function() return { point = "CENTER", x = 5, y = 5 } end,   -- no anchor block
        onChanged = function() seen = seen + 1 end,
    })
    local keys = { "lonely" }
    eq(Lib:RefreshMovedTargets("RZ4", keys), 1, "an unmeasured target reads as changed")
    eq(seen, 0, "an element with no anchor is never notified")
    eq(Lib:RefreshMovedTargets("RZ4", keys), 0, "and settles to a no-op")
    eq(seen, 0, "still nothing applied")

    -- An unknown key is skipped rather than erroring: consumers hand this a list
    -- they rebuild at runtime (DandersFrames' pinned sets come and go).
    local ok, res = pcall(function() return Lib:RefreshMovedTargets("RZ4", { "nope", "lonely" }) end)
    check(ok, "an unregistered key does not error")
    eq(res, 0, "and counts as nothing moved")

    Lib:UnregisterAddon("RZ4")
end

-- ============================================================
-- 4. THE RE-ENTRANCY GUARD
-- The child's onChanged does what a real consumer's does -- runs its layout --
-- and that layout ends up back in the sweep. One pass, not a stack of them.
-- ============================================================
do
    local fx = newFixture("RZ5")
    fx.sweep()

    -- Armed for ONE re-entry only. Left armed, every later sweep in this block
    -- would move the box again from inside its own callback and there would be
    -- no settled state to assert against.
    local nested, nestedResult, armed = 0, nil, true
    local addon = "RZ5"
    Lib:Register(addon, "child", {
        title    = "child",
        frame    = FakeFrame(0, 0, 20, 10),
        getRect  = function() return { x = fx.childPos.x, y = fx.childPos.y, w = fx.childW, h = fx.childH } end,
        getPos   = function() return fx.childPos end,
        onChanged = function(pos)
            fx.applied[#fx.applied + 1] = { x = pos.x, y = pos.y }
            if not armed then return end
            armed = false
            nested = nested + 1
            -- The re-entrant call, with the target moved AGAIN underneath it so
            -- an unguarded sweep would have real work to do and would recurse.
            fx.box.w = fx.box.w + 50
            nestedResult = fx.sweep()
        end,
    })

    local before = #fx.applied
    fx.box.w = fx.box.w + 50
    fx.sweep()
    eq(nested, 1, "onChanged ran once, not recursively")
    eq(nestedResult, 0, "the re-entrant sweep reports no work and returns immediately")
    eq(#fx.applied, before + 1, "exactly one apply came out of the pass")

    -- The guard is released with the pass. The box also grew AGAIN from inside
    -- that callback; the end-of-pass re-stamp records that as state already seen,
    -- so the next tick is quiet rather than chasing it (see the re-stamp note in
    -- Core.lua -- the alternative is a sweep that can never settle).
    eq(fx.sweep(), 0, "the guard clears without leaving phantom work behind")
    fx.box.w = fx.box.w + 50
    eq(fx.sweep(), 1, "and a genuine later change is still picked up")
    eq(fx.childPos.x, expectedX(fx.box, fx.childW), "and the child lands on the current edge")

    fx.done()
end

-- ============================================================
-- 5. COMBAT
-- No new combat path: a secure element's onChanged is deferred by NS:Notify and
-- replayed by NS:FlushPending, exactly as it is for a drag or a profile apply.
-- ============================================================
do
    local addon = "RZ6"
    local fx = { box = { x = 0, y = 0, w = 100, h = 50 }, childW = 20, childH = 10,
                 applied = 0 }
    local childPos = { point = "CENTER", x = 0, y = 0,
                       anchor = { target = addon .. ":box", edge = "right", align = "center" } }
    Lib:Register(addon, "box", {
        title = "box", frame = FakeFrame(0, 0, 100, 50),
        getRect = function() return fx.box end,
        getPos = function() return { point = "CENTER", x = 0, y = 0 } end,
        onChanged = function() end,
    })
    Lib:Register(addon, "child", {
        title = "child", secure = true, frame = FakeFrame(0, 0, 20, 10),
        getRect = function() return { x = childPos.x, y = childPos.y, w = fx.childW, h = fx.childH } end,
        getPos = function() return childPos end,
        onChanged = function() fx.applied = fx.applied + 1 end,
    })
    local keys = { "box", "child" }
    Lib:RefreshMovedTargets(addon, keys)
    local settled = fx.applied

    -- The FLAG, not the global: Core.lua cached InCombatLockdown at load. See shim.lua.
    IN_COMBAT = true
    fx.box.w = 400
    Lib:RefreshMovedTargets(addon, keys)
    eq(fx.applied, settled, "in combat: a secure element's move is not applied")
    check(NS.pending[R.Id(addon, "child")] ~= nil, "in combat: it is queued for the lockdown ending")

    IN_COMBAT = false
    NS:FlushPending()
    eq(fx.applied, settled + 1, "regen replays the held move")
    eq(childPos.x, expectedX(fx.box, fx.childW), "and it lands on the edge it was solved for")

    Lib:UnregisterAddon(addon)
end

-- ============================================================
-- 6. THE CACHE IS CLEANED UP WITH THE REGISTRATION
-- Consumers churn keys (DandersFrames re-registers its whole pinned list on
-- every add/remove), so a per-id cache that only ever grew would be a leak, and
-- a re-registered key would inherit a rect that belonged to something else.
-- ============================================================
do
    local fx = newFixture("RZ7")
    fx.sweep()
    check(NS.lastRect[R.Id("RZ7", "box")] ~= nil, "a swept target is cached")

    Lib:Unregister("RZ7", "box")
    check(NS.lastRect[R.Id("RZ7", "box")] == nil, "Unregister drops its cached rect")

    fx.done()
    check(NS.lastRect[R.Id("RZ7", "child")] == nil, "UnregisterAddon drops the addon's cached rects")
end

R.ready = wasReady
NS.Proxy = savedProxy
IN_COMBAT = false
CreateFrame = savedCreateFrame
InCombatLockdown = savedInCombat
