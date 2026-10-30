local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- ICON RAIL -- a vertical list of icon + label items down a window's edge.
-- The navigation a settings window uses for its top-level places (one item
-- per module). Two slots: "top" items stack down from the top edge, "bottom"
-- items stack up from the bottom edge, and the gap between them is whatever
-- is left over.
--
-- Each item: hover plate, accent-tinted active state, a selection marker on
-- its left edge (the y-axis CreateSelectionMarker, so the bar GLIDES between
-- items), an optional badge ("New", a count), a disabled state (dim + deaf)
-- and a tooltip through ShowTooltip.
--
--   local rail = host:CreateIconRail(parent, {
--       width = 62, onSelect = function(id) ... end,
--   })
--   rail:SetItems({
--       { id = "a", icon = "Interface\\...\\x.png", label = "A",
--         tooltip = "Long name" or { title = ..., lines = ... },
--         accent = {r,g,b} or function() return {r,g,b} end,
--         slot = "top" | "bottom" },
--   })
--   rail:Select("a")          -- paints only; onSelect fires on a USER click
--   rail:SetBadge("a", "New") / rail:SetBadge("a", nil)
--   rail:SetDisabled("a", true)
--
-- label / tooltip / accent may be functions, resolved on every paint, so a
-- language override or a mode-following accent is picked up without a rebuild.
--
-- ☠ NOTHING HERE NAMES A CONSUMER. Which items exist, what a click does and
-- what is locked are the caller's business; the rail only draws them.
-- Part of the load-on-demand options manifest.
-- ============================================================

local CreateFrame = CreateFrame
local ipairs, type, pairs = ipairs, type, pairs

local C_TEXT, C_TEXT_DIM, C_HOVER, C_NOTICE =
      UI.Colors.text, UI.Colors.textDim, UI.Colors.hover, UI.Colors.notice
-- The hover/selected plate: a rounded pill inset inside the rail's width.
local PLATE_INSET_X, PLATE_INSET_Y, PLATE_RADIUS = 4, 2, 6

-- The kit's disabled alpha (CreateSlider, CreateCheckbox, StyleButton's
-- SetEnabled and CreateGlyphButton all use it).
local DISABLED_ALPHA = 0.4

local function Resolve(v)
    if type(v) == "function" then return v() end
    return v
end

local function Unpack(c, dr, dg, db)
    if type(c) ~= "table" then return dr, dg, db end
    return c.r or c[1] or dr, c.g or c[2] or dg, c.b or c[3] or db
end

function UI:CreateIconRail(parent, opts)
    local host = self
    opts = opts or {}
    local width    = opts.width or 62
    local itemH    = opts.itemHeight or 48
    local iconSize = opts.iconSize or 20
    local spacing  = opts.spacing or 2
    local padTop   = opts.paddingTop or 6
    local padBot   = opts.paddingBottom or 6
    local font     = opts.font or "DFFontHighlightSmall"
    local badgeC   = opts.badgeColor or C_NOTICE

    local rail = CreateFrame("Frame", nil, parent)
    rail:SetWidth(width)

    local buttons = {}     -- id -> button (pooled across SetItems)
    local items = {}       -- id -> item def (current set)
    local list = {}        -- current ids, in the order given
    local disabled = {}    -- id -> true
    local badges = {}      -- id -> text
    local selected

    local marker = host:CreateSelectionMarker(rail, {
        -- A short pill, not a full-height square bar: the plates are rounded,
        -- so the edge mark is too, and it stops short of the plate's corners.
        axis = "y", thickness = opts.markerThickness or 4, pill = true,
        inset = opts.markerInset or 12,
    })
    rail.Marker = marker

    local function AccentOf(id)
        local item = items[id]
        local c = item and Resolve(item.accent)
        if type(c) ~= "table" then c = host:GetAccent() end
        return c
    end

    -- One paint for every state, so hover, select, disable and a theme change
    -- cannot each leave the item in a different half-state.
    local function Paint(btn)
        local id = btn.railId
        local isSel = (id == selected)
        local isOff = disabled[id] and true or false
        btn:SetAlpha(isOff and DISABLED_ALPHA or 1)
        if isSel then
            local r, g, b = Unpack(AccentOf(id), 1, 1, 1)
            btn.PlateSurface:SetFillColor(r, g, b, 0.18)
            btn.Plate:Show()
            btn.Icon:SetVertexColor(r, g, b)
            btn.Label:SetTextColor(r, g, b)
        elseif btn.hovered and not isOff then
            btn.PlateSurface:SetFillColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 0.75)
            btn.Plate:Show()
            btn.Icon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            btn.Label:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            btn.Plate:Hide()
            btn.Icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            btn.Label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
        local badge = badges[id]
        if badge then
            btn.Badge:SetText(badge)
            btn.Badge:Show()
        else
            btn.Badge:Hide()
        end
    end

    local function TooltipSpec(btn)
        local item = items[btn.railId]
        if not item then return nil end
        local t = Resolve(item.tooltip)
        if type(t) == "table" then return t end
        if type(t) == "string" and t ~= "" then return { title = t } end
        local label = Resolve(item.label)
        if type(label) == "string" and label ~= "" then return { title = label } end
        return nil
    end

    local function MakeButton(id)
        local btn = CreateFrame("Button", nil, rail)
        btn.railId = id
        btn.hovered = false
        btn:SetSize(width, itemH)
        btn:RegisterForClicks("LeftButtonUp")

        -- The plate is a rounded surface on its own child frame, inset from the
        -- rail's edges so it reads as a pill rather than a full-width band (the
        -- selection marker keeps the rail's left edge to itself).
        local plate = CreateFrame("Frame", nil, btn)
        plate:SetPoint("TOPLEFT", btn, "TOPLEFT", PLATE_INSET_X, -PLATE_INSET_Y)
        plate:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -PLATE_INSET_X, PLATE_INSET_Y)
        plate:SetFrameLevel(btn:GetFrameLevel())
        btn.PlateSurface = host:CreateRoundedSurface(plate, { radius = PLATE_RADIUS, border = false })
        plate:Hide()
        btn.Plate = plate

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetSize(iconSize, iconSize)
        icon:SetPoint("TOP", btn, "TOP", 0, -8)
        btn.Icon = icon

        local label = btn:CreateFontString(nil, "OVERLAY", font)
        label:SetPoint("TOP", icon, "BOTTOM", 0, -3)
        label:SetWidth(width - 4)
        label:SetJustifyH("CENTER")
        label:SetWordWrap(false)
        btn.Label = label

        local badge = btn:CreateFontString(nil, "OVERLAY", font)
        badge:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -3, -3)
        badge:SetTextColor(Unpack(badgeC, 1, 0.82, 0))
        badge:Hide()
        btn.Badge = badge

        btn:SetScript("OnEnter", function(s)
            s.hovered = true
            Paint(s)
            local spec = TooltipSpec(s)
            if spec then host:ShowTooltip(s, spec) end
        end)
        btn:SetScript("OnLeave", function(s)
            s.hovered = false
            Paint(s)
            host:HideTooltip()
        end)
        btn:SetScript("OnClick", function(s)
            if disabled[s.railId] then return end
            if opts.onSelect then opts.onSelect(s.railId) end
        end)
        buttons[id] = btn
        return btn
    end

    -- Lay the current set out: top slot down from the top, bottom slot up from
    -- the bottom (so the LAST bottom item sits on the bottom edge).
    local function Layout()
        local top, bottom = {}, {}
        for _, id in ipairs(list) do
            local item = items[id]
            if item.slot == "bottom" then bottom[#bottom + 1] = id else top[#top + 1] = id end
        end
        local prev
        for _, id in ipairs(top) do
            local btn = buttons[id]
            btn:ClearAllPoints()
            if prev then
                btn:SetPoint("TOP", prev, "BOTTOM", 0, -spacing)
            else
                btn:SetPoint("TOP", rail, "TOP", 0, -padTop)
            end
            prev = btn
        end
        prev = nil
        for i = #bottom, 1, -1 do
            local btn = buttons[bottom[i]]
            btn:ClearAllPoints()
            if prev then
                btn:SetPoint("BOTTOM", prev, "TOP", 0, spacing)
            else
                btn:SetPoint("BOTTOM", rail, "BOTTOM", 0, padBot)
            end
            prev = btn
        end
    end

    function rail:SetItems(newItems)
        items, list = {}, {}
        for _, item in ipairs(newItems or {}) do
            if type(item) == "table" and item.id ~= nil and not items[item.id] then
                items[item.id] = item
                list[#list + 1] = item.id
            end
        end
        for id, btn in pairs(buttons) do
            if not items[id] then btn:Hide() end
        end
        for _, id in ipairs(list) do
            local btn = buttons[id] or MakeButton(id)
            local item = items[id]
            if item.icon then btn.Icon:SetTexture(item.icon) end
            btn.Label:SetText(Resolve(item.label) or "")
            btn:Show()
        end
        Layout()
        if selected and not items[selected] then
            selected = nil
            marker:Clear()
        end
        self:Refresh(true)
        return self
    end

    -- The ids currently shown, in the order given.
    function rail:GetItemIds()
        local out = {}
        for i = 1, #list do out[i] = list[i] end
        return out
    end

    function rail:GetItem(id) return items[id] and buttons[id] or nil end

    -- Mark an item as the current one. Paints only: onSelect is the USER's
    -- click, so a consumer can call this from its own state without looping.
    function rail:Select(id, instant)
        local btn = id ~= nil and items[id] and buttons[id]
        selected = btn and id or nil
        if btn then
            marker:SetTo(btn, AccentOf(id), instant)
        else
            marker:Clear()
        end
        for _, bid in ipairs(list) do Paint(buttons[bid]) end
        return self
    end

    function rail:GetSelected() return selected end

    function rail:SetBadge(id, text)
        if text == "" then text = nil end
        if badges[id] == text then return self end
        badges[id] = text
        if items[id] and buttons[id] then Paint(buttons[id]) end
        return self
    end

    function rail:GetBadge(id) return badges[id] end

    -- Greyed and deaf, the kit's disabled look. A disabled item can still be
    -- the selected one (the caller decides what is current).
    function rail:SetDisabled(id, isDisabled)
        disabled[id] = isDisabled and true or nil
        local btn = buttons[id]
        if btn then
            btn:EnableMouse(not isDisabled)
            if isDisabled then btn.hovered = false end
            if items[id] then Paint(btn) end
        end
        return self
    end

    function rail:IsDisabled(id) return disabled[id] == true end

    -- Re-resolve labels and accents (a language change, an accent that moved).
    function rail:Refresh(instant)
        for _, id in ipairs(list) do
            local btn = buttons[id]
            btn.Label:SetText(Resolve(items[id].label) or "")
            Paint(btn)
        end
        if selected and buttons[selected] then
            marker:SetTo(buttons[selected], AccentOf(selected), instant ~= false)
        end
        return self
    end

    return rail
end
UI.CreateIconRailNative = UI.CreateIconRail
