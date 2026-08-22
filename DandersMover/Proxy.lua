local addonName, NS = ...

-- ============================================================
-- PROXIES
-- One plain Button per movable element, parented to the unlock frame.
-- The proxy is what the user drags; the real frame only ever moves through
-- the consumer's onChanged. Also owns the snap-zone visual pool.
-- ============================================================
local P = { proxies = {}, zones = {}, zoneCount = 0, dragZones = {} }
NS.Proxy = P

local Registry, Solver, T, L = NS.Registry, NS.Solver, NS.Theme, NS.L
local CreateFrame, UIParent, GetCursorPosition, GameTooltip = CreateFrame, UIParent, GetCursorPosition, GameTooltip
local pairs, ipairs, format, sqrt, abs = pairs, ipairs, string.format, math.sqrt, math.abs

local MEDIA = "Interface\\AddOns\\DandersMover\\Media\\"
local DEFAULT_ICON = MEDIA .. "DF_Icon"
local LINK_ICON = MEDIA .. "link"
local PROXIMITY = 100
local MIN_PROXY = 24
local C_ZONE_NEAR = { 0.3, 0.7, 1.0 }
local C_ZONE_HOVER = { 0.3, 0.8, 1.0 }
local C_ZONE_OCCUPIED = { 0.8, 0.2, 0.2 }

-- ============================================================
-- UNLOCK FRAME + CURSOR
-- ============================================================
function P:GetUnlockFrame()
    if self.unlockFrame then return self.unlockFrame end
    local f = CreateFrame("Frame", "DandersMoverUnlockFrame", UIParent)
    f:SetAllPoints(UIParent)
    f:SetFrameStrata("HIGH")
    f:Hide()
    self.unlockFrame = f
    return f
end

function P:CursorPos()
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    return x / s - ux, y / s - uy
end

-- ============================================================
-- PROXY LIFECYCLE
-- ============================================================
local function onDragStart(self)
    local el = self.element
    local cx, cy = P:CursorPos()
    local pcx, pcy = self:GetCenter()
    local ux, uy = UIParent:GetCenter()
    self.grabX, self.grabY = cx - (pcx - ux), cy - (pcy - uy)
    self.startX, self.startY = pcx - ux, pcy - uy
    -- Seed the drop values so a drag that ends before its first OnUpdate
    -- commits the start position rather than nil or a previous drag's values.
    self.lastX, self.lastY, self.lastZone = self.startX, self.startY, nil
    self.axis = nil
    self.dragging = true
    GameTooltip:Hide()
    NS.Session.selected = el.id            -- select without docking the panel; EndDrag re-docks it
    P:Highlight(el.id)
    if NS.Panel then NS.Panel:Hide() end
    NS.Session:BeginDrag(el)
    P:ShowZones(el)
    self:SetScript("OnUpdate", function(s)
        local mx, my = P:CursorPos()
        local nx, ny = mx - s.grabX, my - s.grabY
        if IsShiftKeyDown() then
            if not s.axis then
                local dx, dy = abs(nx - s.startX), abs(ny - s.startY)
                if dx > 2 or dy > 2 then s.axis = dx >= dy and "x" or "y" end
            end
            if s.axis == "x" then ny = s.startY elseif s.axis == "y" then nx = s.startX end
        else
            s.axis = nil
        end
        local fx, fy, zone = NS.Session:DragTo(el, nx, ny)
        s:ClearAllPoints(); s:SetPoint("CENTER", UIParent, "CENTER", fx, fy)
        s.coords:SetText(format("%d, %d", fx, fy))
        P:UpdateZones(fx, fy, zone)
        s.lastX, s.lastY, s.lastZone = fx, fy, zone
    end)
end

local function onDragStop(self)
    if not self.dragging then return end
    self.dragging = false
    self:SetScript("OnUpdate", nil)
    P:HideZones()
    NS.Grid:HidePreview()
    NS.Session:EndDrag(self.element, self.lastX, self.lastY, self.lastZone)
end

local function onClick(self, button)
    if button == "RightButton" then NS.Session:Lock() return end
    NS.Session:Select(self.element.id)
end

local function create(el)
    local b = CreateFrame("Button", nil, P:GetUnlockFrame(), "BackdropTemplate")
    T.Backdrop(b, { 0.18, 0.612, 0.792, 0.25 }, T.C.accent)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(false)
    b:SetClampedToScreen(false)
    b.title = T.Label(b, el.title, 11); b.title:SetPoint("CENTER", 0, 6)
    b.coords = T.Label(b, "", 9); b.coords:SetPoint("CENTER", 0, -7); b.coords:SetTextColor(T.Unpack(T.C.muted))
    -- Owning addon's icon (top-left); falls back to the DF icon bundled with the lib.
    b.icon = b:CreateTexture(nil, "OVERLAY")
    b.icon:SetSize(14, 14); b.icon:SetPoint("TOPLEFT", 3, -3)
    local addon = Registry:GetAddon(el.addon)
    if not b.icon:SetTexture(addon and addon.icon or DEFAULT_ICON) then b.icon:SetTexture(DEFAULT_ICON) end
    -- Link icon (bottom-left) while anchored.
    b.link = b:CreateTexture(nil, "OVERLAY")
    b.link:SetTexture(LINK_ICON); b.link:SetSize(12, 12); b.link:SetPoint("BOTTOMLEFT", 3, 3)
    b.link:SetVertexColor(T.Unpack(T.C.anchored)); b.link:Hide()
    -- Centre crosshair.
    b.crossH = b:CreateTexture(nil, "OVERLAY"); b.crossH:SetColorTexture(1, 1, 1, 0.4); b.crossH:SetSize(16, 1); b.crossH:SetPoint("CENTER")
    b.crossV = b:CreateTexture(nil, "OVERLAY"); b.crossV:SetColorTexture(1, 1, 1, 0.4); b.crossV:SetSize(1, 16); b.crossV:SetPoint("CENTER")
    b:SetScript("OnDragStart", onDragStart)
    b:SetScript("OnDragStop", onDragStop)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(1, 1, 1, 1); P:ShowTooltip(s) end)
    b:SetScript("OnLeave", function(s) P:Highlight(NS.Session.selected); GameTooltip:Hide() end)
    b.element = el
    return b
end

function P:Build(addonFilter)
    local f = self:GetUnlockFrame()
    for _, el in ipairs(Registry:SortedElements()) do
        local wanted = (not addonFilter or el.addon == addonFilter) and Registry:IsEnabled(el.addon, el.key)
        if wanted then
            local frame = Registry:GetFrame(el)
            if NS.db.showHiddenMovers or (frame and frame:IsShown()) then
                local b = self.proxies[el.id] or create(el)
                b.element = el
                self.proxies[el.id] = b
                self:Refresh(el.id)
                b:Show()
            end
        end
    end
    f:Show()
end

function P:Refresh(id)
    local b = self.proxies[id]
    if not b or b.dragging then return end
    local el = b.element
    local rect = Registry:GetRect(el)
    local pos = Registry:GetPos(el)
    local w, h = Registry:GetSize(el)
    w, h = w or MIN_PROXY, h or MIN_PROXY
    local cx, cy
    if rect then cx, cy = rect.x, rect.y; w, h = rect.w, rect.h
    else cx, cy = Solver.PointToCenter(pos.point or "CENTER", pos.x or 0, pos.y or 0, w, h) end
    b:SetSize(math.max(w, MIN_PROXY), math.max(h, MIN_PROXY))
    b:ClearAllPoints(); b:SetPoint("CENTER", UIParent, "CENTER", cx, cy)
    b.coords:SetText(format("%d, %d", cx, cy))
    local frame = Registry:GetFrame(el)
    b:SetAlpha((frame and frame:IsShown()) and 1 or 0.45)
    self:Highlight(NS.Session and NS.Session.selected)
end

function P:RefreshAll() for id in pairs(self.proxies) do self:Refresh(id) end end

function P:Highlight(selectedId)
    for id, b in pairs(self.proxies) do
        local pos = Registry:GetPos(b.element)
        local c = pos.anchor and T.C.anchored or T.C.accent
        b.link:SetShown(pos.anchor ~= nil)
        if id == selectedId then b:SetBackdropBorderColor(1, 1, 1, 1) else b:SetBackdropBorderColor(T.Unpack(c)) end
        b:SetBackdropColor(c[1], c[2], c[3], 0.25)
    end
end

function P:Remove(id)
    local b = self.proxies[id]
    if b then b:Hide(); b:SetScript("OnUpdate", nil); self.proxies[id] = nil end
end

function P:RemoveAddon(addon)
    for id, b in pairs(self.proxies) do if b.element.addon == addon then self:Remove(id) end end
end

function P:DestroyAll()
    for id in pairs(self.proxies) do self:Remove(id) end
    if self.unlockFrame then self.unlockFrame:Hide() end
    self:HideZones()
end

-- ============================================================
-- TOOLTIP
-- ============================================================
function P:ShowTooltip(b)
    if b.dragging then return end
    local el = b.element
    local addon = Registry:GetAddon(el.addon)
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:AddLine(el.title, 1, 1, 1)
    GameTooltip:AddLine(addon and addon.title or el.addon, T.C.muted[1], T.C.muted[2], T.C.muted[3])
    local a = Registry:GetPos(el).anchor
    if a then
        local target = Registry:GetTarget(a.target)
        local name = target and target.title or L["(unavailable)"]
        local how = a.mode == "point" and format("%s → %s", a.point, a.relPoint) or format("%s/%s", a.edge, a.align)
        GameTooltip:AddLine(format(L["Anchored to %s"], format("%s (%s)", name, how)), T.C.anchored[1], T.C.anchored[2], T.C.anchored[3])
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Drag to move. Shift locks an axis."], 0.8, 0.8, 0.8)
    GameTooltip:AddLine(L["Click to select, arrow keys to nudge."], 0.8, 0.8, 0.8)
    if a then GameTooltip:AddLine(L["Drop into a zone to re-anchor; Detach frees it."], 0.8, 0.8, 0.8) end
    GameTooltip:AddLine(L["Right-click to lock."], 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

-- ============================================================
-- SNAP ZONES
-- ============================================================
local function zoneFrame(i)
    local z = P.zones[i]
    if not z then
        z = CreateFrame("Frame", nil, P:GetUnlockFrame(), "BackdropTemplate")
        z:SetFrameLevel(1)
        T.Backdrop(z, { 0, 0, 0, 0 }, { 0, 0, 0, 0 })
        P.zones[i] = z
    end
    return z
end

function P:ShowZones(el)
    wipe(self.dragZones)
    if not NS.db.snapToFrames then self.zoneCount = 0 return end
    local w, h = Registry:GetSize(el)
    if not w then return end
    local descendants = {}
    for _, d in ipairs(Registry:Descendants(el.id)) do descendants[d.id] = true end
    local n = 0
    for _, target in ipairs(Registry:SortedTargets()) do
        local canon = Registry:CanonicalId(target.id)
        local tf = Registry:GetFrame(target)
        local usable = canon ~= el.id and not descendants[canon]
            and tf ~= nil and tf:IsShown()              -- hidden frames are not snap targets (CDM rule)
            and Registry:IsEnabled(target.addon, target.key)
            and not Registry:WouldCreateCycle(el.id, target.id)
        if usable then
            local rect = Registry:GetRect(target)
            local zones = Solver.SnapZones(target.id, rect, w, h, Solver.SPACING,
                function(edge, align) return Registry:IsOccupied(target.id, edge, align, el.id) end)
            for _, zone in ipairs(zones) do
                n = n + 1
                self.dragZones[n] = zone
                local zf = zoneFrame(n)
                zf:SetSize(w, h)
                zf:ClearAllPoints(); zf:SetPoint("CENTER", UIParent, "CENTER", zone.x, zone.y)
                zf.zone = zone
                zf:SetBackdropColor(0, 0, 0, 0); zf:SetBackdropBorderColor(0, 0, 0, 0)
                zf:Show()
            end
        end
    end
    self.zoneCount = n
    for i = n + 1, #self.zones do self.zones[i]:Hide() end
end

function P:UpdateZones(cx, cy, hovered)
    local closest, closestD = nil, PROXIMITY
    for i = 1, self.zoneCount do
        local z = self.zones[i].zone
        local d = sqrt((cx - z.x) ^ 2 + (cy - z.y) ^ 2)
        if d < closestD then closestD = d; closest = z.target end
    end
    for i = 1, self.zoneCount do
        local zf = self.zones[i]
        local z = zf.zone
        if hovered and z == hovered then
            zf:SetBackdropColor(C_ZONE_HOVER[1], C_ZONE_HOVER[2], C_ZONE_HOVER[3], 0.35)
            zf:SetBackdropBorderColor(C_ZONE_HOVER[1], C_ZONE_HOVER[2], C_ZONE_HOVER[3], 0.6)
        elseif closest and z.target == closest and sqrt((cx - z.x) ^ 2 + (cy - z.y) ^ 2) < PROXIMITY then
            local d = sqrt((cx - z.x) ^ 2 + (cy - z.y) ^ 2)
            local f = 0.2 + Solver.ProximityFactor(d, PROXIMITY) * 0.8
            if z.occupied then f = f * 0.5 end   -- occupied zones read quieter (CDM rule)
            local c = z.occupied and C_ZONE_OCCUPIED or C_ZONE_NEAR
            zf:SetBackdropColor(c[1], c[2], c[3], 0.15 * f)
            zf:SetBackdropBorderColor(c[1], c[2], c[3], 0.3 * f)
        else
            zf:SetBackdropColor(0, 0, 0, 0); zf:SetBackdropBorderColor(0, 0, 0, 0)
        end
    end
end

function P:HideZones()
    for i = 1, #self.zones do self.zones[i]:Hide() end
    self.zoneCount = 0
    wipe(self.dragZones)
end
