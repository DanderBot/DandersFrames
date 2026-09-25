local NS = ...

-- ============================================================
-- THE MOVER'S SETTINGS WINDOW, BUILT
-- ------------------------------------------------------------
-- test_settings_window.lua stands the window in for a fake and pins its
-- lifecycle. This file runs the REAL build() against a recording kit, so the
-- controls the window mounts, what they are bound to and where they land can
-- be read back:
--   * every new setting has a default and a control bound to it;
--   * a control's write reaches DandersMoverDB (persisted) and its commit
--     applies the change live.
--
-- ☠ Every global and namespace field replaced here is restored at the end.
-- ============================================================
local prevUI, prevSession, prevDB, prevCreateFrame = NS.UI, NS.Session, NS.db, CreateFrame
local prevProxy, prevGrid, prevSettings, prevSpecial = NS.Proxy, NS.Grid, NS.Settings, UISpecialFrames
local prevRegister = NS.Lib.RegisterCallback
local prevChrome = NS.ChromeScale

-- ---- NS.DEFAULTS, cut out of Core.lua (it cannot load headless) -------
local core = mover_file_source("Core.lua")
local ds = core:find("NS.DEFAULTS = {", 1, true)
local de = ds and core:find("\n}\n", ds, true) or (ds and core:find("\r\n}\r\n", ds, true))
check(ds ~= nil and de ~= nil, "settings build: NS.DEFAULTS can be cut out of Core.lua")
local D = {}
if ds and de then assert(loadstring("local NS = ...\n" .. core:sub(ds, de + 3), "@Core.lua:DEFAULTS"))(D) end
local DEFAULTS = D.DEFAULTS or {}

-- ---- a recording kit --------------------------------------------------
local made = { sliders = {}, checks = {}, boxes = {} }
local function byLabel(list, label)
    for _, w in ipairs(list) do if w._opts and w._opts.label == label then return w end end
end
NS.UI = {
    Space = { section = 10 }, RowGap = 14, RowGapTight = 8,
    RowHeight = { checkbox = 35, dropdown = 44, slider = 50 },
    Colors = { textDim = { r = 0.5, g = 0.5, b = 0.5 }, background = { r = 0, g = 0, b = 0 } },
    MEDIA = "",
    CreatePanelBackdrop = function() end,
    CreateElementBackdrop = function() end,
    StyleScrollBar = function() end,
    CreateLabel = function() return FakeUIFrame() end,
    CreateCloseButton = function() return FakeUIFrame(20, 20) end,
    CreateGlyphButton = function() return FakeUIFrame(20, 20) end,
    CreateButton = function(_, _, opts)
        local b = FakeUIFrame(opts and opts.width or 40, 22)
        b._opts = opts
        return b
    end,
    CreateSlider = function(_, parent, opts)
        local s = FakeUIFrame(260, 50)
        s._opts = opts
        s._parentArg = parent
        s.preferredHeight = 50
        s._enabled = true
        function s:SetEnabled(v) self._enabled = v and true or false end
        made.sliders[#made.sliders + 1] = s
        return s
    end,
    CreateCheckbox = function(_, _, opts)
        local c = FakeUIFrame(260, 35)
        c._opts = opts
        c.preferredHeight = 35
        made.checks[#made.checks + 1] = c
        return c
    end,
    -- A group box: title strip + padding round a content frame, sized by
    -- SetContentHeight the way the real one is.
    CreateGroupBox = function(_, _, opts)
        local box = FakeUIFrame(opts and opts.width or 280, 0)
        box._title = opts and opts.title
        box.content = FakeUIFrame()
        function box:SetContentHeight(h) self._contentH = h; self:SetHeight(h + 20 + 20) end
        made.boxes[#made.boxes + 1] = box
        return box
    end,
}
-- COUNTED: Settings.lua caches CreateFrame at load, so every row, box and
-- scroll frame comes through here.
local framesMade = 0
CreateFrame = function() framesMade = framesMade + 1 return FakeUIFrame() end
UISpecialFrames = {}
NS.db = {}
for k, v in pairs(DEFAULTS) do if type(v) ~= "table" then NS.db[k] = v end end
NS.db.addons = {}
NS.ChromeScale = function() return NS.db.scale or 1 end

-- The modules a control's commit reaches, recorded.
local applied = {}
NS.Proxy = setmetatable({}, { __index = function(_, k)
    return function() applied[k] = (applied[k] or 0) + 1 end
end })
NS.Grid = setmetatable({}, { __index = function(_, k)
    return function() applied["Grid:" .. k] = (applied["Grid:" .. k] or 0) + 1 end
end })
NS.Session = { IsActive = function() return false end, RebuildProxies = function() end }
NS.Lib.RegisterCallback = function() end
load_addon_file("Settings.lua")
NS.Lib.RegisterCallback = prevRegister
local St = NS.Settings
St:Show()
local f = St.frame

-- ============================================================
-- MOVER OPACITY
-- ============================================================
print("-- Settings build: Mover Opacity")
do
    eq(DEFAULTS.moverOpacity, 0.5, "opacity: the default is 0.5")
    local s = byLabel(made.sliders, "Mover Opacity")
    check(s ~= nil, "opacity: the window has a Mover Opacity slider")
    if s then
        local o = s._opts
        eq(o.min, 0.1, "opacity: never fully invisible (min 0.1)")
        eq(o.max, 1, "opacity: up to fully solid")
        eq(o.get(), 0.5, "opacity: reads the saved value")
        o.set(0.3)
        eq(NS.db.moverOpacity, 0.3, "opacity: a change is written to DandersMoverDB")
        applied.ApplyOpacity = nil
        o.onChanged()
        eq(applied.ApplyOpacity, 1, "opacity: ...and repaints the slabs live")
    end
end

-- ============================================================
-- GRID LOOK
-- ============================================================
print("-- Settings build: grid line thickness and the background dim")
do
    eq(DEFAULTS.gridThickness, 1, "grid: thickness defaults to 1 px")
    eq(DEFAULTS.dimBackground, true, "grid: the dim is on by default")
    eq(DEFAULTS.dimAlpha, 0.4, "grid: at 0.4")
    local t = byLabel(made.sliders, "Grid line thickness")
    check(t ~= nil, "grid: the window has a Grid line thickness slider")
    if t then
        eq(t._opts.min, 1, "grid: thickness from 1 px")
        eq(t._opts.max, 5, "grid: ...to 5 px")
        eq(t._opts.step, 1, "grid: ...in whole pixels")
        t._opts.set(3)
        eq(NS.db.gridThickness, 3, "grid: thickness is written to DandersMoverDB")
        applied["Grid:Refresh"] = nil
        t._opts.onChanged()
        eq(applied["Grid:Refresh"], 1, "grid: ...and redraws the grid live")
    end
    local dimBox = byLabel(made.checks, "Dim background")
    local dim = byLabel(made.sliders, "Dim amount")
    check(dimBox ~= nil and dim ~= nil, "grid: a Dim background toggle and its amount slider")
    if dimBox and dim then
        dimBox._opts.set(false)
        eq(NS.db.dimBackground, false, "grid: the toggle is written to DandersMoverDB")
        eq(dim._enabled, false, "grid: the amount greys out with the dim off")
        dimBox._opts.set(true)
        eq(dim._enabled, true, "grid: ...and comes back with it on")
        dim._opts.set(0.6)
        eq(NS.db.dimAlpha, 0.6, "grid: the amount is written to DandersMoverDB")
        applied["Grid:Refresh"] = nil
        dim._opts.onChanged()
        eq(applied["Grid:Refresh"], 1, "grid: ...and applied live")
    end
end

-- ============================================================
-- SCALE: FIRST THING IN THE WINDOW
-- It used to be the last row of the Editor box, at the bottom of the window.
-- ============================================================
print("-- Settings build: the Scale control sits at the top, in its own row")
do
    local sc = byLabel(made.sliders, "Scale")
    check(sc ~= nil, "scale: the window has a Scale slider")
    if sc then
        eq(sc._parentArg, f, "scale: it hangs off the window itself, not inside a settings box")
        local p = sc._points[1]
        eq(p and p[1], "TOPLEFT", "scale: anchored by its top-left")
        eq(p and p[2], f, "scale: ...to the window")
        local topY = p and p[5] or -math.huge
        local firstBoxY = math.huge
        for _, box in ipairs(made.boxes) do
            local bp = box._points[1]
            local by = bp and (bp[5] or bp[3])
            if type(by) == "number" and by > -math.huge then
                check(topY > by, "scale: above the '" .. tostring(box._title) .. "' box")
            end
        end
        local editor
        for _, box in ipairs(made.boxes) do if box._title == "Editor" then editor = box end end
        check(editor ~= nil, "scale: the Editor box still exists")
        eq(sc:GetWidth() > 0 and true, true, "scale: sized to the window's width")
        -- The tooltip says what it now covers.
        local line = sc._opts.tooltip and sc._opts.tooltip.lines and sc._opts.tooltip.lines[1] or ""
        check(line:find("text on the movers", 1, true) ~= nil, "scale: its tooltip says it sizes the text on the movers")
        sc._opts.set(1.2)
        eq(NS.db.scale, 1.2, "scale: written to DandersMoverDB")
        applied.ApplyChromeScale = nil
        sc._opts.onChanged()
        eq(applied.ApplyChromeScale, 1, "scale: ...and applied live")
    end
end

-- ============================================================
-- TWO COLUMNS WHEN THERE IS ROOM
-- Tester request (alpha.12): Registered addons to the right of the settings,
-- in two columns like DandersFrames' own options; one column when narrow.
-- ============================================================
print("-- Settings build: two columns when wide, one when narrow")
do
    local function box(title) for _, b in ipairs(made.boxes) do if b._title == title then return b end end end
    local snap, grid, editor, addons = box("Snapping"), box("Grid"), box("Editor"), box("Registered addons")
    check(snap and grid and editor and addons, "columns: all four boxes are built")
    local function at(b) local p = b._points[1] return p[4], p[5] end   -- 5-arg TOPLEFT: x, y
    local function left(b) local x = at(b) return x end
    local function top(b) local _, y = at(b) return y end

    -- The shim's UIParent is 1920 wide: plenty at scale 1.
    NS.db.scale = 1
    St:ApplyChromeScale()
    check(f.twoColumns == true, "columns: a wide screen gets two columns")
    check(f:GetWidth() > 2 * addons:GetWidth(), "columns: the window is wide enough for both")
    eq(left(snap), left(grid), "columns: the settings boxes share the left column")
    eq(left(snap), left(editor), "columns: ...all of them")
    check(left(addons) >= left(snap) + snap:GetWidth(), "columns: Registered addons sits to the RIGHT of the settings")
    eq(top(addons), top(snap), "columns: ...top-aligned with the first settings box")
    local leftBottom = top(editor) - editor:GetHeight()
    eq(top(addons) - addons:GetHeight(), leftBottom, "columns: its list stretches so both columns end level")
    check(top(snap) < f.scaleSlider._points[1][5], "columns: Scale still sits above both columns")
    check(f.scaleSlider:GetWidth() > addons:GetWidth(), "columns: ...spanning the full window width")
    eq(f:GetHeight(), -leftBottom + 10, "columns: the window ends a pad under the columns")

    -- Registry content, so the row cache has rows to (not) rebuild.
    local wasReady = NS.Registry.ready
    NS.Registry.ready = true
    NS.Registry:RegisterAddon("TC", { title = "TC" })
    NS.Registry:Register("TC", "a", { title = "x", frame = FakeFrame(960, 540, 100, 40),
        getPos = function() return { point = "CENTER", x = 0, y = 0 } end, onChanged = function() end })
    f.expanded.TC = true
    St:Refresh()
    local before = framesMade
    local rowsBefore = #f.rows

    -- Narrow: the same window in one column.
    local prevW = UIParent._w
    UIParent._w = 700
    St:Show()
    check(f.twoColumns == false, "columns: a narrow screen gets one column")
    eq(left(addons), left(snap), "columns: ...Registered addons back under the settings")
    check(top(addons) < top(editor) - editor:GetHeight(), "columns: ...below the Editor box")
    check(f:GetWidth() < 2 * addons:GetWidth(), "columns: ...in the one-column window width")
    St:Refresh()

    -- The chrome scale shrinks the screen in the window's units.
    UIParent._w = prevW
    St:Show()
    check(f.twoColumns == true, "columns: back to two on the wide screen")
    NS.db.scale = 3
    St:ApplyChromeScale()
    check(f.twoColumns == false, "columns: a big chrome scale on the same screen drops to one column")
    NS.db.scale = 1
    St:ApplyChromeScale()
    St:Refresh()

    eq(framesMade, before, "columns: switching layouts builds no frames -- the row cache holds")
    eq(#f.rows, rowsBefore, "columns: ...and the list shows the same rows")
    NS.Registry:UnregisterAddon("TC")
    NS.Registry.ready = wasReady
end

St:Hide()
NS.Settings = prevSettings
NS.UI, NS.Session, NS.db, CreateFrame = prevUI, prevSession, prevDB, prevCreateFrame
NS.Proxy, NS.Grid, UISpecialFrames = prevProxy, prevGrid, prevSpecial
NS.ChromeScale = prevChrome
