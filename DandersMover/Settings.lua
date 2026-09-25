local addonName, NS = ...
-- A copy that lost the LibStub race (a renamed duplicate install) must go
-- fully inert: Core.lua only sets NS.Lib on the winning copy.
if not NS.Lib then return end

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
local CreateFrame, UIParent, C_Timer = CreateFrame, UIParent, C_Timer
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

-- The session chrome's scale. Proxy.lua owns the reader (it sizes the strip and
-- the toast); guarded so a headless load with Proxy stubbed out still answers.
local function chromeScale()
    return NS.ChromeScale and NS:ChromeScale() or 1
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
        if widgets[i + 1] then
            -- Tight metrics throughout: this window is a compact tool palette,
            -- not an options page, so EVERY row closes up to RowGapTight, not
            -- just runs of the same compact kind.
            h = h - (GAP - TIGHT)
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

-- Two checkboxes side by side in one checkbox-height row. Only used where both
-- labels are short (the Snapping toggles): the Editor's long labels stay one
-- per row so a translation cannot collide with its neighbour.
local function pairRow(parent, a, b)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(CONTENT, UI.RowHeight.checkbox)
    row.preferredHeight = UI.RowHeight.checkbox
    row.rowKind = "checkbox"
    local half = (CONTENT - GAP) / 2
    a:SetParent(row); a:ClearAllPoints(); a:SetPoint("TOPLEFT", 0, 0); a:SetWidth(half)
    b:SetParent(row); b:ClearAllPoints(); b:SetPoint("TOPLEFT", half + GAP, 0); b:SetWidth(half)
    return row
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
    -- Centre-right by default: the window is a side palette, and dead centre
    -- is exactly where the frames being moved usually live.
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetScale(chromeScale())
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

    -- ---- Scale: its own row, first thing under the title ---------------
    -- It sizes this very window (and the strip, the panel, the toast and the
    -- text on the slabs -- see NS:ChromeScale), so it is the one control that
    -- has to be findable at a glance. It used to sit last in the Editor box, at
    -- the bottom of the window (tester report, alpha.12).
    f.scaleSlider = UI:CreateSlider(f, {
        label = L["Scale"], min = 0.5, max = 1.5, step = 0.05,
        tooltip = { title = L["Scale"],
                    lines = { L["Size of the top strip, the element panel, this window and the text on the movers. Movers themselves always match their frames."] } },
        get = function() return NS.db.scale end,
        set = function(v) NS.db.scale = v end,
        onChanged = function() if Proxy and Proxy.ApplyChromeScale then Proxy:ApplyChromeScale() end end,
    })
    f.scaleSlider:SetPoint("TOPLEFT", f, "TOPLEFT", PAD * 2, y)
    f.scaleSlider:SetWidth(CONTENT)
    y = y - (f.scaleSlider.preferredHeight or UI.RowHeight.slider or 50) - TIGHT

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
    -- Fixed distance, so the pull is the same for a raid container and a lone icon.
    -- 0 still snaps on a genuine overlap (gap 0), it just kills the reach.
    f.snapDistSlider = UI:CreateSlider(snap.content, {
        label = L["Snap distance"], min = 0, max = 400, step = 10,
        get = function() return NS.db.snapDistance end,
        set = function(v) NS.db.snapDistance = v end,
    })
    -- Zones light up before they grab: this radius is how far out they appear.
    -- Clamped to at least the snap distance so a zone that will take the drop is
    -- always visible.
    f.zoneShowSlider = UI:CreateSlider(snap.content, {
        label = L["Show snap zones within"], min = 0, max = 600, step = 10,
        get = function() return NS.db.zoneShowDistance end,
        set = function(v) NS.db.zoneShowDistance = v end,
    })
    stack(snap, {
        pairRow(snap.content,
            toggle(snap.content, L["Snap to grid"], "snapToGrid"),
            toggle(snap.content, L["Snap to frames"], "snapToFrames")),
        pairRow(snap.content,
            toggle(snap.content, L["Snap to screen"], "snapToScreen"),
            toggle(snap.content, L["Show grid"], "showGrid", function() Grid:Refresh() end)),
        -- One per row, not paired: these two labels are half again as long as
        -- the four above, and a translation of either would run into a
        -- neighbour at half width. The `after` hooks clear whatever is on
        -- screen the moment the toggle goes off, so it takes effect live
        -- rather than at the next drag.
        toggle(snap.content, L["Show distance measures"], "showMeasures", function() Grid:HideMeasure() end),
        toggle(snap.content, L["Show grid snap lines"], "showSnapPreview", function() Grid:HidePreview() end),
        f.snapDistSlider,
        f.zoneShowSlider,
    })
    place(snap)

    -- ---- Grid -------------------------------------------------------
    -- How the grid LOOKS, and the dim behind it. Every change redraws live.
    local gridBox = UI:CreateGroupBox(f, { title = L["Grid"], width = INNER })
    f.gridSlider = UI:CreateSlider(gridBox.content, {
        label = L["Grid Size"], min = 10, max = 100, step = 5,
        get = function() return NS.db.gridSize end,
        set = function(v) NS.db.gridSize = v end,
        onChanged = function() Grid:Refresh() end,
    })
    -- Device pixels; Grid.lua snaps each line to whole pixels.
    f.thickSlider = UI:CreateSlider(gridBox.content, {
        label = L["Grid line thickness"], min = 1, max = 5, step = 1,
        get = function() return NS.db.gridThickness end,
        set = function(v) NS.db.gridThickness = v end,
        onChanged = function() Grid:Refresh() end,
    })
    f.dimSlider = UI:CreateSlider(gridBox.content, {
        label = L["Dim amount"], min = 0.1, max = 0.9, step = 0.05,
        get = function() return NS.db.dimAlpha end,
        set = function(v) NS.db.dimAlpha = v end,
        onChanged = function() Grid:Refresh() end,
    })
    -- Grey-when-disabled: the amount means nothing with the dim off.
    local function gateDim() f.dimSlider:SetEnabled(NS.db.dimBackground and true or false) end
    f.gateDim = gateDim
    stack(gridBox, {
        f.gridSlider,
        f.thickSlider,
        toggle(gridBox.content, L["Dim background"], "dimBackground", function() Grid:Refresh(); gateDim() end,
            { title = L["Dim background"], lines = { L["Darkens the game world behind the grid while the movers are open, so the grid and your frames stand out."] } }),
        f.dimSlider,
    })
    gateDim()
    place(gridBox)

    -- ---- Editor -----------------------------------------------------
    local editor = UI:CreateGroupBox(f, { title = L["Editor"], width = INNER })
    f.sideRow = segmentedRow(editor.content, L["Panel side"],
        { { value = "auto", text = L["Auto"] }, { value = "left", text = L["Left"] }, { value = "right", text = L["Right"] } },
        function() return NS.db.panelSide end,
        function(v) NS.db.panelSide = v; if NS.Panel then NS.Panel:Refresh() end end)
    -- The slabs' fill only; applied live (the mover host has no drag hooks, so
    -- onChanged runs on every step of the drag).
    f.opacitySlider = UI:CreateSlider(editor.content, {
        label = L["Mover Opacity"], min = 0.1, max = 1, step = 0.05,
        tooltip = { title = L["Mover Opacity"],
                    lines = { L["How solid the movers are. Lower it to see the frames underneath; outlines, colours and names stay at full strength."] } },
        get = function() return NS.db.moverOpacity end,
        set = function(v) NS.db.moverOpacity = v end,
        onChanged = function() if Proxy and Proxy.ApplyOpacity then Proxy:ApplyOpacity() end end,
    })
    stack(editor, {
        toggle(editor.content, L["Keyboard nudge"], "keyboardNudge", nil,
            { title = L["Keyboard nudge"], lines = { L["Arrow keys move the selected element. Shift ×10, Ctrl ×100."] } }),
        toggle(editor.content, L["Auto-pin panels when editing"], "autoPinPanels", nil,
            { title = L["Auto-pin panels when editing"], lines = { L["Typing in or clicking a mover's panel pins it in place. Off: only the pin button pins."] } }),
        toggle(editor.content, L["Show movers for hidden frames"], "showHiddenMovers", rebuildProxies),
        -- In a session another addon opened (e.g. /df unlock), other addons' movers are
        -- anchor targets but not draggable unless this is on. Mirrored on the legend.
        toggle(editor.content, L["Show other addons' movers"], "showOtherAddons", rebuildProxies),
        f.sideRow,
        f.opacitySlider,
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
    f.rowCache = {}               -- identity key -> row frame; see ROWS ARE CACHED
    f.expanded = {}

    f:SetHeight(-y - UI.Space.section + PAD)
    -- Every slider, for Refresh to re-read.
    f.sliders = { f.snapDistSlider, f.zoneShowSlider, f.gridSlider, f.thickSlider, f.dimSlider,
                  f.opacitySlider, f.scaleSlider }
    return f
end

-- ============================================================
-- ADDON LIST
-- ============================================================
local function clearRows(f)
    for _, r in ipairs(f.rows) do r:Hide() end
    wipe(f.rows)
end

-- ☠ ROWS ARE CACHED BY IDENTITY, NEVER RE-CREATED. Frames cannot be
-- garbage-collected, and this list redraws on every open, every expand and every
-- registry burst (DandersFrames re-registers its targets on each unlock and sort)
-- -- it used to build a fresh box, heading and checkbox row per entry on each of
-- those and hide the old ones, so every redraw leaked the whole list. Each row now
-- lives in f.rowCache under a key naming exactly what it shows (and, for a row,
-- its label), so a redraw re-positions the one it already has. The get/set
-- closures are bound at creation to that same identity, so reuse cannot point a
-- checkbox at the wrong setting.
local function cached(f, key)
    local r = f.rowCache[key]
    if r then tinsert(f.rows, r); r:Show() end
    return r
end

local function addRow(f, parent, y, indent, label, get, set, expandable, expandedKey, key)
    local r = cached(f, key)
    if not r then
        r = CreateFrame("Frame", nil, parent)
        r:SetSize(f.listWidth, LIST_ROW)
        r.cb = UI:CreateCheckbox(r, { label = label, get = get, set = set })
        if expandable then
            r.exp = UI:CreateGlyphButton(r, {
                texture = UI.MEDIA .. "Icons\\expand_more",
                size = 20, iconSize = 14,
                onClick = function()
                    f.expanded[expandedKey] = not f.expanded[expandedKey]
                    St:Refresh()
                end,
            })
            r.exp:SetPoint("RIGHT", -4, 0)
        end
        f.rowCache[key] = r
        tinsert(f.rows, r)
    else
        r.cb:Refresh()
    end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 0, -y)
    -- The checkbox factory's slot is taller than this row; anchor it so the
    -- check itself sits on the row's vertical centre.
    r.cb:ClearAllPoints()
    r.cb:SetPoint("TOPLEFT", indent, CHECK_CONTENT_TOP + CHECK_CONTENT_H / 2 - LIST_ROW / 2)
    r.cb:SetWidth(f.listWidth - indent - (expandable and 28 or 8))
    if expandable then
        r.exp:SetGlyph(UI.MEDIA .. "Icons\\" .. (f.expanded[expandedKey] and "expand_less" or "expand_more"))
    end
    return r
end

-- A muted subheading naming the group the rows beneath it belong to. Not a
-- toggle -- there is nothing to switch at group level, it only breaks the list up.
local function addGroupHeading(f, parent, y, indent, text, key)
    local r = cached(f, key)
    if not r then
        r = CreateFrame("Frame", nil, parent)
        r.txt = UI:CreateLabel(r, { text = text, size = 10, color = UI.Colors.textDim })
        r.txt:SetPoint("LEFT", 0, 0)
        f.rowCache[key] = r
        tinsert(f.rows, r)
    end
    r:SetSize(f.listWidth - indent, LIST_HEADING)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", indent, -y)
    return r
end

-- One addon: its own element-backdrop box holding the addon row and, when
-- expanded, the indented element rows.
local function addAddonBox(f, y, name, info)
    local box = cached(f, "box\001" .. name)
    if not box then
        box = CreateFrame("Frame", nil, f.content, "BackdropTemplate")
        UI:CreateElementBackdrop(box)
        box:SetWidth(f.listWidth)
        f.rowCache["box\001" .. name] = box
        tinsert(f.rows, box)
    end
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", 0, -y)
    local inner = 0
    addRow(f, box, inner, 6, info.title,
        function() return addonDB(name).enabled ~= false end,
        function(v) Registry:SetEnabled(name, nil, v); rebuildProxies() end,
        true, name, "addon\001" .. name .. "\001" .. info.title)
    inner = inner + LIST_ROW
    if f.expanded[name] then
        -- Grouped so an addon that registers a dozen elements (DandersFrames does)
        -- reads as Party / Raid / Targeted Spells rather than one flat run. Elements
        -- the consumer left ungrouped come first, at the plain indent.
        for _, bucket in ipairs(Registry:GroupedElements(name)) do
            local indent = 6 + GAP
            if bucket.group then
                addGroupHeading(f, box, inner, indent, bucket.group,
                    "group\001" .. name .. "\001" .. bucket.group)
                inner = inner + LIST_HEADING
                indent = indent + TIGHT
            end
            for _, el in ipairs(bucket.elements) do
                local key = el.key
                addRow(f, box, inner, indent, el.title,
                    function() return addonDB(name).elements[key] ~= false end,
                    function(v) Registry:SetEnabled(name, key, v); rebuildProxies() end,
                    false, nil, "el\001" .. name .. "\001" .. key .. "\001" .. el.title)
                inner = inner + LIST_ROW
            end
        end
    end
    box:SetHeight(inner)
    return inner
end

function St:Refresh()
    local f = self.frame
    if not f or not f:IsShown() then return end
    for _, cb in ipairs(f.cb) do cb:Refresh() end
    for _, sl in ipairs(f.sliders) do sl:RefreshValue() end
    if f.gateDim then f.gateDim() end
    f.sideRow:Refresh()

    clearRows(f)
    local names = {}
    for name in pairs(Registry.addons) do tinsert(names, name) end
    tsort(names)
    local y = 0
    if #names == 0 then
        local r = cached(f, "empty")
        if not r then
            r = CreateFrame("Frame", nil, f.content)
            r:SetSize(f.listWidth, LIST_ROW)
            r.txt = UI:CreateLabel(r, { text = L["No addons have registered movers yet."], size = 10, color = UI.Colors.textDim })
            r.txt:SetPoint("LEFT", 4, 0)
            r:SetPoint("TOPLEFT", 0, 0)
            f.rowCache.empty = r
            tinsert(f.rows, r)
        end
        y = y + LIST_ROW
    end
    for _, name in ipairs(names) do
        y = y + addAddonBox(f, y, name, Registry.addons[name]) + TIGHT
    end
    f.content:SetHeight(max(10, y))
end

-- The list is built from the registry, and the registry moves while the window is
-- open (adding or removing a DandersFrames pinned set re-registers the lot). Without
-- this the new row only appeared after collapsing and re-expanding the addon.
-- Debounced to the end of the frame so one burst of registrations redraws once.
-- Expand/collapse state lives on f.expanded, keyed by addon name, so a redraw keeps it.
local refreshPending = false
NS.Lib.RegisterCallback(St, "RegistryChanged", function()
    if refreshPending then return end
    if not (St.frame and St.frame:IsShown()) then return end
    refreshPending = true
    C_Timer.After(0, function()
        refreshPending = false
        St:Refresh()
    end)
end)

-- The window closes with the session it was opened in. It is a UIParent child,
-- not a child of the unlock frame (it has to work with no session at all, from
-- /mover config), so nothing took it down when Save & Exit tore the session
-- down -- only Esc did, through UISpecialFrames. A window opened OUTSIDE a
-- session is the user's own and is left alone when some later session ends.
NS.Lib.RegisterCallback(St, "Locked", function()
    if St.sessionOwned then St:Hide() end
end)

function St:Show()
    if not self.frame then self.frame = build() end
    self.sessionOwned = (Sess and Sess.IsActive and Sess:IsActive()) and true or false
    self.frame:Show()
    self:Refresh()
end

function St:Hide()
    self.sessionOwned = false
    if self.frame then self.frame:Hide() end
end
function St:Toggle() if self.frame and self.frame:IsShown() then self:Hide() else self:Show() end end

-- The Scale setting moved (its slider is in this very window): the window takes
-- it too. Called by Proxy:ApplyChromeScale, which sizes everything else.
function St:ApplyChromeScale()
    if self.frame then self.frame:SetScale(chromeScale()) end
end
