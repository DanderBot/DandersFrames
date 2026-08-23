local addonName, NS = ...

-- ============================================================
-- PROXIES
-- One plain Button per movable element, parented to the unlock frame.
-- The proxy is what the user drags; the real frame only ever moves through
-- the consumer's onChanged. Also owns the snap-zone visual pool.
-- ============================================================
local P = { proxies = {}, zones = {}, zoneCount = 0, dragZones = {} }
NS.Proxy = P

local Registry, Solver, UI, L = NS.Registry, NS.Solver, NS.UI, NS.L
local CreateFrame, UIParent, GetCursorPosition, GameTooltip, C_Timer = CreateFrame, UIParent, GetCursorPosition, GameTooltip, C_Timer
local IsShiftKeyDown, IsControlKeyDown = IsShiftKeyDown, IsControlKeyDown
local pairs, ipairs, format, sqrt, max = pairs, ipairs, string.format, math.sqrt, math.max

local MEDIA = "Interface\\AddOns\\DandersMover\\Media\\"
local DEFAULT_ICON = MEDIA .. "DF_Icon"
local LINK_ICON = MEDIA .. "link"
local ROOT_ICON = UI.MEDIA .. "Icons\\dot"
-- Role colours. FREE (no anchor, nothing anchored to it) = the host accent;
-- CHILD (anchored to something) = C_ANCHORED; ROOT (free, with children) =
-- the theme's anchorRoot green. A root that is itself a child keeps the
-- anchored colour and shows the root marker.
local C_ANCHORED = { r = 0.55, g = 0.40, b = 0.85, a = 1 }
local C_ROOT = UI.Colors.anchorRoot
local C_MUTED = UI.Colors.textDim
local PAD, GAP, TIGHT = UI.Space.section, UI.RowGap, UI.RowGapTight
local SWATCH = 10
-- Only reached when the SV predate the setting; NS.DEFAULTS.snapDistance is the value.
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
        -- Axis locks: Shift = horizontal only, Ctrl = vertical only. Both held
        -- cancel out to a free drag. Read every frame, so the lock can be taken
        -- and released mid-drag.
        local shift, ctrl = IsShiftKeyDown(), IsControlKeyDown()
        if shift and not ctrl then ny = s.startY elseif ctrl and not shift then nx = s.startX end
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
    local ac = UI:GetAccent()
    UI:CreateElementBackdrop(b, { bgColor = { ac.r, ac.g, ac.b, 0.25 }, borderColor = { ac.r, ac.g, ac.b, 1 } })
    UI:ApplyPixelBorder(b, { ac.r, ac.g, ac.b, 1 }, 2)   -- 2px solid so the role colour reads at a glance
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(false)
    b:SetClampedToScreen(false)
    b.title = UI:CreateLabel(b, { text = el.title, size = 11 }); b.title:SetPoint("CENTER", 0, 6)
    b.coords = UI:CreateLabel(b, { size = 9, color = C_MUTED }); b.coords:SetPoint("CENTER", 0, -7)
    -- Owning addon's icon (top-left); falls back to the DF icon bundled with the lib.
    b.icon = b:CreateTexture(nil, "OVERLAY")
    b.icon:SetSize(14, 14); b.icon:SetPoint("TOPLEFT", 3, -3)
    local addon = Registry:GetAddon(el.addon)
    if b.icon:SetTexture(addon and addon.icon or DEFAULT_ICON) == false then b.icon:SetTexture(DEFAULT_ICON) end
    -- Link icon (bottom-left) while anchored.
    b.link = b:CreateTexture(nil, "OVERLAY")
    b.link:SetTexture(LINK_ICON); b.link:SetSize(12, 12); b.link:SetPoint("BOTTOMLEFT", 3, 3)
    b.link:SetVertexColor(C_ANCHORED.r, C_ANCHORED.g, C_ANCHORED.b); b.link:Hide()
    -- Root marker (top-right) while something is anchored to this element.
    b.root = b:CreateTexture(nil, "OVERLAY")
    b.root:SetTexture(ROOT_ICON); b.root:SetSize(12, 12); b.root:SetPoint("TOPRIGHT", -3, -3)
    b.root:SetVertexColor(C_ROOT.r, C_ROOT.g, C_ROOT.b); b.root:Hide()
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

-- filter is the NORMALISED session filter (Session.filter): nil, or
-- { addon = <string|nil>, keySet = <set|nil> }. The initiator's keys outside keySet
-- get NO proxy at all, not a dimmed one (a party unlock must not put raid proxies on
-- screen); other addons' elements get one only with showOtherAddons (Registry:WantsProxy).
function P:Build(filter)
    local f = self:GetUnlockFrame()
    for _, el in ipairs(Registry:SortedElements()) do
        if Registry:WantsProxy(filter, el) then
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
    self:ShowLegend()
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

-- The colour an element's proxy wears for its role, and whether it is a root.
-- Children() is alias-aware, so a target that resolves to this element's
-- frame counts too.
local function roleColor(el, pos)
    local isRoot = #Registry:Children(el.id) > 0
    if pos.anchor then return C_ANCHORED, isRoot end
    if isRoot then return C_ROOT, true end
    return UI:GetAccent(), false
end

function P:Highlight(selectedId)
    for id, b in pairs(self.proxies) do
        local pos = Registry:GetPos(b.element)
        local c, isRoot = roleColor(b.element, pos)
        b.link:SetShown(pos.anchor ~= nil)
        b.root:SetShown(isRoot)
        if id == selectedId then b:SetBackdropBorderColor(1, 1, 1, 1) else b:SetBackdropBorderColor(c.r, c.g, c.b, 1) end
        b:SetBackdropColor(c.r, c.g, c.b, 0.25)
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
    self:HideLegend()
end

-- ============================================================
-- LEGEND
-- Docked top-centre for the session: what the three proxy colours mean plus
-- the modifier hints. Parented to the unlock frame, so suspend and lock hide
-- it with everything else.
-- ============================================================
local function buildLegend()
    local f = CreateFrame("Frame", "DandersMoverLegend", P:GetUnlockFrame(), "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    UI:CreateElementBackdrop(f, { bgColor = UI.Colors.background })
    f:SetPoint("TOP", UIParent, "TOP", 0, -PAD)

    local function entry(prev, color, text)
        local swatch = f:CreateTexture(nil, "OVERLAY")
        swatch:SetSize(SWATCH, SWATCH)
        swatch:SetColorTexture(color.r, color.g, color.b, 1)
        local label = UI:CreateLabel(f, { text = text, size = 11 })
        if prev then swatch:SetPoint("LEFT", prev, "RIGHT", GAP, 0)
        else         swatch:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD - 1) end
        label:SetPoint("LEFT", swatch, "RIGHT", TIGHT - 2, 0)
        return label
    end
    f.entries = {}
    f.entries[1] = entry(nil,          UI:GetAccent(), L["Free"])
    f.entries[2] = entry(f.entries[1], C_ANCHORED,     L["Anchored"])
    f.entries[3] = entry(f.entries[2], C_ROOT,         L["Anchor root"])

    f.hint = UI:CreateLabel(f, { text = L["Shift: horizontal · Ctrl: vertical · Right-click: lock"], size = 10, color = C_MUTED })
    f.hint:SetPoint("TOP", f, "TOP", 0, -PAD - 12 - TIGHT)

    -- Third row, consumer-initiated sessions only: other addons' enabled+relevant
    -- elements are anchor targets already; this also gives them proxies. Same
    -- persisted toggle as Settings > Editor; both rebuild the proxies live.
    f.other = UI:CreateCheckbox(f, {
        label = L["Show other addons' movers"],
        get = function() return NS.db.showOtherAddons end,
        set = function(v) NS.db.showOtherAddons = v and true or false; NS.Session:RebuildProxies() end,
    })
    f.other:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD - 12 - TIGHT - 12 - TIGHT)

    -- Width from the measured text. Fonts resolve a frame late, so this runs
    -- again on the next frame (same converge-next-frame shape as the kit's
    -- own labels).
    function f:Layout()
        local row = PAD
        for i, label in ipairs(self.entries) do
            row = row + SWATCH + TIGHT - 2 + (label:GetStringWidth() or 0) + (i < #self.entries and GAP or 0)
        end
        row = row + PAD
        local hintW = (self.hint:GetStringWidth() or 0) + PAD * 2
        -- The checkbox row only exists for a consumer-initiated session (a filter
        -- with an addon); /mover has no "other" addons.
        local filter = NS.Session and NS.Session.filter
        local showOther = (filter and filter.addon) and true or false
        self.other:SetShown(showOther)
        self.other:Refresh()
        local h = PAD + 12 + TIGHT + 12 + PAD
        if showOther then
            self.other:SetWidth(max(row, hintW) - PAD * 2)
            h = h + TIGHT + UI.RowHeight.checkbox - GAP
        end
        self:SetSize(max(row, hintW), h)
    end
    return f
end

function P:ShowLegend()
    if not self.legend then self.legend = buildLegend() end
    local f = self.legend
    f:Layout()
    if C_Timer then C_Timer.After(0, function() if f:IsShown() then f:Layout() end end) end
    f:Show()
end

function P:HideLegend()
    if self.legend then self.legend:Hide() end
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
    GameTooltip:AddLine(addon and addon.title or el.addon, C_MUTED.r, C_MUTED.g, C_MUTED.b)
    local a = Registry:GetPos(el).anchor
    if a then
        local target = Registry:GetTarget(a.target)
        local name = target and target.title or L["(unavailable)"]
        local how = a.mode == "point" and format("%s → %s", a.point, a.relPoint) or format("%s/%s", a.edge, a.align)
        GameTooltip:AddLine(format(L["Anchored to %s"], format("%s (%s)", name, how)), C_ANCHORED.r, C_ANCHORED.g, C_ANCHORED.b)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Drag to move. Shift locks to horizontal, Ctrl to vertical."], 0.8, 0.8, 0.8)
    GameTooltip:AddLine(L["Click to select, arrow keys to nudge (Shift ×10, Ctrl ×100)."], 0.8, 0.8, 0.8)
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
        UI:CreateElementBackdrop(z, { bgColor = { 0, 0, 0, 0 }, borderColor = { 0, 0, 0, 0 } })
        UI:ApplyPixelBorder(z, { 0, 0, 0, 0 }, 2)
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
        local usable = canon ~= el.id and not descendants[canon]
            and Registry:IsTargetAvailable(target)      -- hidden/unavailable frames are not snap targets (CDM rule)
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
    -- The same radius the drag snaps on (Session:DragTo), so a zone that lights up
    -- is a zone that will take the drop. Reading it per call, not per session: the
    -- slider can move while the settings window is open mid-unlock.
    local radius = (NS.db and NS.db.snapDistance) or PROXIMITY
    local closest, closestD = nil, radius
    for i = 1, self.zoneCount do
        local z = self.zones[i].zone
        local d = sqrt((cx - z.x) ^ 2 + (cy - z.y) ^ 2)
        if d < closestD then closestD = d; closest = z.target end
    end
    for i = 1, self.zoneCount do
        local zf = self.zones[i]
        local z = zf.zone
        if hovered and z == hovered then
            zf:SetBackdropColor(C_ZONE_HOVER[1], C_ZONE_HOVER[2], C_ZONE_HOVER[3], 0.45)
            zf:SetBackdropBorderColor(C_ZONE_HOVER[1], C_ZONE_HOVER[2], C_ZONE_HOVER[3], 1)
        elseif closest and z.target == closest and sqrt((cx - z.x) ^ 2 + (cy - z.y) ^ 2) < radius then
            local d = sqrt((cx - z.x) ^ 2 + (cy - z.y) ^ 2)
            local f = 0.2 + Solver.ProximityFactor(d, radius) * 0.8
            if z.occupied then f = f * 0.5 end   -- occupied zones read quieter (CDM rule)
            local c = z.occupied and C_ZONE_OCCUPIED or C_ZONE_NEAR
            zf:SetBackdropColor(c[1], c[2], c[3], 0.22 * f)
            zf:SetBackdropBorderColor(c[1], c[2], c[3], 0.85 * f)
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
