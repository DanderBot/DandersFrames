local NS = ...

-- ============================================================
-- GREYED CONTROLS SAY WHY, LABEL MARKS, MIRRORED TEXT
--   DandersUI/Widgets.lua    widget.disableReason on the label hover (HoverSpec),
--                            UI:SetLabelMark
--   DandersUI/Sections.lua   the grey sweep stamps dfGreyed beside SetEnabled
--   DandersFrames_Options/GUI/Panel.lua           ...and the page-level sweep
--   DandersFrames_Options/GUI/ModuleRegistry.lua  GUI:RefreshPageMarks (pageMark)
--   DandersFrames_Options/GUI/Rail.lua            deck-2 tab marks (tab.mark)
--   DandersFrames/TextDesigner/Render.lua         frame.dfMirrorText
--
-- ⚠ A FRESH NAMESPACE, NOT THE SHARED ONE (test_widgets_slider.lua's reason): the
-- REAL Widgets.lua is installed here, and the shared one carries other suites'
-- fixtures. Every global replaced below is restored at the end.
-- ============================================================

local prevCreateFrame, prevTimer = CreateFrame, C_Timer
local prevDandersFrames = DandersFrames

local ns = {}
local UI = {
    _state = {},
    _priv  = {},
    MEDIA  = "",
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
ns.__DandersUI = UI
function UI.SnapLen(_, n) return n end
function UI.SnapHeightEven(_, n) return n end
function UI.StyleScrollBar() end
function UI._priv.CreateElementBackdrop(frame) return frame end
function UI._priv.CreatePanelBackdrop(frame) return frame end
local ACCENT = { r = 0.45, g = 0.45, b = 0.95, a = 1 }
function UI:GetAccent() return ACCENT end
function UI:Hook(name)
    local h = rawget(self, "hooks")
    return h and h[name] or nil
end
function UI:Call(name, ...)
    local fn = self:Hook(name)
    if not fn then return nil end
    return fn(...)
end

-- A missing DATA field must read nil, not the shim's catch-all no-op function.
local DATA_KEYS = {
    ThemeListeners = true, UpdateOverrideIndicators = true, tooltip = true,
    tooltipText = true, tooltipSubText = true, tooltipSpellID = true,
    searchEntry = true, disableReason = true, Text = true,
}
local function dataAwareMeta(_, k)
    if DATA_KEYS[k] then return nil end
    if type(k) == "string" and k:byte(1) == 95 then return nil end   -- "_"
    return function() end
end
CreateFrame = function(kind, _, parent)
    local f = FakeUIFrame()
    setmetatable(f, { __index = dataAwareMeta })
    f._kind = kind
    f._children = {}
    f._parent = parent
    f.GetParent = function(self) return self._parent end
    f.SetParent = function(self, p) self._parent = p end
    if kind == "Slider" then
        f._value = 0
        f.SetValue = function(self, v) self._value = v end
        f.GetValue = function(self) return self._value end
    end
    return f
end
C_Timer = { After = function(_, fn) fn() end }

load_ui_file_into("Widgets.lua", ns)

local shown
local function newHost(db)
    local hooks = {
        L = setmetatable({}, { __index = function(_, k) return k end }),
        getSettingsDB = function() return db end,
    }
    local host = setmetatable({ hooks = hooks }, { __index = UI })
    host.ShowTooltip = function(_, owner, spec) shown = { owner = owner, spec = spec } end
    return host
end
local function pane() return CreateFrame("Frame") end
local function hover(w)
    shown = nil
    local hit = rawget(w, "dfTooltipHit")
    hit:GetScript("OnEnter")(hit)
    return shown and shown.spec
end

-- ============================================================
-- 1. THE HOVER: a greyed widget with a reason says it, first
-- ============================================================
print("-- Kit: a greyed control's hover says why")
do
    local db = { portraitEnabled = false }
    local host = newHost(db)
    local s = host:CreateSlider(pane(), { label = "Offset X", min = -100, max = 100, step = 1 })
    eq(hover(s), nil, "no tooltip, no reason, not greyed: nothing shows (as before)")

    s.disableReason = "Turn on Portrait to change this"
    eq(hover(s), nil, "a reason alone shows nothing while the control is live")

    rawset(s, "dfGreyed", true)
    local spec = hover(s)
    check(spec ~= nil, "greyed with a reason: the hover shows a tooltip")
    eq(spec and spec.title, "Offset X", "...titled by the control's own label")
    eq(spec and spec.lines and spec.lines[1].text, "Turn on Portrait to change this", "...the reason first")
    eq(spec and spec.lines and spec.lines[1].accent, true, "...in the accent line style")

    -- A function reason reads the page's settings table.
    s.disableReason = function(d) return d.portraitEnabled == false and "off because of d" or nil end
    spec = hover(s)
    eq(spec and spec.lines[1].text, "off because of d", "a function reason is asked with the settings table")
    s.disableReason = function() return nil end
    eq(hover(s), nil, "a function answering nil shows nothing")
    s.disableReason = function() error("boom") end
    eq(hover(s), nil, "a reason that throws shows nothing and does not throw")

    -- The widget's own tooltip stays, after the reason, and is never written to.
    local own = { title = "Offset X", lines = { "Moves it sideways." } }
    s.tooltip = own
    s.disableReason = "Turn on Portrait to change this"
    spec = hover(s)
    eq(#spec.lines, 2, "greyed: the reason, then the widget's own lines")
    eq(spec.lines[2], "Moves it sideways.", "...in their own order")
    eq(#own.lines, 1, "the widget's own spec table is not mutated")

    rawset(s, "dfGreyed", nil)
    spec = hover(s)
    eq(spec, own, "re-enabled: the widget's own tooltip, untouched")
end

-- ============================================================
-- 2. THE STAMP: both grey sweeps mark what they decided
-- ============================================================
print("-- Kit: the grey sweeps stamp dfGreyed beside SetEnabled")
do
    local sec = ui_file_source("Sections.lua")
    local set = sec:find("widget:SetEnabled(not shouldDisable)", 1, true)
    local stamp = sec:find('rawset(widget, "dfGreyed", shouldDisable and true or nil)', 1, true)
    check(set and stamp and set < stamp, "Sections: RefreshChildStates stamps dfGreyed after SetEnabled")
    local panel = options_file_source("GUI/Panel.lua")
    check(panel:find('rawset(widget, "dfGreyed", shouldDisable and true or nil)', 1, true),
          "Panel: the page-level sweep stamps it too")
    local w = ui_file_source("Widgets.lua")
    check(w:find("local spec = HoverSpec(host, widget, label)", 1, true),
          "Widgets: the label hover goes through HoverSpec")
end

-- ============================================================
-- 3. UI:SetLabelMark
-- ============================================================
print("-- Kit: a label mark")
do
    local host = newHost({})
    local function tab()
        local b = CreateFrame("Button")
        b:SetWidth(58)
        b.Text = b:CreateFontString()
        b.Text:SetText("TARGET")                    -- 42 wide in the shim
        b.Text:SetPoint("CENTER", b, "CENTER", 0, 0)
        return b
    end
    local b = tab()
    local m = host:SetLabelMark(b, { texture = "link.png", size = 12, gap = 3 })
    check(m ~= nil, "a mark is drawn")
    eq(m:GetTexture(), "link.png", "...with the texture asked for")
    eq(m._w, 12, "...at its size")
    local p, rel, relP, x = m:GetPoint(1)
    eq(p, "LEFT", "...right after the label")
    eq(rel, b.Text, "...anchored to the label")
    eq(x, 3, "...one gap away")
    local tp, _, _, tx = b.Text:GetPoint(1)
    eq(tp, "CENTER", "a centred label stays centred...")
    eq(tx, -7.5, "...nudged left by half the mark, so the pair is centred")
    host:SetLabelMark(b, { texture = "link.png", size = 12, gap = 3 })
    _, _, _, tx = b.Text:GetPoint(1)
    eq(tx, -7.5, "idempotent: a repaint does not nudge it twice")
    eq(m._vertex and m._vertex.r, 0.5, "tinted the dim text colour by default")
    host:SetLabelMark(b, nil)
    eq(m:IsShown(), false, "cleared: the mark hides")
    _, _, _, tx = b.Text:GetPoint(1)
    eq(tx, 0, "...and the label goes back where it was")

    local g = tab()
    host:SetLabelMark(g, { texture = "link.png", grow = true })
    eq(g:GetWidth(), 42 + 12 + 3 + 10, "grow: a tab that no longer fits widens")
    local g2 = tab()
    g2:SetWidth(200)
    host:SetLabelMark(g2, { texture = "link.png", grow = true })
    eq(g2:GetWidth(), 200, "grow only: a wide enough tab keeps its width")

    local row = CreateFrame("Button")
    row:SetWidth(180)
    row.Text = row:CreateFontString()
    row.Text:SetText("Health Bar")
    row.Text:SetPoint("LEFT", 24, 0)
    host:SetLabelMark(row, { texture = "link.png" })
    eq(#row.Text._points, 1, "a LEFT-anchored row label is left alone")
    eq(row:GetWidth(), 180, "...and the row keeps the width its container gave it")

    eq(host:SetLabelMark(CreateFrame("Button"), { texture = "x" }), nil, "a button with no label: nothing")
end

-- ============================================================
-- 4. THE HOST: sidebar rows and deck tabs ask their module
-- ============================================================
print("-- Host: page marks and tab marks")
do
    local marks = {}
    -- The window state ModuleRegistry.lua reads at load (its built-in modules
    -- register, and it syncs the selected one) -- test_uf_pages.lua's NewGUI shape.
    local G = {
        Tabs = {}, ModulePageOwner = {},
        SelectedMode = "party", GlobalView = false, GlobalPages = {}, Pages = {},
        Colors = { text = { r = 1, g = 1, b = 1 }, textDim = { r = 0.5, g = 0.5, b = 0.5 } },
    }
    function G.IsGlobalPage() return false end
    function G.GetThemeColorFor(isRaid) return isRaid and "RAID" or "PARTY" end
    function G:SetAccent() end
    function G.CurrentAccent() return "ACCENT" end
    function G.UpdateThemeColors() end
    function G:LastTabInView() return nil end
    function G:EnterView(gv) G.GlobalView = gv and true or false end
    -- Records what was asked, and leaves the mark texture behind the way the real
    -- one does (a cleared mark is hidden, not removed).
    function G:SetLabelMark(btn, spec)
        marks[btn] = spec or false
        if spec then btn.dfLabelMark = true end
    end
    local DF = { GUI = G, L = setmetatable({}, { __index = function(_, k) return k end }) }
    function DF:DebugError() end
    DandersFrames = DF
    load_options_file_into("GUI/ModuleRegistry.lua", {})
    check(type(G.RefreshPageMarks) == "function", "GUI:RefreshPageMarks exists")

    local SPEC = { texture = "link.png" }
    G:RegisterModule({ id = "units", label = "Units",
        pageMark = function(name) return name == "uf_target_health" and SPEC or nil end })
    G:RegisterModule({ id = "other", label = "Other" })
    local a, b, c, d = {}, {}, {}, {}
    G.Tabs = { uf_target_health = a, uf_target_power = b, bars_health = c, plain = d }
    G.ModulePageOwner = { uf_target_health = "units", uf_target_power = "units", bars_health = "other" }
    G:RefreshPageMarks()
    eq(marks[a], SPEC, "a module page with a mark gets it")
    eq(marks[b], nil, "a module page with no mark and none drawn: left alone")
    eq(marks[c], nil, "a module with no pageMark: never asked")
    eq(marks[d], nil, "a page no module owns: never asked")
    b.dfLabelMark = {}
    G:RefreshPageMarks()
    eq(marks[b], false, "a row that HAD a mark and now has none is cleared")
    G:RegisterModule({ id = "units", label = "Units", pageMark = function() error("boom") end })
    G:RefreshPageMarks()
    eq(marks[a], false, "a pageMark that throws clears rather than breaking the sidebar")

    local panel = options_file_source("GUI/Panel.lua")
    check(panel:find("if GUI.RefreshPageMarks then GUI:RefreshPageMarks() end", 1, true),
          "Panel: every sidebar layout repaints the marks")
    local rail = options_file_source("GUI/Rail.lua")
    check(rail:find("local spec = on and Resolve(tab.mark) or nil", 1, true)
          and rail:find("GUI:SetLabelMark(b, spec)", 1, true),
          "Rail: a deck tab paints its module tab's mark")
end

-- ============================================================
-- 5. TEXT DESIGNER: a frame can draw its text mirrored
-- ============================================================
print("-- Text Designer: mirrored text")
do
    local TDF = {}
    load_df_file_into("TextDesigner/Render.lua", TDF)
    local R = TDF.TextDesigner.Render
    check(type(R.Placement) == "function", "Render.Placement exists")
    local plain, mirrored = {}, { dfMirrorText = true }
    local function place(f, anchor, x, y) return R.Placement(f, { anchor = anchor, offsetX = x, offsetY = y }) end
    local p, x, y = place(plain, "TOPLEFT", 6, -2)
    eq(p .. "," .. x .. "," .. y, "TOPLEFT,6,-2", "an ordinary frame: as the template says")
    p, x, y = place(mirrored, "TOPLEFT", 6, -2)
    eq(p .. "," .. x .. "," .. y, "TOPRIGHT,-6,-2", "mirrored: point flipped, x negated, y kept")
    for _, pt in ipairs({ "LEFT", "RIGHT", "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }) do
        eq(R.MirrorPoint(R.MirrorPoint(pt)), pt, "mirror is self-inverse: " .. pt)
        check(R.MirrorPoint(pt) ~= pt, "mirror moves " .. pt)
    end
    for _, pt in ipairs({ "CENTER", "TOP", "BOTTOM" }) do
        eq(R.MirrorPoint(pt), pt, "a centred point stays: " .. pt)
    end
    p, x = place(mirrored, nil, nil, nil)
    eq(p, "CENTER", "no anchor: CENTER, mirrored or not")
    eq(tostring(x), "0", "a zero offset stays 0, never -0")
    p = place({ dfMirrorText = function() end }, "LEFT", 1, 0)
    eq(p, "LEFT", "only a real true mirrors (a stub's catch-all is not a yes)")
    local src = df_file_source("TextDesigner/Render.lua")
    check(src:find("local point, x, y = placement(frame, elem)", 1, true),
          "applyPosition lays out through the placement")
end

DandersFrames = prevDandersFrames
CreateFrame, C_Timer = prevCreateFrame, prevTimer
