local NS = ...

-- ============================================================
-- TEST HOST -- CreateSettingsGroup (DandersUI/Sections.lua)
-- ------------------------------------------------------------
-- Two opt-in options, both added for popout gate two, and both are only
-- interesting because EVERY existing call site must be untouched by them:
--
--   opts.chromeless -- skip the box. A group mounted as the whole contents of a
--       popout pane is not a box ON a surface, it IS the surface's contents, and
--       a faint bordered rectangle inside a panel reads as a second panel.
--   opts.padding    -- the column inset. 0 for that same case, because the
--       popout already pads. LayoutChildren reads self.padding, so the option
--       has to reach the field and the local it lays out with alike.
--
-- ☠ A FRESH NAMESPACE, not the shared `ns` run.py hands every other suite.
-- Sections.lua installs CreateSettingsGroup / the banners / the tooltip onto
-- whatever table its NS.__DandersUI points at, and the shared one is the object
-- the popout suites' live closures were built from. This file therefore stubs a
-- private kit surface and loads into that, so nothing it does is visible to any
-- other file. CreateFrame is a global, so that one is saved and restored.
-- ============================================================

local UI = {
    MEDIA = "",
    Colors = {
        background = { r = 0.08, g = 0.08, b = 0.08, a = 0.95 },
        text       = { r = 0.9,  g = 0.9,  b = 0.9 },
        textDim    = { r = 0.5,  g = 0.5,  b = 0.5 },
    },
    -- The layout metrics LayoutChildren reads. RowCompact empty on purpose: the
    -- run-tightening has its own coverage and would only add noise to the
    -- arithmetic these tests are about.
    RowGap = 14, RowGapTight = 6, RowCompact = {},
    _state = {},
    _priv = {
        INFO_BANNER_TONES = {},
        AddTooltipLines = function() end,
        CURSOR_LIFT_X = 0, CURSOR_LIFT_Y = 0,
        -- RECORDS rather than paints: "was the box drawn at all" is the whole of
        -- the chromeless claim, and it is only answerable as this being called.
        CreateElementBackdrop = function(frame, opts)
            frame._elementOpts = opts
            return frame
        end,
    },
}
-- No snapping: every offset below is asserted as the arithmetic the layout did,
-- and a rounding pass would make those numbers about the device grid instead.
function UI.SnapLen(_, n) return n end
function UI.ResolveRowHeight(widget, height)
    if widget and widget.fixedRowHeight and widget.preferredHeight then
        return widget.preferredHeight
    end
    return height or (widget and widget.preferredHeight) or 55
end
function UI:GetAccent() return { r = 0.45, g = 0.45, b = 0.95, a = 1 } end
function UI:Hook(name)
    local h = rawget(self, "hooks")
    return h and h[name] or nil
end
function UI:Call(name, ...)
    local fn = self:Hook(name)
    if not fn then return nil end
    return fn(...)
end

-- ---- WoW globals ----------------------------------------------------
local prevCreateFrame = CreateFrame
CreateFrame = function(kind, _, parent)
    local f = FakeUIFrame()
    f._kind = kind
    f._parent = parent
    f.GetParent = function(self) return self._parent end
    f.SetParent = function(self, p) self._parent = p end
    return f
end

load_ui_file_into("Sections.lua", { __DandersUI = UI })

local settingsDB = {}
local host = setmetatable({ hooks = { getSettingsDB = function() return settingsDB end } },
                          { __index = UI })

-- A control the group can lay out: a fixed slot height and a recorded anchor.
local function control(h)
    local w = FakeUIFrame(0, h or 20)
    w.preferredHeight = h or 20
    return w
end

-- The y offset the group anchored a widget at, read back off the recorded point.
local function offsetY(w)
    local pt = w._points[#w._points]
    return pt and pt[5]
end

-- ============================================================
-- 1. THE DEFAULT IS UNCHANGED
-- Both options are opt-in, so a call site that passes neither -- which is every
-- call site in the addon -- has to build exactly the box it always did.
-- ============================================================
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280)
    check(g._elementOpts ~= nil, "default: the box is drawn")
    eq(g._elementOpts.bgColor[4], 0.03, "default: at the 3% fill")
    eq(g._elementOpts.borderColor[4], 0.08, "default: inside the 8% border")
    eq(g.padding, 10, "default: and the column inset is the standard 10")
end

-- The legacy boolean form still means `collapsible`, and reaches neither option.
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280, true)
    check(g.collapsible, "legacy: a boolean opts is still the collapsible flag")
    check(g._elementOpts ~= nil, "legacy: ...and the box is still drawn")
    eq(g.padding, 10, "legacy: ...at the standard inset")
end

-- ============================================================
-- 2. CHROMELESS
-- ============================================================
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 260, { chromeless = true })
    -- rawget: the stub answers every unknown key with a function, so a plain read
    -- would find one and the claim could never fail.
    eq(rawget(g, "_elementOpts"), nil, "chromeless: no backdrop was ever applied")
    check(g.isSettingsGroup, "chromeless: it is still a settings group in every other way")
    eq(g.padding, 10, "chromeless: and chromeless alone does not touch the inset")
end

-- Chromeless composes with the rest: a collapsible chromeless group still gets
-- its collapse bar, which is a child frame rather than part of the box.
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 260,
                                       { chromeless = true, collapsible = true })
    eq(rawget(g, "_elementOpts"), nil, "chromeless: still no box when collapsible")
    check(rawget(g, "collapseBar") ~= nil, "chromeless: but the collapse bar is still built")
end

-- ============================================================
-- 3. PADDING
-- The number has to reach BOTH the field a consumer reads and the local
-- LayoutChildren lays out from, or a group would report one inset and draw
-- another.
-- ============================================================
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 260, { padding = 0 })
    eq(g.padding, 0, "padding: zero is honoured, not treated as absent")

    g:SetWidth(260)
    local a, b = control(30), control(40)
    g:AddWidget(a)
    g:AddWidget(b)
    local total = g:LayoutChildren()

    eq(offsetY(a), 0, "padding: the first row starts flush with the group's top")
    eq(offsetY(b), -30, "padding: and the second a row down, with no inset in between")
    eq(a:GetWidth(), 260, "padding: a zero inset gives children the group's full width")
    eq(g:GetHeight(), 70, "padding: the group is exactly its rows")
    eq(total, 70 + g.margin, "padding: ...and reports that plus the between-groups margin")
end

-- The default still pads on both sides, so the change above really is the
-- option's doing and not a layout that stopped padding altogether.
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 260)
    g:SetWidth(260)
    local a = control(30)
    g:AddWidget(a)
    g:LayoutChildren()
    eq(offsetY(a), -10, "padding: the default still insets the first row by 10")
    eq(a:GetWidth(), 240, "padding: ...and takes it off both sides of the width")
    eq(g:GetHeight(), 50, "padding: 30 of row between two 10s")
end

-- A non-numeric padding is ignored rather than propagated: a consumer that
-- passes junk gets the standard box, not a group that errors mid-layout.
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 260, { padding = "wide" })
    eq(g.padding, 10, "padding: a non-number falls back to the standard inset")
end

-- ============================================================
-- 4. BOTH, WHICH IS THE POPOUT'S CALL
-- The shape the Frame page's Border row mounts: chromeless, zero inset, at the
-- popout's content width, so the controls inside land at exactly the width they
-- would have had on the page.
-- ============================================================
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 260, { chromeless = true, padding = 0 })
    eq(rawget(g, "_elementOpts"), nil, "popout shape: no box")
    eq(g.padding, 0, "popout shape: no inset")
    g:SetWidth(260)
    local a = control(55)
    g:AddWidget(a)
    g:LayoutChildren()
    eq(a:GetWidth(), 260, "popout shape: a control mounts at the full content width")
    eq(g:GetHeight(), 55, "popout shape: and the group measures its rows exactly")
end

CreateFrame = prevCreateFrame
