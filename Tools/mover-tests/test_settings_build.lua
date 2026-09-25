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
    CreateSlider = function(_, _, opts)
        local s = FakeUIFrame(260, 50)
        s._opts = opts
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
CreateFrame = function() return FakeUIFrame() end
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

St:Hide()
NS.Settings = prevSettings
NS.UI, NS.Session, NS.db, CreateFrame = prevUI, prevSession, prevDB, prevCreateFrame
NS.Proxy, NS.Grid, UISpecialFrames = prevProxy, prevGrid, prevSpecial
NS.ChromeScale = prevChrome
