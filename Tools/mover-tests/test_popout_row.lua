local NS = ...

-- ============================================================
-- TEST HOST -- PopoutRow
-- ------------------------------------------------------------
-- Same arrangement as test_popout.lua: `ns.__DandersUI` is a plain table
-- standing in for the library, the "host" is a table whose __index is that, and
-- the factories PopoutRow reaches for are stubbed onto the library.
--
-- ⚠ ONE RUNTIME, SHARED LIBRARY TABLE. run.py loads every test_*.lua into the
-- SAME LuaRuntime in alphabetical order, so test_popout.lua has normally already
-- installed Popout.lua and its half of the stubs onto this table by the time
-- this file runs. Everything below is therefore written to ADD rather than
-- replace: re-loading Popout.lua would swap the object the popouts still alive
-- in that file's closures were built from, and re-stubbing its factories would
-- change what a later test sees. `run.py popout_row` on its own still works --
-- each guard fills in what nobody installed.
--
-- test_popout.lua also RESTORES CreateFrame/C_Timer at its end, so this file
-- re-stubs both (with a richer frame -- see below) and restores them again.
-- ============================================================
local UI = NS.__DandersUI

-- ---- what the base half would have installed ----------------------
-- Only when nobody has: see the note above. The values match test_popout.lua's,
-- which are in turn the shapes Popout.lua and PopoutRow.lua read.
UI.MEDIA = UI.MEDIA or ""
UI.Colors = UI.Colors or { text = { r = 0.9, g = 0.9, b = 0.9 },
                           textDim = { r = 0.5, g = 0.5, b = 0.5 } }
-- The plate's neutrals, mirrored from Theme.lua. test_popout.lua's half of the
-- palette stops at the two text colours, so these are added rather than assumed:
-- PopoutRow reads all four at FILE SCOPE and a nil would blow up on load.
UI.Colors.element    = UI.Colors.element    or { r = 0.18, g = 0.18, b = 0.18, a = 1 }
UI.Colors.border     = UI.Colors.border     or { r = 0.25, g = 0.25, b = 0.25, a = 1 }
UI.Colors.hover      = UI.Colors.hover      or { r = 0.22, g = 0.22, b = 0.22, a = 1 }
UI.Colors.background = UI.Colors.background or { r = 0.08, g = 0.08, b = 0.08, a = 0.95 }
-- The amber notice token, mirrored from Theme.lua's C_NOTICE: the modified tick
-- on the count pill reads it at FILE SCOPE.
UI.Colors.notice     = UI.Colors.notice     or { r = 0.91, g = 0.66, b = 0.25, a = 1 }
if not UI.GetAccent then
    local A = { r = 0.45, g = 0.45, b = 0.95, a = 1 }
    function UI:GetAccent() return A end
end
-- Both backdrop factories RECORD what they were asked to paint: the accent
-- chrome is only observable as the colour these were handed.
if not UI.CreatePanelBackdrop then
    function UI:CreatePanelBackdrop(frame, opts) frame._panelOpts = opts return frame end
end
if not UI.ApplyPixelBorder then
    function UI:ApplyPixelBorder(frame, color, weight)
        frame._pxColor, frame._pxWeight = color, weight
        return frame
    end
end
-- The element backdrop, which the row's plate and its count pill are both built
-- from. Records what it was asked to paint AND installs the two recolour methods
-- the real one leaves behind (SetBackdropColor from BackdropTemplateMixin,
-- SetBackdropBorderColor from the pixel-border shim) -- the row drives both on
-- every state change, and the stub's catch-all __index would swallow them.
--
-- ⚠ THE ONE STUB HERE THAT REPLACES RATHER THAN ADDS, against this file's own
-- rule at the head. test_panel.lua installs `function KIT:CreateElementBackdrop()
-- end` on the SAME shared table and runs first, so the guarded version of this
-- never took -- and a no-op cannot answer what the plate was painted, which is
-- the whole of the row's rest/hover/active look. Replacing a no-op with a
-- recorder is a superset: nothing else in the suite reads what it records, and
-- every test that ran against the no-op has already finished.
do
    function UI:CreateElementBackdrop(frame, opts)
        opts = opts or {}
        frame._elementOpts = opts
        frame.SetBackdropColor = function(self, r, g, b, a)
            self._fill = { r = r, g = g, b = b, a = a }
        end
        frame.SetBackdropBorderColor = function(self, r, g, b, a)
            self._edge = { r = r, g = g, b = b, a = a }
        end
        local bg, bc = opts.bgColor, opts.borderColor
        if bg then frame:SetBackdropColor(bg.r or bg[1], bg.g or bg[2], bg.b or bg[3], bg.a or bg[4] or 1) end
        if bc then frame:SetBackdropBorderColor(bc.r or bc[1], bc.g or bc[2], bc.b or bc[3], bc.a or bc[4] or 1) end
        return frame
    end
end
if not UI.CreateLabel then
    function UI:CreateLabel(_, opts)
        local fs = FakeUIFrame()
        if opts and opts.text then fs:SetText(opts.text) end
        return fs
    end
end
if not UI.CreateCloseButton then
    local function stubButton(opts)
        local b = FakeUIFrame(16, 16)
        b._opts = opts
        b:Show()
        return b
    end
    function UI:CreateCloseButton(_, opts) return stubButton(opts) end
    function UI:CreateGlyphButton(_, opts) return stubButton(opts) end
end

-- ---- Theme.lua metrics --------------------------------------------
-- Mirrors of the real values (Theme.lua is not loadable headless: it wants
-- GetPhysicalScreenSize, Mixin and BackdropTemplateMixin). PopoutRow reads all
-- four at FILE SCOPE, so they have to be here before the load below.
UI.RowGap = UI.RowGap or 14
UI.RowHeight = UI.RowHeight or { checkbox = 35 }
UI.PopoutContentWidth = UI.PopoutContentWidth or 260
UI.PopoutTitle = UI.PopoutTitle or { topPad = 6, row = 28, fill = 0.9, sepAlpha = 0.8 }
UI.PopoutTitleHeight = UI.PopoutTitleHeight or (UI.PopoutTitle.topPad + UI.PopoutTitle.row)
UI.PopoutPad = UI.PopoutPad or 10
UI.PopoutFooter = UI.PopoutFooter or { height = 26, btnHeight = 18, gap = 6, sepAlpha = UI.PopoutTitle.sepAlpha }
UI.StyleScrollBar = UI.StyleScrollBar or function(sf) sf._styledScrollBar = true end
-- The row's own box model (Theme.lua's UI.PopoutRow). Mirrored whole, and the
-- slot derived the same way the real one is, so the two cannot drift into
-- numbers that disagree.
UI.PopoutRow = UI.PopoutRow or {
    plate = 44, gap = 10, padX = 10, labelGap = 10, colGap = 6,
    check = 16, checkTick = 9, gear = 14, chevron = 10,
    badgeW = 22, badgeH = 16, modTick = 5,
    labelSize = 12, summarySize = 11, badgeSize = 10,
    restFill = 0.55, hoverFill = 0.75, restBorder = 0.8,
    activeFill = 0.14, activeHover = 0.20, activeBorder = 1,
    badgeFill = 0.55, badgeBorder = 0.45,
    -- The hoisted-controls half of the token table (Theme.lua). Mirrored whole
    -- for the reason the rest of it is: PopoutRow.lua reads these at FILE SCOPE,
    -- so a missing one is a nil in an arithmetic expression at load.
    lineH = 36, nameH = 12, controlH = 24, linePad = 10,
    cellGap = 10, nameSize = 9, minControl = 98, splitCell = 166,
    footer = 18, footerFill = 0.85, footerHover = 1.0,
    footerBorder = 0.6, footerOn = 0.22, footerOnHover = 0.30,
    plateStrip = 30, stripArc = 8, modTickGap = 2,
    dropdownH = 24, sliderH = 50, sliderBarMid = 22,
}
UI.PopoutRow.slot = UI.PopoutRow.plate + UI.PopoutRow.gap

local M       = UI.PopoutRow
local ROW_H   = M.slot
local PLATE_H = M.plate
local PW      = UI.PopoutContentWidth
local TITLE_H, PAD = UI.PopoutTitleHeight, UI.PopoutPad

-- ---- widget stubs PopoutRow touches -------------------------------
-- StyleCheckButton's whole observable contract from here: it sizes the box, it
-- leaves a .Check, and it publishes ApplyThemeColor so a consumer can re-tint.
function UI:StyleCheckButton(cb, opts)
    opts = opts or {}
    cb:SetSize(opts.size or 18, opts.size or 18)
    cb.Check = cb.Check or FakeUIFrame()
    cb._styleOpts = opts
    cb.ApplyThemeColor = function(c) cb._tint = c end
    cb.ApplyThemeColor(opts.accent or self:GetAccent())
    -- ...and the other half of the real contract: an UNACCENTED box registers
    -- itself on its themeRoot's ThemeListeners, which is the list the popout's
    -- accent cascade walks. Without this the header toggle would look unreachable
    -- from a test and the cascade's frame-rooted claim could not be made.
    --
    -- ⚠ rawget. The stub answers every unknown key with a no-op FUNCTION, so a
    -- plain `root.ThemeListeners or {}` keeps that function and table.insert
    -- errors on it. Real frames answer nil, which is why Widgets.lua can write it
    -- the short way.
    if not opts.accent then
        cb.UpdateTheme = function() cb.ApplyThemeColor(self:GetAccent()) end
        local root = opts.themeRoot or cb:GetParent()
        if type(root) == "table" then
            local list = rawget(root, "ThemeListeners")
            if not list then list = {}; root.ThemeListeners = list end
            list[#list + 1] = cb
        end
    end
    return cb.Check
end

-- The *Native alias is what library code must call (the shadow hazard). Records
-- its colour, which the stock FakeUIFrame has no SetTextColor for.
function UI:CreateLabelNative(parent, opts)
    local fs = FakeUIFrame()
    fs._labelOpts = opts
    -- ☠ THE PARENT IS RECORDED. A FontString is a REGION, and a region created on
    -- the wrong parent is simply never drawn -- the hidden-holder trap this
    -- rework has already been bitten by, and the reason a hoisted control's name
    -- lives in a frame of its own rather than on the plate. A stub that dropped
    -- the parent could not tell the two apart.
    fs:SetFakeParent(parent)
    fs.SetTextColor = function(self, r, g, b, a) self._textColor = { r = r, g = g, b = b, a = a } end
    if opts and opts.color then fs:SetTextColor(opts.color.r, opts.color.g, opts.color.b) end
    if opts and opts.text then fs:SetText(opts.text) end
    return fs
end

-- The hook plumbing, verbatim from Core.lua (which a headless run never loads).
-- PopoutRow reaches the consumer's debug printer through it, and a hook that is
-- absent must be silence rather than a nil call -- which is the whole point of
-- these two.
function UI:Hook(name)
    local h = rawget(self, "hooks")
    return h and h[name] or nil
end
function UI:Call(name, ...)
    local fn = self:Hook(name)
    if not fn then return nil end
    return fn(...)
end

local ACCENT = UI:GetAccent()
local C_TEXT, C_TEXT_DIM = UI.Colors.text, UI.Colors.textDim

-- ---- WoW globals --------------------------------------------------
local prevCreateFrame, prevTimer = CreateFrame, C_Timer
local prevPlaySound, prevSoundKit = PlaySound, SOUNDKIT
PlaySound = function() end
SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = 1 }

-- ☠ A MISSING DATA FIELD MUST READ nil, NOT A FUNCTION. FakeUIFrame answers
-- every unknown key with a no-op function so a module may call any frame method
-- it likes -- which is fine for METHODS and wrong for STATE: a widget that keeps
-- `row._accent`, `row._count` or `row.popout` on its own frame would read a
-- truthy function back for every one it has not set, and `row.popout == nil` --
-- a documented part of this widget's contract -- could never be true.
--
-- The rule that separates the two here is the codebase's own: an underscore
-- prefix means a field, and no WoW method is named that way. `popout` and
-- `popoutRadius` -- the tether contract's shape half, which a square row clears
-- back to nil -- are the two public fields this widget publishes without one.
local function dataAwareMeta(k)
    if k == "popout" or k == "popoutRadius" then return nil end
    if type(k) == "string" and k:byte(1) == 95 then return nil end   -- "_"
    return function() end
end

-- A richer CreateFrame than test_popout's: PopoutRow counts the CONTROLS a
-- consumer mounted (frames, not fontstrings) to check them against the declared
-- count, and it drives a real CheckButton's checked state -- neither of which
-- the bare stub can answer. Textures grow a SetColorTexture recorder so the
-- hover plate is observable too.
CreateFrame = function(kind, _, parent)
    local f = FakeUIFrame()
    setmetatable(f, { __index = function(_, k) return dataAwareMeta(k) end })
    f._kind = kind
    f._children = {}
    f._parent = parent
    f.GetParent = function(self) return self._parent end
    f.SetParent = function(self, p) self._parent = p end
    f.GetNumChildren = function(self) return #self._children end
    -- The popout's accent cascade walks the frame tree looking for
    -- ThemeListeners lists, so the stub has to have a tree to walk.
    f.GetChildren = function(self) return unpack(self._children) end
    if kind == "CheckButton" then
        f.SetChecked = function(self, v) self._checked = v and true or false end
        f.GetChecked = function(self) return self._checked end
    end
    local rawCreateTexture = f.CreateTexture
    f.CreateTexture = function(self, ...)
        local t = rawCreateTexture(self, ...)
        t.SetColorTexture = function(s, r, g, b, a) s._fill = { r = r, g = g, b = b, a = a } end
        return t
    end
    -- rawget, not a plain read: FakeUIFrame's __index fallback answers EVERY
    -- missing key with a function, so `parent._children or {}` would keep that
    -- function and try to take its length.
    if type(parent) == "table" then
        local kids = rawget(parent, "_children")
        if not kids then kids = {}; parent._children = kids end
        kids[#kids + 1] = f
    end
    return f
end

local delays = {}
C_Timer = { After = function(d, fn) delays[#delays + 1] = d; fn() end }

local CX, CY = 960, 540      -- the shim's UIParent centre

local L = setmetatable({}, { __index = function(_, k) return k end })
local dbgLog = {}
local host = setmetatable({ hooks = {
    L = L,
    debug = function(cat) return function(msg) dbgLog[#dbgLog + 1] = { cat = cat, msg = msg } end end,
} }, { __index = UI })

-- Only if nobody has: test_popout.lua normally owns this load (see the head).
if not UI.CreatePopout then load_ui_file("Popout.lua") end
load_ui_file("PopoutRow.lua")

-- ---- fixtures ------------------------------------------------------
-- A window at screen centre and rows inside it: the row gives the popout its y,
-- the window gives it its x (the outsideOf placement, Popout.lua).
local WIN_W, WIN_H = 600, 400
local function window()
    local w = FakeUIFrame(WIN_W, WIN_H, CX, CY)
    w:Show()
    return w
end

-- `dy` is the row's height above/below the window's middle, in UIParent-centre
-- units -- the same units every rect in the popout tests is stated in.
local function place(row, dy)
    row:SetSize(260, ROW_H)
    row:SetFakeCenter(CX - 100, CY + (dy or 0))
    row:Show()
    return row
end

local builds = {}
local function counting(name, h, controls)
    return function(_, pane)
        builds[name] = (builds[name] or 0) + 1
        for _ = 1, (controls or 0) do CreateFrame("Frame", nil, pane) end
        pane:SetHeight(h or 60)
    end
end

-- ============================================================
-- 1. ROW ANATOMY
-- Toggle, name, live summary, count badge, way in. Everything the row promises
-- to show at a glance, and the slot it occupies in a settings column.
-- ============================================================
do
    local db = { on = true, size = 12 }
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras",
        db = db,
        toggle = { key = "on" },
        summary = function(d) return "size " .. d.size end,
        count = 4,
        build = counting("anatomy", 60, 4),
        window = window(),
    })
    check(row.checkButton ~= nil, "row: it has a toggle")
    eq(row.label:GetText(), "Auras", "row: the label is the name it was given")
    eq(row.summary:GetText(), "size 12", "row: the summary is rendered from the db")
    eq(row.badge:GetText(), "4", "row: the count badge carries the declared count")
    check(row.gear ~= nil and row.chevron ~= nil, "row: gear and chevron are both drawn")
    eq(row:GetHeight(), ROW_H, "row: it takes the popout row's own slot")
    eq(row.preferredHeight, ROW_H, "row: ...and stamps it, so a call-site number cannot override it")
    check(row.fixedRowHeight, "row: the slot is owned by the factory, not the call site")
    -- rawget: rowKind is not underscore-prefixed, so the stub's method fallback
    -- would answer for it; the claim is that the FACTORY never wrote one.
    eq(rawget(row, "rowKind"), nil, "row: no rowKind -- an unknown kind would break a run of checkboxes")
    eq(row.plate:GetHeight(), PLATE_H, "row: the plate is the slot less its gap")
    eq(ROW_H - PLATE_H, M.gap, "row: ...and the gap is what is left, which is what the next row stands on")

    -- THE PLATE IS A BORDERED SURFACE, not the bare 3%-white texture it was. At
    -- rest it is the kit's element fill inside the kit's element border -- the
    -- same pair every dropdown and edit box wears -- so a column of rows reads as
    -- a stack of controls rather than as faint bands on the page.
    eq(row.plate._fill.r, UI.Colors.element.r, "row: the plate rests on the element fill")
    eq(row.plate._fill.a, M.restFill, "row: ...at the rest alpha")
    eq(row.plate._edge.r, UI.Colors.border.r, "row: inside the element border")
    eq(row.plate._edge.a, M.restBorder, "row: ...at the border's own half strength")

    row:GetScript("OnEnter")()
    eq(row.plate._fill.r, UI.Colors.hover.r, "row: hovering lifts it to the hover colour")
    eq(row.plate._fill.a, M.hoverFill, "row: ...and brightens it")
    row:GetScript("OnLeave")()
    eq(row.plate._fill.r, UI.Colors.element.r, "row: and leaving puts it back")
    eq(row.plate._fill.a, M.restFill, "row: ...to the rest alpha")

    -- The count is a PILL: a fixed, bordered chip with its own darker fill,
    -- carrying the number centred inside it.
    check(row.badgePill ~= nil, "row: the count is drawn in a pill")
    eq(row.badgePill:GetWidth(), M.badgeW, "row: sized, not measured -- the width is the column's")
    eq(row.badgePill:GetHeight(), M.badgeH, "row: ...and its height is fixed too")
    eq(row.badgePill._fill.r, UI.Colors.background.r, "row: the pill is darker than the plate it sits on")
    eq(row.badgePill._edge.r, UI.Colors.border.r, "row: and carries a border of its own")
    check(row.badgePill:IsShown(), "row: a declared count draws the pill")
end

-- No count, no pill: an empty bordered chip beside the chevron says nothing.
do
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Countless", db = {}, build = counting("nopill", 40), window = window(),
    })
    eq(row.badge:GetText(), "", "pill: no count, no number")
    check(not row.badgePill:IsShown(), "pill: ...and no pill either")
end

-- ============================================================
-- 2. THE LIVE SUMMARY
-- The row's whole reason for existing is that it says what the group is set to
-- WITHOUT being opened, so the summary has to track the db rather than the
-- string it was built with.
-- ============================================================
do
    local db = { on = true, size = 12 }
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = db, toggle = { key = "on" },
        summary = function(d) return "size " .. d.size end,
        build = counting("summary", 40), window = window(),
    })
    db.size = 30
    row.Refresh()
    eq(row.summary:GetText(), "size 30", "summary: Refresh re-reads the db")
end

-- A FUNCTION db is re-resolved on every refresh, so a consumer whose settings
-- table is swapped underneath it (a mode switch) stays live.
do
    local party = { on = true, size = 12 }
    local raid  = { on = true, size = 99 }
    local current = party
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = function() return current end, toggle = { key = "on" },
        summary = function(d) return "size " .. d.size end,
        build = counting("dbfn", 40), window = window(),
    })
    eq(row.summary:GetText(), "size 12", "db fn: the first read went to the first table")
    current = raid
    row.Refresh()
    eq(row.summary:GetText(), "size 99", "db fn: ...and the next one to the table it now returns")
    -- The toggle reads through the same function, so it moves with the db.
    raid.on = false
    row.Refresh()
    eq(row.summary:GetText(), "Off", "db fn: the toggle followed the db too")
end

-- ============================================================
-- 3. TOGGLED OFF, AND DEPENDENT GREY
-- Two different statements. OFF means "this feature is not doing anything", and
-- the row dims but the tick stays live. GREY means "you cannot act on this yet",
-- and everything dims -- but the popout still opens either way.
-- ============================================================
do
    local db = { on = true, size = 12 }
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = db, toggle = { key = "on" },
        summary = function(d) return "size " .. d.size end,
        build = counting("off", 40), window = win,
    }))
    eq(row.summary._textColor.a, 1, "off: on, the summary is at full strength")
    db.on = false
    row.Refresh()
    eq(row.summary:GetText(), "Off", "off: the summary is replaced by the off word")
    eq(row.label._textColor.r, C_TEXT_DIM.r, "off: the label goes dim")
    check(row.gear._vertex.a < 0.6, "off: and the glyphs fade")
    eq(row:GetAlpha(), 1, "off: but the ROW is not greyed -- the tick must stay clickable")
    db.on = true
    row.Refresh()
    eq(row.summary:GetText(), "size 12", "off: switching back restores the summary")
    eq(row.label._textColor.r, C_TEXT.r, "off: ...and the label")
end

-- A custom off word, for a row whose "off" reads better as something else.
do
    local db = { on = false }
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = db, toggle = { key = "on" }, offText = "Hidden",
        summary = function() return "never seen" end,
        build = counting("offtext", 40), window = window(),
    })
    eq(row.summary:GetText(), "Hidden", "off: opts.offText wins over the locale default")
end

-- enabled as a PREDICATE: the row greys with the thing it depends on, and the
-- popout still opens, because the control that would switch that thing on may
-- well be inside it.
do
    local db = { master = false, on = true }
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = db, toggle = { key = "on" },
        enabled = function(d) return d.master end,
        summary = function() return "ready" end,
        build = counting("dep", 40), window = win,
    }))
    eq(row:GetAlpha(), 0.4, "dep: a false predicate greys the whole row")
    check(row.checkButton:IsEnabled() == false, "dep: the toggle greys with it")
    row:OpenPopout()
    check(row.popout ~= nil and row.popout:IsShown(), "dep: ...and the popout still opens")
    row:ClosePopout()

    db.master = true
    row.Refresh()
    eq(row:GetAlpha(), 1, "dep: a true predicate un-greys it")
    check(row.checkButton:IsEnabled(), "dep: and the toggle comes back")

    -- An explicit SetEnabled overrides the predicate from there on, so a page
    -- driving disableOn and a row carrying its own gate cannot fight.
    row:SetEnabled(false)
    eq(row:GetAlpha(), 0.4, "dep: SetEnabled(false) greys it")
    row.Refresh()
    eq(row:GetAlpha(), 0.4, "dep: ...and the predicate does not undo it on the next refresh")
    row:SetEnabled(true)
    eq(row:GetAlpha(), 1, "dep: SetEnabled(true) puts it back")
end

-- ============================================================
-- 4. OPENING
-- The popout docks OUTSIDE the window at the row's height (the settings
-- placement), wears the row's name, and is about the ROW.
-- ============================================================
do
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", title = "Aura settings",
        db = { on = true }, toggle = { key = "on" },
        summary = function() return "3 shown" end,
        count = 2, build = counting("open", 60, 2), window = win,
    }), 50)
    row:OpenPopout()
    local po = row.popout
    check(po ~= nil, "open: the row has a popout")
    eq(po.outsideOf, win, "open: it docked outside the WINDOW, not beside the row")
    eq(po.side, "right", "open: on the right, where there is room")
    eq(po.source, row, "open: and it follows the row")
    local pt = po.frame._points[1]
    eq(pt[1], "CENTER", "open: an explicit screen anchor -- the y is a function of two clamps")
    eq(pt[2], UIParent, "open: ...off UIParent, not the window or the row")
    eq(po.titleFS:GetText(), "Aura settings", "open: the header is the row's title")
    eq(po.frame:GetWidth(), PW + PAD * 2, "open: the standard content width plus the popout's padding")
    eq(po.content:GetHeight(), 60, "open: the content is as tall as the pane the row built")
    eq(po.frame:GetHeight(), TITLE_H + PAD + 60 + PAD, "open: and the frame followed it")
    eq(po.srcOutline._points[1][2], row, "open: the beam and outline are on the ROW")
    check(po.beam:IsShown(), "open: the beam is up")

    -- The title defaults to the label when no title was given.
    row:ClosePopout()
    local plain = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Borders", db = {}, build = counting("opentitle", 40), window = win,
    }), -50)
    plain:OpenPopout()
    eq(plain.popout.titleFS:GetText(), "Borders", "open: no title means the label is the title")
    plain:ClosePopout()
end

-- A row with no window has nothing to dock outside of, so it refuses rather
-- than landing the panel on top of the list it came from.
do
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Nowhere", db = {}, build = counting("nowin", 40),
    }))
    row:OpenPopout()
    eq(row.popout, nil, "open: no window, no popout")
end

-- ============================================================
-- 5. TOGGLE SYNC, BOTH WAYS
-- The row's tick and the popout header's tick are two views of one value, so
-- either has to move the other -- and the db has to actually change.
-- ============================================================
do
    local db = { on = false }
    local seen = {}
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = db, toggle = { key = "on" },
        onToggle = function(v) seen[#seen + 1] = v end,
        summary = function() return "on" end,
        count = 1, build = counting("sync", 40, 1), window = win,
    }))
    row:OpenPopout()
    local po = row.popout
    check(po._hdrToggle ~= nil, "sync: the popout header carries a toggle")
    check(po._hdrToggle:GetChecked() == false, "sync: which came up matching the db")
    eq(po._hdrBadge:GetText(), "1", "sync: and a count badge")

    -- Flip it from the ROW.
    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    eq(db.on, true, "sync: the row's tick wrote the db")
    eq(seen[1], true, "sync: onToggle fired with the new value")
    check(po._hdrToggle:GetChecked() == true, "sync: and the header followed")
    eq(row.summary:GetText(), "on", "sync: the row's summary came back")

    -- Flip it from the HEADER.
    po._hdrToggle:SetChecked(false)
    po._hdrToggle:GetScript("OnClick")(po._hdrToggle)
    eq(db.on, false, "sync: the header's tick wrote the db too")
    eq(seen[2], false, "sync: ...through the same onToggle")
    check(row.checkButton:GetChecked() == false, "sync: and the row followed")
    eq(row.summary:GetText(), "Off", "sync: the row went to its off word")
    row:ClosePopout()
end

-- get/set toggles, for a row whose value is not a plain db key.
do
    local stored, win = false, window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Custom", db = {},
        toggle = { get = function() return stored end, set = function(v) stored = v end },
        summary = function() return "custom" end,
        build = counting("getset", 40), window = win,
    }))
    eq(row.summary:GetText(), "Off", "get/set: the getter decided the initial state")
    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    eq(stored, true, "get/set: the setter took the write")
    eq(row.summary:GetText(), "custom", "get/set: and the row re-read through the getter")
end

-- ---- the tick writes through the host's SETTING HOOKS -----------------
-- A {db, key} toggle is a setting like any other, so it takes the route every
-- db-bound widget in Widgets.lua takes: interceptWrite first (the consumer may
-- redirect the write to a baseline it keeps under a runtime overlay), then the
-- plain write, then onSettingWritten (the consumer may record it as an override
-- while a layout is being edited). The row's tick and an ordinary checkbox bound
-- to the SAME key have to be ONE write path, or half a consumer's panel honours
-- its overlay and half of it writes straight through.
--
-- A host with both hooks and a log of what they were handed, in order. `intercept`
-- is what interceptWrite answers -- true stands for "this write was redirected".
local function hookedHost(intercept)
    local log = {}
    local h = setmetatable({ hooks = {
        L = L,
        interceptWrite = function(db, key, value)
            log[#log + 1] = { "interceptWrite", db, key, value }
            return intercept and true or false
        end,
        onSettingWritten = function(db, key, value)
            log[#log + 1] = { "onSettingWritten", db, key, value }
        end,
    } }, { __index = UI })
    return h, log
end

-- A PLAIN write: both hooks fire, in order, and everything else happens as before.
do
    local h, log = hookedHost(false)
    local db, seen = { on = false }, {}
    local row = place(h:CreatePopoutRow(FakeUIFrame(), {
        label = "Hooked", db = db, toggle = { key = "on" },
        onToggle = function(v) seen[#seen + 1] = v end,
        summary = function() return "on" end,
        build = counting("hookplain", 40), window = window(),
    }))
    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    eq(db.on, true, "hooks: a write nobody redirected still lands in the db")
    eq(#log, 2, "hooks: both hooks were consulted, once each")
    eq(log[1][1], "interceptWrite", "hooks: the intercept is asked FIRST -- before the value is written")
    eq(log[2][1], "onSettingWritten", "hooks: ...and the record is made after it landed")
    check(log[1][2] == db, "hooks: the hook is handed the RESOLVED db table")
    eq(log[1][3], "on", "hooks: ...the key")
    eq(log[1][4], true, "hooks: ...and the value being written")
    check(log[2][2] == db, "hooks: onSettingWritten sees the same table")
    eq(log[2][4], true, "hooks: ...and the value that landed")
    eq(seen[1], true, "hooks: onToggle fired with the new value")
    eq(row.summary:GetText(), "on", "hooks: and the row refreshed off the db")
end

-- An INTERCEPTED write: the live table is untouched, nothing is recorded, and the
-- tick goes back to the live value. onToggle does NOT fire -- the same decision
-- the slider and the dropdown make (both return before their callback), because
-- there is no new live value for a consumer to act on.
do
    local h, log = hookedHost(true)
    local db, seen = { on = false }, {}
    local row = place(h:CreatePopoutRow(FakeUIFrame(), {
        label = "Redirected", db = db, toggle = { key = "on" },
        onToggle = function(v) seen[#seen + 1] = v end,
        summary = function() return "on" end,
        build = counting("hookintercept", 40), window = window(),
    }))
    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    eq(db.on, false, "intercept: the redirected write never touched the live table")
    eq(#log, 1, "intercept: and no override was recorded for a write that did not land")
    eq(log[1][1], "interceptWrite", "intercept: the intercept is the only hook that ran")
    eq(#seen, 0, "intercept: onToggle did NOT fire -- the live value did not change")
    check(row.checkButton:GetChecked() == false, "intercept: the tick re-read the live value and went back")
    eq(row.summary:GetText(), "Off", "intercept: ...and the row still reads off")
end

-- A HOOKLESS host -- the demo, DandersMover, anything that never declared these
-- -- writes exactly as it did before. host:Call answers nil for a missing hook,
-- so the intercept branch can never be taken.
do
    local db, seen = { on = false }, {}
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Hookless", db = db, toggle = { key = "on" },
        onToggle = function(v) seen[#seen + 1] = v end,
        summary = function() return "on" end,
        build = counting("hookless", 40), window = window(),
    }))
    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    eq(db.on, true, "hookless: a host with no setting hooks writes the db as before")
    eq(seen[1], true, "hookless: ...and onToggle fires as before")
    eq(row.summary:GetText(), "on", "hookless: ...and the row refreshed as before")
end

-- A {get, set} toggle is the CONSUMER'S write path, so the hooks are not its
-- business -- an intercept that would have swallowed a db write does not touch it.
do
    local h, log = hookedHost(true)
    local stored = false
    local row = place(h:CreatePopoutRow(FakeUIFrame(), {
        label = "Custom hooked", db = {},
        toggle = { get = function() return stored end, set = function(v) stored = v end },
        summary = function() return "custom" end,
        build = counting("hookgetset", 40), window = window(),
    }))
    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    eq(stored, true, "get/set hooks: the consumer's own setter took the write")
    eq(#log, 0, "get/set hooks: ...and the setting hooks were never consulted")
end

-- The POPOUT HEADER'S tick goes through the same hooked path, because it goes
-- through the same _Write. Section 5 proves the two ticks agree about the db;
-- this proves they agree about who gets TOLD.
do
    local h, log = hookedHost(false)
    local db, win = { on = false }, window()
    local row = place(h:CreatePopoutRow(FakeUIFrame(), {
        label = "Header hooked", db = db, toggle = { key = "on" },
        summary = function() return "on" end,
        count = 1, build = counting("hookheader", 40, 1), window = win,
    }))
    row:OpenPopout()
    local po = row.popout
    po._hdrToggle:SetChecked(true)
    po._hdrToggle:GetScript("OnClick")(po._hdrToggle)
    eq(db.on, true, "header hooks: the header's tick wrote the db")
    eq(#log, 2, "header hooks: through the SAME bracketed write path as the row's")
    eq(log[1][1], "interceptWrite", "header hooks: intercept first")
    eq(log[2][1], "onSettingWritten", "header hooks: ...record after")
    eq(log[1][3], "on", "header hooks: on the row's own key")
    row:ClosePopout()
end

-- ============================================================
-- 6. ONE PANEL ACROSS ROWS
-- The point of the whole widget: clicking another row does not open another
-- panel, it moves the one that is up -- and the shell GLIDES it across, because
-- a panel that vanishes here and reappears there reads as a different panel.
-- ============================================================
do
    local win = window()
    local function mk(name, dy, h, controls)
        return place(host:CreatePopoutRow(FakeUIFrame(), {
            label = name, db = { on = true }, toggle = { key = "on" },
            summary = function() return name end,
            count = controls, build = counting(name, h, controls), window = win,
        }), dy)
    end
    local a, b = mk("A", 100, 60, 1), mk("B", -100, 90, 2)

    a:OpenPopout()
    local po = a.popout
    eq(builds.A, 1, "one panel: row A built its pane")
    eq(builds.B, nil, "one panel: row B has built nothing yet")
    local paneA = po._rowPanes[a]
    check(paneA.host:IsShown(), "one panel: A's pane is up")

    b:OpenPopout()
    check(b.popout == po, "one panel: row B got the SAME pooled instance")
    check(po.gliding, "one panel: which glided across rather than teleporting")
    eq(builds.A, 1, "one panel: A's pane was not rebuilt")
    eq(builds.B, 1, "one panel: B's was built once")
    local paneB = po._rowPanes[b]
    check(not paneA.host:IsShown(), "one panel: A's content went down")
    check(paneB.host:IsShown(), "one panel: B's came up")
    eq(po.content:GetHeight(), 90, "one panel: and the popout resized to B's pane")
    eq(po.titleFS:GetText(), "B", "one panel: the header re-read the bound row")
    eq(po._hdrBadge:GetText(), "2", "one panel: ...including its count")
    eq(po._boundRow, b, "one panel: the instance is bound to B")
    eq(a.popout, po, "one panel: A still points at the instance it handed on")

    -- Back to A: its pane is cached, so nothing is rebuilt.
    a:OpenPopout()
    eq(builds.A, 1, "one panel: going back to A reuses its cached pane")
    check(paneA.host:IsShown() and not paneB.host:IsShown(), "one panel: and swaps the two back")
    eq(po.content:GetHeight(), 60, "one panel: the popout resized back down")
    a:ClosePopout()
end

-- ============================================================
-- 7. PINNING
-- A pinned instance leaves the pool with the pinned row's content showing; the
-- next row click gets a fresh instance and a fresh cache, and the two coexist.
-- ============================================================
do
    local win = window()
    local function mk(name, dy)
        return place(host:CreatePopoutRow(FakeUIFrame(), {
            label = name, db = { on = true }, toggle = { key = "on" },
            summary = function() return name end,
            build = counting("pin" .. name, 50), window = win,
        }), dy)
    end
    local a, b = mk("PA", 100), mk("PB", -100)

    a:OpenPopout()
    local pinned = a.popout
    pinned:Pin()
    check(pinned:IsPinned(), "pin: A's panel is pinned")
    check(pinned._rowPanes[a].host:IsShown(), "pin: with A's content still showing")

    b:OpenPopout()
    check(b.popout ~= pinned, "pin: row B got a NEW instance")
    check(not pinned.closed, "pin: and the pinned one lives on")
    eq(builds.pinPA, 1, "pin: A's pane was built once")
    eq(pinned._rowPanes[b], nil, "pin: the pinned instance never learned about B")

    -- Toggle sync still works through a pinned panel: the row kept the ref.
    check(pinned._hdrToggle:GetChecked() == true, "pin: the pinned header still matches A")
    a.checkButton:SetChecked(false)
    a.checkButton:GetScript("OnClick")(a.checkButton)
    check(pinned._hdrToggle:GetChecked() == false, "pin: and follows A's tick")

    -- The page-switch verb takes the shared panel and leaves the pinned one.
    host:CloseUnpinnedPopoutRows("page")
    check(b.popout == nil, "close: CloseUnpinnedPopoutRows closed the shared panel")
    check(not pinned.closed, "close: ...and left the pinned one alone")

    -- The window-close verb takes everything.
    b:OpenPopout()
    check(b.popout ~= nil, "close: a fresh shared panel opened")
    host:CloseAllPopoutRows("window")
    check(pinned.closed, "close: CloseAllPopoutRows closed the pinned panel")
    check(b.popout == nil, "close: ...and the shared one")
    check(a.popout == nil, "close: both rows forgot theirs")

    -- Idempotent: a second sweep with nothing open must not error.
    host:CloseAllPopoutRows("window")
    check(true, "close: sweeping an empty store is a no-op")
end

-- ============================================================
-- 8. THE COUNT CHECK
-- The badge is a claim about how much is inside, and a claim nobody verifies
-- goes stale the first time a control is added. Checked ONCE, on the build that
-- can answer it -- never by building the pane a second time to count it.
-- ============================================================
do
    local win = window()
    local before = #dbgLog
    local wrong = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Wrong", db = {}, count = 3,
        build = counting("countwrong", 50, 2), window = win,
    }), 60)
    wrong:OpenPopout()
    eq(#dbgLog, before + 1, "count: a mismatch reached the debug hook")
    eq(dbgLog[#dbgLog].cat, "popoutrow", "count: under its own category")
    check(dbgLog[#dbgLog].msg:find("Wrong"), "count: naming the row")
    check(dbgLog[#dbgLog].msg:find("3") and dbgLog[#dbgLog].msg:find("2"),
        "count: with both numbers in it")

    -- Re-opening the same row does NOT re-check: the pane is cached, and a
    -- second report of the same mismatch is noise.
    local after = #dbgLog
    wrong:ClosePopout()
    wrong:OpenPopout()
    eq(#dbgLog, after, "count: a cached pane is not re-counted")

    local right = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Right", db = {}, count = 2,
        build = counting("countright", 50, 2), window = win,
    }), -60)
    right:OpenPopout()
    eq(#dbgLog, after, "count: a matching count says nothing at all")
    host:CloseAllPopoutRows()

    -- No declared count, no check -- and no badge text either.
    local none = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "None", db = {}, build = counting("countnone", 50, 5), window = win,
    }), 20)
    none:OpenPopout()
    eq(#dbgLog, after, "count: an undeclared count is not a mismatch")
    eq(none.badge:GetText(), "", "count: and draws no badge")
    host:CloseAllPopoutRows()
end

-- ============================================================
-- 9. ACCENT
-- A per-row accent has to reach the panel that row has open, or a coloured row
-- and its own popout disagree about what colour the feature is.
-- ============================================================
do
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Tinted", db = {}, build = counting("accent", 50), window = win,
    }))
    row:OpenPopout()
    local po = row.popout
    eq(po.frame._panelOpts.borderColor.r, ACCENT.r, "accent: with no override it is the host accent")

    row:SetAccent({ 1, 0.5, 0 })
    eq(po.frame._panelOpts.borderColor.r, 1, "accent: SetAccent re-tints the OPEN popout")
    eq(po.frame._panelOpts.borderColor.g, 0.5, "accent: ...on every channel")
    eq(po.notch._vertex.r, 1, "accent: the connection point went with it")
    eq(po.srcOutline._pxColor[1], 1, "accent: and so did the source outline")
    eq(row.badge._textColor.r, 1, "accent: the row's own badge took the tint too")

    row:SetAccent(nil)
    eq(po.frame._panelOpts.borderColor.r, ACCENT.r, "accent: clearing it hands the popout back to the host")
    row:ClosePopout()

    -- A build-time accent is carried into the popout the row opens.
    local red = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Red", db = {}, accent = { 0.9, 0.2, 0.2 },
        build = counting("accentopt", 50), window = win,
    }), -60)
    red:OpenPopout()
    eq(red.popout.frame._panelOpts.borderColor.r, 0.9, "accent: opts.accent reaches the popout")
    red:ClosePopout()
end

-- ============================================================
-- 10. THE HEIGHT CAP
-- A group with thirty controls would open a panel taller than the monitor, and
-- a panel whose top and bottom are both off-screen can be neither read nor
-- dismissed. Past 60% of the screen it scrolls instead.
-- ============================================================
do
    local win = window()
    local cap = UIParent:GetHeight() * 0.6          -- 648 on the shim's 1080
    local short = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Short", db = {}, build = counting("capshort", 100), window = win,
    }), 60)
    short:OpenPopout()
    local rec = short.popout._rowPanes[short]
    eq(rec.host, rec.pane, "cap: a pane under the cap is mounted straight, no scroll region")
    eq(short.popout.content:GetHeight(), 100, "cap: at its own height")
    short:ClosePopout()

    local tall = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Tall", db = {}, build = counting("captall", 2000), window = win,
    }), -60)
    tall:OpenPopout()
    local trec = tall.popout._rowPanes[tall]
    check(trec.scroll ~= nil, "cap: a pane over the cap gets a scroll region")
    eq(trec.host, trec.scroll, "cap: which is what gets shown and measured")
    eq(trec.host:GetHeight(), cap, "cap: sized to the cap")
    eq(trec.pane:GetHeight(), 2000, "cap: while the pane keeps its full height inside it")
    eq(tall.popout.content:GetHeight(), cap, "cap: so the popout stops at the cap")
    check(trec.scroll._styledScrollBar, "cap: and its scrollbar wears the kit's style")
    tall:ClosePopout()
end

-- ============================================================
-- 11. THE SHELL'S HEADER CONTROLS
-- The generic half, head-on: the shell anchors what a consumer hands back and
-- squeezes the title between them -- and a popout that asks for none is laid
-- out exactly as it always was.
-- ============================================================
do
    local plain = host:CreatePopout({ key = "hdrnone", width = 100,
                                      build = function(_, c) c:SetHeight(20) end })
    eq(plain.headerLeft, nil, "header: no builder, no controls")
    eq(#plain.titleFS._points, 2, "header: and the title keeps its two original anchors")
    eq(plain.titleFS._points[1][2], plain.iconTex, "header: LEFT off the icon")
    eq(plain.titleFS._points[2][2], plain.pinBtn, "header: RIGHT off the pin button")
    plain:Close()

    local left, right = FakeUIFrame(10, 10), FakeUIFrame(10, 10)
    local calls = 0
    local both = host:CreatePopout({ key = "hdrboth", width = 100,
        build = function(_, c) c:SetHeight(20) end,
        headerControls = function(po, bar)
            calls = calls + 1
            po._bar = bar
            return left, right
        end })
    eq(calls, 1, "header: the builder ran once")
    eq(both._bar, both.titleBar, "header: it was handed the title bar")
    eq(both.headerLeft, left, "header: the left control is recorded")
    eq(both.headerRight, right, "header: so is the right one")
    eq(left._points[1][1], "LEFT", "header: left anchors where the icon and title start")
    eq(left._points[1][2], both.iconTex, "header: ...off the icon")
    eq(right._points[1][1], "RIGHT", "header: right anchors inboard of the button cluster")
    eq(right._points[1][2], both.pinBtn, "header: ...off the pin button")
    local tl, tr = both.titleFS._points[1], both.titleFS._points[2]
    eq(tl[2], left, "header: and the title squeezes in after the left control")
    eq(tr[2], right, "header: ...and before the right one")

    -- ONCE per instance: a pooled hit re-targets, it does not rebuild.
    local again = host:CreatePopout({ key = "hdrboth", width = 100,
        build = function(_, c) c:SetHeight(20) end,
        headerControls = function() calls = calls + 1 end })
    check(again == both, "header: the pooled instance came back")
    eq(calls, 1, "header: and its header controls were not rebuilt")
    both:Close()

    -- Either side alone still lays out.
    local only = host:CreatePopout({ key = "hdrone", width = 100,
        build = function(_, c) c:SetHeight(20) end,
        headerControls = function() return nil, FakeUIFrame(10, 10) end })
    eq(only.headerLeft, nil, "header: a nil left is allowed")
    eq(only.titleFS._points[1][2], only.iconTex, "header: the title falls back to the icon")
    eq(only.titleFS._points[2][2], only.headerRight, "header: and still stops at the right control")
    only:Close()
end

-- ============================================================
-- 12. Popout:SetAccent, head-on
-- The live re-tint the row's SetAccent rides on. adopt() paints at OPEN time;
-- this is the only way to repaint one that is already up.
-- ============================================================
do
    local src = FakeUIFrame(80, 40, CX, CY)
    src:Show()
    local p = host:CreatePopout({ key = "setaccent", width = 100,
                                  build = function(_, c) c:SetHeight(20) end })
    p:Follow(src)
    eq(p.frame._panelOpts.borderColor.r, ACCENT.r, "setaccent: it opened in the host accent")
    p:SetAccent({ r = 0.2, g = 0.8, b = 0.4 })
    eq(p:GetAccent().g, 0.8, "setaccent: GetAccent answers the override")
    eq(p.frame._panelOpts.borderColor.g, 0.8, "setaccent: the border repainted")
    eq(p.notch._vertex.g, 0.8, "setaccent: so did the connection point")
    eq(p.srcOutline._pxColor[2], 0.8, "setaccent: and the source outline, though its target never changed")
    eq(p.beam.core._color.g, 0.8, "setaccent: the beam too")
    p:SetAccent(nil)
    eq(p:GetAccent().r, ACCENT.r, "setaccent: nil hands it back to the host")
    eq(p.frame._panelOpts.borderColor.r, ACCENT.r, "setaccent: ...and repaints on the way")
    p:Close()
end

-- ============================================================
-- 13. WHAT THE ROW TELLS THE SHELL ABOUT ITSELF
-- The shell knows nothing about rows, so everything it needs to draw the
-- connected chrome correctly has to be declared BY the row: which part of its
-- slot is actually painted, and what really clips it.
-- ============================================================
do
    local win, view = window(), window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Inked", db = {}, build = counting("ink", 50),
        window = win, clipTo = view,
    }))

    -- The row's frame is its whole layout SLOT; the bottom RowGap of it is the
    -- gap to the next row and nothing paints there. Without this the source
    -- outline was drawn a clear RowGap taller than the plate it was lighting.
    local ins = row.popoutInset
    eq(type(ins), "table", "ink: the row declares which part of its slot is drawn")
    eq(ins[4], M.gap, "ink: the bottom trim is exactly the slot's gap to the next row")
    eq((ins[1] or 0) + (ins[2] or 0) + (ins[3] or 0), 0,
        "ink: and nothing else is trimmed -- the plate is flush with the slot otherwise")
    eq(row:GetHeight() - ins[4], PLATE_H, "ink: so what is left is the plate")

    row:OpenPopout()
    local po = row.popout
    eq(po.outsideOf, win, "ink: the row hands the shell the window it stands outside of")
    eq(po.clipTo, view, "ink: ...and, separately, the thing that really clips it")

    -- The stub resolves no anchors, so the outline's offsets are the claim.
    local tl, br = po.srcOutline._points[1], po.srcOutline._points[2]
    eq(tl[5], 0, "ink: the outline's top is the row's own top")
    eq(br[5], M.gap, "ink: and its bottom lifts clear of the slot's gap")
    row:ClosePopout()

    -- No clipTo declared: the shell falls back to the window rather than losing
    -- the gate outright.
    local bare = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Bare", db = {}, build = counting("inkbare", 50), window = win,
    }), -80)
    bare:OpenPopout()
    eq(bare.popout.clipTo, nil, "ink: a row with no clipper declares none")
    check(not bare.popout:_TetherClipped(), "ink: ...and the window still gates it")
    bare:ClosePopout()
end

-- ============================================================
-- 14. THE COLUMNS LINE UP
-- A stack of these rows has to read as a TABLE: the chevron, the count and the
-- gear in the same place on every row, and the summaries right-aligned with one
-- another. They did not -- the badge sized itself to its text and the gear and
-- summary were anchored off its left edge, so a "3" row and a "14" row put both
-- 6px apart.
--
-- The stub resolves no anchors, so "the same place" is asked of the recorded
-- anchor chain instead: resolve each column's RIGHT edge as an offset from the
-- plate's, and two rows carrying different counts must answer identically.
--
-- ⚠ WHICH HALF OF THIS ACTUALLY BITES. The stub's FontStrings never auto-size,
-- so under the OLD layout both rows resolved to the same (wrong) x and the
-- two-row comparison passed regardless -- it is documentation of the rule, not a
-- guard on it. The guard is the block of literal positions after it: those pin
-- the gear and the summary to the badge COLUMN's width rather than to whatever
-- its text measured, which is the thing that was broken. Verified by reverting
-- the fix: the three literals fail, the comparisons do not.
--
-- The column now starts a PAD in from the plate's edge rather than flush with
-- it, so every offset below carries M.padX -- the chevron no longer hugs an edge
-- the plate has grown a border on.
-- ============================================================
local CHEV_SIZE, GEAR_SIZE, GAP, BADGE_W = M.chevron, M.gear, M.colGap, M.badgeW
local PAD_X = M.padX

local function rightEdgeFrom(region, plate)
    if region == plate then return 0 end
    for _, pt in ipairs(region._points) do
        local point, rel, relPoint, x = pt[1], pt[2], pt[3], pt[4] or 0
        if point == "RIGHT" then
            local base = rightEdgeFrom(rel, plate)
            -- Anchored to the neighbour's LEFT edge: step back across its width.
            if relPoint == "LEFT" then base = base - (rel:GetWidth() or 0) end
            return base + x
        end
    end
end

do
    local win = window()
    local function counted(n)
        return place(host:CreatePopoutRow(FakeUIFrame(), {
            label = "Row " .. n, db = { on = true }, toggle = { key = "on" },
            summary = function() return "a summary of some length" end,
            count = n, build = counting("cols" .. n, 50), window = win,
        }))
    end
    local few, many = counted(3), counted(14)
    eq(few.badge:GetText(), "3", "cols: the two rows really are carrying different counts")
    eq(many.badge:GetText(), "14", "cols: ...one of them twice as wide as the other in text")

    -- The badge is a fixed COLUMN, not a box that grows with its number. This is
    -- the one that caused the rest -- and it is the PILL that is sized now, with
    -- the number laid out inside it, so the box cannot move with what it says.
    eq(few.badgePill:GetWidth(), BADGE_W, "cols: the badge pill is a fixed-width column")
    eq(many.badgePill:GetWidth(), few.badgePill:GetWidth(), "cols: the same width whatever it says")

    for _, part in ipairs({ "chevron", "badgePill", "badge", "gear", "summary" }) do
        local a = rightEdgeFrom(few[part], few.plate)
        local b = rightEdgeFrom(many[part], many.plate)
        check(a ~= nil, "cols: " .. part .. " resolves to the plate's right edge")
        eq(b, a, "cols: " .. part .. " sits at the same x on both rows")
    end

    -- ...and where those columns actually are, so a change to one of the four
    -- constants is a deliberate one rather than a silent drift.
    local p = few.plate
    eq(rightEdgeFrom(few.chevron, p), -PAD_X, "cols: the chevron sits a pad in from the plate's right edge")
    eq(rightEdgeFrom(few.badgePill, p), -(PAD_X + CHEV_SIZE + GAP), "cols: the badge column ends a gap inboard of it")
    eq(rightEdgeFrom(few.badge, p), rightEdgeFrom(few.badgePill, p),
        "cols: the number rides the pill's own right edge rather than its own text")
    eq(rightEdgeFrom(few.gear, p), -(PAD_X + CHEV_SIZE + GAP + BADGE_W + GAP),
        "cols: the gear a gap inboard of the badge COLUMN, not of its text")
    eq(rightEdgeFrom(few.summary, p), -(PAD_X + CHEV_SIZE + GAP + BADGE_W + GAP + GEAR_SIZE + GAP),
        "cols: and the summary right-aligns a gap inboard of the gear")

    -- The other end of the row: the tick is a pad in, and the label is a
    -- generous gap off the tick rather than the column gap -- that pair is the
    -- row's subject, the four columns above are its detail.
    local cbPt = few.checkButton._points[1]
    eq(cbPt[1], "LEFT", "cols: the toggle anchors LEFT, so it centres on the plate's midline")
    eq(cbPt[4], PAD_X, "cols: ...a pad in from the plate's left edge")
    -- The LABEL column is a constant off the plate, not a hop off the tick: see
    -- the toggle-less row below for the case that forces it.
    local lblPt = few.label._points[1]
    eq(lblPt[2], few.plate, "cols: the label anchors to the plate, like every other column")
    eq(lblPt[4], PAD_X + M.check + M.labelGap,
        "cols: past the tick's reserved column, at the label gap")
    check(M.labelGap > M.colGap, "cols: ...and that really is the wider of the two")
end

-- A row with NO toggle RESERVES the tick's column anyway, so a band carrying
-- both kinds -- a feature you switch on, and a group that is only a way in --
-- has ONE label position rather than two 26px apart.
--
-- The same rule the badge pill already follows at the other end of the row: no
-- count, no pill, but the gear still hangs off the pill's rect.
do
    local win = window()
    local function row(opts)
        opts.db, opts.window = {}, win
        return place(host:CreatePopoutRow(FakeUIFrame(), opts))
    end
    local bare   = row({ label = "Untoggled", build = counting("notoggle", 40) })
    local ticked = row({ label = "Toggled", toggle = { key = "on" },
                         build = counting("hastoggle", 40) })

    -- rawget: `checkButton` is not underscore-prefixed, so the stub's method
    -- fallback answers a function for it; the claim is that the factory never
    -- wrote one.
    eq(rawget(bare, "checkButton"), nil, "cols: the untoggled row really has no tick")
    check(rawget(ticked, "checkButton") ~= nil, "cols: ...and the other one does")

    local barePt, tickPt = bare.label._points[1], ticked.label._points[1]
    eq(barePt[2], bare.plate, "cols: the untoggled label anchors to the plate")
    eq(barePt[4], PAD_X + M.check + M.labelGap,
        "cols: ...at the tick's column width, tick or no tick")
    eq(barePt[4], tickPt[4], "cols: which is exactly where the toggled row's label starts")

    -- ...and the row still reads as ON, with no off word and no gate to trip.
    bare.Refresh()
    check(bare._toggledOn, "cols: a row with nothing to switch is never switched off")
end

-- ============================================================
-- 15. THE ACCENT CASCADES INTO THE PANEL'S CONTENTS
-- SetAccent repainted the CHROME -- border, point, beam, outline -- and stopped
-- there, so switching a row's colour under an open panel left a purple-bordered
-- box full of orange sliders. The widgets never read the popout's colour: they
-- were built against the host accent and registered on their parent's
-- ThemeListeners, so the popout has to walk its own tree and repaint them.
-- ============================================================
-- Read one channel off a colour that may not have arrived at all. A bare
-- `seen.r` on a regression ERRORS, which aborts the shared runner and takes
-- every later test with it; this reports a plain failure instead.
local function chan(c, k) return (type(c) == "table") and c[k] or nil end

do
    local win = window()
    local seen, calls = nil, 0
    -- Stands in for a kit widget mounted in the pane. ApplyThemeColor is the
    -- kit's published "tint to THIS colour" entry point -- the one the cascade
    -- drives, and the only one that can safely take a colour (UpdateTheme has
    -- colon call sites in the wild). This one just records what it was handed.
    local widget = { ApplyThemeColor = function(c) seen = c; calls = calls + 1 end }

    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Cascade", db = {}, window = win,
        build = function(_, pane)
            pane.ThemeListeners = { widget }
            pane:SetHeight(50)
        end,
    }))
    row:OpenPopout()
    local po = row.popout
    check(calls > 0, "cascade: opening the panel repaints the widgets inside it")
    eq(chan(seen, "r"), ACCENT.r, "cascade: in the host accent, since this row has none of its own")

    -- The live path: the row's colour changes under an OPEN panel.
    row:SetAccent({ 1, 0.5, 0 })
    eq(po.frame._panelOpts.borderColor.r, 1, "cascade: the chrome took the new colour, as before")
    eq(chan(seen, "r"), 1, "cascade: ...and so did the widget mounted in the content")
    eq(chan(seen, "g"), 0.5, "cascade: on every channel")

    -- The TITLE BAR is not a child of the content, so a cascade rooted there
    -- would leave the panel's own toggle in the colour everything else had left.
    eq(chan(po._hdrToggle._tint, "r"), 1, "cascade: the header toggle re-tints too -- the walk starts at the frame")

    row:SetAccent(nil)
    eq(chan(seen, "r"), ACCENT.r, "cascade: clearing the override hands the content back to the host accent")
    eq(chan(po._hdrToggle._tint, "r"), ACCENT.r, "cascade: header included")
    row:ClosePopout()
end

-- Popout:SetAccent, head-on: the same cascade without a row driving it, and the
-- claim that a widget's colour follows the POPOUT rather than the host.
do
    local src = FakeUIFrame(80, 40, CX, CY)
    src:Show()
    local seen
    -- ☠ A listener that publishes only UpdateTheme must be LEFT ALONE. UpdateTheme
    -- means "repaint to the host accent" and cannot be made to take a colour --
    -- call sites in the wild reach it through COLON syntax
    -- (`slider:UpdateTheme()`), which would fill that parameter with the widget
    -- table and paint every channel nil. This is the guard on that rule.
    local updateOnly = 0
    local p = host:CreatePopout({ key = "cascadebare", width = 100,
        build = function(_, c)
            c.ThemeListeners = {
                { ApplyThemeColor = function(col) seen = col end },
                { UpdateTheme = function() updateOnly = updateOnly + 1 end },
            }
            c:SetHeight(20)
        end })
    p:Follow(src)
    eq(chan(seen, "r"), ACCENT.r, "cascade: a plain popout builds its content in the host accent")
    p:SetAccent({ r = 0.2, g = 0.8, b = 0.4 })
    eq(chan(seen, "g"), 0.8, "cascade: SetAccent on the popout alone reaches the content")
    eq(chan(seen, "r"), 0.2, "cascade: ...without anyone touching the host accent")
    eq(host:GetAccent().r, ACCENT.r, "cascade: which is untouched, as it must be")
    eq(updateOnly, 0, "cascade: and it never drives UpdateTheme, which cannot take a colour")
    p:Close()
end

-- ============================================================
-- 16. THE OFF GATE
-- A feature switched off has a popout full of controls that do nothing, and a
-- live control that does nothing is a lie. So the row's toggle greys its own
-- pane -- and, crucially, NOT the header tick that is the way back on.
--
-- ⚠ EVERY frame this file's CreateFrame makes carries FakeUIFrame's SetEnabled /
-- IsEnabled, so the "mounted widget" path is the default one here and the
-- no-SetEnabled fallback has to be built by hand (see the decoration block).
-- ============================================================

-- A pane build that mounts `n` widgets and hands them back, so a test can drive
-- and read the same objects the gate is walking.
local function mounting(bag, n, h)
    return function(_, pane)
        for i = 1, (n or 1) do bag[i] = CreateFrame("Frame", nil, pane) end
        pane:SetHeight(h or 60)
    end
end

-- The gate greys a pane built for a row that is ALREADY off, and lifts it live.
do
    local win, bag = window(), {}
    local db = { on = false }
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Gated", db = db, toggle = { key = "on" },
        summary = function() return "live" end,
        build = mounting(bag, 3), window = win,
    }))
    row:OpenPopout()
    local po = row.popout
    check(bag[1]:IsEnabled() == false, "gate: a pane built for an off row comes up already dead")
    check(bag[2]:IsEnabled() == false and bag[3]:IsEnabled() == false, "gate: ...every widget in it")
    check(po._rowPanes[row].gateShut, "gate: and the record says so")

    -- The header tick is the way back on, so it must never grey with the group.
    check(po._hdrToggle:IsEnabled(), "gate: the popout's own toggle stays enabled")
    check(po.closeBtn:IsEnabled(), "gate: the cross too")
    check(po.pinBtn:IsEnabled(), "gate: and the pin")

    -- Live, from the ROW's tick.
    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    check(bag[1]:IsEnabled(), "gate: the row's tick lifted the gate on the open pane")
    check(not po._rowPanes[row].gateShut, "gate: ...and cleared the record")

    -- Live, from the HEADER's tick -- the same write path, so the same grey.
    po._hdrToggle:SetChecked(false)
    po._hdrToggle:GetScript("OnClick")(po._hdrToggle)
    check(bag[1]:IsEnabled() == false, "gate: the header's tick shuts it too")
    check(po._hdrToggle:IsEnabled(), "gate: and still does not grey itself")
    row:ClosePopout()
end

-- A row that is ON builds a live pane, and nothing is touched.
do
    local win, bag = window(), {}
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Open", db = { on = true }, toggle = { key = "on" },
        summary = function() return "live" end,
        build = mounting(bag, 2), window = win,
    }))
    row:OpenPopout()
    check(bag[1]:IsEnabled() and bag[2]:IsEnabled(), "gate: an on row's pane is live")
    check(row.popout._rowPanes[row].gateShut == false, "gate: with the gate recorded open")
    row:ClosePopout()
end

-- ☠ THE ONE THAT MATTERS. A widget may carry its OWN gating, and a gate that
-- enabled everything on the way out would resurrect a control that logic had
-- disabled. The gate hands back exactly what it took.
do
    local win, bag = window(), {}
    local db = { on = true }
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Own gate", db = db, toggle = { key = "on" },
        summary = function() return "live" end,
        build = mounting(bag, 2), window = win,
    }))
    row:OpenPopout()

    -- Widget 2 is disabled by its own logic BEFORE the gate ever closes.
    bag[2]:SetEnabled(false)
    check(bag[1]:IsEnabled() and bag[2]:IsEnabled() == false, "gate: a widget disabled itself")

    db.on = false
    row.Refresh()
    check(bag[1]:IsEnabled() == false, "gate: shutting takes the live one down")
    check(bag[2]:IsEnabled() == false, "gate: ...and the already-dead one stays down")

    db.on = true
    row.Refresh()
    check(bag[1]:IsEnabled(), "gate: opening restores the one the gate took")
    check(bag[2]:IsEnabled() == false, "gate: and does NOT resurrect the one it never took")

    -- The reverse: a widget's own logic re-enables it WHILE the gate is shut.
    -- The call is recorded, not applied -- the group is dead until the toggle
    -- says otherwise -- and replayed when the gate opens.
    db.on = false
    row.Refresh()
    bag[2]:SetEnabled(true)
    check(bag[2]:IsEnabled() == false, "gate: a SetEnabled under a shut gate does not light the widget")
    db.on = true
    row.Refresh()
    check(bag[2]:IsEnabled(), "gate: ...and lands the moment the gate opens")
    row:ClosePopout()
end

-- Opening the gate hands the pane back to whoever wired it, because gating that
-- changed while the gate was shut never reached a SetEnabled call to record.
do
    local win, bag = window(), {}
    local db, rewires = { on = true }, 0
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Rewired", db = db, toggle = { key = "on" },
        summary = function() return "live" end,
        window = win,
        build = function(po, pane)
            bag[1] = CreateFrame("Frame", nil, pane)
            pane.RefreshChildStates = function() rewires = rewires + 1 end
            pane:SetHeight(50)
        end,
    }))
    row:OpenPopout()
    eq(rewires, 0, "gate: building a live pane rewires nothing")
    db.on = false
    row.Refresh()
    eq(rewires, 0, "gate: nor does shutting it -- the gate owns the state until it opens")
    db.on = true
    row.Refresh()
    eq(rewires, 1, "gate: opening it re-runs the consumer's own child-state pass")
    row:ClosePopout()
end

-- A widget with no SetEnabled at all -- a note, a separator -- is dimmed to the
-- same depth instead, and handed back the alpha and mouse state it had.
do
    local win = window()
    local db = { on = true }
    local deco = { _alpha = 1, _mouse = true }
    function deco:SetAlpha(v) self._alpha = v end
    function deco:GetAlpha() return self._alpha end
    function deco:EnableMouse(v) self._mouse = v and true or false end
    function deco:IsMouseEnabled() return self._mouse end

    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Deco", db = db, toggle = { key = "on" },
        summary = function() return "live" end,
        window = win,
        build = function(_, pane)
            -- Mounted by hand: the stub's frames all answer SetEnabled, so the
            -- fallback path cannot be reached with one.
            local kids = rawget(pane, "_children")
            if not kids then kids = {}; pane._children = kids end
            kids[#kids + 1] = deco
            pane:SetHeight(40)
        end,
    }))
    row:OpenPopout()
    eq(deco._alpha, 1, "gate: a live pane leaves decoration alone")

    db.on = false
    row.Refresh()
    eq(deco._alpha, 0.4, "gate: no SetEnabled means dimmed to the same 0.4 a disabled widget lands at")
    eq(deco._mouse, false, "gate: and the mouse comes off it")

    db.on = true
    row.Refresh()
    eq(deco._alpha, 1, "gate: opening hands the alpha back")
    eq(deco._mouse, true, "gate: and the mouse with it")
    row:ClosePopout()
end

-- DEPENDENT GREY IS A DIFFERENT MECHANISM. A row greyed by opts.enabled whose
-- own toggle is ON keeps its popout's controls live -- the control that would
-- satisfy the dependency is often one of them.
do
    local win, bag = window(), {}
    local db = { master = false, on = true }
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Dependent", db = db, toggle = { key = "on" },
        enabled = function(d) return d.master end,
        summary = function() return "ready" end,
        build = mounting(bag, 2), window = win,
    }))
    row:OpenPopout()
    eq(row:GetAlpha(), 0.4, "gate: the row really is dependent-greyed")
    check(bag[1]:IsEnabled() and bag[2]:IsEnabled(),
        "gate: ...but its popout's controls stay live -- dependent grey is not the toggle's gate")
    row:ClosePopout()
end

-- ONE PANEL, TWO ROWS: a cached pane whose row was toggled while another row was
-- showing greys on the way back in. A hidden pane takes no refresh of its own.
do
    local win = window()
    local bagA, bagB = {}, {}
    local dbA = { on = true }
    local function mk(name, dy, bag, db)
        return place(host:CreatePopoutRow(FakeUIFrame(), {
            label = name, db = db, toggle = { key = "on" },
            summary = function() return name end,
            build = mounting(bag, 2), window = win,
        }), dy)
    end
    local a = mk("GA", 100, bagA, dbA)
    local b = mk("GB", -100, bagB, { on = true })

    a:OpenPopout()
    check(bagA[1]:IsEnabled(), "gate/swap: A opened live")
    b:OpenPopout()                       -- A's pane is now cached and hidden
    dbA.on = false
    a.Refresh()                          -- A is not bound to the instance any more
    a:OpenPopout()
    check(bagA[1]:IsEnabled() == false, "gate/swap: swapping back to a row toggled off greys its cached pane")
    check(bagB[1]:IsEnabled(), "gate/swap: and B's pane was left alone")
    host:CloseAllPopoutRows()
end

-- ============================================================
-- 17. THE ACTIVE ROW
-- ONE panel serves a whole column, so the column has to say which row the panel
-- is currently about. Without it a user who has scrolled the list -- or glided
-- the panel three rows down -- is reading a set of controls with nothing on the
-- page tying them to the row they came from.
--
-- The statement is the accent, three ways: the plate's border, a wash inside it,
-- and the label that names it. ACTIVE is ANSWERED by walking the row's bound
-- instances rather than kept as a flag, so a pinned panel and the shared one can
-- both be claiming their own row at once.
-- ============================================================
do
    local win = window()
    local function mk(name, dy)
        return place(host:CreatePopoutRow(FakeUIFrame(), {
            label = name, db = { on = true }, toggle = { key = "on" },
            summary = function() return name end,
            count = 1, build = counting("act" .. name, 50, 1), window = win,
        }), dy)
    end
    local a, b = mk("AA", 100), mk("AB", -100)

    eq(a.plate._fill.r, UI.Colors.element.r, "active: a closed row is on the neutral fill")
    eq(a.label._textColor.r, C_TEXT.r, "active: with a plain label")

    a:OpenPopout()
    eq(a.plate._edge.r, ACCENT.r, "active: opening puts the accent on the plate's border")
    eq(a.plate._edge.a, M.activeBorder, "active: at full strength")
    eq(a.plate._fill.r, ACCENT.r, "active: and washes the inside with it")
    eq(a.plate._fill.a, M.activeFill, "active: ...as a WASH, not a fill")
    eq(a.label._textColor.r, ACCENT.r, "active: the label takes the tint too")

    -- Hovering must BRIGHTEN the wash, not swap it for the neutral hover: the
    -- cursor is over the row exactly when the user is reading which one is open.
    a:GetScript("OnEnter")()
    eq(a.plate._fill.r, ACCENT.r, "active: hovering an open row keeps the accent")
    eq(a.plate._fill.a, M.activeHover, "active: ...and brightens it")
    a:GetScript("OnLeave")()
    eq(a.plate._fill.a, M.activeFill, "active: leaving settles it back to the wash")

    -- ONE PANEL: a retarget has to repaint BOTH rows, or the column ends up with
    -- two rows claiming the same panel.
    b:OpenPopout()
    eq(b.plate._edge.r, ACCENT.r, "active: the row the panel glided to is active now")
    eq(a.plate._edge.r, UI.Colors.border.r, "active: and the one it left is back to the neutral border")
    eq(a.plate._fill.r, UI.Colors.element.r, "active: with its wash gone")
    eq(a.label._textColor.r, C_TEXT.r, "active: and its label back to plain")

    b:ClosePopout()
    eq(b.plate._edge.r, UI.Colors.border.r, "active: closing the panel clears the last row too")
    eq(b.label._textColor.r, C_TEXT.r, "active: label included")
end

-- OFF OUTRANKS ACTIVE on the label. A row whose feature is switched off has
-- nothing to be the subject of, open panel or not -- an accent label over a
-- dimmed summary would read as the opposite of what it is.
do
    local win, db = window(), { on = false }
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Dark", db = db, toggle = { key = "on" },
        summary = function() return "live" end,
        build = counting("actoff", 50), window = win,
    }))
    row:OpenPopout()
    eq(row.plate._edge.r, ACCENT.r, "active/off: the PLATE still says which row is open")
    eq(row.label._textColor.r, C_TEXT_DIM.r, "active/off: but the label stays dim, because the feature is")
    db.on = true
    row.Refresh()
    eq(row.label._textColor.r, ACCENT.r, "active/off: switching it on hands the label the accent")
    row:ClosePopout()
end

-- A PINNED panel keeps its own row active after the shared one has moved on.
-- This is why ACTIVE is answered from the bound set rather than kept as a flag:
-- two panels are up, and each is about a different row.
do
    local win = window()
    local function mk(name, dy)
        return place(host:CreatePopoutRow(FakeUIFrame(), {
            label = name, db = { on = true }, toggle = { key = "on" },
            summary = function() return name end,
            build = counting("actpin" .. name, 50), window = win,
        }), dy)
    end
    local a, b = mk("PinA", 100), mk("PinB", -100)

    a:OpenPopout()
    a.popout:Pin()
    b:OpenPopout()
    check(b.popout ~= a.popout, "active/pin: B really did get its own instance")
    eq(a.plate._edge.r, ACCENT.r, "active/pin: A stays active -- the pinned panel is still about it")
    eq(b.plate._edge.r, ACCENT.r, "active/pin: and B is active on the shared one")

    host:CloseAllPopoutRows("window")
    eq(a.plate._edge.r, UI.Colors.border.r, "active/pin: closing everything clears A")
    eq(b.plate._edge.r, UI.Colors.border.r, "active/pin: ...and B")
end

-- The accent is the ROW's, not the host's: re-tinting an open row has to repaint
-- the wash and the label as well as the popout's chrome.
do
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Retint", db = { on = true }, toggle = { key = "on" },
        summary = function() return "live" end,
        build = counting("actaccent", 50), window = win,
    }))
    row:OpenPopout()
    eq(row.plate._edge.r, ACCENT.r, "active/accent: it opened in the host accent")
    row:SetAccent({ 1, 0.5, 0 })
    eq(row.plate._edge.r, 1, "active/accent: SetAccent repaints the active border")
    eq(row.plate._fill.r, 1, "active/accent: the wash too")
    eq(row.label._textColor.g, 0.5, "active/accent: and the label, on every channel")
    row:ClosePopout()
    eq(row.plate._edge.r, UI.Colors.border.r, "active/accent: closing hands the plate back to the neutral border")
end

-- ============================================================
-- 18. A SETTINGS GROUP AS THE PANE'S CONTENT
-- The demo mounts loose widgets straight into the pane, and every rule above was
-- written against that. A real settings PAGE cannot: its group's AddWidget
-- RE-PARENTS each control into the group frame, so a pane built by a page hands
-- the gate ONE direct child -- the group -- and arming that child buys nothing.
-- A group has no SetEnabled, and EnableMouse(false) on a frame does NOT stop its
-- children taking input, so a "dead" pane would still be fully clickable and its
-- declared count would be measured against 1.
--
-- So a group is opened up: its groupChildren are the roster, and the group frame
-- itself is left off it -- which is why rewire has to reach the group's own
-- state pass separately.
-- ============================================================

-- A stand-in for CreateSettingsGroup's observable shape: the two markers the
-- roster keys off, a groupChildren list of { widget = ... } entries, and the
-- child-state pass the gate hands the pane back to.
local function fakeGroup(pane, n, bag, seen)
    local g = CreateFrame("Frame", nil, pane)
    g.isSettingsGroup = true
    g.groupChildren = {}
    for i = 1, n do
        -- Parented to the GROUP, exactly as AddWidget re-parents them, so the
        -- pane really does have one direct child.
        local w = CreateFrame("Frame", nil, g)
        bag[i] = w
        g.groupChildren[i] = { widget = w }
    end
    g.RefreshChildStates = function() seen.passes = seen.passes + 1 end
    return g
end

do
    local win, bag, seen = window(), {}, { passes = 0 }
    local db, group = { on = false }, nil
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Grouped", db = db, toggle = { key = "on" },
        summary = function() return "live" end,
        count = 3, window = win,
        build = function(_, pane)
            group = fakeGroup(pane, 3, bag, seen)
            pane:SetHeight(70)
        end,
    }))
    row:OpenPopout()
    local po = row.popout
    eq(po._rowPanes[row].pane:GetNumChildren(), 1,
        "group: the pane really does have ONE direct child")
    eq(#po._rowPanes[row].kids, 3, "group: ...and the roster is the three widgets inside it")

    -- The gate reaches the INNER widgets, which is the whole point.
    check(bag[1]:IsEnabled() == false, "group: a pane built for an off row greys the group's children")
    check(bag[2]:IsEnabled() == false and bag[3]:IsEnabled() == false, "group: ...every one of them")

    -- ...and leaves the group FRAME alone. Dimming it would double up on the
    -- children's own 0.4, and its mouse state governs nothing.
    eq(group:GetAlpha(), 1, "group: the group frame itself is not dimmed as decoration")
    check(rawget(group, "_dfGateApply") == nil, "group: nor armed as though it were a widget")

    -- Opening the gate hands the pane back to the group's own pass -- the only
    -- thing that re-derives its children's disableOn states.
    eq(seen.passes, 0, "group: a shut gate runs no state pass")
    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    check(bag[1]:IsEnabled(), "group: the toggle lifted the gate off the inner widgets")
    eq(seen.passes, 1, "group: and re-ran the group's own child-state pass")

    -- The borrow still holds through a group: a widget its own logic disabled is
    -- not resurrected by the gate opening.
    bag[2]:SetEnabled(false)
    row.checkButton:SetChecked(false)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    check(bag[1]:IsEnabled() == false, "group: shutting takes the live one down")
    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    check(bag[1]:IsEnabled(), "group: opening restores the one the gate took")
    check(bag[2]:IsEnabled() == false, "group: and not the one it never took")
    row:ClosePopout()
end

-- THE COUNT CHECK IS MEASURED AGAINST THE ROSTER. Against the pane's direct
-- children a group would answer 1, and every honest declaration on a real page
-- would report as a mismatch.
do
    local win, bag, seen = window(), {}, { passes = 0 }
    local before = #dbgLog
    local right = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "GroupRight", db = {}, count = 4, window = win,
        build = function(_, pane) fakeGroup(pane, 4, bag, seen); pane:SetHeight(70) end,
    }), 60)
    right:OpenPopout()
    eq(#dbgLog, before, "group/count: four widgets in a group answer a declared 4")
    host:CloseAllPopoutRows()

    local wrong = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "GroupWrong", db = {}, count = 9, window = win,
        build = function(_, pane) fakeGroup(pane, 4, bag, seen); pane:SetHeight(70) end,
    }), -60)
    wrong:OpenPopout()
    eq(#dbgLog, before + 1, "group/count: a wrong declaration still reports")
    check(dbgLog[#dbgLog].msg:find("4"),
        "group/count: ...naming the roster's four, not the pane's one child")
    host:CloseAllPopoutRows()
end

-- ============================================================
-- 19. THE PANE'S HEIGHT IS NOT A CONSTANT
-- paneFor measures the pane once, at build, and swapTo used to replay that
-- number forever. A pane holding a settings group re-flows whenever a hideOn
-- inside it changes (a style dropdown revealing a texture picker), so the panel
-- was left sized to a column that no longer exists -- a gap under the last
-- control, or a control cut off below the frame.
-- ============================================================
do
    local win, pane = window(), nil
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Grows", db = {}, window = win,
        build = function(_, p) pane = p; p:SetHeight(80) end,
    }))
    row:OpenPopout()
    local po = row.popout
    eq(po.content:GetHeight(), 80, "resync: the panel opened at the pane's build height")
    pane:SetHeight(140)
    eq(po.content:GetHeight(), 80, "resync: a re-flow underneath it is not noticed on its own")
    po:SyncRowPaneHeight()
    eq(po.content:GetHeight(), 140, "resync: the public resync re-measures the active pane")
    eq(po.frame:GetHeight(), TITLE_H + PAD + 140 + PAD, "resync: ...and the frame follows it")
    row:ClosePopout()
end

-- A CACHED pane re-flowed while another row had the panel: the swap back has to
-- re-measure, because nothing else will.
do
    local win, panes = window(), {}
    local function mk(name, dy, h)
        return place(host:CreatePopoutRow(FakeUIFrame(), {
            label = name, db = {}, window = win,
            build = function(_, p) panes[name] = p; p:SetHeight(h) end,
        }), dy)
    end
    local a, b = mk("RA", 100, 60), mk("RB", -100, 90)
    a:OpenPopout()
    local po = a.popout
    eq(po.content:GetHeight(), 60, "resync/swap: A opened at its own height")
    b:OpenPopout()
    panes.RA:SetHeight(200)
    a:OpenPopout()
    eq(po.content:GetHeight(), 200, "resync/swap: swapping back re-reads the cached pane")
    host:CloseAllPopoutRows()
end

-- A SCROLL-WRAPPED pane is left alone by both paths. Its host is the scroll
-- region and rec.h IS the cap, so re-measuring the pane inside it would open a
-- panel taller than the screen -- which is the thing the cap exists to stop.
do
    local win, pane = window(), nil
    local cap = UIParent:GetHeight() * 0.6
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "TallResync", db = {}, window = win,
        build = function(_, p) pane = p; p:SetHeight(2000) end,
    }))
    row:OpenPopout()
    local po = row.popout
    eq(po.content:GetHeight(), cap, "resync/cap: a wrapped pane opens at the cap")
    pane:SetHeight(3000)
    po:SyncRowPaneHeight()
    eq(po.content:GetHeight(), cap, "resync/cap: and the resync leaves it there")
    row:ClosePopout()
end

-- ============================================================
-- 12. A STRETCHED ROW
-- The row is built at 260 but it is a SLOT, not a fixed-width card: a consumer
-- that lays it out full-width (the Frame page's Appearance band, which spans
-- both columns) hands it whatever the page has. Everything the row draws has to
-- travel with that edge -- and so does the popout's beam, which is the whole
-- reason the width matters. A row that stops 280px into a 550px page leaves its
-- panel connected by a line across half the page.
-- ============================================================
do
    -- The plate is the ink, and it is anchored to BOTH of the row's top corners
    -- rather than sized -- which is what makes the row's width the plate's.
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Stretch", db = { on = true }, toggle = { key = "on" }, count = 3,
    })
    local pts = {}
    for _, p in ipairs(row.plate._points) do pts[p[1]] = p end
    check(pts.TOPLEFT ~= nil, "stretch: the plate is pinned to the row's top-LEFT")
    check(pts.TOPRIGHT ~= nil, "stretch: ...and to its top-RIGHT, so it follows the width")
    eq(row.plate:GetParent(), row, "stretch: ...and it is the row's own child")
    -- The gap the slot carries is the only thing trimmed off the row's rect, so
    -- the popout's outline and beam measure the FULL width, not an inset one.
    local ins = row.popoutInset
    eq(ins[1], 0, "stretch: nothing is trimmed off the row's left")
    eq(ins[2], 0, "stretch: ...or its right")
    eq(ins[3], 0, "stretch: ...or its top")
    eq(ins[4], M.gap, "stretch: only the slot's bottom gap, which is not painted")
end

-- ...and the beam gets SHORTER as the row gets wider, because it lands on the
-- row's near face. Two rows sharing a left edge and a y, one at a settings
-- box's width and one at a page's: same popout, same dock, different landing.
do
    local win = window()
    local LEFT = CX - 260          -- both rows start here
    local function stretched(name, w)
        local r = host:CreatePopoutRow(FakeUIFrame(), {
            label = name, db = {}, window = win, build = counting(name, 60),
        })
        r:SetSize(w, ROW_H)
        r:SetFakeCenter(LEFT + w / 2, CY)
        r:Show()
        return r
    end

    -- Where the dock puts the panel, STATED rather than measured (the stub
    -- resolves no anchors -- same arrangement test_popout.lua's beam case uses).
    -- The same spot for both, so the only thing that moves is the row's edge.
    local DOCK_X, DOCK_Y = CX + 420, CY
    local function beamEndX(row)
        row:OpenPopout()
        local po = row.popout
        po.frame:SetFakeCenter(DOCK_X, DOCK_Y)
        po:Follow(row, { outsideOf = win })
        local core = po.beam.core
        local sx, ex = core._start.x, core._end.x
        host:CloseAllPopoutRows("test")
        return ex, sx - ex, core._end.y
    end

    local narrowEnd, narrowLen, narrowY = beamEndX(stretched("BeamNarrow", 260))
    local wideEnd,   wideLen,   wideY   = beamEndX(stretched("BeamWide", 520))

    -- In UIParent-centre units the narrow row's right edge is at CX, the wide
    -- one's 260 further out; the connection point is further right than either,
    -- so the beam clamps onto that edge in both cases.
    eq(narrowEnd, LEFT + 260 - CX, "stretch: the beam lands on the narrow row's right edge")
    eq(wideEnd,   LEFT + 520 - CX, "stretch: ...and on the WIDE row's, 260px further out")
    eq(narrowLen - wideLen, 260, "stretch: so the beam is exactly the extra width shorter")
    check(wideLen < narrowLen, "stretch: ...which is the short hop the band is for")
    eq(narrowY, wideY, "stretch: and it still crosses level -- the width moved nothing else")
end


-- ============================================================
-- THE SURFACE STYLE -- opts.surface
--
-- The plate wears one of two shapes, and the row's THREE STATES -- rest, hover,
-- and the accent wash of the open row -- have to reach whichever one is on
-- screen. That is the whole difficulty: there are already four ways into the
-- state paint (a hover, a retarget, a toggle write, an accent change) and none
-- of them may learn which shape it is painting.
--
-- ☠ WHAT THIS REPLACED. The in-game trial routed the states by SWAPPING the
-- plate's SetBackdropColor / SetBackdropBorderColor for shims that painted a
-- rounded surface -- two sets of methods on one frame, restorable only by
-- remembering the originals, and invisible to anyone reading paintState. The
-- shape is one function now and the state paint calls it with four numbers
-- twice, so what these tests assert is that the SAME state machine drives both.
--
-- ☠ AND THE SQUARE HALF IS AN ASSERTION ABOUT DandersMover. It shares this file
-- and never declares a style, so "no style, backdrop colours, no rounded
-- surface, no declared radius" is the mover's row unchanged.
-- ============================================================

local R8 = { style = "rounded", radius = 8, borderWidth = 2, rowBorderWidth = 1 }

local function plateSurface(row) return UI:GetRoundedSurface(row.plate) end

print("-- Row: no style declared is the square plate, unchanged")
do
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Border", db = { on = true }, toggle = { key = "on" },
        summary = function() return "2px" end, build = counting("sqplate", 40, 1),
        window = window(),
    }))
    check(row:GetSurface() == nil, "square: the row carries no style")
    check(plateSurface(row) == nil, "square: and no rounded surface was ever created")
    check(row.plate._elementOpts ~= nil, "square: the element backdrop is what was issued")
    eq(row.plate._fill.a, M.restFill, "square: painted at the rest alpha")
    -- The tether contract's shape half stays UNDECLARED, which is what tells the
    -- popout shell to trace this plate with a square pixel border.
    check(rawget(row, "popoutRadius") == nil, "square: the row declares no curve")
end

print("-- Row: a rounded style paints the plate's chrome and declares its curve")
do
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Border", db = { on = true }, toggle = { key = "on" },
        summary = function() return "2px" end, build = counting("rndplate", 40, 1),
        window = window(), surface = R8,
    }))
    local rs = plateSurface(row)
    check(rs ~= nil and rs:IsShown(), "rounded: the plate wears a rounded surface")
    local r, w = rs:GetRadius()
    eq(r, 8, "rounded: at the style's radius")
    -- ☠ THE ROW WEIGHT, NOT THE PANEL'S. A column of forty plates at the popout's
    -- two units reads as a grid of boxes rather than as a list -- which is why
    -- the one token carries both numbers and each site picks its own.
    eq(w, 1, "rounded: and the style's ROW border width, not the panel's")
    check(rawget(row.plate, "_pxHidden") == true, "rounded: the square pixel border came down")
    eq(rawget(row, "popoutRadius"), 8, "rounded: the curve is declared on the tether contract")
end

print("-- Row: every state reaches the rounded plate")
do
    local db = { on = true }
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Border", db = db, toggle = { key = "on" },
        summary = function() return "2px" end, build = counting("rndstate", 40, 1),
        window = win, surface = R8,
    }))
    local rs = plateSurface(row)
    eq(rs.fillA, M.restFill, "rest: the surface carries the rest alpha")
    eq(rs.borderA, M.restBorder, "rest: ...inside the rest border")

    row:GetScript("OnEnter")()
    eq(rs.fillR, UI.Colors.hover.r, "hover: lifted to the hover colour")
    eq(rs.fillA, M.hoverFill, "hover: ...and brightened")
    row:GetScript("OnLeave")()
    eq(rs.fillA, M.restFill, "hover: and leaving puts it back")

    -- ACTIVE is the state that used to need the swapped methods most: it is
    -- reached from a retarget rather than from anything the row itself does.
    row:OpenPopout()
    eq(rs.borderR, ACCENT.r, "active: opening puts the accent on the ring")
    eq(rs.borderA, M.activeBorder, "active: at full strength")
    eq(rs.fillR, ACCENT.r, "active: and washes the inside with it")
    eq(rs.fillA, M.activeFill, "active: ...as a WASH, not a fill")
    row:GetScript("OnEnter")()
    eq(rs.fillA, M.activeHover, "active: hovering an open row brightens the wash")
    row:GetScript("OnLeave")()
    eq(rs.fillA, M.activeFill, "active: and settles back")

    row:SetAccent({ r = 1, g = 0.5, b = 0, a = 1 })
    eq(rs.fillR, 1, "accent: a re-tint repaints the open row's wash")
    eq(rs.borderR, 1, "accent: ...and its ring")
    host:CloseAllPopoutRows("test")
end

print("-- Row: the style is FORWARDED to the panel the row opens")
do
    -- ☠ NOT LEFT TO THE HOST. The panel and the plate it comes out of are one
    -- object as far as the eye is concerned -- they share an accent, a beam and
    -- an outline traced on the plate at the plate's own radius -- so a row given
    -- an explicit style and a panel resolving its own would disagree about the
    -- shape of the thing they are both drawing.
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Border", db = { on = true }, toggle = { key = "on" },
        summary = function() return "2px" end, build = counting("fwd", 40, 1),
        window = window(), surface = R8,
    }))
    row:OpenPopout()
    local po = row.popout
    check(po.surface ~= nil, "the panel took the row's style")
    eq(po.surface.radius, 8, "...at the row's radius")
    -- The outline the shell lays over the plate follows the plate's declared
    -- curve, which is what makes the pair read as one object.
    local ring = UI:GetRoundedSurface(po.srcOutline)
    check(ring ~= nil and ring:IsShown(), "and the outline over the plate is a matching ring")
    eq(ring:GetRadius(), 8, "...at the plate's radius")
    host:CloseAllPopoutRows("test")
end

print("-- Row: a SQUARE row forces its panel square, on a rounded host")
do
    -- `row._surface` is nil for a square row and nil means "ask the host" to the
    -- popout -- so the row has to spell the override out as an explicit false.
    -- This is the case the chrome workbench lives in.
    host:SetSurfaceStyle(R8)
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Border", db = { on = true }, toggle = { key = "on" },
        summary = function() return "2px" end, build = counting("sqonround", 40, 1),
        window = window(), surface = false,
    }))
    check(row:GetSurface() == nil, "the row is square, though the host is not")
    check(plateSurface(row) == nil, "...its plate never took a rounded surface")
    row:OpenPopout()
    check(row.popout.surface == nil, "...and neither did the panel it opened")
    host:CloseAllPopoutRows("test")

    -- ...while a row that says nothing on that same host is rounded.
    local dflt = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Shadow", db = { on = true }, toggle = { key = "on" },
        summary = function() return "4px" end, build = counting("dfltround", 40, 1),
        window = window(),
    }))
    check(dflt:GetSurface() ~= nil, "a row that declares nothing takes the host's style")
    eq(rawget(dflt, "popoutRadius"), 8, "...and declares its curve")
    host:SetSurfaceStyle(nil)
end

print("-- Row: SetSurface swaps the shape live, and takes its panels with it")
do
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Border", db = { on = true }, toggle = { key = "on" },
        summary = function() return "2px" end, build = counting("live", 40, 1),
        window = win, surface = R8,
    }))
    row:OpenPopout()
    local po = row.popout
    local rs = plateSurface(row)
    check(rs:IsShown() and po.surface ~= nil, "start: both round")

    row:SetSurface(false)
    check(not rs:IsShown(), "square: the plate's rounded textures go down")
    check(row.plate._elementOpts ~= nil, "square: the element backdrop is re-issued")
    -- REPLAYED through the state machine, not left on the factory's rest colours:
    -- this row is ACTIVE, so it has to come back wearing the accent wash.
    eq(row.plate._fill.r, ACCENT.r, "square: and the ACTIVE wash is repainted, not lost")
    check(rawget(row, "popoutRadius") == nil, "square: the declared curve is withdrawn")
    check(po.surface == nil, "square: the open panel followed the row")

    row:SetSurface(R8)
    check(plateSurface(row) == rs, "rounded again: the SAME surface, not a second pair")
    check(rs:IsShown(), "rounded again: and it is up")
    eq(rs.fillR, ACCENT.r, "rounded again: still wearing the active wash")
    eq(rawget(row, "popoutRadius"), 8, "rounded again: and the curve is re-declared")
    check(po.surface ~= nil, "rounded again: the panel came along")
    host:CloseAllPopoutRows("test")
end

-- ============================================================
-- THE MODIFIED TICK
-- The row's half of the modified-default marks: an amber notch on the count
-- pill saying "at least one setting behind this row is not the shipped
-- default". Same colour token as the per-control dots inside the popout, so the
-- row and the controls it opens say it in one colour.
--
-- The CHECK is the consumer's -- the kit knows nothing about defaults -- and it
-- is optional, so every existing consumer keeps a row with no tick and no error.
-- ============================================================
do
    local db = { on = true, size = 12 }
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = db, toggle = { key = "on" },
        summary = function(d) return "size " .. d.size end,
        count = 4, build = counting("modtick", 60, 4), window = window(),
    })
    check(row.modifiedTick ~= nil, "tick: the texture is built whether or not a check was declared")
    check(not row.modifiedTick:IsShown(), "tick: no check declared, no tick -- and no error")
    row.Refresh()
    check(not row.modifiedTick:IsShown(), "tick: a refresh cannot conjure one either")

    -- It is a mark ON THE PILL, so it inherits the pill's own "no count, no
    -- pill" hide and can never be left floating beside a column that is not
    -- drawn. Notched on the corner: its CENTRE on the pill's top-right.
    local p = row.modifiedTick._points[1]
    eq(p[1], "CENTER", "tick: its CENTRE...")
    check(p[2] == row.badgePill, "tick: ...on the count PILL")
    eq(p[3], "TOPRIGHT", "tick: ...at the top-right corner, straddling the border")
    eq(row.modifiedTick:GetWidth(), M.modTick, "tick: at the theme's own size")
    eq(row.modifiedTick._vertex.r, UI.Colors.notice.r, "tick: in the amber notice token")
    eq(row.modifiedTick._vertex.g, UI.Colors.notice.g, "tick: ...green")
    eq(row.modifiedTick._vertex.b, UI.Colors.notice.b, "tick: ...blue")
end

-- Declared up front, and answered live off the db the row already re-resolves.
do
    local db = { on = true, size = 12 }
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = db, toggle = { key = "on" },
        summary = function(d) return "size " .. d.size end,
        modified = function(d) return d.size ~= 12 end,
        count = 4, build = counting("modtick_opt", 60, 4), window = window(),
    })
    check(not row.modifiedTick:IsShown(), "opts.modified: at the shipped value, no tick")
    db.size = 30
    row.Refresh()
    check(row.modifiedTick:IsShown(), "opts.modified: a change lights it on the same refresh as the summary")
    eq(row.summary:GetText(), "size 30", "opts.modified: ...which is the summary's own cadence")
    db.size = 12
    row.Refresh()
    check(not row.modifiedTick:IsShown(), "opts.modified: and back to default puts it out")
end

-- SET AFTER CREATION, which is the case that forces the method to exist: a
-- consumer that learns the group's key set by WALKING the pane it just built has
-- nothing to hand CreatePopoutRow at the moment it calls it.
do
    local db = { on = true, size = 12 }
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = db, toggle = { key = "on" },
        count = 4, build = counting("modtick_late", 60, 4), window = window(),
    })
    check(not row.modifiedTick:IsShown(), "SetModifiedCheck: nothing before it is called")
    local ret = row:SetModifiedCheck(function(d) return d.size ~= 12 end)
    check(ret == row, "SetModifiedCheck: returns the row, like every other setter here")
    check(not row.modifiedTick:IsShown(), "SetModifiedCheck: it repaints immediately -- still default")

    db.size = 30
    row.Refresh()
    check(row.modifiedTick:IsShown(), "SetModifiedCheck: ...and is live from then on")

    -- Withdrawing it takes the tick down rather than freezing it where it was.
    row:SetModifiedCheck(nil)
    check(not row.modifiedTick:IsShown(), "SetModifiedCheck: nil withdraws the check AND the tick")
    row.Refresh()
    check(not row.modifiedTick:IsShown(), "SetModifiedCheck: and a later refresh does not bring it back")
end

-- A row whose toggle is OFF still shows the tick. The group is switched off; the
-- values it holds are still not the shipped ones, and hiding the mark there
-- would say they had been reset. The row's own dim carries "not doing anything".
do
    local db = { on = false, size = 30 }
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = db, toggle = { key = "on" },
        summary = function(d) return "size " .. d.size end,
        modified = function(d) return d.size ~= 12 end,
        count = 4, build = counting("modtick_off", 60, 4), window = window(),
    })
    eq(row.summary:GetText(), "Off", "tick when off: the summary is replaced, as it always was")
    check(row.modifiedTick:IsShown(), "tick when off: but the tick stays -- the values are still changed")
end

-- A non-function is not a check. Guarded here rather than at the call, so a
-- consumer that passes the wrong thing gets no tick instead of an error a frame
-- later inside Refresh.
do
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = {}, modified = true,
        count = 2, build = counting("modtick_bad", 40, 2), window = window(),
    })
    check(not row.modifiedTick:IsShown(), "bad check: a non-function opt is ignored, not called")
    row.Refresh()
    check(not row.modifiedTick:IsShown(), "bad check: ...on every refresh")
end

-- ============================================================
-- 20. ONE PANEL PER ROW
-- "If a popout is pinned, it shouldn't be able to open again as an unpinned
-- popout. Only 1 of each popout." (Danders, in-game.)
--
-- The pool cannot promise this on its own: PINNING takes an instance out of the
-- pool -- that is what pinning IS -- so a second click on the same row found
-- nothing pooled for the key and built a fresh panel. Two panels, one row, the
-- same controls in both, and no way to tell which one a write went through.
--
-- The open path therefore asks about the ROW, not about the key: is any live
-- instance currently bound to me. If one is, the click raises it.
-- ============================================================
-- The shell's own live register, which is the only honest count of "how many
-- panels exist right now" -- the row's `.popout` is one row's opinion, and the
-- bug was precisely that two of them could disagree.
local function livePanels() return #rawget(host, "_popouts").live end

do
    local win = window()
    local function mk(name, dy)
        return place(host:CreatePopoutRow(FakeUIFrame(), {
            label = name, db = { on = true }, toggle = { key = "on" },
            summary = function() return name end,
            count = 1, build = counting("one" .. name, 50, 1), window = win,
        }), dy)
    end
    local a, b = mk("OneA", 100), mk("OneB", -100)
    local base = livePanels()

    a:OpenPopout()
    local first = a.popout
    eq(livePanels(), base + 1, "one: the first click on a row opens a panel")
    eq(builds["oneOneA"], 1, "one: ...and mounts the row's controls once")

    -- Clicking an open row again is "show me that one", not "make me another".
    a:OpenPopout()
    check(a.popout == first, "one: a second click on the same row is the same panel")
    eq(livePanels(), base + 1, "one: ...and no second panel was built")
    eq(builds["oneOneA"], 1, "one: ...nor a second copy of its controls")

    -- ☠ THE CASE THAT SHIPPED BROKEN. Pinned is still LIVE, and still about this
    -- row -- so the row already has its panel and must not be given another.
    first:Pin(true)
    check(first.pinned, "one: (the panel is pinned now, and out of the pool)")
    a:OpenPopout()
    check(a.popout == first, "one: clicking a PINNED row's plate finds that panel, not a second one")
    eq(livePanels(), base + 1, "one: ...so there is still exactly one panel in the world")
    eq(builds["oneOneA"], 1, "one: ...and still one copy of the controls")
    eq(first._boundRow, a, "one: ...and it is still about the row that was clicked")

    -- ANOTHER row is a different question: it has no panel of its own, so it gets
    -- one -- the pinned instance left the pool, so this is a fresh build.
    b:OpenPopout()
    local second = b.popout
    check(second ~= first, "one: a row with no panel of its own still opens one")
    check(second.frame:GetFrameLevel() > first.frame:GetFrameLevel(),
          "one: (and the newer panel is on top of the pinned one)")

    -- ...and NOW the raise is observable: clicking the pinned row brings its
    -- panel forward instead of duplicating it.
    a:OpenPopout()
    check(a.popout == first, "one: the click still finds the pinned panel")
    check(first.frame:GetFrameLevel() > second.frame:GetFrameLevel(),
          "one: ...and RAISES it over the one that was in front")
    eq(livePanels(), base + 2, "one: two rows, two panels -- and not a third")

    second:Close()
    first:Close()
    eq(livePanels(), base, "one: (and both are gone again)")
end

-- ============================================================
-- 21. THE ROW GOES AWAY UNDER ITS OWN PANEL
-- "If a collapsible section collapses when something is popped out, it leaves a
-- highlight overlapping other parts of the settings." (Danders, in-game.)
--
-- The panel is not a child of the row -- it hangs off UIParent so it can draw
-- outside the window -- and neither is the accent outline it traces ON the row.
-- So hiding the row left both exactly where they were, and the page re-flowed
-- underneath them: an accent rectangle lying across whatever moved up.
--
-- The row answers the kit's layout-hidden contract (see Sections.lua, and
-- test_sections_group for the callers). Here: what the row DOES about it.
-- ============================================================
do
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Fold", db = { on = true }, toggle = { key = "on" },
        summary = function() return "live" end,
        count = 1, build = counting("fold", 50, 1), window = win,
    }), 100)
    check(type(rawget(row, "_OnLayoutHidden")) == "function",
          "fold: the row declares the kit's layout-hidden hook")

    row:OpenPopout()
    local po = row.popout
    check(po and not po.closed, "fold: (a panel is up, docked to the row)")
    check(po.srcOutline and po.srcOutline:IsShown(), "fold: (with the outline traced on the row)")
    check(po.beam and po.beam:IsShown(), "fold: (and the beam across the gap)")
    eq(row.plate._edge.r, ACCENT.r, "fold: (and the row painted as the open one)")

    row._OnLayoutHidden(row)
    check(po.closed, "fold: the row leaving the page closes the panel docked to it")
    check(not po.srcOutline:IsShown(), "fold: the outline goes with it -- INSTANTLY, not on a fade")
    check(not po.beam:IsShown(), "fold: the beam too")
    check(not po.notch:IsShown(), "fold: and the connection point")
    eq(row.popout, nil, "fold: the row lets go of it")
    eq(row.plate._edge.r, UI.Colors.border.r, "fold: ...and stops painting itself as the open one")
end

-- A PINNED panel survives. Pinning is the gesture that detaches a panel from the
-- row it came out of, and a detached panel does not care where that row went --
-- it carries no beam and no outline, so there is nothing left to orphan.
do
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "FoldPin", db = { on = true }, toggle = { key = "on" },
        count = 1, build = counting("foldpin", 50, 1), window = win,
    }), 100)
    row:OpenPopout()
    local po = row.popout
    po:Pin(true)
    row._OnLayoutHidden(row)
    check(not po.closed, "fold: a pinned panel is detached, and survives its row going away")
    po:Close()
end

-- One row's fold is not another row's. The hook walks the panels bound to THIS
-- row, and the shared instance is only ever about one row at a time.
do
    local win = window()
    local function mk(name, dy)
        return place(host:CreatePopoutRow(FakeUIFrame(), {
            label = name, db = { on = true }, toggle = { key = "on" },
            count = 1, build = counting("fold" .. name, 50, 1), window = win,
        }), dy)
    end
    local a, b = mk("FA", 100), mk("FB", -100)
    a:OpenPopout()
    b:OpenPopout()                      -- the shared panel glides across to b
    local po = b.popout
    a._OnLayoutHidden(a)
    check(not po.closed, "fold: folding the row the panel LEFT does not close it")
    eq(po._boundRow, b, "fold: ...it is still about the row it moved to")
    b._OnLayoutHidden(b)
    check(po.closed, "fold: folding the row it is about does")
end

-- ============================================================
-- 24. THE FOOTER STRIP, AND THE HOISTED CONTROL LINES
-- ------------------------------------------------------------
-- The popout sweep put every setting behind a row, and the feedback was "less
-- overwhelming but much harder to find what ur looking for". So a row may now
-- draw up to two CONTROL LINES under its title -- each one a named cell holding
-- the panel's OWN setting a second time -- and its way in moves to a FOOTER
-- STRIP along the bottom of the plate.
--
-- ☠ EVERY LINE OF IT IS OPT-IN. `footerStrip` is what a page passes; a row that
-- does not is the row every other page's census suite already pins, and section
-- 24.1 is that claim stated where it can fail.
--
-- WHAT THIS SUITE CAN AND CANNOT SEE. Fake frames RECORD anchors rather than
-- resolving them, so nothing here proves a cell LANDS where its anchor says --
-- the same honest limit test_addindicator_pane.lua states. What is driven is the
-- arithmetic: how many cells fit a width, how many lines that makes, what the
-- plate and the slot then measure, and which region the panel tethers to.
-- ============================================================
print("-- Row: the footer strip and the hoisted control lines")

-- ---- the two embedded factories -----------------------------------
-- ADDED, not replaced, per this file's rule at the head. Each answers exactly
-- the contract SetHoistedControls drives: the opts it was handed (so the binding
-- is assertable), a re-readable bound value, and -- deliberately -- refreshValue
-- as a METHOD that USES its self, which is what the real dropdown's does. A stub
-- that ignored self would let a bare `c.refreshValue()` pass.
if not UI.CreateSliderNative then
    local function boundValue(opts)
        if opts.get then return opts.get() end
        if opts.dbRef and opts.dbRef.db then return opts.dbRef.db[opts.dbRef.key] end
        return nil
    end
    -- ☠ THE HOVER HIT, BUILT THE WAY UI:AttachTooltip BUILDS IT under the two
    -- opts a caption-hiding caller passes. The real helper's own end of the
    -- contract -- motion but never clicks, parented to and levelled off the frame
    -- it was pointed at, and nothing at all under `noTooltipHit` -- is driven
    -- against the real Widgets.lua in test_widgets_slider.lua. What THIS stub
    -- exists to let the row's own claims fail is (a) that the row points it at
    -- the NAME TIER rather than leaving it on the hidden caption, (b) that a
    -- declaration carrying no tooltip gets no frame at all, and (c) that the
    -- layout narrows it to the words and re-levels it.
    local function attachStubHit(c, opts)
        if opts.noTooltipHit then return end
        local box = opts.tooltipHit
        if not box then return end
        local hit = CreateFrame("Frame", nil, box)
        hit:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
        hit:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 0)
        hit:SetMouseMotionEnabled(true)
        hit:SetMouseClickEnabled(false)
        hit:SetFrameLevel((box:GetFrameLevel() or 0) + 1)
        hit:Show()
        c.dfTooltipHit = hit
    end
    -- ☠ THE MODIFIED-DEFAULT DOT, MODELLED. Widgets.lua's AddModifiedDot hangs a
    -- 6px amber texture at the end of the control's OWN caption's words -- and
    -- this cell HIDES that caption, which is the whole of the defect: the dot was
    -- placed off a rect nobody can see, which lies directly under the name tier,
    -- and came down on the letters of the name.
    --
    -- What the stub honours is exactly the kit's two optional fields, read on
    -- EVERY update: `modifiedDotLabel` (which FontString the offset is measured
    -- from) and `modifiedDotMaxX` (a ceiling on that measurement). The kit's own
    -- end of that contract -- that it reads both, obeys the cap as a CEILING and
    -- not as a position, and falls back to the caption when neither is set -- is
    -- driven against the real Widgets.lua in test_widgets_slider.lua. Same split
    -- this file's tooltip-hit stub above is already written to.
    --
    -- ⚠ ON THE SLIDER ONLY, and that is enough: the row sets the two fields on
    -- whatever the factory handed back, without asking what kind it is, so a pair
    -- of sliders drives the whole of the row's surface. Both kinds reach
    -- AddModifiedDot through the one AddOverrideIndicators door over there.
    local function attachStubDot(host, c, opts)
        local dot = c:CreateTexture(nil, "OVERLAY")
        dot:SetSize(6, 6)
        dot:Hide()
        c.modifiedDot = dot
        c.UpdateModifiedDot = function(self)
            local ref = opts.dbRef
            local on = host:Call("isModifiedDefault", ref and ref.db, ref and ref.key)
                       and true or false
            if on then
                -- rawget for both, as the kit does: an unset key on these frames
                -- answers a truthy no-op FUNCTION, and a plain read would anchor
                -- the dot to it.
                local anchor = rawget(self, "modifiedDotLabel") or self.label
                local x = (anchor:GetStringWidth() or 0)
                local maxX = rawget(self, "modifiedDotMaxX")
                if type(maxX) == "number" and x > maxX then x = maxX end
                dot:ClearAllPoints()
                dot:SetPoint("LEFT", anchor, "LEFT", x + 4, 0)
            end
            dot:SetShown(on)
            return on
        end
        c:UpdateModifiedDot()
    end
    function UI:CreateSliderNative(parent, opts)
        local c = CreateFrame("Frame", nil, parent)
        c._sliderOpts = opts
        -- SHOWN to begin with: the real factory draws its caption and the row
        -- hides it afterwards, so a stub that started hidden would let "the
        -- caption is hidden" pass without the row doing anything.
        --
        -- ...and CARRYING ITS TEXT, as the real one does. The caption is what the
        -- dot falls back to, so a blank one would let "the dot is off the name"
        -- pass at an offset the hidden caption would have given anyway.
        c.label = FakeUIFrame()
        c.label:SetText(opts.label or "")
        c.label:Show()
        if opts.tooltip ~= nil then c.tooltip = opts.tooltip end
        attachStubHit(c, opts)
        attachStubDot(self, c, opts)
        -- The kit's slider re-answers the dot from inside its own value repaint
        -- (RefreshValue -> UpdateValue -> UpdateOverrideIndicators), which is what
        -- makes the row's Refresh keep the mark live without the row knowing the
        -- indicator exists.
        c.refreshValue = function(self2)
            self2._value = boundValue(opts)
            self2:UpdateModifiedDot()
        end
        c:refreshValue()
        return c
    end
    function UI:CreateDropdownNative(parent, opts)
        local c = CreateFrame("Frame", nil, parent)
        c._dropdownOpts = opts
        if opts.tooltip ~= nil then c.tooltip = opts.tooltip end
        attachStubHit(c, opts)
        c.refreshValue = function(self) self._value = boundValue(opts) end
        c:refreshValue()
        return c
    end
end

local LINE_H, NAME_H, CONTROL_H = M.lineH, M.nameH, M.controlH
local LINE_PAD, CELL_GAP, FOOTER_H = M.linePad, M.cellGap, M.footer
local MIN_CONTROL, SPLIT_CELL = M.minControl, M.splitCell
local LABEL_X = M.padX + M.check + M.labelGap
-- ☠ A STRIP ROW'S TITLE LINE IS **NOT** `plate`. A plain row's plate is the
-- whole row and is the 44 every other page's census pins; a strip row's plate is
-- a title line, some control lines and a strip, and the title line alone is
-- M.plateStrip. Section 24.1 pins that the plain row did not move.
local HEAD_H = M.plateStrip
-- The kit slider's own two numbers, from DandersUI/Widgets.lua's CreateSlider:
-- the value box is SetSize(50, 20) pinned to the container's right edge, and the
-- track and the bar both stop 8 short of it. Restated here because they are
-- file-locals over there and the WHOLE POINT of putting the name above the
-- control is what these two leave of a cell -- see 24.4's track arithmetic.
local SLIDER_BOX, SLIDER_BOX_GAP = 50, 8

-- A row at a stated WIDTH, laid out. `place` pins 260 on every row, which is one
-- of the three width regimes this suite needs, so the width is set after it and
-- the layout re-run by hand -- headless frames fire no OnSizeChanged.
local function widen(row, w)
    row:SetWidth(w)
    row._LayoutPlate()
    return row
end

-- ⚠ NOT `place`, and that is the point of writing a second one. `place` pins
-- SetSize(260, ROW_H) on every row it is handed, which would stamp a plain row's
-- 50px slot back over a strip row's own -- so this gives the row its width and
-- its screen position and leaves the HEIGHT to the row, which is the thing under
-- test.
local function stripRow(opts)
    opts.db = opts.db or { on = true }
    opts.build = opts.build or counting("hoist" .. tostring(opts.label), 50)
    local row = host:CreatePopoutRow(FakeUIFrame(), opts)
    row:SetWidth(260)
    row:SetFakeCenter(CX - 100, CY)
    row:Show()
    -- ⚠ FAKE FRAMES DO NOT RESOLVE ANCHORS: a child's centre stays (0,0)
    -- until a test says otherwise, and the popout's CLIP GATE asks the tether
    -- for its rect -- so a strip left at the origin reads as off-screen and the
    -- panel takes its whole chrome down. Given the row's own rect, which is
    -- where its anchors put it to within the strip's own height.
    if row.footerStrip then
        row.footerStrip:SetSize(260, M.footer)
        row.footerStrip:SetFakeCenter(CX - 100, CY)
    end
    return row
end

-- Two sliders on one db table, the shape the Frame Size row declares.
local function twoSliders(db, seen)
    return {
        { name = "Frame Width", kind = "slider", key = "frameWidth", db = db,
          min = 60, max = 300, step = 1,
          onChanged = function() seen[#seen + 1] = "w" end },
        { name = "Frame Height", kind = "slider", key = "frameHeight", db = db,
          min = 20, max = 300, step = 1,
          onChanged = function() seen[#seen + 1] = "h" end },
    }
end

-- ---- 24.1 a row that did not ask is untouched ----------------------
-- The whole of "no other page moves". Stated against the SAME anatomy section 1
-- pins, so the two agree about what an unconverted row is.
do
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Plain", db = { on = true }, toggle = { key = "on" },
        count = 4, build = counting("plainstrip", 50), window = win,
    }))
    eq(rawget(row, "footerStrip"), nil, "strip: a row that did not ask has none")
    eq(rawget(row, "stripCount"), nil, "strip: ...and no count phrase either")
    eq(row.plate:GetHeight(), PLATE_H, "strip: its plate is the plate it always was")
    eq(row:GetHeight(), ROW_H, "strip: ...in the slot it always took")
    check(row.badgePill:IsShown(), "strip: the count is still a pill on the title line")
    eq(row.badge:GetText(), "4", "strip: ...carrying the declared count")
    eq(row.modifiedTick._points[1][2], row.badgePill, "strip: and the tick is still notched on it")
    -- The four right-hand columns still resolve to the PLATE's right edge, which
    -- is the claim section 14 makes at length.
    eq(rightEdgeFrom(row.chevron, row.plate), -M.padX, "strip: the chevron is still on the title line")
    -- ...and the title line's regions carry no vertical offset, because there is
    -- nothing under them to make room for.
    eq(row.label._points[1][5] or 0, 0, "strip: the label is centred on the whole plate")
end

-- ---- 24.2 the strip itself -----------------------------------------
do
    local win = window()
    local row = stripRow({ label = "Stripped", toggle = { key = "on" },
                           count = 5, window = win, footerStrip = true })
    local strip = row.footerStrip
    check(strip ~= nil, "strip: declaring it builds it")
    eq(strip:GetHeight(), FOOTER_H, "strip: at the theme's own height")
    -- ☠ THE TITLE LINE IS TIGHTER ON A STRIP ROW, and that is the whole of the
    -- "chonky" half of the in-game verdict. 44 was a row; here it is the top
    -- third of one, and 44 + 36 + 4 + 18 is a plate a third of which is air.
    eq(row.plate:GetHeight(), HEAD_H + FOOTER_H,
        "strip: the plate is the title line and the strip, and nothing between them")
    eq(row:GetHeight(), HEAD_H + FOOTER_H + M.gap, "strip: and the slot follows the plate")
    eq(row.preferredHeight, HEAD_H + FOOTER_H + M.gap,
        "strip: ...re-reported, because the row was added to its band before this")
    eq(row.layoutHeight, row.preferredHeight, "strip: under the name the layout pass reads")
    -- The number that matters, stated as the comparison rather than as a
    -- constant: a row with nothing hoisted has to be VISIBLY shorter than the
    -- 62px plate the first try shipped, or the strip is pure cost on the ten
    -- rows that hoist nothing.
    check(row.plate:GetHeight() < PLATE_H + FOOTER_H,
        "strip: a bare strip row is shorter than it was when the title line was a whole plate")
    check(HEAD_H >= M.check + 12,
        "strip: ...but still holds the 16px tick with air either side")

    -- The cluster MOVED. Same two textures, re-anchored -- not a second pair.
    eq(rightEdgeFrom(row.chevron, strip), -M.padX, "strip: the chevron is a pad in from the strip's right")
    eq(rightEdgeFrom(row.stripCount, strip), -(M.padX + M.chevron + M.colGap),
        "strip: the count phrase a gap inboard of it")
    eq(rightEdgeFrom(row.gear, strip),
        -(M.padX + M.chevron + M.colGap + (row.stripCount:GetWidth() or 0) + M.colGap),
        "strip: and the cog a gap inboard of the phrase")
    check(not row.badgePill:IsShown(), "strip: the count PILL is gone -- the words replace it")
    -- ☠ AND THE MODIFIED TICK IS NOT ON THE COG. It was notched on the cog's
    -- top-right corner and in game the 5px dot landed ON the 14px glyph -- a
    -- notch needs something bigger than itself to be notched on. It goes after
    -- the CHEVRON instead: the end of the way-in cluster, touching none of it.
    eq(row.modifiedTick._points[1][2], row.chevron,
        "strip: the modified tick sits after the chevron, at the strip's far right")
    eq(row.modifiedTick._points[1][1], "LEFT", "strip: ...anchored by its own left edge")
    eq(row.modifiedTick._points[1][3], "RIGHT", "strip: ...to the chevron's right")
    eq(row.modifiedTick._points[1][4], M.modTickGap, "strip: a hair clear of it")
    check(row.modifiedTick._points[1][2] ~= row.gear,
        "strip: and NOT on the cog, which is the same size class as the dot")
    -- ...and it still fits inside the plate's own padding: the chevron ends a
    -- padX in, and the dot plus its gap have to come out of that.
    check(M.modTickGap + M.modTick < M.padX,
        "strip: the dot and its gap fit inside the plate's right-hand padding")

    -- ☠ THE STRIP TAKES THE MOUSE, and 24.19 drives what it does with it.
    -- Stated here as anatomy because the first try asserted the OPPOSITE ("the
    -- strip installs no hover of its own", "the whole row is already the click
    -- target"), and the reversal is the whole of section 21: the band along the
    -- bottom is the only way in and the only thing that lights.
    eq(strip._kind, "Button", "strip: the strip is a Button, because it answers a click")
    check(strip._flags.mouseClick, "strip: ...with the mouse actually on it")
    check(strip:GetScript("OnClick") ~= nil, "strip: it carries the click")
    check(strip:GetScript("OnEnter") ~= nil, "strip: ...a hover of its own")
    check(strip:GetScript("OnLeave") ~= nil, "strip: ...and the leave that ends it")

    -- The title line made room for it, and every region on it moved by the SAME
    -- amount -- two that disagreed would be two vertical constraints fighting.
    local dy = FOOTER_H / 2
    eq(row.label._points[1][5], dy, "strip: the label lifts to the title line's own middle")
    eq(row.checkButton._points[1][5], dy, "strip: ...and the tick with it")
    eq(row.summary._points[2][5], dy, "strip: ...and the summary's right edge")
end

-- ---- 24.3 what the strip says --------------------------------------
do
    local win = window()
    local db = { on = true, frameWidth = 100, frameHeight = 50 }
    local seen = {}
    local row = stripRow({ label = "Counting", db = db, toggle = { key = "on" },
                           count = 5, window = win, footerStrip = true })
    eq(row.stripCount:GetText(), "5 more settings",
        "count: with nothing hoisted, the strip says the whole group")
    row:SetHoistedControls(twoSliders(db, seen))
    widen(row, 401)
    eq(row.stripCount:GetText(), "3 more settings",
        "count: ...and MORE means more: the two on the plate come off it")
    eq(row:GetShownHoistCount(), 2, "count: the row agrees about how many it is showing")
end

-- ---- 24.4 the cells, the lane and the split ------------------------
do
    local win = window()
    local db = { on = true, frameWidth = 100, frameHeight = 50 }
    local seen = {}
    local row = stripRow({ label = "Cells", db = db, count = 5,
                           window = win, footerStrip = true })
    row:SetHoistedControls(twoSliders(db, seen))

    -- A 401 plate is the shipped default window's (DandersUI/ControlRow.lua
    -- carries the arithmetic). Two cells fit.
    widen(row, 401)
    local lineW = 401 - LABEL_X - M.padX
    local cellW = math.floor((lineW - CELL_GAP) / 2)
    eq(lineW, 355, "cells: the control line is the plate less the name indent and the padding")
    local h1, h2 = row._hoistCells[1], row._hoistCells[2]
    check(h1 ~= nil and h2 ~= nil, "cells: both declarations built a cell")
    check(h1:IsShown() and h2:IsShown(), "cells: ...and both are drawn")
    eq(h1:GetWidth(), cellW, "cells: two equal cells share the line")
    eq(h2:GetWidth(), cellW, "cells: ...exactly equal")
    eq(cellW, 172, "cells: ...172 each at the shipped default window")
    eq(h1:GetHeight(), LINE_H, "cells: at the theme's line height")
    eq(LINE_H, NAME_H + CONTROL_H, "cells: which is the name tier plus the control tier")
    -- Same line, second column.
    eq(h1._points[1][4], LABEL_X, "cells: the first cell starts at the NAME's x, not the tick's")
    eq(h2._points[1][4], LABEL_X + cellW + CELL_GAP, "cells: the second a cell-gap along")
    eq(h1._points[1][5], -HEAD_H, "cells: line one sits directly under the title line")
    eq(h2._points[1][5], -HEAD_H, "cells: ...and both cells are on it")
    eq(row.plate:GetHeight(), HEAD_H + LINE_H + LINE_PAD + FOOTER_H,
        "cells: one line of controls, so the plate grows by one -- and by the air under it")

    -- ☠ THE NAME IS ABOVE THE CONTROL, NOT BESIDE IT. The lane version gave the
    -- name a fixed 62px and the panel's own labels did not fit: "FRAME WI...",
    -- "GROWTH DI...". Two tiers, and each gets the cell's whole width.
    local h = row._hoists[1]
    local nm, box = h.nameText, h.nameBox
    eq(nm:GetText(), "FRAME WIDTH", "name: the name is the panel's own string, in caps")
    check(box ~= nil, "name: the name tier is a FRAME of its own")
    eq(box:GetParent(), h1, "name: ...inside the cell")
    eq(box:GetHeight(), NAME_H, "name: with a height, so what sits under it is anchored to something")
    eq(box._points[1][5], 0, "name: flush with the cell's top -- it is the upper tier")
    eq(box._points[1][4], 0, "name: ...and its full width, left edge")
    eq(box._points[2][4], 0, "name: ...to right edge")
    eq(nm:GetParent(), box, "name: the string lives in that frame, not on the plate")
    -- ⚠ AND IT TAKES NO MOUSE. It lies directly over a control on a plate that is
    -- itself the click target: the one frame in this cell that would eat a drag.
    eq(rawget(box, "_flags").mouse, false, "name: and the tier takes no mouse")
    -- The control's own tier is the rest of the cell, and it starts under the name.
    local c1 = h.control
    eq(c1._points[1][1], "TOPRIGHT", "name: the control hangs from the cell's top-right")
    eq(c1._points[1][5], -(NAME_H + CONTROL_H / 2) + M.sliderBarMid,
        "name: ...centred by its BAR on the control tier, not on the whole cell")

    -- ☠ THE POINT OF THE WHOLE CHANGE: THE TRACK. The control gets the cell's
    -- full width now, and the kit slider spends 50 of it on its value box and 8
    -- keeping clear of it. Beside a 62px lane that left 46px of live track on a
    -- 60-300 range -- about five units per pixel.
    eq(c1:GetWidth(), cellW, "track: the control fills the whole cell, lane and all")
    eq(cellW - SLIDER_BOX - SLIDER_BOX_GAP, 114,
        "track: so a control in a PAIR gets 114px of live track, not 46")
    check(cellW - SLIDER_BOX - SLIDER_BOX_GAP >= 112,
        "track: ...at least the 112 ControlRow.lua sized its own slider for")

    -- THE SPLIT. Narrow the plate until two cells no longer fit and the pair
    -- becomes two ONE-cell lines -- the tracks get longer, not shorter.
    widen(row, 260)
    eq(row._hoistCells[1]:GetWidth(), 260 - LABEL_X - M.padX,
        "split: at 260 a cell takes the whole line")
    eq(row._hoistCells[1]._points[1][5], -HEAD_H, "split: the first is on line one")
    eq(row._hoistCells[2]._points[1][5], -(HEAD_H + LINE_H), "split: the second on line two")
    eq(row.plate:GetHeight(), HEAD_H + 2 * LINE_H + LINE_PAD + FOOTER_H,
        "split: so the plate is two lines tall")
    eq(row:GetHeight(), HEAD_H + 2 * LINE_H + LINE_PAD + FOOTER_H + M.gap,
        "split: and the slot with it")
    eq(row.stripCount:GetText(), "3 more settings",
        "split: a split shows the same two, so the count does not move")
    -- ☠ AND THE SPLIT STILL HAPPENS AT 260, which is the reason splitCell is a
    -- token of its own rather than minControl. With the name above, a cell IS
    -- its control's width -- so a rule that split only at minControl would put
    -- two 98px cells on this plate and hand the NARROW window 40px of track,
    -- the exact cramp the tiers were built to fix, arriving at the other end.
    check(SPLIT_CELL > MIN_CONTROL,
        "split: the split threshold is generous and the fold floor is hard -- two numbers")
    eq(row._hoistCells[1]:GetWidth() - SLIDER_BOX - SLIDER_BOX_GAP, 156,
        "split: so a split line's track is LONGER than a pair's, not shorter")

    -- NEVER THREE. Three lanes plus three minimum tracks do not fit any plate
    -- the shell allows, so a very wide row still splits its pair across two
    -- columns and no more.
    widen(row, 1200)
    eq(row._hoistCells[2]._points[1][5], -HEAD_H, "cells: a wide plate puts both back on one line")
    eq(row.plate:GetHeight(), HEAD_H + LINE_H + LINE_PAD + FOOTER_H, "cells: ...one line tall")
    -- ...in TWO cells, not three. The line is wide enough for three lanes and
    -- three tracks here, so a rule that allowed them would show up as a narrower
    -- cell -- which is what this measures, rather than counting a third control
    -- that was never declared.
    eq(row._hoistCells[1]:GetWidth(), math.floor((1200 - LABEL_X - M.padX - CELL_GAP) / 2),
        "cells: ...and each cell is still HALF the line, never a third of it")
end

-- ---- 24.5 the fold --------------------------------------------------
do
    local win = window()
    local db = { on = true, frameWidth = 100, frameHeight = 50 }
    local seen = {}
    local row = stripRow({ label = "Folding", db = db, count = 5,
                           window = win, footerStrip = true })
    row:SetHoistedControls(twoSliders(db, seen))
    -- The floor: below the width where a line cannot hold ONE drawable control.
    local floorW = LABEL_X + M.padX + MIN_CONTROL
    widen(row, floorW)
    eq(row:GetShownHoistCount(), 2, "fold: at the floor exactly one cell still fits")
    widen(row, floorW - 1)
    eq(row:GetShownHoistCount(), 0, "fold: one pixel under it the row folds")
    check(not row._hoistCells[1]:IsShown(), "fold: ...and draws no cell at all")
    eq(row.plate:GetHeight(), HEAD_H + FOOTER_H,
        "fold: back to the title line and the strip -- and the air under the lines goes too")
    eq(row.stripCount:GetText(), "5 more settings",
        "fold: and the count goes back up by what it was showing")
    -- ...and back again, because a fold is a state and not a demolition.
    widen(row, 401)
    eq(row:GetShownHoistCount(), 2, "fold: widening brings them back")
    eq(row.stripCount:GetText(), "3 more settings", "fold: ...and the count with them")
end

-- ---- 24.6 the gate: a control for a feature that is OFF -------------
do
    local win = window()
    local db = { on = false, moverW = 40, moverH = 20 }
    local function gate(d) return (d or db).on and true or false end
    local row = stripRow({ label = "Gated", db = db, toggle = { key = "on" },
                           count = 15, window = win, footerStrip = true })
    row:SetHoistedControls({
        { name = "Handle Width", kind = "slider", key = "moverW", db = db,
          min = 5, max = 500, step = 1, visible = gate },
        { name = "Handle Height", kind = "slider", key = "moverH", db = db,
          min = 5, max = 500, step = 1, visible = gate },
    })
    widen(row, 401)
    eq(row:GetShownHoistCount(), 0, "gate: a control for a feature that is OFF is not hoisted")
    eq(row.plate:GetHeight(), HEAD_H + FOOTER_H, "gate: ...so the row is title line and strip")
    eq(row.stripCount:GetText(), "15 more settings", "gate: and the whole group is behind the click")

    -- Switch it on THROUGH THE ROW'S OWN WRITE PATH, which is the way a user
    -- does it -- so this also pins that the gate is re-asked on a refresh rather
    -- than answered once at build.
    row._Write(true)
    eq(row:GetShownHoistCount(), 2, "gate: switching the feature on brings its controls out")
    eq(row.plate:GetHeight(), HEAD_H + LINE_H + LINE_PAD + FOOTER_H,
        "gate: ...and the row grows for them")
    eq(row.stripCount:GetText(), "13 more settings", "gate: with the count down by the two on show")
end

-- ---- 24.7 the SAME setting, shown twice -----------------------------
-- The whole data claim: a second WIDGET on the same table and the same key, not
-- a copy of the value.
do
    local win = window()
    local db = { on = true, frameWidth = 100, frameHeight = 50 }
    local seen = {}
    local row = stripRow({ label = "Bound", db = db, count = 5,
                           window = win, footerStrip = true })
    row:SetHoistedControls(twoSliders(db, seen))
    widen(row, 401)

    local w = row._hoists[1].control
    local o = w._sliderOpts
    check(o.dbRef ~= nil, "bound: the control is bound through dbRef, not through a private getter")
    check(o.dbRef.db == db, "bound: ...to the very table the panel's own control writes")
    eq(o.dbRef.key, "frameWidth", "bound: ...and the same key")
    eq(o.get, nil, "bound: and NOT also through get/set, which would run the host's hooks twice")
    eq(o.set, nil, "bound: ...either half of them")
    eq(o.label, "Frame Width", "bound: the factory is handed the setting's own name, for search and the markers")
    eq(o.min, 60, "bound: with the panel's own range")
    eq(o.max, 300, "bound: ...both ends")
    check(w.label ~= nil and not w.label:IsShown(),
        "bound: the factory's own caption is hidden -- the cell's lane names it")
    -- ☠ AND THE FACTORY BUILT NO HOVER RECT OVER THAT HIDDEN CAPTION. These two
    -- declarations carry no tooltip, so there is nothing to show and therefore
    -- nothing laid over the plate to show it -- see section 24.12 for the
    -- declaration that DOES carry one and where its rect goes.
    eq(rawget(w, "dfTooltipHit"), nil,
        "bound: and no hover rect over that hidden caption, because there is nothing to say")
    check(w._sliderOpts.noTooltipHit == true,
        "bound: ...and the row SAID so to the factory rather than fixing it up afterwards")

    -- A write nobody on this plate made -- the pane's twin, a Reset Group, an
    -- undo -- reaches the hoisted control on the row's own refresh.
    eq(w._value, 100, "bound: it came up on the value in the table")
    db.frameWidth = 275
    row.Refresh()
    eq(w._value, 275, "bound: and a refresh re-reads it, which is how the two follow each other")
end

-- ---- 24.8 the strip is the tether -----------------------------------
-- The panel opens to the RIGHT of the window and the strip's chevron points at
-- it, so the beam has to leave the STRIP rather than the middle of a plate that
-- may now be three lines tall. Reused through tetherSource, so the outline, the
-- beam and the clip gate all describe one rect.
do
    local win = window()
    local plain = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "NoStrip", db = { on = true }, count = 2,
        build = counting("tetherplain", 50), window = win,
    }), 60)
    plain:OpenPopout()
    eq(plain.popout.tetherSource, plain, "tether: a row without a strip tethers to the row")
    -- ...and it wears the shell's outline, because it declares no objection to
    -- one. Every source that says nothing is untouched by the decline below.
    check(plain.popout.srcOutline:IsShown(), "tether: ...and the outline is traced on it")
    check(plain.popout.srcOutline._pxColor ~= nil,
        "tether: a square plate declares no curve, so it gets the pixel border")
    -- ...and it goes away before the next one opens: every row on a host shares
    -- ONE pooled panel, and a panel adopted from another row keeps the outline it
    -- was already anchored on.
    plain:ClosePopout()

    -- The same row with a CURVE declared gets the RING, exactly as before. The
    -- decline is a third answer to "what shape is this source", not a rename of
    -- either of the two that already existed.
    local round = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "NoStripRound", db = { on = true }, count = 2, surface = R8,
        build = counting("tetherround", 50), window = win,
    }), 20)
    round:OpenPopout()
    local ring = UI:GetRoundedSurface(round.popout.srcOutline)
    check(ring ~= nil and ring:IsShown(),
        "tether: a plate that declares a radius still gets a ring at it")
    round:ClosePopout()

    local row = stripRow({ label = "Tethered", count = 2, window = win, footerStrip = true })
    row:OpenPopout()
    local po = row.popout
    eq(po.tetherSource, row.footerStrip,
        "tether: a row WITH one tethers to the strip -- the way in, not the title")
    -- ☠ ...AND THE STRIP DECLINES THE OUTLINE. Reported in game as
    -- "selected rows have hard corners on the bottom, not curved": the shell has
    -- two paints for a source, a square pixel border and a full ring, and this
    -- band is square where it meets the plate's interior and round where it IS
    -- the plate's bottom edge. Neither one describes it, so the strip says so on
    -- the tether contract and the shell draws nothing.
    eq(rawget(row.footerStrip, "popoutOutline"), false,
        "tether: the strip declines the outline on the tether contract")
    check(not po.srcOutline:IsShown(),
        "tether: ...so nothing is traced round the strip's curved foot")
    -- ⚠ THE DECLINE IS THE OUTLINE'S ALONE. The beam and the connection
    -- point say where the panel came from, which is still true -- and the strip
    -- is still the one rect all three of the shell's readers describe.
    check(po.beam:IsShown(), "tether: the beam still leaves the strip")
    check(po.notch:IsShown(), "tether: ...and so does the connection point")

    row:ClosePopout()
end

-- ---- 24.9 the strip's paint -----------------------------------------
do
    local win = window()
    local row = stripRow({ label = "Painted", count = 3, window = win, footerStrip = true })
    local fill, line = row._stripFill, row._stripLine
    check(fill ~= nil and line ~= nil, "paint: the strip has a wash and a hairline above it")
    -- A RAISED band, not a hole: C_ELEMENT (0.18) over a 0.12 plate. The hole --
    -- C_BACKGROUND at half alpha -- was more black on black in game and the strip
    -- vanished into the window ("blends into the black background too much").
    eq(fill._fill.r, UI.Colors.element.r, "paint: at rest the wash is a raised band, lighter than the plate")
    eq(fill._fill.a, M.footerFill, "paint: ...at the theme's own alpha")
    eq(line._fill.r, UI.Colors.border.r, "paint: and the hairline is the border token")
    local acc = host:GetAccent()
    eq(row.gear._vertex.r, acc.r, "paint: the cog is drawn in the accent, because it is the way in")
    eq(row.chevron._vertex.r, acc.r, "paint: ...and the chevron with it")

    row:OpenPopout()
    eq(fill._fill.r, acc.r, "paint: with the panel open the strip lights in the accent")
    eq(fill._fill.a, M.footerOn, "paint: ...at the open alpha, brighter than the plate's wash")
    eq(line._fill.r, acc.r, "paint: and the hairline goes with it")
    row:ClosePopout()
end

-- ---- 24.10 the strip's SHAPE: square top, round bottom ---------------
-- ☠ THE SHAPE Round.lua DOES NOT BAKE, MADE FROM THE ONE IT DOES. The strip runs
-- to the plate's bottom edge, so on a rounded plate its wash has to be square
-- where it meets the plate's interior and curved where it IS the plate's edge.
-- The generator bakes all-four and top-two only; the first try dodged it by
-- insetting the wash 4px off the arc, and in game that read as a floating bar
-- sitting inside the plate rather than as the plate's own foot.
--
-- So: a CLIP frame the strip's height, holding an all-four-corners surface that
-- is taller than the clip and anchored to its BOTTOM. The clip eats the overhang
-- and the top curve with it.
do
    local win = window()

    -- The SQUARE arm first -- the row every section above builds. One flat quad,
    -- flush, no clip involved at all.
    local sq = stripRow({ label = "Square", count = 3, window = win, footerStrip = true })
    check(sq._stripFill:IsShown(), "shape: a square plate paints the strip as one flat quad")
    check(not sq._stripClip:IsShown(), "shape: ...and does not use the clip")
    eq(sq._stripFill._points[1][4], 0, "shape: flush with the strip's left edge")
    eq(sq._stripFill._points[2][4], 0, "shape: ...and with its right")

    -- ...and the ROUNDED arm.
    local rd = stripRow({ label = "Round", count = 3, window = win, footerStrip = true,
                          surface = UI.SurfaceStyle })
    local clip, shape = rd._stripClip, rd._stripShape
    check(rd._surface ~= nil, "shape: the row took the rounded style it was handed")
    check(not rd._stripFill:IsShown(), "shape: the flat quad steps aside")
    check(clip:IsShown(), "shape: ...and the clip takes over")
    check(clip:DoesClipChildren(), "shape: the clip actually clips")
    -- ☠ SIZED BEFORE THE SHAPE WENT IN IT. SetClipsChildren clips at the frame's
    -- own RECT, and a holder anchored inside a clip with no resolved height is
    -- measured against nothing -- the surface would be stretched over a zero rect
    -- and never appear.
    eq(clip:GetHeight(), FOOTER_H - 1, "shape: the clip is the strip's own height, resolved")
    check(clip:GetHeight() > 0, "shape: ...and NOT zero, which is what a clip must never be")

    eq(shape:GetParent(), clip, "shape: the rounded surface's holder is INSIDE the clip")
    check(shape:GetHeight() > clip:GetHeight(),
        "shape: and it is taller than the clip -- the overhang is what removes the top corners")
    check(M.stripArc >= 8,
        "shape: the overhang is at least the largest radius Round.lua bakes, or a nick of arc survives")
    eq(shape._points[1][1], "BOTTOMLEFT", "shape: anchored by its BOTTOM, so the bottom curve is the one kept")
    eq(shape._points[2][1], "BOTTOMRIGHT", "shape: ...both corners of it")

    -- FULL WIDTH, less the plate's own border weight and nothing more. The 4px
    -- clearance is what made the first try read as a bar floating in the plate.
    local bw = UI.SurfaceStyle.rowBorderWidth
    eq(shape._points[1][4], bw, "shape: inset by the plate's border weight, so the ring survives")
    eq(shape._points[2][4], -bw, "shape: ...symmetrically")
    check(bw < UI.SurfaceEdgeInset(UI.SurfaceStyle.radius),
        "shape: which is far less than the arc clearance the inset version used")

    -- ☠ THE WASH DRAWS UNDER THE STRIP'S OWN REGIONS. The count, the cog and the
    -- chevron are regions on `strip`; the clip and the shape are child FRAMES of
    -- it, and a child frame's textures draw above every region of its parent
    -- whatever layer the region asked for. Left at its default level the wash
    -- painted straight over "3 more settings" -- in game the text read as nearly
    -- black and it looked like a colour problem. It was an order problem. The clip
    -- sits at the PLATE's level: above the plate's fill (same level, created
    -- later), below the strip (plate + 1) and everything drawn on it.
    do
        local lwin = window()
        local row  = stripRow({ label = "Levelled", count = 3, window = lwin, footerStrip = true })
        local clip = row._stripClip
        check(clip ~= nil, "level: the strip has its clip")
        eq(clip:GetFrameLevel(), row.plate:GetFrameLevel(),
           "level: the clip sits at the plate's level, under the strip's regions")
        check(clip:GetFrameLevel() < row.footerStrip:GetFrameLevel(),
           "level: ...and strictly below the strip, so the count text is drawn over the wash")
        -- ⚠ AND IT IS RE-ASSERTED, not set once. Re-level the plate the way a later
        -- pass might, re-apply the shape, and the clip must follow -- otherwise it is
        -- stranded under the plate's fill and the strip goes plain grey.
        row.plate:SetFrameLevel(row.plate:GetFrameLevel() + 5)
        row._ApplyStripShape()
        eq(clip:GetFrameLevel(), row.plate:GetFrameLevel(),
           "level: ...and follows the plate when the shape is re-applied")
    end

    -- ⚠ NEITHER FRAME TAKES THE MOUSE. Both lie over the strip, the strip lies
    -- over the plate, and the whole row is the click target.
    eq(rawget(clip, "_flags").mouse, false, "shape: the clip takes no mouse")
    eq(rawget(shape, "_flags").mouse, false, "shape: ...nor its holder")

    local surf = UI:GetRoundedSurface(shape)
    check(surf ~= nil, "shape: a rounded surface was actually issued on the holder")
    eq(surf:GetShape(), "all", "shape: as the ALL-FOUR art -- the clip makes the other two square")
    eq(surf:GetRadius(), UI.SurfaceStyle.radius, "shape: on the plate's own curve")
    check(not surf.hasBorder, "shape: with no ring -- the plate already draws one round the row")
    local sr, _, _, sa = surf:GetFillColor()
    eq(sr, UI.Colors.element.r, "shape: at rest the wash is a raised band, lighter than the plate")
    eq(sa, M.footerFill, "shape: ...at the theme's own alpha")

    -- ...and the one paint path reaches BOTH shapes: open the panel and the
    -- rounded wash lights exactly as the flat one does.
    rd:OpenPopout()
    local ar, _, _, aa = surf:GetFillColor()
    eq(ar, (rd._accent or host:GetAccent()).r, "shape: an open row lights the rounded wash too")
    eq(aa, M.footerOn, "shape: ...at the open alpha")
    rd:ClosePopout()
end

-- ---- 24.11 a strip row's title line says nothing but "Off" ----------
-- ☠ THE CORNER TEXT MADE NO SENSE ON ITS OWN. For one pass the summary was
-- DERIVED -- it named only what the plate did not show ("Spacing 2") -- and in
-- game that fragment sat in the top-right corner with nothing to explain it:
-- "makes no sense on its own and feels out of place". A strip row that is ON
-- now paints NO summary at all: the controls beneath say what the row is, the
-- strip says there is more. The one word that earns the corner is "Off".
--
-- ⚠ KEYED ON THE STRIP, NOT THE HOISTS. Frame Fade has a strip and nothing
-- hoisted, and it was showing "Alpha 0.30 · Combat 1.00" -- the row the
-- feedback named. And a row WITHOUT a strip -- every other page -- keeps its
-- summary byte for byte, which the last block below pins.
do
    local win = window()
    local db = { on = true, frameWidth = 100, frameHeight = 50, spacing = 2 }
    local called = 0
    local function summary(d)
        called = called + 1
        return "100x50 Spacing 2"          -- a consumer that STILL returns text
    end

    -- A strip row with nothing hoisted: on -> nothing, even though the consumer
    -- handed back a string.
    local row = stripRow({ label = "Quiet", db = db, count = 5, window = win,
                           footerStrip = true, summary = summary, toggle = { key = "on" } })
    eq(row.summary:GetText(), "",
        "summary: a strip row that is on paints nothing on its title line")

    -- ...and hoisting changes nothing about that: still nothing, at any width.
    row:SetHoistedControls(twoSliders(db, {}))
    widen(row, 401)
    eq(row.summary:GetText(), "", "summary: ...hoisted or not")
    widen(row, LABEL_X + M.padX + MIN_CONTROL - 1)
    eq(row:GetShownHoistCount(), 0, "summary: the row folded")
    eq(row.summary:GetText(), "",
        "summary: ...and folding does not bring the fragment back")

    -- OFF is the one word that earns the corner.
    row._Write(false)
    eq(row.summary:GetText(), "Off", "summary: a strip row that is switched off still says so")
    row._Write(true)
    eq(row.summary:GetText(), "", "summary: ...and goes quiet again when switched back on")

    -- ☠ A ROW WITHOUT A STRIP KEEPS ITS SUMMARY. This is every other page, and
    -- it must not have moved. Asserted on the strip's absence FIRST, so that if
    -- the helper ever grows a strip by default this fails on the premise rather
    -- than passing on a row that quietly had one.
    -- Built DIRECTLY, not through stripRow(): that helper assumes a strip frame
    -- exists to size, and on a strip-less row the field resolves to a function.
    local plain = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Loud", db = db, count = 5, window = win,
        build = counting("hoistLoud", 50), summary = summary, toggle = { key = "on" } })
    plain:SetWidth(260); plain:SetFakeCenter(CX - 100, CY); plain:Show()
    check(not (type(plain.footerStrip) == "table" and plain.footerStrip.SetSize),
        "summary: the comparison row has no strip frame")
    eq(plain.summary:GetText(), "100x50 Spacing 2",
        "summary: a row without a strip still paints its summary, byte for byte")
    plain._Write(false)
    eq(plain.summary:GetText(), "Off", "summary: ...and its off word, as it always did")
end

-- ---- 24.12 the hoisted control's tooltip, and where its rect lands ----
-- The first try shipped these with NO tooltip: the factory lays its hover rect
-- over the CAPTION, this cell hides the caption, and the rect therefore landed
-- in the title line (slider) or on the opener (inline dropdown). Taking it down
-- fixed the click and lost the explanation.
--
-- What is pinned here is the replacement: the rect rides the cell's NAME TIER,
-- it is as wide as the WORDS rather than as wide as the lane, it never reaches
-- the tier the control is in, and it exists at all only for a declaration that
-- has something to say.
--
-- ⚠ WHAT THIS CAN SEE. Fake frames record anchors instead of resolving them, so
-- the non-overlap below is arithmetic on the recorded offsets, in cell-local
-- coordinates measured DOWN from the cell's top -- the same way 24.4 reasons
-- about the track. The tier heights are the theme's own.
do
    local win = window()
    local db = { on = true, growDirection = "HORIZONTAL", frameWidth = 100 }
    local TIP = "The shape each line of frames takes."
    local row = stripRow({ label = "Explained", db = db, count = 4,
                           window = win, footerStrip = true })
    row:SetHoistedControls({
        { name = "Growth Direction", kind = "dropdown", key = "growDirection", db = db,
          options = { _order = { "HORIZONTAL" }, HORIZONTAL = "Rows" }, tooltip = TIP },
        { name = "Frame Width", kind = "slider", key = "frameWidth", db = db,
          min = 60, max = 300, step = 1 },
    })
    widen(row, 401)
    eq(row:GetShownHoistCount(), 2, "tip: both declarations are on the plate")

    local dd, sl = row._hoists[1], row._hoists[2]

    -- ☠ THE PREMISE, ASSERTED BEFORE ANYTHING IS ANCHORED TO IT. A frame with no
    -- resolved height silently misplaces a child anchored to both its corners, so
    -- "the name tier has a height" is the thing the rest of this section stands
    -- on rather than something it assumes.
    eq(dd.nameBox:GetHeight(), NAME_H, "tip: the name tier has a resolved height to anchor into")

    -- ---- the declaration that says something --------------------------
    eq(dd.control.tooltip, TIP, "tip: the declaration's words reach the widget that shows them")
    local hit = rawget(dd.control, "dfTooltipHit")
    check(hit ~= nil, "tip: ...and it has a rect to show them from")
    eq(hit:GetParent(), dd.nameBox,
        "tip: built ON the name tier, so its level is relative to the thing it covers")
    eq(hit:GetFrameLevel(), dd.nameBox:GetFrameLevel() + 1, "tip: ...one above it")
    -- ☠ MOTION, NEVER CLICKS -- the whole of the bug this replaced. A rect that
    -- takes clicks over a control eats them, and this class has shipped three
    -- times in this codebase.
    eq(hit._flags.mouseMotion, true, "tip: it hovers")
    eq(hit._flags.mouseClick, false, "tip: ...and it can never eat a click")

    -- ---- where it lands, in cell-local units --------------------------
    -- The layout re-points it to the tier's left edge and gives it the WORDS'
    -- width, so the hole in the row's own click target is the name and not the
    -- lane. The lane is the whole cell because the FontString is stretched
    -- across it to truncate.
    eq(hit._points[1][1], "TOPLEFT", "tip: re-pointed to the tier's top left")
    eq(hit._points[1][2], dd.nameBox, "tip: ...on the tier")
    eq(hit._points[2][1], "BOTTOMLEFT", "tip: and its bottom left")
    eq(hit._points[2][2], dd.nameBox, "tip: ...on the tier again, so its WIDTH is its own")
    local cellW = dd.control:GetWidth()
    check(hit:GetWidth() <= cellW,
        "tip: the rect is never wider than the cell it is in")
    eq(hit:GetWidth(), dd.nameText:GetStringWidth(),
        "tip: it is as wide as the WORDS, which is the whole size of the hole")
    check(hit:GetWidth() < cellW,
        "tip: ...and that is strictly less than the lane, which is the point of measuring it")

    -- ---- and it never reaches the control -----------------------------
    -- Both tiers, in cell-local coordinates measured DOWN from the cell's top.
    -- ⚠ THE RECT'S OWN EXTENT IS DERIVED FROM WHAT THE LAYOUT ANCHORED IT TO, not
    -- assumed to be the name tier -- otherwise every line below would still pass
    -- with the rect laid over the whole cell.
    local hitBox = hit._points[1][2]
    local hitBottom = hitBox:GetHeight()
    eq(hitBottom, NAME_H, "tip: the rect is exactly the name tier deep, and no deeper")
    -- The dropdown's opener is anchored TOPRIGHT into the control tier.
    local ddTop = -(dd.control._points[1][5])
    check(ddTop >= hitBottom,
        "tip: the opener starts at or below the tier the rect is in -- no overlap")
    eq(ddTop, NAME_H + (CONTROL_H - M.dropdownH) / 2, "tip: ...centred in the control tier")
    -- ☠ THE SLIDER'S CONTAINER *DOES* CROSS THE TIER, and that is not the same
    -- question. Its top 18px are the caption this cell hides -- dead space, which
    -- is exactly why the container is centred by its BAR. What must not be
    -- reached is the LIVE part: the bar and the 20px value box, whose middle is
    -- sliderBarMid below the container's top.
    local slTop = -(sl.control._points[1][5])
    local barMid = slTop + M.sliderBarMid
    local liveTop = barMid - 10          -- half the 20px value box
    check(liveTop >= hitBottom,
        "tip: and a slider's live rect starts below the name tier too")
    check(slTop < hitBottom,
        "tip: ...even though its CONTAINER crosses the tier, which is why the bar is what is measured")

    -- ---- the declaration that says nothing ----------------------------
    eq(rawget(sl.control, "dfTooltipHit"), nil,
        "tip: a declaration with no tooltip builds no rect, so it costs the row nothing")
    check(sl.control._sliderOpts.noTooltipHit == true,
        "tip: ...said to the factory, not undone afterwards")
    eq(sl.control._sliderOpts.tooltipHit, nil, "tip: ...and pointed at nothing")

    -- ---- and the layout re-seats it ------------------------------------
    -- The cell width is what decides both the clamp and the placement, so the
    -- re-seat has to run again when the row narrows to one cell per line.
    --
    -- ☠ AND THE LEVEL IS RE-STATED, NOT SET ONCE. A rect built at "one above the
    -- tier" is only above the tier until something re-levels the plate -- which
    -- this row does whenever its shape changes (_ApplyStripShape re-levels the
    -- strip off the plate on every surface change). Driven by moving the tier
    -- underneath it and re-placing: a rect that kept its build-time number would
    -- be BELOW the name it is meant to sit over.
    dd.nameBox:SetFrameLevel(50)
    widen(row, 260)
    eq(row:GetShownHoistCount(), 2, "tip: narrowed to one cell a line, both are still drawn")
    eq(hit:GetFrameLevel(), 51, "tip: the rect is re-levelled off the tier after the re-place")
    check(hit:GetWidth() <= dd.control:GetWidth(),
        "tip: ...and still no wider than the cell it now sits in")
    check(hit:GetWidth() > 0, "tip: ...and it did not lose its width to the re-place")
end

-- ---- 24.13 who gets told when the plate's set of keys moves ---------
-- ☠ THE PANE BEHIND THE ROW HAS TO LOSE ITS COPY of any control the plate has
-- taken over: the strip promised "3 more settings" and the panel then opened
-- with five, two of them the sliders the user had just looked at. The kit's half
-- of that is this hook -- `row:SetOnShownKeysChanged(fn)`, fired from the LAYOUT
-- rather than from the refresh, because the fold, the split and the gate are all
-- WIDTH and a window drag runs the layout alone.
--
-- ⚠ ON MEMBERSHIP, NOT ON PLACEMENT. The row's other signature (row._hoistSig)
-- carries the cell WIDTH, which moves on every frame of a window drag while the
-- set of keys does not move at all -- announcing on that one would re-flow the
-- open panel throughout the drag. So a width change that keeps the same keys has
-- to announce NOTHING, which is the assertion this block exists for.
--
-- The kit knows nothing about what the keys MEAN; it hands over the set and the
-- consumer decides. What the CONSUMER does with it -- the pane hide, the count
-- that has to agree with it -- is driven in test_popout_page_tools.lua.
local function keyList(keys)
    local names = {}
    for k in pairs(keys) do names[#names + 1] = k end
    table.sort(names)
    return table.concat(names, ",")
end

do
    local win = window()
    local db = { on = true, frameWidth = 100, frameHeight = 50 }
    local row = stripRow({ label = "Told", db = db, count = 5, window = win,
                           footerStrip = true, toggle = { key = "on" } })

    -- Wired BEFORE anything is hoisted, which is the order the Frame page uses:
    -- it claims its keys (and wires this) before it declares its hoists.
    local seen = {}
    local ret = row:SetOnShownKeysChanged(function(_, keys) seen[#seen + 1] = keyList(keys) end)
    eq(ret, row, "told: the setter is chainable, like every other one on this row")
    eq(#seen, 0, "told: a row with nothing hoisted announces nothing on the way in")

    -- The declaration is the first thing that puts keys on the plate, and it
    -- lays the row out itself rather than waiting for a width to move.
    row:SetHoistedControls(twoSliders(db, {}))
    eq(row:GetShownHoistCount(), 2, "told: both cells are drawn at the row's build width")
    eq(#seen, 1, "told: ...and the consumer was told exactly once")
    eq(seen[1], "frameHeight,frameWidth", "told: ...with both keys on the plate")

    -- ☠ A WIDTH-ONLY DRAG SAYS NOTHING. 401 puts the pair on ONE line, 260 stacks
    -- them on two -- a different placement, at a different cell width, of exactly
    -- the same two keys.
    widen(row, 401)
    eq(row:GetShownHoistCount(), 2, "told: a generous width puts both on one line")
    eq(#seen, 1, "told: ...and says nothing, because nothing joined or left")
    widen(row, 260)
    eq(row:GetShownHoistCount(), 2, "told: narrowing to one cell a line still draws both")
    eq(#seen, 1, "told: ...and still says nothing")

    -- THE FOLD, which is the something-to-EMPTY case: below the floor there is no
    -- control left to draw, and the pane's copies have to come back.
    widen(row, LABEL_X + M.padX + MIN_CONTROL - 1)
    eq(row:GetShownHoistCount(), 0, "told: under the floor the row folds")
    eq(#seen, 2, "told: ...and folding to nothing IS an announcement")
    eq(seen[2], "", "told: ...carrying an empty set")

    -- ...and widening past the floor brings them back, once.
    widen(row, 401)
    eq(#seen, 3, "told: widening past the floor announces the keys again")
    eq(seen[3], "frameHeight,frameWidth", "told: ...both of them")

    -- The set handed over is the row's OWN live table, which is why the contract
    -- says read it and never keep it: the next layout clears and refills it.
    local held
    row:SetOnShownKeysChanged(function(_, keys) held = keys end)
    local first = held
    check(first ~= nil, "told: a consumer wired late is handed the set at once")
    widen(row, LABEL_X + M.padX + MIN_CONTROL - 1)
    eq(held, first, "told: every announcement hands back the same table")
    eq(next(held), nil, "told: ...which the fold has already emptied")

    -- ...and a consumer can be taken off again.
    row:SetOnShownKeysChanged(nil)
    held = "untouched"
    widen(row, 401)
    eq(held, "untouched", "told: clearing the hook stops the announcements")
end

-- THE GATE is the other way a key leaves the plate with the width standing still
-- -- and it is the path a USER takes, through the row's own write.
do
    local win = window()
    local db = { on = false, moverW = 40, moverH = 20 }
    local function gate(d) return (d or db).on and true or false end
    local row = stripRow({ label = "Gated told", db = db, toggle = { key = "on" },
                           count = 5, window = win, footerStrip = true })
    row:SetHoistedControls({
        { name = "Handle Width", kind = "slider", key = "moverW", db = db,
          min = 5, max = 500, step = 1, visible = gate },
        { name = "Handle Height", kind = "slider", key = "moverH", db = db,
          min = 5, max = 500, step = 1, visible = gate },
    })
    widen(row, 401)
    eq(row:GetShownHoistCount(), 0, "told: a gated-off feature draws nothing")

    -- ⚠ WIRED WITH THE PLATE EMPTY, so there is nothing to say and nothing is
    -- said -- the immediate call is for a consumer that arrived LATE to a plate
    -- that already had keys on it, not a way of announcing an empty set twice.
    local seen = {}
    row:SetOnShownKeysChanged(function(_, keys) seen[#seen + 1] = keyList(keys) end)
    eq(#seen, 0, "told: nothing on the plate, nothing announced")

    row._Write(true)
    eq(row:GetShownHoistCount(), 2, "told: switching the feature on brings its controls out")
    eq(#seen, 1, "told: ...which the consumer is told about")
    eq(seen[1], "moverH,moverW", "told: ...by name")
    row._Write(false)
    eq(row:GetShownHoistCount(), 0, "told: and switching it off takes them away again")
    eq(#seen, 2, "told: ...which is an announcement of its own")
    eq(seen[2], "", "told: ...with an empty set, so the pane's copies come back")
end

-- ---- 24.14 THE ROW TELLS ITS CONSUMER WHEN A PANEL IS PINNED ---------
-- ☠ A PINNED PANEL IS NOT ABOUT THIS ROW ANY MORE. Pinning is the gesture
-- that detaches a panel from the row it came out of, and the user pins one in
-- order to CHANGE PAGE -- at which point the row, and the width and height
-- sliders on its plate, are not on screen at all. A consumer that leaves
-- settings out of a panel because the plate is showing them (24.13, and the
-- pane hide it drives in test_popout_page_tools.lua) has to put them back for
-- that one instance, so the row says when.
--
-- The kit still knows nothing about what any of it MEANS: it names the row and
-- the instance, and the consumer decides.
do
    local win = window()
    local db = { on = true, frameWidth = 100, frameHeight = 50 }
    local row = stripRow({ label = "Pinned told", db = db, count = 5, window = win,
                           footerStrip = true, toggle = { key = "on" } })
    row:SetHoistedControls(twoSliders(db, {}))

    local seen = {}
    local ret = row:SetOnPanelPinned(function(r, po)
        -- The per-host store, read AT THE MOMENT OF THE CALL -- see below for
        -- why the two flags matter more than the fact of the call.
        local s = rawget(host, "_popoutRows")
        seen[#seen + 1] = { row = r, po = po, detached = po:IsPinned(),
                            unshared = (s.shared[po.key] ~= po),
                            listed   = (s.pinned[#s.pinned] == po) }
    end)
    eq(ret, row, "pinned: the setter is chainable, like every other one on this row")
    -- ⚠ NO IMMEDIATE CALL, unlike the shown-keys hook. There is nothing to
    -- catch up on: a panel pinned before the consumer was wired had no consumer
    -- to leave anything out for it either.
    eq(#seen, 0, "pinned: wiring it announces nothing")

    row:OpenPopout()
    local po = row.popout
    eq(#seen, 0, "pinned: ...and opening a panel is not pinning one")

    po:Pin()
    eq(#seen, 1, "pinned: pinning tells the consumer, once")
    eq(seen[1].row, row, "pinned: ...naming the row")
    eq(seen[1].po, po, "pinned: ...and the instance that was pinned, not just any of them")
    -- ☠ AND IT ARRIVES AFTER THE DETACHMENT, not during it. The consumer
    -- reacts by re-flowing this very panel, and everything it reads -- the pin
    -- flag, the row's own bookkeeping -- has to be finished first.
    eq(seen[1].detached, true, "pinned: ...by which time the panel already reports itself pinned")
    -- ⚠ AND WHAT A STRIP SOURCE HAS IS NO OUTLINE AT ALL. This row tethers
    -- to its footer strip, and a strip DECLINES the source outline outright
    -- (section 17.1) -- so the popout never builds one, and `po.srcOutline` here
    -- is whatever an earlier section left on the pooled instance. Reading it
    -- straight passed by luck. The honest claim is the declaration plus the
    -- absence: the source says no, and nothing is traced on it.
    eq(rawget(row.footerStrip, "popoutOutline"), false,
       "pinned: the strip this panel tethers to declines the outline")
    check(not (po.srcOutline and po.srcOutline:IsShown()),
          "pinned: ...so there is none traced on it, pinned or otherwise")
    check(not po.beam:IsShown(), "pinned: ...and its beam is down too")
    -- ...AND THE ROW'S OWN BOOKKEEPING IS FINISHED TOO. The consumer re-flows
    -- this very panel, and a re-flow that ran while the store still listed it as
    -- the SHARED instance would be laying out the panel the next click adopts.
    eq(seen[1].unshared, true, "pinned: ...and the store has already let go of it as the shared one")
    eq(seen[1].listed, true, "pinned: ...and already lists it among the pinned")

    -- ⚠ PER ROW, AND PER INSTANCE. Pinning promoted that panel out of the
    -- pool, so the next row to click gets a fresh one -- and what happens to THAT
    -- one is its own row's business. A consumer told about a panel it never had
    -- would put settings back into a panel that is still hiding them correctly.
    local other = stripRow({ label = "Pinned other", db = db, count = 5, window = win,
                             footerStrip = true, toggle = { key = "on" } })
    other:OpenPopout()
    check(other.popout ~= po, "pinned: the next row to click gets a fresh instance")
    other.popout:Pin()
    eq(#seen, 1, "pinned: ...and pinning that one says nothing to this row's consumer")

    -- ...and a consumer can be taken off again.
    local quiet = stripRow({ label = "Pinned quiet", db = db, count = 5, window = win,
                             footerStrip = true, toggle = { key = "on" } })
    local told = 0
    quiet:SetOnPanelPinned(function() told = told + 1 end)
    quiet:SetOnPanelPinned(nil)
    quiet:OpenPopout()
    quiet.popout:Pin()
    eq(told, 0, "pinned: clearing the hook stops the announcements")

    host:CloseAllPopoutRows("test")
end

-- ---- 24.15 THE STRIP'S NUMBER CAN COME FROM SOMEWHERE ELSE ---------
-- ☠ A DECLARED COUNT CANNOT FOLLOW THE MODE. The Layout Direction pane
-- mounts a Growth Direction dropdown per mode (one hideOn-gated away) plus a
-- party-only anchor, so its declared 3 less one hoisted control promised "2
-- more settings" over a pane holding exactly ONE control in party and none at
-- all in raid. The row cannot see its own pane; the consumer that built it can,
-- so it answers the number instead -- and the arithmetic is then not consulted.
--
-- ⚠ ROWS WITHOUT ONE ARE UNTOUCHED. Every other page keeps opts.count and
-- the subtraction, which is what 24.2 through 24.7 above are all still saying.
do
    local win = window()
    local db = { on = true, frameWidth = 100, frameHeight = 50 }
    local row = stripRow({ label = "Derived", db = db, count = 5, window = win,
                           footerStrip = true, toggle = { key = "on" } })
    eq(row.stripCount:GetText(), "5 more settings",
       "derived: the declared count, while nothing else answers for it")

    local behind = 4
    local ret = row:SetCountProvider(function() return behind end)
    eq(ret, row, "derived: the setter is chainable, like every other one on this row")
    eq(row.stripCount:GetText(), "4 more settings",
       "derived: ...and a provider is painted the moment it is wired")

    -- ☠ IT REPLACES THE ARITHMETIC, it is not another term in it. The
    -- consumer already counts the pane with the hoisted controls hidden, so
    -- subtracting them again here would take them off twice.
    row:SetHoistedControls(twoSliders(db, {}))
    eq(row:GetShownHoistCount(), 2, "derived: two controls on the plate")
    eq(row.stripCount:GetText(), "4 more settings",
       "derived: ...and the strip says what the provider says, not four less two")

    -- REPAINTED FROM THE LAYOUT, which is the pass a fold and a gate both run.
    behind = 3
    row._LayoutPlate()
    eq(row.stripCount:GetText(), "3 more settings", "derived: the layout re-asks")
    -- ...and from the refresh, which is the pass a write runs.
    behind = 1
    row.Refresh()
    eq(row.stripCount:GetText(), "1 more settings", "derived: ...and so does the refresh")

    -- ZERO, WITH THE PLATE HOLDING SOMETHING. There is nothing left behind the
    -- click, but the settings on the plate are still worth having beside another
    -- page -- so the corner stops promising a count and offers the way to keep
    -- them: a pinned panel. The words ARE the confirmation for the click.
    behind = 0
    row._LayoutPlate()
    eq(row.stripCount:GetText(), "Pin settings in popout",
       "derived: an empty pane offers to pin instead of promising nothing")

    -- ...and the moment there is something behind the click again the phrase
    -- comes back. A gate, a mode switch or a fold can all do it.
    behind = 2
    row.Refresh()
    eq(row.stripCount:GetText(), "2 more settings",
       "derived: ...and the count phrase returns when the pane fills again")

    -- ☠ ZERO AND AN EMPTY PLATE IS NOT THE PIN CASE, and the honest words
    -- there are the count. Pinning is an offer to keep the ROW'S OWN controls
    -- open somewhere else; with the row folded there are none, so the panel it
    -- pinned would be as empty as the one it refused to open. "0 more settings"
    -- says the true thing: there is nothing behind this click.
    behind = 0
    widen(row, LABEL_X + M.padX + MIN_CONTROL - 1)
    eq(row:GetShownHoistCount(), 0, "derived: under the floor the row folds")
    eq(row.stripCount:GetText(), "0 more settings",
       "derived: ...and an empty pane behind an empty plate is not an offer to pin")

    -- ...and a provider can be taken off again, which hands the row back to its
    -- own arithmetic -- five declared, none on the plate.
    row:SetCountProvider(nil)
    eq(row.stripCount:GetText(), "5 more settings",
       "derived: clearing the provider gives the declared count back")
end

-- ⚠ AND NOTHING ON THE TITLE LINE MOVES. The badge pill is opts.count and
-- stays opts.count: a provider is about the STRIP's phrase, and a row without a
-- strip has no phrase to paint. Built directly rather than through stripRow,
-- which exists to give a row its strip.
do
    local win = window()
    local row = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Plain provider", db = { on = true }, toggle = { key = "on" },
        count = 4, build = counting("plainprov", 50), window = win,
    }))
    row:SetCountProvider(function() return 0 end)
    eq(rawget(row, "stripCount"), nil, "derived: a title-line row has no count phrase")
    check(row.badgePill:IsShown(), "derived: ...its count is still a pill")
    eq(row.badge:GetText(), "4", "derived: ...carrying the DECLARED number, provider or no provider")
end

-- ---- 24.16 AN EMPTY PANE PINS ITSELF OPEN --------------------------
-- ☠ A LOOSE EMPTY PANEL IS NEVER OPENED. With every one of its settings on
-- the plate the panel has nothing left to draw, and a blank box docked beside
-- the row is not what the strip's words offered -- they offered to PIN them, so
-- the click that read them does it in one move. Pin(true) is AutoPin's silent
-- path: the confirm pop is feedback for a press on the pin button, and here the
-- strip's own words are the confirmation.
--
-- Driven against a REAL Popout, which is why it lives in this file: the page
-- half (Controls.lua wiring the provider to its pane group) is driven in
-- test_popout_page_tools.lua, which has no shell to pin against.
do
    local win = window()
    local db = { on = true, frameWidth = 100, frameHeight = 50 }

    -- ⚠ EACH ROW ON ITS OWN POPOUT KEY. The shell pools by key, so three
    -- rows sharing the default one would hand the same instance round between
    -- them -- and what is under test here is what an OPEN makes, not what an
    -- adopt reuses (24.14 owns that claim).
    -- WITH SOMETHING BEHIND THE CLICK the panel opens docked, exactly as before.
    local full = stripRow({ label = "Opens loose", db = db, count = 5, window = win,
                            popoutKey = "emptyopen.full",
                            footerStrip = true, toggle = { key = "on" } })
    full:SetCountProvider(function() return 3 end)
    full:SetHoistedControls(twoSliders(db, {}))
    full:OpenPopout()
    local loose = full.popout
    check(loose ~= nil, "empty open: a row with settings behind it opens a panel")
    check(not loose.pinned, "empty open: ...docked to the row, not pinned")
    check(loose.following, "empty open: ...and still following it")

    -- WITH NOTHING BEHIND IT the same click pins.
    local bare = stripRow({ label = "Pins itself", db = db, count = 5, window = win,
                            popoutKey = "emptyopen.bare",
                            footerStrip = true, toggle = { key = "on" } })
    bare:SetCountProvider(function() return 0 end)
    bare:SetHoistedControls(twoSliders(db, {}))
    eq(bare:GetShownHoistCount(), 2, "empty open: the plate is drawing both settings")
    eq(bare.stripCount:GetText(), "Pin settings in popout", "empty open: ...so the strip is offering")

    bare:OpenPopout()
    local po = bare.popout
    check(po ~= nil and po ~= loose, "empty open: the click brought up its own panel")
    eq(po.pinned, true, "empty open: ...already pinned, so nothing empty is left docked")
    check(not po.following, "empty open: ...detached from the row it came out of")
    -- Pinned chrome, which is no chrome: the two things that describe a dock.
    -- Guarded on existence, not just on Shown -- a strip declines the source
    -- outline outright (section 17.1), so a panel that never had one is the
    -- same answer as one that has put it away.
    check(not (po.srcOutline and po.srcOutline:IsShown()),
          "empty open: ...with no outline traced on the strip")
    check(not (po.beam and po.beam:IsShown()), "empty open: ...and no beam")
    -- ...and out of the pool, which is what Pin is for -- see 24.14.
    local store = rawget(host, "_popoutRows")
    check(store.shared[bare._key] ~= po, "empty open: ...and never listed as the shared instance")
    eq(store.pinned[#store.pinned], po, "empty open: ...it is listed among the pinned")

    -- ⚠ AND A SECOND CLICK RAISES THAT ONE. livePanel prefers a pinned panel,
    -- so the row does not make a second empty box -- the fresh pooled instance
    -- appears when the NEXT row asks for the key, not when this one is clicked
    -- again.
    bare:OpenPopout()
    eq(bare.popout, po, "empty open: clicking again raises the panel it already pinned")

    -- The row's own OnClick is the same path, which is what the user presses.
    local clicked = stripRow({ label = "Clicked", db = db, count = 5, window = win,
                               popoutKey = "emptyopen.clicked",
                               footerStrip = true, toggle = { key = "on" } })
    clicked:SetCountProvider(function() return 0 end)
    clicked:SetHoistedControls(twoSliders(db, {}))
    -- ⚠ THE STRIP'S CLICK, not the row's. Section 21 moved the way in onto the
    -- band along the bottom and the row's own OnClick returns early there -- but
    -- both ends of that split still run row:OpenPopout(), which is the point of
    -- doing it that way and is what this line is really about.
    clicked.footerStrip:GetScript("OnClick")(clicked.footerStrip)
    check(clicked.popout ~= nil, "empty open: the strip's click opens a panel")
    eq(clicked.popout.pinned, true, "empty open: ...and pins it, like the verb does")


    -- ☠ ZERO WITH AN EMPTY PLATE DOES NOT PIN EITHER, because the strip did
    -- not offer to. The two are one decision asked in one place: the words say
    -- what the click will do, and a click that pinned where the corner read "0
    -- more settings" would be answering a question nobody asked. There is
    -- nothing on the plate to keep open beside another page, which is the whole
    -- reason to pin.
    local nothing = stripRow({ label = "Nothing at all", db = db, count = 5, window = win,
                               popoutKey = "emptyopen.nothing",
                               footerStrip = true, toggle = { key = "on" } })
    nothing:SetCountProvider(function() return 0 end)
    eq(nothing:GetShownHoistCount(), 0, "empty open: nothing hoisted onto this plate")
    eq(nothing.stripCount:GetText(), "0 more settings", "empty open: ...so the strip is not offering")
    nothing:OpenPopout()
    check(nothing.popout ~= nil, "empty open: the click still opens a panel")
    check(not nothing.popout.pinned, "empty open: ...and leaves it docked, as the words said")
    host:CloseAllPopoutRows("test")
end

-- ---- 24.17 AND THE WORDS DO NOT MOVE WHEN THE PANEL IS PINNED ------
-- ☠ THE STRIP IS A PROMISE ABOUT WHAT A CLICK DOES, and pinning is the
-- thing the click DID. A corner that read "Pin settings in popout", was
-- clicked, and then flipped to a count would be describing a second panel
-- that is never coming: livePanel prefers a pinned one, so the next click
-- raises the very panel that is already open. Wrong words for a right click.
--
-- ⚠ THE ROW'S HALF OF IT, which is that the row adds nothing of its own on a
-- pin: it paints what the provider answers and does not fall back to its
-- declared arithmetic. What the CONSUMER answers across a pin -- the pane
-- counted as the loose panel would draw it, whatever the instance in hand is
-- doing -- is driven in test_popout_page_tools.lua, which owns Controls.lua.
do
    local win = window()
    local db = { on = true, frameWidth = 100, frameHeight = 50 }

    -- Declared NINE against a provider that says three, so the two can never be
    -- mistaken for one another: the arithmetic would be 9 - 2 = 7.
    local kept = stripRow({ label = "Words hold", db = db, count = 9, window = win,
                            popoutKey = "pinwords.kept",
                            footerStrip = true, toggle = { key = "on" } })
    kept:SetCountProvider(function() return 3 end)
    kept:SetHoistedControls(twoSliders(db, {}))
    eq(kept:GetShownHoistCount(), 2, "pin words: two controls on the plate")
    eq(kept.stripCount:GetText(), "3 more settings",
       "pin words: the provider's number, before any click")
    kept:OpenPopout()
    check(not kept.popout.pinned, "pin words: a pane with something in it opens docked")
    kept.popout:Pin()
    check(kept.popout.pinned, "pin words: ...and pins on the gesture")
    kept._LayoutPlate()
    eq(kept.stripCount:GetText(), "3 more settings",
       "pin words: ...and the layout repaints the same number over a pinned panel")
    kept.Refresh()
    eq(kept.stripCount:GetText(), "3 more settings", "pin words: ...as does the refresh")

    -- The OFFER, which is the phrase the click answered.
    local offer = stripRow({ label = "Offer holds", db = db, count = 9, window = win,
                             popoutKey = "pinwords.offer",
                             footerStrip = true, toggle = { key = "on" } })
    offer:SetCountProvider(function() return 0 end)
    offer:SetHoistedControls(twoSliders(db, {}))
    eq(offer.stripCount:GetText(), "Pin settings in popout",
       "pin words: an empty pane offers to pin")
    offer:OpenPopout()
    local pinned = offer.popout
    eq(pinned.pinned, true, "pin words: ...and the click that read it pins")
    offer._LayoutPlate()
    eq(offer.stripCount:GetText(), "Pin settings in popout",
       "pin words: ...and the offer reads the same once something repaints it")
    offer.Refresh()
    eq(offer.stripCount:GetText(), "Pin settings in popout",
       "pin words: ...and after a refresh")
    -- ...which is exactly what the unchanged words promise: the second click
    -- raises that panel rather than making a second empty one.
    offer:OpenPopout()
    eq(offer.popout, pinned, "pin words: the second click raises the panel it pinned")
    eq(offer.stripCount:GetText(), "Pin settings in popout",
       "pin words: ...with the corner still saying the one true thing about it")

    host:CloseAllPopoutRows("test")
end

-- ---- 24.18 the modified dot rides the NAME, and stays in the cell ----
-- ☠ THE DEFECT IT PINS. Widgets.lua anchors the amber modified-default dot at
-- the END OF THE CONTROL'S OWN CAPTION, re-anchored on every update -- and this
-- cell HIDES that caption and draws the setting's name in a tier of its own. So
-- the dot was measured off a rect nobody can see, which lies directly under the
-- name tier, and landed on the words: in game, on the T of "...EIGHT".
--
-- ⚠ AND THE CLAMP IS NOT OPTIONAL. GetStringWidth measures the WHOLE string, and
-- the name FontString is stretched across the cell precisely so it truncates --
-- so the untruncated width of a long name puts the dot outside the cell
-- entirely, which is a worse bug than the one being fixed.
do
    local win = window()
    local db = { on = true, frameWidth = 100, frameHeight = 50 }
    local modified = {}
    -- The consumer's engine, stubbed to a set of keys this test controls. A host
    -- that never publishes the hook draws no dot at all, which is what every
    -- other section in this file has been running against.
    host.hooks.isModifiedDefault = function(_, key)
        return key ~= nil and modified[key] == true
    end

    modified.frameWidth = true
    local row = stripRow({ label = "Marked", db = db, count = 5,
                           window = win, footerStrip = true })
    row:SetHoistedControls(twoSliders(db, {}))
    widen(row, 401)
    local cellW = math.floor((401 - LABEL_X - M.padX - CELL_GAP) / 2)
    eq(cellW, 172, "dot: the shipped default window's cell, as 24.4 measures it")

    local h1, h2 = row._hoists[1], row._hoists[2]
    local c1, nm1 = h1.control, h1.nameText
    check(c1.modifiedDot:IsShown(), "dot: a hoisted control whose key is modified shows one")
    local p = c1.modifiedDot._points[#c1.modifiedDot._points]
    check(p[2] == nm1, "dot: hung off the NAME the cell draws...")
    check(p[2] ~= c1.label, "dot: ...and NOT off the caption the cell hid")
    eq(p[1], "LEFT", "dot: by its own left edge")
    eq(p[3], "LEFT", "dot: measured from the name's own left")
    eq(p[5], 0, "dot: and on the name's line, which is what makes it read as the name's")
    local w1 = nm1:GetStringWidth()
    check(w1 < cellW - 10, "dot: 'FRAME WIDTH' fits the cell with room to spare")
    eq(p[4], w1 + 4, "dot: so it sits just past the end of the words, unclamped")
    check(p[4] + 6 <= cellW, "dot: ...and its right edge is inside the cell")
    -- The caption it is NOT on, stated as a rect: the hidden label carries the
    -- same words, so a dot that fell back to it would sit at the same x on a
    -- frame the user cannot see -- which is exactly how this shipped.
    eq(c1.label:GetText(), h1.name, "dot: the hidden caption carries the same words")
    check(not c1.label:IsShown(), "dot: ...and is hidden, which is why it cannot hold the mark")

    -- A CONTROL AT ITS SHIPPED VALUE SHOWS NOTHING. Same row, same pass.
    check(not h2.control.modifiedDot:IsShown(),
        "dot: a control still at its default shows none")

    -- ...and lights on the ROW'S OWN REFRESH when its key goes off default, with
    -- nothing invalidated by hand: the kit's value repaint re-answers the hook.
    modified.frameHeight = true
    row.Refresh()
    check(h2.control.modifiedDot:IsShown(), "dot: ...until its key moves, and then it lights")
    local p2 = h2.control.modifiedDot._points[#h2.control.modifiedDot._points]
    check(p2[2] == h2.nameText, "dot: on ITS OWN name, not the first cell's")

    -- ---- a name WIDER than the cell -------------------------------
    local wide = stripRow({ label = "Long name", db = db, count = 5,
                            window = win, footerStrip = true })
    wide:SetHoistedControls({
        { name = "Permanent Mover Handle Width", kind = "slider",
          key = "frameWidth", db = db, min = 60, max = 300, step = 1 },
    })
    widen(wide, 401)
    local lh = wide._hoists[1]
    local lc, lnm = lh.control, lh.nameText
    check(lnm:GetStringWidth() > cellW,
        "clamp: the name measures WIDER than the cell it is truncated into")
    local lp = lc.modifiedDot._points[#lc.modifiedDot._points]
    check(lp[2] == lnm, "clamp: still hung off the name")
    check(lp[4] < lnm:GetStringWidth() + 4,
        "clamp: ...but short of where the untruncated words would have put it")
    eq(lp[4], cellW - 6 - 4 + 4, "clamp: capped at the cell less the dot and its gap")
    eq(lp[4] + 6, cellW, "clamp: which lands the dot's RIGHT edge exactly on the cell's")

    -- ---- and it moves when the cell moves --------------------------
    -- A window drag changes the cell's width and writes NOTHING, so no value
    -- repaint will ever re-ask: the layout has to. At 260 the pair splits to one
    -- cell a line, the cell gets wider, and this name now fits inside the cap --
    -- which is the other half of the claim, that the cap is a ceiling and not a
    -- position.
    local before = lp[4]
    widen(wide, 260)
    local wideCell = 260 - LABEL_X - M.padX
    eq(wide._hoistCells[1]:GetWidth(), wideCell, "clamp: the split gave the cell the whole line")
    local sp = lc.modifiedDot._points[#lc.modifiedDot._points]
    check(sp[4] ~= before, "clamp: the dot moved with the cell, with nothing written")
    check(lnm:GetStringWidth() <= wideCell - 10, "clamp: the name now fits the wider cell...")
    eq(sp[4], lnm:GetStringWidth() + 4, "clamp: ...so the cap steps aside and the words decide")
    check(sp[4] + 6 <= wideCell, "clamp: still inside the cell")

    -- ...and back the other way, so the cap is not a one-way ratchet.
    widen(wide, 401)
    local bp = lc.modifiedDot._points[#lc.modifiedDot._points]
    eq(bp[4], cellW - 6, "clamp: narrowed again, and the cap takes over again")

    -- A repaint that is NOT a layout keeps the cap the layout left behind: the
    -- number lives on the control, so every other path that redraws the dot -- a
    -- drag, a reset, a profile switch -- gets it for free.
    wide.Refresh()
    local rp = lc.modifiedDot._points[#lc.modifiedDot._points]
    eq(rp[4], cellW - 6, "clamp: and a plain refresh redraws it at the same cap")

    host.hooks.isModifiedDefault = nil
    host:CloseAllPopoutRows("test")
end

-- ---- 24.19 THE STRIP IS THE ONLY WAY IN -----------------------------
-- ☠ THE REVERSAL, ASKED FOR AFTER LIVING WITH THE FIRST TRY: "the popout
-- should only be triggered from the bottom bar, same with the on hover highlight
-- instead of the whole row being clickable". A plate whose every square inch
-- opens a panel is a plate the cursor cannot rest on, and a whole row lighting
-- up wherever the cursor lands says nothing about where to press. So on a STRIP
-- ROW -- and nowhere else -- the strip owns the click and the strip is the only
-- thing that lights.
--
-- ⚠ ACTIVE IS UNTOUCHED. The accent plate wash, the accent hairline and the
-- beam are what say "the open panel is about THIS row", and that claim is about
-- the row, not about where the cursor happens to be.
do
    local win = window()
    local db = { on = true }
    local row = stripRow({ label = "Only the strip", db = db, count = 5, window = win,
                           popoutKey = "striponly.row",
                           footerStrip = true, toggle = { key = "on" } })
    local strip = row.footerStrip
    local fill  = row._stripFill

    -- ---- hover: the row's script still runs, the plate still does not move ----
    eq(row.plate._fill.r, UI.Colors.element.r, "only: the plate rests on the element fill")
    eq(row.plate._fill.a, M.restFill, "only: ...at the rest alpha")
    row:GetScript("OnEnter")()
    check(row._hovered, "only: hovering the ROW still sets its flag -- the script was not removed")
    eq(row.plate._fill.r, UI.Colors.element.r,
        "only: ...and the plate stays on the element fill anyway")
    eq(row.plate._fill.a, M.restFill, "only: at the REST alpha, not the hover one")
    eq(fill._fill.a, M.footerFill, "only: and the strip has not lit -- the cursor is not on it")

    -- ---- hover: the strip is what lights ------------------------------
    strip:GetScript("OnEnter")(strip)
    eq(fill._fill.r, UI.Colors.hover.r, "only: hovering the STRIP lifts it to the hover colour")
    eq(fill._fill.a, M.footerHover, "only: ...at the strip's own hover alpha")
    eq(row.plate._fill.a, M.restFill, "only: while the plate under it still has not moved")
    strip:GetScript("OnLeave")(strip)
    eq(fill._fill.r, UI.Colors.element.r, "only: leaving the strip puts the band back")
    eq(fill._fill.a, M.footerFill, "only: ...to its rest alpha")
    row:GetScript("OnLeave")()

    -- ---- click: the plate is inert ------------------------------------
    row:GetScript("OnClick")(row)
    eq(row.popout, nil, "only: a click on the PLATE opens nothing")
    eq(next(row._bound), nil, "only: ...and binds no panel to the row")

    strip:GetScript("OnClick")(strip)
    check(row.popout ~= nil, "only: the strip's click opens one")
    eq(row.popout.tetherSource, strip, "only: tethered to the strip, exactly as before")

    -- ---- active, and active + hover -----------------------------------
    local acc = host:GetAccent()
    eq(row.plate._fill.r, acc.r, "only: the open row's plate still takes the accent wash")
    eq(row.plate._fill.a, M.activeFill, "only: ...at the wash alpha -- ACTIVE did not change")
    eq(fill._fill.r, acc.r, "only: and the strip lights in the accent with it")
    eq(fill._fill.a, M.footerOn, "only: at the open alpha")
    -- ⚠ THE ROW'S OWN HOVER FLAG IS SET FOR THE NEXT LINE, which is what makes
    -- it a claim rather than a coincidence: the suppression has to hold on an OPEN
    -- row too, and paintState's active arm is a second place it could have been
    -- left out.
    row:GetScript("OnEnter")()
    eq(row.plate._fill.a, M.activeFill,
        "only: hovering an OPEN row's plate does not brighten the wash either")
    strip:GetScript("OnEnter")(strip)
    eq(fill._fill.r, acc.r, "only: hovering an OPEN strip keeps the accent")
    eq(fill._fill.a, M.footerOnHover, "only: ...and brightens it")
    check(M.footerOnHover > M.footerOn, "only: which is only feedback if the token is brighter")
    eq(row.plate._fill.a, M.activeFill,
        "only: and the plate under it still does not -- the row's hover lift is gone")
    strip:GetScript("OnLeave")(strip)
    eq(fill._fill.a, M.footerOn, "only: leaving settles the open strip back to the open alpha")
    row:GetScript("OnLeave")()
    row:ClosePopout()

    -- ---- and every unconverted row is untouched -----------------------
    -- ⚠ BUILT DIRECTLY, not through stripRow(): that helper hands the row a
    -- rect for a strip frame, which this one does not have.
    local plain = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Whole plate", db = { on = true }, count = 3,
        build = counting("striponlyplain", 50), window = win,
    }), 80)
    eq(rawget(plain, "footerStrip"), nil, "only: a row that did not ask has no strip")
    plain:GetScript("OnEnter")()
    eq(plain.plate._fill.r, UI.Colors.hover.r, "only: so IT still lifts to the hover colour")
    eq(plain.plate._fill.a, M.hoverFill, "only: ...and brightens")
    plain:GetScript("OnLeave")()
    eq(plain.plate._fill.a, M.restFill, "only: and settles back")
    plain:GetScript("OnClick")(plain)
    check(plain.popout ~= nil, "only: and its WHOLE PLATE still opens the panel")
    host:CloseAllPopoutRows("test")
end


CreateFrame, C_Timer = prevCreateFrame, prevTimer
PlaySound, SOUNDKIT = prevPlaySound, prevSoundKit

-- ---- 24.20 THE STRIP'S CLICK IS A TOGGLE -----------------------------
-- ☠ ASKED FOR THE MOMENT THE STRIP BECAME THE ONLY WAY IN: "clicking the
-- bottom bar of the row should close the popout instead of just reopening it".
-- A raise of a panel already in front is a click that does nothing visible.
-- ⚠ PINNED PANELS GO DOWN TOO. The first cut spared them, and a "Pin settings
-- in popout" row -- whose panel opens pinned -- then had the one strip that
-- could never close what it opened. Tried in game, corrected the same hour.
do
    local win = window()
    local db = { on = true }
    local row = stripRow({ label = "Toggle me", db = db, count = 5, window = win,
                           popoutKey = "toggle.row",
                           footerStrip = true, toggle = { key = "on" } })
    local strip = row.footerStrip

    strip:GetScript("OnClick")(strip)
    local po = row.popout
    check(po ~= nil and not po.closed, "toggle: the first click opens the panel")
    strip:GetScript("OnClick")(strip)
    check(po.closed, "toggle: the second click CLOSES that panel rather than raising it")
    eq(row.popout, nil, "toggle: ...and the row no longer names it")
    eq(next(row._bound), nil, "toggle: ...nor is it bound any more")
    strip:GetScript("OnClick")(strip)
    check(row.popout ~= nil and not row.popout.closed, "toggle: a third click opens again")
    check(row._active, "toggle: ...and the row is active once more")

    -- The verb itself, for a consumer that wants the same gesture elsewhere.
    row:TogglePopout()
    check(row.popout == nil, "toggle: the verb closes an open loose panel")
    row:TogglePopout()
    check(row.popout ~= nil, "toggle: ...and opens when there is none")

    -- ---- pinned: the strip closes that too --------------------------------
    local pinned = row.popout
    pinned:Pin(true)
    eq(pinned.pinned, true, "toggle: (pinned by hand)")
    strip:GetScript("OnClick")(strip)
    check(pinned.closed, "toggle: a click on the strip closes a PINNED panel as well")
    eq(row.popout, nil, "toggle: ...and the row names nothing")

    -- ---- the empty pane, which opens pinned: the strip still toggles it ----
    local empty = stripRow({ label = "Pin me", db = db, count = 5, window = win,
                             popoutKey = "toggle.empty",
                             footerStrip = true, toggle = { key = "on" } })
    empty:SetCountProvider(function() return 0 end)
    empty:SetHoistedControls(twoSliders(db, {}))
    local es = empty.footerStrip
    es:GetScript("OnClick")(es)
    local ep = empty.popout
    check(ep ~= nil and ep.pinned, "toggle: an empty pane's strip opens its panel pinned")
    es:GetScript("OnClick")(es)
    check(ep.closed, "toggle: ...and the SAME strip closes it again -- the case that failed in game")
    es:GetScript("OnClick")(es)
    check(empty.popout ~= nil and empty.popout.pinned and not empty.popout.closed,
          "toggle: a third click pins a fresh one")
    empty:TogglePopout()
    eq(empty.popout, nil, "toggle: (and the verb takes it down)")
    -- ⚠ NOT DRIVEN: a row bound to a pinned AND a loose panel at once. The
    -- verb closes every panel about the row rather than livePanel's favourite,
    -- but the row's own verbs cannot reach that state -- a re-open RAISES the
    -- pinned one (section 17.3) rather than building a loose one beside it --
    -- so the loop is defensive, and this file says so instead of faking it.

    -- ---- the ROW's own verb keeps raise semantics --------------------------
    local plain = place(host:CreatePopoutRow(FakeUIFrame(), {
        label = "Whole plate", db = { on = true }, count = 3,
        build = counting("toggleplain", 50), window = win,
    }), 80)
    plain:GetScript("OnClick")(plain)
    local first = plain.popout
    check(first ~= nil, "toggle: a plain row's click opens")
    plain:GetScript("OnClick")(plain)
    eq(plain.popout, first, "toggle: ...and a second click on the PLATE raises, not closes")
    check(not first.closed, "toggle: (it is still open)")
    plain:ClosePopout()
end
