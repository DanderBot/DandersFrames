local addonName, NS = ...

-- ============================================================
-- MINI-PANEL
-- Docks beside the selected proxy, flips side at the screen edge. Parented to
-- the unlock frame so combat suspension hides it for free.
--
-- Deliberately NOT a settings window: it holds only what acts on the SELECTED
-- element plus the session verbs. Editor preferences (snapping, grid size)
-- live behind the cog, because a preference you set once does not belong in a
-- panel you read on every drag.
-- ============================================================
local Pn = {}
NS.Panel = Pn

local Registry, Sess, Proxy, UI, L = NS.Registry, NS.Session, NS.Proxy, NS.UI, NS.L
local CreateFrame, UIParent, IsShiftKeyDown = CreateFrame, UIParent, IsShiftKeyDown
local format, tonumber, ipairs, floor = string.format, tonumber, ipairs, math.floor

local W, GAP, PAD = 236, 12, 10
local POINTS = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" }

local function selectedElement()
    return Sess.selected and Registry:Get(Sess.selected) or nil
end

local function step() return IsShiftKeyDown() and 10 or 1 end

local function build()
    local f = CreateFrame("Frame", "DandersMoverPanel", Proxy:GetUnlockFrame(), "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetWidth(W)
    UI:CreatePanelBackdrop(f)
    f:EnableMouse(true)

    local y = -PAD
    local function row(h) local cur = y; y = y - h; return cur end

    -- ---- header: icon + title + addon ----------------------------
    f.icon = f:CreateTexture(nil, "OVERLAY")
    f.icon:SetSize(16, 16)
    f.icon:SetPoint("TOPLEFT", PAD, -PAD)

    f.title = UI:CreateLabel(f, { size = 12, color = UI.Colors.text })
    f.title:SetPoint("TOPLEFT", PAD + 22, row(17))
    f.addon = UI:CreateLabel(f, { size = 10, color = UI.Colors.textDim })
    f.addon:SetPoint("TOPLEFT", PAD, row(15))
    f.anchorLine = UI:CreateLabel(f, { size = 10, color = UI.Colors.accent, width = W - PAD * 2 })
    f.anchorLine:SetPoint("TOPLEFT", PAD, row(16))

    f.btnSettings = UI:CreateButton(f, {
        text = L["Settings"], width = 62, height = 18, style = "ghost",
        tooltip = { title = L["Settings"], lines = { L["Snapping, grid and per-addon mover toggles."] } },
        onClick = function() if NS.Settings then NS.Settings:Toggle() end end,
    })
    f.btnSettings:SetPoint("TOPRIGHT", -PAD, -PAD)

    -- ---- X / Y ---------------------------------------------------
    local ry = row(26)
    f.xLabel = UI:CreateLabel(f, { text = L["X"], size = 11 })
    f.xLabel:SetPoint("TOPLEFT", PAD, ry - 4)
    f.xBox = UI:CreateEditBox(f, {
        width = 62, numeric = true,
        get = function()
            local el = selectedElement(); if not el then return 0 end
            local pos = Registry:GetPos(el)
            return pos.anchor and (pos.anchor.offsetX or 0) or floor((pos.x or 0) + 0.5)
        end,
        onCommit = function(v)
            local el = selectedElement()
            if el then Sess:SetXY(el, v, tonumber(f.yBox:GetText()) or 0) end
        end,
    })
    f.xBox:SetPoint("TOPLEFT", PAD + 22, ry)

    f.yLabel = UI:CreateLabel(f, { text = L["Y"], size = 11 })
    f.yLabel:SetPoint("TOPLEFT", PAD + 100, ry - 4)
    f.yBox = UI:CreateEditBox(f, {
        width = 62, numeric = true,
        get = function()
            local el = selectedElement(); if not el then return 0 end
            local pos = Registry:GetPos(el)
            return pos.anchor and (pos.anchor.offsetY or 0) or floor((pos.y or 0) + 0.5)
        end,
        onCommit = function(v)
            local el = selectedElement()
            if el then Sess:SetXY(el, tonumber(f.xBox:GetText()) or 0, v) end
        end,
    })
    f.yBox:SetPoint("TOPLEFT", PAD + 122, ry)

    -- ---- nudge arrows (Shift = x10) + 9-point picker -------------
    local ny = row(66)
    local ARROWS = {
        { "expand_less",  0,  1, 24,   0 },
        { "chevron_left", -1, 0,  0, -21 },
        { "chevron_right", 1, 0, 48, -21 },
        { "expand_more",  0, -1, 24, -42 },
    }
    for _, a in ipairs(ARROWS) do
        local icon, dx, dy, ax, ay = a[1], a[2], a[3], a[4], a[5]
        local b = UI:CreateGlyphButton(f, {
            texture = UI.MEDIA .. "Icons\\" .. icon, size = 20, iconSize = 14,
            onClick = function()
                local el = selectedElement()
                if el then Sess:Nudge(el, dx * step(), dy * step()) end
            end,
            tooltip = { title = L["Nudge"], lines = { L["Hold Shift for 10 units."] } },
        })
        b:SetPoint("TOPLEFT", PAD + ax, ny + ay)
    end

    f.points = {}
    for i, point in ipairs(POINTS) do
        local col, rowi = (i - 1) % 3, floor((i - 1) / 3)
        local b = UI:CreateButton(f, {
            width = 16, height = 16,
            onClick = function()
                local el = selectedElement()
                if el then Sess:SetAnchorPoint(el, point) end
            end,
            tooltip = point,
        })
        b:SetPoint("TOPLEFT", PAD + 118 + col * 20, ny - rowi * 20)
        b.point = point
        f.points[i] = b
    end

    -- ---- actions -------------------------------------------------
    local by = row(28)
    local function action(text, x, w, fn, tone)
        local b = UI:CreateButton(f, { text = text, width = w, height = 20, onClick = fn, tone = tone })
        b:SetPoint("TOPLEFT", x, by)
        return b
    end
    f.btnCenter = action(L["Center"], PAD,      68, function() local el = selectedElement(); if el then Sess:Center(el) end end)
    f.btnReset  = action(L["Reset"],  PAD + 72, 68, function() local el = selectedElement(); if el then Sess:Reset(el) end end)
    f.btnDetach = action(L["Detach"], PAD + 144, 68, function() local el = selectedElement(); if el then Sess:Detach(el) end end)

    local uy = row(28)
    f.btnUndo = UI:CreateButton(f, { text = L["Undo"], width = 104, height = 20, onClick = function() Sess:Undo() end })
    f.btnUndo:SetPoint("TOPLEFT", PAD, uy)
    f.btnRedo = UI:CreateButton(f, { text = L["Redo"], width = 104, height = 20, onClick = function() Sess:Redo() end })
    f.btnRedo:SetPoint("TOPLEFT", PAD + 108, uy)

    local fy = row(32)
    f.btnSave = UI:CreateButton(f, { text = L["Save & Exit"], width = 104, height = 22, style = "primary", onClick = function() Sess:Finish("save") end })
    f.btnSave:SetPoint("TOPLEFT", PAD, fy)
    f.btnDiscard = UI:CreateButton(f, { text = L["Discard"], width = 104, height = 22, tone = "danger", onClick = function() Sess:Finish("discard") end })
    f.btnDiscard:SetPoint("TOPLEFT", PAD + 108, fy)

    f:SetHeight(-y + PAD)
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
    local icon = addon and addon.icon or (UI.MEDIA .. "DF_Icon")
    if f.icon:SetTexture(icon) == false then f.icon:SetTexture(UI.MEDIA .. "DF_Icon") end
    f.addon:SetText(addon and addon.title or el.addon)

    if pos.anchor then
        local a = pos.anchor
        local target = Registry:GetTarget(a.target)
        local name = target and target.title or L["(unavailable)"]
        local detail
        if a.mode == "point" then detail = format("%s (%s → %s)", name, a.point, a.relPoint)
        else detail = format("%s (%s/%s)", name, a.edge, a.align) end
        f.anchorLine:SetText(format(L["Anchored to %s"], detail))
        f.xLabel:SetText(L["Offset X"]); f.yLabel:SetText(L["Offset Y"])
        f.btnDetach:SetEnabled(true)
        for _, b in ipairs(f.points) do b:Hide() end
    else
        f.anchorLine:SetText("")
        f.xLabel:SetText(L["X"]); f.yLabel:SetText(L["Y"])
        f.btnDetach:SetEnabled(false)
        local cur = pos.point or "CENTER"
        for _, b in ipairs(f.points) do
            b:Show()
            b:SetActive(b.point == cur)
        end
    end
    f.xBox:Refresh(); f.yBox:Refresh()

    f.btnUndo:SetEnabled(Sess.undo and Sess.undo:CanUndo() or false)
    f.btnRedo:SetEnabled(Sess.undo and Sess.undo:CanRedo() or false)
    self:Dock()
end
