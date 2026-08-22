local addonName, NS = ...

-- ============================================================
-- SETTINGS WINDOW
-- Editor preferences and the per-addon / per-element mover toggles.
-- Nothing position-related is ever stored here.
-- ============================================================
local St = {}
NS.Settings = St

local Registry, Sess, Proxy, Grid, T, L = NS.Registry, NS.Session, NS.Proxy, NS.Grid, NS.Theme, NS.L
local CreateFrame, UIParent = CreateFrame, UIParent
local ipairs, pairs, tinsert = ipairs, pairs, table.insert

local W, H = 380, 460

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
    T.Backdrop(f, T.C.bg, T.C.border)
    f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "DandersMoverSettings")   -- Esc closes

    f.title = T.Label(f, L["DandersMover"] .. " — " .. L["Settings"], 13)
    f.title:SetPoint("TOPLEFT", 12, -10)
    f.close = T.Button(f, "X", 20, 18, function() f:Hide() end)
    f.close:SetPoint("TOPRIGHT", -8, -8)

    local y = -36
    local function row(h) local cur = y; y = y - h; return cur end
    local function toggle(label, key, after)
        local cb = T.Checkbox(f, label, function() return NS.db[key] end, function(v) NS.db[key] = v; if after then after() end end)
        cb:SetPoint("TOPLEFT", 14, row(20))
        return cb
    end
    f.cb = {}
    f.cb[1] = toggle(L["Snap to grid"], "snapToGrid")
    f.cb[2] = toggle(L["Snap to frames"], "snapToFrames")
    f.cb[3] = toggle(L["Snap to screen"], "snapToScreen")
    f.cb[4] = toggle(L["Show grid"], "showGrid", function() Grid:Refresh() end)
    f.cb[5] = toggle(L["Keyboard nudge"], "keyboardNudge")
    f.cb[6] = toggle(L["Show movers for hidden frames"], "showHiddenMovers", rebuildProxies)

    local gy = row(34)
    f.gridLabel = T.Label(f, L["Grid Size"], 10); f.gridLabel:SetPoint("TOPLEFT", 14, gy)
    f.gridSlider = T.Slider(f, 160, 10, 100, 5, function() return NS.db.gridSize end, function(v) NS.db.gridSize = v; Grid:Refresh() end)
    f.gridSlider:SetPoint("TOPLEFT", 14, gy - 14)

    local sy = row(26)
    f.sideLabel = T.Label(f, L["Panel side"], 10); f.sideLabel:SetPoint("TOPLEFT", 14, sy)
    f.sides = {}
    for i, side in ipairs({ { "auto", L["Auto"] }, { "left", L["Left"] }, { "right", L["Right"] } }) do
        local b = T.Button(f, side[2], 50, 18, function() NS.db.panelSide = side[1]; St:Refresh() end)
        b:SetPoint("TOPLEFT", 90 + (i - 1) * 54, sy + 2)
        b.side = side[1]
        f.sides[i] = b
    end

    f.addonsLabel = T.Label(f, L["Registered addons"], 11); f.addonsLabel:SetPoint("TOPLEFT", 14, row(22))

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, y)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(W - 50, 10)
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

local function addRow(f, indent, label, get, set, expandable, expandedKey)
    local r = CreateFrame("Frame", nil, f.content)
    r:SetSize(W - 50, 20)
    r.cb = T.Checkbox(r, label, get, set)
    r.cb:SetPoint("LEFT", indent, 0)
    if expandable then
        r.exp = T.Button(r, f.expanded[expandedKey] and "-" or "+", 16, 16, function()
            f.expanded[expandedKey] = not f.expanded[expandedKey]
            St:Refresh()
        end)
        r.exp:SetPoint("RIGHT", -4, 0)
    end
    tinsert(f.rows, r)
    return r
end

function St:Refresh()
    local f = self.frame
    if not f or not f:IsShown() then return end
    for _, cb in ipairs(f.cb) do cb:Refresh() end
    f.gridSlider:Refresh()
    for _, b in ipairs(f.sides) do b:SetBaseColor(b.side == NS.db.panelSide and T.C.accent or nil) end

    clearRows(f)
    local names = {}
    for name in pairs(Registry.addons) do tinsert(names, name) end
    table.sort(names)
    local y = 0
    if #names == 0 then
        local r = CreateFrame("Frame", nil, f.content); r:SetSize(W - 50, 20)
        r.txt = T.Label(r, L["No addons have registered movers yet."], 10); r.txt:SetPoint("LEFT", 4, 0)
        r.txt:SetTextColor(T.Unpack(T.C.muted))
        r:SetPoint("TOPLEFT", 0, y); tinsert(f.rows, r); y = y - 20
    end
    for _, name in ipairs(names) do
        local info = Registry.addons[name]
        local r = addRow(f, 4, info.title,
            function() return addonDB(name).enabled ~= false end,
            function(v) addonDB(name).enabled = v; rebuildProxies() end,
            true, name)
        r:SetPoint("TOPLEFT", 0, y); y = y - 22
        if f.expanded[name] then
            for _, el in ipairs(Registry:SortedElements()) do
                if el.addon == name then
                    local er = addRow(f, 24, el.title,
                        function() return addonDB(name).elements[el.key] ~= false end,
                        function(v) addonDB(name).elements[el.key] = (not v) and false or nil; rebuildProxies() end,
                        false)
                    er:SetPoint("TOPLEFT", 0, y); y = y - 20
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
