local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- ROW LIST -- a compact, single-column list of settings rows.
-- One row per setting, label on the left and the control on the right: a
-- switch for an on / off value, a short slider with its value for a number, a
-- small dropdown for a choice. Small headings split the rows into groups. The
-- list scrolls once it is taller than its max height.
--
-- Built for small floating panels (a test / preview popup) where a full
-- settings group with 50px slider rows would not fit. Three widgets ride along
-- and are usable on their own: UI:CreateSwitch, UI:CreateMiniSlider and the
-- list itself.
--
--   local rows = host:CreateRowList(parent, {
--       width = 200, maxHeight = 240,
--       store = function() return db end,          -- where `key` rows read / write
--       accent = function() return {r,g,b} end,    -- optional; host accent if nil
--       onWrite = function(spec, value) end,       -- after ANY user write
--   })
--   rows:AddHeading("Group")
--   rows:AddSwitch({ label = "Show Pets", key = "showPets", default = true,
--                    onChanged = function(v, spec) end })
--   rows:AddSlider({ label = "Count", key = "count", min = 0, max = 5, step = 1,
--                    onDragStart = fn, onDragStop = fn })
--   rows:AddDropdown({ label = "Mode", key = "mode",
--                      options = { A = "Alpha", B = "Beta" } })
--   rows:Refresh()      -- re-read every value / disabled state / the accent
--   rows:Clear()        -- drop every row (they are pooled for the next build)
--
-- Every row spec takes:
--   label        string or function
--   key          bound into opts.store(); or give get() / set(v) instead
--   default      shown when the stored value is nil
--   get / set    custom binding (wins over key)
--   onChanged    (value, spec) after the write
--   tooltip      string or { title, lines } on the label
--   link         function: the label becomes a link (chevron, hover tint) and
--                a click runs it -- e.g. open the related settings page
--   linkHint     tooltip body line for a link ("Click to open settings")
--   disabled     function -> isDisabled[, reasonTitle[, reasonLines]]: greys
--                the row in place (visible, deaf), and hovering it explains
--   hidden       function -> bool: the row takes no space (a variant hide)
-- Sliders add min, max, step, format(v) -> text, onDragStart, onDragStop.
-- Dropdowns add options (table or function) -- the kit's dropdown option shape.
--
-- ☠ NOTHING HERE NAMES A CONSUMER. What a row writes and what a write sets off
-- are the caller's; the list only draws rows and routes values.
-- Part of the load-on-demand options manifest.
-- ============================================================

local CreateFrame = CreateFrame
local type, ipairs, tostring, tonumber = type, ipairs, tostring, tonumber
local floor, max, min = math.floor, math.max, math.min

local C_TEXT, C_TEXT_DIM = UI.Colors.text, UI.Colors.textDim
local MEDIA = UI.MEDIA

-- The kit's disabled alpha (CreateSlider, CreateCheckbox, StyleButton...).
local DISABLED_ALPHA = 0.4

-- The list's metrics, in one place so a consumer can size around them.
UI.RowList = {
    row        = 22,   -- every control row
    heading    = 18,   -- a group heading
    headingGap = 6,    -- air above a heading that is not the first row
    switchW    = 26, switchH = 14,
    sliderW    = 64, sliderH = 8,
    valueW     = 22,   -- a slider's value readout
    dropdownW  = 96, dropdownH = 18,
    labelGap   = 8,    -- label to control
}

local function Resolve(v)
    if type(v) == "function" then return v() end
    return v
end

local function Unpack(c, dr, dg, db)
    if type(c) ~= "table" then return dr, dg, db end
    return c.r or c[1] or dr, c.g or c[2] or dg, c.b or c[3] or db
end

local function Sound(on)
    if PlaySound and SOUNDKIT then
        PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    end
end

local function AccentOf(host, accent)
    local c = Resolve(accent)
    if type(c) ~= "table" then c = host:GetAccent() end
    return c
end

-- ============================================================
-- SWITCH -- an on / off toggle: a small track that fills with the accent and
-- a square knob that sits right when on, left when off.
--   opts: width (26), height (14), accent, tooltip, onToggle(checked)
--   :SetChecked(bool) / :GetChecked() / :SetEnabled(bool) / :Repaint()
-- onToggle runs on a user click only; SetChecked never calls it.
-- ============================================================
function UI:CreateSwitch(parent, opts)
    local host = self
    opts = opts or {}
    local M = UI.RowList
    local w, h = opts.width or M.switchW, opts.height or M.switchH

    local sw = CreateFrame("Button", nil, parent, "BackdropTemplate")
    sw:SetSize(w, h)
    host:CreateElementBackdrop(sw)

    local fill = sw:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", sw, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", sw, "BOTTOMRIGHT", -1, 1)
    fill:SetColorTexture(1, 1, 1, 0)
    fill:Hide()
    sw.Fill = fill

    local knob = sw:CreateTexture(nil, "OVERLAY")
    knob:SetSize(h - 4, h - 4)
    sw.Knob = knob

    sw.checked, sw.enabled, sw.hovered = false, true, false

    function sw:Repaint()
        local r, g, b = Unpack(AccentOf(host, opts.accent), 1, 1, 1)
        knob:ClearAllPoints()
        if self.checked then
            fill:SetColorTexture(r, g, b, (self.hovered and self.enabled) and 1 or 0.85)
            fill:Show()
            knob:SetPoint("RIGHT", self, "RIGHT", -2, 0)
            knob:SetColorTexture(1, 1, 1, 1)
        else
            fill:Hide()
            local c = (self.hovered and self.enabled) and C_TEXT or C_TEXT_DIM
            knob:SetPoint("LEFT", self, "LEFT", 2, 0)
            knob:SetColorTexture(c.r, c.g, c.b, 1)
        end
        self:SetAlpha(self.enabled and 1 or DISABLED_ALPHA)
    end

    function sw:SetChecked(v)
        self.checked = v and true or false
        self:Repaint()
    end

    function sw:GetChecked() return self.checked end

    -- Grey-when-disabled: dimmed and deaf. The mouse goes too, so a row that
    -- explains WHY it is greyed gets the hover instead of the switch.
    function sw:SetEnabled(enabled)
        self.enabled = enabled and true or false
        self:EnableMouse(self.enabled)
        if not self.enabled then self.hovered = false end
        self:Repaint()
    end

    -- Flip and report: what a click does, callable by a row whose label is
    -- part of the hit target.
    function sw:Toggle()
        if not self.enabled then return end
        self:SetChecked(not self.checked)
        Sound(self.checked)
        if opts.onToggle then opts.onToggle(self.checked) end
    end

    sw:SetScript("OnClick", function(self) self:Toggle() end)
    sw:SetScript("OnEnter", function(self)
        self.hovered = true
        self:Repaint()
        local t = Resolve(opts.tooltip)
        if type(t) == "string" and t ~= "" then t = { title = t } end
        if type(t) == "table" then host:ShowTooltip(self, t) end
    end)
    sw:SetScript("OnLeave", function(self)
        self.hovered = false
        self:Repaint()
        if opts.tooltip then host:HideTooltip() end
    end)

    sw:Repaint()
    return sw
end

-- ============================================================
-- MINI SLIDER -- a short bar with an accent fill and a thumb, no label and no
-- edit box; the caller draws the value next to it.
--   opts: width (64), height (8), min, max, step, accent,
--         onValueChanged(value)  -- user moves only, snapped to step, once per
--                                   distinct value
--         onDragStart() / onDragStop()  -- a left-button drag begins / ends
--   :SetValue(v) (silent) / :GetValue() / :SetMinMaxValues(lo, hi) /
--   :SetStep(step) / :SetEnabled(bool) / :Repaint()
-- ============================================================
function UI:CreateMiniSlider(parent, opts)
    local host = self
    opts = opts or {}
    local M = UI.RowList
    local width = opts.width or M.sliderW
    local height = opts.height or M.sliderH
    local lo, hi, step = opts.min or 0, opts.max or 1, opts.step or 1

    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(width, height)

    local track = CreateFrame("Frame", nil, c, "BackdropTemplate")
    track:SetAllPoints(c)
    host:CreateElementBackdrop(track)

    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("LEFT", track, "LEFT", 1, 0)
    fill:SetHeight(max(1, height - 2))
    fill:SetWidth(1)

    local slider = CreateFrame("Slider", nil, c)
    slider:SetAllPoints(c)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(lo, hi)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetHitRectInsets(-4, -4, -8, -8)

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(8, height + 4)
    slider:SetThumbTexture(thumb)

    c.Slider, c.Fill, c.Thumb = slider, fill, thumb
    c.enabled, c.dragging = true, false

    -- Programmatic sets are silent: only a user move reports.
    local silent = false
    local last

    local function Snap(v)
        v = tonumber(v) or lo
        if step and step > 0 then v = lo + floor((v - lo) / step + 0.5) * step end
        if v < lo then v = lo elseif v > hi then v = hi end
        return v
    end

    local function UpdateFill()
        local v = Snap(slider:GetValue())
        local span = hi - lo
        local pct = span > 0 and (v - lo) / span or 0
        fill:SetWidth(max(1, pct * (width - 2)))
    end

    function c:Repaint()
        if self.enabled then
            local r, g, b = Unpack(AccentOf(host, opts.accent), 1, 1, 1)
            thumb:SetColorTexture(r, g, b, 1)
            fill:SetColorTexture(r, g, b, 0.8)
        else
            -- Muted rather than accent while greyed (and the frame dims too).
            thumb:SetColorTexture(0.4, 0.4, 0.4, 1)
            fill:SetColorTexture(0.4, 0.4, 0.4, 0.5)
        end
        self:SetAlpha(self.enabled and 1 or DISABLED_ALPHA)
    end

    slider:SetScript("OnValueChanged", function(_, v)
        UpdateFill()
        if silent then return end
        v = Snap(v)
        if v == last then return end
        last = v
        if opts.onValueChanged then opts.onValueChanged(v) end
    end)

    local function StopDrag()
        if not c.dragging then return end
        c.dragging = false
        if opts.onDragStop then opts.onDragStop() end
    end
    slider:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" or not c.enabled or c.dragging then return end
        c.dragging = true
        if opts.onDragStart then opts.onDragStart() end
    end)
    slider:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then StopDrag() end
    end)
    -- A slider hidden mid-drag (its list rebuilt, its panel closed) never sees
    -- the mouse-up; end the drag anyway, or a caller counting drags never
    -- hears the stop.
    slider:SetScript("OnHide", StopDrag)

    function c:SetValue(v)
        v = Snap(v)
        silent = true
        slider:SetValue(v)
        silent = false
        last = v
        UpdateFill()
    end

    function c:GetValue() return Snap(slider:GetValue()) end

    function c:SetMinMaxValues(newLo, newHi)
        lo, hi = newLo or lo, newHi or hi
        silent = true
        slider:SetMinMaxValues(lo, hi)
        silent = false
        UpdateFill()
    end

    function c:SetStep(newStep)
        step = newStep or step
        slider:SetValueStep(step)
    end

    function c:SetEnabled(enabled)
        self.enabled = enabled and true or false
        slider:EnableMouse(self.enabled)
        if not self.enabled then StopDrag() end
        self:Repaint()
    end

    c:Repaint()
    UpdateFill()
    return c
end

-- ============================================================
-- THE LIST
-- ============================================================
function UI:CreateRowList(parent, opts)
    local host = self
    opts = opts or {}
    local M = UI.RowList
    local width = opts.width or 200
    local maxHeight = opts.maxHeight
    local font = opts.font or "DFFontHighlightSmall"

    local list = CreateFrame("Frame", nil, parent)
    list:SetSize(width, 1)

    local scroll = CreateFrame("ScrollFrame", nil, list, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(width, 1)
    if scroll.SetScrollChild then scroll:SetScrollChild(child) end
    if UI.StyleScrollBar then UI.StyleScrollBar(scroll) end
    list.Scroll, list.Child = scroll, child

    local rows = {}        -- the current rows, in order
    local pools = { heading = {}, switch = {}, slider = {}, dropdown = {} }
    local contentHeight, innerWidth = 0, width

    local function Accent() return AccentOf(host, opts.accent) end

    -- ---- binding --------------------------------------------------------
    local function Read(spec)
        local v
        if spec.get then
            v = spec.get()
        else
            local t = opts.store and opts.store()
            if t and spec.key ~= nil then v = t[spec.key] end
        end
        if v == nil then v = spec.default end
        return v
    end

    local function Write(spec, v)
        if spec.set then
            spec.set(v)
        else
            local t = opts.store and opts.store()
            if t and spec.key ~= nil then t[spec.key] = v end
        end
    end

    -- A USER change: the write, the row's own follow-up, the list's, and then
    -- every row re-reads (a write can change another row's value or grey).
    local function UserWrite(row, v)
        local spec = row.spec
        if not spec or row.off then return end
        Write(spec, v)
        if spec.onChanged then spec.onChanged(v, spec) end
        if opts.onWrite then opts.onWrite(spec, v) end
        list:Refresh()
    end

    -- ---- the label (and its link) -----------------------------------------
    local function PaintLabel(row)
        local label = row.Label
        if row.kind == "heading" then
            label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            return
        end
        local c = C_TEXT
        if row.off then
            c = C_TEXT_DIM
        elseif row.labelHover and row.spec and row.spec.link then
            c = Accent()
        end
        local r, g, b = Unpack(c, 1, 1, 1)
        label:SetTextColor(r, g, b)
        if row.Chevron then
            if row.spec and row.spec.link then
                row.Chevron:Show()
                local cr, cg, cb = Unpack((row.labelHover and not row.off) and c or C_TEXT_DIM, 1, 1, 1)
                row.Chevron:SetVertexColor(cr, cg, cb, row.off and 0.35 or 0.9)
            else
                row.Chevron:Hide()
            end
        end
    end

    local function LabelTooltip(row)
        local spec = row.spec
        if not spec then return nil end
        local title = Resolve(spec.label)
        local lines = {}
        local t = Resolve(spec.tooltip)
        if type(t) == "table" then
            title = t.title or title
            for _, line in ipairs(t.lines or {}) do lines[#lines + 1] = line end
        elseif type(t) == "string" and t ~= "" then
            lines[#lines + 1] = t
        end
        if spec.link and spec.linkHint then lines[#lines + 1] = Resolve(spec.linkHint) end
        if #lines == 0 and not spec.link then return nil end
        return { title = title, lines = lines }
    end

    local function NewRow(kind)
        local row = CreateFrame("Frame", nil, child)
        row.kind = kind
        row:SetHeight(kind == "heading" and M.heading or M.row)

        local label = row:CreateFontString(nil, "OVERLAY", font)
        label:SetJustifyH("LEFT")
        label:SetWordWrap(false)
        label:SetPoint("LEFT", row, "LEFT", 0, kind == "heading" and -2 or 0)
        row.Label = label

        if kind == "heading" then
            PaintLabel(row)
            return row
        end

        -- The label's hit area: a link opens, a switch's label toggles (the
        -- whole label is part of the switch's target), anything else only
        -- shows its tooltip.
        local hit = CreateFrame("Button", nil, row)
        hit:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        hit:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        hit:SetWidth(1)
        hit:RegisterForClicks("LeftButtonUp")
        row.LabelHit = hit

        local chevron = hit:CreateTexture(nil, "OVERLAY")
        chevron:SetTexture(MEDIA .. "Icons\\chevron_right.png")
        chevron:SetSize(8, 8)
        chevron:SetPoint("LEFT", label, "RIGHT", 2, 0)
        chevron:Hide()
        row.Chevron = chevron

        hit:SetScript("OnEnter", function(self)
            if row.off then return end
            row.labelHover = true
            PaintLabel(row)
            local spec = LabelTooltip(row)
            if spec then host:ShowTooltip(self, spec) end
        end)
        hit:SetScript("OnLeave", function()
            row.labelHover = false
            PaintLabel(row)
            host:HideTooltip()
        end)
        hit:SetScript("OnClick", function()
            local spec = row.spec
            if not spec or row.off then return end
            if spec.link then
                spec.link()
            elseif row.kind == "switch" then
                row.Control:Toggle()
            end
        end)

        -- A greyed row keeps the mouse to say WHY it is greyed.
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            if not (row.off and row.reasonTitle) then return end
            host:ShowTooltip(self, { title = row.reasonTitle, lines = row.reasonLines })
        end)
        row:SetScript("OnLeave", function() host:HideTooltip() end)

        if kind == "switch" then
            row.Control = host:CreateSwitch(row, {
                accent = Accent,
                onToggle = function(v) UserWrite(row, v) end,
            })
            row.Control:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            row.controlWidth = M.switchW
        elseif kind == "slider" then
            local value = row:CreateFontString(nil, "OVERLAY", font)
            value:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            value:SetWidth(M.valueW)
            value:SetJustifyH("RIGHT")
            row.Value = value
            row.Control = host:CreateMiniSlider(row, {
                width = M.sliderW, accent = Accent,
                onValueChanged = function(v) UserWrite(row, v) end,
                onDragStart = function()
                    if row.spec and row.spec.onDragStart then row.spec.onDragStart() end
                end,
                onDragStop = function()
                    if row.spec and row.spec.onDragStop then row.spec.onDragStop() end
                end,
            })
            row.Control:SetPoint("RIGHT", value, "LEFT", -6, 0)
            row.controlWidth = M.sliderW + 6 + M.valueW
        elseif kind == "dropdown" then
            row.Control = host:CreateDropdownNative(row, {
                inline = true, noTooltipHit = true, options = {},
                get = function() return row.spec and Read(row.spec) end,
                set = function(v) UserWrite(row, v) end,
            })
            row.Control:SetSize(M.dropdownW, M.dropdownH)
            row.Control:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            row.controlWidth = M.dropdownW
        end
        return row
    end

    local function Acquire(kind)
        local pool = pools[kind]
        local row = pool[#pool]
        if row then
            pool[#pool] = nil
        else
            row = NewRow(kind)
        end
        row.off, row.labelHover, row.reasonTitle, row.reasonLines = false, false, nil, nil
        return row
    end

    local function Add(kind, spec)
        if type(spec) ~= "table" then spec = { label = spec } end
        local row = Acquire(kind)
        row.spec = spec
        row.Label:SetText(Resolve(spec.label) or "")
        if kind == "slider" then
            row.Control:SetStep(spec.step or 1)
            row.Control:SetMinMaxValues(spec.min or 0, spec.max or 1)
        elseif kind == "dropdown" then
            local o = Resolve(spec.options) or {}
            if row.Control.RebuildOptions then row.Control:RebuildOptions(o) end
        end
        rows[#rows + 1] = row
        list:Layout()
        return row
    end

    function list:AddHeading(spec) return Add("heading", spec) end
    function list:AddSwitch(spec) return Add("switch", spec) end
    function list:AddSlider(spec) return Add("slider", spec) end
    function list:AddDropdown(spec) return Add("dropdown", spec) end

    function list:Clear()
        for _, row in ipairs(rows) do
            row:Hide()
            row:ClearAllPoints()
            row.spec = nil
            local pool = pools[row.kind]
            pool[#pool + 1] = row
        end
        rows = {}
        if scroll.SetVerticalScroll then scroll:SetVerticalScroll(0) end
        self:Layout()
        return self
    end

    -- Size each label to its text, clipped to the room left of its control, so
    -- a link's chevron sits right after the words rather than at the control.
    local function FitLabel(row)
        local label = row.Label
        local avail = innerWidth - (row.controlWidth or 0) - (row.controlWidth and M.labelGap or 0)
        if row.spec and row.spec.link then avail = avail - 10 end
        local tw = (label.GetUnboundedStringWidth and label:GetUnboundedStringWidth())
            or (label.GetStringWidth and label:GetStringWidth()) or avail
        -- +2: a font string exactly as wide as its text can still clip it.
        local w = max(1, min((tw or avail) + 2, avail))
        label:SetWidth(w)
        if row.LabelHit then row.LabelHit:SetWidth(w + ((row.spec and row.spec.link) and 12 or 0)) end
    end

    function list:Layout()
        local y, first = 0, true
        for _, row in ipairs(rows) do
            local hidden = row.spec and Resolve(row.spec.hidden)
            if hidden then
                row:Hide()
            else
                if row.kind == "heading" and not first then y = y + M.headingGap end
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
                row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -y)
                row:Show()
                y = y + (row.kind == "heading" and M.heading or M.row)
                first = false
            end
        end
        contentHeight = y

        local scrolls = maxHeight and contentHeight > maxHeight
        local gutter = scrolls and (UI.Scroll.bar + UI.Scroll.pad) or 0
        innerWidth = width - gutter
        scroll:ClearAllPoints()
        scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
        scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -gutter, 0)
        child:SetWidth(innerWidth)
        child:SetHeight(max(contentHeight, 1))
        list:SetHeight(max(scrolls and maxHeight or contentHeight, 1))
        local bar = scroll.ScrollBar
        if bar then
            if scrolls then
                if UI.PinScrollBar then UI.PinScrollBar(scroll, list, 0, 0, 0) end
                bar:Show()
            else
                bar:Hide()
            end
        end
        if not scrolls and scroll.SetVerticalScroll then scroll:SetVerticalScroll(0) end
        for _, row in ipairs(rows) do FitLabel(row) end
        return self
    end

    local function SetRowEnabled(row, enabled, why, lines)
        row.off = not enabled
        row.reasonTitle = (not enabled) and why or nil
        row.reasonLines = (not enabled) and lines or nil
        if row.LabelHit then row.LabelHit:EnableMouse(enabled) end
        if not enabled then row.labelHover = false end
        if row.Control and row.Control.SetEnabled then row.Control:SetEnabled(enabled) end
        PaintLabel(row)
    end

    function list:Refresh()
        local relayout = false
        for _, row in ipairs(rows) do
            local spec = row.spec
            if spec then
                if (Resolve(spec.hidden) and true or false) == (row:IsShown() and true or false) then
                    relayout = true
                end
                if row.kind ~= "heading" then
                    row.Label:SetText(Resolve(spec.label) or "")
                    local off, why, lines = false, nil, nil
                    if spec.disabled then off, why, lines = spec.disabled() end
                    SetRowEnabled(row, not off, why, lines)
                    local v = Read(spec)
                    if row.kind == "switch" then
                        row.Control:SetChecked(v)
                    elseif row.kind == "slider" then
                        v = tonumber(v) or spec.min or 0
                        row.Control:SetValue(v)
                        local shown = row.Control:GetValue()
                        row.Value:SetText(spec.format and spec.format(shown) or tostring(shown))
                        local c = row.off and C_TEXT_DIM or C_TEXT
                        row.Value:SetTextColor(c.r, c.g, c.b)
                        row.Control:Repaint()
                    elseif row.kind == "dropdown" then
                        if row.Control.UpdateText then row.Control:UpdateText() end
                    end
                else
                    row.Label:SetText(Resolve(spec.label) or "")
                    PaintLabel(row)
                end
            end
        end
        if relayout then self:Layout() end
        return self
    end

    function list:SetMaxHeight(h)
        maxHeight = h
        return self:Layout()
    end

    function list:SetListWidth(w)
        width = w or width
        list:SetWidth(width)
        return self:Layout()
    end

    function list:GetContentHeight() return contentHeight end
    function list:GetRows() return rows end

    -- A row by its key (the first one bound to it) or by its position.
    function list:GetRow(which)
        if type(which) == "number" then return rows[which] end
        for _, row in ipairs(rows) do
            if row.spec and row.spec.key == which then return row end
        end
        return nil
    end

    return list
end
