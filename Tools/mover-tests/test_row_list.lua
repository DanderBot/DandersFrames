local NS = ...

-- ============================================================
-- UI:CreateRowList / CreateSwitch / CreateMiniSlider -- DandersUI/RowList.lua
--
-- The real file over a stub host and recording fake frames. Checked: the row
-- contract a test mode builds on -- key binding into the store, defaults,
-- user writes (switch, slider, dropdown) and what follows them, grey-when-
-- disabled with its reason, variant hide, links, pooling, and the scroll
-- threshold. Not pixels: a green run here is not proof the list renders.
-- ☠ Every global it replaces is restored at the end.
-- ============================================================

local saved = { CreateFrame = CreateFrame, PlaySound = PlaySound, SOUNDKIT = SOUNDKIT }

local function noop() end
-- Unknown methods are no-ops; the FIELDS the list hangs on its frames are not,
-- or a missing one would read as a function rather than nil.
local FIELDS = { LabelHit = true, Chevron = true, Control = true, Value = true, Label = true,
                 Fill = true, Knob = true, Slider = true, Thumb = true, ScrollBar = true,
                 Scroll = true, Child = true }
local FrameMT = { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") and not FIELDS[k] then return noop end
end }

local function Frame(kind)
    local f = setmetatable({ kind = kind, shown = true, scripts = {}, points = {}, mouse = true,
                             alpha = 1, w = 0, h = 0 }, FrameMT)
    function f:SetScript(n, fn) self.scripts[n] = fn end
    function f:GetScript(n) return self.scripts[n] end
    function f:HookScript(n, fn) self.scripts["hook:" .. n] = fn end
    function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function f:ClearAllPoints() self.points = {} end
    function f:Show() self.shown = true end
    function f:Hide()
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function f:IsShown() return self.shown end
    function f:SetSize(w, h) self.w, self.h = w, h end
    function f:SetWidth(w) self.w = w end
    function f:SetHeight(h) self.h = h end
    function f:GetWidth() return self.w end
    function f:GetHeight() return self.h end
    function f:SetAlpha(a) self.alpha = a end
    function f:EnableMouse(v) self.mouse = v and true or false end
    function f:SetText(t) self.text = t end
    function f:GetText() return self.text end
    function f:SetTextColor(r, g, b) self.color = { r, g, b } end
    function f:SetVertexColor(r, g, b, a) self.color = { r, g, b, a } end
    function f:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
    function f:SetTexture(t) self.texture = t end
    function f:GetStringWidth() return #(self.text or "") * 5 end
    function f:CreateTexture() return Frame("Texture") end
    function f:CreateFontString() return Frame("FontString") end
    if kind == "Slider" then
        f.value, f.lo, f.hi = 0, 0, 1
        function f:SetMinMaxValues(lo, hi)
            self.lo, self.hi = lo, hi
            local v = math.min(math.max(self.value, lo), hi)
            if v ~= self.value then self:SetValue(v) end
        end
        function f:SetValue(v)
            v = math.min(math.max(v, self.lo), self.hi)
            if v == self.value then return end
            self.value = v
            if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end
        end
        function f:GetValue() return self.value end
    end
    if kind == "ScrollFrame" then
        f.ScrollBar = Frame("Frame")
        function f:SetScrollChild(c) self.child = c end
        function f:SetVerticalScroll(v) self.scrollY = v end
    end
    return f
end
CreateFrame = function(kind) return Frame(kind) end
local sounds = {}
PlaySound = function(id) sounds[#sounds + 1] = id end
SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = "on", IG_MAINMENU_OPTION_CHECKBOX_OFF = "off" }

local ACCENT = { r = 0.1, g = 0.2, b = 0.3 }
local tips, pins = {}, {}
local dropdowns = {}
local UI = {
    MEDIA = "Media\\",
    Colors = { text = { r = 0.9, g = 0.9, b = 0.9 }, textDim = { r = 0.5, g = 0.5, b = 0.5 } },
    Scroll = { bar = 10, pad = 4 },
    StyleScrollBar = noop,
    PinScrollBar = function(sf, region) pins[#pins + 1] = region end,
}
function UI:GetAccent() return ACCENT end
function UI:ShowTooltip(owner, spec) tips[#tips + 1] = spec end
function UI:HideTooltip() tips[#tips + 1] = "hide" end
function UI:CreateElementBackdrop() end
function UI:CreateDropdownNative(parent, opts)
    local c = Frame("Frame")
    c.opts = opts
    c.enabled = true
    function c:RebuildOptions(o) self.options = o end
    function c:UpdateText() self.shownValue = opts.get() end
    function c:SetEnabled(on) self.enabled = on end
    dropdowns[#dropdowns + 1] = c
    return c
end
local ns = { __DandersUI = UI }
load_ui_file_into("RowList.lua", ns)

print("-- Row list: API")
check(type(UI.CreateRowList) == "function" and type(UI.CreateSwitch) == "function"
      and type(UI.CreateMiniSlider) == "function", "api: list, switch and mini slider on the library")
check(UI.RowList and UI.RowList.row == 22, "metrics: 22px rows")

print("-- Switch")
do
    local got = {}
    local sw = UI:CreateSwitch(Frame(), { onToggle = function(v) got[#got + 1] = v end })
    eq(sw:GetChecked(), false, "switch: starts off")
    sw:SetChecked(true)
    eq(#got, 0, "switch: SetChecked never reports")
    check(sw.Fill.shown, "switch: on fills the track")
    eq(sw.Fill.color[1], 0.1, "switch: ...in the accent")
    sw.scripts.OnClick(sw)
    eq(got[1], false, "switch: a click flips and reports")
    check(not sw.Fill.shown, "switch: off empties the track")
    eq(sounds[#sounds], "off", "switch: plays the checkbox sound")
    sw:SetEnabled(false)
    sw.scripts.OnClick(sw)
    eq(#got, 1, "switch: disabled ignores clicks")
    check(sw.alpha == 0.4 and sw.mouse == false, "switch: disabled is dimmed and deaf")
end

print("-- Mini slider")
do
    local moves, drags = {}, {}
    local s = UI:CreateMiniSlider(Frame(), { min = 0, max = 5, step = 1,
        onValueChanged = function(v) moves[#moves + 1] = v end,
        onDragStart = function() drags[#drags + 1] = "start" end,
        onDragStop = function() drags[#drags + 1] = "stop" end })
    s:SetValue(3)
    eq(#moves, 0, "slider: SetValue is silent")
    eq(s:GetValue(), 3, "slider: holds the value")
    s.Slider:SetValue(4.4)
    eq(moves[1], 4, "slider: a user move reports, snapped to the step")
    s.Slider:SetValue(4.2)
    eq(#moves, 1, "slider: the same snapped value reports once")
    s.Slider.scripts.OnMouseDown(s.Slider, "LeftButton")
    s.Slider.scripts.OnMouseUp(s.Slider, "LeftButton")
    eq(table.concat(drags, ","), "start,stop", "slider: drag start / stop")
    s.Slider.scripts.OnMouseDown(s.Slider, "LeftButton")
    s.Slider.scripts.OnHide(s.Slider)
    eq(drags[#drags], "stop", "slider: hidden mid-drag still ends the drag")
    s:SetEnabled(false)
    eq(s.alpha, 0.4, "slider: disabled dims")
    s.Slider.scripts.OnMouseDown(s.Slider, "LeftButton")
    eq(#drags, 4, "slider: disabled starts no drag")
end

print("-- Row list: binding, defaults and writes")
local db = { showPets = nil, count = 2, mode = "A" }
local writes, changed = {}, {}
local list = UI:CreateRowList(Frame(), {
    width = 200, maxHeight = 1000,
    store = function() return db end,
    onWrite = function(spec, v) writes[#writes + 1] = tostring(spec.key) .. "=" .. tostring(v) end,
})
local h = list:AddHeading("Group")
local pets = list:AddSwitch({ label = "Show Pets", key = "showPets", default = true,
    onChanged = function(v, spec) changed[#changed + 1] = spec.key .. ":" .. tostring(v) end })
local count = list:AddSlider({ label = "Count", key = "count", min = 0, max = 5, step = 1,
    disabled = function() return db.showPets == false, "Why", { "Because" } end })
local mode = list:AddDropdown({ label = "Mode", key = "mode", options = { A = "Alpha", B = "Beta" } })
list:Refresh()
eq(h.Label.text, "Group", "heading: its text")
eq(pets.Control:GetChecked(), true, "switch row: nil in the store shows the default")
eq(count.Control:GetValue(), 2, "slider row: shows the stored value")
eq(count.Value.text, "2", "slider row: ...and its readout")
eq(mode.Control.options.B, "Beta", "dropdown row: options handed to the dropdown")
eq(mode.Control.shownValue, "A", "dropdown row: shows the stored choice")
eq(list:GetRow("count"), count, "GetRow: by key")
eq(list:GetRow(1), h, "GetRow: by position")
eq(list:GetContentHeight(), 18 + 22 * 3, "layout: heading 18, rows 22")

pets.Control.scripts.OnClick(pets.Control)
eq(db.showPets, false, "switch row: a click writes the key")
eq(changed[1], "showPets:false", "switch row: onChanged(value, spec)")
eq(writes[1], "showPets=false", "list: onWrite after the row's own")
check(count.off and count.Control.enabled == false, "refresh: a write re-greys the rows it gates")
eq(count.Value.color[1], 0.5, "disabled: the readout dims too")
count.scripts.OnEnter(count)
eq(tips[#tips].title, "Why", "disabled: hovering a greyed row says why")
eq(tips[#tips].lines[1], "Because", "disabled: ...with its lines")
count.Control.Slider:SetValue(5)
eq(db.count, 2, "disabled: a greyed slider does not write")

pets.LabelHit.scripts.OnClick(pets.LabelHit)
eq(db.showPets, true, "switch row: clicking the label toggles too")
check(not count.off, "refresh: ...and the gated row comes back")
count.Control.Slider:SetValue(4)
eq(db.count, 4, "slider row: a user move writes")
eq(count.Value.text, "4", "slider row: ...and the readout follows")
mode.Control.opts.set("B")
eq(db.mode, "B", "dropdown row: a pick writes")

print("-- Row list: custom binding, links and tooltips")
do
    local val, opened = 0, 0
    local r = list:AddSwitch({ label = "View", get = function() return val > 0 end,
        set = function(on) val = on and 3 or 0 end,
        link = function() opened = opened + 1 end, linkHint = "Click to open settings" })
    list:Refresh()
    eq(r.Control:GetChecked(), false, "custom: get() wins over the store")
    r.Control.scripts.OnClick(r.Control)
    eq(val, 3, "custom: set() wins over the store")
    check(r.Chevron.shown, "link: a chevron after the label")
    r.LabelHit.scripts.OnClick(r.LabelHit)
    eq(opened, 1, "link: a label click runs the link")
    eq(val, 3, "link: ...and does not toggle")
    r.LabelHit.scripts.OnEnter(r.LabelHit)
    local t = tips[#tips]
    check(t.title == "View" and t.lines[1] == "Click to open settings", "link: tooltip is label + hint")
    eq(r.Label.color[1], 0.1, "link: hover tints the label with the accent")
    r.LabelHit.scripts.OnLeave(r.LabelHit)
    eq(r.Label.color[1], 0.9, "link: ...and leaves it")
end

print("-- Row list: hidden rows, scroll threshold, clear and pooling")
do
    local hide = true
    local l2 = UI:CreateRowList(Frame(), { width = 200, maxHeight = 50, store = function() return db end })
    local a = l2:AddSwitch({ label = "A", key = "a" })
    local b = l2:AddSwitch({ label = "B", key = "b", hidden = function() return hide end })
    local c = l2:AddSwitch({ label = "C", key = "c" })
    eq(l2:GetContentHeight(), 44, "hidden: a hidden row takes no space")
    check(not b.shown, "hidden: ...and is not shown")
    eq(l2.h, 44, "scroll: under the max the list is its content height")
    check(not l2.Scroll.ScrollBar.shown, "scroll: ...with no bar")
    hide = false
    l2:Refresh()
    eq(l2:GetContentHeight(), 66, "hidden: a refresh re-lays out when it changes")
    eq(l2.h, 50, "scroll: over the max the list caps at it")
    check(l2.Scroll.ScrollBar.shown, "scroll: ...and shows its bar")
    eq(l2.Child.w, 200 - 14, "scroll: the rows give the bar its gutter")
    l2:Clear()
    eq(#l2:GetRows(), 0, "clear: no rows")
    check(not a.shown, "clear: rows hidden")
    local again = l2:AddSwitch({ label = "D", key = "d" })
    check(again == a or again == b or again == c, "clear: rows are pooled and reused")
    check(again.off == false and again.Label.text == "D", "clear: a reused row is rebound clean")
end

print("-- Row list: button rows")
do
    local made = {}
    function UI:CreateButtonNative(parent, opts)
        local btn = Frame("Button")
        btn.opts = opts
        btn.Text = Frame("FontString")
        function btn:SetDisabled(v) self.disabled = v end
        btn.scripts.OnClick = opts.onClick
        made[#made + 1] = btn
        return btn
    end
    local clicks, actions, gate, whole = {}, 0, false, false
    local l3 = UI:CreateRowList(Frame(), { width = 200, store = function() return db end,
        onAction = function() actions = actions + 1 end })
    local r = l3:AddButtons({ label = "Ring 1", disabled = function() return whole, "Why" end, buttons = {
        { text = "Up", onClick = function() clicks[#clicks + 1] = "up" end, disabled = function() return gate end },
        { text = "Remove", width = 70, onClick = function() clicks[#clicks + 1] = "remove" end },
    } })
    l3:Refresh()
    eq(#made, 2, "buttons: one per spec")
    made = { rawget(r, "Buttons")[1], rawget(r, "Buttons")[2] }
    eq(made[1].Text.text, "Up", "buttons: their text")
    eq(made[2].w, 70, "buttons: a width of their own")
    eq(r.controlWidth, 54 + 4 + 70, "buttons: the row's control width is all of them")
    eq(made[2].points[1][1], "RIGHT", "buttons: right-aligned, the last at the edge")
    made[1].scripts.OnClick(made[1])
    eq(clicks[1], "up", "buttons: a click runs its handler")
    eq(actions, 1, "buttons: ...then the list's onAction")
    gate = true
    l3:Refresh()
    check(made[1].disabled and made[1].alpha == 0.4, "buttons: its own disabled() greys just it")
    check(not made[2].disabled, "buttons: ...and not the others")
    made[1].scripts.OnClick(made[1])
    eq(#clicks, 1, "buttons: a greyed button does nothing")
    whole = true
    l3:Refresh()
    check(made[2].disabled and r.off, "buttons: a greyed row greys every button")
    made[2].scripts.OnClick(made[2])
    eq(#clicks, 1, "buttons: ...and they do nothing")
    whole, gate = false, false
    l3:Clear()
    local r2 = l3:AddButtons({ label = "Again", buttons = { { text = "Add", onClick = function() clicks[#clicks + 1] = "add" end } } })
    check(r2 == r, "buttons: pooled")
    l3:Refresh()
    made[1].scripts.OnClick(made[1])
    eq(clicks[#clicks], "add", "buttons: a pooled row runs its NEW spec")
    check(not made[2].shown, "buttons: a spare button hides")
end

print("-- Row list: the kit names no consumer")
do
    local src = ui_file_source("RowList.lua")
    check(not src:find("DF[%.:]") and not src:find("DandersFrames") and not src:find("DandersMover"),
          "kit: no DF / DandersFrames / DandersMover reference")
    local xml = ui_file_source("DandersUI_Options.xml")
    check(xml:find('<Script file="RowList.lua"/>', 1, true) ~= nil, "manifest: listed in the options manifest")
end

CreateFrame, PlaySound, SOUNDKIT = saved.CreateFrame, saved.PlaySound, saved.SOUNDKIT
