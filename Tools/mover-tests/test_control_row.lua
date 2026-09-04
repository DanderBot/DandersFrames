local NS = ...

-- ============================================================
-- TEST HOST -- ControlRow (DandersUI/ControlRow.lua)
-- ------------------------------------------------------------
-- ☠ A FRESH NAMESPACE, not the shared `ns` run.py hands the popout suites.
-- test_sections_group.lua's reasoning, and this file needs it more than that one
-- does: run.py loads test_*.lua in ALPHABETICAL order, so "control_row" runs
-- BEFORE "popout_row", "panel", "sections_group" and "widgets_slider" -- every
-- suite whose `if not UI.X then` guards would silently adopt a stub installed
-- here and start asserting against it. Loading into a private kit means nothing
-- this file does is visible to any of them.
--
-- CreateFrame, PlaySound and SOUNDKIT are globals, so those three are saved and
-- restored at the end.
--
-- WHAT THIS SUITE IS ABOUT. A control row's whole claim is PLATE PARITY: it is
-- the same plate a popout row draws, carrying a control instead of a summary and
-- a way in. So the parity assertions are not made against numbers copied into
-- this file -- they are made against a REAL PopoutRow built in the same private
-- kit, and against the REAL Theme.lua token table loaded into a throwaway
-- namespace. Both shapes have to move together or the suite goes red.
-- ============================================================

-- ---- the private kit ------------------------------------------------
local UI = {
    MEDIA = "",
    Colors = {
        -- Distinct numbers from one another, so an assertion that a plate wears
        -- C_ELEMENT at rest and C_HOVER on hover cannot pass by coincidence.
        text       = { r = 0.90, g = 0.90, b = 0.90 },
        textDim    = { r = 0.50, g = 0.50, b = 0.50 },
        element    = { r = 0.20, g = 0.21, b = 0.22, a = 1 },
        border     = { r = 0.31, g = 0.32, b = 0.33, a = 1 },
        hover      = { r = 0.41, g = 0.42, b = 0.43, a = 1 },
        background = { r = 0.08, g = 0.08, b = 0.08, a = 0.95 },
        -- The amber notice token: PopoutRow.lua reads it at FILE SCOPE for the
        -- modified tick on its count pill, and this file loads PopoutRow.
        notice     = { r = 0.91, g = 0.66, b = 0.25, a = 1 },
    },
    -- The layout metrics Sections' LayoutChildren reads. RowCompact empty on
    -- purpose -- the run-tightening has its own coverage elsewhere and would only
    -- add noise to the slot arithmetic this file asserts.
    RowGap = 14, RowGapTight = 6, RowCompact = {},
    RowHeight = { checkbox = 35, slider = 55, dropdown = 55 },
    SettingsBox = { group = 280, pad = 10, colMargin = 5, minCol = 285,
                    colGutter = 20, innerGap = 10 },
    PopoutContentWidth = 260,
    PopoutPad = 10,
    -- ★ THE ROW PLATE'S BOX MODEL. Mirrored from Theme.lua, and section 2 below
    -- asserts key-for-key that the mirror still says what Theme.lua says -- so a
    -- retune over there is a red suite here rather than a test quietly agreeing
    -- with its own stale copy.
    PopoutRow = {
        plate = 44, gap = 8, padX = 10, labelGap = 10, colGap = 6,
        check = 16, checkTick = 9, gear = 14, chevron = 10,
        badgeW = 22, badgeH = 16, modTick = 5,
        labelSize = 12, summarySize = 11, badgeSize = 10,
        restFill = 0.55, hoverFill = 0.75, restBorder = 0.5,
        activeFill = 0.14, activeHover = 0.20, activeBorder = 1,
        badgeFill = 0.55, badgeBorder = 0.45,
        -- The hoisted-controls half. This file only reads three of them
        -- (dropdownH / sliderH / sliderBarMid, which ControlRow.lua now takes
        -- from the theme rather than restating), but section 2 below compares
        -- the mirror to Theme.lua KEY FOR KEY -- so every token the real table
        -- carries has to be here or the mirror is the thing that has drifted.
        lineH = 36, nameH = 12, controlH = 24, linePad = 4,
        cellGap = 10, nameSize = 9, minControl = 98, splitCell = 166,
        footer = 18, footerFill = 0.85, footerBorder = 0.6, footerOn = 0.22,
        plateStrip = 30, stripArc = 8, modTickGap = 2,
        dropdownH = 24, sliderH = 50, sliderBarMid = 22,
    },
    _state = {},
    _priv = {
        INFO_BANNER_TONES = {},
        AddTooltipLines = function() end,
        CURSOR_LIFT_X = 0, CURSOR_LIFT_Y = 0,
        -- Sections.lua takes this one off _priv and calls it WITHOUT a self.
        CreateElementBackdrop = function(frame, opts)
            frame._elementOpts = opts
            return frame
        end,
    },
}
UI.PopoutRow.slot = UI.PopoutRow.plate + UI.PopoutRow.gap

-- ---- the surface style and the rounded primitive, BORROWED --------
-- Taken from the shared library table rather than re-implemented: run.py lifts
-- the REAL Theme.lua resolver and loads the REAL Round.lua onto it, and a second
-- implementation here would be a test that agrees with itself. Same list
-- test_sections_group.lua borrows.
do
    local SHARED = NS.__DandersUI
    for _, name in ipairs({ "SurfaceStyle", "ResolveSurfaceStyle", "SetSurfaceStyle",
                            "GetSurfaceStyle", "HidePixelBorder",
                            "CreateRoundedSurface", "GetRoundedSurface",
                            "ApplyRoundedChrome", "RemoveRoundedChrome" }) do
        UI[name] = SHARED[name]
    end
end

-- No snapping: every offset below is asserted as the arithmetic the row did, and
-- a rounding pass would make those numbers about the device grid instead.
function UI.SnapLen(_, n) return n end
function UI.ResolveRowHeight(widget, height)
    if widget and widget.fixedRowHeight and widget.preferredHeight then
        return widget.preferredHeight
    end
    return height or (widget and widget.preferredHeight) or 55
end
local ACCENT = { r = 0.45, g = 0.45, b = 0.95, a = 1 }
function UI:GetAccent() return ACCENT end

-- The hook plumbing, verbatim from Core.lua (which a headless run never loads).
function UI:Hook(name)
    local h = rawget(self, "hooks")
    return h and h[name] or nil
end
function UI:Call(name, ...)
    local fn = self:Hook(name)
    if not fn then return nil end
    return fn(...)
end

-- ---- widget stubs the row touches -----------------------------------
-- The element backdrop RECORDS what it was asked to paint and installs the two
-- recolour methods the real one leaves behind (SetBackdropColor from
-- BackdropTemplateMixin, SetBackdropBorderColor from the pixel-border shim). The
-- plate's whole rest/hover look is only observable as these.
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

-- StyleCheckButton's whole observable contract: it sizes the box, records the
-- opts it was styled with (the tick size is only visible as those) and publishes
-- ApplyThemeColor. Identical in shape to test_popout_row.lua's, because the two
-- shapes are supposed to be styling the SAME tick.
function UI:StyleCheckButton(cb, opts)
    opts = opts or {}
    cb:SetSize(opts.size or 18, opts.size or 18)
    cb.Check = cb.Check or FakeUIFrame()
    cb._styleOpts = opts
    cb.ApplyThemeColor = function(c) cb._tint = c end
    cb.ApplyThemeColor(opts.accent or self:GetAccent())
    return cb.Check
end

function UI:CreateLabelNative(parent, opts)
    local fs = FakeUIFrame()
    fs._labelOpts = opts
    fs.SetTextColor = function(self, r, g, b, a) self._textColor = { r = r, g = g, b = b, a = a } end
    if opts and opts.color then fs:SetTextColor(opts.color.r, opts.color.g, opts.color.b) end
    if opts and opts.text then fs:SetText(opts.text) end
    return fs
end

-- ---- the four embedded factories ------------------------------------
-- Each stub answers exactly the contract ControlRow drives: the opts it was
-- handed (so the pass-through is assertable), a readable bound value, SetEnabled
-- and ONE of the repaint verbs. They deliberately expose DIFFERENT repaint names
-- -- refreshValue on the slider and the dropdown, bare Refresh on the edit box --
-- so the row's fallback chain is exercised rather than assumed.
local function boundValue(opts)
    if opts.get then return opts.get() end
    if opts.dbRef and opts.dbRef.db then return opts.dbRef.db[opts.dbRef.key] end
    return nil
end

function UI:CreateSliderNative(parent, opts)
    local c = CreateFrame("Frame", nil, parent)
    c._sliderOpts = opts
    -- SHOWN to begin with, deliberately: the real factory draws its caption and
    -- the row hides it afterwards, so a stub that started hidden would let
    -- "the caption is hidden" pass without the row doing anything.
    c.label = FakeUIFrame()
    c.label:Show()
    c.refreshValue = function(self) self._value = boundValue(opts) end
    c.SetEnabled = function(self, e) self._enabled = e and true or false end
    c:refreshValue()
    return c
end

function UI:CreateDropdownNative(parent, opts)
    local c = CreateFrame("Frame", nil, parent)
    c._dropdownOpts = opts
    c.refreshValue = function(self) self._value = boundValue(opts) end
    c.SetEnabled = function(self, e) self._enabled = e and true or false end
    c:refreshValue()
    return c
end

function UI:CreateEditBoxNative(parent, opts)
    local eb = CreateFrame("EditBox", nil, parent)
    eb._ebOpts = opts
    -- ⚠ ONLY `Refresh`, which is all the real edit box publishes. The row has to
    -- reach it through the fallback chain.
    eb.Refresh = function(self) self._value = boundValue(opts) end
    eb.SetEnabled = function(self, e) self._enabled = e and true or false end
    eb:Refresh()
    return eb
end

function UI:CreateButtonNative(parent, opts)
    local b = CreateFrame("Button", nil, parent)
    b._btnOpts = opts
    b.SetEnabled = function(self, e) self._enabled = e and true or false end
    return b
end

-- The tooltip surface, RECORDED rather than drawn: what a row shows is only
-- observable as the spec it asked for and the frame it hung it off.
local tipCalls, tipHidden = {}, 0
function UI:ShowTooltip(anchor, spec)
    tipCalls[#tipCalls + 1] = { anchor = anchor, spec = spec }
end
function UI:HideTooltip() tipHidden = tipHidden + 1 end

-- The colour picker: RECORDS the call and hands its callbacks back, so a test can
-- drive an accept the way a user would.
local pickerCalls = {}
function UI:OpenColorPicker(initial, hasAlpha, onAccept, onCancel, onChange, default)
    pickerCalls[#pickerCalls + 1] = {
        initial = initial, hasAlpha = hasAlpha, accept = onAccept,
        cancel = onCancel, change = onChange, default = default,
    }
    return true
end

-- ---- WoW globals ----------------------------------------------------
local prevCreateFrame = CreateFrame
local prevPlaySound, prevSoundKit = PlaySound, SOUNDKIT
PlaySound = function() end
SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = 1 }

-- ☠ A MISSING DATA FIELD MUST READ nil, NOT A FUNCTION -- test_popout_row.lua's
-- rule, for its reason: FakeUIFrame answers every unknown key with a no-op
-- function, which is right for METHODS and wrong for STATE. `hideOn` is the field
-- that forces it here: Sections' entryVisible reads it straight off the widget,
-- and a truthy no-op on every widget that has none would make the hidden test
-- meaningless.
--
-- ...AND SO MUST A VERB THE ROW PROBES FOR. `refreshValue` / `RefreshValue` /
-- `Refresh` / `refreshContent` are the four names ControlRow walks in order to
-- find a control's repaint (the factories publish different ones; the edit box
-- has only the bare `Refresh`). Against the no-op fallback the FIRST probe always
-- succeeds, so the fallback chain could never be reached and the test that says
-- it is would pass against nothing.
local DATA_KEYS = { hideOn = true, control = true, controlKind = true,
                    isControlRow = true, popout = true, popoutRadius = true,
                    refreshValue = true, RefreshValue = true,
                    Refresh = true, refreshContent = true,
                    -- ...AND THE TOOLTIP SPEC, for the same reason. The row's own
                    -- OnEnter early-outs on `row.tooltip` being absent; a truthy
                    -- no-op would make every row show one, and the row with none
                    -- would be asserted against nothing.
                    tooltip = true,
                    -- The kit's own click-refusal flag (Widgets.lua's buttons
                    -- early-out on it). A truthy no-op here would refuse every
                    -- click on a live control.
                    dfDisabled = true }
local function dataAwareMeta(k)
    if DATA_KEYS[k] then return nil end
    if type(k) == "string" and k:byte(1) == 95 then return nil end   -- "_"
    return function() end
end

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
    local rawCreateTexture = f.CreateTexture
    f.CreateTexture = function(self, ...)
        local t = rawCreateTexture(self, ...)
        t.SetColorTexture = function(s, r, g, b, a) s._color = { r = r, g = g, b = b, a = a } end
        return t
    end
    if type(parent) == "table" then
        local kids = rawget(parent, "_children")
        if not kids then kids = {}; parent._children = kids end
        kids[#kids + 1] = f
    end
    return f
end

-- ---- the host, and the two files under test -------------------------
local settingsDB = {}
local L = setmetatable({}, { __index = function(_, k) return k end })
local dbgLog = {}
local host = setmetatable({ hooks = {
    L = L,
    getSettingsDB = function() return settingsDB end,
    debug = function(cat) return function(msg) dbgLog[#dbgLog + 1] = { cat = cat, msg = msg } end end,
} }, { __index = UI })

local PRIVATE_NS = { __DandersUI = UI }
load_ui_file_into("Sections.lua", PRIVATE_NS)
-- ⚠ READ-ONLY HERE. PopoutRow is loaded so the parity claims below can be made
-- against the real shape rather than against numbers copied out of it. Nothing in
-- this suite drives it beyond building one and reading its anchors.
load_ui_file_into("PopoutRow.lua", PRIVATE_NS)
load_ui_file_into("ControlRow.lua", PRIVATE_NS)

local M       = UI.PopoutRow
local ROW_H   = M.slot
local PLATE_H = M.plate
local LABEL_X = M.padX + M.check + M.labelGap
local C_TEXT, C_TEXT_DIM = UI.Colors.text, UI.Colors.textDim
local C_ELEMENT, C_BORDER, C_HOVER = UI.Colors.element, UI.Colors.border, UI.Colors.hover

-- The documented control-column widths (DandersUI/ControlRow.lua's CONTROL_W).
-- Restated here as the numbers the FILE promises, so a change to either without
-- the other is a red suite.
local W = { dropdown = 160, slider = 170, editbox = 80, color = 44, button = 90 }
local H = { dropdown = 24,  slider = 50,  editbox = 20, color = 18, button = 22 }
local SLIDER_BAR_MID = 22

-- The anchor a control was placed with, as (point, relPoint, x, y).
local function anchor(w, i)
    local p, _, rel, x, y = w:GetPoint(i or 1)
    return p, rel, x, y
end

-- ============================================================
-- 1. ANATOMY
-- One row of every kind. The claims are about WHERE things land, because that is
-- the entire reason this shape exists rather than an inline box.
-- ============================================================
print("-- ControlRow: anatomy")
do
    local db = { on = true }
    local row = host:CreateControlRow(FakeUIFrame(), {
        label = "Show Power Bar", kind = "checkbox", db = db, key = "on",
    })
    eq(row:GetHeight(), ROW_H, "checkbox: it takes the popout row's own slot")
    eq(row.preferredHeight, ROW_H, "checkbox: ...and stamps it, so a call-site number cannot override it")
    check(row.fixedRowHeight, "checkbox: the slot is owned by the factory, not the call site")
    -- rawget: rowKind is not underscore-prefixed, so the stub's method fallback
    -- would answer for it; the claim is that the FACTORY never wrote one.
    eq(rawget(row, "rowKind"), nil, "checkbox: no rowKind -- an unknown kind would break a run of checkboxes")
    eq(row.plate:GetHeight(), PLATE_H, "checkbox: the plate is the slot less its gap")
    eq(ROW_H - PLATE_H, M.gap, "checkbox: ...and the gap is what the next row stands on")

    check(row.checkButton ~= nil, "checkbox: the tick is drawn")
    local p, rel, x, y = anchor(row.checkButton)
    eq(p, "LEFT", "checkbox: the tick is anchored on the LEFT of the plate")
    eq(rel, "LEFT", "checkbox: ...to the plate's own left edge")
    eq(x, M.padX, "checkbox: ...at the plate's inner padding")
    eq(y, 0, "checkbox: ...centred on the plate's midline")
    eq(row.checkButton:GetWidth(), M.check, "checkbox: the box is the row plate's tick size")
    eq(row.checkButton._styleOpts.checkSize, M.checkTick, "checkbox: ...and so is the tick inside it")

    -- ☠ NO RIGHT-SIDE CONTROL. The tick IS the control, so `control` is the tick
    -- itself and the label runs all the way to the plate's right padding.
    eq(rawget(row, "control"), row.checkButton, "checkbox: the tick is the row's control")
    eq(row.label:GetText(), "Show Power Bar", "checkbox: the label is the name it was given")
    local lp, lrel, lx = anchor(row.label, 1)
    eq(lp, "LEFT", "checkbox: the label starts on the left")
    eq(lx, LABEL_X, "checkbox: ...in the shared label column")
    local rp, rrel, rx = anchor(row.label, 2)
    eq(rp, "RIGHT", "checkbox: and runs to the right")
    eq(rrel, "RIGHT", "checkbox: ...of the PLATE, since nothing else is drawn there")
    eq(rx, -M.padX, "checkbox: ...stopping at the plate's inner padding")
end

-- Every other kind: label left, control right-aligned in the fixed column.
do
    local cases = {
        { kind = "dropdown", extra = { options = { A = "A", B = "B" } } },
        { kind = "slider",   extra = { min = 0, max = 100, step = 1 } },
        { kind = "editbox",  extra = { numeric = true } },
        { kind = "color",    extra = {} },
        { kind = "button",   extra = { onClick = function() end } },
    }
    for _, case in ipairs(cases) do
        local o = { label = "Width", kind = case.kind, db = { Width = 5 }, key = "Width" }
        for k, v in pairs(case.extra) do o[k] = v end
        local row = host:CreateControlRow(FakeUIFrame(), o)
        local w = rawget(row, "control")
        check(w ~= nil, case.kind .. ": the control is built")
        eq(row:GetHeight(), ROW_H, case.kind .. ": the slot is the popout row's")
        eq(row.plate:GetHeight(), PLATE_H, case.kind .. ": ...and so is the plate")
        eq(rawget(row, "checkButton"), nil, case.kind .. ": no tick is drawn on a non-checkbox row")

        eq(w:GetWidth(), W[case.kind], case.kind .. ": the control is the documented column width")
        eq(w:GetHeight(), H[case.kind], case.kind .. ": ...at the documented height")
        local p, rel, x, y = anchor(w)
        eq(p, "TOPRIGHT", case.kind .. ": the control is anchored by its top-right")
        eq(rel, "RIGHT", case.kind .. ": ...to the plate's right edge, on the midline")
        eq(x, -M.padX, case.kind .. ": ...inset by the plate's own padding")
        eq(y, case.kind == "slider" and SLIDER_BAR_MID or (H[case.kind] / 2),
           case.kind .. ": ...and lifted so the control centres on that midline")

        -- The label column is the SAME x as a checkbox row's, tick or no tick.
        local lp, _, lx = anchor(row.label, 1)
        eq(lp, "LEFT", case.kind .. ": the label starts on the left")
        eq(lx, LABEL_X, case.kind .. ": ...in the same column a ticked row uses")
        local rp, rrel, rx = anchor(row.label, 2)
        eq(rp, "RIGHT", case.kind .. ": and stops short of the control")
        eq(rrel, "LEFT", case.kind .. ": ...against the control's left edge")
        eq(rx, -M.colGap, case.kind .. ": ...by one column gap")
    end
end

-- The label is PASSED to the embedded factory as well as drawn: the override
-- markers, the tooltip title and the search index all read it, and an empty one
-- would register the setting under no name at all.
do
    local db = { size = 12 }
    local slider = host:CreateControlRow(FakeUIFrame(), {
        label = "Width", kind = "slider", db = db, key = "size",
        min = 1, max = 40, step = 1,
    })
    local o = slider.control._sliderOpts
    eq(o.label, "Width", "slider: the row's label reaches the factory")
    eq(o.min, 1, "slider: min is forwarded")
    eq(o.max, 40, "slider: max is forwarded")
    eq(o.step, 1, "slider: step is forwarded")
    check(not slider.control.label:IsShown(), "slider: ...but the factory's own caption is hidden")

    local dd = host:CreateControlRow(FakeUIFrame(), {
        label = "Anchor", kind = "dropdown", db = db, key = "anchor",
        options = { CENTER = "Center" },
    })
    eq(dd.control._dropdownOpts.label, "Anchor", "dropdown: the row's label reaches the factory")
    check(dd.control._dropdownOpts.inline, "dropdown: ...and it is built in the inline form, caption hidden")

    -- A button with no caption of its own wears the row's name rather than
    -- nothing -- the one string this shape defaults, and it is the consumer's.
    local btn = host:CreateControlRow(FakeUIFrame(), { label = "Reset", kind = "button" })
    eq(btn.control._btnOpts.text, "Reset", "button: an absent caption falls back to the row's label")
    local named = host:CreateControlRow(FakeUIFrame(), {
        label = "Profile", kind = "button", text = "Reset",
    })
    eq(named.control._btnOpts.text, "Reset", "button: an explicit caption wins")
end

-- An unrecognised kind is a call-site mistake: a plate with a name on it and one
-- line where the consumer's debug output goes, not an error at a user.
do
    local before = #dbgLog
    local row = host:CreateControlRow(FakeUIFrame(), { label = "Mystery", kind = "wat" })
    eq(rawget(row, "control"), nil, "unknown kind: no control is invented")
    eq(row.label:GetText(), "Mystery", "unknown kind: the plate still carries the name")
    check(#dbgLog > before, "unknown kind: ...and it is reported through the debug hook")
    eq(dbgLog[#dbgLog].cat, "controlrow", "unknown kind: under its own debug category")
end

-- ============================================================
-- 2. PLATE PARITY
-- The point of the whole shape. Two independent claims:
--   a) the token table this file mirrors still says what Theme.lua says
--   b) a control row and a POPOUT ROW built in the same kit draw the same plate
-- ============================================================
print("-- ControlRow: plate parity")

-- (a) the mirror has not drifted from the real Theme.lua.
do
    local themeNS = { __DandersUI = { _state = {}, _priv = {} } }
    load_ui_file_into("Theme.lua", themeNS)
    local real = themeNS.__DandersUI.PopoutRow
    check(type(real) == "table", "theme: UI.PopoutRow is declared in Theme.lua")
    if type(real) == "table" then
        local n = 0
        for k, v in pairs(real) do
            n = n + 1
            eq(M[k], v, "theme: the mirrored token " .. tostring(k) .. " matches Theme.lua")
        end
        for k in pairs(M) do
            check(real[k] ~= nil, "theme: the mirror invents no token -- " .. tostring(k))
        end
        check(n > 20, "theme: the whole token table was compared, not a stub of it")
        eq(real.slot, real.plate + real.gap, "theme: the slot is derived from the plate and the gap")
        -- The numbers the shape was designed against, pinned so a retune is a
        -- deliberate act with a red suite in front of it.
        -- gap went 6 -> 8 on 2026-09-04 ("a tiny bit more spacing between the
        -- rows", from the Frame page's first hoisted look). Every converted page
        -- moves 2px per row with it -- one rhythm, not a strip-row exception.
        eq(real.slot, 52, "theme: the slot is 52")
        eq(real.plate, 44, "theme: 44 of that is ink")
        eq(real.gap, 8, "theme: and 8 is the gap below it")
        eq(real.padX, 10, "theme: the plate's inner padding is 10")
        eq(real.check, 16, "theme: the tick box is 16")
        eq(real.checkTick, 9, "theme: with a 9px tick in it")
        eq(real.labelGap, 10, "theme: tick -> label is 10")
        eq(real.colGap, 6, "theme: and the column gap is 6")
        eq(real.restFill, 0.55, "theme: the plate rests at 0.55 of the element fill")
        eq(real.hoverFill, 0.75, "theme: and lifts to 0.75 of the hover colour")
        eq(real.restBorder, 0.5, "theme: inside the border at half strength")
    end
end

-- (b) the two shapes, side by side in one kit.
do
    local db = { on = true, size = 12 }
    local pr = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Auras", db = db, toggle = { key = "on" },
        build = function(_, pane) pane:SetHeight(40) end,
    })
    local cr = host:CreateControlRow(FakeUIFrame(), {
        label = "Auras", kind = "checkbox", db = db, key = "on",
    })

    eq(cr:GetHeight(), pr:GetHeight(), "parity: the two rows take the same slot")
    eq(cr.preferredHeight, pr.preferredHeight, "parity: ...and declare it the same way")
    eq(cr.plate:GetHeight(), pr.plate:GetHeight(), "parity: the plates are the same height")

    -- Rest paint: same colour, same alphas, from the same tokens.
    eq(cr.plate._fill.r, pr.plate._fill.r, "parity: both plates rest on the element fill")
    eq(cr.plate._fill.a, pr.plate._fill.a, "parity: ...at the same rest alpha")
    eq(cr.plate._edge.r, pr.plate._edge.r, "parity: inside the same border colour")
    eq(cr.plate._edge.a, pr.plate._edge.a, "parity: ...at the same border alpha")
    eq(cr.plate._fill.r, C_ELEMENT.r, "parity: and that colour IS the element token")
    eq(cr.plate._fill.a, M.restFill, "parity: at the token's own rest alpha")
    eq(cr.plate._edge.a, M.restBorder, "parity: and the token's border alpha")

    -- The tick column and the label column, which is the alignment the shape
    -- exists for.
    local _, _, crx, cry = anchor(cr.checkButton)
    local _, _, prx, pry = anchor(pr.checkButton)
    eq(crx, prx, "parity: the ticks sit at the same inset")
    eq(cry, pry, "parity: ...on the same midline")
    eq(cr.checkButton:GetWidth(), pr.checkButton:GetWidth(), "parity: at the same size")
    eq(cr.checkButton._styleOpts.checkSize, pr.checkButton._styleOpts.checkSize,
       "parity: with the same tick inside")
    local _, _, clx = anchor(cr.label, 1)
    local _, _, plx = anchor(pr.label, 1)
    eq(clx, plx, "parity: and the labels start in the same column")

    -- The ink/slot split, which is what lets a page mount either shape into the
    -- same band and get one rhythm.
    eq(cr.popoutInset[4], pr.popoutInset[4], "parity: the same gap is declared as slot, not ink")

    -- The hover lift is the same lift.
    cr:GetScript("OnEnter")()
    pr:GetScript("OnEnter")()
    eq(cr.plate._fill.r, pr.plate._fill.r, "parity: hovering lifts both to the hover colour")
    eq(cr.plate._fill.a, pr.plate._fill.a, "parity: ...by the same amount")
    cr:GetScript("OnLeave")()
    pr:GetScript("OnLeave")()
end

-- The corner radius comes from the same resolver, so a rounded host rounds both
-- shapes at one number rather than at two that happen to agree.
do
    local style = { style = "rounded", radius = 8, borderWidth = 2, rowBorderWidth = 1 }
    local cr = host:CreateControlRow(FakeUIFrame(), {
        label = "Rounded", kind = "editbox", surface = style,
    })
    local pr = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Rounded", db = {}, surface = style,
        build = function(_, pane) pane:SetHeight(10) end,
    })
    eq(cr:GetSurface().radius, pr:GetSurface().radius, "surface: the same radius reaches both shapes")
    eq(cr:GetSurface(), pr:GetSurface(), "surface: ...because both resolve the one declaration")
    -- `false` forces square on a host that has opted in; the row clears its
    -- surface rather than keeping a stale handle.
    cr:SetSurface(false)
    eq(cr:GetSurface(), nil, "surface: false forces square")
    eq(cr.plate._fill.a, M.restFill, "surface: ...and the square plate repaints at the rest alpha")
end

-- ============================================================
-- 3. STATES
-- Grey-when-disabled is TWO statements -- the row fades and the control stops
-- taking input -- and a plate that only faded would still be editable through.
-- ============================================================
print("-- ControlRow: enabled and hover")
do
    local db = { size = 12 }
    local row = host:CreateControlRow(FakeUIFrame(), {
        label = "Width", kind = "slider", db = db, key = "size",
        min = 1, max = 40, step = 1,
    })
    eq(row:GetAlpha(), 1, "enabled: a live row is at full strength")
    eq(row.control._enabled, true, "enabled: and its control takes input")
    eq(row.label._textColor.r, C_TEXT.r, "enabled: the label is at the text colour")

    row:SetEnabled(false)
    eq(row:GetAlpha(), 0.4, "disabled: the whole row dims to the shared 0.4")
    eq(row.control._enabled, false, "disabled: ...and the control is disabled, not merely faded")
    eq(row.label._textColor.r, C_TEXT_DIM.r, "disabled: the label goes dim")

    row:SetEnabled(true)
    eq(row:GetAlpha(), 1, "re-enabled: the row comes back to full strength")
    eq(row.control._enabled, true, "re-enabled: ...and the control takes input again")
    eq(row.label._textColor.r, C_TEXT.r, "re-enabled: and the label is lit again")
end

-- opts.enabled, and the rule that an explicit SetEnabled OUTRANKS it from then on
-- -- every other widget's grey path, so a page driving disableOn and a row
-- carrying its own predicate cannot fight each other every refresh.
do
    local db = { gate = false }
    local row = host:CreateControlRow(FakeUIFrame(), {
        label = "Width", kind = "editbox", db = db, key = "w",
        enabled = function(d) return d.gate end,
    })
    eq(row:GetAlpha(), 0.4, "enabled fn: the predicate greys the row at build")
    db.gate = true
    row.Refresh()
    eq(row:GetAlpha(), 1, "enabled fn: ...and a refresh re-asks it")
    row:SetEnabled(false)
    db.gate = true
    row.Refresh()
    eq(row:GetAlpha(), 0.4, "enabled fn: an explicit SetEnabled outranks the predicate")
end

-- Hover: the plate lifts and drops back, and there is NO third state -- a control
-- row opens nothing, so it can never wear the accent wash a popout row does.
do
    local row = host:CreateControlRow(FakeUIFrame(), { label = "Hover", kind = "checkbox" })
    eq(row.plate._fill.r, C_ELEMENT.r, "hover: at rest the plate is the element colour")
    eq(row.plate._fill.a, M.restFill, "hover: ...at the rest alpha")

    row:GetScript("OnEnter")()
    eq(row.plate._fill.r, C_HOVER.r, "hover: entering lifts it to the hover colour")
    eq(row.plate._fill.a, M.hoverFill, "hover: ...and brightens it")
    eq(row.plate._edge.a, M.restBorder, "hover: the border is unchanged")
    check(row.plate._fill.r ~= ACCENT.r, "hover: and it is never the accent -- there is no active state")

    row:GetScript("OnLeave")()
    eq(row.plate._fill.r, C_ELEMENT.r, "hover: leaving puts it back")
    eq(row.plate._fill.a, M.restFill, "hover: ...to the rest alpha")

    -- A disabled row still answers the hover, exactly as a greyed popout row does:
    -- the dim is an alpha on the frame, not a dead plate.
    row:SetEnabled(false)
    row:GetScript("OnEnter")()
    eq(row.plate._fill.a, M.hoverFill, "hover: a greyed row still lifts under the cursor")
    row:GetScript("OnLeave")()
end

-- ============================================================
-- 3b. THE TOOLTIP RIDES THE PLATE'S OWN HOVER
-- ☠ AND IT HAS TO. Every factory hangs a forwarded tooltip on the LABEL it was
-- handed, and this shape hides that label because the row draws the name itself;
-- a CHECKBOX row never gets that far, because its tick is hand-built from the
-- shared styler and never sees the option. The plate is the one thing every kind
-- has -- and it must NOT be a hit frame, because a mouse-enabled child inside the
-- plate would take the hover away from the row and drop it back to rest across
-- the whole width of its own label.
-- ============================================================
print("-- ControlRow: the tooltip rides the plate's own hover")
do
    local before, hidBefore = #tipCalls, tipHidden
    local row = host:CreateControlRow(FakeUIFrame(), {
        label = "Hide Self", kind = "checkbox", tooltip = "Removes your player frame.",
    })
    eq(rawget(row, "tooltip"), "Removes your player frame.",
       "tooltip: the spec is stamped on the row, where a search result can read it")

    row:GetScript("OnEnter")()
    eq(#tipCalls, before + 1, "tooltip: entering the plate shows it")
    local call = tipCalls[#tipCalls]
    eq(call.anchor, row, "tooltip: ...anchored to the ROW, not to a hit frame over its label")
    eq(call.spec.title, "Hide Self", "tooltip: a bare string is titled with the row's own name")
    eq(call.spec.lines[1], "Removes your player frame.", "tooltip: ...and carries the sentence")
    -- The paint is untouched by the tooltip: both still happen on one hover.
    eq(row.plate._fill.a, M.hoverFill, "tooltip: ...and the plate still lifts, because nothing stole the hover")

    row:GetScript("OnLeave")()
    eq(tipHidden, hidBefore + 1, "tooltip: leaving hides it")
    eq(row.plate._fill.a, M.restFill, "tooltip: ...and the plate drops back")

    -- A row with no tooltip asks for nothing and hides nothing -- the hover paint
    -- is the whole of its OnEnter, exactly as before.
    local n, hid = #tipCalls, tipHidden
    local bare = host:CreateControlRow(FakeUIFrame(), { label = "Bare", kind = "checkbox" })
    bare:GetScript("OnEnter")()
    bare:GetScript("OnLeave")()
    eq(#tipCalls, n, "tooltip: a row without one shows nothing")
    eq(tipHidden, hid, "tooltip: ...and hides nothing on the way out")

    -- A full spec is passed straight through rather than re-wrapped.
    local spec = { title = "Own Title", lines = { "a", "b" } }
    local dd = host:CreateControlRow(FakeUIFrame(), {
        label = "Anchor", kind = "dropdown", options = { A = "A" }, tooltip = spec,
    })
    dd:GetScript("OnEnter")()
    eq(tipCalls[#tipCalls].spec, spec, "tooltip: a table spec reaches the surface untouched")
    -- ...and it still reaches the embedded factory, which is where the override
    -- markers and the result card look for it.
    eq(dd.control._dropdownOpts.tooltip, spec, "tooltip: ...and the factory is still handed it too")
    dd:GetScript("OnLeave")()
end

-- ============================================================
-- 4. hideOn
-- Stamped on the frame, so a settings group's own layout honours it like any
-- other widget's -- the slot COLLAPSES, it does not leave a hole.
-- ============================================================
print("-- ControlRow: hideOn collapses the slot in a settings group")
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280, { chromeless = true })
    g:SetWidth(280)

    local before = FakeUIFrame(0, 20); before.preferredHeight = 20
    local after  = FakeUIFrame(0, 20); after.preferredHeight = 20
    settingsDB.hideIt = false
    local row = host:CreateControlRow(FakeUIFrame(), {
        label = "Width", kind = "slider", min = 1, max = 40, step = 1,
        hideOn = function(d) return d.hideIt end,
    })
    check(type(rawget(row, "hideOn")) == "function", "hideOn: the predicate is stamped on the frame")

    g:AddWidget(before, 20)
    g:AddWidget(row)
    g:AddWidget(after, 20)

    local function offsetY(w) local p = w._points[#w._points]; return p and p[5] end

    g:LayoutChildren()
    check(row:IsShown(), "hideOn: with the predicate false the row is laid out")
    eq(offsetY(row), -(10 + 20), "hideOn: ...one row down from the group's inset")
    eq(offsetY(after), -(10 + 20 + ROW_H), "hideOn: ...and the next widget clears its whole slot")
    eq(g:GetHeight(), 10 + 20 + ROW_H + 20 + 10, "hideOn: the group is its three rows plus its inset")

    settingsDB.hideIt = true
    g:LayoutChildren()
    check(not row:IsShown(), "hideOn: with it true the row is hidden")
    eq(offsetY(after), -(10 + 20), "hideOn: ...and the widget after it moves UP into the slot")
    eq(g:GetHeight(), 10 + 20 + 20 + 10, "hideOn: the group is exactly one slot shorter")

    settingsDB.hideIt = false
    g:LayoutChildren()
    eq(offsetY(after), -(10 + 20 + ROW_H), "hideOn: and flipping it back re-opens the slot")
    settingsDB.hideIt = nil
end

-- ============================================================
-- 5. refreshValue
-- A group reset writes thirteen keys behind every widget's back, and the UNDO of
-- one replays the same apply. `refreshValue` is the one name Sections'
-- RefreshChildValues calls to make every control re-read what it is bound to.
-- ============================================================
print("-- ControlRow: refreshValue re-reads the db")
do
    local db = { size = 12, on = false, mode = "A", w = "5" }

    local slider = host:CreateControlRow(FakeUIFrame(), {
        label = "Width", kind = "slider", db = db, key = "size",
        min = 1, max = 40, step = 1,
    })
    eq(slider.control._value, 12, "slider: the control painted the db value at build")
    db.size = 30
    slider:refreshValue()
    eq(slider.control._value, 30, "slider: refreshValue re-reads it")

    local tick = host:CreateControlRow(FakeUIFrame(), {
        label = "Enabled", kind = "checkbox", db = db, key = "on",
    })
    eq(tick.checkButton:GetChecked(), false, "checkbox: the tick painted the db value at build")
    db.on = true
    tick:refreshValue()
    eq(tick.checkButton:GetChecked(), true, "checkbox: refreshValue repaints the tick")

    -- The fallback chain: the edit box publishes only `Refresh`, and the row has
    -- to find it.
    local eb = host:CreateControlRow(FakeUIFrame(), {
        label = "Width", kind = "editbox", db = db, key = "w",
    })
    eq(eb.control._value, "5", "editbox: bound at build")
    db.w = "9"
    eb:refreshValue()
    eq(eb.control._value, "9", "editbox: ...and reached through the Refresh fallback")

    -- The group-wide sweep drives it by name, and the STATE sweep's name reaches
    -- the same repaint plus the grey pass.
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280, { chromeless = true })
    g:SetWidth(280)
    g:AddWidget(slider)
    db.size = 7
    g:RefreshChildValues()
    eq(slider.control._value, 7, "group: RefreshChildValues reaches the row by name")
    db.size = 8
    slider:refreshContent(db)
    eq(slider.control._value, 8, "group: and refreshContent repaints the value too")
end

-- ============================================================
-- 6. THE BINDING
-- A {db, key} binding is a SETTING, and settings go through the host's setting
-- hooks -- the rule PopoutRow._Write states. A control that wrote the key bare
-- would disagree with every other control bound to the same key.
-- ============================================================
print("-- ControlRow: the binding routes writes through the host's setting hooks")
do
    local db = { on = false }
    local written, intercepted = {}, false
    local hooked = setmetatable({ hooks = {
        L = L,
        getSettingsDB = function() return settingsDB end,
        interceptWrite = function() return intercepted end,
        onSettingWritten = function(t, k, v, label, apply)
            written[#written + 1] = { t = t, k = k, v = v, label = label, apply = apply }
        end,
    } }, { __index = UI })

    local applied = 0
    local commit = function() applied = applied + 1 end
    local row = hooked:CreateControlRow(FakeUIFrame(), {
        label = "Enabled", kind = "checkbox", db = db, key = "on", onChanged = commit,
    })

    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    eq(db.on, true, "binding: the tick wrote the key")
    eq(#written, 1, "binding: ...and told the host about it")
    eq(written[1].k, "on", "binding: naming the key")
    eq(written[1].label, "Enabled", "binding: the row's label names the setting")
    eq(written[1].apply, commit, "binding: and the commit rides along by reference for an undo replay")
    eq(applied, 1, "binding: the consumer's own callback ran once")

    -- A REDIRECTED write: the live value does not change, so neither the write
    -- nor the commit happens -- what the slider, the dropdown and the popout row's
    -- tick all do.
    intercepted = true
    db.on = false
    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    eq(db.on, false, "binding: an intercepted write never lands")
    eq(#written, 1, "binding: ...and the host is not told twice")
    eq(applied, 1, "binding: nor is the commit run")
    intercepted = false
end

-- A TABLE db hands the factory its own dbRef and NO get/set: Widgets' slider and
-- dropdown fire the setting hooks themselves whenever a dbKey is present, so
-- passing both would run a consumer's hooks twice for one edit.
do
    local db = { size = 12 }
    local row = host:CreateControlRow(FakeUIFrame(), {
        label = "Width", kind = "slider", db = db, key = "size", min = 1, max = 40, step = 1,
    })
    local o = row.control._sliderOpts
    check(o.dbRef ~= nil, "dbRef: a table db reaches the factory as a dbRef")
    eq(o.dbRef.db, db, "dbRef: pointing at the very table")
    eq(o.dbRef.key, "size", "dbRef: and the key")
    eq(o.get, nil, "dbRef: ...and the factory is handed no get")
    eq(o.set, nil, "dbRef: ...nor a set, so its own hooks fire exactly once")
end

-- A FUNCTION db is re-resolved on every read, and gets get/set instead: a table
-- that changes under the widget cannot be a stable search or override target.
do
    local party = { size = 12 }
    local raid  = { size = 99 }
    local current = party
    local row = host:CreateControlRow(FakeUIFrame(), {
        label = "Width", kind = "slider", db = function() return current end, key = "size",
        min = 1, max = 100, step = 1,
    })
    local o = row.control._sliderOpts
    eq(o.dbRef, nil, "db fn: no dbRef -- the table is not a stable target")
    check(type(o.get) == "function", "db fn: the factory is bound through a get instead")
    eq(row.control._value, 12, "db fn: the first read went to the first table")
    current = raid
    row:refreshValue()
    eq(row.control._value, 99, "db fn: ...and the next one to the table it now returns")
end

-- The colour row opens the kit's own picker and repaints its chip on accept.
do
    local db = { color = { r = 1, g = 0, b = 0, a = 1 } }
    local row = host:CreateControlRow(FakeUIFrame(), {
        label = "Bar Color", kind = "color", db = db, key = "color", hasAlpha = true,
    })
    eq(row.control.swatch._color.r, 1, "color: the chip paints the bound colour at build")

    local before = #pickerCalls
    row.control:GetScript("OnClick")(row.control)
    eq(#pickerCalls, before + 1, "color: clicking opens the kit's picker")
    local call = pickerCalls[#pickerCalls]
    eq(call.initial.r, 1, "color: seeded with the current colour")
    eq(call.hasAlpha, true, "color: and the alpha bar was asked for")

    call.accept({ r = 0, g = 0.5, b = 1, a = 1 })
    eq(db.color.b, 1, "color: accepting writes the new colour")
    eq(row.control.swatch._color.g, 0.5, "color: ...and repaints the chip")

    -- Disabled means the click is refused, not merely faded.
    row:SetEnabled(false)
    local n = #pickerCalls
    row.control:GetScript("OnClick")(row.control)
    eq(#pickerCalls, n, "color: a greyed chip does not open the picker")
end

-- ---- put the globals back -------------------------------------------
CreateFrame = prevCreateFrame
PlaySound, SOUNDKIT = prevPlaySound, prevSoundKit
