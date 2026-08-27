local NS = ...

-- ============================================================
-- Fx.MoveTo -- THE POSITION SIBLING OF FadeTo / ScaleTo
--
-- The contract, and the whole of what makes it safe to use for chrome that
-- something else measures:
--
--   * the ANCHORS land immediately, before anything animates, so a client (or a
--     harness) with no animation groups is left in exactly the right place;
--   * the glide is a REVERSED Translation of the delta the re-anchor produced,
--     so the animation state reverts on finish and the target rests at its true
--     point -- nothing has to be put back;
--   * a target with unresolved anchors, or one that did not actually move,
--     re-anchors and plays nothing;
--   * a second MoveTo mid-glide stops the first, so a spammed selection cannot
--     stack groups on one frame;
--   * Fx.Cancel stops it and, unlike alpha, leaves the POSITION alone.
--
-- ☠ THE SHARED FakeUIFrame ANSWERS nil TO CreateAnimationGroup, which is the
-- headless path -- correct for every other suite and useless for testing the
-- animation. The recording frame below is local to this file and is the only
-- thing here that grows an animation group.
-- ============================================================

local Fx = NS.__DandersUI.Fx
check(type(Fx.MoveTo) == "function", "fx: MoveTo is published on Fx")

-- ---- a frame that records what its animation group was asked for ----
-- Geometry is the settable fake centre the shim already models: MoveTo reads
-- GetLeft/GetBottom either side of place(), so a test moves the frame by having
-- place() call SetFakeCenter -- which is exactly what a real re-anchor would do
-- to the rendered position, minus anchors the stub does not resolve.
local function animFrame(w, h, cx, cy)
    local f = FakeUIFrame(w or 10, h or 4, cx or 0, cy or 0)
    f._groups = {}
    function f:CreateAnimationGroup()
        local g = { _playing = false, _plays = 0, _stops = 0, _reverse = nil }
        function g:CreateAnimation(kind)
            local a = { _kind = kind }
            function a:SetOffset(x, y) self._ox, self._oy = x, y end
            function a:SetDuration(d) self._dur = d end
            function a:SetSmoothing(s) self._smooth = s end
            return a
        end
        function g:Play(reverse)
            self._playing = true
            self._plays = self._plays + 1
            self._reverse = reverse and true or false
        end
        function g:Stop() self._playing = false; self._stops = self._stops + 1 end
        function g:IsPlaying() return self._playing end
        function g:SetScript() end
        self._groups[#self._groups + 1] = g
        return g
    end
    return f
end

-- ============================================================
-- 1. THE ANCHORS LAND FIRST, AND THE GLIDE IS THE DELTA, REVERSED
-- ============================================================
do
    local f = animFrame(10, 4, 100, 50)
    local placed = 0
    Fx.MoveTo(f, function(t)
        placed = placed + 1
        check(t == f, "move: place() is handed the target it is moving")
        t:SetPoint("BOTTOMLEFT", nil, "BOTTOMLEFT", 0, 0)
        t:SetFakeCenter(160, 50)                       -- +60 on x, nothing on y
    end, 0.2)

    eq(placed, 1, "move: place() ran exactly once")
    eq(f:GetNumPoints(), 1, "move: ...and its anchor is already on the frame")
    eq(#f._groups, 1, "move: one animation group was built")

    local g = f._groups[1]
    eq(g._plays, 1, "move: it played once")
    eq(g._reverse, true, "move: REVERSED -- forward the group drifts away, backwards it arrives")
    eq(g.move._kind, "Translation", "move: the animation is a Translation")
    eq(g.move._ox, -60, "move: the offset is where it CAME FROM, relative to where it now is")
    eq(g.move._oy, 0, "move: ...on both axes")
    eq(g.move._dur, 0.2, "move: at the duration asked for")
    eq(g.move._smooth, "IN", "move: forward smoothing IN, which reversed is the ease-out wanted")
end

-- The default duration, and a vertical move (the nav rail's axis).
do
    local f = animFrame(4, 28, 20, 400)
    Fx.MoveTo(f, function(t) t:SetFakeCenter(20, 316) end)
    local g = f._groups[1]
    eq(g.move._ox, 0, "move: a vertical glide has no x component")
    eq(g.move._oy, 84, "move: ...and carries the whole y delta")
    eq(g.move._dur, 0.12, "move: the default duration is 0.12")
end

-- ============================================================
-- 2. NOTHING TO GLIDE: RE-ANCHOR AND PLAY NOTHING
-- ============================================================
do
    -- A place() that does not move the frame.
    local f = animFrame(10, 4, 100, 50)
    local placed = 0
    Fx.MoveTo(f, function() placed = placed + 1 end, 0.2)
    eq(placed, 1, "still: place() still ran")
    eq(#f._groups, 0, "still: but a frame that did not move builds no animation group")
end

do
    -- Unresolved anchors: GetLeft answers nil, so there is no visible "from".
    local f = animFrame(10, 4, 100, 50)
    f.GetLeft = function() return nil end
    local placed = 0
    Fx.MoveTo(f, function(t) placed = placed + 1; t:SetFakeCenter(160, 50) end, 0.2)
    eq(placed, 1, "unlaid: place() ran, so the anchors are right")
    eq(#f._groups, 0, "unlaid: ...and it lands instantly rather than sweeping from nowhere")
end

do
    -- The headless path every other suite takes: no animation groups at all.
    local f = FakeUIFrame(10, 4, 100, 50)
    local placed = 0
    Fx.MoveTo(f, function(t) placed = placed + 1; t:SetFakeCenter(160, 50) end)
    eq(placed, 1, "headless: a client with no animation groups still re-anchors")
end

-- Guards.
do
    local ran = 0
    Fx.MoveTo(nil, function() ran = ran + 1 end)
    Fx.MoveTo(animFrame(), nil)
    eq(ran, 0, "guard: a nil target does not call place()")
end

-- ============================================================
-- 3. A SECOND MOVE MID-GLIDE STOPS THE FIRST
-- One group per frame, reused -- a spammed tab click cannot stack them.
-- ============================================================
do
    local f = animFrame(10, 4, 100, 50)
    Fx.MoveTo(f, function(t) t:SetFakeCenter(160, 50) end)
    local g = f._groups[1]
    check(g:IsPlaying(), "spam: the first glide is running")

    Fx.MoveTo(f, function(t) t:SetFakeCenter(220, 50) end)
    eq(#f._groups, 1, "spam: the SAME group is reused, not a second one")
    eq(g._stops, 1, "spam: the running glide was stopped first")
    eq(g._plays, 2, "spam: ...and the new one played")
    eq(g.move._ox, -60, "spam: from where it was when the second call came in")

    -- ...and a re-anchor to where it already is stops the glide without replaying.
    Fx.MoveTo(f, function() end)
    eq(g._stops, 2, "spam: a move to the same place still stops what was running")
    eq(g._plays, 2, "spam: ...and plays nothing new")
end

-- ============================================================
-- 4. CANCEL STOPS THE GLIDE AND LEAVES THE POSITION ALONE
-- The same rule ScaleTo already had: alpha is Fx's, position is the caller's.
-- ============================================================
do
    local f = animFrame(10, 4, 100, 50)
    Fx.MoveTo(f, function(t) t:SetFakeCenter(160, 50) end)
    local g = f._groups[1]
    f:SetAlpha(0.3)
    Fx.Cancel(f)
    eq(g._stops, 1, "cancel: the glide was stopped")
    check(not g:IsPlaying(), "cancel: ...and is no longer playing")
    eq(f:GetAlpha(), 1, "cancel: alpha is restored, as it always was")
    eq(select(1, f:GetCenter()), 160, "cancel: the resting POSITION is the caller's and is left alone")
end

-- A frame Fx has never touched: the shim seeds fxMove FALSE for the same reason
-- it seeds the other five, and Cancel must not choke on it.
do
    local f = FakeUIFrame(10, 4)
    eq(rawget(f, "fxMove"), false, "cancel: fxMove is seeded false on the shared stub")
    Fx.Cancel(f)
    eq(f:GetAlpha(), 1, "cancel: a frame with no groups cancels cleanly")
end
