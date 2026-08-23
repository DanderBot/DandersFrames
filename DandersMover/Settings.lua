local addonName, NS = ...

-- ============================================================
-- SETTINGS WINDOW
-- Editor preferences and the per-addon / per-element mover toggles. Nothing
-- position-related is ever stored here. Everything the mini-panel dropped
-- (snapping, grid size) lands here, which is where a set-once preference
-- belongs.
--
-- Laid out as titled group boxes in the DandersFrames settings style:
-- Snapping, Editor, Registered addons. Rows inside a box stack on the theme's
-- slot heights (UI.RowHeight), so the rhythm matches the options pages.
-- ============================================================
local St = {}
NS.Settings = St

local Registry, Sess, Proxy, Grid, UI, L = NS.Registry, NS.Session, NS.Proxy, NS.Grid, NS.UI, NS.L
local CreateFrame, UIParent = CreateFrame, UIParent
local ipairs, pairs, tinsert, wipe, tsort, max = ipairs, pairs, table.insert, wipe, table.sort, math.max

local W = 420
local PAD, GAP, TIGHT = UI.Space.section, UI.RowGap, UI.RowGapTight
local INNER = W - PAD * 2                 -- group box width
local CONTENT = INNER - PAD * 2           -- width inside a group box
local TITLE_ICON, TITLE_H = 20, 24        -- window title bar
local LIST_H = 200                        -- the scrollable addon list
local SCROLLBAR_W = 16                    -- room for the styled scrollbar
local LIST_ROW = 26                       -- one toggle row in the addon list
local LIST_HEADING = 16                   -- a group subheading between element rows
local CHECK_CONTENT_TOP, CHECK_CONTENT_H = 3, 18   -- where the check sits inside its 35px slot
local SEG_GAP = 2                         -- between segmented buttons

local function rebuildProxies()
    Sess:RebuildProxies()
end

local function addonDB(name)
    NS.db.addons[name] = NS.db.addons[name] or { enabled = true, elements = {} }
    return NS.db.addons[name]
end

-- ============================================================
-- ROW STACKING
-- Stacks widgets down a group box's content frame on their factory slot
-- heights. A run of the same compact kind closes up to RowGapTight (the rule
-- in UI.RowCompact); the last row drops its trailing gap because the box's own
-- padding follows it. Returns the content height.
-- ============================================================
local function stack(box, widgets)
    local y = 0
    for i, w in ipairs(widgets) do
        local h = w.preferredHeight or UI.RowHeight.checkbox
        local nxt = widgets[i + 1]
        if nxt then
            if w.rowKind and UI.RowCompact[w.rowKind] and nxt.rowKind == w.rowKind then
                h = h - (GAP - TIGHT)
            end
        else
            h = h - GAP
        end
        w:SetParent(box.content)
        w:ClearAllPoints()
        w:SetPoint("TOPLEFT", box.content, "TOPLEFT", 0, -y)
        w:SetWidth(CONTENT)
        y = y + h
    end
    box:SetContentHeight(y)
    return y
end

-- Label above three equal buttons, one of which is active: the panel-side
-- picker. Sized like a dropdown row so it stacks on the same rhythm.
local function segmentedRow(parent, label, options, get, set)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(CONTENT, UI.RowHeight.dropdown)
    row.preferredHeight = UI.RowHeight.dropdown
    row.rowKind = "segment"
    row.label = UI:CreateLabel(row, { text = label })
    row.label:SetPoint("TOPLEFT", 0, 0)
    local n = #options
    local bw = (CONTENT - SEG_GAP * (n - 1)) / n
    row.buttons = {}
    for i, opt in ipairs(options) do
        local b = UI:CreateButton(row, {
            text = opt.text, width = bw, height = 22, fitText = false,
            onClick = function() set(opt.value); row:Refresh() end,
        })
        b:SetPoint("TOPLEFT", (i - 1) * (bw + SEG_GAP), -16)
        b.value = opt.value
        row.buttons[i] = b
    end
    function row:Refresh()
        local cur = get()
        for _, b in ipairs(self.buttons) do b:SetActive(b.value == cur) end
    end
    row:Refresh()
    return row
end

-- ============================================================
-- BUILD
-- ============================================================
local function build()
    local f = CreateFrame("Frame", "DandersMoverSettings", UIParent, "BackdropTemplate")
    f:SetWidth(W)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    UI:CreatePanelBackdrop(f, { bgColor = UI.Colors.background })
    f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "DandersMoverSettings")   -- Esc closes

    -- ---- title bar: icon | title ...... close ----------------------
    f.icon = f:CreateTexture(nil, "OVERLAY")
    f.icon:SetSize(TITLE_ICON, TITLE_ICON)
    f.icon:SetPoint("LEFT", f, "TOPLEFT", PAD, -PAD - TITLE_H / 2)
    f.icon:SetTexture(UI.MEDIA .. "DF_Icon")
    f.close = UI:CreateCloseButton(f, { size = TITLE_ICON, onClick = function() f:Hide() end, tooltip = L["Close"] })
    f.close:SetPoint("RIGHT", f, "TOPRIGHT", -PAD, -PAD - TITLE_H / 2)
    f.title = UI:CreateLabel(f, { text = L["DandersMover"] .. " — " .. L["Settings"], font = "DFFontNormalLarge" })
    f.title:SetPoint("LEFT", f.icon, "RIGHT", TIGHT, 0)
    f.title:SetPoint("RIGHT", f.close, "LEFT", -TIGHT, 0)
    f.title:SetWordWrap(false)

    local y = -(PAD + TITLE_H + GAP)
    local function place(box)
        box:SetPoint("TOPLEFT", PAD, y)
        y = y - box:GetHeight() - UI.Space.section
    end

    f.cb = {}
    local function toggle(parent, label, key, after, tooltip)
        local cb = UI:CreateCheckbox(parent, {
            label = label, tooltip = tooltip,
            get = function() return NS.db[key] end,
            set = function(v) NS.db[key] = v; if after then after() end end,
        })
        tinsert(f.cb, cb)
        return cb
    end

    -- ---- Snapping ---------------------------------------------------
    local snap = UI:CreateGroupBox(f, { title = L["Snapping"], width = INNER })
    f.gridSlider = UI:CreateSlider(snap.content, {
        label = L["Grid Size"], min = 10, max = 100, step = 5,
        get = function() return NS.db.gridSize end,
        set = function(v) NS.db.gridSize = v end,
        onChanged = function() Grid:Refresh() end,
    })
    stack(snap, {
        toggle(snap.content, L["Snap to grid"], "snapToGrid"),
        toggle(snap.content, L["Snap to frames"], "snapToFrames"),
        toggle(snap.content, L["Snap to screen"], "snapToScreen"),
        toggle(snap.content, L["Show grid"], "showGrid", function() Grid:Refresh() end),
        f.gridSlider,
    })
    place(snap)

    -- ---- Editor -----------------------------------------------------
    local editor = UI:CreateGroupBox(f, { title = L["Editor"], width = INNER })
    f.sideRow = segmentedRow(editor.content, L["Panel side"],
        { { value = "auto", text = L["Auto"] }, { value = "left", text = L["Left"] }, { value = "right", text = L["Right"] } },
        function() return NS.db.panelSide end,
        function(v) NS.db.panelSide = v; if NS.Panel then NS.Panel:Refresh() end end)
    stack(editor, {
        toggle(editor.content, L["Keyboard nudge"], "keyboardNudge", nil,
            { title = L["Keyboard nudge"], lines = { L["Arrow keys move the selected element. Shift ×10, Ctrl ×100."] } }),
        toggle(editor.content, L["Show movers for hidden frames"], "showHiddenMovers", rebuildProxies),
        -- In a session another addon opened (e.g. /df unlock), other addons' movers are
        -- anchor targets but not draggable unless this is on. Mirrored on the legend.
        toggle(editor.content, L["Show other addons' movers"], "showOtherAddons", rebuildProxies),
        f.sideRow,
    })
    place(editor)

    -- ---- Registered addons ------------------------------------------
    local addons = UI:CreateGroupBox(f, { title = L["Registered addons"], width = INNER })
    local scroll = CreateFrame("ScrollFrame", nil, addons.content, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetSize(CONTENT - SCROLLBAR_W, LIST_H)
    UI.StyleScrollBar(scroll)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(CONTENT - SCROLLBAR_W, 10)
    scroll:SetScrollChild(content)
    addons:SetContentHeight(LIST_H)
    place(addons)
    f.content = content
    f.listWidth = CONTENT - SCROLLBAR_W
    f.rows = {}
    f.expanded = {}

    f:SetHeight(-y - UI.Space.section + PAD)
    return f
end

-- ============================================================
-- ADDON LIST
-- ============================================================
local function clearRows(f)
    for _, r in ipairs(f.rows) do r:Hide() end
    wipe(f.rows)
end

-- One toggle row. Rows are hidden rather than destroyed -- frames cannot be
-- garbage-collected -- and re-created on each refresh, because this list
-- rebuilds on every expand.
local function addRow(f, parent, y, indent, label, get, set, expandable, expandedKey)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(f.listWidth, LIST_ROW)
    r:SetPoint("TOPLEFT", 0, -y)
    r.cb = UI:CreateCheckbox(r, { label = label, get = get, set = set })
    -- The checkbox factory's slot is taller than this row; anchor it so the
    -- check itself sits on the row's vertical centre.
    r.cb:SetPoint("TOPLEFT", indent, CHECK_CONTENT_TOP + CHECK_CONTENT_H / 2 - LIST_ROW / 2)
    r.cb:SetWidth(f.listWidth - indent - (expandable and 28 or 8))
    if expandable then
        r.exp = UI:CreateGlyphButton(r, {
            texture = UI.MEDIA .. "Icons\\" .. (f.expanded[expandedKey] and "expand_less" or "expand_more"),
            size = 20, iconSize = 14,
            onClick = function()
                f.expanded[expandedKey] = not f.expanded[expandedKey]
                St:Refresh()
            end,
        })
        r.exp:SetPoint("RIGHT", -4, 0)
    end
    tinsert(f.rows, r)
    return r
end

-- A muted subheading naming the group the rows beneath it belong to. Not a
-- toggle -- there is nothing to switch at group level, it only breaks the list up.
local function addGroupHeading(f, parent, y, indent, text)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(f.listWidth - indent, LIST_HEADING)
    r:SetPoint("TOPLEFT", indent, -y)
    r.txt = UI:CreateLabel(r, { text = text, size = 10, color = UI.Colors.textDim })
    r.txt:SetPoint("LEFT", 0, 0)
    tinsert(f.rows, r)
    return r
end

-- One addon: its own element-backdrop box holding the addon row and, when
-- expanded, the indented element rows.
local function addAddonBox(f, y, name, info)
    local box = CreateFrame("Frame", nil, f.content, "BackdropTemplate")
    UI:CreateElementBackdrop(box)
    box:SetPoint("TOPLEFT", 0, -y)
    box:SetWidth(f.listWidth)
    local inner = 0
    addRow(f, box, inner, 6, info.title,
        function() return addonDB(name).enabled ~= false end,
        function(v) Registry:SetEnabled(name, nil, v); rebuildProxies() end,
        true, name)
    inner = inner + LIST_ROW
    if f.expanded[name] then
        -- Grouped so an addon that registers a dozen elements (DandersFrames does)
        -- reads as Party / Raid / Targeted Spells rather than one flat run. Elements
        -- the consumer left ungrouped come first, at the plain indent.
        for _, bucket in ipairs(Registry:GroupedElements(name)) do
            local indent = 6 + GAP
            if bucket.group then
                addGroupHeading(f, box, inner, indent, bucket.group)
                inner = inner + LIST_HEADING
                indent = indent + TIGHT
            end
            for _, el in ipairs(bucket.elements) do
                addRow(f, box, inner, indent, el.title,
                    function() return addonDB(name).elements[el.key] ~= false end,
                    function(v) Registry:SetEnabled(name, el.key, v); rebuildProxies() end,
                    false)
                inner = inner + LIST_ROW
            end
        end
    end
    box:SetHeight(inner)
    tinsert(f.rows, box)
    return inner
end

function St:Refresh()
    local f = self.frame
    if not f or not f:IsShown() then return end
    for _, cb in ipairs(f.cb) do cb:Refresh() end
    f.gridSlider:RefreshValue()
    f.sideRow:Refresh()

    clearRows(f)
    local names = {}
    for name in pairs(Registry.addons) do tinsert(names, name) end
    tsort(names)
    local y = 0
    if #names == 0 then
        local r = CreateFrame("Frame", nil, f.content)
        r:SetSize(f.listWidth, LIST_ROW)
        r.txt = UI:CreateLabel(r, { text = L["No addons have registered movers yet."], size = 10, color = UI.Colors.textDim })
        r.txt:SetPoint("LEFT", 4, 0)
        r:SetPoint("TOPLEFT", 0, 0); tinsert(f.rows, r); y = y + LIST_ROW
    end
    for _, name in ipairs(names) do
        y = y + addAddonBox(f, y, name, Registry.addons[name]) + TIGHT
    end
    f.content:SetHeight(max(10, y))
end

function St:Show()
    if not self.frame then self.frame = build() end
    self.frame:Show()
    self:Refresh()
end

function St:Hide() if self.frame then self.frame:Hide() end end
function St:Toggle() if self.frame and self.frame:IsShown() then self:Hide() else self:Show() end end
