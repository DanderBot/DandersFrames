local addonName, NS = ...

-- ============================================================
-- SETTINGS WINDOW
-- Editor preferences and the per-addon / per-element mover toggles. Nothing
-- position-related is ever stored here. Everything the mini-panel dropped
-- (snapping, grid size) lands here, which is where a set-once preference
-- belongs.
-- ============================================================
local St = {}
NS.Settings = St

local Registry, Sess, Proxy, Grid, UI, L = NS.Registry, NS.Session, NS.Proxy, NS.Grid, NS.UI, NS.L
local CreateFrame, UIParent = CreateFrame, UIParent
local ipairs, pairs, tinsert, wipe, tsort = ipairs, pairs, table.insert, wipe, table.sort

local W, H, PAD = 380, 500, 14
local ROW_W = W - 50

local function rebuildProxies()
    if Sess:IsActive() and not Sess:IsSuspended() then
        Proxy:DestroyAll()
        Proxy:Build(Sess.filter)
        Grid:Refresh()
        if NS.Panel then NS.Panel:Refresh() end
    end
end

local function addonDB(name)
    NS.db.addons[name] = NS.db.addons[name] or { enabled = true, elements = {} }
    return NS.db.addons[name]
end

local function build()
    local f = CreateFrame("Frame", "DandersMoverSettings", UIParent, "BackdropTemplate")
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    UI:CreatePanelBackdrop(f, { bgColor = UI.Colors.background })
    f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "DandersMoverSettings")   -- Esc closes

    f.title = UI:CreateLabel(f, { text = L["DandersMover"] .. " — " .. L["Settings"], font = "DFFontNormalLarge" })
    f.title:SetPoint("TOPLEFT", 12, -10)
    f.close = UI:CreateCloseButton(f, { onClick = function() f:Hide() end, tooltip = L["Close"] })
    f.close:SetPoint("TOPRIGHT", -8, -8)

    local y = -38
    local function row(h) local cur = y; y = y - h; return cur end

    f.cb = {}
    local function toggle(label, key, after, tooltip)
        local cb = UI:CreateCheckbox(f, {
            label = label, tooltip = tooltip,
            get = function() return NS.db[key] end,
            set = function(v) NS.db[key] = v; if after then after() end end,
        })
        cb:SetPoint("TOPLEFT", PAD, row(24))
        cb:SetWidth(ROW_W)
        tinsert(f.cb, cb)
        return cb
    end
    toggle(L["Snap to grid"], "snapToGrid")
    toggle(L["Snap to frames"], "snapToFrames")
    toggle(L["Snap to screen"], "snapToScreen")
    toggle(L["Show grid"], "showGrid", function() Grid:Refresh() end)
    toggle(L["Keyboard nudge"], "keyboardNudge", nil,
        { title = L["Keyboard nudge"], lines = { L["Arrow keys move the selected element. Hold Shift for 10 units."] } })
    toggle(L["Show movers for hidden frames"], "showHiddenMovers", rebuildProxies)

    f.gridSlider = UI:CreateSlider(f, {
        label = L["Grid Size"], min = 10, max = 100, step = 5,
        get = function() return NS.db.gridSize end,
        set = function(v) NS.db.gridSize = v end,
        onChanged = function() Grid:Refresh() end,
    })
    f.gridSlider:SetPoint("TOPLEFT", PAD, row(50))
    f.gridSlider:SetWidth(ROW_W)

    f.sideDropdown = UI:CreateDropdown(f, {
        label = L["Panel side"],
        options = { _order = { "auto", "left", "right" }, auto = L["Auto"], left = L["Left"], right = L["Right"] },
        get = function() return NS.db.panelSide end,
        set = function(v) NS.db.panelSide = v end,
        onChanged = function() if NS.Panel then NS.Panel:Refresh() end end,
    })
    f.sideDropdown:SetPoint("TOPLEFT", PAD, row(56))
    f.sideDropdown:SetWidth(ROW_W)

    f.addonsLabel = UI:CreateLabel(f, { text = L["Registered addons"], size = 11 })
    f.addonsLabel:SetPoint("TOPLEFT", PAD, row(22))

    local scroll = CreateFrame("ScrollFrame", nil, f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", PAD, y)
    scroll:SetPoint("BOTTOMRIGHT", -26, 12)
    UI.StyleScrollBar(scroll)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(ROW_W, 10)
    scroll:SetScrollChild(content)
    f.content = content
    f.rows = {}
    f.expanded = {}
    return f
end

local function clearRows(f)
    for _, r in ipairs(f.rows) do r:Hide() end
    wipe(f.rows)
end

-- One toggle row in the addon list. Rows are hidden rather than destroyed --
-- frames cannot be garbage-collected -- and re-created on each refresh, because
-- this list rebuilds on every expand.
local function addRow(f, indent, label, get, set, expandable, expandedKey)
    local r = CreateFrame("Frame", nil, f.content)
    r:SetSize(ROW_W, 22)
    r.cb = UI:CreateCheckbox(r, { label = label, get = get, set = set })
    r.cb:SetPoint("LEFT", indent, 0)
    r.cb:SetWidth(ROW_W - indent - 24)
    if expandable then
        r.exp = UI:CreateGlyphButton(r, {
            texture = UI.MEDIA .. "Icons\\" .. (f.expanded[expandedKey] and "expand_less" or "expand_more"),
            size = 18, iconSize = 14,
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

function St:Refresh()
    local f = self.frame
    if not f or not f:IsShown() then return end
    for _, cb in ipairs(f.cb) do cb:Refresh() end
    f.gridSlider:RefreshValue()
    f.sideDropdown:UpdateText()

    clearRows(f)
    local names = {}
    for name in pairs(Registry.addons) do tinsert(names, name) end
    tsort(names)
    local y = 0
    if #names == 0 then
        local r = CreateFrame("Frame", nil, f.content)
        r:SetSize(ROW_W, 20)
        r.txt = UI:CreateLabel(r, { text = L["No addons have registered movers yet."], size = 10, color = UI.Colors.textDim })
        r.txt:SetPoint("LEFT", 4, 0)
        r:SetPoint("TOPLEFT", 0, y); tinsert(f.rows, r); y = y - 20
    end
    for _, name in ipairs(names) do
        local info = Registry.addons[name]
        local r = addRow(f, 4, info.title,
            function() return addonDB(name).enabled ~= false end,
            function(v) Registry:SetEnabled(name, nil, v); rebuildProxies() end,
            true, name)
        r:SetPoint("TOPLEFT", 0, y); y = y - 24
        if f.expanded[name] then
            for _, el in ipairs(Registry:SortedElements()) do
                if el.addon == name then
                    local er = addRow(f, 26, el.title,
                        function() return addonDB(name).elements[el.key] ~= false end,
                        function(v) Registry:SetEnabled(name, el.key, v); rebuildProxies() end,
                        false)
                    er:SetPoint("TOPLEFT", 0, y); y = y - 22
                end
            end
        end
    end
    f.content:SetHeight(math.max(10, -y))
end

function St:Show()
    if not self.frame then self.frame = build() end
    self.frame:Show()
    self:Refresh()
end

function St:Hide() if self.frame then self.frame:Hide() end end
function St:Toggle() if self.frame and self.frame:IsShown() then self:Hide() else self:Show() end end
