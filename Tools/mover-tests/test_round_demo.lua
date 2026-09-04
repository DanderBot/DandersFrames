local NS = ...

-- ============================================================
-- THE RADIUS WORKBENCH -- DandersFrames_Options/GUI/PopoutDemo.lua
-- ------------------------------------------------------------
-- test_round.lua covers the rounded SURFACE and the surface STYLE; test_popout
-- and test_popout_row cover what each shell does with a style it is handed. This
-- file covers the workbench that drives all of it from one button, and the two
-- claims that only a cycling button can make:
--
--   1. the SOURCE OUTLINE swaps between a rounded ring (at the SOURCE's declared
--      radius) and the square pixel border, in both directions, through every
--      path that re-commits it -- a re-dock, a retarget, an accent change, a
--      close and re-open
--   2. the title bars' CROSS is nudged inboard of the arc and returns to its
--      ORIGINAL offset on Square, shifted from that original every time rather
--      than compounded
--
-- ☠ THE SHAPE OF THIS FILE'S SUBJECT CHANGED COMPLETELY. It used to test five
-- per-instance SHADOWS the demo installed on the library -- swapped backdrop
-- methods on the row plate, a shadowed _ApplyAccent, a shadowed
-- _UpdateSourceOutline that SUPPRESSED the outline in rounded mode, and an
-- OpenPopout wrapper to install the lot on a pooled panel. Every one of those is
-- a first-class option now, and the outline is no longer suppressed -- it
-- follows the source's shape. Assertions written against the old behaviour would
-- pass here only by accident, so they were rewritten rather than adjusted.
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
-- PopoutRow.lua reads the amber notice token at FILE SCOPE (the modified tick).
C.notice     = C.notice     or { r = 0.91, g = 0.66, b = 0.25, a = 1 }
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
UI.PopoutFooter = UI.PopoutFooter or { height = 26, btnHeight = 18, gap = 6, sepAlpha = UI.PopoutTitle.sepAlpha }
UI.Space = UI.Space or { section = 16 }
UI.StyleScrollBar = UI.StyleScrollBar or function(sf) sf._styledScrollBar = true end
UI.PopoutRow = UI.PopoutRow or {
    plate = 44, gap = 8, padX = 10, labelGap = 10, colGap = 6,
    check = 16, checkTick = 9, gear = 14, chevron = 10,
    badgeW = 22, badgeH = 16, modTick = 5,
    labelSize = 12, summarySize = 11, badgeSize = 10,
    restFill = 0.55, hoverFill = 0.75, restBorder = 0.5,
    activeFill = 0.14, activeHover = 0.20, activeBorder = 1,
    badgeFill = 0.55, badgeBorder = 0.45,
    -- The hoisted-controls half of the token table (Theme.lua). Mirrored whole
    -- for the reason the rest of it is: PopoutRow.lua reads these at FILE SCOPE,
    -- so a missing one is a nil in an arithmetic expression at load.
    lineH = 36, nameH = 12, controlH = 24, linePad = 4,
    cellGap = 10, nameSize = 9, minControl = 98, splitCell = 166,
    footer = 18, footerFill = 0.85, footerBorder = 0.6, footerOn = 0.22,
    plateStrip = 30, stripArc = 8, modTickGap = 2,
    dropdownH = 24, sliderH = 50, sliderBarMid = 22,
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
-- Normally run.py's, and it records the same way: "did the rounded path actually
-- take the square border down" has to stay answerable. Kept as a fallback for a
-- harness that stopped providing it.
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
--
-- `popoutRadius` is on the list for the same reason as `popout`: it is the
-- tether contract's SHAPE half, a row sets it to nil when it goes square, and a
-- metatable that answered a function there would make "this row declares no
-- curve" untestable. (The library itself reads it with rawget, so only the test
-- is affected -- but a harness that cannot express the nil is a harness that
-- cannot catch the row forgetting to clear it.)
local function dataAwareMeta(k)
    if k == "popout" or k == "popoutRadius" then return nil end
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
-- The shell draws an accent outline over whatever the panel is tethered to. It
-- used to be a pixel border and nothing else -- square by construction -- so in
-- rounded mode it traced a hard rectangle round a plate that had just been given
-- a curve: "a second corner around a selected object".
--
-- ☠ AND THE ANSWER IS NO LONGER "TAKE IT AWAY". The trial's fix was to suppress
-- the outline entirely while a radius was selected and let the row's own active
-- ring stand in for it -- which worked only because the source happened to BE a
-- row, and silently dropped the shell's half of the shared-edge story for any
-- other kind of source. The shipping shell instead follows the SOURCE'S shape: a
-- source declares its curve on the tether contract (row.popoutRadius, set by the
-- row when it takes a rounded surface) and the outline becomes a rounded RING at
-- that radius. Square source, or square panel, and it is the pixel border
-- exactly as it always was.
--
-- So what these blocks assert is the SWAP, not a suppression, and every one of
-- them would have passed against the old suppression only by accident.
-- ============================================================

-- Which of the two paints the outline is currently wearing. The ring is a
-- rounded surface on the outline's own frame; the square one is the pixel
-- border, which this harness records as _pxColor (test_popout_row's stub).
local function outlineRing(po)
    local o = rawget(po, "srcOutline")
    if not o then return nil end
    local rs = UI:GetRoundedSurface(o)
    if rs and rs:IsShown() then return rs end
    return nil
end

-- ☠ THE COLD OPEN GOES FIRST, and the order is the assertion.
--
-- A popout is POOLED, and the only moment in a session at which the shell can
-- present a panel before anything has told it what shape to be is the VERY FIRST
-- open. Under the old demo that was a real hazard -- the shadows were installed
-- by a wrapper that ran after the shell had already painted -- and it is what
-- the whole first-class `surface` option removes: the row forwards its style
-- into CreatePopout, so the panel is the right shape before it is placed.
--
-- This block cannot be moved further down the file: open one popout in Square
-- first and every later "from cold" is a lie, because the instance already
-- exists and every later open is an adopt.
print("-- Round demo: the FIRST popout of the session, opened in rounded mode")
do
    pressCorners(1)                                  -- Square -> R4
    eq(cornerLabel(), "Corners: R4", "one press lands on R4")
    eq(border.popoutRadius, 4, "R4: the row declares its curve on the tether contract")
    border:OpenPopout()
    local po = border.popout
    check(po ~= nil, "the row opened a popout")
    check(po.surface ~= nil and po.surface.radius == 4,
          "R4: the panel took the row's style, not the host's")
    local ring = outlineRing(po)
    check(ring ~= nil, "R4: the outline is up, and it is a ROUNDED ring")
    eq(ring:GetRadius(), 4, "R4: at the source's radius, not the panel's")
    -- RING ONLY. The outline lies on top of the plate it is outlining, so a fill
    -- of any alpha would be a pane of glass over the row.
    check(ring.hasFill == false, "R4: ...and it draws no interior at all")
end

print("-- Round demo: Square is the pixel border, exactly as it shipped")
do
    local po = border.popout
    pressCorners(3)                                  -- R4 -> R6 -> R8 -> Square
    eq(cornerLabel(), "Corners: Square", "three more presses come back to Square")
    check(po.srcOutline ~= nil and po.srcOutline:IsShown(),
          "square: the outline is still up -- it is not suppressed in either mode")
    check(outlineRing(po) == nil, "square: and the rounded ring is down")
    check(po.srcOutline._pxColor ~= nil, "square: the pixel border is what is drawn")
    eq(po.srcOutline._points[1][2], border, "square: on the row the panel is about")
    eq(border.popoutRadius, nil, "square: the row declares no curve")
end

print("-- Round demo: a radius swaps the paint, in both directions")
do
    local po = border.popout
    pressCorners(1)                                  -- Square -> R4
    local ring = outlineRing(po)
    check(ring ~= nil, "R4: the ring is back")
    eq(ring:GetRadius(), 4, "R4: at four")
    pressCorners(1)                                  -- R4 -> R6
    eq(outlineRing(po):GetRadius(), 6, "R6: the ring re-textures rather than stacking")
    pressCorners(1)                                  -- R6 -> R8
    eq(outlineRing(po):GetRadius(), 8, "R8: and again at eight")
end

print("-- Round demo: the ring survives everything that re-docks")
do
    local po = border.popout
    -- _Present is the shell's "put it there and show the chrome" path and it ends
    -- in _UpdateSourceOutline. A shape committed ONCE rather than re-decided on
    -- every anchor would be lost here.
    po:_Present(po.side)
    check(outlineRing(po) ~= nil, "R8: a re-dock keeps the ring")

    -- ...and a retarget, which commits the chrome to a new source through a
    -- different call site again -- and re-reads the NEW source's declared curve.
    shadow:OpenPopout()
    check(shadow.popout == po, "the popout is pooled and shared between rows")
    check(outlineRing(po) ~= nil, "R8: retargeting to another row keeps it")
    eq(po.srcOutline._points[1][2], shadow, "R8: ...anchored to the row it moved to")

    -- ...nor does an accent change, which repaints every piece of chrome that
    -- carries the colour and must repaint the RING rather than reinstating the
    -- pixel border underneath it.
    po:SetAccent({ r = 1, g = 0.5, b = 0, a = 1 })
    local ring = outlineRing(po)
    check(ring ~= nil, "R8: an accent change keeps it a ring")
    eq(ring.borderR, 1, "R8: ...repainted in the new accent")
end

print("-- Round demo: Square puts the pixel border back")
do
    local po = shadow.popout
    pressCorners(1)                                  -- R8 -> Square
    eq(cornerLabel(), "Corners: Square", "the fourth press is back to Square")
    check(outlineRing(po) == nil, "square: the ring is taken down")
    check(po.srcOutline:IsShown(), "square: and the outline itself is still up")
    -- ...on the row the panel is ACTUALLY on now, not the one it was on when the
    -- radius was selected. That is why the hide forgets its target AND its shape.
    eq(po.srcOutline._points[1][2], shadow, "square: anchored to the row it came back on")
end

print("-- Round demo: closing and re-opening rebuilds the right shape")
do
    -- A CLOSE is the one path that takes the whole connected chrome down by hand
    -- (HideChrome), so the re-open builds the outline's state back up from
    -- nothing -- target, shown-state and shape alike.
    host:CloseAllPopoutRows("test")
    pressCorners(2)                                  -- Square -> R4 -> R6
    eq(cornerLabel(), "Corners: R6", "back into rounded mode")
    border:OpenPopout()
    local po = border.popout
    check(po ~= nil, "the row re-opened a popout")
    local ring = outlineRing(po)
    check(ring ~= nil and ring:GetRadius() == 6,
          "R6: a re-opened popout comes up with the ring at the current radius")

    pressCorners(2)                                  -- R6 -> R8 -> Square
    eq(cornerLabel(), "Corners: Square", "and back to Square")
    check(outlineRing(po) == nil and po.srcOutline:IsShown(),
          "square: which restores the pixel border")
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
