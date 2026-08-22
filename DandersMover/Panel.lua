local addonName, NS = ...

-- ============================================================
-- MINI-PANEL
-- Docks beside the selected proxy, flips side at the screen edge. Parented to
-- the unlock frame so combat suspension hides it for free.
-- ============================================================
local Pn = {}
NS.Panel = Pn

local Registry, Sess, Proxy, Grid, T, L = NS.Registry, NS.Session, NS.Proxy, NS.Grid, NS.Theme, NS.L
local CreateFrame, UIParent, IsShiftKeyDown = CreateFrame, UIParent, IsShiftKeyDown
local format, tonumber, ipairs = string.format, tonumber, ipairs

local W, GAP = 220, 12
local POINTS = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" }

local function selectedElement()
    return Sess.selected and Registry:Get(Sess.selected) or nil
end

local function step() return IsShiftKeyDown() and 10 or 1 end

local function build()
    local f = CreateFrame("Frame", "DandersMoverPanel", Proxy:GetUnlockFrame(), "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetWidth(W)
    T.Backdrop(f, T.C.panel, T.C.border)
    f:EnableMouse(true)

    local y = -8
    local function row(h) local cur = y; y = y - h; return cur end

    f.title = T.Label(f, "", 12); f.title:SetPoint("TOPLEFT", 10, row(16))
    f.addon = T.Label(f, "", 10); f.addon:SetTextColor(T.Unpack(T.C.muted)); f.addon:SetPoint("TOPLEFT", 10, row(14))
    f.anchorLine = T.Label(f, "", 10); f.anchorLine:SetTextColor(T.Unpack(T.C.anchored)); f.anchorLine:SetPoint("TOPLEFT", 10, row(16))

    -- X / Y
    local ry = row(24)
    f.xLabel = T.Label(f, L["X"], 11); f.xLabel:SetPoint("TOPLEFT", 10, ry - 4)
    f.xBox = T.EditBox(f, 60, function(text)
        local el = selectedElement(); local v = tonumber(text)
        if el and v then Sess:SetXY(el, v, tonumber(f.yBox:GetText()) or 0) end
    end)
    f.xBox:SetPoint("TOPLEFT", 30, ry)
    f.yLabel = T.Label(f, L["Y"], 11); f.yLabel:SetPoint("TOPLEFT", 110, ry - 4)
    f.yBox = T.EditBox(f, 60, function(text)
        local el = selectedElement(); local v = tonumber(text)
        if el and v then Sess:SetXY(el, tonumber(f.xBox:GetText()) or 0, v) end
    end)
    f.yBox:SetPoint("TOPLEFT", 130, ry)

    -- nudge arrows (Shift = x10)
    local ny = row(64)
    local function arrow(text, dx, dy, ax, ay)
        local b = T.Button(f, text, 22, 18, function()
            local el = selectedElement(); if el then Sess:Nudge(el, dx * step(), dy * step()) end
        end)
        b:SetPoint("TOPLEFT", 10 + ax, ny + ay)
        return b
    end
    arrow("^", 0, 1, 24, 0); arrow("<", -1, 0, 0, -20); arrow(">", 1, 0, 48, -20); arrow("v", 0, -1, 24, -40)

    -- 9-point picker (free elements only)
    f.points = {}
    for i, point in ipairs(POINTS) do
        local col, rowi = (i - 1) % 3, math.floor((i - 1) / 3)
        local b = T.Button(f, "", 14, 14, function()
            local el = selectedElement(); if el then Sess:SetAnchorPoint(el, point) end
        end)
        b:SetPoint("TOPLEFT", 120 + col * 18, ny - rowi * 18)
        b.point = point
        f.points[i] = b
    end

    -- toggles
    local function toggle(label, key)
        local cb = T.Checkbox(f, label, function() return NS.db[key] end, function(v) NS.db[key] = v; Grid:Refresh() end)
        cb:SetPoint("TOPLEFT", 10, row(20))
        return cb
    end
    f.cbGrid = toggle(L["Snap to grid"], "snapToGrid")
    f.cbFrames = toggle(L["Snap to frames"], "snapToFrames")
    f.cbScreen = toggle(L["Snap to screen"], "snapToScreen")
    f.cbShowGrid = toggle(L["Show grid"], "showGrid")

    local gy = row(30)
    f.gridLabel = T.Label(f, L["Grid Size"], 10); f.gridLabel:SetPoint("TOPLEFT", 10, gy)
    f.gridSlider = T.Slider(f, 120, 10, 100, 5, function() return NS.db.gridSize end, function(v) NS.db.gridSize = v; Grid:Refresh() end)
    f.gridSlider:SetPoint("TOPLEFT", 10, gy - 14)

    -- action buttons
    local by = row(26)
    f.btnCenter = T.Button(f, L["Center"], 62, 20, function() local el = selectedElement(); if el then Sess:Center(el) end end)
    f.btnCenter:SetPoint("TOPLEFT", 10, by)
    f.btnReset = T.Button(f, L["Reset"], 62, 20, function() local el = selectedElement(); if el then Sess:Reset(el) end end)
    f.btnReset:SetPoint("TOPLEFT", 78, by)
    f.btnDetach = T.Button(f, L["Detach"], 62, 20, function() local el = selectedElement(); if el then Sess:Detach(el) end end)
    f.btnDetach:SetPoint("TOPLEFT", 146, by)

    local uy = row(26)
    f.btnUndo = T.Button(f, L["Undo"], 96, 20, function() Sess:Undo() end); f.btnUndo:SetPoint("TOPLEFT", 10, uy)
    f.btnRedo = T.Button(f, L["Redo"], 96, 20, function() Sess:Redo() end); f.btnRedo:SetPoint("TOPLEFT", 112, uy)

    local fy = row(30)
    f.btnSave = T.Button(f, L["Save & Exit"], 96, 22, function() Sess:Finish("save") end); f.btnSave:SetPoint("TOPLEFT", 10, fy)
    f.btnDiscard = T.Button(f, L["Discard"], 96, 22, function() Sess:Finish("discard") end); f.btnDiscard:SetPoint("TOPLEFT", 112, fy)

    f.btnSettings = T.Button(f, L["Settings"], 60, 16, function() if NS.Settings then NS.Settings:Toggle() end end)
    f.btnSettings:SetPoint("TOPRIGHT", -8, -8)

    f:SetHeight(-y + 8)
    f:Hide()
    return f
end

function Pn:Ensure()
    if not self.frame then self.frame = build() end
    return self.frame
end

function Pn:Hide() if self.frame then self.frame:Hide() end end

function Pn:Dock()
    local f = self.frame
    local proxy = Sess.selected and Proxy.proxies[Sess.selected]
    if not f or not proxy or not proxy:IsShown() then self:Hide() return end
    local side = NS.db.panelSide
    if side == "auto" then
        local right = proxy:GetRight() or 0
        side = (right + GAP + W > (UIParent:GetRight() or 0)) and "left" or "right"
    end
    f:ClearAllPoints()
    if side == "left" then f:SetPoint("TOPRIGHT", proxy, "TOPLEFT", -GAP, 0)
    else f:SetPoint("TOPLEFT", proxy, "TOPRIGHT", GAP, 0) end
    f:Show()
end

function Pn:Refresh()
    if not Sess:IsActive() or Sess:IsSuspended() then self:Hide() return end
    local el = selectedElement()
    if not el then self:Hide() return end
    local f = self:Ensure()
    local pos = Registry:GetPos(el)
    f.title:SetText(el.title)
    local addon = Registry:GetAddon(el.addon)
    f.addon:SetText(addon and addon.title or el.addon)
    if pos.anchor then
        local target = Registry:GetTarget(pos.anchor.target)
        local name = target and target.title or L["(unavailable)"]
        f.anchorLine:SetText(format(L["Anchored to %s"], format("%s (%s/%s)", name, pos.anchor.edge, pos.anchor.align)))
        f.xLabel:SetText(L["Offset X"]); f.yLabel:SetText(L["Offset Y"])
        f.xBox:SetText(tostring(pos.anchor.offsetX or 0)); f.yBox:SetText(tostring(pos.anchor.offsetY or 0))
        f.btnDetach:SetEnabledState(true)
        for _, b in ipairs(f.points) do b:Hide() end
    else
        f.anchorLine:SetText("")
        f.xLabel:SetText(L["X"]); f.yLabel:SetText(L["Y"])
        f.xBox:SetText(tostring(math.floor((pos.x or 0) + 0.5))); f.yBox:SetText(tostring(math.floor((pos.y or 0) + 0.5)))
        f.btnDetach:SetEnabledState(false)
        for _, b in ipairs(f.points) do
            b:Show()
            local on = b.point == (pos.point or "CENTER")
            b:SetBaseColor(on and T.C.accent or nil)
        end
    end
    f.cbGrid:Refresh(); f.cbFrames:Refresh(); f.cbScreen:Refresh(); f.cbShowGrid:Refresh(); f.gridSlider:Refresh()
    f.btnUndo:SetEnabledState(Sess.undo and Sess.undo:CanUndo() or false)
    f.btnRedo:SetEnabledState(Sess.undo and Sess.undo:CanRedo() or false)
    self:Dock()
end
