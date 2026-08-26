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
UI.PopoutTitleHeight = UI.PopoutTitleHeight or 28
UI.PopoutPad = UI.PopoutPad or 10
UI.StyleScrollBar = UI.StyleScrollBar or function(sf) sf._styledScrollBar = true end

local ROW_H   = UI.RowHeight.checkbox
local PLATE_H = ROW_H - UI.RowGap
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
-- prefix means a field, and no WoW method is named that way. `popout` is the one
-- public field this widget publishes without one.
local function dataAwareMeta(k)
    if k == "popout" then return nil end
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
    eq(row:GetHeight(), ROW_H, "row: it takes a checkbox's slot")
    eq(row.preferredHeight, ROW_H, "row: ...and stamps it, so a call-site number cannot override it")
    check(row.fixedRowHeight, "row: the slot is owned by the factory, not the call site")
    -- rawget: rowKind is not underscore-prefixed, so the stub's method fallback
    -- would answer for it; the claim is that the FACTORY never wrote one.
    eq(rawget(row, "rowKind"), nil, "row: no rowKind -- an unknown kind would break a run of checkboxes")
    eq(row.plate._fill.a, 0.03, "row: the hover plate rests at the collapse bar's own alpha")
    eq(row.plate:GetHeight(), PLATE_H, "row: the plate is the slot less its gap")

    row:GetScript("OnEnter")()
    eq(row.plate._fill.a, 0.06, "row: hovering lights it")
    row:GetScript("OnLeave")()
    eq(row.plate._fill.a, 0.03, "row: and leaving puts it back")
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

CreateFrame, C_Timer = prevCreateFrame, prevTimer
PlaySound, SOUNDKIT = prevPlaySound, prevSoundKit
