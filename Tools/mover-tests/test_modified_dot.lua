local NS = ...

-- ============================================================
-- THE MODIFIED-DEFAULT DOT: TOOLTIP AND HOLD-TO-RESET
-- DandersUI/Widgets.lua (AddModifiedDot) + the DF-side factories in
-- DandersFrames_Options/GUI/SettingsWidgets.lua that publish the dot's hooks.
-- ------------------------------------------------------------
-- The dot answers when asked: hovering it names the shipped default and the
-- current value, and holding it for DOT_HOLD_TIME writes the default back
-- THROUGH THE CONTROL'S OWN WRITE PATH. What is pinned here:
--
--   * the hit frame exists only when the host opted in, and is shown only while
--     the dot is;
--   * the tooltip's lines, and each control's way of naming a value (a slider's
--     number format, On/Off, a dropdown's display text, a colour's hex);
--   * a hold completes after the threshold and runs the control's commit with
--     the default -- the same host bracket a user edit runs -- and cancels on an
--     early release, on leaving the hit, and in combat;
--   * the hold's per-frame update allocates nothing;
--   * a control whose display is not what is stored, or a greyed control,
--     gets the tooltip but no hold.
--
-- ⚠ A FRESH NAMESPACE, as test_widgets_slider.lua does, for the same reason:
-- this installs the REAL Widgets.lua, which would replace factories other
-- suites built their fixtures from. Every global replaced is restored at the end.
-- ============================================================

local prevCreateFrame, prevTimer, prevTooltip = CreateFrame, C_Timer, GameTooltip
local prevDF = DandersFrames

-- ---- the tooltip, recorded -----------------------------------------
-- Widgets.lua caches GameTooltip at FILE SCOPE, so this must be in place
-- before the load.
local TT = { lines = {}, shown = false }
GameTooltip = {
    SetOwner = function(_, owner) TT.owner = owner; TT.lines = {}; TT.title = nil end,
    SetText = function(_, t) TT.title = t end,
    AddLine = function(_, t, r, g, b) TT.lines[#TT.lines + 1] = { text = t, r = r, g = g, b = b } end,
    AddDoubleLine = function(_, l, r) TT.lines[#TT.lines + 1] = { text = l .. " " .. r } end,
    Show = function() TT.shown = true end,
    Hide = function() TT.shown = false end,
}

-- ---- the library table this file owns ------------------------------
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
    RowHeight = { slider = 50, checkbox = 35, dropdown = 50, colorpicker = 28, editbox = 44 },
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

-- ---- frame stub (the slider suite's, trimmed) -----------------------
local DATA_KEYS = {
    ThemeListeners = true, UpdateOverrideIndicators = true, tooltip = true,
    tooltipText = true, tooltipSubText = true, tooltipSpellID = true,
    searchEntry = true, dragBubble = true, openerTooltip = true,
    UpdateModifiedDot = true, modifiedDotLabel = true, modifiedDotMaxX = true,
    modifiedDotHit = true, modifiedDot = true,
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
    f.GetChildren = function(self) return unpack(self._children) end
    f.GetParent = function(self) return self._parent end
    f.SetParent = function(self, p) self._parent = p end
    if kind == "Slider" then
        f._value = 0
        f.SetValue = function(self, v)
            self._value = v
            local fn = self._scripts.OnValueChanged
            if fn then fn(self, v) end
        end
        f.GetValue = function(self) return self._value end
    end
    if kind == "CheckButton" then
        f.SetChecked = function(self, v) self._checked = v and true or false end
        f.GetChecked = function(self) return self._checked == true end
    end
    if type(parent) == "table" then
        local kids = rawget(parent, "_children")
        if not kids then kids = {}; parent._children = kids end
        kids[#kids + 1] = f
    end
    return f
end
C_Timer = { After = function(_, fn) fn() end }

load_ui_file_into("Widgets.lua", ns)

-- The override star and reset button are styled buttons; their chrome is not
-- under test here (test_widgets_slider.lua stubs the same way).
function UI:StyleButton(btn, opts)
    if opts and opts.text then btn:SetText(opts.text) end
    btn.SetActive = function() end
    return btn
end

local function pane() return CreateFrame("Frame") end
local function fire(frame, script, ...) return frame:GetScript(script)(frame, ...) end
local function plainText(s) return (s:gsub("|T.-|t", "")) end

-- A host with the dot hooks. `defaults` is the shipped table, `db` the stored
-- one; the host's hooks answer the way DF's do (modified = stored differs).
-- Every host hook a write fires is counted, so "went through the write path"
-- is a question about these counters.
local function newHost(db, defaults, opts)
    opts = opts or {}
    local log = { intercept = 0, written = 0, refreshNow = 0, writes = {} }
    local function same(a, b)
        if type(a) == "table" and type(b) == "table" then
            for k, v in pairs(a) do if b[k] ~= v then return false end end
            for k in pairs(b) do if a[k] == nil then return false end end
            return true
        end
        return a == b
    end
    local hooks = {
        L = setmetatable({}, { __index = function(_, k) return k end }),
        refresh = function() end,
        refreshNow = function() log.refreshNow = log.refreshNow + 1 end,
        interceptWrite = function(_, key, value)
            log.intercept = log.intercept + 1
            return opts.redirect and true or false
        end,
        onSettingWritten = function(_, key, value)
            log.written = log.written + 1
            log.writes[#log.writes + 1] = { key = key, value = value }
        end,
    }
    if not opts.noDotHook then
        hooks.isModifiedDefault = function(t, key)
            if t ~= db or defaults[key] == nil or t[key] == nil then return false end
            return not same(t[key], defaults[key])
        end
    end
    if not opts.noDefaultHook then
        hooks.getDefaultValue = function(t, key)
            if t ~= db then return nil end
            local v = defaults[key]
            if type(v) == "table" then
                local c = {}
                for k2, v2 in pairs(v) do c[k2] = v2 end
                return c
            end
            return v
        end
    end
    return setmetatable({ hooks = hooks }, { __index = UI }), log
end

local function slider(host, db, key, extra)
    extra = extra or {}
    return host:CreateSlider(pane(), {
        label = "Width", min = extra.min or 0, max = extra.max or 100, step = extra.step or 1,
        get = extra.get or function() return db[key] end,
        set = function(v) db[key] = v end,
        onChanged = extra.onChanged,
        dbRef = { db = db, key = key },
    })
end

-- Press, then run the hold's per-frame update `n` times of `dt` seconds.
local function hold(hit, n, dt)
    fire(hit, "OnMouseDown", "LeftButton")
    local up = hit:GetScript("OnUpdate")
    for _ = 1, n do
        up = hit:GetScript("OnUpdate")
        if not up then break end
        up(hit, dt)
    end
end

-- ============================================================
-- 1. HOOK ABSENT: NO HIT FRAME, NO TOOLTIP
-- ============================================================
print("-- Modified dot: no hook, no hit frame")
do
    local db, defaults = { w = 30 }, { w = 10 }
    local host = newHost(db, defaults, { noDotHook = true })
    local s = slider(host, db, "w")
    check(not s.modifiedDot:IsShown(), "no hook: no dot")
    eq(rawget(s, "modifiedDotHit"), nil, "no hook: ...and no hit frame is ever built")
    s:UpdateOverrideIndicators(30)
    eq(rawget(s, "modifiedDotHit"), nil, "no hook: ...not even after a repaint")
end

-- ============================================================
-- 2. THE HIT FRAME FOLLOWS THE DOT
-- ============================================================
print("-- Modified dot: the hit frame is shown only with the dot")
do
    local db, defaults = { w = 30 }, { w = 10 }
    local host = newHost(db, defaults)
    local s = slider(host, db, "w")
    local hit = rawget(s, "modifiedDotHit")
    check(hit ~= nil, "hit: built once the dot is shown")
    check(hit and hit:IsShown(), "hit: ...and shown with it")
    eq(hit and hit:GetWidth(), 16, "hit: 16 wide")
    eq(hit and hit:GetHeight(), 16, "hit: ...and 16 tall")
    eq(s.modifiedDot:GetWidth(), 6, "hit: while the drawn dot stays 6px")
    check(hit and hit._flags.mouseClick == true, "hit: it takes clicks (it is a control now)")
    local p = hit._points[#hit._points]
    eq(p[1], "CENTER", "hit: centred...")
    check(p[2] == s.label, "hit: ...off the same label the dot hangs from")
    eq(p[4], s.label:GetStringWidth() + 4 + 3, "hit: ...on the dot's resting centre")
    check(hit._flags.level > s:GetFrameLevel() + 5, "hit: above the label's tooltip hit (+5)")

    db.w = 10
    s:UpdateOverrideIndicators(10)
    check(not s.modifiedDot:IsShown(), "hit: at the default the dot goes...")
    check(not hit:IsShown(), "hit: ...and the hit frame with it")
    db.w = 40
    s:UpdateOverrideIndicators(40)
    check(hit:IsShown(), "hit: ...and both come back together")
    check(rawget(s, "modifiedDotHit") == hit, "hit: the same frame, not a new one per show")
end

-- ============================================================
-- 3. THE TOOLTIP
-- ============================================================
print("-- Modified dot: the tooltip names the default and the current value")
do
    local db, defaults = { w = 2.5 }, { w = 1 }
    local host = newHost(db, defaults)
    local s = slider(host, db, "w", { step = 0.5 })
    local hit = s.modifiedDotHit
    fire(hit, "OnEnter")
    check(TT.shown, "tooltip: shown on enter")
    check(TT.owner == hit, "tooltip: ...owned by the hit frame")
    eq(TT.title, "Changed from default", "tooltip: the header")
    eq(TT.lines[1] and TT.lines[1].text, "Default: 1", "tooltip: the default, in the slider's own format")
    eq(TT.lines[2] and TT.lines[2].text, "Current: 2.5", "tooltip: the current value, same format")
    eq(TT.lines[3] and TT.lines[3].text, "Hold click to reset", "tooltip: the hint")
    check(TT.lines[3] and TT.lines[3].r < TT.lines[2].r, "tooltip: ...drawn dimmer than the values")
    fire(hit, "OnLeave")
    check(not TT.shown, "tooltip: hidden on leave")
end

do
    -- No getDefaultValue hook: the tooltip still names the current value, but
    -- there is no default to name and nothing to reset to.
    local db, defaults = { w = 30 }, { w = 10 }
    local host = newHost(db, defaults, { noDefaultHook = true })
    local s = slider(host, db, "w")
    fire(s.modifiedDotHit, "OnEnter")
    eq(#TT.lines, 1, "no default hook: one line")
    eq(TT.lines[1].text, "Current: 30", "no default hook: ...the current value")
    hold(s.modifiedDotHit, 100, 0.05)
    eq(db.w, 30, "no default hook: a hold does nothing")
end

print("-- Modified dot: each control names a value its own way")
do
    -- Dropdown: the option's DISPLAY text, never the stored key.
    local db, defaults = { style = "TEXTURE" }, { style = "SOLID" }
    local host = newHost(db, defaults)
    local d = host:CreateDropdown(pane(), {
        label = "Style",
        options = { _order = { "SOLID", "TEXTURE" }, SOLID = "Solid Colour", TEXTURE = { text = "Bar Texture" } },
        get = function() return db.style end,
        set = function(v) db.style = v end,
        dbRef = { db = db, key = "style" },
    })
    fire(d.modifiedDotHit, "OnEnter")
    eq(TT.lines[1].text, "Default: Solid Colour", "dropdown: the default's display text")
    eq(TT.lines[2].text, "Current: Bar Texture", "dropdown: ...a table option's text too")

    -- The kit's fallbacks: booleans as On/Off, a colour as a swatch + hex.
    eq(d.FormatDotValue("NOPE"), nil, "dropdown: an unknown key falls through to the kit")
    local fmtSlider = slider(newHost({ w = 1 }, { w = 2 }), { w = 1 }, "w")
    eq(fmtSlider.FormatDotValue(0.25), "0.25", "slider: two decimals when it needs them")
    eq(fmtSlider.FormatDotValue(3), "3", "slider: ...none when it does not")

    local c = UI.FormatColorValue({ r = 1, g = 0.5, b = 0 })
    check(c:find("#FF8000", 1, true) ~= nil, "colour: the hex, upper case")
    check(c:find("|T", 1, true) == 1, "colour: ...after a swatch texture escape")
    check(c:find(":255:128:0|t", 1, true) ~= nil, "colour: ...tinted to the colour itself")
    check(UI.FormatColorValue({ r = 0, g = 0, b = 0, a = 0.5 }):find("50%", 1, true) ~= nil,
          "colour: a part-transparent one says its opacity")
    check(UI.FormatColorValue({ 0, 0, 1 }):find("#0000FF", 1, true) ~= nil,
          "colour: positional {r,g,b} too")
end

-- ============================================================
-- 4. THE HOLD
-- ============================================================
print("-- Modified dot: holding resets through the control's own commit")
do
    local db, defaults = { w = 30 }, { w = 10 }
    local host, log = newHost(db, defaults)
    local commits = 0
    local s = slider(host, db, "w", { onChanged = function() commits = commits + 1 end })
    local hit = s.modifiedDotHit

    fire(hit, "OnEnter")
    fire(hit, "OnMouseDown", "LeftButton")
    check(hit:GetScript("OnUpdate") ~= nil, "hold: pressing starts the per-frame update")
    local up = hit:GetScript("OnUpdate")
    up(hit, 0.3)
    eq(db.w, 30, "hold: nothing is written before the threshold")
    check(s.modifiedDot:GetWidth() > 6 and s.modifiedDot:GetWidth() < 10, "hold: the dot grows while held")
    up(hit, 0.31)
    eq(db.w, 10, "hold: past the threshold the default is written")
    eq(log.intercept, 1, "hold: ...through the host's redirect gate")
    eq(log.written, 1, "hold: ...and its write announcement (undo, auto layout)")
    eq(log.writes[1].value, 10, "hold: ...announcing the default")
    eq(commits, 1, "hold: the control's own onChanged ran, once")
    eq(log.refreshNow, 1, "hold: ...and the live refresh")
    eq(s.slider:GetValue(), 10, "hold: the bar shows the default")
    check(not s.modifiedDot:IsShown(), "hold: the dot went out")
    check(not hit:IsShown(), "hold: ...taking the hit frame with it")
    eq(hit:GetScript("OnUpdate"), nil, "hold: the per-frame update is gone")
    eq(s.modifiedDot:GetWidth(), 6, "hold: and the dot is back to its size for next time")
    check(not TT.shown, "hold: the tooltip is down")
end

print("-- Modified dot: a hold cancels on release, on leave, and in combat")
do
    local db, defaults = { w = 30 }, { w = 10 }
    local host = newHost(db, defaults)
    local s = slider(host, db, "w")
    local hit = s.modifiedDotHit

    fire(hit, "OnMouseDown", "LeftButton")
    hit:GetScript("OnUpdate")(hit, 0.4)
    fire(hit, "OnMouseUp", "LeftButton")
    eq(hit:GetScript("OnUpdate"), nil, "release: the update stops")
    eq(s.modifiedDot:GetWidth(), 6, "release: the dot shrinks back")
    eq(db.w, 30, "release: nothing written")

    -- A new press starts from zero, not from where the last one stopped.
    fire(hit, "OnMouseDown", "LeftButton")
    hit:GetScript("OnUpdate")(hit, 0.4)
    eq(db.w, 30, "release: a fresh press starts the count again")
    fire(hit, "OnLeave")
    eq(hit:GetScript("OnUpdate"), nil, "leave: sliding off cancels")
    eq(db.w, 30, "leave: nothing written")

    fire(hit, "OnMouseDown", "RightButton")
    eq(hit:GetScript("OnUpdate"), nil, "right button: not a hold")

    IN_COMBAT = true
    fire(hit, "OnMouseDown", "LeftButton")
    eq(hit:GetScript("OnUpdate"), nil, "combat: a hold cannot start")
    IN_COMBAT = false
    fire(hit, "OnMouseDown", "LeftButton")
    hit:GetScript("OnUpdate")(hit, 0.2)
    IN_COMBAT = true
    hit:GetScript("OnUpdate")(hit, 0.5)
    IN_COMBAT = false
    eq(hit:GetScript("OnUpdate"), nil, "combat: one starting mid-hold cancels it")
    eq(db.w, 30, "combat: nothing written")
end

print("-- Modified dot: the hold's per-frame update allocates nothing")
do
    local db, defaults = { w = 30 }, { w = 10 }
    local host = newHost(db, defaults)
    local s = slider(host, db, "w")
    local hit = s.modifiedDotHit
    fire(hit, "OnMouseDown", "LeftButton")
    local up = hit:GetScript("OnUpdate")
    up(hit, 0.0001)            -- warm
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    for _ = 1, 2000 do up(hit, 0.0001) end
    local after = collectgarbage("count")
    collectgarbage("restart")
    check(after - before < 0.5, string.format("alloc: 2000 held frames allocated %.2f KB", after - before))
    fire(hit, "OnMouseUp", "LeftButton")
end

print("-- Modified dot: what withholds the hold")
do
    -- A redirected write (a running raid layout): the dot stays, and says so.
    local db, defaults = { w = 30 }, { w = 10 }
    local host, log = newHost(db, defaults, { redirect = true })
    local s = slider(host, db, "w")
    hold(s.modifiedDotHit, 20, 0.05)
    eq(log.intercept, 1, "redirect: the write was offered to the gate")
    eq(log.written, 0, "redirect: ...which took it, so nothing was announced")
    check(s.modifiedDot:IsShown(), "redirect: the dot stays (the stored value did not move)")
    check(TT.shown and TT.title == "Changed from default", "redirect: ...and the tooltip says it is still changed")
end
do
    -- A display that is not the stored value (a scaling customGet).
    local db, defaults = { w = 0.3 }, { w = 0.1 }
    local host, log = newHost(db, defaults)
    local s = slider(host, db, "w", { get = function() return db.w * 100 end })
    fire(s.modifiedDotHit, "OnEnter")
    eq(#TT.lines, 2, "scaled get: tooltip, but no hint")
    hold(s.modifiedDotHit, 20, 0.05)
    eq(db.w, 0.3, "scaled get: and no reset")
    eq(log.intercept, 0, "scaled get: ...nothing even offered to the write path")
end
do
    -- A default outside the bar's range: refused, not clamped.
    local db, defaults = { w = 30 }, { w = 500 }
    local host = newHost(db, defaults)
    local s = slider(host, db, "w")
    hold(s.modifiedDotHit, 20, 0.05)
    eq(db.w, 30, "out of range: no reset")
end
do
    -- A greyed control is non-interactive, dot included.
    local db, defaults = { w = 30 }, { w = 10 }
    local host = newHost(db, defaults)
    local s = slider(host, db, "w")
    s:SetEnabled(false)
    fire(s.modifiedDotHit, "OnEnter")
    eq(#TT.lines, 2, "greyed: tooltip, but no hint")
    hold(s.modifiedDotHit, 20, 0.05)
    eq(db.w, 30, "greyed: no reset")
    s:SetEnabled(true)
    hold(s.modifiedDotHit, 20, 0.05)
    eq(db.w, 10, "greyed: ...until it is enabled again")
end

print("-- Modified dot: a dropdown resets to the default option through its pick")
do
    local db, defaults = { style = "TEXTURE" }, { style = "SOLID" }
    local host, log = newHost(db, defaults)
    local picked = 0
    local d = host:CreateDropdown(pane(), {
        label = "Style",
        options = { _order = { "SOLID", "TEXTURE" }, SOLID = "Solid", TEXTURE = "Texture" },
        get = function() return db.style end,
        set = function(v) db.style = v end,
        onChanged = function() picked = picked + 1 end,
        dbRef = { db = db, key = "style" },
    })
    hold(d.modifiedDotHit, 20, 0.05)
    eq(db.style, "SOLID", "dropdown: reset to the default key")
    eq(log.written, 1, "dropdown: ...announced once")
    eq(picked, 1, "dropdown: ...its onChanged ran once")
    check(not d.modifiedDot:IsShown(), "dropdown: and its dot is out")
end

print("-- Modified dot: the anchor grid resets each key on its own")
do
    local db, defaults = { h = "END", v = "END" }, { h = "START", v = "START" }
    local host = newHost(db, defaults)
    local g = host:CreateAnchorGrid(pane(), { label = "Anchor", dbRef = { db = db, keyH = "h", keyV = "v" } })
    -- The grid paints its indicators on a sweep or a click, not at build.
    g:UpdateOverrideIndicatorsBoth()
    check(g.modifiedDot:IsShown(), "grid: the align key's dot")
    hold(g.modifiedDotHit, 20, 0.05)
    eq(db.h, "START", "grid: align reset")
    eq(db.v, "END", "grid: ...and the wrap key untouched")
end

-- ============================================================
-- 5. THE DF-SIDE FACTORIES: CHECKBOX, COLOUR PICKER, EDIT BOX
-- SettingsWidgets.lua built against the REAL kit above, so the checkbox and
-- the colour picker are the real ones.
-- ============================================================
do
    local db, defaults = { showX = false, tint = { r = 1, g = 0, b = 0 }, name = "x", w = 30 },
                         { showX = true,  tint = { r = 0, g = 1, b = 0 }, name = "", w = 10 }
    local host, log = newHost(db, defaults)
    host.Colors = UI.Colors
    host.RowHeight = UI.RowHeight
    local updates = 0
    local DF = { GUI = host, L = host.hooks.L }
    function DF:Debug() end
    function DF:UpdateAll() updates = updates + 1 end
    function DF:ThrottledUpdateAll() end
    DandersFrames = DF
    -- The DF factories re-anchor the kit's dot through GUI:PinModifiedDotTopLeft,
    -- which lives in the resident GUI/Compat.lua.
    load_df_file_into("GUI/Compat.lua", { GUI = host })
    load_options_file_into("GUI/SettingsWidgets.lua", ns)
    -- The box's chrome (pixel snapping, the themed check) is not under test.
    host.StyleCheckButton = function() end

    print("-- Modified dot: the checkbox")
    local clicks = 0
    local cb = host:CreateCheckbox(pane(), "Show X", db, "showX", function() clicks = clicks + 1 end)
    check(cb.modifiedDot:IsShown(), "checkbox: modified shows the dot")
    local dp = cb.modifiedDot._points[#cb.modifiedDot._points]
    check(dp[1] == "CENTER" and dp[2] == cb.label and dp[3] == "TOPLEFT",
          "checkbox: the dot sits against the label's top-left")
    local hp = cb.modifiedDotHit._points[#cb.modifiedDotHit._points]
    check(hp[2] == cb.label and hp[3] == "TOPLEFT" and hp[4] == dp[4] and hp[5] == dp[5],
          "checkbox: ...and its hit is centred on it")
    fire(cb.modifiedDotHit, "OnEnter")
    eq(TT.lines[1].text, "Default: On", "checkbox: the default as On/Off")
    eq(TT.lines[2].text, "Current: Off", "checkbox: ...and the current")
    hold(cb.modifiedDotHit, 20, 0.05)
    eq(db.showX, true, "checkbox: reset to the default")
    eq(clicks, 1, "checkbox: through its click: the callback ran once")
    check(updates >= 1, "checkbox: ...and the live refresh")
    check(not cb.modifiedDot:IsShown(), "checkbox: dot out")

    -- The positional slider (GUI/Compat.lua) paints its dot inside the kit's
    -- constructor, before the shim wraps it, and a slider born visible gets no
    -- OnShow to repaint it: the wrap has to re-place a dot that is already up.
    print("-- Modified dot: the positional slider, painted at build")
    local sl = host:CreateSlider(pane(), "Width", 0, 100, 1, db, "w")
    check(sl.modifiedDot:IsShown(), "slider: modified shows the dot at build")
    local sp = sl.modifiedDot._points[#sl.modifiedDot._points]
    check(sp[1] == "CENTER" and sp[3] == "TOPLEFT",
          "slider: ...already against the label's top-left, with no repaint")
    local shp = sl.modifiedDotHit._points[#sl.modifiedDotHit._points]
    check(shp[2] == sp[2] and shp[3] == "TOPLEFT", "slider: ...and its hit with it")

    -- A card's header mark asks every control in its body, through a body row
    -- that holds them, and hears a control's own update. settingsGroup and
    -- parentSection are what AddWidget and RegisterChild set.
    print("-- Modified dot: a card's header mark counts its body")
    local section, band = pane(), pane()
    section.title = section:CreateFontString()
    section.sectionChildren = { band }
    band.parentSection = section
    host:AttachCardModifiedMark(section, pane())
    local bodyRow = CreateFrame("Frame", nil, band)
    local atDefault = host:CreateCheckbox(bodyRow, "Show X", db, "showX")
    local changed = host:CreateSlider(bodyRow, "Width", 0, 100, 1, db, "w")
    atDefault.settingsGroup, changed.settingsGroup = band, band
    section:RefreshModifiedMark()
    check(section.modifiedMark:IsShown(), "mark: one changed control in the body lights the header")
    check(section.modifiedMarkHit:IsShown(), "mark: ...with its hover")
    check(section.modifiedMarkHit._flags.mouseClick == false, "mark: ...which takes no clicks, so the header still folds")
    fire(section.modifiedMarkHit, "OnEnter")
    eq(TT.lines[1].text, "1 setting in this section is changed.", "mark: ...and says how many")
    db.w = 10
    changed:UpdateOverrideIndicators(10)
    check(not section.modifiedMark:IsShown(), "mark: back to default puts it out, from the control's own update")

    print("-- Modified dot: the colour picker")
    local recolours = 0
    local cp = host:CreateColorPicker(pane(), "Tint", db, "tint", false, function() recolours = recolours + 1 end)
    local stored = db.tint
    fire(cp.modifiedDotHit, "OnEnter")
    check(plainText(TT.lines[1].text) == "Default:  #00FF00", "colour picker: the default as swatch + hex")
    check(plainText(TT.lines[2].text) == "Current:  #FF0000", "colour picker: ...and the current")
    local before = log.written
    hold(cp.modifiedDotHit, 20, 0.05)
    check(db.tint == stored, "colour picker: the stored table keeps its identity")
    eq(db.tint.r, 0, "colour picker: reset -- red")
    eq(db.tint.g, 1, "colour picker: ...green")
    eq(db.tint.a, nil, "colour picker: ...and no stray alpha the default does not have")
    eq(log.written, before + 1, "colour picker: announced through the host")
    check(log.writes[#log.writes].value ~= db.tint, "colour picker: ...with a COPY, not the live table")
    eq(recolours, 1, "colour picker: its callback ran once")
    check(not cp.modifiedDot:IsShown(), "colour picker: dot out")

    print("-- Modified dot: the edit box")
    local eb = host:CreateEditBox(pane(), "Name", db, "name")
    eb.refreshValue()   -- its indicators paint on OnShow, which a stub never fires
    fire(eb.modifiedDotHit, "OnEnter")
    eq(TT.lines[1].text, "Default: None", "edit box: an empty default reads None")
    hold(eb.modifiedDotHit, 20, 0.05)
    eq(db.name, "", "edit box: reset through its save")
end

-- ---- restore the globals -------------------------------------------
CreateFrame, C_Timer, GameTooltip = prevCreateFrame, prevTimer, prevTooltip
DandersFrames = prevDF
