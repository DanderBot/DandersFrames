local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - OPTIONS GUI
-- Custom page layout: left content area + fixed 280px right panel
-- Called from Options/Options.lua via DF.BuildAuraDesignerPage()
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local format = string.format
local wipe = wipe
local tinsert = table.insert
local max, min = math.max, math.min

-- Local references set during BuildAuraDesignerPage
local GUI
local page
local db
local Adapter

-- State
local selectedAura = nil        -- nil = Global Settings view, or aura internal name
local selectedSpec = nil         -- Current spec key being viewed

-- Reusable color constants (mirrors GUI.lua)
local C_BACKGROUND = {r = 0.08, g = 0.08, b = 0.08, a = 0.95}
local C_PANEL      = {r = 0.12, g = 0.12, b = 0.12, a = 1}
local C_ELEMENT    = {r = 0.18, g = 0.18, b = 0.18, a = 1}
local C_BORDER     = {r = 0.25, g = 0.25, b = 0.25, a = 1}
local C_HOVER      = {r = 0.22, g = 0.22, b = 0.22, a = 1}
local C_TEXT       = {r = 0.9, g = 0.9, b = 0.9, a = 1}
local C_TEXT_DIM   = {r = 0.6, g = 0.6, b = 0.6, a = 1}

-- Indicator type definitions
local INDICATOR_TYPES = {
    { key = "icon",       label = "Icon",             placed = true  },
    { key = "square",     label = "Square",           placed = true  },
    { key = "bar",        label = "Bar",              placed = true  },
    { key = "border",     label = "Border",           placed = false },
    { key = "healthbar",  label = "Health Bar Color", placed = false },
    { key = "nametext",   label = "Name Text Color",  placed = false },
    { key = "healthtext", label = "Health Text Color", placed = false },
    { key = "framealpha", label = "Frame Alpha",      placed = false },
}

local ANCHOR_OPTIONS = {
    CENTER = "Center", TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
    TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
    _order = {"TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT"},
}

local GROWTH_OPTIONS = {
    RIGHT = "Right", LEFT = "Left", UP = "Up", DOWN = "Down",
    _order = {"RIGHT", "LEFT", "UP", "DOWN"},
}

local BORDER_STYLE_OPTIONS = {
    Solid = "Solid", Glow = "Glow", Pulse = "Pulse",
    _order = {"Solid", "Glow", "Pulse"},
}

local HEALTHBAR_MODE_OPTIONS = {
    Replace = "Replace", Tint = "Tint",
    _order = {"Replace", "Tint"},
}

local BAR_ORIENT_OPTIONS = {
    HORIZONTAL = "Horizontal", VERTICAL = "Vertical",
    _order = {"HORIZONTAL", "VERTICAL"},
}

-- ============================================================
-- HELPERS
-- ============================================================

local function GetAuraDesignerDB()
    return db.auraDesigner
end

local function GetThemeColor()
    return GUI.GetThemeColor()
end

local function ApplyBackdrop(frame, bgColor, borderColor)
    if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    if bgColor then
        frame:SetBackdropColor(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 1)
    end
    if borderColor then
        frame:SetBackdropBorderColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
    end
end

-- Get or resolve the active spec key from settings
local function ResolveSpec()
    local adDB = GetAuraDesignerDB()
    if adDB.spec == "auto" then
        return Adapter:GetPlayerSpec()
    end
    return adDB.spec
end

-- Ensure an aura config table exists, creating it with defaults if needed
local function EnsureAuraConfig(auraName)
    local adDB = GetAuraDesignerDB()
    if not adDB.auras[auraName] then
        adDB.auras[auraName] = {
            priority = 5,
        }
    end
    return adDB.auras[auraName]
end

-- Ensure a type sub-table exists within an aura config
local function EnsureTypeConfig(auraName, typeKey)
    local auraCfg = EnsureAuraConfig(auraName)
    if not auraCfg[typeKey] then
        -- Create default config for each type
        if typeKey == "icon" then
            auraCfg[typeKey] = {
                anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
                growth = "RIGHT", spacing = 2, size = nil, scale = nil,
                alpha = 1.0, borderEnabled = nil, borderThickness = nil,
                hideSwipe = false, stackFont = nil, stackScale = nil,
                stackMinimum = nil, showDuration = nil, durationScale = nil,
                durationColorByTime = nil,
            }
        elseif typeKey == "square" then
            auraCfg[typeKey] = {
                anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
                growth = "RIGHT", spacing = 2, size = 10,
                color = {r = 1, g = 1, b = 1, a = 1}, alpha = 1.0,
                borderEnabled = true, showDuration = false, showStacks = false,
            }
        elseif typeKey == "bar" then
            auraCfg[typeKey] = {
                anchor = "BOTTOM", offsetX = 0, offsetY = 0,
                orientation = "HORIZONTAL", width = 0, height = 4,
                matchFrameWidth = true, fillColor = {r = 1, g = 1, b = 1, a = 1},
                bgColor = {r = 0, g = 0, b = 0, a = 0.5},
                borderColor = {r = 0, g = 0, b = 0, a = 1}, alpha = 1.0,
            }
        elseif typeKey == "border" then
            auraCfg[typeKey] = {
                style = "Solid", color = {r = 1, g = 1, b = 1, a = 1},
                thickness = 2, pulsate = false, speed = 0.5,
            }
        elseif typeKey == "healthbar" then
            auraCfg[typeKey] = {
                mode = "Tint", color = {r = 1, g = 1, b = 1, a = 1}, blend = 0.5,
            }
        elseif typeKey == "nametext" then
            auraCfg[typeKey] = {
                color = {r = 1, g = 1, b = 1, a = 1},
            }
        elseif typeKey == "healthtext" then
            auraCfg[typeKey] = {
                color = {r = 1, g = 1, b = 1, a = 1},
            }
        elseif typeKey == "framealpha" then
            auraCfg[typeKey] = {
                alpha = 0.5,
            }
        end
    end
    return auraCfg[typeKey]
end

-- Create a proxy table that maps flat key access to nested aura config
local function CreateProxy(auraName, typeKey)
    return setmetatable({}, {
        __index = function(_, k)
            local adDB = GetAuraDesignerDB()
            local auraCfg = adDB.auras[auraName]
            if auraCfg and auraCfg[typeKey] then
                return auraCfg[typeKey][k]
            end
            return nil
        end,
        __newindex = function(_, k, v)
            local typeCfg = EnsureTypeConfig(auraName, typeKey)
            typeCfg[k] = v
        end,
    })
end

-- Create a proxy for the aura-level config (priority, expiring)
local function CreateAuraProxy(auraName)
    return setmetatable({}, {
        __index = function(_, k)
            local adDB = GetAuraDesignerDB()
            local auraCfg = adDB.auras[auraName]
            if auraCfg then return auraCfg[k] end
            return nil
        end,
        __newindex = function(_, k, v)
            local auraCfg = EnsureAuraConfig(auraName)
            auraCfg[k] = v
        end,
    })
end

-- Create a proxy for the expiring sub-table
local function CreateExpiringProxy(auraName)
    return setmetatable({}, {
        __index = function(_, k)
            local adDB = GetAuraDesignerDB()
            local auraCfg = adDB.auras[auraName]
            if auraCfg and auraCfg.expiring then
                return auraCfg.expiring[k]
            end
            return nil
        end,
        __newindex = function(_, k, v)
            local auraCfg = EnsureAuraConfig(auraName)
            if not auraCfg.expiring then
                auraCfg.expiring = {
                    enabled = false, threshold = 30,
                    borderEnabled = false, borderColor = {r = 1, g = 0.53, b = 0, a = 1},
                    borderThickness = 1, pulsate = false,
                    tintEnabled = false, tintColor = {r = 1, g = 0.3, b = 0.3, a = 0.5},
                }
            end
            auraCfg.expiring[k] = v
        end,
    })
end

-- Count active effects for an aura
local function CountActiveEffects(auraName)
    local adDB = GetAuraDesignerDB()
    local auraCfg = adDB.auras[auraName]
    if not auraCfg then return 0 end
    local count = 0
    for _, typeDef in ipairs(INDICATOR_TYPES) do
        if auraCfg[typeDef.key] then count = count + 1 end
    end
    return count
end

-- ============================================================
-- FRAME REFERENCES (populated during build)
-- ============================================================
local mainFrame           -- The root frame for the entire page
local leftPanel           -- Left content area (flexible width)
local rightPanel          -- Right settings panel (280px fixed)
local enableBanner        -- Enable toggle banner
local attributionRow      -- HARF attribution row
local tileStrip           -- Horizontal scrolling aura tile palette
local tileStripContent    -- ScrollChild for tile strip
local framePreview        -- Mock unit frame preview
local activeEffectsStrip  -- Active effects list below preview
local rightScrollFrame    -- Scroll frame for right panel content
local rightScrollChild    -- ScrollChild for right panel

-- Tile button pool
local tilePool = {}
local activeTiles = {}

-- ============================================================
-- TILE STRIP
-- ============================================================

local function CreateAuraTile(parent, auraInfo, index)
    local tile = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tile:SetSize(64, 82)
    ApplyBackdrop(tile, C_ELEMENT, {r = 0.27, g = 0.27, b = 0.27, a = 1})

    -- Icon area (colored square as placeholder until real spell icons)
    tile.iconBg = tile:CreateTexture(nil, "ARTWORK")
    tile.iconBg:SetPoint("TOP", 0, -4)
    tile.iconBg:SetSize(48, 48)
    tile.iconBg:SetColorTexture(auraInfo.color[1] * 0.4, auraInfo.color[2] * 0.4, auraInfo.color[3] * 0.4, 1)

    -- Icon letter (first letter as placeholder)
    tile.letter = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tile.letter:SetPoint("CENTER", tile.iconBg, "CENTER", 0, 0)
    tile.letter:SetText(auraInfo.display:sub(1, 1))
    tile.letter:SetTextColor(auraInfo.color[1], auraInfo.color[2], auraInfo.color[3])

    -- Name label
    tile.nameLabel = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tile.nameLabel:SetPoint("BOTTOM", 0, 2)
    tile.nameLabel:SetWidth(60)
    tile.nameLabel:SetMaxLines(1)
    tile.nameLabel:SetText(auraInfo.display)
    tile.nameLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- Configured badge
    tile.badge = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tile.badge:SetPoint("TOPRIGHT", -2, -2)
    tile.badge:SetText("")
    tile.badge:SetTextColor(1, 1, 1)
    tile.badge:Hide()

    tile.auraInfo = auraInfo
    tile.auraName = auraInfo.name

    tile.SetSelected = function(self, selected)
        if selected then
            local c = GetThemeColor()
            self:SetBackdropBorderColor(c.r, c.g, c.b, 1)
        else
            local adDB = GetAuraDesignerDB()
            local auraCfg = adDB.auras[self.auraName]
            if auraCfg then
                self:SetBackdropBorderColor(self.auraInfo.color[1], self.auraInfo.color[2], self.auraInfo.color[3], 0.8)
            else
                self:SetBackdropBorderColor(0.27, 0.27, 0.27, 1)
            end
        end
    end

    tile.UpdateBadge = function(self)
        local count = CountActiveEffects(self.auraName)
        if count > 0 then
            self.badge:SetText(count)
            self.badge:Show()
        else
            self.badge:Hide()
        end
    end

    tile:SetScript("OnEnter", function(self)
        if selectedAura ~= self.auraName then
            self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
        end
    end)
    tile:SetScript("OnLeave", function(self)
        if selectedAura ~= self.auraName then
            self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        end
    end)

    tile:SetScript("OnClick", function(self)
        selectedAura = self.auraName
        DF:AuraDesigner_RefreshPage()
    end)

    return tile
end

local function CreateGlobalSettingsTile(parent)
    local tile = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tile:SetSize(64, 82)
    ApplyBackdrop(tile, C_ELEMENT, {r = 0.40, g = 0.40, b = 0.40, a = 1})

    tile.iconBg = tile:CreateTexture(nil, "ARTWORK")
    tile.iconBg:SetPoint("TOP", 0, -4)
    tile.iconBg:SetSize(48, 48)
    tile.iconBg:SetColorTexture(0.25, 0.25, 0.25, 1)

    tile.letter = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tile.letter:SetPoint("CENTER", tile.iconBg, "CENTER", 0, 0)
    tile.letter:SetText("*")
    tile.letter:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    tile.nameLabel = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tile.nameLabel:SetPoint("BOTTOM", 0, 2)
    tile.nameLabel:SetWidth(60)
    tile.nameLabel:SetMaxLines(1)
    tile.nameLabel:SetText("Global")
    tile.nameLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    tile.auraName = nil
    tile.UpdateBadge = function() end  -- No badge for global

    tile.SetSelected = function(self, isSelected)
        if isSelected then
            local c = GetThemeColor()
            self:SetBackdropBorderColor(c.r, c.g, c.b, 1)
        else
            self:SetBackdropBorderColor(0.40, 0.40, 0.40, 1)
        end
    end

    tile:SetScript("OnEnter", function(self)
        if selectedAura ~= nil then
            self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
        end
    end)
    tile:SetScript("OnLeave", function(self)
        if selectedAura ~= nil then
            self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        end
    end)

    tile:SetScript("OnClick", function(self)
        selectedAura = nil
        DF:AuraDesigner_RefreshPage()
    end)

    return tile
end

-- ============================================================
-- TILE STRIP POPULATION
-- ============================================================

local function PopulateTileStrip()
    for _, tile in ipairs(activeTiles) do
        tile:Hide()
    end
    wipe(activeTiles)

    if not tileStripContent then return end

    local spec = ResolveSpec()
    selectedSpec = spec

    if not spec then return end

    local auras = Adapter:GetTrackableAuras(spec)
    if not auras or #auras == 0 then return end

    local globalTile = CreateGlobalSettingsTile(tileStripContent)
    globalTile:SetPoint("LEFT", tileStripContent, "LEFT", 4, 0)
    globalTile:SetSelected(selectedAura == nil)
    activeTiles[#activeTiles + 1] = globalTile

    local prevTile = globalTile
    for i, auraInfo in ipairs(auras) do
        local tile = CreateAuraTile(tileStripContent, auraInfo, i)
        tile:SetPoint("LEFT", prevTile, "RIGHT", 4, 0)
        tile:SetSelected(selectedAura == auraInfo.name)
        tile:UpdateBadge()
        activeTiles[#activeTiles + 1] = tile
        prevTile = tile
    end

    local totalWidth = (#auras + 1) * (64 + 4) + 4
    tileStripContent:SetWidth(totalWidth)
end

-- ============================================================
-- RIGHT PANEL: INDICATOR TYPE SECTION BUILDER
-- Builds a collapsible section for one indicator type
-- ============================================================

local function AddSectionHeader(parent, yOffset, label, typeKey, auraName, width)
    local headerHeight = 28
    local header = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    header:SetSize(width or 258, headerHeight)
    header:SetPoint("TOPLEFT", 0, yOffset)
    ApplyBackdrop(header, C_PANEL, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    -- Enable checkbox
    local cb = CreateFrame("CheckButton", nil, header, "BackdropTemplate")
    cb:SetSize(16, 16)
    cb:SetPoint("LEFT", 6, 0)
    ApplyBackdrop(cb, C_ELEMENT, C_BORDER)

    cb.Check = cb:CreateTexture(nil, "OVERLAY")
    cb.Check:SetTexture("Interface\\Buttons\\WHITE8x8")
    local tc = GetThemeColor()
    cb.Check:SetVertexColor(tc.r, tc.g, tc.b)
    cb.Check:SetPoint("CENTER")
    cb.Check:SetSize(8, 8)
    cb:SetCheckedTexture(cb.Check)

    local adDB = GetAuraDesignerDB()
    local auraCfg = adDB.auras[auraName]
    cb:SetChecked(auraCfg and auraCfg[typeKey] ~= nil)

    -- Collapse/expand arrow
    header.arrow = header:CreateTexture(nil, "OVERLAY")
    header.arrow:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    header.arrow:SetSize(10, 10)
    header.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    header.arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Title
    local title = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("LEFT", header.arrow, "RIGHT", 4, 0)
    title:SetText(label)
    title:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- State
    header.expanded = false
    header.contentFrame = nil
    header.typeKey = typeKey
    header.auraName = auraName

    return header, cb
end

-- Build the widget content for a given indicator type
local function BuildTypeContent(parent, typeKey, auraName, width)
    local proxy = CreateProxy(auraName, typeKey)
    local contentWidth = width or 248
    local widgets = {}
    local totalHeight = 8  -- top padding

    local function AddWidget(widget, height)
        widget:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -totalHeight)
        if widget.SetWidth then widget:SetWidth(contentWidth - 10) end
        tinsert(widgets, widget)
        totalHeight = totalHeight + (height or 30)
    end

    if typeKey == "icon" then
        AddWidget(GUI:CreateDropdown(parent, "Anchor", ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset X", -50, 50, 1, proxy, "offsetX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset Y", -50, 50, 1, proxy, "offsetY"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Growth", GROWTH_OPTIONS, proxy, "growth"), 54)
        AddWidget(GUI:CreateSlider(parent, "Spacing", 0, 20, 1, proxy, "spacing"), 54)
        AddWidget(GUI:CreateSlider(parent, "Size", 8, 64, 1, proxy, "size"), 54)
        AddWidget(GUI:CreateSlider(parent, "Scale", 0.5, 3.0, 0.05, proxy, "scale"), 54)
        AddWidget(GUI:CreateSlider(parent, "Alpha", 0, 1, 0.05, proxy, "alpha"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Show Border", proxy, "borderEnabled"), 28)
        AddWidget(GUI:CreateCheckbox(parent, "Hide Cooldown Swipe", proxy, "hideSwipe"), 28)
        AddWidget(GUI:CreateCheckbox(parent, "Show Duration Text", proxy, "showDuration"), 28)
        AddWidget(GUI:CreateSlider(parent, "Duration Scale", 0.5, 2.0, 0.1, proxy, "durationScale"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Color Duration by Time", proxy, "durationColorByTime"), 28)
        AddWidget(GUI:CreateCheckbox(parent, "Show Stacks", proxy, "showStacks"), 28)
        AddWidget(GUI:CreateSlider(parent, "Stack Minimum", 1, 10, 1, proxy, "stackMinimum"), 54)

    elseif typeKey == "square" then
        AddWidget(GUI:CreateDropdown(parent, "Anchor", ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset X", -50, 50, 1, proxy, "offsetX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset Y", -50, 50, 1, proxy, "offsetY"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Growth", GROWTH_OPTIONS, proxy, "growth"), 54)
        AddWidget(GUI:CreateSlider(parent, "Spacing", 0, 20, 1, proxy, "spacing"), 54)
        AddWidget(GUI:CreateSlider(parent, "Size", 4, 32, 1, proxy, "size"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true), 28)
        AddWidget(GUI:CreateSlider(parent, "Alpha", 0, 1, 0.05, proxy, "alpha"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Show Border", proxy, "borderEnabled"), 28)
        AddWidget(GUI:CreateCheckbox(parent, "Show Duration", proxy, "showDuration"), 28)
        AddWidget(GUI:CreateCheckbox(parent, "Show Stacks", proxy, "showStacks"), 28)

    elseif typeKey == "bar" then
        AddWidget(GUI:CreateDropdown(parent, "Anchor", ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset X", -50, 50, 1, proxy, "offsetX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Offset Y", -50, 50, 1, proxy, "offsetY"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Orientation", BAR_ORIENT_OPTIONS, proxy, "orientation"), 54)
        AddWidget(GUI:CreateSlider(parent, "Width", 0, 200, 1, proxy, "width"), 54)
        AddWidget(GUI:CreateSlider(parent, "Height", 1, 30, 1, proxy, "height"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Match Frame Width", proxy, "matchFrameWidth"), 28)
        AddWidget(GUI:CreateColorPicker(parent, "Fill Color", proxy, "fillColor", true), 28)
        AddWidget(GUI:CreateColorPicker(parent, "Background Color", proxy, "bgColor", true), 28)
        AddWidget(GUI:CreateColorPicker(parent, "Border Color", proxy, "borderColor", true), 28)
        AddWidget(GUI:CreateSlider(parent, "Alpha", 0, 1, 0.05, proxy, "alpha"), 54)

    elseif typeKey == "border" then
        AddWidget(GUI:CreateDropdown(parent, "Style", BORDER_STYLE_OPTIONS, proxy, "style"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true), 28)
        AddWidget(GUI:CreateSlider(parent, "Thickness", 1, 8, 1, proxy, "thickness"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Pulsate", proxy, "pulsate"), 28)
        AddWidget(GUI:CreateSlider(parent, "Pulse Speed", 0.1, 2.0, 0.1, proxy, "speed"), 54)

    elseif typeKey == "healthbar" then
        AddWidget(GUI:CreateDropdown(parent, "Mode", HEALTHBAR_MODE_OPTIONS, proxy, "mode"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true), 28)
        AddWidget(GUI:CreateSlider(parent, "Blend %", 0, 1, 0.05, proxy, "blend"), 54)

    elseif typeKey == "nametext" then
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true), 28)

    elseif typeKey == "healthtext" then
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true), 28)

    elseif typeKey == "framealpha" then
        AddWidget(GUI:CreateSlider(parent, "Alpha", 0, 1, 0.05, proxy, "alpha"), 54)
    end

    totalHeight = totalHeight + 4  -- bottom padding
    parent:SetHeight(totalHeight)
    return widgets, totalHeight
end

-- ============================================================
-- RIGHT PANEL CONTENT
-- ============================================================

local rightPanelChildren = {}

local function BuildGlobalView(parent)
    local adDB = GetAuraDesignerDB()
    local defaults = adDB.defaults
    local yPos = -10
    local contentWidth = 258

    -- Title
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, yPos)
    title:SetText("Global Defaults")
    local c = GetThemeColor()
    title:SetTextColor(c.r, c.g, c.b)
    yPos = yPos - 20

    -- Description
    local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 10, yPos)
    desc:SetWidth(240)
    desc:SetJustifyH("LEFT")
    desc:SetWordWrap(true)
    desc:SetText("Default values for all aura indicators. Per-aura settings override these when set.")
    desc:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 32

    -- Icon defaults
    local iconSize = GUI:CreateSlider(parent, "Icon Size", 8, 64, 1, defaults, "iconSize")
    iconSize:SetPoint("TOPLEFT", 5, yPos)
    iconSize:SetWidth(contentWidth - 10)
    yPos = yPos - 54

    local iconScale = GUI:CreateSlider(parent, "Icon Scale", 0.5, 3.0, 0.05, defaults, "iconScale")
    iconScale:SetPoint("TOPLEFT", 5, yPos)
    iconScale:SetWidth(contentWidth - 10)
    yPos = yPos - 54

    local showDuration = GUI:CreateCheckbox(parent, "Show Duration", defaults, "showDuration")
    showDuration:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 28

    local durationScale = GUI:CreateSlider(parent, "Duration Scale", 0.5, 2.0, 0.1, defaults, "durationScale")
    durationScale:SetPoint("TOPLEFT", 5, yPos)
    durationScale:SetWidth(contentWidth - 10)
    yPos = yPos - 54

    local colorByTime = GUI:CreateCheckbox(parent, "Color Duration by Time", defaults, "durationColorByTime")
    colorByTime:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 28

    local showStacks = GUI:CreateCheckbox(parent, "Show Stacks", defaults, "showStacks")
    showStacks:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 28

    local stackMin = GUI:CreateSlider(parent, "Stack Minimum", 1, 10, 1, defaults, "stackMinimum")
    stackMin:SetPoint("TOPLEFT", 5, yPos)
    stackMin:SetWidth(contentWidth - 10)
    yPos = yPos - 54

    local iconBorder = GUI:CreateCheckbox(parent, "Icon Border", defaults, "iconBorderEnabled")
    iconBorder:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 34

    -- ===== DIVIDER =====
    local divider = parent:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", 10, yPos)
    divider:SetSize(238, 1)
    divider:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    yPos = yPos - 12

    -- ===== ACTIONS =====
    local actionsTitle = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    actionsTitle:SetPoint("TOPLEFT", 10, yPos)
    actionsTitle:SetText("Actions")
    actionsTitle:SetTextColor(c.r, c.g, c.b)
    yPos = yPos - 24

    -- Copy Settings to Raid button
    local copyBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    copyBtn:SetSize(238, 26)
    copyBtn:SetPoint("TOPLEFT", 10, yPos)
    ApplyBackdrop(copyBtn, C_ELEMENT, C_BORDER)

    local copyText = copyBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copyText:SetPoint("CENTER", 0, 0)
    copyText:SetText("Copy Settings to Raid")
    copyText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    copyBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    copyBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)
    copyBtn:SetScript("OnClick", function()
        local source = DF:GetDB("party").auraDesigner
        local dest = DF:GetDB("raid").auraDesigner
        -- Deep copy
        local function DeepCopy(src)
            if type(src) ~= "table" then return src end
            local copy = {}
            for k, v in pairs(src) do copy[k] = DeepCopy(v) end
            return copy
        end
        local newCopy = DeepCopy(source)
        for k, v in pairs(newCopy) do dest[k] = v end
        DF:Debug("Aura Designer: Copied party settings to raid")
    end)
    yPos = yPos - 32

    -- Reset All button
    local resetBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    resetBtn:SetSize(238, 26)
    resetBtn:SetPoint("TOPLEFT", 10, yPos)
    ApplyBackdrop(resetBtn, {r = 0.3, g = 0.12, b = 0.12, a = 1}, {r = 0.5, g = 0.2, b = 0.2, a = 1})

    local resetText = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    resetText:SetPoint("CENTER", 0, 0)
    resetText:SetText("Reset All Aura Configs")
    resetText:SetTextColor(1, 0.7, 0.7)

    resetBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.4, 0.15, 0.15, 1)
    end)
    resetBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.3, 0.12, 0.12, 1)
    end)
    resetBtn:SetScript("OnClick", function()
        wipe(GetAuraDesignerDB().auras)
        DF:AuraDesigner_RefreshPage()
        DF:Debug("Aura Designer: Reset all aura configurations")
    end)
    yPos = yPos - 40

    parent:SetHeight(-yPos + 10)
end

local function BuildPerAuraView(parent, auraName)
    local auraInfo
    local spec = ResolveSpec()
    if spec then
        for _, info in ipairs(Adapter:GetTrackableAuras(spec)) do
            if info.name == auraName then
                auraInfo = info
                break
            end
        end
    end
    if not auraInfo then return end

    local adDB = GetAuraDesignerDB()
    local auraCfg = adDB.auras[auraName]
    local yPos = -10
    local contentWidth = 258

    -- ===== HEADER: icon + name + status =====
    local iconBg = parent:CreateTexture(nil, "ARTWORK")
    iconBg:SetPoint("TOPLEFT", 10, yPos)
    iconBg:SetSize(32, 32)
    iconBg:SetColorTexture(auraInfo.color[1] * 0.4, auraInfo.color[2] * 0.4, auraInfo.color[3] * 0.4, 1)

    local letter = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    letter:SetPoint("CENTER", iconBg, "CENTER", 0, 0)
    letter:SetText(auraInfo.display:sub(1, 1))
    letter:SetTextColor(auraInfo.color[1], auraInfo.color[2], auraInfo.color[3])

    local nameText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("LEFT", iconBg, "RIGHT", 8, 4)
    nameText:SetText(auraInfo.display)
    nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local statusText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -2)

    local effectCount = CountActiveEffects(auraName)
    if effectCount > 0 then
        statusText:SetText(effectCount .. " effect(s) active")
        statusText:SetTextColor(auraInfo.color[1], auraInfo.color[2], auraInfo.color[3])
    else
        statusText:SetText("Not configured")
        statusText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end
    yPos = yPos - 46

    -- ===== PRIORITY SLIDER =====
    local auraProxy = CreateAuraProxy(auraName)
    -- Ensure priority default
    if not auraCfg or auraCfg.priority == nil then
        EnsureAuraConfig(auraName)
    end

    local priority = GUI:CreateSlider(parent, "Priority", 1, 10, 1, auraProxy, "priority")
    priority:SetPoint("TOPLEFT", 5, yPos)
    priority:SetWidth(contentWidth - 10)
    yPos = yPos - 58

    -- ===== DIVIDER =====
    local div1 = parent:CreateTexture(nil, "ARTWORK")
    div1:SetPoint("TOPLEFT", 10, yPos)
    div1:SetSize(238, 1)
    div1:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    yPos = yPos - 8

    -- ===== 8 INDICATOR TYPE SECTIONS =====
    -- Each section: collapsible header with enable checkbox + content
    local sectionStates = {}

    for _, typeDef in ipairs(INDICATOR_TYPES) do
        local typeKey = typeDef.key
        local typeLabel = typeDef.label
        local isEnabled = auraCfg and auraCfg[typeKey] ~= nil

        -- Section header
        local header = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        header:SetSize(contentWidth, 26)
        header:SetPoint("TOPLEFT", 0, yPos)
        ApplyBackdrop(header, C_PANEL, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

        -- Enable checkbox
        local cb = CreateFrame("CheckButton", nil, header, "BackdropTemplate")
        cb:SetSize(14, 14)
        cb:SetPoint("LEFT", 6, 0)
        ApplyBackdrop(cb, C_ELEMENT, C_BORDER)

        cb.Check = cb:CreateTexture(nil, "OVERLAY")
        cb.Check:SetTexture("Interface\\Buttons\\WHITE8x8")
        local tc = GetThemeColor()
        cb.Check:SetVertexColor(tc.r, tc.g, tc.b)
        cb.Check:SetPoint("CENTER")
        cb.Check:SetSize(8, 8)
        cb:SetCheckedTexture(cb.Check)
        cb:SetChecked(isEnabled)

        -- Arrow
        local arrow = header:CreateTexture(nil, "OVERLAY")
        arrow:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        arrow:SetSize(10, 10)
        arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        -- Title
        local title = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        title:SetPoint("LEFT", arrow, "RIGHT", 4, 0)
        title:SetText(typeLabel)
        if isEnabled then
            title:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            title:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end

        -- Content container
        local content = CreateFrame("Frame", nil, parent)
        content:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
        content:SetWidth(contentWidth)
        content:Hide()

        -- Expand/collapse state
        local expanded = false

        local function UpdateArrow()
            if expanded and isEnabled then
                arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            else
                arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
            end
        end
        UpdateArrow()

        -- Build content if enabled
        local contentHeight = 0
        if isEnabled then
            local _, h = BuildTypeContent(content, typeKey, auraName, contentWidth)
            contentHeight = h
        end

        -- Store section state for layout calculation
        local sectionData = {
            header = header,
            content = content,
            contentHeight = contentHeight,
            expanded = expanded,
            enabled = isEnabled,
        }
        tinsert(sectionStates, sectionData)

        yPos = yPos - 28  -- header height + gap

        -- Click header to toggle expand
        local headerClick = CreateFrame("Button", nil, header)
        headerClick:SetAllPoints()
        headerClick:RegisterForClicks("LeftButtonUp")
        headerClick:SetScript("OnClick", function()
            if not isEnabled then return end
            expanded = not expanded
            sectionData.expanded = expanded
            if expanded then
                content:Show()
            else
                content:Hide()
            end
            UpdateArrow()
            -- Recalculate layout
            DF:AuraDesigner_RefreshPage()
        end)

        -- Checkbox click to enable/disable type
        cb:SetScript("OnClick", function(self)
            local checked = self:GetChecked()
            local cfg = EnsureAuraConfig(auraName)
            if checked then
                EnsureTypeConfig(auraName, typeKey)
                isEnabled = true
                sectionData.enabled = true
                title:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                -- Rebuild content
                local _, h = BuildTypeContent(content, typeKey, auraName, contentWidth)
                contentHeight = h
                sectionData.contentHeight = h
            else
                cfg[typeKey] = nil
                isEnabled = false
                sectionData.enabled = false
                expanded = false
                sectionData.expanded = false
                content:Hide()
                title:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            end
            UpdateArrow()
            DF:AuraDesigner_RefreshPage()
        end)

        -- If expanded, show content and adjust yPos
        if expanded and isEnabled then
            content:Show()
            yPos = yPos - contentHeight - 2
        end
    end

    -- ===== DIVIDER =====
    yPos = yPos - 4
    local div2 = parent:CreateTexture(nil, "ARTWORK")
    div2:SetPoint("TOPLEFT", 10, yPos)
    div2:SetSize(238, 1)
    div2:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    yPos = yPos - 12

    -- ===== EXPIRING INDICATOR SECTION =====
    local expTitle = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    expTitle:SetPoint("TOPLEFT", 10, yPos)
    expTitle:SetText("Expiring Indicator")
    local c = GetThemeColor()
    expTitle:SetTextColor(c.r, c.g, c.b)
    yPos = yPos - 20

    local expProxy = CreateExpiringProxy(auraName)

    local expEnabled = GUI:CreateCheckbox(parent, "Enable Expiring Effects", expProxy, "enabled")
    expEnabled:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 28

    local expThreshold = GUI:CreateSlider(parent, "Threshold (%)", 1, 100, 1, expProxy, "threshold")
    expThreshold:SetPoint("TOPLEFT", 5, yPos)
    expThreshold:SetWidth(contentWidth - 10)
    yPos = yPos - 54

    local expBorder = GUI:CreateCheckbox(parent, "Border on Expiring", expProxy, "borderEnabled")
    expBorder:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 28

    local expBorderColor = GUI:CreateColorPicker(parent, "Expiring Border Color", expProxy, "borderColor", true)
    expBorderColor:SetPoint("TOPLEFT", 5, yPos)
    expBorderColor:SetWidth(contentWidth - 10)
    yPos = yPos - 28

    local expPulsate = GUI:CreateCheckbox(parent, "Pulsate on Expiring", expProxy, "pulsate")
    expPulsate:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 28

    local expTint = GUI:CreateCheckbox(parent, "Tint on Expiring", expProxy, "tintEnabled")
    expTint:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 28

    local expTintColor = GUI:CreateColorPicker(parent, "Expiring Tint Color", expProxy, "tintColor", true)
    expTintColor:SetPoint("TOPLEFT", 5, yPos)
    expTintColor:SetWidth(contentWidth - 10)
    yPos = yPos - 34

    parent:SetHeight(-yPos + 10)
end

local function RefreshRightPanel()
    for _, child in ipairs(rightPanelChildren) do
        child:Hide()
        child:SetParent(nil)
    end
    wipe(rightPanelChildren)

    if not rightScrollChild then return end

    local container = CreateFrame("Frame", nil, rightScrollChild)
    container:SetPoint("TOPLEFT", 0, 0)
    container:SetPoint("TOPRIGHT", 0, 0)
    container:SetHeight(800)
    rightPanelChildren[#rightPanelChildren + 1] = container

    if selectedAura == nil then
        BuildGlobalView(container)
    else
        BuildPerAuraView(container, selectedAura)
    end

    -- Update scroll child height to match content
    rightScrollChild:SetHeight(container:GetHeight())
end

-- ============================================================
-- ENABLE BANNER
-- ============================================================

local function CreateEnableBanner(parent)
    local banner = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    banner:SetHeight(36)
    banner:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    banner:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    ApplyBackdrop(banner, {r = 0.14, g = 0.14, b = 0.14, a = 1}, {r = 0.30, g = 0.30, b = 0.30, a = 0.5})

    local cb = CreateFrame("CheckButton", nil, banner, "UICheckButtonTemplate")
    cb:SetPoint("LEFT", 8, 0)
    cb:SetSize(24, 24)

    local adDB = GetAuraDesignerDB()
    cb:SetChecked(adDB.enabled)
    cb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        GetAuraDesignerDB().enabled = checked
        DF:AuraDesigner_RefreshPage()
    end)

    local cbLabel = banner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cbLabel:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cbLabel:SetText("Enable Aura Designer")
    cbLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local specLabel = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    specLabel:SetPoint("RIGHT", banner, "RIGHT", -145, 0)
    specLabel:SetText("Spec:")
    specLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local specBtn = CreateFrame("Button", nil, banner, "BackdropTemplate")
    specBtn:SetSize(130, 22)
    specBtn:SetPoint("LEFT", specLabel, "RIGHT", 4, 0)
    ApplyBackdrop(specBtn, C_ELEMENT, C_BORDER)

    specBtn.text = specBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    specBtn.text:SetPoint("LEFT", 6, 0)
    specBtn.text:SetPoint("RIGHT", -16, 0)
    specBtn.text:SetJustifyH("LEFT")

    local arrow = specBtn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -4, 0)
    arrow:SetSize(10, 10)
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local function UpdateSpecText()
        local adDB = GetAuraDesignerDB()
        if adDB.spec == "auto" then
            local autoSpec = Adapter:GetPlayerSpec()
            if autoSpec then
                specBtn.text:SetText("Auto (" .. Adapter:GetSpecDisplayName(autoSpec) .. ")")
            else
                specBtn.text:SetText("Auto (detect)")
            end
        else
            specBtn.text:SetText(Adapter:GetSpecDisplayName(adDB.spec))
        end
    end

    local specMenu = CreateFrame("Frame", nil, specBtn, "BackdropTemplate")
    specMenu:SetFrameStrata("DIALOG")
    specMenu:SetPoint("TOPLEFT", specBtn, "BOTTOMLEFT", 0, -1)
    specMenu:SetWidth(200)
    ApplyBackdrop(specMenu, C_PANEL, {r = 0.35, g = 0.35, b = 0.35, a = 1})
    specMenu:Hide()

    local function BuildSpecMenu()
        for _, child in ipairs({specMenu:GetChildren()}) do
            child:Hide()
            child:SetParent(nil)
        end

        local yOffset = -4
        local options = {{"auto", "Auto (detect spec)"}}
        for _, specKey in ipairs({
            "PreservationEvoker", "AugmentationEvoker", "RestorationDruid",
            "DisciplinePriest", "HolyPriest", "MistweaverMonk",
            "RestorationShaman", "HolyPaladin"
        }) do
            options[#options + 1] = {specKey, Adapter:GetSpecDisplayName(specKey)}
        end

        for _, opt in ipairs(options) do
            local btn = CreateFrame("Button", nil, specMenu)
            btn:SetHeight(20)
            btn:SetPoint("TOPLEFT", 4, yOffset)
            btn:SetPoint("TOPRIGHT", -4, yOffset)

            local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("LEFT", 4, 0)
            label:SetText(opt[2])
            label:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            btn:SetScript("OnEnter", function() label:SetTextColor(1, 1, 1) end)
            btn:SetScript("OnLeave", function() label:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b) end)
            btn:SetScript("OnClick", function()
                GetAuraDesignerDB().spec = opt[1]
                specMenu:Hide()
                UpdateSpecText()
                selectedAura = nil
                DF:AuraDesigner_RefreshPage()
            end)

            yOffset = yOffset - 20
        end
        specMenu:SetHeight(-yOffset + 4)
    end

    specBtn:SetScript("OnClick", function()
        if specMenu:IsShown() then
            specMenu:Hide()
        else
            BuildSpecMenu()
            specMenu:Show()
        end
    end)

    banner.UpdateSpecText = UpdateSpecText
    banner.checkbox = cb
    return banner
end

-- ============================================================
-- ATTRIBUTION ROW
-- ============================================================

local function CreateAttributionRow(parent, yOffset)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(20)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yOffset)

    local available = Adapter:IsAvailable()
    local sourceName = Adapter:GetSourceName()

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("LEFT", 4, 0)
    icon:SetSize(14, 14)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", icon, "RIGHT", 4, 0)

    if available then
        icon:SetColorTexture(0.3, 0.8, 0.3, 1)
        label:SetText("Data source: " .. (sourceName or "Unknown"))
        label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    else
        icon:SetColorTexture(0.8, 0.3, 0.3, 1)
        label:SetText("Harrek's Advanced Raid Frames not detected")
        label:SetTextColor(0.8, 0.6, 0.3, 1)
    end

    return row
end

-- ============================================================
-- FRAME PREVIEW (placeholder for Sub-Step 4)
-- ============================================================

local function CreateFramePreview(parent, yOffset)
    local preview = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    preview:SetHeight(80)
    preview:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    preview:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -290, yOffset)
    ApplyBackdrop(preview, {r = 0.10, g = 0.10, b = 0.10, a = 1}, C_BORDER)

    local placeholder = preview:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    placeholder:SetPoint("CENTER", 0, 0)
    placeholder:SetText("Frame Preview")
    placeholder:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.5)

    return preview
end

-- ============================================================
-- ACTIVE EFFECTS STRIP (placeholder for Sub-Step 4)
-- ============================================================

local function CreateActiveEffectsStrip(parent, yOffset)
    local strip = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    strip:SetHeight(82)
    strip:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    strip:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -290, yOffset)
    ApplyBackdrop(strip, {r = 0.10, g = 0.10, b = 0.10, a = 1}, C_BORDER)

    strip.placeholder = strip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    strip.placeholder:SetPoint("CENTER", 0, 0)
    strip.placeholder:SetText("Enable effects on an aura to see them here")
    strip.placeholder:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.5)

    return strip
end

-- ============================================================
-- ACTIVE EFFECTS STRIP REFRESH
-- ============================================================
local activeEffectEntries = {}

local function RefreshActiveEffectsStrip()
    if not activeEffectsStrip then return end

    -- Clear old entries
    for _, entry in ipairs(activeEffectEntries) do
        entry:Hide()
    end
    wipe(activeEffectEntries)

    local adDB = GetAuraDesignerDB()
    local spec = ResolveSpec()
    if not spec then return end

    local auraList = Adapter:GetTrackableAuras(spec)
    if not auraList then return end

    -- Build a lookup for aura info
    local auraInfoLookup = {}
    for _, info in ipairs(auraList) do
        auraInfoLookup[info.name] = info
    end

    -- Collect all active effects
    local effects = {}
    for auraName, auraCfg in pairs(adDB.auras) do
        local info = auraInfoLookup[auraName]
        if info then
            for _, typeDef in ipairs(INDICATOR_TYPES) do
                if auraCfg[typeDef.key] then
                    tinsert(effects, {
                        auraName = auraName,
                        display = info.display,
                        color = info.color,
                        typeKey = typeDef.key,
                        typeLabel = typeDef.label,
                    })
                end
            end
        end
    end

    if #effects == 0 then
        activeEffectsStrip.placeholder:Show()
        return
    end
    activeEffectsStrip.placeholder:Hide()

    local xOffset = 4
    for _, effect in ipairs(effects) do
        local entry = CreateFrame("Button", nil, activeEffectsStrip, "BackdropTemplate")
        entry:SetSize(64, 74)
        entry:SetPoint("LEFT", activeEffectsStrip, "LEFT", xOffset, 0)
        ApplyBackdrop(entry, C_ELEMENT, {r = 0.30, g = 0.30, b = 0.30, a = 0.5})

        -- X button to disable
        local xBtn = CreateFrame("Button", nil, entry)
        xBtn:SetSize(14, 14)
        xBtn:SetPoint("TOPRIGHT", -1, -1)
        local xText = xBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        xText:SetAllPoints()
        xText:SetText("x")
        xText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        xBtn:SetScript("OnEnter", function() xText:SetTextColor(1, 0.3, 0.3) end)
        xBtn:SetScript("OnLeave", function() xText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b) end)
        xBtn:SetScript("OnClick", function()
            local cfg = adDB.auras[effect.auraName]
            if cfg then
                cfg[effect.typeKey] = nil
                DF:AuraDesigner_RefreshPage()
            end
        end)

        -- Spell name
        local name = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("TOP", 0, -3)
        name:SetWidth(60)
        name:SetMaxLines(1)
        name:SetText(effect.display)
        name:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        name:SetJustifyH("CENTER")

        -- Icon placeholder
        local iconBg = entry:CreateTexture(nil, "ARTWORK")
        iconBg:SetPoint("CENTER", 0, 2)
        iconBg:SetSize(28, 28)
        iconBg:SetColorTexture(effect.color[1] * 0.4, effect.color[2] * 0.4, effect.color[3] * 0.4, 1)

        local letter = entry:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        letter:SetPoint("CENTER", iconBg, "CENTER", 0, 0)
        letter:SetText(effect.display:sub(1, 1))
        letter:SetTextColor(effect.color[1], effect.color[2], effect.color[3])

        -- Type label
        local typeLabel = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        typeLabel:SetPoint("BOTTOM", 0, 3)
        typeLabel:SetWidth(60)
        typeLabel:SetMaxLines(1)
        local tc = GetThemeColor()
        typeLabel:SetText(effect.typeLabel:upper())
        typeLabel:SetTextColor(tc.r, tc.g, tc.b)

        -- Click to select aura
        entry:SetScript("OnClick", function()
            selectedAura = effect.auraName
            DF:AuraDesigner_RefreshPage()
        end)
        entry:SetScript("OnEnter", function(self)
            self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
        end)
        entry:SetScript("OnLeave", function(self)
            self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        end)

        tinsert(activeEffectEntries, entry)
        xOffset = xOffset + 68
    end
end

-- ============================================================
-- MAIN PAGE BUILD
-- ============================================================

function DF.BuildAuraDesignerPage(guiRef, pageRef, dbRef)
    GUI = guiRef
    page = pageRef
    db = dbRef
    Adapter = DF.AuraDesigner.Adapter

    local parent = page.child

    -- ========================================
    -- MAIN FRAME
    -- ========================================
    mainFrame = CreateFrame("Frame", nil, parent)
    mainFrame:SetAllPoints()

    local yPos = 0

    -- ========================================
    -- ENABLE BANNER
    -- ========================================
    enableBanner = CreateEnableBanner(mainFrame)
    enableBanner:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, yPos)
    enableBanner:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, yPos)
    enableBanner.UpdateSpecText()
    yPos = yPos - 40

    -- ========================================
    -- ATTRIBUTION ROW
    -- ========================================
    attributionRow = CreateAttributionRow(mainFrame, yPos)
    yPos = yPos - 24

    -- ========================================
    -- TILE STRIP
    -- ========================================
    tileStrip = CreateFrame("ScrollFrame", nil, mainFrame)
    tileStrip:SetHeight(90)
    tileStrip:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, yPos)
    tileStrip:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, yPos)
    tileStrip:EnableMouseWheel(true)

    tileStripContent = CreateFrame("Frame", nil, tileStrip)
    tileStripContent:SetHeight(90)
    tileStripContent:SetWidth(800)
    tileStrip:SetScrollChild(tileStripContent)

    tileStrip:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetHorizontalScroll()
        local maxScroll = max(0, tileStripContent:GetWidth() - self:GetWidth())
        local newScroll = max(0, min(maxScroll, current - (delta * 68)))
        self:SetHorizontalScroll(newScroll)
    end)

    local tileStripBg = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    tileStripBg:SetAllPoints(tileStrip)
    tileStripBg:SetFrameLevel(mainFrame:GetFrameLevel())
    ApplyBackdrop(tileStripBg, {r = 0.10, g = 0.10, b = 0.10, a = 0.5}, {r = 0.20, g = 0.20, b = 0.20, a = 0.5})

    yPos = yPos - 94

    -- ========================================
    -- FRAME PREVIEW
    -- ========================================
    framePreview = CreateFramePreview(mainFrame, yPos)
    yPos = yPos - 84

    -- ========================================
    -- ACTIVE EFFECTS STRIP
    -- ========================================
    activeEffectsStrip = CreateActiveEffectsStrip(mainFrame, yPos)

    -- ========================================
    -- RIGHT PANEL (fixed 280px)
    -- ========================================
    rightPanel = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    rightPanel:SetWidth(280)
    rightPanel:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -64)
    rightPanel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 0)
    ApplyBackdrop(rightPanel, {r = 0.10, g = 0.10, b = 0.10, a = 1}, {r = 0.20, g = 0.20, b = 0.20, a = 0.5})

    rightScrollFrame = CreateFrame("ScrollFrame", nil, rightPanel, "UIPanelScrollFrameTemplate")
    rightScrollFrame:SetPoint("TOPLEFT", 0, 0)
    rightScrollFrame:SetPoint("BOTTOMRIGHT", -22, 0)

    rightScrollChild = CreateFrame("Frame", nil, rightScrollFrame)
    rightScrollChild:SetWidth(258)
    rightScrollChild:SetHeight(800)
    rightScrollFrame:SetScrollChild(rightScrollChild)

    local scrollBar = rightScrollFrame.ScrollBar
    if scrollBar then
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOPLEFT", rightScrollFrame, "TOPRIGHT", 2, -16)
        scrollBar:SetPoint("BOTTOMLEFT", rightScrollFrame, "BOTTOMRIGHT", 2, 16)
    end

    -- ========================================
    -- POPULATE
    -- ========================================
    PopulateTileStrip()
    RefreshRightPanel()
    RefreshActiveEffectsStrip()
end

-- ============================================================
-- REFRESH
-- ============================================================

function DF:AuraDesigner_RefreshPage()
    if not mainFrame then return end

    -- Refresh tile states
    for _, tile in ipairs(activeTiles) do
        tile:SetSelected(selectedAura == tile.auraName)
        tile:UpdateBadge()
        if selectedAura == tile.auraName then
            tile:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 1)
        else
            tile:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        end
    end

    -- Check if spec changed
    local currentSpec = ResolveSpec()
    if currentSpec ~= selectedSpec then
        selectedAura = nil
        PopulateTileStrip()
    end

    -- Refresh panels
    RefreshRightPanel()
    RefreshActiveEffectsStrip()

    -- Update enable state
    if enableBanner then
        enableBanner.checkbox:SetChecked(GetAuraDesignerDB().enabled)
        enableBanner.UpdateSpecText()
    end

    -- Tab disable logic: grey out Buffs + My Buff Indicators when enabled
    if GUI and GUI.Tabs then
        local adEnabled = GetAuraDesignerDB().enabled
        local buffsTab = GUI.Tabs["auras_buffs"]
        local myBuffTab = GUI.Tabs["auras_mybuffindicators"]
        if buffsTab then
            buffsTab.disabled = adEnabled
            if adEnabled then
                buffsTab.Text:SetTextColor(0.2, 0.2, 0.2)
                buffsTab.Text:SetAlpha(0.8)
            else
                buffsTab.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                buffsTab.Text:SetAlpha(1)
            end
        end
        if myBuffTab then
            myBuffTab.disabled = adEnabled
            if adEnabled then
                myBuffTab.Text:SetTextColor(0.2, 0.2, 0.2)
                myBuffTab.Text:SetAlpha(0.8)
            else
                myBuffTab.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                myBuffTab.Text:SetAlpha(1)
            end
        end
    end
end
