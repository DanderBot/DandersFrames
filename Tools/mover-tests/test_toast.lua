local NS = ...

-- ============================================================
-- THE TOAST PRIMITIVE (DandersUI/Toast.lua) and the glyph button's
-- grey-when-disabled state (DandersUI/Widgets.lua).
--
-- What is under test on the toast is IDENTITY and TIMING, not looks:
--
--   * one frame per HOST, built lazily -- a second call reuses it and replaces
--     the text, and a second host gets its own;
--   * every call reparents and re-anchors, so a consumer with two windows
--     toasts on the one it is talking about;
--   * a replacement RESTARTS the clock: the previous hold timer is stale and
--     must not take the new toast down early;
--   * a toast whose window closed under it is hidden outright rather than
--     faded, because a fade on a frame nobody draws never finishes;
--   * the chrome takes the arm the host's surface style asks for, and each arm
--     takes the other down.
--
-- ⚠ FRESH NAMESPACES, NOT THE SHARED ONE. run.py loads every test_*.lua into
-- one runtime against one `NS.__DandersUI`, and this file installs real library
-- files -- which would replace factories the popout and panel suites built their
-- fixtures from. `load_ui_file_into` takes a namespace of the caller's choosing,
-- so everything below is private to this file.
--
-- ☠ Every global this file replaces (CreateFrame, C_Timer) is restored at the
-- end, or the next file inherits it.
-- ============================================================

local prevCreateFrame, prevTimer = CreateFrame, C_Timer

-- ---- a frame stub that models PARENTAGE ----------------------------
-- The shim's FakeUIFrame answers every unset key with a no-op, so SetParent
-- would be swallowed and "did the toast move to the other window" could not be
-- asked. Counted too: the singleton claim is a claim about how many frames were
-- ever built.
local built = 0
local function newFrame()
    local f = FakeUIFrame(0, 0, 0, 0)
    built = built + 1
    f.SetParent = function(self, p) self._parent = p end
    f.GetParent = function(self) return rawget(self, "_parent") end
    return f
end
CreateFrame = function() return newFrame() end

-- ---- a timer queue the test drives --------------------------------
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { delay = delay, fn = fn } end }
local function fireTimer(i)
    local t = timers[i]
    if t then t.fn() end
end

-- ============================================================
-- THE LIBRARY TABLE THIS FILE OWNS
-- ============================================================
local ns = {}
local UI = {
    _state = {},
    _priv  = {},
    Colors = {
        panel   = { r = 0.12, g = 0.13, b = 0.14, a = 1 },
        border  = { r = 0.25, g = 0.25, b = 0.25, a = 1 },
        text    = { r = 0.9,  g = 0.9,  b = 0.9 },
        textDim = { r = 0.5,  g = 0.5,  b = 0.5 },
    },
}
ns.__DandersUI = UI

-- The REAL surface resolver and the REAL style token, lifted from the shared
-- namespace run.py already filled from Theme.lua -- `nil means ask the host` is
-- exactly the rule a re-implementation here would drift from.
UI.SurfaceStyle = NS.__DandersUI.SurfaceStyle
UI.ResolveSurfaceStyle = NS.__DandersUI.ResolveSurfaceStyle
UI.SetSurfaceStyle = NS.__DandersUI.SetSurfaceStyle

-- ...and the REAL Fx, wrapped so the calls are countable. Headless it takes its
-- own no-animation path (FakeUIFrame answers nil to CreateAnimationGroup), which
-- is exactly the path that makes the show/hide observable in one step.
local fxLog = { fadeIn = 0, fadeOut = 0 }
local realFx = NS.__DandersUI.Fx
UI.Fx = {
    FadeIn = function(target, dur)
        fxLog.fadeIn = fxLog.fadeIn + 1
        fxLog.inDur = dur
        return realFx.FadeIn(target, dur)
    end,
    FadeOut = function(target, dur, onDone)
        fxLog.fadeOut = fxLog.fadeOut + 1
        fxLog.outDur = dur
        return realFx.FadeOut(target, dur, onDone)
    end,
    Cancel = realFx.Cancel,
}

-- Font plumbing and the two chrome arms, recorded.
local paintLog = { font = 0, rounded = 0, square = 0, unrounded = 0 }
function UI:SetSettingsFont(fs, size)
    paintLog.font = paintLog.font + 1
    paintLog.fontSize = size
    paintLog.fontString = fs
end
function UI:ApplyRoundedChrome(frame, opts)
    paintLog.rounded = paintLog.rounded + 1
    paintLog.roundedOpts = opts
    paintLog.roundedFrame = frame
    return frame
end
function UI:RemoveRoundedChrome(frame)
    paintLog.unrounded = paintLog.unrounded + 1
    return frame
end
function UI:CreateElementBackdrop(frame, opts)
    paintLog.square = paintLog.square + 1
    paintLog.squareOpts = opts
    return frame
end

load_ui_file_into("Toast.lua", ns)
check(type(UI.ShowToast) == "function", "toast: ShowToast is published on the library")

local function newHost() return setmetatable({}, { __index = UI }) end

-- ============================================================
-- 1. GUARDS -- NOTHING TO SAY, NOTHING BUILT
-- ============================================================
do
    local host = newHost()
    local before = built
    check(host:ShowToast(nil) == nil, "guard: no opts at all")
    check(host:ShowToast({ text = "hi" }) == nil, "guard: no parent")
    check(host:ShowToast({ parent = newFrame() }) == nil, "guard: no text")
    check(host:ShowToast({ parent = newFrame(), text = "" }) == nil, "guard: empty text")
    eq(built - before, 2, "guard: only the two throwaway parents were built -- no toast frame")
    check(rawget(host, "_dfToast") == nil, "guard: ...and the host is still toast-less")
end

-- ============================================================
-- 2. THE FIRST TOAST: BUILT, DRESSED, ANCHORED, SHOWN
-- ============================================================
local host, parent, toast
do
    host = newHost()
    parent = newFrame()
    parent:SetFrameLevel(7)
    local before = built
    toast = host:ShowToast({ parent = parent, text = "Undid: Frame Width" })

    check(toast ~= nil, "first: a frame comes back")
    eq(built - before, 1, "first: exactly one frame was built for it")
    check(rawget(host, "_dfToast") == toast, "first: ...and it is stored on the HOST, under a private key")
    check(toast:IsShown(), "first: it is shown")
    eq(toast:GetParent(), parent, "first: parented to the surface it was asked for")
    eq(toast.Text:GetText(), "Undid: Frame Width", "first: carrying the text it was given")
    eq(toast:GetFrameLevel(), 27, "first: lifted 20 levels over the parent's own content")
    check(toast._flags.mouse == false, "first: non-interactive -- it cannot eat a click")

    eq(toast:GetNumPoints(), 1, "anchor: one point, not a stack of them")
    local p = { toast:GetPoint(1) }
    eq(p[1], "BOTTOM", "anchor: by its BOTTOM edge...")
    check(p[2] == parent, "anchor: ...to the parent...")
    eq(p[3], "BOTTOM", "anchor: ...measured from the parent's bottom...")
    eq(p[4], 0, "anchor: ...centred...")
    eq(p[5], 14, "anchor: ...and lifted clear of the edge, INSIDE the surface")

    -- The stub's string width is 7px a character.
    eq(toast:GetWidth(), 18 * 7 + 24, "size: auto-width -- the text plus 12px either side")
    eq(toast:GetHeight(), 24, "size: a fixed height")

    eq(paintLog.font, 1, "dress: the text went through the host's font plumbing")
    check(paintLog.fontString == toast.Text, "dress: ...on the toast's own fontstring")
    eq(fxLog.fadeIn, 1, "show: it faded in")
    eq(fxLog.inDur, 0.1, "show: at the entrance duration")
    eq(#timers, 1, "clock: one hold timer was queued")
    eq(timers[1].delay, 2, "clock: the default hold is 2 seconds")
end

-- ============================================================
-- 3. THE HOLD CLOCK, AND WHAT A REPLACEMENT DOES TO IT
-- ============================================================
do
    -- A second toast on the same host reuses the frame and replaces the text.
    local before, fadesIn = built, fxLog.fadeIn
    local again = host:ShowToast({ parent = parent, text = "Redid: Alpha" })
    check(again == toast, "again: the SAME frame comes back -- one toast per host")
    eq(built - before, 0, "again: nothing new was built")
    eq(toast.Text:GetText(), "Redid: Alpha", "again: the text was replaced")
    eq(toast:GetNumPoints(), 1, "again: re-anchored, not anchored twice")
    eq(fxLog.fadeIn - fadesIn, 1, "again: and the entrance ran again -- FadeIn stops any exit mid-flight")
    eq(#timers, 2, "again: a fresh hold timer was queued")

    -- ...and the FIRST timer is now stale. Firing it must not take the
    -- replacement down early: that is the whole of "the clock restarts".
    local fadesOut = fxLog.fadeOut
    fireTimer(1)
    check(toast:IsShown(), "stale: the superseded timer left the live toast alone")
    eq(fxLog.fadeOut - fadesOut, 0, "stale: ...and did not start a fade")

    fireTimer(2)
    eq(fxLog.fadeOut - fadesOut, 1, "hold: the LIVE timer faded it out")
    eq(fxLog.outDur, 0.2, "hold: at the exit duration")
    check(not toast:IsShown(), "hold: ...and the fade's onDone hid it")
end

-- A short line still gets a floor width, so a one-word toast is not a pill --
-- and a SECOND HOST gets its own frame rather than borrowing the first host's.
do
    local h2 = newHost()
    local t2 = h2:ShowToast({ parent = newFrame(), text = "Ok" })
    eq(t2:GetWidth(), 80, "size: ...but never narrower than the 80px floor")
    check(t2 ~= toast, "hosts: a SECOND HOST gets its own frame, not the first host's")
end

-- An explicit duration is honoured; a nonsense one falls back to the default.
do
    timers = {}
    host:ShowToast({ parent = parent, text = "Undid: Width", duration = 5 })
    eq(timers[1].delay, 5, "duration: an explicit hold is used verbatim")
    host:ShowToast({ parent = parent, text = "Undid: Width", duration = "soon" })
    eq(timers[2].delay, 2, "duration: a non-number falls back to the default")
    host:ShowToast({ parent = parent, text = "Undid: Width", duration = 0 })
    eq(timers[3].delay, 0, "duration: zero is a legal hold, not a missing one")
end

-- ============================================================
-- 4. REPARENTING -- THE TOAST FOLLOWS THE WINDOW IT IS ABOUT
-- ============================================================
do
    local other = newFrame()
    other:SetFrameLevel(40)
    timers = {}
    local t = host:ShowToast({ parent = other, text = "Undid: Border" })
    check(t == toast, "move: still the same frame")
    eq(t:GetParent(), other, "move: reparented to the other surface")
    eq(t:GetNumPoints(), 1, "move: with its old anchor cleared first")
    local p = { t:GetPoint(1) }
    check(p[2] == other, "move: ...and the new one is against the new parent")
    eq(t:GetFrameLevel(), 60, "move: the lift is re-derived from the NEW parent's level")
end

-- ============================================================
-- 5. A WINDOW CLOSED UNDER IT IS HIDDEN OUTRIGHT, NOT FADED
-- A fade on a frame nobody draws never finishes, so the callback that hides it
-- would never run and the toast would come back with the window.
-- ============================================================
do
    timers = {}
    local t = host:ShowToast({ parent = parent, text = "Undid: Scale" })
    local fadesOut = fxLog.fadeOut
    t.IsVisible = function() return false end          -- the window went away
    fireTimer(1)
    eq(fxLog.fadeOut - fadesOut, 0, "closed: no fade was started on an undrawn frame")
    check(not t:IsShown(), "closed: it was hidden outright instead")
    t.IsVisible = function(self) return self._shown end
end

-- ============================================================
-- 6. CHROME -- ONE ARM OR THE OTHER, AND EACH TAKES THE OTHER DOWN
-- ============================================================
do
    -- Square: the host never opted in to a surface style.
    timers = {}
    local sq = newHost()
    local before = { r = paintLog.rounded, s = paintLog.square, u = paintLog.unrounded }
    sq:ShowToast({ parent = newFrame(), text = "Square" })
    eq(paintLog.rounded - before.r, 0, "square: no rounded surface was applied")
    eq(paintLog.square - before.s, 1, "square: the element backdrop was")
    eq(paintLog.unrounded - before.u, 1, "square: ...after taking any rounded surface down")
    eq(paintLog.squareOpts.bgColor[1], UI.Colors.panel.r, "square: filled with the PANEL token")
    eq(paintLog.squareOpts.borderColor[1], UI.Colors.border.r, "square: edged with the BORDER token")

    -- Rounded: the host opted in, the way DF's GUI host does.
    local rd = newHost()
    rd:SetSurfaceStyle(UI.SurfaceStyle)
    before = { r = paintLog.rounded, s = paintLog.square }
    rd:ShowToast({ parent = newFrame(), text = "Rounded" })
    eq(paintLog.square - before.s, 0, "rounded: no square backdrop was issued")
    eq(paintLog.rounded - before.r, 1, "rounded: the rounded surface was")
    eq(paintLog.roundedOpts.radius, 8, "rounded: at the style token's radius")
    eq(paintLog.roundedOpts.borderWidth, UI.SurfaceStyle.borderWidth, "rounded: and its border weight")
    eq(paintLog.roundedOpts.fill[1], UI.Colors.panel.r, "rounded: filled with the PANEL token")
    eq(paintLog.roundedOpts.border[1], UI.Colors.border.r, "rounded: ringed with the BORDER token")
end

-- ============================================================
-- 7. THE GLYPH BUTTON'S GREY-WHEN-DISABLED STATE
-- Its own namespace: Widgets.lua is a big file with its own file-scope needs,
-- and installing it over the toast namespace would be two libraries in one table.
-- ============================================================
do
    local wns = {}
    local W = {
        _state = {}, _priv = {}, MEDIA = "",
        Colors = {
            panel   = { r = 0.12, g = 0.12, b = 0.12, a = 1 },
            element = { r = 0.18, g = 0.18, b = 0.18, a = 1 },
            border  = { r = 0.25, g = 0.25, b = 0.25, a = 1 },
            hover   = { r = 0.22, g = 0.22, b = 0.22, a = 1 },
            accent  = { r = 0.45, g = 0.45, b = 0.95, a = 1 },
            text    = { r = 0.9,  g = 0.9,  b = 0.9 },
            textDim = { r = 0.5,  g = 0.5,  b = 0.5 },
            notice  = { r = 0.91, g = 0.66, b = 0.25, a = 1 },
        },
        RowHeight = { slider = 50, checkbox = 35 },
        RowGap = 14,
    }
    wns.__DandersUI = W
    function W.SnapLen(_, n) return n end
    function W.SnapHeightEven(_, n) return n end
    function W.StyleScrollBar() end
    function W._priv.CreateElementBackdrop(frame) return frame end
    function W._priv.CreatePanelBackdrop(frame) return frame end
    function W:Hook() return nil end
    function W:Call() return nil end
    load_ui_file_into("Widgets.lua", wns)

    local btn = W:CreateGlyphButton(newFrame(), {
        texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\undo",
        width = 22, height = 22, iconSize = 16,
        color = W.Colors.textDim,
    })
    check(type(btn.SetGlyphEnabled) == "function", "glyph: SetGlyphEnabled is on the button")
    local dim = W.Colors.textDim

    -- Disabled UNDER THE CURSOR: the hover brighten must be undone, because the
    -- OnLeave that would normally restore it is now the leave of a dead button.
    btn:GetScript("OnEnter")(btn)
    eq(btn.Icon._vertex.r, 1, "glyph: hovering brightens it while enabled")
    btn:SetGlyphEnabled(false)
    eq(btn:GetAlpha(), 0.4, "off: dimmed to the kit's disabled alpha")
    eq(btn:IsEnabled(), false, "off: clicks are off")
    eq(btn._glyphHover, false, "off: the hover brighten is suppressed")
    eq(btn.Icon._vertex.r, dim.r, "off: ...and the tint it was wearing was put back")

    -- ...and the hover really is inert now.
    btn:GetScript("OnEnter")(btn)
    eq(btn.Icon._vertex.r, dim.r, "off: a hover over a disabled glyph does not light it up")

    btn:SetGlyphEnabled(true)
    eq(btn:GetAlpha(), 1, "on: full alpha again")
    eq(btn:IsEnabled(), true, "on: clicks are back")
    eq(btn._glyphHover, true, "on: and so is the hover brighten")
    btn:GetScript("OnEnter")(btn)
    eq(btn.Icon._vertex.r, 1, "on: which proves the round trip left no state behind")

    -- A re-enabled glyph whose REST colour was changed keeps the new rest colour
    -- rather than snapping back to the one it was built with.
    btn:GetScript("OnLeave")(btn)
    btn:SetGlyph(nil, { r = 0.2, g = 0.7, b = 0.3 })
    btn:SetGlyphEnabled(false)
    eq(btn.Icon._vertex.g, 0.7, "rest: disabling restores the CURRENT rest colour, not the original")
end

-- ---- restore the globals -------------------------------------------
CreateFrame, C_Timer = prevCreateFrame, prevTimer
