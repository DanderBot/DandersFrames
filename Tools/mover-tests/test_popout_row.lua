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
    plate = 44, gap = 6, padX = 10, labelGap = 10, colGap = 6,
    check = 16, checkTick = 9, gear = 14, chevron = 10,
    badgeW = 22, badgeH = 16, modTick = 5,
    labelSize = 12, summarySize = 11, badgeSize = 10,
    restFill = 0.55, hoverFill = 0.75, restBorder = 0.5,
    activeFill = 0.14, activeHover = 0.20, activeBorder = 1,
    badgeFill = 0.55, badgeBorder = 0.45,
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

CreateFrame, C_Timer = prevCreateFrame, prevTimer
PlaySound, SOUNDKIT = prevPlaySound, prevSoundKit
