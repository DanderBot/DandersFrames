local addonName, NS = ...

-- ============================================================
-- MINI-PANEL
-- Docks beside the selected proxy on whichever side covers the least (auto),
-- or on the side the user pinned. Parented to the unlock frame so combat
-- suspension hides it for free.
--
-- Deliberately NOT a settings window: it holds only what acts on the SELECTED
-- element plus the session verbs. Editor preferences (snapping, grid size)
-- live behind the cog, because a preference you set once does not belong in a
-- panel you read on every drag.
-- ============================================================
local Pn = {}
NS.Panel = Pn

local Registry, Sess, Proxy, Solver, UI, L = NS.Registry, NS.Session, NS.Proxy, NS.Solver, NS.UI, NS.L
local CreateFrame, UIParent, IsShiftKeyDown, IsControlKeyDown = CreateFrame, UIParent, IsShiftKeyDown, IsControlKeyDown
local xpcall, geterrorhandler = xpcall, geterrorhandler
local GetTime, C_Timer = GetTime, C_Timer
local format, tonumber, ipairs, pairs, floor, max, min = string.format, tonumber, ipairs, pairs, math.floor, math.max, math.min

-- Spacing comes from the theme so this panel keeps the rhythm of every other
-- DandersUI surface: PAD is the outer padding, GAP the gap between rows of
-- different kinds, TIGHT the gap inside a run of like things (buttons in a
-- row, the two X/Y pairs).
local W = 236
local PAD, GAP, TIGHT = UI.Space.section, UI.RowGap, UI.RowGapTight
local CW = W - PAD * 2            -- content width
local DOCK_GAP = 12               -- panel <-> proxy distance
local ICON = 24                   -- header icon, drawn from the full 64px source
local HEADER_H = 26               -- title line + addon line
local BOX_W = 62                  -- X / Y edit boxes
local NUDGE_CELL, NUDGE_ICON = 22, 14
local DOT, DOT_GAP = 16, 4        -- 9-point picker cells
local BTN_H, CTA_H = 20, 22
local POINTS = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" }

local function selectedElement()
    return Sess.selected and Registry:Get(Sess.selected) or nil
end

local function step() return Solver.NudgeStep(IsShiftKeyDown(), IsControlKeyDown()) end

-- A row of equal-width buttons spanning the content width.
local function buttonRow(f, y, height, defs)
    local n = #defs
    local bw = floor((CW - TIGHT * (n - 1)) / n)
    local out = {}
    for i, d in ipairs(defs) do
        local b = UI:CreateButton(f, {
            text = d.text, width = bw, height = height, onClick = d.onClick,
            style = d.style, tone = d.tone, fitText = false,
        })
        b:SetPoint("TOPLEFT", PAD + (i - 1) * (bw + TIGHT), y)
        out[i] = b
    end
    return out
end

local function build()
    local f = CreateFrame("Frame", "DandersMoverPanel", Proxy:GetUnlockFrame(), "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetWidth(W)
    UI:CreatePanelBackdrop(f)
    f:EnableMouse(true)

    local y = -PAD
    -- Reserve a row of height h and return its top; gap is the space to leave below it.
    local function row(h, gap) local cur = y; y = y - h - (gap or GAP); return cur end

    -- ---- header: icon | title / addon ...... settings -------------
    local hy = row(HEADER_H, TIGHT)
    f.icon = f:CreateTexture(nil, "OVERLAY")
    f.icon:SetSize(ICON, ICON)
    f.icon:SetPoint("LEFT", f, "TOPLEFT", PAD, hy - HEADER_H / 2)   -- centred on the header block

    f.btnSettings = UI:CreateButton(f, {
        text = L["Settings"], width = 62, height = 18, style = "ghost",
        tooltip = { title = L["Settings"], lines = { L["Snapping, grid and per-addon mover toggles."] } },
        onClick = function() if NS.Settings then NS.Settings:Toggle() end end,
    })
    f.btnSettings:SetPoint("TOPRIGHT", -PAD, hy)

    -- Consumer settings entry: only shown when the selected element's def has
    -- openSettings (Refresh). Distinct from the Settings button beside it,
    -- which opens the LIB's own settings window.
    f.btnConfigure = UI:CreateButton(f, {
        text = L["Configure"], width = 62, height = 18, style = "ghost",
        tooltip = { title = L["Configure"], lines = { L["Open this element's own settings."] } },
        onClick = function()
            local el = selectedElement()
            if el and el.openSettings then xpcall(el.openSettings, geterrorhandler()) end
        end,
    })
    f.btnConfigure:SetPoint("RIGHT", f.btnSettings, "LEFT", -TIGHT, 0)
    f.btnConfigure:Hide()

    f.headerY = hy
    f.title = UI:CreateLabel(f, { size = 12, color = UI.Colors.text })
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + ICON + TIGHT - 2, hy)
    f.title:SetPoint("TOPRIGHT", f.btnSettings, "TOPLEFT", -TIGHT, 0)
    f.title:SetWordWrap(false)
    f.addon = UI:CreateLabel(f, { size = 10, color = UI.Colors.textDim })
    f.addon:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -1)
    f.addon:SetPoint("TOPRIGHT", f.title, "BOTTOMRIGHT", 0, -1)
    f.addon:SetWordWrap(false)

    -- ---- anchored-to line ----------------------------------------
    f.anchorLine = UI:CreateLabel(f, { size = 10, color = UI.Colors.accent, width = CW })
    f.anchorLine:SetPoint("TOPLEFT", PAD, row(14))

    -- ---- X / Y: two label+box pairs centred as one group ------------
    -- The pairs live in a container whose width is recomputed on Refresh
    -- (the labels change between "X" and "Offset X"), and the container is
    -- centred in the panel, so the group stays centred whatever the labels say.
    local ry = row(20)
    f.xyRow = CreateFrame("Frame", nil, f)
    f.xyRow:SetSize(CW, 20)
    f.xyRow:SetPoint("TOP", f, "TOP", 0, ry)
    f.xLabel = UI:CreateLabel(f.xyRow, { text = L["X"], size = 11, justify = "RIGHT" })
    f.xLabel:SetPoint("LEFT", 0, 0)
    f.xBox = UI:CreateEditBox(f.xyRow, {
        width = BOX_W, numeric = true,
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
    f.xBox:SetPoint("LEFT", f.xLabel, "RIGHT", TIGHT - 2, 0)
    f.yLabel = UI:CreateLabel(f.xyRow, { text = L["Y"], size = 11, justify = "RIGHT" })
    f.yLabel:SetPoint("LEFT", f.xBox, "RIGHT", GAP, 0)
    f.yBox = UI:CreateEditBox(f.xyRow, {
        width = BOX_W, numeric = true,
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
    f.yBox:SetPoint("LEFT", f.yLabel, "RIGHT", TIGHT - 2, 0)

    -- ---- nudge cluster | 9-point picker: two equal halves ------------
    -- Each cluster sits in its own container, centred in its half of the
    -- content width and on the same vertical centre.
    local clusterH = max(NUDGE_CELL * 3, DOT * 3 + DOT_GAP * 2)
    local ny = row(clusterH)
    local half = CW / 2

    f.nudge = CreateFrame("Frame", nil, f)
    f.nudge:SetSize(NUDGE_CELL * 3, NUDGE_CELL * 3)
    f.nudge:SetPoint("CENTER", f, "TOPLEFT", PAD + half / 2, ny - clusterH / 2)
    local ARROWS = {   -- icon, dx, dy, column, row (0-based in the 3x3 cluster)
        { "expand_less",   0,  1, 1, 0 },
        { "chevron_left", -1,  0, 0, 1 },
        { "chevron_right", 1,  0, 2, 1 },
        { "expand_more",   0, -1, 1, 2 },
    }
    for _, a in ipairs(ARROWS) do
        local icon, dx, dy, col, rowi = a[1], a[2], a[3], a[4], a[5]
        local b = UI:CreateGlyphButton(f.nudge, {
            texture = UI.MEDIA .. "Icons\\" .. icon, size = NUDGE_CELL, iconSize = NUDGE_ICON,
            onClick = function()
                local el = selectedElement()
                if el then Sess:Nudge(el, dx * step(), dy * step()) end
            end,
            tooltip = { title = L["Nudge"], lines = { L["Hold Shift for 10 units, Ctrl for 100."] } },
        })
        b:SetPoint("TOPLEFT", col * NUDGE_CELL, -rowi * NUDGE_CELL)
    end

    f.picker = CreateFrame("Frame", nil, f)
    f.picker:SetSize(DOT * 3 + DOT_GAP * 2, DOT * 3 + DOT_GAP * 2)
    f.picker:SetPoint("CENTER", f, "TOPLEFT", PAD + half + half / 2, ny - clusterH / 2)
    f.points = {}
    for i, point in ipairs(POINTS) do
        local col, rowi = (i - 1) % 3, floor((i - 1) / 3)
        local b = UI:CreateButton(f.picker, {
            width = DOT, height = DOT,
            onClick = function()
                local el = selectedElement()
                if el then Sess:SetAnchorPoint(el, point) end
            end,
            tooltip = point,
        })
        b:SetPoint("TOPLEFT", col * (DOT + DOT_GAP), -rowi * (DOT + DOT_GAP))
        b.point = point
        f.points[i] = b
    end

    -- ---- actions -------------------------------------------------
    local acts = buttonRow(f, row(BTN_H, TIGHT), BTN_H, {
        { text = L["Center"], onClick = function() local el = selectedElement(); if el then Sess:Center(el) end end },
        { text = L["Reset"],  onClick = function() local el = selectedElement(); if el then Sess:Reset(el) end end },
        { text = L["Detach"], onClick = function() local el = selectedElement(); if el then Sess:Detach(el) end end },
    })
    f.btnCenter, f.btnReset, f.btnDetach = acts[1], acts[2], acts[3]

    local hist = buttonRow(f, row(BTN_H), BTN_H, {
        { text = L["Undo"], onClick = function() Sess:Undo() end },
        { text = L["Redo"], onClick = function() Sess:Redo() end },
    })
    f.btnUndo, f.btnRedo = hist[1], hist[2]

    local fin = buttonRow(f, row(CTA_H, 0), CTA_H, {
        { text = L["Save & Exit"], style = "primary", onClick = function() Sess:Finish("save") end },
        { text = L["Discard"], tone = "danger", onClick = function() Sess:Finish("discard") end },
    })
    f.btnSave, f.btnDiscard = fin[1], fin[2]

    f:SetHeight(-y + PAD)
    f:Hide()
    return f
end

-- Size the X/Y group to its current labels so it stays centred. Both labels
-- take the wider of the two, so the pairs mirror each other; the boxes give up
-- width when the labels are long ("Offset X") so the group never overflows.
local function layoutXY(f)
    local lw = max(f.xLabel:GetStringWidth() or 0, f.yLabel:GetStringWidth() or 0)
    f.xLabel:SetWidth(lw); f.yLabel:SetWidth(lw)
    local pair = lw + TIGHT - 2
    local bw = max(40, floor(min(BOX_W, (CW - GAP) / 2 - pair)))
    f.xBox:SetWidth(bw); f.yBox:SetWidth(bw)
    f.xyRow:SetWidth((pair + bw) * 2 + GAP)
end

function Pn:Ensure()
    if not self.frame then self.frame = build() end
    return self.frame
end

-- Instant hide: combat suspend, session teardown, selection loss mid-refresh.
-- Cancels any running fade so a stale "hide when done" cannot land later.
function Pn:Hide()
    self.holdUntil = nil          -- a hidden panel has nothing to hold in place
    self.dockedTo = nil
    if self.frame then
        NS.Fx.Cancel(self.frame)
        self.frame:Hide()
    end
end

-- Deselection: fade out (0.1s), then hide. Suspend never comes through here.
function Pn:FadeOut()
    self.holdUntil = nil
    self.dockedTo = nil
    local f = self.frame
    if not f or not f:IsShown() then return end
    NS.Fx.FadeOut(f, 0.1, function() f:Hide() end)
end

-- ============================================================
-- NUDGE HOLD
-- Re-docking on every keypress makes the panel chase the frame around, so a
-- nudge parks it: each nudge pushes the deadline out, and one C_Timer chain
-- re-docks once after the LAST nudge's hold expires. Session:Select clears the
-- hold, so an explicit selection always docks immediately.
-- ============================================================
local HOLD = 2

function Pn:HoldDock()
    self.holdUntil = GetTime() + HOLD
    if self.holdTimerArmed then return end
    self.holdTimerArmed = true
    local function tick()
        if not self.holdUntil then self.holdTimerArmed = false return end
        local left = self.holdUntil - GetTime()
        if left > 0 then
            C_Timer.After(left, tick)
        else
            self.holdTimerArmed = false
            self.holdUntil = nil
            if Sess:IsActive() and not Sess:IsSuspended() then self:Dock() end
        end
    end
    C_Timer.After(HOLD, tick)
end

function Pn:ClearHold() self.holdUntil = nil end

-- Rect of a frame in UIParent-centre units; nil while it has no geometry yet.
local function rectOf(fr)
    local cx, cy = fr:GetCenter()
    if not cx then return nil end
    local ux, uy = UIParent:GetCenter()
    return { x = cx - ux, y = cy - uy, w = fr:GetWidth() or 0, h = fr:GetHeight() or 0 }
end

-- "auto": the candidate beside the proxy that covers the least, scored against
-- every OTHER visible proxy and the legend (Solver.BestDockSide). nil when no
-- candidate fits fully on screen.
local function autoSide(f, proxy)
    local pr = rectOf(proxy)
    if not pr then return nil end
    local obstacles = {}
    for _, b in pairs(Proxy.proxies) do
        if b ~= proxy and b:IsShown() then
            local r = rectOf(b)
            if r then obstacles[#obstacles + 1] = r end
        end
    end
    if Proxy.legend and Proxy.legend:IsShown() then
        local r = rectOf(Proxy.legend)
        if r then obstacles[#obstacles + 1] = r end
    end
    return Solver.BestDockSide(pr, W, f:GetHeight() or 0, DOCK_GAP, obstacles,
        UIParent:GetWidth(), UIParent:GetHeight())
end

function Pn:Dock()
    local f = self.frame
    local proxy = Sess.selected and Proxy.proxies[Sess.selected]
    if not f or not proxy or not proxy:IsShown() then self:Hide() return end
    -- Parked by a nudge: keep the panel where it is until the hold expires.
    if self.holdUntil then
        if GetTime() < self.holdUntil then return end
        self.holdUntil = nil
    end
    local side = NS.db.panelSide
    if side == "auto" then
        -- Least-covering side; when nothing fits on screen, the old edge flip.
        side = autoSide(f, proxy)
        if not side then
            side = ((proxy:GetRight() or 0) + DOCK_GAP + W > (UIParent:GetRight() or 0)) and "left" or "right"
        end
    end
    f:ClearAllPoints()
    if side == "left" then f:SetPoint("TOPRIGHT", proxy, "TOPLEFT", -DOCK_GAP, 0)
    elseif side == "below" then f:SetPoint("TOP", proxy, "BOTTOM", 0, -DOCK_GAP)
    elseif side == "above" then f:SetPoint("BOTTOM", proxy, "TOP", 0, DOCK_GAP)
    else f:SetPoint("TOPLEFT", proxy, "TOPRIGHT", DOCK_GAP, 0) end

    -- Entrance: pop from behind the proxy -- scale up from 0.92 with the scale
    -- originating at the docked edge, sliding from the proxy's side onto the
    -- anchor, ease-out (Fx.PopIn). Target changed while the panel was already
    -- up: a quick fade-swap, no pop. Same target: nothing -- Dock runs on
    -- every Refresh and must not flicker the panel.
    local wasShown = f:IsShown()
    if not wasShown then
        local ox, oy, origin = 0, 0, "CENTER"
        if side == "right" then ox, origin = -8, "LEFT"
        elseif side == "left" then ox, origin = 8, "RIGHT"
        elseif side == "below" then oy, origin = 8, "TOP"
        elseif side == "above" then oy, origin = -8, "BOTTOM" end
        NS.Fx.PopIn(f, 0.12, ox, oy, 0.92, origin)
    elseif self.dockedTo ~= Sess.selected then
        NS.Fx.FadeIn(f, 0.08)
    end
    self.dockedTo = Sess.selected
    f:Show()
end

function Pn:Refresh()
    if not Sess:IsActive() or Sess:IsSuspended() then self:Hide() return end
    local el = selectedElement()
    if not el then self:FadeOut() return end
    local f = self:Ensure()
    local pos = Registry:GetPos(el)

    f.title:SetText(el.title)
    -- Configure only exists for elements whose def offers openSettings; the
    -- title gives up the room while the extra button is up.
    local canConfigure = el.openSettings ~= nil
    f.btnConfigure:SetShown(canConfigure)
    f.title:ClearAllPoints()
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + ICON + TIGHT - 2, f.headerY)
    f.title:SetPoint("TOPRIGHT", canConfigure and f.btnConfigure or f.btnSettings, "TOPLEFT", -TIGHT, 0)
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
            -- pointLocked: the consumer derives `point` (e.g. a growth corner); a
            -- picker would be silently overwritten, so it is not offered.
            b:SetShown(not el.pointLocked)
            b:SetActive(b.point == cur)
        end
    end
    layoutXY(f)
    f.xBox:Refresh(); f.yBox:Refresh()

    f.btnUndo:SetEnabled(Sess.undo and Sess.undo:CanUndo() or false)
    f.btnRedo:SetEnabled(Sess.undo and Sess.undo:CanRedo() or false)
    self:Dock()
end
