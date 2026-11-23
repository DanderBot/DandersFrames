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
    CreateCheckbox = function(_, parent, opts)
        local c = FakeUIFrame(260, 35)
        c._opts = opts
        c._parentArg = parent
        c.preferredHeight = 35
        made.checks[#made.checks + 1] = c
        return c
    end,
    -- The icon rail: records its items, its pick and its options (onSelect).
    CreateIconRail = function(_, _, opts)
        local r = FakeUIFrame(opts and opts.width or 60, 0)
        r._opts, r._items = opts, {}
        function r:SetItems(items) self._items = items; return self end
        function r:Select(id) self._selected = id; return self end
        function r:GetSelected() return self._selected end
        function r:GetContentHeight() local n = #self._items return 6 + n * 40 + math.max(n - 1, 0) + 6 end
        made.rail = r
        return r
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
-- THE RAIL: FIVE SECTIONS, IN ORDER
-- One slim column with an icon rail on its left (like DandersFrames' settings
-- window and test popup), replacing the old group boxes / two-column layout.
-- ============================================================
print("-- Settings build: the rail lists five sections in order")
local ORDER = { "general", "snapping", "grid", "editor", "addons" }
local LABELS = { "General", "Snapping", "Grid", "Editor", "Addons" }
do
    local rail = made.rail
    check(rail ~= nil and f.rail == rail, "rail: the window has an icon rail")
    eq(#rail._items, 5, "rail: five sections")
    for i, id in ipairs(ORDER) do
        local it = rail._items[i] or {}
        eq(it.id, ORDER[i], "rail: item " .. i .. " is " .. id)
        eq(it.label, LABELS[i], "rail: ...labelled " .. LABELS[i])
        check(type(it.icon) == "string" and it.icon ~= "", "rail: ...with an icon")
        -- Standalone: every icon ships with DandersMover or the kit it embeds,
        -- never DandersFrames' own media.
        check(type(it.icon) == "string" and not it.icon:find("DandersFrames", 1, true),
              "rail: ...that does not need DandersFrames")
    end
    eq(#made.boxes, 0, "rail: no group boxes are built any more")
    check(rawget(f, "twoColumns") == nil and rawget(f, "addonsBox") == nil, "rail: the two-column layout is gone")
    check(f:GetWidth() < 420, "rail: the window is narrower than the old one-column window")
end

-- ============================================================
-- PICKING A SECTION SHOWS ONLY ITS ROWS
-- ============================================================
print("-- Settings build: picking a section shows only its page")
do
    eq(f.section, "general", "pick: a fresh window opens on General")
    for _, id in ipairs(ORDER) do
        made.rail._opts.onSelect(id)        -- a user click on the rail
        eq(f.section, id, "pick: " .. id .. " is current")
        eq(made.rail:GetSelected(), id, "pick: ...and painted on the rail")
        for _, other in ipairs(ORDER) do
            eq(f.pages[other]:IsShown(), other == id,
               "pick: with " .. id .. " picked, the " .. other .. " page is " .. (other == id and "shown" or "hidden"))
        end
    end
    made.rail._opts.onSelect("general")
end

-- ============================================================
-- EVERY SETTING, UNDER ITS SECTION, ON ITS OLD KEY
-- ============================================================
print("-- Settings build: every setting sits under the right section, same key")
do
    local CHECKS = {
        { "Snap to grid", "snapToGrid", "snapping" },
        { "Snap to frames", "snapToFrames", "snapping" },
        { "Snap to screen", "snapToScreen", "snapping" },
        { "Show grid", "showGrid", "snapping" },
        { "Show distance measures", "showMeasures", "snapping" },
        { "Show grid snap lines", "showSnapPreview", "snapping" },
        { "Dim background", "dimBackground", "grid" },
        { "Keyboard nudge", "keyboardNudge", "editor" },
        { "Auto-pin panels when editing", "autoPinPanels", "editor" },
        { "Show movers for hidden frames", "showHiddenMovers", "editor" },
        { "Show other addons' movers", "showOtherAddons", "editor" },
    }
    eq(#made.checks, #CHECKS, "keys: exactly the old checkboxes, no more, no fewer")
    for _, c in ipairs(CHECKS) do
        local label, key, sec = c[1], c[2], c[3]
        local w = byLabel(made.checks, label)
        check(w ~= nil, "keys: '" .. label .. "' is still in the window")
        if w then
            eq(w._parentArg, f.pages[sec], "keys: '" .. label .. "' sits under " .. sec)
            local was = NS.db[key]
            w._opts.set(not was)
            eq(NS.db[key], not was, "keys: '" .. label .. "' writes " .. key)
            eq(w._opts.get(), not was, "keys: ...and reads it back")
            w._opts.set(was)
        end
    end
    for _, label in ipairs({ "Dim background", "Keyboard nudge", "Auto-pin panels when editing" }) do
        local w = byLabel(made.checks, label)
        check(w and w._opts.tooltip and w._opts.tooltip.title == label, "keys: '" .. label .. "' keeps its tooltip")
    end
    local SLIDERS = {
        { "Scale", "scale", "general" },
        { "Mover Opacity", "moverOpacity", "general" },
        { "Snap distance", "snapDistance", "snapping" },
        { "Show snap zones within", "zoneShowDistance", "snapping" },
        { "Grid Size", "gridSize", "grid" },
        { "Grid line thickness", "gridThickness", "grid" },
        { "Dim amount", "dimAlpha", "grid" },
    }
    eq(#made.sliders, #SLIDERS, "keys: exactly the old sliders, no more, no fewer")
    for _, c in ipairs(SLIDERS) do
        local label, key, sec = c[1], c[2], c[3]
        local w = byLabel(made.sliders, label)
        check(w ~= nil, "keys: the '" .. label .. "' slider is still in the window")
        if w then
            eq(w._parentArg, f.pages[sec], "keys: '" .. label .. "' sits under " .. sec)
            local was = NS.db[key]
            w._opts.set(0.5)
            eq(NS.db[key], 0.5, "keys: '" .. label .. "' writes " .. key)
            eq(w._opts.get(), 0.5, "keys: ...and reads it back")
            NS.db[key] = was
        end
    end
    -- Panel side: the segmented row, stacked into General.
    local p = f.sideRow._points[1]
    eq(p and p[2], f.pages.general, "keys: Panel side sits under general")
    for _, b in ipairs(f.sideRow.buttons) do
        if b.value == "left" then b._opts.onClick() end
    end
    eq(NS.db.panelSide, "left", "keys: Panel side writes panelSide")
    NS.db.panelSide = "auto"
    -- Scale is the first row of General: the control that sizes this window.
    local sp = f.scaleSlider._points[1]
    eq(sp and sp[2], f.pages.general, "keys: Scale is stacked in General")
    eq(sp and sp[5], 0, "keys: ...as its first row")
end

-- ============================================================
-- SCALE: STILL WRITTEN AND APPLIED
-- ============================================================
print("-- Settings build: the Scale control")
do
    local sc = byLabel(made.sliders, "Scale")
    check(sc ~= nil, "scale: the window has a Scale slider")
    if sc then
        local line = sc._opts.tooltip and sc._opts.tooltip.lines and sc._opts.tooltip.lines[1] or ""
        check(line:find("text on the movers", 1, true) ~= nil, "scale: its tooltip says it sizes the text on the movers")
        sc._opts.set(1.2)
        eq(NS.db.scale, 1.2, "scale: written to DandersMoverDB")
        applied.ApplyChromeScale = nil
        sc._opts.onChanged()
        eq(applied.ApplyChromeScale, 1, "scale: ...and applied live")
        St:ApplyChromeScale()
        eq(f:GetScale(), 1.2, "scale: the window takes it")
        NS.db.scale = 1
        St:ApplyChromeScale()
    end
end

-- ============================================================
-- THE ADDONS LIST FILLS THE COLUMN
-- No fixed 200px list any more: it is as tall as the tallest settings page.
-- ============================================================
print("-- Settings build: the Addons list fills the height")
do
    local tallest = 0
    for _, id in ipairs({ "general", "snapping", "grid", "editor" }) do
        tallest = math.max(tallest, f.pages[id]:GetHeight())
    end
    check(tallest > 0, "fill: the settings pages have heights")
    check(f.paneHeight >= tallest, "fill: the column is at least the tallest page")
    eq(f.pages.addons:GetHeight(), f.paneHeight, "fill: the Addons page takes the whole column")
    eq(f.scroll:GetHeight(), f.paneHeight, "fill: ...and its scrolling list too")
    check(f.scroll:GetHeight() ~= 200, "fill: not the old fixed 200px list")
    check(f:GetHeight() > f.paneHeight, "fill: the window wraps the column")
    check(f:GetHeight() >= made.rail:GetContentHeight(), "fill: the window is tall enough for the rail")

    -- Registry content: switching sections redraws nothing.
    local wasReady = NS.Registry.ready
    NS.Registry.ready = true
    NS.Registry:RegisterAddon("TC", { title = "TC" })
    NS.Registry:Register("TC", "a", { title = "x", frame = FakeFrame(960, 540, 100, 40),
        getPos = function() return { point = "CENTER", x = 0, y = 0 } end, onChanged = function() end })
    f.expanded.TC = true
    St:Refresh()
    local before, rowsBefore = framesMade, #f.rows
    check(rowsBefore > 0, "fill: the list has rows")
    for _, id in ipairs(ORDER) do St:SelectSection(id); St:Refresh() end
    eq(framesMade, before, "fill: switching sections builds no frames -- the row cache holds")
    eq(#f.rows, rowsBefore, "fill: ...and the list shows the same rows")
    NS.Registry:UnregisterAddon("TC")
    NS.Registry.ready = wasReady
end

-- ============================================================
-- THE LAST SECTION IS REMEMBERED
-- In DandersMoverDB.settingsSection, so it survives a reload.
-- ============================================================
print("-- Settings build: the last picked section is remembered")
do
    eq(DEFAULTS.settingsSection, "general", "remember: defaults to General")
    made.rail._opts.onSelect("grid")
    eq(NS.db.settingsSection, "grid", "remember: a pick is written to DandersMoverDB")
    -- A fresh window (a reload) opens on it.
    St:Hide()
    St.frame = nil
    St:Show()
    local g = St.frame
    check(g ~= f, "remember: a new window was built")
    eq(g.section, "grid", "remember: the new window opens on the remembered section")
    check(g.pages.grid:IsShown() and not g.pages.general:IsShown(), "remember: ...showing its page")
    eq(made.rail:GetSelected(), "grid", "remember: ...painted on the rail")
    -- A stale or unknown value falls back to General.
    NS.db.settingsSection = "nonsense"
    St:Hide(); St.frame = nil; St:Show()
    eq(St.frame.section, "general", "remember: an unknown section opens General")
    eq(NS.db.settingsSection, "general", "remember: ...and the stale value is replaced")
end

St:Hide()
NS.Settings = prevSettings
NS.UI, NS.Session, NS.db, CreateFrame = prevUI, prevSession, prevDB, prevCreateFrame
NS.Proxy, NS.Grid, UISpecialFrames = prevProxy, prevGrid, prevSpecial
NS.ChromeScale = prevChrome

-- Scale applies on RELEASE, never mid-drag: applied live it resized the window
-- under the held slider and flickered in a loop (tester report, alpha.12).
do
    local SET = mover_file_source("Settings.lua"):gsub("\r\n", "\n")
    local s = SET:find("f.scaleSlider = UI:CreateSlider(pages.general, {", 1, true)
    local e = s and SET:find("\n    })", s, true)
    local body = (s and e) and SET:sub(s, e) or ""
    check(body:find('IsMouseButtonDown("LeftButton")', 1, true) ~= nil,
          "scale: the slider checks for a held mouse before applying")
    check(body:find("dfScaleWatch", 1, true) ~= nil,
          "scale: ...and defers the apply to a one-shot release watcher")
end
