local addonName, NS = ...

-- ============================================================
-- PROXIES
-- One plain Button per movable element, parented to the unlock frame.
-- The proxy is what the user drags; the real frame only ever moves through
-- the consumer's onChanged. Also owns the snap-zone visual pool.
-- ============================================================
local P = { proxies = {}, zones = {}, zoneCount = 0, dragZones = {}, tethers = {}, tetherCount = 0 }
NS.Proxy = P

local Registry, Solver, UI, L = NS.Registry, NS.Solver, NS.UI, NS.L
local CreateFrame, UIParent, GetCursorPosition, GameTooltip, C_Timer, GetTime = CreateFrame, UIParent, GetCursorPosition, GameTooltip, C_Timer, GetTime
local IsShiftKeyDown, IsControlKeyDown, IsAltKeyDown = IsShiftKeyDown, IsControlKeyDown, IsAltKeyDown
local pairs, ipairs, format, sqrt, max, abs, tsort = pairs, ipairs, string.format, math.sqrt, math.max, math.abs, table.sort

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
-- the coords first, then the role DOT -- the addon icon wins the space (the
-- left edge already carries the role colour) -- then everything but the
-- floating title. The icon itself never drops.
local NO_COORDS_H, NO_COORDS_W, NO_DOT_W, TITLE_ONLY_W = 28, 120, 80, 60
-- Snap zones. Same accent as the free-role dot, because a zone IS where a free
-- drop would land; occupied ones go red. Hover is the only place a zone borrows
-- the selection white, and the kit has no white token, so that one is a literal.
local C_ZONE = UI.Colors.accent
local C_ZONE_OCCUPIED = UI.Colors.danger
local C_ZONE_HOVER = { r = 1, g = 1, b = 1 }
local ZONE_WEIGHT, ZONE_HOVER_WEIGHT = 1, 2
local TAG_PAD = 3                        -- padding of the floating title pill
-- Session-open entrance: each slab fades in over FADE_IN with STAGGER between
-- slabs in build order. Lock/save/discard fades the whole overlay out over
-- FADE_OUT and only then tears it down (DismissAll). Combat suspend stays
-- instant -- Session:Suspend hides the unlock frame directly.
local FADE_IN, FADE_OUT, STAGGER = 0.25, 0.2, 0.035
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
    -- The overlay owns clicks on empty space: left deselects. Proxies, panel
    -- and legend are children at higher frame levels, so they keep taking
    -- their own clicks first. While a session is open the overlay therefore
    -- captures the mouse and the world behind it is unreachable -- documented
    -- in the README; locking (Esc, the strip, /mover) gives the screen back.
    f:EnableMouse(true)
    f:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then P:ClickSelect() end
    end)
    -- Alt-peek. The event is only registered while a session is up (Build /
    -- DestroyAll), so this cannot fire outside one.
    f:SetScript("OnEvent", function(_, _, key)
        if key == "LALT" or key == "RALT" then P:SetPeek(IsAltKeyDown()) end
    end)
    f:Hide()
    self.unlockFrame = f
    return f
end

-- Hold Alt to peek at the UI underneath: everything the session put on screen
-- (slabs, strip and panel are all children of the unlock frame) drops to
-- PEEK_ALPHA while Alt is held; release restores. Ignored while a drag is in
-- flight -- the drag is the one thing that must stay fully visible.
local PEEK_ALPHA = 0.1

function P:SetPeek(on)
    on = on and true or false
    if on then
        for _, b in pairs(self.proxies) do if b.dragging then return end end
    end
    if self.peeking == on then return end
    self.peeking = on
    NS.Fx.FadeTo(self:GetUnlockFrame(), on and PEEK_ALPHA or 1, 0.1)
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
        -- Brighten the centre line of the axis the drag is locked TO.
        NS.Grid:SetAxisLock(shift and not ctrl, ctrl and not shift)
        local fx, fy, zone = NS.Session:DragTo(el, nx, ny)
        s:ClearAllPoints(); s:SetPoint("CENTER", UIParent, "CENTER", fx, fy)
        s.coords:SetText(format("%d, %d", fx, fy))
        P:UpdateZones(fx, fy, zone)
        P:UpdateLegendDodge(fx, fy, s:GetWidth() or 0, s:GetHeight() or 0)
        -- After the SetPoint above, so the tether's slab endpoint has no
        -- one-frame lag behind the cursor.
        P:UpdateTethers()
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
    NS.Grid:HideMeasure()
    NS.Grid:SetAxisLock(false, false)
    NS.Session:EndDrag(self.element, self.lastX, self.lastY, self.lastZone)
end

-- Both the proxies' own clicks and the overlay's empty-space clicks route
-- through ClickSelect, so a click on a stack of overlapping proxies can cycle
-- through them even though the top proxy is the one that took the click.
local function onClick(self)
    P:ClickSelect()
end

-- ============================================================
-- OVERLAP CYCLING
-- The first click on a point selects the topmost proxy under it; clicking
-- again at (about) the same point cycles to the next one down, wrapping
-- around. The cycle resets when the click lands more than CYCLE_MOVE from the
-- last one or after CYCLE_TIMEOUT seconds. A click over nothing deselects.
-- ============================================================
local CYCLE_MOVE, CYCLE_TIMEOUT = 10, 2
local cycle = { x = nil, y = nil, at = 0, index = 0 }

-- Every shown proxy whose rect covers (x, y), topmost first: higher frame
-- level wins, ties go to the later-created button (which renders on top).
local function hitsAt(x, y)
    local out = {}
    local ux, uy = UIParent:GetCenter()
    for _, b in pairs(P.proxies) do
        if b:IsShown() then
            local cx, cy = b:GetCenter()
            if cx then
                cx, cy = cx - ux, cy - uy
                local hw, hh = (b:GetWidth() or 0) / 2, (b:GetHeight() or 0) / 2
                if x >= cx - hw and x <= cx + hw and y >= cy - hh and y <= cy + hh then
                    out[#out + 1] = b
                end
            end
        end
    end
    tsort(out, function(a, b)
        local la, lb = a:GetFrameLevel() or 0, b:GetFrameLevel() or 0
        if la ~= lb then return la > lb end
        return (a.createIndex or 0) > (b.createIndex or 0)
    end)
    return out
end

function P:ClickSelect()
    local x, y = self:CursorPos()
    local hits = hitsAt(x, y)
    if #hits == 0 then NS.Session:Select(nil) return end
    local now = GetTime and GetTime() or 0
    local same = cycle.x ~= nil
        and abs(x - cycle.x) <= CYCLE_MOVE and abs(y - cycle.y) <= CYCLE_MOVE
        and (now - cycle.at) <= CYCLE_TIMEOUT
    if same then cycle.index = cycle.index % #hits + 1 else cycle.index = 1 end
    cycle.x, cycle.y, cycle.at = x, y, now
    NS.Session:Select(hits[cycle.index].element.id)
end


-- Lay the slab's contents out for its CURRENT size. A proxy is exactly as big as
-- the frame it stands in for, so one 24px icon mover and one full raid container
-- come through here: parts drop out as the room runs out rather than overlapping.
local function layout(b, anchored)
    local w = b:GetWidth() or 0
    local h = b:GetHeight() or 0
    local titleOnly = w < TITLE_ONLY_W
    local showDot = not titleOnly and w >= NO_DOT_W
    local showCoords = not titleOnly and w >= NO_COORDS_W and h >= NO_COORDS_H
    local showLink = anchored and not titleOnly

    -- The thresholds are only the fast path. A long title can fail to fit a slab
    -- wide enough to keep the normal layout, and its LEFT->RIGHT anchors would
    -- ellipsise it -- so MEASURE the text and fall back in the same order the
    -- thresholds do: coords out, then the dot, then the centred overflow title.
    -- The title itself never truncates, and the icon never drops.
    if b.layoutTitle ~= b.element.title then b.title:SetText(b.element.title) end
    if not titleOnly then
        -- Unbounded = the full text's width even while the FontString is
        -- clipped; guarded for stubs that only have GetStringWidth.
        local titleW
        if b.title.GetUnboundedStringWidth then titleW = b.title:GetUnboundedStringWidth() end
        titleW = titleW or b.title:GetStringWidth() or 0
        local function avail()
            local left = EDGE_W + INSET + ICON_SZ + ITEM
            if showDot then left = left + DOT + ITEM end
            local right = INSET
            if showCoords then right = right + (b.coords:GetStringWidth() or 0) + ITEM end
            if showLink then right = right + LINK_SZ + ITEM end
            return w - left - right
        end
        if titleW > avail() then showCoords = false end
        if titleW > avail() then showDot = false end
        if titleW > avail() then titleOnly, showDot, showCoords, showLink = true, false, false, false end
    end

    -- Dragging re-runs this for EVERY proxy on every frame (RefreshAll ->
    -- Refresh -> Highlight), so the anchors and the SetText only get touched
    -- when the answer actually changed. Which parts are visible, plus the
    -- title, is the whole of the layout's input.
    local key = (titleOnly and 1 or 0) + (showDot and 2 or 0)
              + (showCoords and 4 or 0) + (showLink and 8 or 0)
    b.showDot = showDot           -- applyLook's ring placement reads this
    if b.layoutKey == key and b.layoutTitle == b.element.title then return end
    b.layoutKey, b.layoutTitle = key, b.element.title

    b.icon:Show()                 -- explicit for pooled reuse and stubs
    b.dot:SetShown(showDot)
    b.coords:SetShown(showCoords)
    b.link:SetShown(showLink)

    -- Anchored whether or not they are shown: a region with no points is a
    -- region nothing else can anchor OFF, and the title does exactly that.
    -- With the dot dropped the icon takes its place flush left, and the root
    -- ring re-homes onto whichever of the two is the leftmost marker.
    b.icon:ClearAllPoints()
    if showDot then b.icon:SetPoint("LEFT", b.dot, "RIGHT", ITEM, 0)
    else            b.icon:SetPoint("LEFT", b, "LEFT", EDGE_W + INSET, 0) end
    b.root:ClearAllPoints()
    if showDot then
        b.root:SetPoint("CENTER", b.dot, "CENTER")
        b.root:SetSize(DOT_RING, DOT_RING)
    else
        b.root:SetPoint("CENTER", b.icon, "CENTER")
        b.root:SetSize(ICON_SZ + 4, ICON_SZ + 4)
    end
    b.link:ClearAllPoints()
    if showCoords then b.link:SetPoint("RIGHT", b.coords, "LEFT", -ITEM, 0)
    else               b.link:SetPoint("RIGHT", b, "RIGHT", -INSET, 0) end

    b.title:ClearAllPoints()
    b.title:SetPoint("LEFT", b.icon, "RIGHT", ITEM, 0)
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
    layout(b, pos.anchor ~= nil)
    -- With the dot on show, the ring marks the one case the dot cannot: a root
    -- that is ITSELF anchored, whose dot is already wearing the anchored
    -- purple. On a slab too narrow for the dot the ICON carries the ring for
    -- EVERY root, or the root state would vanish with the dot (layout homes
    -- the ring on whichever marker is showing).
    local ringOn
    if b.showDot then ringOn = isRoot and pos.anchor ~= nil
    else ringOn = isRoot end
    b.root:SetShown(ringOn and true or false)

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
    b:RegisterForClicks("LeftButtonUp")
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
    -- Sublevel 2 (like the dot) so the root ring at sublevel 1 sits BEHIND it
    -- when a narrow slab homes the ring on the icon instead of the dot.
    b.icon = b:CreateTexture(nil, "OVERLAY", nil, 2)
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
    -- Creation order breaks z-ties in the overlap cycle: at equal frame level
    -- the later-created button renders on top.
    P.createCounter = (P.createCounter or 0) + 1
    b.createIndex = P.createCounter
    return b
end

-- filter is the NORMALISED session filter (Session.filter): nil, or
-- { addon = <string|nil>, keySet = <set|nil> }. The initiator's keys outside keySet
-- get NO proxy at all, not a dimmed one (a party unlock must not put raid proxies on
-- screen); other addons' elements get one only with showOtherAddons (Registry:WantsProxy).
-- animate: session open only -- slabs fade in with a small stagger in build
-- order. Rebuilds mid-session come through without it and stay instant.
function P:Build(filter, animate)
    local f = self:GetUnlockFrame()
    -- A lock's dismiss fade may still be running (lock -> unlock inside FADE_OUT):
    -- invalidate its deferred teardown and restore the frame it was fading.
    self.dismissToken = (self.dismissToken or 0) + 1
    NS.Fx.Cancel(f)
    f:EnableMouse(true)
    self.peeking = false          -- Cancel above restored alpha 1
    if f.RegisterEvent then f:RegisterEvent("MODIFIER_STATE_CHANGED") end
    local n = 0
    for _, el in ipairs(Registry:SortedElements()) do
        if Registry:WantsProxy(filter, el) then
            local frame = Registry:GetFrame(el)
            if NS.db.showHiddenMovers or (frame and frame:IsShown()) then
                local b = self.proxies[el.id] or create(el)
                b.element = el
                self.proxies[el.id] = b
                self:Refresh(el.id)
                b:Show()
                if animate and C_Timer then
                    n = n + 1
                    b:SetAlpha(0)
                    local id = el.id
                    C_Timer.After((n - 1) * STAGGER, function()
                        -- The pool can be torn down and rebuilt while this
                        -- timer is pending; only fade the exact button that is
                        -- still the live proxy for the id.
                        if self.proxies[id] == b and b:IsShown() then
                            NS.Fx.FadeIn(b, FADE_IN)
                        end
                    end)
                else
                    -- A rebuild can reuse a slab whose entrance was interrupted
                    -- mid-fade; make sure it rests at full alpha.
                    NS.Fx.Cancel(b)
                end
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
    self:UpdateTethers()
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
    if self.unlockFrame then
        if self.unlockFrame.UnregisterEvent then self.unlockFrame:UnregisterEvent("MODIFIER_STATE_CHANGED") end
        self.peeking = false
        self.unlockFrame:SetAlpha(1)
        self.unlockFrame:Hide()
    end
    self:HideZones()
    self:HideTethers()
    self:HideLegend()
    if self.toast then NS.Fx.Cancel(self.toast); self.toast:Hide() end
end

-- Lock/save/discard: fade the whole overlay (slabs, legend, panel) out, then
-- destroy. The token guards the deferred teardown -- a new session can open
-- before the fade lands, and its freshly built proxies must not be destroyed
-- by the previous session's callback (Build bumps the token and cancels the
-- fade). Mouse goes off immediately so the screen is usable during the fade.
function P:DismissAll()
    local f = self.unlockFrame
    if not f or not f:IsShown() then self:DestroyAll() return end
    local token = (self.dismissToken or 0) + 1
    self.dismissToken = token
    f:EnableMouse(false)
    self.peeking = false          -- the fade below plays from full alpha
    NS.Fx.FadeOut(f, FADE_OUT, function()
        if self.dismissToken == token and not (NS.Session and NS.Session:IsActive()) then
            self:DestroyAll()
        end
    end)
end

-- ============================================================
-- ANCHOR TETHER
-- A thin line from an anchored slab's centre to the nearest point on its
-- anchor target's rect (the centre when the slab sits inside it). Shown while
-- the slab is selected, hovered or being dragged; hovering also lights the
-- whole chain -- the hovered slab's parent link AND every child's link
-- (alias-aware via Registry:Children). Subtle lavender at rest; the dragged
-- slab's tether lerps to the danger red and thins as it strains
-- (Session.tether), and flashes once when it snaps.
--
-- Drawn with Line objects (frame:CreateLine), not a rotated texture:
-- TextureBase:SetRotation rotates the texture inside its axis-aligned quad,
-- so a long thin quad cannot draw a diagonal.
-- ============================================================
local C_TETHER = UI.Colors.accent
local C_TETHER_STRAIN = UI.Colors.danger
local TETHER_W, TETHER_STRAIN_W = 2, 1
local TETHER_ALPHA = 0.7

-- Pooled line on the unlock frame (under the slabs, which are child frames).
-- nil in a headless stub without CreateLine support.
local function tetherLine(pool, i)
    local t = pool[i]
    if t == nil then
        local f = P:GetUnlockFrame()
        t = f.CreateLine and f:CreateLine(nil, "ARTWORK") or false
        pool[i] = t
    end
    return t or nil
end

-- Proxy centre in UIParent-centre units.
local function proxyCenter(b)
    local cx, cy = b:GetCenter()
    if not cx then return nil end
    local ux, uy = UIParent:GetCenter()
    return cx - ux, cy - uy
end

-- Nearest point on a centre-based rect from (cx, cy); the rect's centre when
-- the point lies inside it.
local function nearestOnRect(rect, cx, cy)
    local l, r = rect.x - rect.w / 2, rect.x + rect.w / 2
    local b, t = rect.y - rect.h / 2, rect.y + rect.h / 2
    local px = cx < l and l or (cx > r and r or cx)
    local py = cy < b and b or (cy > t and t or cy)
    if px == cx and py == cy then return rect.x, rect.y end
    return px, py
end

local function lerp(a, b, f) return a + (b - a) * f end

-- Lay one tether for element el / slab b. Returns the new pool watermark.
-- drag is Session.tether: only the slab actually being dragged reads it (the
-- working record's anchor is nil'd during a drag, so the target comes from
-- there), everyone else reads their own record.
local function drawTether(n, el, b, drag)
    local targetId, strain
    if b.dragging then
        if not drag or drag.snapped then return n end   -- snapped: tether gone
        targetId, strain = drag.target, drag.strain or 0
    else
        local a = Registry:GetPos(el).anchor
        if not a then return n end
        targetId, strain = a.target, 0
    end
    local target = Registry:GetTarget(targetId)
    local rect = target and Registry:GetRect(target)
    if not rect then return n end
    local cx, cy = proxyCenter(b)
    if not cx then return n end
    local tx, ty = nearestOnRect(rect, cx, cy)
    local line = tetherLine(P.tethers, n + 1)
    if not line then return n end
    line:SetStartPoint("CENTER", UIParent, cx, cy)
    line:SetEndPoint("CENTER", UIParent, tx, ty)
    line:SetThickness(strain > 0 and TETHER_STRAIN_W or TETHER_W)
    line:SetColorTexture(lerp(C_TETHER.r, C_TETHER_STRAIN.r, strain),
                         lerp(C_TETHER.g, C_TETHER_STRAIN.g, strain),
                         lerp(C_TETHER.b, C_TETHER_STRAIN.b, strain),
                         lerp(TETHER_ALPHA, 1, strain))
    line:Show()
    return n + 1
end

-- Which slabs show their parent tether: the selected one, any hovered one
-- (plus all of the hovered one's children -- the chain highlight), and the
-- one being dragged. Called from Highlight, so every selection/hover change
-- and every drag frame comes through here.
function P:UpdateTethers()
    local sess = NS.Session
    local drag = sess and sess.tether
    local want = {}
    local selected = sess and sess.selected
    if selected and self.proxies[selected] then want[selected] = true end
    for id, b in pairs(self.proxies) do
        if b:IsShown() then
            if b.hovered then
                want[id] = true
                for _, child in ipairs(Registry:Children(id)) do
                    if self.proxies[child.id] then want[child.id] = true end
                end
            end
            if b.dragging then want[id] = true end
        end
    end
    local n = 0
    for id in pairs(want) do
        local el = Registry:Get(id)
        local b = self.proxies[id]
        if el and b and b:IsShown() then n = drawTether(n, el, b, drag) end
    end
    for i = n + 1, #self.tethers do
        local t = self.tethers[i]
        if t then t:Hide() end
    end
    self.tetherCount = n
end

function P:HideTethers()
    for i = 1, #self.tethers do
        local t = self.tethers[i]
        if t then t:Hide() end
    end
    self.tetherCount = 0
    if self.tetherFlash then self.tetherFlash:Hide() end
end

-- The snap moment: paint a dedicated line (the pool relays every frame) full
-- danger red along the breaking tether and let it fade out. UpdateTethers
-- stops drawing the live one from now on (Session.tether.snapped).
function P:SnapTether(el)
    local b = self.proxies[el.id]
    local drag = NS.Session and NS.Session.tether
    if not b or not drag then return end
    local target = Registry:GetTarget(drag.target)
    local rect = target and Registry:GetRect(target)
    local cx, cy = proxyCenter(b)
    if not rect or not cx then return end
    if self.tetherFlash == nil then
        local f = self:GetUnlockFrame()
        self.tetherFlash = f.CreateLine and f:CreateLine(nil, "ARTWORK") or false
    end
    local line = self.tetherFlash
    if not line then return end
    local tx, ty = nearestOnRect(rect, cx, cy)
    NS.Fx.Cancel(line)
    line:SetStartPoint("CENTER", UIParent, cx, cy)
    line:SetEndPoint("CENTER", UIParent, tx, ty)
    line:SetThickness(TETHER_W)
    line:SetColorTexture(C_TETHER_STRAIN.r, C_TETHER_STRAIN.g, C_TETHER_STRAIN.b, 1)
    line:Show()
    NS.Fx.FadeOut(line, 0.25, function() line:Hide() end)
end

-- ============================================================
-- LEGEND / ACTION STRIP
-- Docked top-centre for the session: one compact strip with the dot key on
-- the left and the session verbs (Save & Exit, Discard, Settings, Grid) on
-- the right, plus the modifier hints below -- so the session can be saved or
-- discarded with nothing selected. Same dot art and same slab as the proxies
-- themselves, so the key and the thing it is a key to cannot drift apart.
-- Parented to the unlock frame, so suspend and lock hide it with everything
-- else.
-- ============================================================
local LEGEND_ROW = 18                    -- first row: dots left, buttons right
local function buildLegend()
    local f = CreateFrame("Frame", "DandersMoverLegend", P:GetUnlockFrame(), "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    -- Swallow clicks: the strip is chrome, not empty space -- clicking beside
    -- its checkbox must not fall through to the overlay's deselect.
    f:EnableMouse(true)
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
        else         swatch:SetPoint("LEFT", f, "TOPLEFT", PAD, -PAD - LEGEND_ROW / 2) end
        label:SetPoint("LEFT", swatch, "RIGHT", TIGHT - 2, 0)
        return label
    end
    f.entries = {}
    f.entries[1] = entry(nil,          C_FREE,     L["Free"])
    f.entries[2] = entry(f.entries[1], C_ANCHORED, L["Anchored"])
    f.entries[3] = entry(f.entries[2], C_ROOT,     L["Anchor root"])

    -- Session verbs on the same row, right-aligned: the strip doubles as the
    -- action bar (EUI has a separate one; ours merges into the legend so there
    -- is a single top element). Declared widths are floors -- fitText grows
    -- them for longer localisations, and Layout re-measures.
    f.btnSave = UI:CreateButton(f, { text = L["Save & Exit"], width = 76, height = LEGEND_ROW, style = "primary",
        onClick = function() NS.Session:Finish("save") end })
    f.btnDiscard = UI:CreateButton(f, { text = L["Discard"], width = 56, height = LEGEND_ROW, tone = "danger",
        onClick = function() NS.Session:Finish("discard") end })
    f.btnSettings = UI:CreateButton(f, { text = L["Settings"], width = 56, height = LEGEND_ROW, style = "ghost",
        tooltip = { title = L["Settings"], lines = { L["Snapping, grid and per-addon mover toggles."] } },
        onClick = function() if NS.Settings then NS.Settings:Toggle() end end })
    f.btnGrid = UI:CreateButton(f, { text = L["Grid"], width = 40, height = LEGEND_ROW, style = "ghost",
        tooltip = { title = L["Show grid"] },
        onClick = function()
            NS.db.showGrid = not NS.db.showGrid
            NS.Grid:Refresh()
            f.btnGrid:SetActive(NS.db.showGrid)
            if NS.Settings then NS.Settings:Refresh() end
        end })
    -- Collapse chevron at the strip's right end: the strip folds away to a
    -- slim tab at the top screen edge (state remembered in DandersMoverDB).
    f.btnCollapse = UI:CreateGlyphButton(f, {
        texture = UI.MEDIA .. "Icons\\expand_less", size = LEGEND_ROW, iconSize = 12,
        tooltip = { title = L["Collapse"], lines = { L["Fold the strip away to a small tab at the top of the screen."] } },
        onClick = function() P:SetStripCollapsed(true) end,
    })
    f.btnCollapse:SetPoint("RIGHT", f, "TOPRIGHT", -PAD, -PAD - LEGEND_ROW / 2)
    f.btnGrid:SetPoint("RIGHT", f.btnCollapse, "LEFT", -TIGHT, 0)
    f.btnSettings:SetPoint("RIGHT", f.btnGrid, "LEFT", -TIGHT, 0)
    f.btnDiscard:SetPoint("RIGHT", f.btnSettings, "LEFT", -TIGHT, 0)
    f.btnSave:SetPoint("RIGHT", f.btnDiscard, "LEFT", -TIGHT, 0)

    f.hint = UI:CreateLabel(f, { text = L["Shift: horizontal · Ctrl: vertical · Esc: lock"], size = 10, color = C_MUTED })
    f.hint:SetPoint("TOP", f, "TOP", 0, -PAD - LEGEND_ROW - TIGHT)

    -- Third row, consumer-initiated sessions only: other addons' enabled+relevant
    -- elements are anchor targets already; this also gives them proxies. Same
    -- persisted toggle as Settings > Editor; both rebuild the proxies live.
    f.other = UI:CreateCheckbox(f, {
        label = L["Show other addons' movers"],
        get = function() return NS.db.showOtherAddons end,
        set = function(v) NS.db.showOtherAddons = v and true or false; NS.Session:RebuildProxies() end,
    })
    f.other:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD - LEGEND_ROW - TIGHT - 12 - TIGHT)

    -- Width from the measured text. Fonts resolve a frame late, so this runs
    -- again on the next frame (same converge-next-frame shape as the kit's
    -- own labels).
    function f:Layout()
        local row = PAD
        for i, label in ipairs(self.entries) do
            row = row + DOT + TIGHT - 2 + (label:GetStringWidth() or 0) + (i < #self.entries and GAP or 0)
        end
        -- Dots left, buttons right, a double gap between the halves so the
        -- strip reads as key | verbs and not one run.
        row = row + GAP * 2
        for _, b in ipairs({ self.btnSave, self.btnDiscard, self.btnSettings, self.btnGrid, self.btnCollapse }) do
            row = row + (b:GetWidth() or 0) + TIGHT
        end
        row = row - TIGHT + PAD
        self.btnGrid:SetActive(NS.db.showGrid and true or false)
        local hintW = (self.hint:GetStringWidth() or 0) + PAD * 2
        -- The checkbox row only exists for a consumer-initiated session (a filter
        -- with an addon); /mover has no "other" addons.
        local filter = NS.Session and NS.Session.filter
        local showOther = (filter and filter.addon) and true or false
        self.other:SetShown(showOther)
        self.other:Refresh()
        local h = PAD + LEGEND_ROW + TIGHT + 12 + PAD
        if showOther then
            self.other:SetWidth(max(row, hintW) - PAD * 2)
            h = h + TIGHT + UI.RowHeight.checkbox - GAP
        end
        self:SetSize(max(row, hintW), h)
    end
    return f
end

-- The collapsed strip: a slim tab hugging the top screen edge. Clicking it
-- brings the full strip back.
local function buildStripTab()
    local t = CreateFrame("Button", "DandersMoverLegendTab", P:GetUnlockFrame(), "BackdropTemplate")
    t:SetFrameStrata("DIALOG")
    t:SetSize(44, 14)
    t:SetPoint("TOP", UIParent, "TOP", 0, 0)
    UI:CreateElementBackdrop(t, {
        bgColor     = { C_BODY.r, C_BODY.g, C_BODY.b, BODY_ALPHA },
        borderColor = { C_OUTLINE.r, C_OUTLINE.g, C_OUTLINE.b, 1 },
    })
    t.icon = t:CreateTexture(nil, "OVERLAY")
    t.icon:SetTexture(UI.MEDIA .. "Icons\\expand_more")
    t.icon:SetSize(12, 12)
    t.icon:SetPoint("CENTER")
    t.icon:SetVertexColor(C_MUTED.r, C_MUTED.g, C_MUTED.b)
    t:SetScript("OnEnter", function(s) s.icon:SetVertexColor(1, 1, 1) end)
    t:SetScript("OnLeave", function(s) s.icon:SetVertexColor(C_MUTED.r, C_MUTED.g, C_MUTED.b) end)
    t:SetScript("OnClick", function() P:SetStripCollapsed(false) end)
    return t
end

function P:SetStripCollapsed(collapsed)
    NS.db.stripCollapsed = collapsed and true or false
    self:ShowLegend()
end

function P:ShowLegend()
    if not self.legend then self.legend = buildLegend() end
    if not self.stripTab then self.stripTab = buildStripTab() end
    if NS.db.stripCollapsed then
        self.legend:Hide()
        self.stripTab:Show()
        return
    end
    self.stripTab:Hide()
    local f = self.legend
    f:Layout()
    if C_Timer then C_Timer.After(0, function() if f:IsShown() then f:Layout() end end) end
    self:ResetLegendDodge()
    f:Show()
end

function P:HideLegend()
    if self.legend then self.legend:Hide() end
    if self.stripTab then self.stripTab:Hide() end
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
-- UNDO TOAST
-- A small transient readout under the top strip naming what an Undo/Redo just
-- did. Re-showing replaces the text and restarts the hold clock (token), so a
-- run of Ctrl+Z presses reads as one toast that keeps up.
-- ============================================================
local TOAST_HOLD = 1.5

local function buildToast()
    local t = CreateFrame("Frame", "DandersMoverToast", P:GetUnlockFrame(), "BackdropTemplate")
    t:SetFrameStrata("DIALOG")
    UI:CreateElementBackdrop(t, {
        bgColor     = { C_BODY.r, C_BODY.g, C_BODY.b, BODY_ALPHA },
        borderColor = { C_OUTLINE.r, C_OUTLINE.g, C_OUTLINE.b, 1 },
    })
    t.text = UI:CreateLabel(t, { size = 11, color = UI.Colors.text })
    t.text:SetPoint("CENTER")
    t:Hide()
    return t
end

function P:ShowToast(text)
    if not self.toast then self.toast = buildToast() end
    local t = self.toast
    t.text:SetText(text)
    t:SetSize(max(80, (t.text:GetStringWidth() or 0) + PAD * 2), 22)
    t:ClearAllPoints()
    -- Near the strip: under it when expanded, under the slim tab otherwise.
    local anchor = (self.legend and self.legend:IsShown()) and self.legend or self.stripTab
    if anchor and anchor:IsShown() then t:SetPoint("TOP", anchor, "BOTTOM", 0, -TIGHT)
    else t:SetPoint("TOP", UIParent, "TOP", 0, -PAD) end
    NS.Fx.FadeIn(t, 0.1)
    local token = (self.toastToken or 0) + 1
    self.toastToken = token
    if C_Timer then
        C_Timer.After(TOAST_HOLD, function()
            if self.toastToken == token and t:IsShown() then
                NS.Fx.FadeOut(t, 0.2, function() t:Hide() end)
            end
        end)
    end
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
    if a then GameTooltip:AddLine(L["Drop into a zone to re-anchor; pull far away or Detach to free it."], 0.8, 0.8, 0.8) end
    GameTooltip:AddLine(L["Press Esc or use the top strip to lock."], 0.8, 0.8, 0.8)
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
