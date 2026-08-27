local NS = ...

-- ============================================================
-- THE CORNER TRIAL'S DEMO WIRING -- DandersFrames_Options/GUI/PopoutDemo.lua
-- ------------------------------------------------------------
-- test_round.lua covers the rounded SURFACE. This covers the two things the demo
-- does AROUND it, both of which are answers to "there is a second corner beside
-- the rounded one" and both of which have to undo themselves exactly when the
-- Corners button comes back round to Square:
--
--   1. the popout shell's SOURCE OUTLINE -- a square accent box the pack lays
--      over the active row -- is suppressed while a radius is selected, and comes
--      back on Square
--   2. the title bars' CROSS is nudged inboard of the arc, and returns to its
--      original offset on Square
--
-- Both are per-INSTANCE shadows on a pooled popout, which is the shape that goes
-- wrong quietly: a shadow installed one click too late, or a restore that writes
-- a literal instead of the value it replaced, both look fine until the third or
-- fourth press of the button. Neither is visible from in-game without watching
-- for it, and the trial is being judged on exactly this.
--
-- ☠ ONE RUNTIME, SHARED LIBRARY TABLE. run.py loads every test_*.lua into the
-- same LuaRuntime in alphabetical order, so test_popout / test_popout_row have
-- installed Popout.lua and PopoutRow.lua onto NS.__DandersUI and test_round.lua
-- has installed Round.lua by the time this runs. Everything below ADDS what
-- nobody installed, and restores the globals it stubs at the end.
--
-- ⚠ THIS FILE MUST SORT AFTER test_round.lua (it does: "test_round_demo" >
-- "test_round"). Running it alone (`run.py round_demo`) loads what it needs
-- itself, which is why every load below is guarded rather than assumed.
-- ============================================================

local UI = NS.__DandersUI

-- ---- the kit surface the demo reads at file scope -------------------
UI.MEDIA = UI.MEDIA or ""
UI.Colors = UI.Colors or {}
local C = UI.Colors
C.text       = C.text       or { r = 0.9, g = 0.9, b = 0.9 }
C.textDim    = C.textDim    or { r = 0.5, g = 0.5, b = 0.5 }
C.element    = C.element    or { r = 0.18, g = 0.18, b = 0.18, a = 1 }
C.border     = C.border     or { r = 0.25, g = 0.25, b = 0.25, a = 1 }
C.hover      = C.hover      or { r = 0.22, g = 0.22, b = 0.22, a = 1 }
C.background = C.background or { r = 0.08, g = 0.08, b = 0.08, a = 0.95 }
-- The three the demo reads that the popout suites never needed: the panel fill
-- both title strips are drawn in, and the two accent poles its Accent button
-- swaps the rows between.
C.panel  = C.panel  or { r = 0.12, g = 0.12, b = 0.12, a = 1 }
C.accent = C.accent or { r = 0.45, g = 0.45, b = 0.95, a = 1 }
C.raid   = C.raid   or { r = 0.95, g = 0.55, b = 0.25, a = 1 }

UI.RowGap = UI.RowGap or 14
UI.RowHeight = UI.RowHeight or {}
UI.RowHeight.checkbox = UI.RowHeight.checkbox or 35
UI.RowHeight.editbox  = UI.RowHeight.editbox  or 40
UI.PopoutContentWidth = UI.PopoutContentWidth or 260
UI.PopoutTitle = UI.PopoutTitle or { topPad = 6, row = 28, fill = 0.9, sepAlpha = 0.8 }
UI.PopoutTitleHeight = UI.PopoutTitleHeight or (UI.PopoutTitle.topPad + UI.PopoutTitle.row)
UI.PopoutPad = UI.PopoutPad or 10
UI.Space = UI.Space or { section = 16 }
UI.StyleScrollBar = UI.StyleScrollBar or function(sf) sf._styledScrollBar = true end
UI.PopoutRow = UI.PopoutRow or {
    plate = 44, gap = 6, padX = 10, labelGap = 10, colGap = 6,
    check = 16, checkTick = 9, gear = 14, chevron = 10,
    badgeW = 22, badgeH = 16,
    labelSize = 12, summarySize = 11, badgeSize = 10,
    restFill = 0.55, hoverFill = 0.75, restBorder = 0.5,
    activeFill = 0.14, activeHover = 0.20, activeBorder = 1,
    badgeFill = 0.55, badgeBorder = 0.45,
}
UI.PopoutRow.slot = UI.PopoutRow.plate + UI.PopoutRow.gap

if not UI.GetAccent then
    local A = C.accent
    function UI:GetAccent() return A end
end
if not UI.CreatePanelBackdrop then
    function UI:CreatePanelBackdrop(frame, opts) frame._panelOpts = opts return frame end
end
if not UI.ApplyPixelBorder then
    function UI:ApplyPixelBorder(frame, color, weight)
        frame._pxColor, frame._pxWeight = color, weight
        return frame
    end
end
-- The demo calls this on every surface it takes rounded, and Theme.lua is not
-- loadable headless. Recorded rather than a bare no-op, so "did the rounded path
-- actually take the square border down" stays answerable.
if not UI.HidePixelBorder then
    function UI:HidePixelBorder(frame) frame._pxHidden = true return frame end
end
if not UI.CreateElementBackdrop then
    function UI:CreateElementBackdrop(frame, opts)
        frame._elementOpts = opts or {}
        frame.SetBackdropColor = function(self, r, g, b, a) self._fill = { r, g, b, a } end
        frame.SetBackdropBorderColor = function(self, r, g, b, a) self._edge = { r, g, b, a } end
        return frame
    end
end
if not UI.StyleCheckButton then
    function UI:StyleCheckButton(cb, opts)
        opts = opts or {}
        cb:SetSize(opts.size or 18, opts.size or 18)
        cb.Check = cb.Check or FakeUIFrame()
        cb.ApplyThemeColor = function(c) cb._tint = c end
        return cb
    end
end
-- Same rule as test_popout_row's frame stub: a missing DATA field must read nil,
-- not the catch-all no-op function, or `row.popout == nil` can never be true.
local function dataAwareMeta(k)
    if k == "popout" then return nil end
    if type(k) == "string" and k:byte(1) == 95 then return nil end   -- "_"
    return function() end
end

-- ☠ REPLACED, NOT GUARDED, and restored at the end of this file.
--
-- test_popout_row installs a close-button stub on this same shared table, and its
-- buttons carry the bare FakeUIFrame metatable -- which answers EVERY unset key
-- with a no-op function. That is fine for methods and fatal here: the demo
-- remembers a button's original anchor in `btn._demoSquareX` and tests it against
-- nil, so on a bare stub the field is always "already set" (to a function) and
-- the first shift does arithmetic on it. A real Button answers nil, which is why
-- the demo can write it the short way.
--
-- So this file uses buttons whose unset underscore fields read nil, and hands the
-- original stub back afterwards so nothing downstream sees the swap.
local prevCloseButton, prevGlyphButton = UI.CreateCloseButton, UI.CreateGlyphButton
do
    local function stubButton(opts)
        local b = FakeUIFrame(16, 16)
        setmetatable(b, { __index = function(_, k) return dataAwareMeta(k) end })
        b._opts = opts
        b:Show()
        return b
    end
    function UI:CreateCloseButton(_, opts) return stubButton(opts) end
    function UI:CreateGlyphButton(_, opts) return stubButton(opts) end
end

-- ---- WoW globals ----------------------------------------------------
local prevCreateFrame, prevTimer = CreateFrame, C_Timer
local prevPlaySound, prevSoundKit = PlaySound, SOUNDKIT
local prevDF = DandersFrames
PlaySound = function() end
SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = 1 }
C_Timer = { After = function(_, fn) fn() end }

-- The scroll frame the demo builds is captured on the way past: the rows are
-- gated against it (opts.clipTo), so the test has to give it a rect they overlap
-- or every popout would report itself clipped and no outline would ever show --
-- which would make the whole file pass against nothing.
local lastScroll
CreateFrame = function(kind, _, parent)
    local f = FakeUIFrame()
    setmetatable(f, { __index = function(_, k) return dataAwareMeta(k) end })
    f._kind = kind
    f._children = {}
    f._parent = parent
    f.GetParent = function(self) return self._parent end
    f.SetParent = function(self, p) self._parent = p end
    f.GetNumChildren = function(self) return #self._children end
    f.GetChildren = function(self) return unpack(self._children) end
    if kind == "CheckButton" then
        f.SetChecked = function(self, v) self._checked = v and true or false end
        f.GetChecked = function(self) return self._checked end
    end
    if kind == "ScrollFrame" then lastScroll = f end
    local rawCreateTexture = f.CreateTexture
    f.CreateTexture = function(self, ...)
        local t = rawCreateTexture(self, ...)
        t.SetColorTexture = function(s, r, g, b, a) s._fill = { r = r, g = g, b = b, a = a } end
        return t
    end
    if type(parent) == "table" then
        local kids = rawget(parent, "_children")
        if not kids then kids = {}; parent._children = kids end
        kids[#kids + 1] = f
    end
    return f
end

-- ---- the host the demo takes its factories off ----------------------
local L = setmetatable({}, { __index = function(_, k) return k end })
local host = setmetatable({ hooks = { L = L, debug = function() return function() end end } },
                          { __index = UI })

if not UI.CreatePopout then load_ui_file("Popout.lua") end
if not UI.CreatePopoutRow then load_ui_file("PopoutRow.lua") end
if not UI.CreateRoundedSurface then load_ui_file("Round.lua") end

-- ---- the *Native factories ------------------------------------------
-- ☠ THE DEMO USES THE *Native NAMES THROUGHOUT (its own header says why: DF
-- shadows the plain names with positional shims). So these are what has to
-- exist, and they are stubbed on the HOST rather than the library -- that is
-- where the real ones live for DF, and putting them on the library would leak
-- them into every other suite sharing this table.
--
-- ⚠ preferredHeight IS SET, and it is not decoration. The demo's stack() reads
-- `w.preferredHeight or (w:GetHeight() + RowGap)` -- and the frame stub answers
-- an unset key with a no-op FUNCTION, which is truthy, so a widget without one
-- would put a function into that addition and blow up. Real kit widgets all
-- carry it; these have to as well.
local function paneWidget(parent, h)
    local w = CreateFrame("Frame", nil, parent)
    w:SetSize(UI.PopoutContentWidth, h)
    w.preferredHeight = h
    w.fixedRowHeight = true
    w.SetEnabled = function(self, v) self._enabled = v and true or false end
    return w
end

function host:CreateSliderNative(parent, opts) local w = paneWidget(parent, 40); w._opts = opts; return w end
function host:CreateDropdownNative(parent, opts) local w = paneWidget(parent, 40); w._opts = opts; return w end
function host:CreateCheckboxNative(parent, opts) local w = paneWidget(parent, 28); w._opts = opts; return w end
function host:CreateEditBoxNative(parent, opts)
    -- NOT a paneWidget: the demo wraps this in its own container frame and that
    -- wrapper is the counted control, so an edit box that made itself a second
    -- child of the pane would push every count off by one.
    local w = FakeUIFrame(80, 22)
    w._opts = opts
    w.SetEnabled = function(self, v) self._enabled = v and true or false end
    return w
end
-- A FontString stands in for a label -- deliberately NOT a frame, because the
-- row's control count is frames only and a counted label would be a phantom
-- control in every pane.
function host:CreateLabelNative(_, opts)
    local fs = FakeUIFrame()
    if opts and opts.text then fs:SetText(opts.text) end
    return fs
end
-- The title bar's ghost buttons. `_opts` is the whole point: pressing the
-- Corners button in a test is calling the onClick this recorded.
function host:CreateButtonNative(_, opts)
    local b = FakeUIFrame(opts and opts.width or 60, opts and opts.height or 18)
    b._opts = opts
    if opts and opts.text then b:SetText(opts.text) end
    b:Show()
    return b
end

-- ---- rows, captured on construction ---------------------------------
-- The demo keeps its rows in a file-local table it does not publish, and it
-- should not grow a test hook to publish them. So they are taken on the way
-- through the factory instead; the wrapper is removed again at the end.
local demoRows = {}
local baseCreateRow = UI.CreatePopoutRow
function UI:CreatePopoutRow(parent, opts)
    local row = baseCreateRow(self, parent, opts)
    demoRows[#demoRows + 1] = row
    if opts and opts.label then demoRows[opts.label] = row end
    return row
end

-- ---- the host DF publishes ------------------------------------------
-- ☠ The companion's files take their host off the GLOBAL (`local DF =
-- DandersFrames`), not off the varargs -- see run.py's note on
-- load_options_file_into. So the global is what has to be right.
DandersFrames = { GUI = host }
-- ...and the library off LibStub, by the name the demo asks for. Written
-- straight into LibStub's own tables rather than through NewLibrary, which would
-- hand back a fresh table instead of the one every other suite has been building
-- the kit onto.
LibStub.libs["DandersUI-1.0"] = UI
LibStub.minors["DandersUI-1.0"] = 1

load_options_file_into("GUI/PopoutDemo.lua", NS)

-- ---- geometry -------------------------------------------------------
-- The stub resolves no anchors, so every rect a test needs is stated by hand
-- (the note at the head of shim.lua). Three of them matter here: the window the
-- popout docks OUTSIDE of, the scroll frame the row is clipped against, and the
-- rows themselves.
local CX, CY = 960, 540      -- the shim's UIParent centre
local win = DandersFrames:TogglePopoutDemo()
win:SetFakeCenter(CX, CY)
win:Show()

local scroll = lastScroll
scroll:SetSize(440, 380)
scroll:SetFakeCenter(CX, CY - 40)

for i, row in ipairs(demoRows) do
    row:SetSize(440, UI.PopoutRow.slot)
    -- Stacked downwards inside the scroll frame, so all four are unclipped and
    -- each is a distinct rect -- a retarget between two rows at the same place
    -- would not exercise the glide the outline commits through.
    row:SetFakeCenter(CX, CY + 100 - (i - 1) * UI.PopoutRow.slot)
    row:Show()
end

-- ---- driving the Corners button -------------------------------------
-- Through the button's own onClick, not by poking the demo's cornerIndex: the
-- index is a file-local and the click is what a person does. One press per step
-- of Square -> R4 -> R6 -> R8 -> Square.
local cornerBtn = win.cornerBtn
local function pressCorners(n)
    for _ = 1, (n or 1) do cornerBtn._opts.onClick(cornerBtn) end
end
local function cornerLabel() return cornerBtn:GetText() end

local border = demoRows["Border"]
local shadow = demoRows["Border Shadow"]

print("-- Round demo: the workbench builds")
do
    check(win ~= nil, "the demo window is built")
    eq(#demoRows, 4, "four rows")
    check(cornerBtn ~= nil and cornerBtn._opts ~= nil, "the Corners button is wired")
    eq(cornerLabel(), "Corners: Square", "and it starts on Square -- the shipping look")
end

-- ============================================================
-- 1. THE SOURCE OUTLINE
--
-- The shell draws a square accent box over whatever the panel is tethered to. In
-- rounded mode the row already wears a ROUND accent ring of its own, so the two
-- together are the "second corner around a selected object" this fixes.
-- ============================================================

-- ☠ THE COLD OPEN GOES FIRST, and the order is the assertion.
--
-- A popout is POOLED and hooked ONCE, on the first open that reaches it. So the
-- only moment in a session at which the shell can present a panel before the
-- demo's shadow exists is the VERY FIRST open -- and if that happens while a
-- radius is selected, the pack has already run _Present -> _UpdateSourceOutline
-- unhooked and put a square box on the row.
--
-- That is why the demo re-runs the outline immediately after installing the
-- hook, and it is why this block cannot be moved further down the file: open one
-- popout in Square first and every later "from cold" is a lie -- the instance is
-- already hooked, the shadow catches the present, and a test written after it
-- passes with the re-run deleted.
print("-- Round demo: the FIRST popout of the session, opened in rounded mode")
do
    pressCorners(1)                                  -- Square -> R4
    eq(cornerLabel(), "Corners: R4", "one press lands on R4")
    border:OpenPopout()
    local po = border.popout
    check(po ~= nil, "the row opened a popout")
    check(rawget(po, "srcOutline") == nil or not po.srcOutline:IsShown(),
          "R4: it comes up with no square outline at all")
end

print("-- Round demo: Square is what puts one there")
do
    -- The control for every "not shown" above and below: the shell really does
    -- draw this outline for these rows in this harness, so a suppressed one is a
    -- suppression rather than geometry that never showed anything.
    local po = border.popout
    pressCorners(3)                                  -- R4 -> R6 -> R8 -> Square
    eq(cornerLabel(), "Corners: Square", "three more presses come back to Square")
    check(po.srcOutline ~= nil, "square: the shell built its source outline")
    check(po.srcOutline:IsShown(), "square: ...and it is up, exactly as it ships")
    eq(po.srcOutline._points[1][2], border, "square: on the row the panel is about")
end

print("-- Round demo: a radius suppresses it")
do
    local po = border.popout
    pressCorners(1)                                  -- Square -> R4
    eq(cornerLabel(), "Corners: R4", "one press lands on R4")
    check(not po.srcOutline:IsShown(), "R4: the square outline is taken down")
    -- FORGOTTEN, not merely hidden: _HideSourceOutline clears the target it was
    -- anchored to, which is what makes the restore below re-anchor rather than
    -- come back on whichever row it happened to go down against.
    check(rawget(po, "_outlineOn") == nil, "R4: ...and the target it was on is forgotten")

    pressCorners(1)                                  -- R4 -> R6
    check(not po.srcOutline:IsShown(), "R6: still down")
    pressCorners(1)                                  -- R6 -> R8
    check(not po.srcOutline:IsShown(), "R8: still down")
end

print("-- Round demo: the suppression survives everything that re-docks")
do
    local po = border.popout
    -- _Present is the shell's "put it there and show the chrome" path and it ends
    -- in _UpdateSourceOutline. If the demo had suppressed the outline ONCE rather
    -- than shadowing the method, every re-dock -- and there is one per source move
    -- -- would put it straight back.
    po:_Present(po.side)
    check(not po.srcOutline:IsShown(), "R8: a re-dock does not bring it back")

    -- ...and neither does a retarget, which commits the chrome to the new source
    -- at once through a different call site again.
    shadow:OpenPopout()
    check(shadow.popout == po, "the popout is pooled and shared between rows")
    check(not po.srcOutline:IsShown(), "R8: retargeting to another row does not bring it back")

    -- ...nor an accent change, which repaints every piece of chrome that carries
    -- the colour.
    po:SetAccent({ r = 1, g = 0.5, b = 0, a = 1 })
    check(not po.srcOutline:IsShown(), "R8: an accent change does not bring it back")
end

print("-- Round demo: Square brings it back")
do
    local po = shadow.popout
    pressCorners(1)                                  -- R8 -> Square
    eq(cornerLabel(), "Corners: Square", "the fourth press is back to Square")
    check(po.srcOutline:IsShown(), "square: the outline returns")
    -- ...on the row the panel is ACTUALLY on now, not the one it was on when the
    -- radius was selected. That is the whole reason the hide forgets its target.
    eq(po.srcOutline._points[1][2], shadow, "square: ...anchored to the row it came back on")
end

print("-- Round demo: closing and re-opening does not resurrect it")
do
    -- A CLOSE is the one path that takes the whole connected chrome down by hand
    -- (HideChrome), so the re-open builds the outline's state back up from
    -- nothing. Not the same case as the cold open at the top of this file -- the
    -- instance is pooled and stays hooked across a close -- but it is the other
    -- way the outline's shown-state gets rebuilt, and it has to land on the same
    -- answer.
    host:CloseAllPopoutRows("test")
    pressCorners(2)                                  -- Square -> R4 -> R6
    eq(cornerLabel(), "Corners: R6", "back into rounded mode")
    border:OpenPopout()
    local po = border.popout
    check(po ~= nil and not po.srcOutline:IsShown(),
          "R6: a re-opened popout still comes up with no square outline")

    pressCorners(2)                                  -- R6 -> R8 -> Square
    eq(cornerLabel(), "Corners: Square", "and back to Square")
    check(po.srcOutline:IsShown(), "square: which restores it")
end

-- ============================================================
-- 2. THE TITLE BAR'S CROSS
--
-- A square 18px button parked a fixed distance in from the bar's right edge sits
-- inside the corner box once that corner is an arc. Rounded mode moves it inboard
-- by half the radius; Square puts it back on the number it started with -- the
-- ORIGINAL number, read off the anchor, not a literal copied into the demo.
-- ============================================================

local function anchorX(btn)
    local _, _, _, x = btn:GetPoint(1)
    return x
end

print("-- Round demo: the window's cross clears the arc")
do
    host:CloseAllPopoutRows("test")
    local cross = win.closeBtn
    local square = anchorX(cross)
    eq(square, -6, "square: the cross sits at its authored offset")

    pressCorners(1)                                  -- R4
    eq(anchorX(cross), square - 2, "R4: inboard by half the radius")
    pressCorners(1)                                  -- R6
    eq(anchorX(cross), square - 3, "R6: and by three at radius six")
    pressCorners(1)                                  -- R8
    eq(anchorX(cross), square - 4, "R8: and by four at radius eight")
    -- Shifted from the ORIGINAL each time, never compounded. A second radius that
    -- measured from the last shift would walk the cross across the title bar --
    -- slowly enough that three presses look fine and ten do not.
    check(anchorX(cross) > square - 9, "the shifts do not accumulate")

    pressCorners(1)                                  -- Square
    eq(anchorX(cross), square, "square: exactly the offset it started on")
    eq(cross:GetNumPoints(), 1, "...and still one anchor, not a stack of them")
end

print("-- Round demo: the popout's cross moves with it")
do
    pressCorners(2)                                  -- Square -> R4 -> R6
    border:OpenPopout()
    local po = border.popout
    local cross = po.closeBtn
    local x = anchorX(cross)
    check(x ~= nil, "the popout's cross is anchored the readable way")
    -- The shell's own offset is HDR_EDGE = 6, and the demo never names it: it
    -- reads the anchor back. So the assertion is the SHIFT, not the number.
    pressCorners(2)                                  -- R6 -> R8 -> Square
    local squareX = anchorX(cross)
    eq(x, squareX - 3, "R6 had it three units inboard of where Square puts it")

    pressCorners(3)                                  -- Square -> R4 -> R6 -> R8
    eq(anchorX(cross), squareX - 4, "R8: four units inboard")
    pressCorners(1)                                  -- Square
    eq(anchorX(cross), squareX, "square: back to the shell's own offset")
end

print("-- Round demo: Square restores the rounded surfaces too")
do
    -- The other half of "Square restores exactly", which the demo has always
    -- claimed: the rounded textures are the demo's own, so nothing else takes
    -- them down.
    local po = border.popout
    pressCorners(1)                                  -- R4
    local rs = UI:GetRoundedSurface(po.frame)
    check(rs ~= nil and rs:IsShown(), "R4: the panel wears a rounded surface")
    pressCorners(3)                                  -- back to Square
    check(not rs:IsShown(), "square: and it is hidden again")
    local plate = UI:GetRoundedSurface(border.plate)
    check(plate == nil or not plate:IsShown(), "square: the row plate's is down as well")
end

host:CloseAllPopoutRows("test")
win:Hide()

-- ---- restore --------------------------------------------------------
UI.CreatePopoutRow = baseCreateRow
UI.CreateCloseButton, UI.CreateGlyphButton = prevCloseButton, prevGlyphButton
CreateFrame, C_Timer = prevCreateFrame, prevTimer
PlaySound, SOUNDKIT = prevPlaySound, prevSoundKit
DandersFrames = prevDF
