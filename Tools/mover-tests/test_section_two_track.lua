local NS = ...

-- ============================================================
-- THE DEBUFF BAR'S TWO OPT-INS, RUN FOR REAL -- GUI/Controls.lua page tools
-- ------------------------------------------------------------
-- The Debuff Bar's cards ask the shared section helper (tools.OpenSection) for
-- two things the Buff Bar does not: controls TWO PER ROW when the card is wide
-- enough, and captions drawn DIM so a setting never reads as a heading. The
-- page's own census file pins who asks; this file RUNS the four helpers that do
-- the work, against the kit's real settings group (DandersUI/Sections.lua), so
-- the claims are about behaviour rather than source shape:
--
--   ✓ the track count follows the band's LIVE width on every layout pass, and
--     falls back to one track below the threshold -- no rebuild involved
--   ✓ prose / notes / buttons take a full row; bound controls share one
--   ✓ a short slot beside a tall one is centred on the row, not top-pinned
--   ✓ a quiet caption maps text -> dim, dim -> dim at half alpha, and lets
--     every other colour through, surviving the factories' SetEnabled repaint
--   ✗ nothing here draws: how the result LOOKS is read in game.
--
-- The helpers are locals inside GUI:CreatePopoutPageTools, so they are lifted
-- out of the source by their own two ends and loaded with just the upvalues
-- they close over. A rename or a reorder fails at the lift.
-- ============================================================

local CTRL = options_file_source("GUI/Controls.lua"):gsub("\r\n", "\n")

-- ---- the kit, exactly as test_sections_group.lua stands it up -----------
local UI = {
    MEDIA = "",
    Colors = {
        background = { r = 0.08, g = 0.08, b = 0.08, a = 0.95 },
        text       = { r = 0.9,  g = 0.9,  b = 0.9 },
        textDim    = { r = 0.6,  g = 0.6,  b = 0.6 },
        element    = { r = 0.20, g = 0.21, b = 0.22 },
        border     = { r = 0.31, g = 0.32, b = 0.33 },
    },
    RowGap = 14, RowGapTight = 6, RowCompact = {},
    SettingsBox = { group = 280, pad = 10, colMargin = 5, minCol = 285, colGutter = 20,
                    innerGap = 10 },
    PopoutContentWidth = 260,
    PopoutPad = 10,
    PopoutRow = { plate = 44, gap = 6, padX = 10, restFill = 0.55, restBorder = 0.5 },
    _state = {},
    _priv = {
        INFO_BANNER_TONES = {},
        AddTooltipLines = function() end,
        CURSOR_LIFT_X = 0, CURSOR_LIFT_Y = 0,
        CreateElementBackdrop = function(frame, opts) frame._elementOpts = opts return frame end,
    },
}
do
    local SHARED = NS.__DandersUI
    for _, name in ipairs({ "SurfaceStyle", "ResolveSurfaceStyle", "SetSurfaceStyle",
                            "GetSurfaceStyle", "HidePixelBorder",
                            "CreateRoundedSurface", "GetRoundedSurface",
                            "ApplyRoundedChrome", "RemoveRoundedChrome" }) do
        UI[name] = SHARED[name]
    end
end
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

local host = setmetatable({ hooks = { getSettingsDB = function() return {} end } },
                          { __index = UI })

-- ---- the four helpers, lifted out of the page tools ---------------------
local HELPERS
do
    local a = CTRL:find("\n    local SECTION_TWO_TRACK_MIN = ", 1, true)
    local b = CTRL:find("\n    local function OpenSection(Add, ", 1, true)
    check(a ~= nil and b ~= nil and a < b, "lift: the helpers sit between the threshold and OpenSection")
    local chunk = (a and b) and CTRL:sub(a, b) or ""
    chunk = chunk .. "\nreturn { MIN = SECTION_TWO_TRACK_MIN, WireTwoTrack = WireTwoTrack,"
        .. " StampFullRows = StampFullRows, QuietLabels = QuietLabels, QuietLabel = QuietLabel }\n"
    local f, err = loadstring(chunk, "=page-tools helpers")
    check(f ~= nil, "lift: the lifted helpers parse (" .. tostring(err) .. ")")
    if f then
        setfenv(f, setmetatable({
            GUI = { SettingsBox = UI.SettingsBox },
            C_TEXT = UI.Colors.text, C_TEXT_DIM = UI.Colors.textDim,
            SnapLen = function(_, n) return n end,
        }, { __index = _G }))
        HELPERS = f()
    end
end

local function control(h, bound)
    local w = FakeUIFrame(0, h)
    w.preferredHeight = h
    w.fixedRowHeight = true
    if bound then w.refreshValue = function() end end
    return w
end
local function lastPoint(w)
    local pt = w._points[#w._points]
    return pt and pt[4], pt and pt[5]
end

check(HELPERS ~= nil and HELPERS.WireTwoTrack ~= nil, "lift: the helpers came back")
if HELPERS and HELPERS.WireTwoTrack then
    local MIN = HELPERS.MIN
    eq(MIN, 330, "threshold: two 160px tracks and the kit's 10px gutter")

    -- A card body: chromeless, the card's 12px inset, laid out by the real kit.
    local function band(width)
        local g = host:CreateSettingsGroup(FakeUIFrame(), width, { chromeless = true })
        g.padding = 12
        g:SetWidth(width)
        HELPERS.WireTwoTrack(g)
        return g
    end

    print("-- Two tracks: the count follows the live width, on every pass")
    do
        -- 24 + 330 = 354 is the narrowest card that gets a second track.
        local g = band(354)
        local a = g:AddWidget(control(55, true), 55)
        local b = g:AddWidget(control(55, true), 55)
        HELPERS.StampFullRows(g)
        g:LayoutChildren()
        eq(rawget(g, "innerColumns"), 2, "wide: a 354px card lays out two tracks")
        local ax, ay = lastPoint(a)
        local bx, by = lastPoint(b)
        eq(ay, by, "wide: ...the two sliders share a row")
        check(bx > ax, "wide: ...side by side")
        eq(a:GetWidth(), 160, "wide: ...each exactly one 160px track")

        -- Narrowed with NO rebuild -- the page folding, or a resize-grip drag.
        g:SetWidth(353)
        g:LayoutChildren()
        eq(rawget(g, "innerColumns"), nil, "narrow: one pixel under, the card is one track again")
        local _, ay2 = lastPoint(a)
        local _, by2 = lastPoint(b)
        check(by2 < ay2, "narrow: ...the second slider drops under the first")
        eq(a:GetWidth(), 353 - 24, "narrow: ...at the full inner width")

        -- ...and back.
        g:SetWidth(600)
        g:LayoutChildren()
        eq(rawget(g, "innerColumns"), 2, "re-widened: two tracks again, still without a rebuild")
    end

    print("-- Two tracks: prose takes a row, bound controls share one")
    do
        local g = band(600)
        local blurb = g:AddWidget(control(30, false), 30)      -- a label: no refreshValue
        local cb    = g:AddWidget(control(30, true), 30)
        local sl    = g:AddWidget(control(55, true), 55)
        local btn   = g:AddWidget(control(30, false), 30)      -- a button
        local pinned = control(30, true); pinned.fullRow = false
        g:AddWidget(pinned, 30)
        HELPERS.StampFullRows(g)
        eq(rawget(blurb, "fullRow"), true, "full rows: a label is given a row of its own")
        eq(rawget(btn, "fullRow"), true, "full rows: ...and so is a button")
        eq(rawget(cb, "fullRow"), nil, "full rows: a bound checkbox is left to share")
        eq(rawget(sl, "fullRow"), nil, "full rows: ...and so is a bound slider")
        eq(rawget(pinned, "fullRow"), false, "full rows: a widget that already said is never overridden")
        g:LayoutChildren()
        eq(blurb:GetWidth(), 600 - 24, "full rows: ...the label spans the card")
        eq(cb:GetWidth(), (600 - 24 - 10) / 2, "full rows: ...the checkbox takes one track")
    end

    print("-- Two tracks: a short slot beside a tall one is centred on the row")
    do
        local g = band(600)
        local sl = g:AddWidget(control(55, true), 55)
        local cb = g:AddWidget(control(30, true), 30)
        local sl2 = g:AddWidget(control(55, true), 55)
        local sl3 = g:AddWidget(control(55, true), 55)
        HELPERS.StampFullRows(g)
        g:LayoutChildren()
        local _, sy = lastPoint(sl)
        local _, cy = lastPoint(cb)
        eq(cy, sy - math.floor((55 - 30) / 2), "centre: the checkbox sits 12px down, level with the slider's bar")
        eq(#cb._points, 1, "centre: ...re-anchored, not anchored twice")
        local _, y2 = lastPoint(sl2)
        local _, y3 = lastPoint(sl3)
        eq(y2, y3, "centre: two equal slots are left exactly where the kit put them")
        eq(y2, sy - 55, "centre: ...and the next row still starts one tallest-slot down")
        -- One track: nothing is centred, because nothing shares a row.
        g:SetWidth(300)
        g:LayoutChildren()
        local _, sy1 = lastPoint(sl)
        local _, cy1 = lastPoint(cb)
        eq(cy1, sy1 - 55, "centre: in one track the checkbox is simply the next row")
    end

    print("-- Quiet captions: dim when live, dimmer when greyed, everything else untouched")
    do
        local function fontString()
            local fs = { _c = { 0.9, 0.9, 0.9, 1 } }
            function fs:GetObjectType() return "FontString" end
            function fs:SetTextColor(r, g, b, a) self._c = { r, g, b, a } end
            function fs:GetTextColor() return self._c[1], self._c[2], self._c[3], self._c[4] end
            return fs
        end
        local g = band(600)
        local slider = control(55, true)
        slider.label = fontString()
        slider.rowKind = "slider"
        local box = control(30, true)
        box.label = fontString()
        box.rowKind = "checkbox"
        g:AddWidget(slider, 55)
        g:AddWidget(box, 30)
        HELPERS.QuietLabels(g)

        local c = slider.label._c
        eq(c[1], 0.6, "quiet: a slider's caption is repainted dim at once")
        -- The factory's own SetEnabled repaints, on every state pass:
        slider.label:SetTextColor(0.9, 0.9, 0.9)
        eq(slider.label._c[1], 0.6, "quiet: ...and stays dim when the factory repaints it 'on'")
        slider.label:SetTextColor(0.6, 0.6, 0.6)
        eq(slider.label._c[1], 0.6, "quiet: greyed, it keeps the dim colour...")
        eq(slider.label._c[4], 0.5, "quiet: ...at half alpha, so a greyed setting still reads as greyed")
        slider.label:SetTextColor(1, 0.5, 0, 1)
        eq(slider.label._c[1], 1, "quiet: any other colour (an override marker's) passes straight through")
        eq(box.label._c[1], 0.9, "quiet: a checkbox's caption is the control, and keeps its colour")

        -- Idempotent: a second pass does not wrap the wrapper.
        local wrapped = slider.label.SetTextColor
        HELPERS.QuietLabels(g)
        check(slider.label.SetTextColor == wrapped, "quiet: a caption is only ever wrapped once")
    end
end

CreateFrame = prevCreateFrame
