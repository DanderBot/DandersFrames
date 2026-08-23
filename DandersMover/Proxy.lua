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
local DOT_ICON = UI.MEDIA .. "Icons\\dot"
-- Role colours, all off the shared palette. FREE (no anchor, nothing anchored
-- to it) = the party accent; CHILD (anchored to something) = the anchored
-- purple; ROOT (free, with children) = the anchorRoot green. A root that is
-- itself a child keeps the anchored colour and wears the root ring on its dot.
-- Free elements use the HOST accent (the mover sets a blue), not the shared
-- lavender: at 9px the lavender is indistinguishable from the anchored purple.
local C_FREE = UI:GetAccent() or UI.Colors.accent
local C_ANCHORED = UI.Colors.anchored
local C_ROOT = UI.Colors.anchorRoot
local C_MUTED = UI.Colors.textDim
local C_BODY = UI.Colors.panel          -- the slab itself
local C_OUTLINE = UI.Colors.border      -- neutral hairline; the ROLE never colours it
local PAD, GAP, TIGHT = UI.Space.section, UI.RowGap, UI.RowGapTight
local DOT, DOT_RING = 9, 11             -- role dot, and the root ring behind it
-- Only reached when the SV predate the setting; NS.DEFAULTS.snapDistance is the value.
local PROXIMITY = 100
local MIN_PROXY = 24
-- Slab metrics. The theme's row rhythm (UI.Space / UI.RowGap) is page-scale, and
-- a proxy is only ever as big as the frame it stands in for -- which can be 24px
-- square -- so the inline art carries its own small scale.
local EDGE_W = 3                        -- role-coloured left edge
local ICON_SZ, LINK_SZ = 16, 12
local INSET, ITEM = 4, 4                -- slab padding, gap between inline items
local BODY_ALPHA, HOVER_ALPHA = 0.95, 1
local WEIGHT, SEL_WEIGHT = 1, 1         -- outline thickness; selection is colour, not weight
-- Below these the slab cannot hold everything, so parts drop out in this order:
-- the coords first, then the addon icon, then all but a shortened title.
local NO_COORDS_H, NO_COORDS_W, NO_ICON_W, TITLE_ONLY_W = 28, 120, 80, 60
-- Snap zones. Same accent as the free-role dot, because a zone IS where a free
-- drop would land; occupied ones go red. Hover is the only place a zone borrows
-- the selection white, and the kit has no white token, so that one is a literal.
local C_ZONE = UI.Colors.accent
local C_ZONE_OCCUPIED = UI.Colors.danger
local C_ZONE_HOVER = { r = 1, g = 1, b = 1 }
local ZONE_WEIGHT, ZONE_HOVER_WEIGHT = 1, 2
local TAG_PAD = 3                        -- padding of the floating title pill
local ZONE_DASH_W = 2                    -- dashed-edge thickness
local DASH_H, DASH_V = MEDIA .. "dash_h", MEDIA .. "dash_v"

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
        P:UpdateLegendDodge(fx, fy, s:GetWidth() or 0, s:GetHeight() or 0)
        s.lastX, s.lastY, s.lastZone = fx, fy, zone
    end)
end

local function onDragStop(self)
    if not self.dragging then return end
    self.dragging = false
    self:SetScript("OnUpdate", nil)
    P:HideZones()
    P:ClearLegendDodge()
    NS.Grid:HidePreview()
    NS.Session:EndDrag(self.element, self.lastX, self.lastY, self.lastZone)
end

local function onClick(self, button)
    if button == "RightButton" then NS.Session:Lock() return end
    NS.Session:Select(self.element.id)
end


-- Lay the slab's contents out for its CURRENT size. A proxy is exactly as big as
-- the frame it stands in for, so one 24px icon mover and one full raid container
-- come through here: parts drop out as the room runs out rather than overlapping.
local function layout(b, anchored)
    local w = b:GetWidth() or 0
    local h = b:GetHeight() or 0
    local titleOnly = w < TITLE_ONLY_W
    local showIcon = not titleOnly and w >= NO_ICON_W
    local showCoords = not titleOnly and w >= NO_COORDS_W and h >= NO_COORDS_H
    local showLink = anchored and not titleOnly

    -- The thresholds are only the fast path. A long title can fail to fit a slab
    -- wide enough to keep the normal layout, and its LEFT->RIGHT anchors would
    -- ellipsise it -- so MEASURE the text and fall back in the same order the
    -- thresholds do: coords out, then the icon, then the centred overflow title.
    -- The title itself never truncates.
    if b.layoutTitle ~= b.element.title then b.title:SetText(b.element.title) end
    if not titleOnly then
        -- Unbounded = the full text's width even while the FontString is
        -- clipped; guarded for stubs that only have GetStringWidth.
        local titleW
        if b.title.GetUnboundedStringWidth then titleW = b.title:GetUnboundedStringWidth() end
        titleW = titleW or b.title:GetStringWidth() or 0
        local function avail()
            local left = EDGE_W + INSET + DOT + ITEM
            if showIcon then left = left + ICON_SZ + ITEM end
            local right = INSET
            if showCoords then right = right + (b.coords:GetStringWidth() or 0) + ITEM end
            if showLink then right = right + LINK_SZ + ITEM end
            return w - left - right
        end
        if titleW > avail() then showCoords = false end
        if titleW > avail() then showIcon = false end
        if titleW > avail() then titleOnly, showIcon, showCoords, showLink = true, false, false, false end
    end

    -- Dragging re-runs this for EVERY proxy on every frame (RefreshAll ->
    -- Refresh -> Highlight), so the anchors and the SetText only get touched
    -- when the answer actually changed. Which parts are visible, plus the
    -- title, is the whole of the layout's input.
    local key = (titleOnly and 1 or 0) + (showIcon and 2 or 0)
              + (showCoords and 4 or 0) + (showLink and 8 or 0)
    if b.layoutKey == key and b.layoutTitle == b.element.title then return end
    b.layoutKey, b.layoutTitle = key, b.element.title

    b.icon:SetShown(showIcon)
    b.coords:SetShown(showCoords)
    b.link:SetShown(showLink)

    -- Anchored whether or not they are shown: a region with no points is a
    -- region nothing else can anchor OFF, and the title does exactly that.
    b.icon:ClearAllPoints()
    b.icon:SetPoint("LEFT", b.dot, "RIGHT", ITEM, 0)
    b.link:ClearAllPoints()
    if showCoords then b.link:SetPoint("RIGHT", b.coords, "LEFT", -ITEM, 0)
    else               b.link:SetPoint("RIGHT", b, "RIGHT", -INSET, 0) end

    b.title:ClearAllPoints()
    b.title:SetPoint("LEFT", showIcon and b.icon or b.dot, "RIGHT", ITEM, 0)
    if showLink then        b.title:SetPoint("RIGHT", b.link, "LEFT", -ITEM, 0)
    elseif showCoords then  b.title:SetPoint("RIGHT", b.coords, "LEFT", -ITEM, 0)
    else                    b.title:SetPoint("RIGHT", b, "RIGHT", -INSET, 0) end
    -- Small slabs: the full title, centred and allowed to overflow the slab --
    -- never truncated (an outlined font stays readable over the world).
    if titleOnly then
        -- Too narrow for an in-slab title: float it in a pill BELOW the slab so
        -- the dot, edge and logo stay visible and the text sits on its own dark
        -- background instead of over the world or the frame's contents.
        b.title:ClearAllPoints()
        b.title:SetPoint("TOP", b, "BOTTOM", 0, -(TAG_PAD + 2))
        b.tagBg:ClearAllPoints()
        b.tagBg:SetPoint("TOPLEFT", b.title, "TOPLEFT", -TAG_PAD, TAG_PAD)
        b.tagBg:SetPoint("BOTTOMRIGHT", b.title, "BOTTOMRIGHT", TAG_PAD, -TAG_PAD)
        b.titleFloating = true
    else
        b.titleFloating = false
        b.tagShown = nil
        -- A pill fade may still be running from the floating state; cancel it
        -- so its "hide when done" cannot swallow the in-slab title.
        NS.Fx.Cancel(b.title)
        NS.Fx.Cancel(b.tagBg)
        b.tagBg:Hide()
        b.title:Show()
    end
end

-- Everything about how one slab READS: role colour, markers, selection and hover
-- chrome, and the layout that follows from its size. One function, so no state
-- change can repaint half a slab and leave the other half saying something else.
local function applyLook(b, selected, hovered)
    local pos = Registry:GetPos(b.element)
    -- Children() is alias-aware, so a target that resolves to this element's
    -- frame counts too.
    local isRoot = #Registry:Children(b.element.id) > 0
    local c = pos.anchor and C_ANCHORED or (isRoot and C_ROOT or C_FREE)
    b.edge:SetColorTexture(c.r, c.g, c.b, 1)
    b.dot:SetVertexColor(c.r, c.g, c.b)
    -- The ring marks the one case the dot cannot: a root that is ITSELF anchored,
    -- whose dot is already wearing the anchored purple.
    b.root:SetShown(isRoot and pos.anchor ~= nil)
    layout(b, pos.anchor ~= nil)

    -- A floating title is on-demand chrome: shown only while this slab is the
    -- one being looked at or moved, so stacked anchors do not pile pills on
    -- top of each other. The tooltip still names an idle slab on hover.
    if b.titleFloating then
        local showTag = (selected or hovered or b.dragging) and true or false
        -- Fade rather than pop, but only on the transition: applyLook runs
        -- every frame of a drag and must not restart the animation.
        if b.tagShown ~= showTag then
            b.tagShown = showTag
            if showTag then
                NS.Fx.FadeIn(b.title, 0.1)
                NS.Fx.FadeIn(b.tagBg, 0.1)
            else
                NS.Fx.FadeOut(b.title, 0.1, function() b.title:Hide() end)
                NS.Fx.FadeOut(b.tagBg, 0.1, function() b.tagBg:Hide() end)
            end
        end
    end
    b:SetBackdropColor(C_BODY.r, C_BODY.g, C_BODY.b, hovered and HOVER_ALPHA or BODY_ALPHA)
    -- Selection is the OUTLINE, never the fill or the role colour: white and
    -- twice as thick. Hover is a softer white at the same weight, and it stands
    -- down for the selected proxy so hovering cannot make it look less selected.
    local weight = selected and SEL_WEIGHT or WEIGHT
    local r, g, bl, a = C_OUTLINE.r, C_OUTLINE.g, C_OUTLINE.b, 1
    if selected then r, g, bl, a = 1, 1, 1, 1
    elseif hovered then r, g, bl, a = 1, 1, 1, 0.6 end
    -- Weight is baked into the border textures, so it only re-lays out when the
    -- thickness actually changes; a recolour goes through the cheap shim.
    if b.outlineWeight ~= weight then
        UI:ApplyPixelBorder(b, { r, g, bl, a }, weight)
        b.outlineWeight = weight
    else
        b:SetBackdropBorderColor(r, g, bl, a)
    end
end

local function create(el)
    local b = CreateFrame("Button", nil, P:GetUnlockFrame(), "BackdropTemplate")
    -- A solid dark slab with a neutral hairline. The role is carried by the dot
    -- and the left edge ONLY, so the outline is free to mean "selected" and the
    -- body is free to stay readable behind whatever the proxy is sitting on.
    UI:CreateElementBackdrop(b, {
        bgColor     = { C_BODY.r, C_BODY.g, C_BODY.b, BODY_ALPHA },
        borderColor = { C_OUTLINE.r, C_OUTLINE.g, C_OUTLINE.b, 1 },
    })
    b.outlineWeight = WEIGHT
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(false)
    b:SetClampedToScreen(false)

    -- Role edge: full height, flush left, and UNDER the pixel border (which draws
    -- at ARTWORK sublevel 7) so the selection outline always reads over it.
    b.edge = b:CreateTexture(nil, "ARTWORK", nil, 6)
    b.edge:SetWidth(EDGE_W)
    b.edge:SetPoint("TOPLEFT"); b.edge:SetPoint("BOTTOMLEFT")

    -- Role dot, with the root ring behind it: the same circle one pixel larger
    -- all round, so what shows is a 1px rim.
    b.root = b:CreateTexture(nil, "OVERLAY", nil, 1)
    b.root:SetTexture(DOT_ICON); b.root:SetSize(DOT_RING, DOT_RING)
    b.root:SetVertexColor(C_ROOT.r, C_ROOT.g, C_ROOT.b); b.root:Hide()
    b.dot = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.dot:SetTexture(DOT_ICON); b.dot:SetSize(DOT, DOT)
    b.dot:SetPoint("LEFT", b, "LEFT", EDGE_W + INSET, 0)
    b.root:SetPoint("CENTER", b.dot, "CENTER")

    -- Owning addon's icon; falls back to the DF icon bundled with the lib.
    b.icon = b:CreateTexture(nil, "OVERLAY")
    b.icon:SetSize(ICON_SZ, ICON_SZ)
    local addon = Registry:GetAddon(el.addon)
    if b.icon:SetTexture(addon and addon.icon or DEFAULT_ICON) == false then b.icon:SetTexture(DEFAULT_ICON) end

    b.title = UI:CreateLabel(b, { text = el.title, font = "DFFontNormal", color = UI.Colors.text })
    -- Pill behind the title when it floats below a too-narrow slab.
    b.tagBg = b:CreateTexture(nil, "BACKGROUND")
    b.tagBg:SetColorTexture(C_BODY.r, C_BODY.g, C_BODY.b, 0.92)
    b.tagBg:Hide()
    b.title:SetWordWrap(false)
    b.coords = UI:CreateLabel(b, { size = 9, color = C_MUTED, justify = "RIGHT" })
    b.coords:SetPoint("RIGHT", b, "RIGHT", -INSET, 0)

    -- Link glyph while anchored; sits just before the coords.
    b.link = b:CreateTexture(nil, "OVERLAY")
    b.link:SetTexture(LINK_ICON); b.link:SetSize(LINK_SZ, LINK_SZ)
    b.link:SetVertexColor(C_ANCHORED.r, C_ANCHORED.g, C_ANCHORED.b); b.link:Hide()

    -- Centre crosshair, quiet enough that it marks the centre without competing
    -- with the content beside it.
    b.crossH = b:CreateTexture(nil, "OVERLAY"); b.crossH:SetColorTexture(1, 1, 1, 0.25); b.crossH:SetSize(16, 1); b.crossH:SetPoint("CENTER")
    b.crossV = b:CreateTexture(nil, "OVERLAY"); b.crossV:SetColorTexture(1, 1, 1, 0.25); b.crossV:SetSize(1, 16); b.crossV:SetPoint("CENTER")
    b:SetScript("OnDragStart", onDragStart)
    b:SetScript("OnDragStop", onDragStop)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(s)
        s.hovered = true
        applyLook(s, NS.Session and NS.Session.selected == s.element.id, true)
        P:ShowTooltip(s)
    end)
    b:SetScript("OnLeave", function(s)
        s.hovered = false
        P:Highlight(NS.Session and NS.Session.selected)
        GameTooltip:Hide()
    end)
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
    -- A mover whose element is not on screen has no meaningful position to
    -- report, so the coords slot says so instead of quoting a stale number.
    -- Availability, not the raw frame's IsShown: a consumer getRect owns the
    -- "is it visible" question (Registry:IsTargetAvailable), and DF's raid
    -- container is hidden behind its test-mode preview during every mover
    -- session -- the visible thing is the test container its getRect measures.
    -- Elements without getRect still fall back to the frame's shown state.
    local shown = Registry:IsTargetAvailable(el)
    -- Hidden frames keep a full-strength slab; the muted "hidden" word carries
    -- the state on its own.
    b.coords:SetText(shown and format("%d, %d", cx, cy) or L["hidden"])
    self:Highlight(NS.Session and NS.Session.selected)
end

function P:RefreshAll() for id in pairs(self.proxies) do self:Refresh(id) end end

function P:Highlight(selectedId)
    for id, b in pairs(self.proxies) do
        applyLook(b, id == selectedId, b.hovered)
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
-- Docked top-centre for the session: what the three proxy DOTS mean plus the
-- modifier hints. Same dot art and same slab as the proxies themselves, so the
-- key and the thing it is a key to cannot drift apart. Parented to the unlock
-- frame, so suspend and lock hide it with everything else.
-- ============================================================
local function buildLegend()
    local f = CreateFrame("Frame", "DandersMoverLegend", P:GetUnlockFrame(), "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    UI:CreateElementBackdrop(f, {
        bgColor     = { C_BODY.r, C_BODY.g, C_BODY.b, BODY_ALPHA },
        borderColor = { C_OUTLINE.r, C_OUTLINE.g, C_OUTLINE.b, 1 },
    })
    f:SetPoint("TOP", UIParent, "TOP", 0, -PAD)

    local function entry(prev, color, text)
        local swatch = f:CreateTexture(nil, "OVERLAY")
        swatch:SetSize(DOT, DOT)
        swatch:SetTexture(DOT_ICON)
        swatch:SetVertexColor(color.r, color.g, color.b)
        local label = UI:CreateLabel(f, { text = text, size = 11 })
        if prev then swatch:SetPoint("LEFT", prev, "RIGHT", GAP, 0)
        else         swatch:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD - 1) end
        label:SetPoint("LEFT", swatch, "RIGHT", TIGHT - 2, 0)
        return label
    end
    f.entries = {}
    f.entries[1] = entry(nil,          C_FREE,     L["Free"])
    f.entries[2] = entry(f.entries[1], C_ANCHORED, L["Anchored"])
    f.entries[3] = entry(f.entries[2], C_ROOT,     L["Anchor root"])

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
            row = row + DOT + TIGHT - 2 + (label:GetStringWidth() or 0) + (i < #self.entries and GAP or 0)
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
    self:ResetLegendDodge()
    f:Show()
end

function P:HideLegend()
    if self.legend then self.legend:Hide() end
end

-- ------------------------------------------------------------
-- The legend dodges the drag: when the dragged slab or the cursor comes within
-- DODGE_MARGIN of it, it slides off the top edge, and slides back once clear.
-- An OnUpdate lerp rather than a Translation: the strip must keep its REAL
-- position while visible (it holds a live checkbox), and a Translation only
-- displaces the rendering.
-- ------------------------------------------------------------
local DODGE_MARGIN = 60
local DODGE_TIME = 0.15

-- t: 0 = home (top-centre), 1 = fully off the top edge.
local function legendApply(f, t)
    local h = f:GetHeight() or 0
    f:ClearAllPoints()
    f:SetPoint("TOP", UIParent, "TOP", 0, -PAD + t * (h + PAD + 4))
end

local function legendSlide(f, up)
    up = up and true or false
    if f.dodgeUp == up then return end
    f.dodgeUp = up
    f:SetScript("OnUpdate", function(s, elapsed)
        local target = s.dodgeUp and 1 or 0
        local t = s.dodgeT or 0
        local step = (elapsed or 0) / DODGE_TIME
        if target > t then t = math.min(target, t + step) else t = math.max(target, t - step) end
        s.dodgeT = t
        legendApply(s, t)
        if t == target then s:SetScript("OnUpdate", nil) end
    end)
end

-- Called every drag frame with the dragged slab's centre rect.
function P:UpdateLegendDodge(cx, cy, w, h)
    local f = self.legend
    if not f or not f:IsShown() then return end
    -- Proximity is measured against the legend's HOME rect (t = 0), not where
    -- the slide has taken it -- measuring the dodged position would read
    -- "clear" at once and bounce the strip straight back onto the drag.
    local lh = f:GetHeight() or 0
    local home = {
        x = 0,
        y = (UIParent:GetHeight() or 0) / 2 - PAD - lh / 2,
        w = (f:GetWidth() or 0) + DODGE_MARGIN * 2,
        h = lh + DODGE_MARGIN * 2,
    }
    local mx, my = self:CursorPos()
    local near = Solver.RectOverlapArea(home, { x = cx, y = cy, w = w, h = h }) > 0
        or (mx > home.x - home.w / 2 and mx < home.x + home.w / 2
            and my > home.y - home.h / 2 and my < home.y + home.h / 2)
    legendSlide(f, near)
end

function P:ClearLegendDodge()
    if self.legend then legendSlide(self.legend, false) end
end

-- Snap the legend back to its home instantly (fresh session / re-show).
function P:ResetLegendDodge()
    local f = self.legend
    if not f then return end
    f:SetScript("OnUpdate", nil)
    f.dodgeUp, f.dodgeT = false, 0
    legendApply(f, 0)
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
        z.weight = ZONE_WEIGHT
        -- Dashed edges: 8x8 tiles (5-on/3-off dash in a 2px strip) tiled along
        -- each edge with REPEAT wrap. Two pre-rotated tiles rather than
        -- SetTexCoord rotation, which tiled textures do not honour reliably.
        z.dashes = {}
        local function edge(p1, p2, horizontal)
            local t = z:CreateTexture(nil, "OVERLAY")
            t:SetTexture(horizontal and DASH_H or DASH_V, "REPEAT", "REPEAT")
            if horizontal then t:SetHeight(ZONE_DASH_W); t:SetHorizTile(true)
            else               t:SetWidth(ZONE_DASH_W);  t:SetVertTile(true) end
            t:SetPoint(p1); t:SetPoint(p2)
            z.dashes[#z.dashes + 1] = t
        end
        edge("TOPLEFT", "TOPRIGHT", true)
        edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
        edge("TOPLEFT", "BOTTOMLEFT", false)
        edge("TOPRIGHT", "BOTTOMRIGHT", false)
        P.zones[i] = z
    end
    return z
end

-- One zone's whole look: fill, outline (colour AND thickness) and the corner
-- ticks, which always match the outline. Called for every live zone on every
-- frame of a drag, so the weight is only re-laid out when it actually changes;
-- a recolour goes through the pixel border's cheap shim.
local function paintZone(z, fill, fillAlpha, line, lineAlpha, weight)
    -- The dashes ARE the outline; the backdrop border stays off so the slot
    -- reads dashed, exactly like the approved mock. `weight` is kept in the
    -- signature for call-site stability but no longer drawn.
    z:SetBackdropColor(fill.r, fill.g, fill.b, fillAlpha)
    z:SetBackdropBorderColor(0, 0, 0, 0)
    for _, d in ipairs(z.dashes) do d:SetVertexColor(line.r, line.g, line.b, lineAlpha) end
end

local function clearZone(z)
    paintZone(z, C_ZONE, 0, C_ZONE, 0, ZONE_WEIGHT)
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
                clearZone(zf)
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
    -- Zones appear within zoneShowDistance (never less than the snap distance),
    -- so the user sees where a drop would land before it actually grabs.
    local snapR = (NS.db and NS.db.snapDistance) or PROXIMITY
    local radius = math.max(snapR, (NS.db and NS.db.zoneShowDistance) or snapR)
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
            -- The zone that WILL take the drop: accent fill, white outline, the
            -- same 2px the selected proxy wears.
            paintZone(zf, C_ZONE, 0.55, C_ZONE_HOVER, 1, ZONE_HOVER_WEIGHT)
        elseif closest and z.target == closest and sqrt((cx - z.x) ^ 2 + (cy - z.y) ^ 2) < radius then
            local d = sqrt((cx - z.x) ^ 2 + (cy - z.y) ^ 2)
            local f = 0.2 + Solver.ProximityFactor(d, radius) * 0.8
            -- Occupied zones read quieter (CDM rule) -- here that is the lower
            -- pair of alphas rather than an extra factor on top of the accent's.
            if z.occupied then paintZone(zf, C_ZONE_OCCUPIED, 0.10 * f, C_ZONE_OCCUPIED, 0.6 * f, ZONE_WEIGHT)
            else               paintZone(zf, C_ZONE, 0.28 * f, C_ZONE, f, ZONE_WEIGHT) end
        else
            clearZone(zf)
        end
    end
end

function P:HideZones()
    for i = 1, #self.zones do self.zones[i]:Hide() end
    self.zoneCount = 0
    wipe(self.dragZones)
end
