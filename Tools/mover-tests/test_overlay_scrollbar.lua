local NS = ...

-- ============================================================
-- StyleScrollBar's OVERLAY VARIANT
--
-- A bar that is a hairline until it matters: it rests narrow and dim, goes to
-- the full width and full alpha while the pointer is on it or the pane is being
-- scrolled, and shrinks back a moment after the last of either.
--
-- The state machine is the whole of it, and every input into it is a script the
-- stub records, so this is a real behavioural test rather than a source read:
--
--   * it starts narrow, dim, and with the grab area already made up;
--   * hover, wheel, scroll and a thumb press each wake it;
--   * the idle clock does not run while the pointer is on it OR the thumb is
--     held -- a drag that pauses must not shrink out from under the cursor;
--   * it shrinks exactly once the hold has elapsed, and the timer stops itself;
--   * the grab area is the SAME size at either width -- what the bar gives up
--     visually it takes back invisibly;
--   * styling the same bar twice does not double the hooks;
--   * and a bar styled WITHOUT the opt is untouched by any of it.
--
-- ☠ THE REAL Theme.lua, loaded into a throwaway namespace exactly the way run.py
-- lifts the surface-style resolver out of it -- it declares no frames at file
-- scope. The scroll-frame stub below is hand-built rather than a FakeUIFrame:
-- StyleScrollBar probes .Background / .Track / .Thumb, and the shared stub's
-- catch-all __index answers each of those with a FUNCTION, which it then indexes.
-- ============================================================

local prevCreateFrame = CreateFrame

-- ---- the stub ------------------------------------------------------
local function part()
    local p = { _scripts = {}, _shown = true, _hitRect = nil }
    function p:Hide() self._shown = false end
    function p:Show() self._shown = true end
    function p:SetSize() end
    function p:SetAllPoints() end
    function p:SetColorTexture() end
    function p:CreateTexture() return part() end
    function p:SetHitRectInsets(l, r, t, b) self._hitRect = { l, r, t, b } end
    -- HookScript COMPOSES, as the client's does: the template may already own
    -- these, and a variant that silently replaced them would hide exactly the
    -- bug this file is guarding against.
    function p:HookScript(name, fn)
        local prev = self._scripts[name]
        self._scripts[name] = prev and function(...) prev(...) return fn(...) end or fn
    end
    function p:SetScript(name, fn) self._scripts[name] = fn end
    function p:GetScript(name) return self._scripts[name] end
    return p
end

local function scrollStub()
    local sf = part()
    local sb = part()
    sb._w, sb._alpha = nil, nil
    function sb:SetWidth(w) self._w = w end
    function sb:GetWidth() return self._w end
    function sb:SetAlpha(a) self._alpha = a end
    function sb:GetAlpha() return self._alpha end
    sb.Background = part()
    sb.Track = part()
    sb.Track.Begin, sb.Track.End, sb.Track.Middle = part(), part(), part()
    sb.Thumb = part()
    sb.Thumb.Begin, sb.Thumb.End, sb.Thumb.Middle = part(), part(), part()
    sb.Thumb.customBg = nil
    sb.Back, sb.Forward = part(), part()
    sf.ScrollBar = sb
    return sf, sb
end

-- The ticker StyleScrollBar builds for the idle clock. It is the ONLY frame the
-- overlay path creates, so a bare recorder is enough.
CreateFrame = function()
    local f = part()
    f._shown = true
    return f
end

local tns = { __DandersUI = { _state = {}, _priv = {} } }
load_ui_file_into("Theme.lua", tns)
local UI = tns.__DandersUI
CreateFrame = prevCreateFrame

local SC = UI.Scroll
local function fire(p, script, ...) local fn = p:GetScript(script) if fn then return fn(p, ...) end end
-- The ticker only ticks while it is shown -- that IS its on/off switch.
local function tick(sb, elapsed)
    local t = sb.dfOverlayTicker
    if not t._shown then return end
    fire(t, "OnUpdate", elapsed)
end

-- ============================================================
-- 1. THE TOKENS
-- ============================================================
do
    eq(SC.gutter, SC.bar + SC.pad, "tokens: the gutter is still bar + pad, derived")
    check(SC.overlayIdle < SC.bar, "tokens: the idle width is narrower than the full bar")
    check(SC.overlayHit >= 12, "tokens: the grab area is at least 12 wide")
    check(SC.overlayHit <= SC.gutter, "tokens: ...and never wider than the gutter it lives in")
    check(SC.overlayAlpha > 0 and SC.overlayAlpha < 1, "tokens: it rests dim, not invisible")
end

-- ============================================================
-- 2. IT RESTS NARROW, DIM, AND ALREADY EASY TO GRAB
-- ============================================================
do
    local sf, sb = scrollStub()
    UI.StyleScrollBar(sf, { overlay = true })

    eq(sb:GetWidth(), SC.overlayIdle, "rest: it starts at the hairline width")
    eq(sb:GetAlpha(), SC.overlayAlpha, "rest: ...and dim")
    eq(sb.dfOverlayWide, false, "rest: which is the narrow state, explicitly")
    check(not sb.dfOverlayTicker._shown, "rest: the idle clock is not running")

    -- The hit rect makes the difference up, on the bar AND on the thumb.
    local grow = (SC.overlayHit - SC.overlayIdle) / 2
    eq(sb._hitRect[1], -grow, "rest: the bar's grab area is grown on the left")
    eq(sb._hitRect[2], -grow, "rest: ...and the right")
    eq(sb.Thumb._hitRect[1], -grow, "rest: and so is the thumb's, which is what you grab")

    -- The rest of the styling is the plain bar's, unchanged.
    check(not sb.Background._shown, "rest: the track background is still stripped")
    check(sb.Thumb.customBg ~= nil, "rest: and the pill thumb is still painted")
end

-- ============================================================
-- 3. EVERY WAY OF USING IT WAKES IT
-- ============================================================
local function wakeCase(name, drive)
    local sf, sb = scrollStub()
    UI.StyleScrollBar(sf, { overlay = true })
    drive(sf, sb)
    eq(sb:GetWidth(), SC.bar, "wake: " .. name .. " widens it")
    eq(sb:GetAlpha(), 1, "wake: " .. name .. " brings it to full alpha")
    check(sb.dfOverlayTicker._shown, "wake: " .. name .. " starts the idle clock")
    local grow = (SC.overlayHit - SC.bar) / 2
    eq(sb._hitRect[1], -grow, "wake: " .. name .. " -- the grab area stays the same total size")
    return sf, sb
end

wakeCase("hovering the bar", function(_, sb) fire(sb, "OnEnter") end)
wakeCase("hovering the thumb", function(_, sb) fire(sb.Thumb, "OnEnter") end)
wakeCase("pressing the thumb", function(_, sb) fire(sb.Thumb, "OnMouseDown") end)
wakeCase("the wheel", function(sf) fire(sf, "OnMouseWheel", -1) end)
wakeCase("the pane scrolling", function(sf) fire(sf, "OnVerticalScroll", 40) end)

-- The grab area really is the same at both sizes -- the whole justification for
-- a 4px bar being usable.
do
    local sf, sb = scrollStub()
    UI.StyleScrollBar(sf, { overlay = true })
    local narrow = SC.overlayIdle + (-sb._hitRect[1]) + (-sb._hitRect[2])
    fire(sb, "OnEnter")
    local wide = SC.bar + (-sb._hitRect[1]) + (-sb._hitRect[2])
    eq(narrow, SC.overlayHit, "grab: narrow, it is worth the full hit width to the mouse")
    eq(wide, SC.overlayHit, "grab: and wide, it is worth exactly the same")
end

-- ============================================================
-- 4. THE IDLE CLOCK
-- ============================================================
do
    local sf, sb = scrollStub()
    UI.StyleScrollBar(sf, { overlay = true })
    fire(sf, "OnVerticalScroll", 40)

    tick(sb, SC.overlayHold - 0.1)
    eq(sb:GetWidth(), SC.bar, "idle: it is still wide just before the hold elapses")
    tick(sb, 0.1)
    eq(sb:GetWidth(), SC.overlayIdle, "idle: and shrinks the moment it does")
    eq(sb:GetAlpha(), SC.overlayAlpha, "idle: back to dim with it")
    check(not sb.dfOverlayTicker._shown, "idle: and the clock stops itself rather than running for the session")

    -- More scrolling starts the whole thing again.
    fire(sf, "OnVerticalScroll", 40)
    eq(sb:GetWidth(), SC.bar, "idle: the next scroll wakes it again")
    tick(sb, SC.overlayHold / 2)
    fire(sf, "OnVerticalScroll", 40)          -- resets the clock
    tick(sb, SC.overlayHold * 0.6)
    eq(sb:GetWidth(), SC.bar, "idle: a scroll part-way through the hold restarts it")
end

-- ...and it does not run at all while the pointer is on it.
do
    local sf, sb = scrollStub()
    UI.StyleScrollBar(sf, { overlay = true })
    fire(sb, "OnEnter")
    tick(sb, SC.overlayHold * 5)
    eq(sb:GetWidth(), SC.bar, "hover: it stays wide for as long as the pointer is on it")
    fire(sb, "OnLeave")
    tick(sb, SC.overlayHold)
    eq(sb:GetWidth(), SC.overlayIdle, "hover: and only then starts shrinking")
end

-- A HELD thumb keeps it wide even with the pointer dragged off the bar, which is
-- what a real drag looks like -- the cursor leaves the 10px column constantly.
do
    local sf, sb = scrollStub()
    UI.StyleScrollBar(sf, { overlay = true })
    fire(sb.Thumb, "OnMouseDown")
    fire(sb.Thumb, "OnLeave")
    fire(sb, "OnLeave")
    tick(sb, SC.overlayHold * 3)
    eq(sb:GetWidth(), SC.bar, "held: a drag that wanders off the bar does not shrink under the cursor")
    fire(sb.Thumb, "OnMouseUp")
    tick(sb, SC.overlayHold)
    eq(sb:GetWidth(), SC.overlayIdle, "held: releasing it starts the clock")
end

-- ============================================================
-- 5. IDEMPOTENT, AND OPT-IN
-- ============================================================
do
    local sf, sb = scrollStub()
    UI.StyleScrollBar(sf, { overlay = true })
    local ticker = sb.dfOverlayTicker
    UI.StyleScrollBar(sf, { overlay = true })
    eq(sb.dfOverlayTicker, ticker, "twice: re-styling the same bar reuses its state, it does not build a second")

    -- If the hooks had been installed twice the hold would still be one hold --
    -- the observable damage is a doubled clock, so tick it and check.
    fire(sf, "OnVerticalScroll", 40)
    tick(sb, SC.overlayHold - 0.05)
    eq(sb:GetWidth(), SC.bar, "twice: and the idle clock still runs at one speed")
end

do
    -- No opt: exactly the bar this kit has always drawn.
    local sf, sb = scrollStub()
    UI.StyleScrollBar(sf)
    eq(sb:GetWidth(), SC.bar, "plain: a bar with no opt is the full width, as before")
    eq(sb:GetAlpha(), nil, "plain: nothing touched its alpha")
    eq(sb.dfOverlay, nil, "plain: and no state machine was installed")
    eq(sb._hitRect, nil, "plain: nor a grown hit rect")
    fire(sb, "OnEnter")
    eq(sb:GetWidth(), SC.bar, "plain: hovering it does nothing")
end
