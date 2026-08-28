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
        -- The row plate's pair, which the band-styled box paints with. Distinct
        -- numbers from each other and from every colour above, so an assertion
        -- that a plate wears C_ELEMENT over C_BORDER cannot pass by coincidence.
        element    = { r = 0.20, g = 0.21, b = 0.22 },
        border     = { r = 0.31, g = 0.32, b = 0.33 },
    },
    -- The layout metrics LayoutChildren reads. RowCompact empty on purpose: the
    -- run-tightening has its own coverage and would only add noise to the
    -- arithmetic these tests are about.
    RowGap = 14, RowGapTight = 6, RowCompact = {},
    -- The settings column's box model, which CreateSettingsGroup now takes its
    -- `width or` and `padding or` defaults from rather than repeating them as
    -- literals. Stated at the REAL values (DandersUI/Theme.lua) so the default
    -- tests below still assert the shipped numbers.
    SettingsBox = { group = 280, pad = 10, colMargin = 5, minCol = 285, colGutter = 20 },
    PopoutContentWidth = 260,
    -- The popout half of the box model, which the BAND-STYLED group takes its
    -- inset and its plate paint from. Real values (DandersUI/Theme.lua) for the
    -- same reason SettingsBox is: the assertions below are about the shipped
    -- rhythm, not about numbers this file invented.
    PopoutPad = 10,
    PopoutRow = { plate = 44, gap = 6, padX = 10, restFill = 0.55, restBorder = 0.5 },
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
-- ---- the surface style, borrowed whole from the shared library table --
-- The group box wears whichever shape the HOST declared (see CreateSettingsGroup's
-- note on why this one surface is not told per call site), so this private kit
-- needs the resolver and the rounded primitive. They are TAKEN, not written: the
-- shared table already carries the real Theme.lua resolver and the real Round.lua
-- (run.py lifts both), and a second implementation here would be a test that
-- agrees with itself.
do
    local SHARED = NS.__DandersUI
    for _, name in ipairs({ "SurfaceStyle", "ResolveSurfaceStyle", "SetSurfaceStyle",
                            "GetSurfaceStyle", "HidePixelBorder",
                            "CreateRoundedSurface", "GetRoundedSurface",
                            "ApplyRoundedChrome", "RemoveRoundedChrome" }) do
        UI[name] = SHARED[name]
    end
end

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


-- ============================================================
-- 5. THE SURFACE STYLE
--
-- ☠ THIS IS THE ONE SURFACE IN THE PACK THAT IS NOT TOLD PER CALL SITE, and the
-- reason is arithmetic: every other shell that can wear either shape is built at
-- a handful of places and can be handed a style, while a settings group is built
-- at something over a hundred, on every page. Threading a style through all of
-- them means the ONE that gets missed is the box that stays square in a round
-- window -- so the style is asked for once, off the HOST that declared it.
--
-- Which makes the DEFAULT the load-bearing assertion: a host that declared
-- nothing has to build exactly the box it always did, because that is every call
-- site in DandersMover and every call site in DandersFrames on the day before
-- the shell went round.
-- ============================================================
print("-- Group: a host that declared no style builds the square box")
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280)
    check(g._elementOpts ~= nil, "no style: the square element backdrop is what was issued")
    check(UI:GetRoundedSurface(g) == nil, "no style: and no rounded surface exists")
end

print("-- Group: a rounded host rounds the box, at the ROW weight")
do
    host:SetSurfaceStyle(UI.SurfaceStyle)
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280)
    local rs = UI:GetRoundedSurface(g)
    check(rs ~= nil and rs:IsShown(), "rounded: the box wears a rounded surface")
    local r, w = rs:GetRadius()
    eq(r, UI.SurfaceStyle.radius, "rounded: at the declared radius")
    -- A page column is a STACK of these boxes, and at the panel's two units a
    -- column of them reads as a grid of frames rather than as sections of a page.
    eq(w, UI.SurfaceStyle.rowBorderWidth, "rounded: and the row border width, not the panel's")
    -- The COLOURS are the square box's, verbatim: 3% white over an 8% white edge.
    -- The only thing that changed is the corner.
    eq(rs.fillA, 0.03, "rounded: the same 3% fill")
    eq(rs.borderA, 0.08, "rounded: inside the same 8% border")
    check(rawget(g, "_pxHidden") == true, "rounded: the square pixel border came down")
    host:SetSurfaceStyle(nil)
end

print("-- Group: chromeless outranks the style")
do
    -- A group mounted as the whole contents of another surface is not a box ON a
    -- page, it IS the contents -- and a faint ROUNDED rectangle inside a panel
    -- reads as a second panel every bit as much as a square one does.
    host:SetSurfaceStyle(UI.SurfaceStyle)
    local g = host:CreateSettingsGroup(FakeUIFrame(), 260, { chromeless = true, padding = 0 })
    eq(rawget(g, "_elementOpts"), nil, "chromeless: no square box")
    check(UI:GetRoundedSurface(g) == nil, "chromeless: and no rounded one either")
    host:SetSurfaceStyle(nil)
end

print("-- Group: opts.surface overrides the host, both ways")
do
    -- The per-box escape hatch. Nothing in the pages uses it today; it exists so
    -- a box that must not follow the shell has a way to say so that is not
    -- "chromeless", which means something else entirely.
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280, { surface = UI.SurfaceStyle })
    check(UI:GetRoundedSurface(g) ~= nil, "an explicit style rounds a box on a square host")

    host:SetSurfaceStyle(UI.SurfaceStyle)
    local sq = host:CreateSettingsGroup(FakeUIFrame(), 280, { surface = false })
    check(UI:GetRoundedSurface(sq) == nil, "...and false squares one on a rounded host")
    check(sq._elementOpts ~= nil, "...with the square backdrop issued as before")
    host:SetSurfaceStyle(nil)
end

-- ============================================================
-- 6. BAND STYLE -- THE STAY-INLINE BOX'S SKIN
--
-- A page half-converted to bands speaks two visual languages: the converted
-- sections are an accent header ABOVE a stack of fat row plates, the survivors
-- are the classic dense box with the title INSIDE a faint white rectangle.
-- Danders, on the converted Frame page: "Layout Direction does not match the
-- Appearance settings."
--
-- bandStyle is the survivors' half, and it is exactly two moves: the TITLE
-- leaves the box, and the BOX becomes a row plate. The widgets inside are
-- untouched -- same factories, same order, same slots -- which is what makes
-- this a skin rather than a conversion.
--
-- ☠ THE LOAD-BEARING ASSERTION IS STILL THE DEFAULT. Every call site that does
-- not ask for it has to build exactly the box it always did, which section 1
-- above pins; what is pinned here is that the opt does the two things it claims
-- and touches nothing else.
-- ============================================================

-- The x/y a widget was anchored at, and the FIRST recorded point rather than the
-- last: the plate is anchored twice (TOPLEFT and BOTTOMRIGHT) and it is the top
-- edge that carries the claim.
local function pointAt(w, i)
    local pt = w._points[i or 1]
    return pt and pt[4], pt and pt[5]
end

-- A title row: the first child of every settings group in this kit, and the one
-- child a band-styled box draws outside its plate.
local function headerRow(h)
    local w = control(h or 37)
    w.rowKind = "header"
    return w
end

print("-- Group: bandStyle takes the title out of the box and the box off the plate")
do
    host:SetSurfaceStyle(UI.SurfaceStyle)
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280, { bandStyle = true })

    -- 1. THE BOX ITSELF WEARS NOTHING. Neither the square backdrop nor a rounded
    --    surface: what carries the chrome is the plate, and a group drawing both
    --    would be a rectangle with a second rectangle inside it.
    eq(rawget(g, "_elementOpts"), nil, "band: the group frame is not itself a box")
    check(UI:GetRoundedSurface(g) == nil, "band: ...and carries no rounded surface either")

    -- 2. THE PLATE EXISTS, and it is a child frame rather than the group's own
    --    backdrop -- a backdrop covers the whole rect by definition, and the
    --    whole point is that this one stops short of the top edge.
    local plate = rawget(g, "bandPlate")
    check(plate ~= nil, "band: a plate frame is built for the chrome")
    eq(plate:GetFrameLevel(), g:GetFrameLevel(),
       "band: pinned to the group's own level, so it stays under every widget in it")

    -- 3. ...WEARING THE ROW PLATE'S PAINT. The same C_ELEMENT-over-C_BORDER pair
    --    at the same alphas a PopoutRow uses, at the ROW border weight, so an
    --    inline box and the plates beside it are one surface.
    local rs = UI:GetRoundedSurface(plate)
    check(rs ~= nil and rs:IsShown(), "band: the plate wears a rounded surface")
    local r, w = rs:GetRadius()
    eq(r, UI.SurfaceStyle.radius, "band: at the shell's radius")
    eq(w, UI.SurfaceStyle.rowBorderWidth, "band: and the ROW border weight, not the panel's")
    eq(rs.fillA, UI.PopoutRow.restFill, "band: the row plate's rest fill")
    eq(rs.borderA, UI.PopoutRow.restBorder, "band: inside the row plate's rest border")

    -- 4. AND THE POPOUT PANE'S INSET, not the settings column's. Equal numbers
    --    today; separate tokens because only one of them follows the popout.
    eq(g.padding, UI.PopoutPad, "band: the inner inset is the popout pane's")

    host:SetSurfaceStyle(nil)
end

print("-- Group: bandStyle's rhythm is the band's own header-to-plate gap")
do
    host:SetSurfaceStyle(UI.SurfaceStyle)
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280, { bandStyle = true })
    g:SetWidth(280)
    local plate = rawget(g, "bandPlate")

    local head = g:AddWidget(headerRow(37), 37)
    local a, b = control(55), control(55)
    g:AddWidget(a, 55)
    g:AddWidget(b, 55)
    local total = g:LayoutChildren()

    -- The header sits where a header always sat: one inset down, one inset in.
    -- ⚠ THE X IS THE ALIGNMENT CLAIM. A band is a chromeless container at this
    -- same inset with its header as child one, so a band header and this one land
    -- on the same column of the page -- which is the whole of "the titles line up".
    local hx, hy = pointAt(head)
    eq(hx, 10, "band: the title is inset by the group's own padding, like a band's")
    eq(hy, -10, "band: ...and one inset below the top, with no box above it")

    -- The plate starts exactly where the first row WOULD have started in a normal
    -- box -- which is where a band's first row plate starts under its own header.
    -- That equality is the rhythm: same gap under the title on both.
    local px, py = pointAt(plate)
    eq(px, 0, "band: the plate spans the group's full width")
    eq(py, -(10 + 37), "band: and starts at the y a band's first row plate does")
    check(plate:IsShown(), "band: the plate is drawn")

    -- ...and the rows are then inset INSIDE it, exactly as a popout row's content
    -- is inset inside its own plate.
    eq(offsetY(a), -(10 + 37 + 10), "band: the first row sits one inset inside the plate")
    eq(offsetY(b), -(10 + 37 + 10 + 55), "band: and the second a slot below it")
    eq(g:GetHeight(), 10 + 37 + 10 + 55 + 55 + 10,
       "band: the box is lead-in + title + plate inset + rows + plate inset")
    eq(total, g:GetHeight() + g.margin, "band: ...plus the between-groups margin, as always")

    host:SetSurfaceStyle(nil)
end

print("-- Group: bandStyle on a square host, and the options it composes with")
do
    -- A consumer that never opted into a surface style gets the plate as a SQUARE
    -- element backdrop -- same two colours, no arc. The plate is still a separate
    -- frame, so the title is still outside it.
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280, { bandStyle = true })
    local plate = rawget(g, "bandPlate")
    check(plate ~= nil, "band/square: the plate is built on a square host too")
    check(rawget(plate, "_elementOpts") ~= nil, "band/square: wearing the square backdrop")
    eq(plate._elementOpts.bgColor[4], UI.PopoutRow.restFill, "band/square: at the plate's fill")
    eq(plate._elementOpts.borderColor[4], UI.PopoutRow.restBorder, "band/square: and its border")
    eq(rawget(g, "_elementOpts"), nil, "band/square: and the group is still not a box")

    -- CHROMELESS OUTRANKS IT, the same way it outranks the surface style: a group
    -- that IS another surface's contents must not draw a plate in there either.
    local c = host:CreateSettingsGroup(FakeUIFrame(), 260,
                                       { bandStyle = true, chromeless = true, padding = 0 })
    eq(rawget(c, "bandPlate"), nil, "band: chromeless outranks it -- no plate")
    eq(c.bandStyle, false, "band: ...and the group does not claim the skin")
    eq(c.padding, 0, "band: ...nor does it take the popout inset over an explicit one")

    -- An explicit padding still wins over the band default.
    local p = host:CreateSettingsGroup(FakeUIFrame(), 280, { bandStyle = true, padding = 4 })
    eq(p.padding, 4, "band: an explicit inset outranks the popout default")
end

print("-- Group: a collapsed bandStyle box draws no empty plate")
do
    -- Nothing behind the title to put in a plate, and a 20px empty rectangle
    -- under a collapsed heading reads as a rendering fault rather than a section.
    host:SetSurfaceStyle(UI.SurfaceStyle)
    -- ⚠ A REAL ThemeListeners table on the parent. The collapse arrow registers
    -- itself there, and the stub answers an unset key with a no-op FUNCTION --
    -- so a bare FakeUIFrame would have the header setup table.insert into one.
    local parent = FakeUIFrame()
    parent.ThemeListeners = {}
    local g = host:CreateSettingsGroup(parent, 280, { bandStyle = true, collapsible = true })
    g:SetWidth(280)
    local plate = rawget(g, "bandPlate")
    -- Same stub artefact, one field further on: the collapse path guards on
    -- `self.collapseSummary` before anything has built one, and an unset key on a
    -- FakeUIFrame is a function rather than nil. Seeded with the fontstring the
    -- lazy branch would have made, so the real guard is exercised rather than
    -- bypassed.
    g.collapseSummary = FakeUIFrame()

    local head = headerRow(37)
    head.text = FakeUIFrame()
    head.text:SetText("Frame Size")
    g:AddWidget(head, 37)
    g:AddWidget(control(55), 55)

    g:LayoutChildren()
    check(plate:IsShown(), "band/collapse: expanded, the plate is drawn")

    g.collapsed = true
    g:LayoutChildren()
    check(not plate:IsShown(), "band/collapse: collapsed, it is not")
    eq(g:GetHeight(), 10 + 37 + 10, "band/collapse: ...and its inset is not charged to the height")

    host:SetSurfaceStyle(nil)
end

-- ============================================================
-- RefreshChildValues -- THE VALUE SWEEP
-- ------------------------------------------------------------
-- ☠ THE BUG IT EXISTS FOR: with a feature row's popout open, "Reset Group" wrote
-- thirteen keys, moved the frames and repainted the row summary -- and left every
-- control inside the panel showing the values it had before. The undo of that
-- reset had the identical gap, because it replays the same apply.
--
-- The reason is that RefreshChildStates is about a widget's STATE (greyed or
-- not, plus whatever refreshContent a page bolted on for dynamic captions). A
-- checkbox's tick, a slider's thumb, a dropdown's caption and a swatch are none
-- of those -- the factories paint them at build and on their own OnShow, on the
-- assumption that nothing writes a setting except the widget bound to it. A
-- group reset is precisely the write that breaks that assumption.
-- ============================================================
print("-- Group: RefreshChildValues repaints bound values")
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280)

    local hits = {}
    local function valued(name)
        local w = control(20)
        w.refreshValue = function() hits[#hits + 1] = name end
        return g:AddWidget(w, 20)
    end

    local header = g:AddWidget(control(20), 20)     -- no hook: a label, a header
    valued("check")
    valued("slider")
    valued("swatch")

    g:RefreshChildValues()
    eq(#hits, 3, "values: every child that opted in was repainted")
    eq(hits[1], "check", "values: ...in layout order")
    eq(hits[3], "swatch", "values: ...to the last one")
    check(rawget(header, "refreshValue") == nil,
          "values: a widget with no bound value is simply skipped, not errored on")

    -- ⚠ HIDDEN CHILDREN TOO, unlike the refreshContent half of
    -- RefreshChildStates. A control hidden by a hideOn is still bound to a key a
    -- reset just moved, and it is one predicate away from being on screen -- so
    -- leaving it stale only defers the wrong number to the moment it appears.
    hits = {}
    local hidden = valued("hidden")
    hidden.IsShown = function() return false end
    g:RefreshChildValues()
    eq(#hits, 4, "values: a hidden child is repainted as well")
end

-- ...and it is NOT folded into the state sweep. RefreshChildStates runs on every
-- page RefreshStates, including ones a slider drag triggers, and a value repaint
-- mid-drag snaps the thumb from where the mouse is back to the last committed
-- step -- every step.
print("-- Group: RefreshChildStates leaves bound values alone")
do
    local g = host:CreateSettingsGroup(FakeUIFrame(), 280)
    local painted = 0
    local w = control(20)
    w.refreshValue = function() painted = painted + 1 end
    g:AddWidget(w, 20)

    g:RefreshChildStates()
    eq(painted, 0, "states: the state sweep does not repaint values")
    g:RefreshChildValues()
    eq(painted, 1, "states: ...only the value sweep does")
end

CreateFrame = prevCreateFrame
