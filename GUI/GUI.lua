local addonName, DF = ...
local GUI = {}
DF.GUI = GUI

-- =========================================================================
-- MODERN UI CONSTANTS & STYLING (Matching Original v2.3.8)
-- =========================================================================

local C_BACKGROUND = {r = 0.08, g = 0.08, b = 0.08, a = 0.95}  -- Dark charcoal
local C_PANEL      = {r = 0.12, g = 0.12, b = 0.12, a = 1}     -- Slightly lighter
local C_ELEMENT    = {r = 0.18, g = 0.18, b = 0.18, a = 1}     -- Element backgrounds
local C_BORDER     = {r = 0.25, g = 0.25, b = 0.25, a = 1}     -- Subtle borders
local C_ACCENT     = {r = 0.45, g = 0.45, b = 0.95, a = 1}       -- Party Purple-Blue
local C_RAID       = {r = 1.0, g = 0.5, b = 0.2, a = 1}        -- Raid Orange
local C_HOVER      = {r = 0.22, g = 0.22, b = 0.22, a = 1}
local C_TEXT       = {r = 0.9, g = 0.9, b = 0.9, a = 1}
local C_TEXT_DIM   = {r = 0.6, g = 0.6, b = 0.6, a = 1}

DF.SectionRegistry = DF.SectionRegistry or {}

-- Track selected mode
GUI.SelectedMode = "party"

-- Track currently open dropdown menu (only one can be open at a time)
local currentOpenDropdown = nil

-- Close any currently open dropdown
local function CloseOpenDropdown()
    if currentOpenDropdown and currentOpenDropdown:IsShown() then
        currentOpenDropdown:Hide()
    end
    currentOpenDropdown = nil
end

-- Set the currently open dropdown
local function SetOpenDropdown(menuFrame)
    CloseOpenDropdown()
    currentOpenDropdown = menuFrame
end

-- Helper to get current theme color
local function GetThemeColor()
    if GUI.SelectedMode == "raid" then return C_RAID else return C_ACCENT end
end
GUI.GetThemeColor = GetThemeColor

-- Helper to create element backdrop (for dropdowns, sliders, inputs)
local function CreateElementBackdrop(frame)
    if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, C_ELEMENT.a)
    frame:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
end

-- Helper to create panel backdrop (for main panels)
local function CreatePanelBackdrop(frame)
    if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b, C_BACKGROUND.a)
    frame:SetBackdropBorderColor(0, 0, 0, 1)
end
GUI.CreatePanelBackdrop = CreatePanelBackdrop

-- =========================================================================
-- WIDGET FACTORY
-- =========================================================================

function GUI:CreateHeader(parent, text)
    -- Use a frame container so we can position text at bottom (padding above)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(200, 25)
    container:Show()
    
    local h = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 2)
    h:SetText(text)
    local c = GetThemeColor()
    h:SetTextColor(c.r, c.g, c.b)
    h:SetJustifyH("LEFT")
    h.UpdateTheme = function() local nc = GetThemeColor() h:SetTextColor(nc.r, nc.g, nc.b) end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, h)
    
    -- Store text reference
    container.text = h
    
    -- Forward IsShown to ensure layout works
    container.GetText = function() return h:GetText() end
    
    -- SEARCH: Track current section
    if DF.Search then
        DF.Search:SetCurrentSection(text)
    end
    
    return container
end

-- Collapsible section for grouping related settings
function GUI:CreateCollapsibleSection(parent, text, defaultExpanded, width)
    local section = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    section:SetSize(width or 500, 28)  -- Header height
    section.expanded = defaultExpanded ~= false  -- Default to expanded
    section.sectionChildren = {}
    section.paddingAfter = 8  -- Padding space after header before first child
    
    -- Header bar with background
    if not section.SetBackdrop then Mixin(section, BackdropTemplateMixin) end
    section:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    section:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.8)
    section:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    
    -- Click area
    local clickArea = CreateFrame("Button", nil, section)
    clickArea:SetAllPoints()
    clickArea:EnableMouse(true)
    
    -- Expand/collapse arrow icon
    section.arrow = section:CreateTexture(nil, "OVERLAY")
    section.arrow:SetPoint("LEFT", 8, 0)
    section.arrow:SetSize(12, 12)
    if section.expanded then
        section.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    else
        section.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
    end
    section.arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Section title
    section.title = section:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    section.title:SetPoint("LEFT", 26, 0)
    section.title:SetText(text)
    local c = GetThemeColor()
    section.title:SetTextColor(c.r, c.g, c.b)
    section.title.UpdateTheme = function()
        local nc = GetThemeColor()
        section.title:SetTextColor(nc.r, nc.g, nc.b)
    end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, section.title)
    
    -- SEARCH: Track current section
    if DF.Search then
        DF.Search:SetCurrentSection(text)
    end
    
    -- Toggle function
    section.Toggle = function(self)
        self.expanded = not self.expanded
        if self.expanded then
            self.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
        else
            self.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
        end
        
        -- Trigger layout refresh (RefreshStates handles show/hide based on expanded state)
        if parent.RefreshStates then
            parent:RefreshStates()
        end
    end
    
    -- Register child widgets to this section
    section.RegisterChild = function(self, widget)
        table.insert(self.sectionChildren, widget)
        widget.parentSection = self
        
        -- Use a marker to check section state during RefreshStates
        widget.collapsibleSection = self
    end
    
    -- Hover effects
    clickArea:SetScript("OnEnter", function()
        section:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 0.8)
    end)
    clickArea:SetScript("OnLeave", function()
        section:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.8)
    end)
    clickArea:SetScript("OnClick", function()
        section:Toggle()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    
    return section
end

-- =========================================================================
-- SETTINGS GROUP - Visible container that groups related settings together
-- Ensures settings never get split across columns
-- =========================================================================
function GUI:CreateSettingsGroup(parent, width)
    local group = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    group:SetSize(width or 280, 10)  -- Height will be calculated dynamically
    group.groupChildren = {}
    group.isSettingsGroup = true
    
    -- Visual styling - subtle background and border
    local padding = 10
    local margin = 10  -- Space between groups
    group.padding = padding
    group.margin = margin
    
    if not group.SetBackdrop then Mixin(group, BackdropTemplateMixin) end
    group:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    group:SetBackdropColor(1, 1, 1, 0.03)  -- Very subtle white background (3% opacity)
    group:SetBackdropBorderColor(1, 1, 1, 0.08)  -- Subtle white border (8% opacity)
    
    -- Add a widget to this group
    group.AddWidget = function(self, widget, height)
        widget:SetParent(self)
        table.insert(self.groupChildren, {
            widget = widget,
            height = height or 55,
        })
        -- Mark widget as belonging to this group
        widget.settingsGroup = self
        return widget
    end
    
    -- Calculate total height based on visible children and layout them
    group.LayoutChildren = function(self)
        local y = -self.padding  -- Start with top padding
        local visibleCount = 0
        local innerWidth = self:GetWidth() - (self.padding * 2)  -- Width for child widgets
        
        for _, entry in ipairs(self.groupChildren) do
            local widget = entry.widget
            local height = entry.height
            
            -- Check if widget should be visible
            local shouldShow = true
            if widget.hideOn then
                local db = DF.db[GUI.SelectedMode]
                if db and widget.hideOn(db) then
                    shouldShow = false
                end
            end
            
            if shouldShow then
                widget:ClearAllPoints()
                widget:SetPoint("TOPLEFT", self, "TOPLEFT", self.padding, y)
                -- Set width to fit within group padding
                widget:SetWidth(innerWidth)
                widget:Show()
                y = y - height
                visibleCount = visibleCount + 1
            else
                widget:Hide()
            end
        end
        
        -- Update group height (add padding at bottom)
        local totalHeight = math.abs(y) + self.padding
        if totalHeight < 1 then totalHeight = 1 end
        self:SetHeight(totalHeight)
        -- Add margin to calculated height for spacing between groups
        self.calculatedHeight = totalHeight + self.margin
        
        return self.calculatedHeight
    end
    
    -- Process disableOn for children
    group.RefreshChildStates = function(self)
        local db = DF.db[GUI.SelectedMode]
        if not db then return end
        
        for _, entry in ipairs(self.groupChildren) do
            local widget = entry.widget
            if widget.disableOn then
                local shouldDisable = widget.disableOn(db)
                if widget.SetEnabled then
                    widget:SetEnabled(not shouldDisable)
                end
            end
        end
    end
    
    return group
end

function GUI:CreateLabel(parent, text, width, color)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 380, 40)
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, -5)
    lbl:SetWidth(width or 380)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(text)
    
    if color then
        lbl:SetTextColor(color.r, color.g, color.b, color.a or 1)
    else
        lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
    end
    
    frame.SetText = function(self, newText) lbl:SetText(newText) end
    return frame
end

function GUI:CreateWarningBox(parent, text, width, height)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(width or 280, height or 70)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0.4, 0.1, 0.1, 0.7)  -- Dark red background
    frame:SetBackdropBorderColor(0.8, 0.2, 0.2, 1)  -- Red border
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 8, -8)
    lbl:SetPoint("BOTTOMRIGHT", -8, 8)
    lbl:SetJustifyH("LEFT")
    lbl:SetJustifyV("TOP")
    lbl:SetWordWrap(true)
    lbl:SetNonSpaceWrap(true)
    lbl:SetText(text)
    lbl:SetTextColor(1, 0.8, 0.8, 1)  -- Light red/pink text
    
    frame.SetText = function(self, newText) lbl:SetText(newText) end
    return frame
end

function GUI:CreateButton(parent, text, width, height, func)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width or 120, height or 22)
    CreateElementBackdrop(btn)
    
    btn.Text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.Text:SetPoint("CENTER")
    btn.Text:SetText(text)
    btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    btn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then
            self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if self:IsEnabled() then
            if self.isTab and self.isActive then
                self:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 1)
            else
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            end
        end
    end)
    btn:SetScript("OnClick", function(self)
        if func then func(self) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    return btn
end

-- Creates a button with an icon and text
-- iconName is the name of the icon file (without path/extension)
-- iconSize is optional (defaults to 16)
function GUI:CreateIconButton(parent, iconName, text, width, height, func, iconSize)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width or 120, height or 22)
    CreateElementBackdrop(btn)
    
    local iSize = iconSize or 16
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("LEFT", 8, 0)
    icon:SetSize(iSize, iSize)
    icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. iconName)
    icon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    btn.Icon = icon
    
    btn.Text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.Text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    btn.Text:SetText(text)
    btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    btn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then
            self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if self:IsEnabled() then
            self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        end
    end)
    btn:SetScript("OnClick", function(self)
        if func then func(self) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    return btn
end

-- Creates a \"See Also:\" section with clickable links to related pages
-- links = { {pageId = \"display_tooltips\", label = \"Tooltips\"}, ... }
function GUI:CreateSeeAlso(parent, links)
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetHeight(32)
    container:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    container:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
    container:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
    
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 8, -10)
    label:SetText("See Also:")
    label:SetTextColor(0.7, 0.7, 0.7)
    
    local linkButtons = {}
    local separators = {}
    
    for i, linkData in ipairs(links) do
        local link = CreateFrame("Button", nil, container)
        link:SetHeight(16)
        
        local linkText = link:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        linkText:SetPoint("TOPLEFT", 0, -1)
        linkText:SetText(linkData.label)
        local c = GetThemeColor()
        linkText:SetTextColor(c.r, c.g, c.b)
        link.text = linkText
        link.textWidth = linkText:GetStringWidth() + 4
        link:SetWidth(link.textWidth)
        
        link:SetScript("OnEnter", function(self)
            linkText:SetTextColor(1, 1, 1)
        end)
        link:SetScript("OnLeave", function(self)
            linkText:SetTextColor(c.r, c.g, c.b)
        end)
        link:SetScript("OnClick", function()
            if GUI.SelectTab then
                GUI.SelectTab(linkData.pageId)
            end
        end)
        
        table.insert(linkButtons, link)
        
        -- Create separator (hidden by default, shown as needed)
        if i < #links then
            local sep = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            sep:SetText("•")
            sep:SetTextColor(0.5, 0.5, 0.5)
            table.insert(separators, sep)
        end
    end
    
    -- Layout function that handles wrapping
    local function LayoutLinks()
        local containerWidth = container:GetWidth()
        if containerWidth < 50 then return end  -- Not sized yet
        
        local labelWidth = label:GetStringWidth() + 16
        local firstLinkX = labelWidth  -- Where first link starts
        local xOffset = labelWidth
        local yOffset = -9
        local lineHeight = 18
        local maxX = containerWidth - 10
        local rowCount = 1
        
        -- First pass: determine which links are on which row
        local linkRows = {}
        local tempX = labelWidth
        local currentRow = 1
        
        for i, link in ipairs(linkButtons) do
            local linkWidth = link.textWidth
            local sepWidth = (i < #linkButtons) and 14 or 0
            
            -- Check if we need to wrap
            if tempX + linkWidth > maxX and tempX > labelWidth then
                currentRow = currentRow + 1
                tempX = firstLinkX
            end
            
            linkRows[i] = currentRow
            tempX = tempX + linkWidth + sepWidth
        end
        
        rowCount = currentRow
        
        -- Second pass: position elements
        xOffset = labelWidth
        local lastRowForLink = 1
        
        for i, link in ipairs(linkButtons) do
            local linkWidth = link.textWidth
            
            -- Check if we need to wrap to new line
            if linkRows[i] > lastRowForLink then
                xOffset = firstLinkX
                yOffset = yOffset - lineHeight
                lastRowForLink = linkRows[i]
            end
            
            link:ClearAllPoints()
            link:SetPoint("TOPLEFT", container, "TOPLEFT", xOffset, yOffset)
            
            xOffset = xOffset + linkWidth + 2
            
            -- Position separator only if next link is on same row
            if separators[i] then
                if linkRows[i + 1] == linkRows[i] then
                    separators[i]:ClearAllPoints()
                    separators[i]:SetPoint("TOPLEFT", container, "TOPLEFT", xOffset, yOffset - 1)
                    separators[i]:Show()
                    xOffset = xOffset + 12
                else
                    separators[i]:Hide()
                end
            end
        end
        
        -- Adjust container height based on rows
        local newHeight = 10 + (rowCount * lineHeight)
        container:SetHeight(newHeight)
        container.layoutHeight = newHeight + 5
    end
    
    container:SetScript("OnSizeChanged", LayoutLinks)
    
    -- Initial layout after a frame (to let width be set)
    C_Timer.After(0, LayoutLinks)
    
    return container
end

-- =========================================================================
-- OVERRIDE INDICATORS FOR AUTO PROFILES
-- =========================================================================
-- Helper function to add override indicators (star, reset button, global value text)
-- to widget containers when editing an auto profile

-- Debug flag - when true, shows all reset buttons regardless of override state
local overrideDebugMode = false

-- Track all widgets with override indicators for refresh
local overrideWidgets = {}

-- Function to check if debug mode is active (exposed for other files)
local function IsOverrideDebugMode()
    return overrideDebugMode
end
GUI.IsOverrideDebugMode = IsOverrideDebugMode

-- Function to refresh all override indicators
local function RefreshAllOverrideIndicators()
    for _, widget in ipairs(overrideWidgets) do
        if widget and widget.UpdateOverrideIndicators then
            widget:UpdateOverrideIndicators()
        end
    end
    -- Also refresh position override indicator
    if GUI.UpdatePositionOverrideIndicator then
        GUI.UpdatePositionOverrideIndicator()
    end
    -- Refresh tab override stars (auto-profiles)
    if DF.AutoProfilesUI and DF.AutoProfilesUI.RefreshTabOverrideStars then
        DF.AutoProfilesUI:RefreshTabOverrideStars()
    end
end
GUI.RefreshAllOverrideIndicators = RefreshAllOverrideIndicators

-- Allow other files to register widgets with override indicators
function GUI.RegisterOverrideWidget(widget)
    table.insert(overrideWidgets, widget)
end

-- Slash command to toggle debug mode
SLASH_DFOVERRIDEDEBUG1 = "/dfoverridedebug"
SlashCmdList["DFOVERRIDEDEBUG"] = function()
    overrideDebugMode = not overrideDebugMode
    print("|cff00ff00DandersFrames:|r Override debug mode " .. (overrideDebugMode and "ENABLED" or "DISABLED"))
    -- Refresh all override indicators
    RefreshAllOverrideIndicators()
    -- Also update position panel if open
    if DF.positionPanel and DF.positionPanel.UpdatePositionOverride then
        DF.positionPanel.UpdatePositionOverride()
    end
end

local function AddOverrideIndicators(container, lbl, dbKey, onReset, verticalOffset)
    verticalOffset = verticalOffset or 0
    
    -- Reset button (shown when overridden) - positioned at top right
    local resetBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    resetBtn:SetSize(18, 18)
    resetBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, verticalOffset)
    resetBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    resetBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    resetBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    resetBtn:Hide()
    
    local resetIcon = resetBtn:CreateTexture(nil, "OVERLAY")
    resetIcon:SetPoint("CENTER")
    resetIcon:SetSize(12, 12)
    resetIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh")
    resetIcon:SetVertexColor(0.6, 0.6, 0.6)
    
    resetBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(1, 0.8, 0.2, 1)
        resetIcon:SetVertexColor(1, 0.8, 0.2)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Reset to Global")
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        resetIcon:SetVertexColor(0.6, 0.6, 0.6)
        GameTooltip:Hide()
    end)
    resetBtn:SetScript("OnClick", function()
        if onReset then
            onReset()
        end
    end)
    container.overrideResetBtn = resetBtn
    
    -- Override icon (shown when overridden) - positioned LEFT of reset button, yellow/gold color
    local starBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    starBtn:SetSize(18, 18)
    starBtn:SetPoint("RIGHT", resetBtn, "LEFT", -2, 0)
    starBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    starBtn:SetBackdropColor(0, 0, 0, 0)
    starBtn:SetBackdropBorderColor(0, 0, 0, 0)
    starBtn:Hide()
    local starIcon = starBtn:CreateTexture(nil, "OVERLAY")
    starIcon:SetSize(12, 12)
    starIcon:SetPoint("CENTER")
    starIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\star")
    starIcon:SetVertexColor(1, 0.8, 0.2)
    starBtn:SetScript("OnEnter", function(s)
        if s.tooltipText then
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetText(s.tooltipText)
            if s.tooltipSubText then
                GameTooltip:AddLine(s.tooltipSubText, 1, 1, 1, true)
            end
            GameTooltip:Show()
        end
    end)
    starBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    container.overrideStar = starBtn
    
    -- Global value text (shown when in edit mode) - positioned inline after label
    local globalText = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    globalText:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
    globalText:SetTextColor(0.4, 0.4, 0.4)
    globalText:Hide()
    container.overrideGlobalText = globalText
    
    -- Checkmark icon for matching global value
    local checkIcon = container:CreateTexture(nil, "OVERLAY")
    checkIcon:SetSize(8, 8)
    checkIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
    checkIcon:SetVertexColor(0.3, 0.7, 0.3)
    checkIcon:Hide()
    container.overrideCheckIcon = checkIcon
    
    -- Store dbKey for reference
    container.overrideDbKey = dbKey
    
    -- Function to update override indicators
    container.UpdateOverrideIndicators = function(self, currentValue)
        -- Debug mode shows all buttons
        if overrideDebugMode then
            self.overrideStar:Show()
            self.overrideResetBtn:Show()
            self.overrideGlobalText:SetText("(debug)")
            self.overrideGlobalText:SetTextColor(1, 0.8, 0.2)  -- Yellow for visibility
            self.overrideGlobalText:Show()
            self.overrideCheckIcon:Hide()
            return
        end
        
        -- Only show when in raid mode
        local GUI = DF.GUI
        if not GUI or GUI.SelectedMode ~= "raid" then
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
            self.overrideGlobalText:Hide()
            self.overrideCheckIcon:Hide()
            return
        end

        local AutoProfilesUI = DF.AutoProfilesUI
        local isEditing = AutoProfilesUI and AutoProfilesUI:IsEditing()
        local isRuntimeOverridden = AutoProfilesUI and AutoProfilesUI:IsOverriddenByRuntime(dbKey)

        -- Hide everything if not editing AND not runtime-overridden
        if not isEditing and not isRuntimeOverridden then
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
            self.overrideGlobalText:Hide()
            self.overrideCheckIcon:Hide()
            return
        end

        -- Runtime override mode: show star + global value, but no reset button
        if isRuntimeOverridden and not isEditing then
            self.overrideStar.tooltipText = "Overridden by Auto Layout"
            self.overrideStar.tooltipSubText = "This setting is being overridden by the active auto layout profile. To change it, edit the profile in the Auto Layouts tab."
            self.overrideStar:Show()
            self.overrideResetBtn:Hide()  -- Can't reset runtime overrides from controls
            self.overrideCheckIcon:Hide()

            local globalValue = AutoProfilesUI:GetRuntimeGlobalValue(dbKey)

            -- Format global value for display
            local globalDisplay
            if type(globalValue) == "boolean" then
                globalDisplay = globalValue and "Yes" or "No"
            elseif type(globalValue) == "number" then
                if globalValue == math.floor(globalValue) then
                    globalDisplay = tostring(globalValue)
                else
                    globalDisplay = string.format("%.2f", globalValue)
                end
            elseif type(globalValue) == "table" then
                if globalValue.r then
                    globalDisplay = "Color"
                else
                    globalDisplay = "..."
                end
            else
                globalDisplay = tostring(globalValue or "None")
            end

            self.overrideGlobalText:SetText("(Global: " .. globalDisplay .. ")")
            self.overrideGlobalText:ClearAllPoints()
            self.overrideGlobalText:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
            self.overrideGlobalText:SetTextColor(0.5, 0.5, 0.5)
            self.overrideGlobalText:Show()
            return
        end

        -- Editing mode: existing behavior
        -- Check if setting is overridden
        local isOverridden = AutoProfilesUI:IsSettingOverridden(dbKey)
        local globalValue = AutoProfilesUI:GetGlobalValue(dbKey)

        -- Show/hide star and reset button
        if isOverridden then
            self.overrideStar.tooltipText = "Overridden in this layout"
            self.overrideStar.tooltipSubText = "This setting differs from the global profile value. Click the reset button to revert."
            self.overrideStar:Show()
            self.overrideResetBtn:Show()
        else
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
        end

        -- Format global value for display
        local globalDisplay
        if type(globalValue) == "boolean" then
            globalDisplay = globalValue and "Yes" or "No"
        elseif type(globalValue) == "number" then
            if globalValue == math.floor(globalValue) then
                globalDisplay = tostring(globalValue)
            else
                globalDisplay = string.format("%.2f", globalValue)
            end
        elseif type(globalValue) == "table" then
            -- Color table
            if globalValue.r then
                globalDisplay = "Color"
            else
                globalDisplay = "..."
            end
        else
            globalDisplay = tostring(globalValue or "None")
        end

        -- Show global value inline with label
        self.overrideGlobalText:SetText("(Global: " .. globalDisplay .. ")")
        self.overrideGlobalText:ClearAllPoints()
        self.overrideGlobalText:SetPoint("LEFT", lbl, "RIGHT", 4, 0)

        if isOverridden then
            self.overrideGlobalText:SetTextColor(0.5, 0.5, 0.5)
            self.overrideCheckIcon:Hide()
        else
            self.overrideGlobalText:SetTextColor(0.3, 0.6, 0.3)
            -- Position check icon after text
            self.overrideCheckIcon:ClearAllPoints()
            self.overrideCheckIcon:SetPoint("LEFT", self.overrideGlobalText, "RIGHT", 2, 0)
            self.overrideCheckIcon:Show()
        end
        self.overrideGlobalText:Show()
    end
    
    -- Register this widget for refresh tracking
    table.insert(overrideWidgets, container)
    
    return container
end

-- Override indicators for order list controls (drag lists)
-- These don't have traditional labels, so we use a compact star + reset + "Modified" badge
local function AddOrderListOverrideIndicators(container, dbKey, onReset)
    -- Reset button (shown when overridden) - positioned at top right
    local resetBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    resetBtn:SetSize(18, 18)
    resetBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 14)
    resetBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    resetBtn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    resetBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    resetBtn:Hide()
    
    local resetIcon = resetBtn:CreateTexture(nil, "OVERLAY")
    resetIcon:SetPoint("CENTER")
    resetIcon:SetSize(12, 12)
    resetIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh")
    resetIcon:SetVertexColor(0.6, 0.6, 0.6)
    
    resetBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(1, 0.8, 0.2, 1)
        resetIcon:SetVertexColor(1, 0.8, 0.2)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Reset to Global Order")
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        resetIcon:SetVertexColor(0.6, 0.6, 0.6)
        GameTooltip:Hide()
    end)
    resetBtn:SetScript("OnClick", function()
        if onReset then onReset() end
    end)
    container.overrideResetBtn = resetBtn
    
    -- Star icon to the left of reset button (Button for tooltip support)
    local starBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    starBtn:SetSize(18, 18)
    starBtn:SetPoint("RIGHT", resetBtn, "LEFT", -2, 0)
    starBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    starBtn:SetBackdropColor(0, 0, 0, 0)
    starBtn:SetBackdropBorderColor(0, 0, 0, 0)
    starBtn:Hide()
    local starIcon = starBtn:CreateTexture(nil, "OVERLAY")
    starIcon:SetSize(12, 12)
    starIcon:SetPoint("CENTER")
    starIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\star")
    starIcon:SetVertexColor(1, 0.8, 0.2)
    starBtn:SetScript("OnEnter", function(s)
        if s.tooltipText then
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetText(s.tooltipText)
            if s.tooltipSubText then
                GameTooltip:AddLine(s.tooltipSubText, 1, 1, 1, true)
            end
            GameTooltip:Show()
        end
    end)
    starBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    container.overrideStar = starBtn
    
    -- "Modified" text to the left of star
    local modifiedText = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    modifiedText:SetPoint("RIGHT", starIcon, "LEFT", -2, 0)
    modifiedText:SetText("Modified")
    modifiedText:SetTextColor(1, 0.8, 0.2, 0.8)
    modifiedText:Hide()
    container.overrideModifiedText = modifiedText
    
    -- Store dbKey for reference
    container.overrideDbKey = dbKey
    
    -- Update function
    container.UpdateOverrideIndicators = function(self, currentValue)
        -- Debug mode
        if overrideDebugMode then
            self.overrideStar:Show()
            self.overrideResetBtn:Show()
            self.overrideModifiedText:SetText("Modified (debug)")
            self.overrideModifiedText:Show()
            return
        end
        
        -- Only show when in raid mode and editing
        local GUI = DF.GUI
        if not GUI or GUI.SelectedMode ~= "raid" then
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
            self.overrideModifiedText:Hide()
            return
        end
        
        local AutoProfilesUI = DF.AutoProfilesUI
        if not AutoProfilesUI or not AutoProfilesUI:IsEditing() then
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
            self.overrideModifiedText:Hide()
            return
        end
        
        local isOverridden = AutoProfilesUI:IsSettingOverridden(dbKey)
        
        if isOverridden then
            self.overrideStar.tooltipText = "Overridden in this layout"
            self.overrideStar.tooltipSubText = "This setting differs from the global profile value. Click the reset button to revert."
            self.overrideStar:Show()
            self.overrideResetBtn:Show()
            self.overrideModifiedText:Show()
        else
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
            self.overrideModifiedText:Hide()
        end
    end

    -- Register for refresh tracking
    table.insert(overrideWidgets, container)
end

function GUI:CreateCheckbox(parent, label, dbTable, dbKey, callback, customGet, customSet, overrideKey)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(220, 24)
    
    local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
    cb:SetSize(18, 18)
    cb:SetPoint("LEFT", 0, 0)
    CreateElementBackdrop(cb)
    
    -- Checkmark
    cb.Check = cb:CreateTexture(nil, "OVERLAY")
    cb.Check:SetTexture("Interface\\Buttons\\WHITE8x8")
    local c = GetThemeColor()
    cb.Check:SetVertexColor(c.r, c.g, c.b)
    cb.Check:SetPoint("CENTER")
    cb.Check:SetSize(10, 10)
    cb:SetCheckedTexture(cb.Check)
    
    -- Label
    local txt = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    txt:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    txt:SetText(label)
    txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Determine the key to use for override indicators
    local effectiveOverrideKey = overrideKey or dbKey
    
    -- Add override indicators if we have a key (either dbKey or overrideKey)
    if effectiveOverrideKey and type(effectiveOverrideKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(effectiveOverrideKey)
                -- Refresh to global value
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(effectiveOverrideKey)
                cb:SetChecked(globalVal)
                if dbTable and dbKey then
                    dbTable[dbKey] = globalVal
                elseif customSet then
                    customSet(globalVal)
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
                if callback then callback() end
            end
        end
        AddOverrideIndicators(container, txt, effectiveOverrideKey, onReset)
    end
    
    local function UpdateState()
        local val = false
        if customGet then val = customGet() elseif dbTable and dbKey then val = dbTable[dbKey] end
        cb:SetChecked(val)
        -- Update override indicators
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(val)
        end
    end
    
    cb.UpdateTheme = function()
        local nc = GetThemeColor()
        cb.Check:SetVertexColor(nc.r, nc.g, nc.b)
    end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, cb)
    
    container:SetScript("OnShow", UpdateState)
    cb:SetScript("OnClick", function(self)
        local val = self:GetChecked()
        if DF.debugEnabled then
            print("|cffff00ffDF DEBUG:|r Checkbox OnClick")
            print("  dbKey:", dbKey)
            print("  overrideKey:", overrideKey)
            print("  new value:", val)
        end

        -- Runtime override protection: redirect to baseline, skip refresh
        if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
           and DF.AutoProfilesUI:HandleRuntimeWrite(effectiveOverrideKey, val) then
            if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(val) end
            return
        end

        if customSet then customSet(val) elseif dbTable and dbKey then dbTable[dbKey] = val end

        -- If editing a profile, also set the override (use effectiveOverrideKey)
        if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and effectiveOverrideKey then
            DF.AutoProfilesUI:SetProfileSetting(effectiveOverrideKey, val)
        end
        
        -- Update override indicators
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(val)
        end
        
        if callback then 
            if DF.debugEnabled then print("  -> calling callback") end
            callback() 
        end
        if parent.RefreshStates then 
            if DF.debugEnabled then print("  -> calling RefreshStates") end
            parent:RefreshStates() 
        end
        if DF.debugEnabled then print("  -> calling DF:UpdateAll()") end
        DF:UpdateAll()
    end)
    
    container.SetEnabled = function(self, enabled)
        cb:SetEnabled(enabled)
        if enabled then
            txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            txt:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end
    
    UpdateState()
    
    -- SEARCH: Register this setting
    if DF.Search then
        local hasCustomGetSet = (customGet ~= nil or customSet ~= nil)
        if dbKey and type(dbKey) == "string" then
            container.searchEntry = DF.Search:RegisterCheckbox(label, dbKey, nil, false)
        elseif hasCustomGetSet then
            container.searchEntry = DF.Search:RegisterCheckbox(label, nil, nil, true)
        end
    end
    
    return container
end

function GUI:CreateInput(parent, label, width)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 180, 44)
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    local editbox = CreateFrame("EditBox", nil, frame)
    editbox:SetPoint("TOPLEFT", 0, -15)
    editbox:SetPoint("TOPRIGHT", 0, -15)
    editbox:SetHeight(24)
    if not editbox.SetBackdrop then Mixin(editbox, BackdropTemplateMixin) end
    editbox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    editbox:SetBackdropColor(0, 0, 0, 0.5)
    editbox:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    editbox:SetFontObject(GameFontHighlightSmall)
    editbox:SetTextInsets(5, 5, 0, 0)
    editbox:SetAutoFocus(false)
    editbox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editbox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    
    frame.EditBox = editbox
    return frame
end

-- CreateEditBox: Text input with db binding (for settings like custom text)
function GUI:CreateEditBox(parent, label, dbTable, dbKey, callback, width)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 180, 44)
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Add override indicators if dbKey is provided
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and dbKey then
                    dbTable[dbKey] = globalVal
                end
                if frame.EditBox then
                    frame.EditBox:SetText(globalVal or "")
                end
                if frame.UpdateOverrideIndicators then
                    frame:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
                if callback then callback() end
            end
        end
        AddOverrideIndicators(frame, lbl, dbKey, onReset, 6)
    end
    
    local editbox = CreateFrame("EditBox", nil, frame)
    editbox:SetPoint("TOPLEFT", 0, -15)
    editbox:SetPoint("TOPRIGHT", 0, -15)
    editbox:SetHeight(24)
    if not editbox.SetBackdrop then Mixin(editbox, BackdropTemplateMixin) end
    editbox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    editbox:SetBackdropColor(0, 0, 0, 0.5)
    editbox:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    editbox:SetFontObject(GameFontHighlightSmall)
    editbox:SetTextInsets(5, 5, 0, 0)
    editbox:SetAutoFocus(false)
    
    -- Set initial value from db
    if dbTable and dbKey then
        editbox:SetText(dbTable[dbKey] or "")
    end
    
    -- Save on enter or focus lost
    local function SaveValue()
        if dbTable and dbKey then
            local val = editbox:GetText()
            -- Runtime override protection
            if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
               and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, val) then
                if frame.UpdateOverrideIndicators then frame:UpdateOverrideIndicators(val) end
                return
            end
            dbTable[dbKey] = val
            -- Track override when editing a profile
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
                DF.AutoProfilesUI:SetProfileSetting(dbKey, val)
            end
            if frame.UpdateOverrideIndicators then
                frame:UpdateOverrideIndicators(val)
            end
            if callback then callback() end
        end
    end
    
    editbox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editbox:SetScript("OnEnterPressed", function(self)
        SaveValue()
        self:ClearFocus()
    end)
    editbox:SetScript("OnEditFocusLost", SaveValue)
    
    -- Refresh override indicators on show
    frame:SetScript("OnShow", function()
        if dbTable and dbKey then
            editbox:SetText(dbTable[dbKey] or "")
        end
        if frame.UpdateOverrideIndicators then
            frame:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
        end
    end)
    
    frame.EditBox = editbox
    return frame
end

function GUI:CreateSlider(parent, label, minVal, maxVal, step, dbTable, dbKey, callback, lightweightUpdate, usePreviewMode)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)
    
    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Add override indicators if dbKey is provided (for auto profiles)
    -- Use vertical offset of 6 to align with label row (sliders have input box below)
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                -- Refresh to global value
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                dbTable[dbKey] = globalVal
                -- Update slider display
                if container.slider then
                    container.slider:SetValue(globalVal)
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
            end
        end
        AddOverrideIndicators(container, lbl, dbKey, onReset, 6)
    end
    
    -- Background track
    local track = CreateFrame("Frame", nil, container, "BackdropTemplate")
    track:SetPoint("TOPLEFT", 0, -18)
    track:SetSize(180, 8)
    CreateElementBackdrop(track)
    
    -- Fill track (colored portion)
    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("LEFT", 1, 0)
    fill:SetHeight(6)
    local c = GetThemeColor()
    fill:SetColorTexture(c.r, c.g, c.b, 0.8)
    
    -- Slider
    local slider = CreateFrame("Slider", nil, container)
    slider:SetPoint("TOPLEFT", 0, -18)
    slider:SetSize(180, 8)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetHitRectInsets(-4, -4, -8, -8)
    container.slider = slider  -- Store reference for reset
    
    -- Track whether this slider is actively being dragged
    local isDragging = false
    
    -- Store preview mode flag for this slider
    local sliderUsePreviewMode = usePreviewMode or false
    
    -- Thumb
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 16)
    thumb:SetColorTexture(c.r, c.g, c.b, 1)
    slider:SetThumbTexture(thumb)
    
    -- Value input
    local input = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    input:SetPoint("LEFT", track, "RIGHT", 8, 0)
    input:SetSize(50, 20)
    CreateElementBackdrop(input)
    input:SetFontObject(GameFontHighlightSmall)
    input:SetJustifyH("CENTER")
    input:SetAutoFocus(false)
    input:SetTextInsets(2, 2, 0, 0)
    
    local function UpdateFill()
        local val = slider:GetValue()
        local pct = (val - minVal) / (maxVal - minVal)
        fill:SetWidth(math.max(1, pct * 178))
    end
    
    container.SetEnabled = function(self, enabled)
        slider:SetEnabled(enabled)
        input:EnableMouse(enabled)
        local tc = GetThemeColor()
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            thumb:SetColorTexture(tc.r, tc.g, tc.b, 1)
            fill:SetColorTexture(tc.r, tc.g, tc.b, 0.8)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            thumb:SetColorTexture(0.4, 0.4, 0.4, 1)
            fill:SetColorTexture(0.4, 0.4, 0.4, 0.5)
        end
    end
    
    container.UpdateTheme = function()
        local nc = GetThemeColor()
        if slider:IsEnabled() then
            thumb:SetColorTexture(nc.r, nc.g, nc.b, 1)
            fill:SetColorTexture(nc.r, nc.g, nc.b, 0.8)
        end
    end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, container)
    
    local suppressCallback = false
    
    -- Smart format: show whole numbers as integers, decimals with minimum precision needed
    local function FormatValue(val)
        if val == math.floor(val) then
            return string.format("%d", val)
        elseif val * 10 == math.floor(val * 10) then
            return string.format("%.1f", val)
        else
            return string.format("%.2f", val)
        end
    end
    
    local function UpdateValue(val)
        val = val or minVal
        suppressCallback = true
        slider:SetValue(val)
        suppressCallback = false
        input:SetText(FormatValue(val))
        UpdateFill()
        -- Update override indicators
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(val)
        end
    end
    
    -- Track drag start - pass the lightweight update function, name for debug, and preview mode
    slider:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            isDragging = true
            local funcName = lightweightUpdate and (dbKey .. " lightweight") or nil
            DF:OnSliderDragStart(lightweightUpdate, funcName, sliderUsePreviewMode)
        end
    end)
    
    -- Track drag end - do full update when slider is released
    slider:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and isDragging then
            isDragging = false
            DF:OnSliderDragStop()
            -- Update override indicators after drag ends
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(slider:GetValue())
            end
        end
    end)
    
    slider:SetScript("OnShow", function()
        if dbTable then UpdateValue(dbTable[dbKey]) end
    end)
    
    slider:SetScript("OnValueChanged", function(self, value)
        if suppressCallback then return end
        if not dbTable then return end
        if step >= 1 then
            value = math.floor(value + 0.5)
        else
            value = math.floor(value / step + 0.5) * step
        end

        -- Runtime override protection: redirect to baseline, skip refresh
        if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
           and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, value) then
            if not input:HasFocus() then input:SetText(FormatValue(value)) end
            UpdateFill()
            if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(value) end
            return
        end

        dbTable[dbKey] = value

        -- If editing a profile, also set the override
        if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
            DF.AutoProfilesUI:SetProfileSetting(dbKey, value)
        end
        
        if not input:HasFocus() then
            input:SetText(FormatValue(value))
        end
        UpdateFill()
        -- Use targeted update system - lightweight during drag, full on release
        DF:ThrottledUpdateAll()
        -- Skip callback during drag - it will run via UpdateAll on release
        if callback and not DF.sliderDragging then
            callback()
        end
    end)
    
    input:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            val = math.max(minVal, math.min(maxVal, val))

            -- Runtime override protection: redirect to baseline, skip refresh
            if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
               and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, val) then
                self:SetText(FormatValue(val))
                suppressCallback = true
                slider:SetValue(val)
                suppressCallback = false
                UpdateFill()
                if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(val) end
                self:ClearFocus()
                return
            end

            dbTable[dbKey] = val
            suppressCallback = true
            slider:SetValue(val)
            suppressCallback = false

            -- Update input text to show actual value entered
            self:SetText(FormatValue(val))
            UpdateFill()

            -- If editing a profile, also set the override
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                DF.AutoProfilesUI:SetProfileSetting(dbKey, val)
            end

            -- Update override indicators
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(val)
            end

            -- FIX 2025-01-20: Call callback OR lightweightUpdate (some sliders have nil callback)
            if callback then
                callback()
            elseif lightweightUpdate then
                lightweightUpdate()
            end

            -- Guaranteed full update (SetValue may not fire OnValueChanged if value didn't change)
            DF:UpdateAll()
        else
            UpdateValue(dbTable[dbKey])
        end
        self:ClearFocus()
    end)
    
    input:SetScript("OnEscapePressed", function(self)
        UpdateValue(dbTable[dbKey])
        self:ClearFocus()
    end)
    
    if dbTable then UpdateValue(dbTable[dbKey]) end
    
    -- SEARCH: Register this setting with slider metadata
    if DF.Search and dbKey and type(dbKey) == "string" then
        container.searchEntry = DF.Search:RegisterSlider(label, dbKey, minVal, maxVal, step, nil)
    end
    
    -- Expose label for dynamic updates
    container.label = lbl
    
    return container
end

function GUI:CreateColorPicker(parent, label, dbTable, dbKey, hasAlpha, callback, lightweightCallback, useLightweight)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 28)
    
    -- Button - use relative anchoring so it resizes with container
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, 0)
    btn:SetPoint("TOPRIGHT", 0, 0)
    btn:SetHeight(24)
    CreateElementBackdrop(btn)
    
    -- Label
    local txt = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    txt:SetPoint("LEFT", 8, 0)
    txt:SetText(label)
    txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Color swatch
    local swatch = btn:CreateTexture(nil, "OVERLAY")
    swatch:SetSize(40, 16)
    swatch:SetPoint("RIGHT", -6, 0)
    
    -- Add override indicators if dbKey is provided (for auto profiles)
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                -- Refresh to global value
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if globalVal then
                    dbTable[dbKey].r = globalVal.r
                    dbTable[dbKey].g = globalVal.g
                    dbTable[dbKey].b = globalVal.b
                    dbTable[dbKey].a = globalVal.a or 1
                end
                if container.UpdateSwatch then
                    container:UpdateSwatch()
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(dbTable[dbKey])
                end
                DF:UpdateAll()
            end
        end
        AddOverrideIndicators(container, txt, dbKey, onReset)
    end
    
    local function UpdateSwatch()
        if dbTable and dbKey and dbTable[dbKey] then
            local c = dbTable[dbKey]
            swatch:SetColorTexture(c.r, c.g, c.b, c.a or 1)
            -- Update override indicators
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(c)
            end
        end
    end
    container.UpdateSwatch = UpdateSwatch  -- Expose for reset
    
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)
    
    btn:SetScript("OnClick", function()
        if not dbTable then return end
        local c = dbTable[dbKey]
        if not c then 
            c = {r = 1, g = 1, b = 1, a = 1}
            dbTable[dbKey] = c
        end
        
        -- Store original values for cancel
        local originalColor = {r = c.r, g = c.g, b = c.b, a = c.a or 1}
        
        local info = {
            swatchFunc = function()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                local a = 1
                if hasAlpha and ColorPickerFrame.GetColorAlpha then
                    a = ColorPickerFrame:GetColorAlpha() or 1
                end
                dbTable[dbKey].r = r
                dbTable[dbKey].g = g
                dbTable[dbKey].b = b
                dbTable[dbKey].a = a
                
                -- If editing a profile, also set the override
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                    DF.AutoProfilesUI:SetProfileSetting(dbKey, {r = r, g = g, b = b, a = a})
                end
                
                UpdateSwatch()
                -- Use lightweight callback during dragging if available
                if useLightweight and lightweightCallback then
                    lightweightCallback()
                else
                    DF:ThrottledUpdateAll()
                    if callback then callback() end
                end
            end,
            hasOpacity = hasAlpha,
            opacityFunc = hasAlpha and function()
                if ColorPickerFrame.GetColorAlpha then
                    local a = ColorPickerFrame:GetColorAlpha()
                    if a then
                        dbTable[dbKey].a = a
                        UpdateSwatch()
                        -- Use lightweight callback during dragging if available
                        if useLightweight and lightweightCallback then
                            lightweightCallback()
                        else
                            DF:ThrottledUpdateAll()
                            if callback then callback() end
                        end
                    end
                end
            end or nil,
            cancelFunc = function(restore)
                -- Restore original color on cancel
                dbTable[dbKey].r = originalColor.r
                dbTable[dbKey].g = originalColor.g
                dbTable[dbKey].b = originalColor.b
                dbTable[dbKey].a = originalColor.a
                UpdateSwatch()
                DF:UpdateAll()
                if callback then callback() end
            end,
            r = c.r or 1, 
            g = c.g or 1, 
            b = c.b or 1, 
            opacity = hasAlpha and (c.a or 1) or nil,
        }
        
        -- Hook the OK button to run full update when confirmed
        if useLightweight and lightweightCallback then
            -- We need to run full update when picker is closed via OK
            local oldSetup = ColorPickerFrame.SetupColorPickerAndShow
            local function OnPickerClosed()
                DF:UpdateAll()
                if callback then callback() end
            end
            -- Use a frame to detect when color picker closes
            if not container.colorPickerWatcher then
                container.colorPickerWatcher = CreateFrame("Frame")
            end
            container.colorPickerWatcher:SetScript("OnUpdate", function(self)
                if not ColorPickerFrame:IsShown() then
                    self:SetScript("OnUpdate", nil)
                    -- Only run if color changed (not cancelled)
                    local cur = dbTable[dbKey]
                    if cur.r ~= originalColor.r or cur.g ~= originalColor.g or 
                       cur.b ~= originalColor.b or cur.a ~= originalColor.a then
                        DF:UpdateAll()
                        if callback then callback() end
                    end
                end
            end)
        end
        
        -- Mark this as a DandersFrames color picker call
        GUI:MarkColorPickerCall()
        ColorPickerFrame:SetupColorPickerAndShow(info)
    end)
    
    container.SetEnabled = function(self, enabled)
        btn:SetEnabled(enabled)
        if enabled then
            txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            swatch:SetDesaturated(false)
        else
            txt:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            swatch:SetDesaturated(true)
        end
    end
    
    btn:SetScript("OnShow", UpdateSwatch)
    UpdateSwatch()
    
    -- SEARCH: Register this setting
    if DF.Search and dbKey and type(dbKey) == "string" then
        container.searchEntry = DF.Search:RegisterColorPicker(label, dbKey, hasAlpha, nil)
    end
    
    return container
end

function GUI:CreateDropdown(parent, label, options, dbTable, dbKey, callback)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)
    
    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Add override indicators if dbKey is provided (for auto profiles)
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                -- Refresh to global value
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                dbTable[dbKey] = globalVal
                if container.UpdateText then
                    container:UpdateText()
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
            end
        end
        AddOverrideIndicators(container, lbl, dbKey, onReset, 6)
    end
    
    -- Button - use relative anchoring so it resizes with container
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    CreateElementBackdrop(btn)
    
    btn.Text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.Text:SetPoint("LEFT", 8, 0)
    btn.Text:SetPoint("RIGHT", -20, 0)
    btn.Text:SetJustifyH("LEFT")
    btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Arrow indicator
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetSize(12, 12)
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local function UpdateText()
        if dbTable and dbKey then
            local val = dbTable[dbKey]
            local displayVal = options[val]
            -- Handle table format: {value = X, text = "text"} or {text = "text"}
            if type(displayVal) == "table" then
                displayVal = displayVal.text or displayVal.label or tostring(val)
            end
            btn.Text:SetText(displayVal or tostring(val) or "Select...")
            -- Update override indicators
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(val)
            end
        end
    end
    container.UpdateText = UpdateText  -- Expose for reset
    
    -- Menu frame
    local menuFrame = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menuFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    menuFrame:SetClampedToScreen(true)
    CreateElementBackdrop(menuFrame)
    menuFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.98)
    menuFrame:Hide()
    
    -- Clear tracking when hidden
    menuFrame:SetScript("OnHide", function()
        if currentOpenDropdown == menuFrame then
            currentOpenDropdown = nil
        end
    end)
    
    local menuButtons = {}
    local menuHeight = 0
    local sortedOptions = {}
    
    -- Check for custom order array
    if options._order then
        -- Use specified order
        for _, k in ipairs(options._order) do
            if options[k] then
                table.insert(sortedOptions, {key = k, value = options[k]})
            end
        end
    else
        -- Default: sort alphabetically by display value
        for k, v in pairs(options) do
            -- Handle both formats: KEY = "text" or KEY = {value = X, text = "text"}
            local displayValue = type(v) == "table" and (v.text or v.label or tostring(k)) or v
            table.insert(sortedOptions, {key = k, value = displayValue})
        end
        table.sort(sortedOptions, function(a, b)
            local aVal = type(a.value) == "string" and a.value or tostring(a.key)
            local bVal = type(b.value) == "string" and b.value or tostring(b.key)
            return aVal < bVal
        end)
    end
    
    for i, opt in ipairs(sortedOptions) do
        local menuBtn = CreateFrame("Button", nil, menuFrame)
        menuBtn:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 22)
        menuBtn:SetPoint("TOPRIGHT", -2, -2 - (i - 1) * 22)
        menuBtn:SetHeight(22)
        
        menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        menuBtn.Text:SetPoint("LEFT", 8, 0)
        menuBtn.Text:SetText(opt.value)
        menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        
        menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
        menuBtn.Highlight:SetAllPoints()
        local c = GetThemeColor()
        menuBtn.Highlight:SetColorTexture(c.r, c.g, c.b, 0.3)
        
        menuBtn:SetScript("OnClick", function()
            -- Runtime override protection: redirect to baseline, skip refresh
            if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
               and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, opt.key) then
                UpdateText()
                menuFrame:Hide()
                if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(opt.key) end
                return
            end

            dbTable[dbKey] = opt.key

            -- If editing a profile, also set the override
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                DF.AutoProfilesUI:SetProfileSetting(dbKey, opt.key)
            end

            UpdateText()
            menuFrame:Hide()
            DF:UpdateAll()
            if callback then callback() end
            if parent.RefreshStates then parent:RefreshStates() end
        end)
        
        table.insert(menuButtons, menuBtn)
        menuHeight = menuHeight + 22
    end
    
    -- Menu frame width matches button width
    menuFrame:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
    menuFrame:SetHeight(menuHeight + 4)
    
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)
    
    btn:SetScript("OnClick", function(self)
        if menuFrame:IsShown() then
            menuFrame:Hide()
            currentOpenDropdown = nil
        else
            -- Close any other open dropdown first
            CloseOpenDropdown()
            for i, menuBtn in ipairs(menuButtons) do
                local opt = sortedOptions[i]
                if dbTable[dbKey] == opt.key then
                    menuBtn.Text:SetTextColor(GetThemeColor().r, GetThemeColor().g, GetThemeColor().b)
                else
                    menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                end
            end
            menuFrame:Show()
            currentOpenDropdown = menuFrame
        end
    end)
    
    btn:SetScript("OnShow", UpdateText)
    UpdateText()
    
    container.SetEnabled = function(self, enabled)
        btn:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            btn.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end
    
    -- SEARCH: Register this setting
    if DF.Search and dbKey and type(dbKey) == "string" then
        container.searchEntry = DF.Search:RegisterDropdown(label, dbKey, options, nil)
    end
    
    return container
end

-- ============================================================
-- TEXTURE DROPDOWN WITH PREVIEW
-- ============================================================

function GUI:CreateTextureDropdown(parent, label, dbTable, dbKey, callback, customOptions)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)
    
    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Add override indicators if dbKey is provided
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and dbKey then
                    dbTable[dbKey] = globalVal
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
                if callback then callback() end
            end
        end
        AddOverrideIndicators(container, lbl, dbKey, onReset, 6)
    end
    
    -- Button - use relative anchoring so it resizes with container
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    CreateElementBackdrop(btn)
    
    -- Texture preview on button
    btn.Preview = btn:CreateTexture(nil, "ARTWORK")
    btn.Preview:SetPoint("LEFT", 4, 0)
    btn.Preview:SetSize(80, 16)
    
    btn.Text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.Text:SetPoint("LEFT", 90, 0)
    btn.Text:SetPoint("RIGHT", -20, 0)
    btn.Text:SetJustifyH("LEFT")
    btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Arrow indicator
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetSize(12, 12)
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local function UpdateText()
        if dbTable and dbKey then
            local val = dbTable[dbKey]
            local displayName
            if customOptions then
                -- Use custom options lookup
                displayName = customOptions[val]
            else
                -- Use robust SharedMedia lookup
                displayName = DF:GetTextureNameFromPath(val)
            end
            btn.Text:SetText(displayName or "Select...")
            -- Handle "Solid" special case (not a valid texture path)
            if val == "Solid" then
                btn.Preview:SetColorTexture(0.3, 0.3, 0.3, 1)
            else
                btn.Preview:SetTexture(val)
                btn.Preview:SetVertexColor(0.3, 0.7, 0.3)  -- Green tint for preview
            end
        end
    end
    
    -- Menu frame with scroll
    local menuFrame = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menuFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    menuFrame:SetClampedToScreen(true)
    CreateElementBackdrop(menuFrame)
    menuFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.98)
    menuFrame:Hide()
    
    -- Search box at top of menu
    local SEARCH_HEIGHT = 26
    local searchBox = CreateFrame("EditBox", nil, menuFrame, "BackdropTemplate")
    searchBox:SetPoint("TOPLEFT", 4, -4)
    searchBox:SetPoint("TOPRIGHT", -4, -4)
    searchBox:SetHeight(22)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject(GameFontHighlightSmall)
    searchBox:SetTextInsets(24, 8, 0, 0)
    CreateElementBackdrop(searchBox)
    searchBox:SetBackdropColor(0.1, 0.1, 0.1, 1)
    
    -- Search icon
    local searchIcon = searchBox:CreateTexture(nil, "OVERLAY")
    searchIcon:SetPoint("LEFT", 6, 0)
    searchIcon:SetSize(12, 12)
    searchIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\search")
    searchIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Placeholder text
    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    placeholder:SetPoint("LEFT", 24, 0)
    placeholder:SetText("Search textures...")
    placeholder:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
    
    searchBox:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function() 
        if searchBox:GetText() == "" then placeholder:Show() end
    end)
    
    -- Clear tracking when hidden
    menuFrame:SetScript("OnHide", function()
        if currentOpenDropdown == menuFrame then
            currentOpenDropdown = nil
        end
        searchBox:SetText("")
        searchBox:ClearFocus()
        placeholder:Show()
    end)
    
    -- Scroll frame - positioned below search box
    local scrollFrame = CreateFrame("ScrollFrame", nil, menuFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 2, -(SEARCH_HEIGHT + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", -20, 2)
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(234)  -- Match button width for texture dropdown
    scrollFrame:SetScrollChild(scrollChild)
    
    -- Hide scroll bar styling
    local scrollBar = scrollFrame.ScrollBar
    if scrollBar then
        scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", -16, -16)
        scrollBar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", -16, 16)
    end
    
    local menuButtons = {}
    local ITEM_HEIGHT = 28
    local MAX_VISIBLE = 8
    
    -- Function to rebuild menu with current textures
    local function RebuildMenu(filterText)
        -- Clear old buttons
        for _, menuBtn in ipairs(menuButtons) do
            menuBtn:Hide()
            menuBtn:SetParent(nil)
        end
        wipe(menuButtons)
        
        -- Get fresh texture list (use custom options if provided)
        local options = customOptions or DF:GetTextureList()
        local sortedOptions = {}
        
        -- Apply filter if provided
        filterText = filterText and filterText:lower() or ""
        
        for k, v in pairs(options) do
            if filterText == "" or v:lower():find(filterText, 1, true) then
                table.insert(sortedOptions, {key = k, value = v})
            end
        end
        table.sort(sortedOptions, function(a, b) return a.value < b.value end)
        
        -- Resize menu and scroll child
        local menuHeight = math.min(#sortedOptions, MAX_VISIBLE) * ITEM_HEIGHT + SEARCH_HEIGHT + 8
        menuFrame:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
        menuFrame:SetHeight(menuHeight)
        scrollChild:SetHeight(#sortedOptions * ITEM_HEIGHT)
        
        -- Hide scrollbar if not needed
        if scrollBar then
            if #sortedOptions <= MAX_VISIBLE then
                scrollBar:Hide()
            else
                scrollBar:Show()
            end
        end
        
        -- Create new buttons
        for i, opt in ipairs(sortedOptions) do
            local menuBtn = CreateFrame("Button", nil, scrollChild)
            menuBtn:SetSize(234, ITEM_HEIGHT)
            menuBtn:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM_HEIGHT)
            
            -- Texture preview
            menuBtn.Preview = menuBtn:CreateTexture(nil, "ARTWORK")
            menuBtn.Preview:SetPoint("LEFT", 4, 0)
            menuBtn.Preview:SetSize(80, 18)
            -- Handle "Solid" special case
            if opt.key == "Solid" then
                menuBtn.Preview:SetColorTexture(0.3, 0.3, 0.3, 1)
            else
                menuBtn.Preview:SetTexture(opt.key)
                menuBtn.Preview:SetVertexColor(0.3, 0.7, 0.3)  -- Green tint for preview
            end
            
            menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            menuBtn.Text:SetPoint("LEFT", 90, 0)
            menuBtn.Text:SetText(opt.value)
            
            -- Highlight selected item
            if dbTable[dbKey] == opt.key then
                menuBtn.Text:SetTextColor(GetThemeColor().r, GetThemeColor().g, GetThemeColor().b)
            else
                menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end
            
            menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
            menuBtn.Highlight:SetAllPoints()
            local c = GetThemeColor()
            menuBtn.Highlight:SetColorTexture(c.r, c.g, c.b, 0.3)
            
            menuBtn:SetScript("OnClick", function()
                -- Runtime override protection
                if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
                   and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, opt.key) then
                    UpdateText()
                    menuFrame:Hide()
                    if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(opt.key) end
                    return
                end
                dbTable[dbKey] = opt.key
                -- Track override when editing a profile
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                    DF.AutoProfilesUI:SetProfileSetting(dbKey, opt.key)
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(opt.key)
                end
                UpdateText()
                menuFrame:Hide()
                DF:UpdateAll()
                if callback then callback() end
            end)

            table.insert(menuButtons, menuBtn)
        end
    end
    
    -- Search box text changed handler
    searchBox:SetScript("OnTextChanged", function(self)
        RebuildMenu(self:GetText())
    end)
    
    -- Allow escape to close
    searchBox:SetScript("OnEscapePressed", function()
        menuFrame:Hide()
    end)
    
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)
    
    btn:SetScript("OnClick", function(self)
        if menuFrame:IsShown() then
            menuFrame:Hide()
            currentOpenDropdown = nil
        else
            -- Close any other open dropdown first
            CloseOpenDropdown()
            -- Rebuild menu with current SharedMedia textures
            RebuildMenu()
            menuFrame:Show()
            currentOpenDropdown = menuFrame
            -- Focus search box
            searchBox:SetFocus()
        end
    end)
    
    btn:SetScript("OnShow", UpdateText)
    UpdateText()
    
    -- Refresh override indicators on show
    container:SetScript("OnShow", function()
        UpdateText()
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
        end
    end)
    
    container.SetEnabled = function(self, enabled)
        btn:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            btn.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end
    
    -- SEARCH: Register this setting (use current texture list)
    if DF.Search and dbKey and type(dbKey) == "string" then
        local currentOptions = customOptions or DF:GetTextureList()
        container.searchEntry = DF.Search:RegisterDropdown(label, dbKey, currentOptions, nil)
    end
    
    return container
end

-- ============================================================
-- FONT DROPDOWN WITH PREVIEW
-- ============================================================

function GUI:CreateFontDropdown(parent, label, dbTable, dbKey, callback)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)
    
    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Add override indicators if dbKey is provided
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and dbKey then
                    dbTable[dbKey] = globalVal
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
                if callback then callback() end
            end
        end
        AddOverrideIndicators(container, lbl, dbKey, onReset, 6)
    end
    
    -- Button - use relative anchoring so it resizes with container
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    CreateElementBackdrop(btn)
    
    btn.Text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.Text:SetPoint("LEFT", 8, 0)
    btn.Text:SetPoint("RIGHT", -20, 0)
    btn.Text:SetJustifyH("LEFT")
    btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Arrow indicator
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetSize(12, 12)
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local function UpdateText()
        if dbTable and dbKey then
            local val = dbTable[dbKey]
            -- Get font display name (handles both names and legacy paths)
            local displayName = DF:GetFontNameFromPath(val)
            btn.Text:SetText(displayName or "Select...")
            -- Try to set the button text to the selected font for preview
            local fontPath = DF:GetFontPath(val)
            if fontPath then
                local success = pcall(function()
                    btn.Text:SetFont(fontPath, 12, "")
                end)
                if not success then
                    btn.Text:SetFontObject(GameFontHighlightSmall)
                end
            end
        end
    end
    
    -- Menu frame with scroll
    local menuFrame = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menuFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    menuFrame:SetClampedToScreen(true)
    CreateElementBackdrop(menuFrame)
    menuFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.98)
    menuFrame:Hide()
    
    -- Search box at top of menu
    local SEARCH_HEIGHT = 26
    local searchBox = CreateFrame("EditBox", nil, menuFrame, "BackdropTemplate")
    searchBox:SetPoint("TOPLEFT", 4, -4)
    searchBox:SetPoint("TOPRIGHT", -4, -4)
    searchBox:SetHeight(22)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject(GameFontHighlightSmall)
    searchBox:SetTextInsets(24, 8, 0, 0)
    CreateElementBackdrop(searchBox)
    searchBox:SetBackdropColor(0.1, 0.1, 0.1, 1)
    
    -- Search icon
    local searchIcon = searchBox:CreateTexture(nil, "OVERLAY")
    searchIcon:SetPoint("LEFT", 6, 0)
    searchIcon:SetSize(12, 12)
    searchIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\search")
    searchIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Placeholder text
    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    placeholder:SetPoint("LEFT", 24, 0)
    placeholder:SetText("Search fonts...")
    placeholder:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
    
    searchBox:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function() 
        if searchBox:GetText() == "" then placeholder:Show() end
    end)
    
    -- Clear tracking when hidden
    menuFrame:SetScript("OnHide", function()
        if currentOpenDropdown == menuFrame then
            currentOpenDropdown = nil
        end
        searchBox:SetText("")
        searchBox:ClearFocus()
        placeholder:Show()
    end)
    
    -- Scroll frame - positioned below search box
    local scrollFrame = CreateFrame("ScrollFrame", nil, menuFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 2, -(SEARCH_HEIGHT + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", -20, 2)
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(234)  -- Match button width for font dropdown
    scrollFrame:SetScrollChild(scrollChild)
    
    -- Hide scroll bar styling
    local scrollBar = scrollFrame.ScrollBar
    if scrollBar then
        scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", -16, -16)
        scrollBar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", -16, 16)
    end
    
    local menuButtons = {}
    local ITEM_HEIGHT = 24
    local MAX_VISIBLE = 10
    
    -- Function to rebuild menu with current fonts
    local function RebuildMenu(filterText)
        -- Clear old buttons
        for _, menuBtn in ipairs(menuButtons) do
            menuBtn:Hide()
            menuBtn:SetParent(nil)
        end
        wipe(menuButtons)
        
        -- Get fresh font list
        local options = DF:GetFontList()
        local sortedOptions = {}
        
        -- Apply filter if provided
        filterText = filterText and filterText:lower() or ""
        
        for k, v in pairs(options) do
            if filterText == "" or v:lower():find(filterText, 1, true) then
                table.insert(sortedOptions, {key = k, value = v})
            end
        end
        table.sort(sortedOptions, function(a, b) return a.value < b.value end)
        
        -- Resize menu and scroll child
        local menuHeight = math.min(#sortedOptions, MAX_VISIBLE) * ITEM_HEIGHT + SEARCH_HEIGHT + 8
        menuFrame:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
        menuFrame:SetHeight(menuHeight)
        scrollChild:SetHeight(#sortedOptions * ITEM_HEIGHT)
        
        -- Hide scrollbar if not needed
        if scrollBar then
            if #sortedOptions <= MAX_VISIBLE then
                scrollBar:Hide()
            else
                scrollBar:Show()
            end
        end
        
        -- Create new buttons
        for i, opt in ipairs(sortedOptions) do
            local menuBtn = CreateFrame("Button", nil, scrollChild)
            menuBtn:SetSize(234, ITEM_HEIGHT)
            menuBtn:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM_HEIGHT)
            
            menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY")
            menuBtn.Text:SetPoint("LEFT", 8, 0)
            menuBtn.Text:SetPoint("RIGHT", -8, 0)
            menuBtn.Text:SetJustifyH("LEFT")
            
            -- Set default font first, then try to use the actual font for preview
            menuBtn.Text:SetFontObject(GameFontHighlightSmall)
            
            -- Try to preview in the actual font
            local LSM = DF.GetLSM and DF.GetLSM()
            if LSM then
                local fontPath = LSM:Fetch("font", opt.key)
                if fontPath then
                    pcall(function()
                        menuBtn.Text:SetFont(fontPath, 12, "")
                    end)
                end
            end
            
            menuBtn.Text:SetText(opt.value)
            
            -- Highlight selected item (compare with stored font name)
            local currentValue = dbTable[dbKey]
            local currentName = DF:GetFontNameFromPath(currentValue)
            if currentName == opt.key or currentValue == opt.key then
                menuBtn.Text:SetTextColor(GetThemeColor().r, GetThemeColor().g, GetThemeColor().b)
            else
                menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end
            
            menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
            menuBtn.Highlight:SetAllPoints()
            local c = GetThemeColor()
            menuBtn.Highlight:SetColorTexture(c.r, c.g, c.b, 0.3)
            
            menuBtn:SetScript("OnClick", function()
                -- Runtime override protection
                if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
                   and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, opt.key) then
                    UpdateText()
                    menuFrame:Hide()
                    if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(opt.key) end
                    return
                end
                -- Store font NAME in database (not path)
                dbTable[dbKey] = opt.key
                -- Track override when editing a profile
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                    DF.AutoProfilesUI:SetProfileSetting(dbKey, opt.key)
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(opt.key)
                end
                UpdateText()
                menuFrame:Hide()
                DF:UpdateAll()
                if callback then callback() end
            end)
            
            table.insert(menuButtons, menuBtn)
        end
    end
    
    -- Search box text changed handler
    searchBox:SetScript("OnTextChanged", function(self)
        RebuildMenu(self:GetText())
    end)
    
    -- Allow escape to close
    searchBox:SetScript("OnEscapePressed", function()
        menuFrame:Hide()
    end)
    
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)
    
    btn:SetScript("OnClick", function(self)
        if menuFrame:IsShown() then
            menuFrame:Hide()
            currentOpenDropdown = nil
        else
            -- Close any other open dropdown first
            CloseOpenDropdown()
            -- Rebuild menu with current SharedMedia fonts
            RebuildMenu()
            menuFrame:Show()
            currentOpenDropdown = menuFrame
            -- Focus search box
            searchBox:SetFocus()
        end
    end)
    
    btn:SetScript("OnShow", UpdateText)
    UpdateText()
    
    -- Refresh override indicators on show
    container:SetScript("OnShow", function()
        UpdateText()
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
        end
    end)
    
    container.SetEnabled = function(self, enabled)
        btn:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            btn.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end
    
    -- SEARCH: Register this setting (use current font list)
    if DF.Search and dbKey and type(dbKey) == "string" then
        container.searchEntry = DF.Search:RegisterDropdown(label, dbKey, DF:GetFontList(), nil)
    end
    
    return container
end

-- ============================================================
-- ROLE ORDER LIST (Drag-Drop)
-- ============================================================

function GUI:CreateRoleOrderList(parent, dbTable, dbKey, callback, separateMeleeRangedKey)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(220, 130)
    
    -- Role display info with colors
    local ROLE_INFO = {
        TANK = { name = "Tank", color = {0.53, 0.77, 0.84}, coords = {0, 19/64, 22/64, 41/64} },
        HEALER = { name = "Healer", color = {0.25, 0.78, 0.25}, coords = {20/64, 39/64, 1/64, 20/64} },
        MELEE = { name = "Melee DPS", color = {0.82, 0.65, 0.47}, coords = {20/64, 39/64, 22/64, 41/64} },
        RANGED = { name = "Ranged DPS", color = {1.0, 0.49, 0.04}, coords = {20/64, 39/64, 22/64, 41/64} },
        DAMAGER = { name = "DPS", color = {0.82, 0.65, 0.47}, coords = {20/64, 39/64, 22/64, 41/64} },
    }
    
    local roleItems = {}
    local ITEM_HEIGHT = 30
    local draggingItem = nil
    local dragOffsetY = 0
    
    -- Check if we should show separate melee/ranged
    local function IsSeparateMeleeRanged()
        if separateMeleeRangedKey and dbTable then
            return dbTable[separateMeleeRangedKey]
        end
        return true
    end
    
    -- Get the roles to display
    local function GetDisplayRoles()
        if IsSeparateMeleeRanged() then
            return { "TANK", "HEALER", "MELEE", "RANGED" }
        else
            return { "TANK", "HEALER", "DAMAGER" }
        end
    end
    
    -- Get current order from db or use default
    local function GetCurrentOrder()
        local displayRoles = GetDisplayRoles()
        if dbTable and dbKey and dbTable[dbKey] then
            local order = {}
            for _, role in ipairs(dbTable[dbKey]) do
                for _, displayRole in ipairs(displayRoles) do
                    if role == displayRole or 
                       (displayRole == "DAMAGER" and (role == "MELEE" or role == "RANGED" or role == "DAMAGER")) then
                        local found = false
                        for _, existing in ipairs(order) do
                            if existing == displayRole then found = true break end
                        end
                        if not found then
                            table.insert(order, displayRole)
                        end
                        break
                    end
                end
            end
            for _, displayRole in ipairs(displayRoles) do
                local found = false
                for _, existing in ipairs(order) do
                    if existing == displayRole then found = true break end
                end
                if not found then
                    table.insert(order, displayRole)
                end
            end
            return order
        end
        return displayRoles
    end
    
    -- Save order to db
    local function SaveOrder(newOrder)
        if dbTable and dbKey then
            local saveOrder = {}
            for _, role in ipairs(newOrder) do
                if role == "DAMAGER" then
                    table.insert(saveOrder, "MELEE")
                    table.insert(saveOrder, "RANGED")
                else
                    table.insert(saveOrder, role)
                end
            end
            dbTable[dbKey] = saveOrder
            -- Track override when editing a profile
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                local copy = {}
                for i, v in ipairs(saveOrder) do copy[i] = v end
                DF.AutoProfilesUI:SetProfileSetting(dbKey, copy)
            end
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(saveOrder)
            end
            if callback then callback() end
        end
    end
    
    -- Get index from Y position
    local function GetIndexFromY(y)
        local containerTop = container:GetTop()
        if not containerTop then return 1 end
        local relativeY = containerTop - y
        local index = math.floor(relativeY / ITEM_HEIGHT) + 1
        local order = GetCurrentOrder()
        return math.max(1, math.min(index, #order))
    end
    
    -- Update visual positions
    local function UpdateItemPositions()
        local order = GetCurrentOrder()
        local numRoles = #order
        
        container:SetHeight(numRoles * ITEM_HEIGHT + 5)
        
        for _, item in pairs(roleItems) do
            item:Hide()
        end
        
        for i, role in ipairs(order) do
            local item = roleItems[role]
            if item then
                item:Show()
                item.posIndex = i
                item.numText:SetText(i .. ".")
                if item ~= draggingItem then
                    item:ClearAllPoints()
                    item:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ITEM_HEIGHT))
                    item:SetWidth(container:GetWidth() > 0 and container:GetWidth() or 220)
                end
            end
        end
    end
    
    -- Create grip texture (3 horizontal lines)
    local function CreateGripTexture(parentFrame)
        local grip = CreateFrame("Frame", nil, parentFrame)
        grip:SetSize(12, 16)
        
        for i = 1, 3 do
            local line = grip:CreateTexture(nil, "ARTWORK")
            line:SetSize(10, 2)
            line:SetPoint("TOP", grip, "TOP", 0, -3 - (i - 1) * 5)
            line:SetColorTexture(0.5, 0.5, 0.5, 1)
            grip["line" .. i] = line
        end
        
        grip.SetGripColor = function(self, r, g, b)
            for i = 1, 3 do
                self["line" .. i]:SetColorTexture(r, g, b, 1)
            end
        end
        
        return grip
    end
    
    -- Create a single role item
    local function CreateRoleItem(role)
        local info = ROLE_INFO[role]
        if not info then return nil end
        
        local item = CreateFrame("Frame", nil, container, "BackdropTemplate")
        item:SetHeight(ITEM_HEIGHT - 2)
        item:EnableMouse(true)
        item:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        item:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
        item:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        
        -- Grip texture
        local grip = CreateGripTexture(item)
        grip:SetPoint("LEFT", 6, 0)
        item.grip = grip
        
        -- Priority number
        local numText = item:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        numText:SetPoint("LEFT", grip, "RIGHT", 6, 0)
        numText:SetWidth(18)
        numText:SetJustifyH("LEFT")
        item.numText = numText
        
        -- Role icon
        local icon = item:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", numText, "RIGHT", 2, 0)
        icon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
        icon:SetTexCoord(unpack(info.coords))
        item.icon = icon
        
        -- Role name with color
        local text = item:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        text:SetText(info.name)
        text:SetTextColor(info.color[1], info.color[2], info.color[3])
        item.text = text
        
        item.role = role
        item.posIndex = 1
        
        -- Mouse handlers for dragging
        item:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                draggingItem = self
                local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
                local itemTop = self:GetTop()
                dragOffsetY = itemTop - cursorY
                
                self:SetBackdropColor(0.28, 0.28, 0.55, 0.9)
                self:SetBackdropBorderColor(0.45, 0.45, 0.95, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 10)
                self.grip:SetGripColor(1, 1, 1)
            end
        end)
        
        item:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and draggingItem == self then
                local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
                local dropIndex = GetIndexFromY(cursorY)
                
                local order = GetCurrentOrder()
                local currentIdx = self.posIndex
                
                if currentIdx ~= dropIndex then
                    local draggedRole = self.role
                    table.remove(order, currentIdx)
                    table.insert(order, dropIndex, draggedRole)
                    SaveOrder(order)
                end
                
                self:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
                
                draggingItem = nil
                UpdateItemPositions()
            end
        end)
        
        item:SetScript("OnUpdate", function(self)
            if draggingItem ~= self then return end
            
            local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local containerTop = container:GetTop()
            local containerBottom = container:GetBottom()
            
            if not containerTop or not containerBottom then return end
            
            local targetY = cursorY + dragOffsetY
            local offsetFromTop = containerTop - targetY
            
            local maxOffset = (containerTop - containerBottom) - ITEM_HEIGHT + 5
            offsetFromTop = math.max(0, math.min(offsetFromTop, maxOffset))
            
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -offsetFromTop)
            self:SetWidth(container:GetWidth())
            
            -- Update other items based on where this would drop
            local dropIndex = GetIndexFromY(cursorY)
            local order = GetCurrentOrder()
            
            local tempOrder = {}
            for i, r in ipairs(order) do
                if roleItems[r] ~= self then
                    table.insert(tempOrder, r)
                end
            end
            table.insert(tempOrder, dropIndex, self.role)
            
            for i, r in ipairs(tempOrder) do
                local otherItem = roleItems[r]
                if otherItem and otherItem ~= self then
                    otherItem:ClearAllPoints()
                    otherItem:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ITEM_HEIGHT))
                    otherItem:SetWidth(container:GetWidth())
                    otherItem.numText:SetText(i .. ".")
                end
            end
        end)
        
        -- Hover effects
        item:SetScript("OnEnter", function(self)
            if not draggingItem then
                self:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
                self.grip:SetGripColor(0.8, 0.8, 0.8)
            end
        end)
        
        item:SetScript("OnLeave", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
            end
        end)
        
        return item
    end
    
    -- Create all role items
    for _, role in ipairs({"TANK", "HEALER", "MELEE", "RANGED", "DAMAGER"}) do
        roleItems[role] = CreateRoleItem(role)
    end
    
    -- Initial layout
    UpdateItemPositions()
    
    -- Refresh function
    container.Refresh = function()
        UpdateItemPositions()
    end
    
    -- Override indicators for profile editing
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and type(globalVal) == "table" then
                    local copy = {}
                    for i, v in ipairs(globalVal) do copy[i] = v end
                    dbTable[dbKey] = copy
                end
                UpdateItemPositions()
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(dbTable[dbKey])
                end
                if callback then callback() end
            end
        end
        AddOrderListOverrideIndicators(container, dbKey, onReset)
        
        container:SetScript("OnShow", function()
            UpdateItemPositions()
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
            end
        end)
    end
    
    return container
end

-- ============================================================
-- CLASS ORDER LIST (Drag-Drop) - For class sorting within roles
-- ============================================================

function GUI:CreateClassOrderList(parent, dbTable, dbKey, callback)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(220, 340)  -- Taller to fit all 13 classes
    
    -- Class display info with colors (using Blizzard class colors)
    local CLASS_INFO = {
        DEATHKNIGHT = { name = "Death Knight", color = {0.77, 0.12, 0.23} },
        DEMONHUNTER = { name = "Demon Hunter", color = {0.64, 0.19, 0.79} },
        DRUID = { name = "Druid", color = {1.0, 0.49, 0.04} },
        EVOKER = { name = "Evoker", color = {0.20, 0.58, 0.50} },
        HUNTER = { name = "Hunter", color = {0.67, 0.83, 0.45} },
        MAGE = { name = "Mage", color = {0.25, 0.78, 0.92} },
        MONK = { name = "Monk", color = {0.0, 1.0, 0.59} },
        PALADIN = { name = "Paladin", color = {0.96, 0.55, 0.73} },
        PRIEST = { name = "Priest", color = {1.0, 1.0, 1.0} },
        ROGUE = { name = "Rogue", color = {1.0, 0.96, 0.41} },
        SHAMAN = { name = "Shaman", color = {0.0, 0.44, 0.87} },
        WARLOCK = { name = "Warlock", color = {0.53, 0.53, 0.93} },
        WARRIOR = { name = "Warrior", color = {0.78, 0.61, 0.43} },
    }
    
    local ALL_CLASSES = {
        "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER",
        "MAGE", "MONK", "PALADIN", "PRIEST", "ROGUE",
        "SHAMAN", "WARLOCK", "WARRIOR"
    }
    
    local classItems = {}
    local ITEM_HEIGHT = 24  -- Slightly smaller to fit all classes
    local draggingItem = nil
    local dragOffsetY = 0
    
    -- Get current order from db or use default
    local function GetCurrentOrder()
        if dbTable and dbKey and dbTable[dbKey] then
            -- Ensure all classes are present
            local order = {}
            local seen = {}
            for _, class in ipairs(dbTable[dbKey]) do
                if CLASS_INFO[class] and not seen[class] then
                    table.insert(order, class)
                    seen[class] = true
                end
            end
            -- Add any missing classes
            for _, class in ipairs(ALL_CLASSES) do
                if not seen[class] then
                    table.insert(order, class)
                end
            end
            return order
        end
        return ALL_CLASSES
    end
    
    -- Save order to db
    local function SaveOrder(newOrder)
        if dbTable and dbKey then
            dbTable[dbKey] = newOrder
            -- Track override when editing a profile
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                local copy = {}
                for i, v in ipairs(newOrder) do copy[i] = v end
                DF.AutoProfilesUI:SetProfileSetting(dbKey, copy)
            end
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(newOrder)
            end
            if callback then callback() end
        end
    end
    
    -- Get index from Y position
    local function GetIndexFromY(y)
        local containerTop = container:GetTop()
        if not containerTop then return 1 end
        local relativeY = containerTop - y
        local index = math.floor(relativeY / ITEM_HEIGHT) + 1
        local order = GetCurrentOrder()
        return math.max(1, math.min(index, #order))
    end
    
    -- Update visual positions
    local function UpdateItemPositions()
        local order = GetCurrentOrder()
        local numClasses = #order
        
        container:SetHeight(numClasses * ITEM_HEIGHT + 5)
        
        for _, item in pairs(classItems) do
            item:Hide()
        end
        
        for i, class in ipairs(order) do
            local item = classItems[class]
            if item then
                item:Show()
                item.posIndex = i
                item.numText:SetText(i .. ".")
                if item ~= draggingItem then
                    item:ClearAllPoints()
                    item:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ITEM_HEIGHT))
                    item:SetWidth(container:GetWidth() > 0 and container:GetWidth() or 220)
                end
            end
        end
    end
    
    -- Create grip texture (3 horizontal lines)
    local function CreateGripTexture(parentFrame)
        local grip = CreateFrame("Frame", nil, parentFrame)
        grip:SetSize(10, 12)
        
        for i = 1, 3 do
            local line = grip:CreateTexture(nil, "ARTWORK")
            line:SetSize(8, 1)
            line:SetPoint("TOP", grip, "TOP", 0, -2 - (i - 1) * 4)
            line:SetColorTexture(0.5, 0.5, 0.5, 1)
            grip["line" .. i] = line
        end
        
        grip.SetGripColor = function(self, r, g, b)
            for i = 1, 3 do
                self["line" .. i]:SetColorTexture(r, g, b, 1)
            end
        end
        
        return grip
    end
    
    -- Create a single class item
    local function CreateClassItem(class)
        local info = CLASS_INFO[class]
        if not info then return nil end
        
        local item = CreateFrame("Frame", nil, container, "BackdropTemplate")
        item:SetHeight(ITEM_HEIGHT - 2)
        item:EnableMouse(true)
        item:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        item:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
        item:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        
        -- Grip texture
        local grip = CreateGripTexture(item)
        grip:SetPoint("LEFT", 4, 0)
        item.grip = grip
        
        -- Priority number
        local numText = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        numText:SetPoint("LEFT", grip, "RIGHT", 4, 0)
        numText:SetWidth(20)
        numText:SetJustifyH("LEFT")
        item.numText = numText
        
        -- Class color bar
        local colorBar = item:CreateTexture(nil, "ARTWORK")
        colorBar:SetSize(3, ITEM_HEIGHT - 6)
        colorBar:SetPoint("LEFT", numText, "RIGHT", 2, 0)
        colorBar:SetColorTexture(info.color[1], info.color[2], info.color[3], 1)
        item.colorBar = colorBar
        
        -- Class name with color
        local text = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", colorBar, "RIGHT", 6, 0)
        text:SetText(info.name)
        text:SetTextColor(info.color[1], info.color[2], info.color[3])
        item.text = text
        
        item.class = class
        item.posIndex = 1
        
        -- Mouse handlers for dragging
        item:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                draggingItem = self
                local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
                local itemTop = self:GetTop()
                dragOffsetY = itemTop - cursorY
                
                self:SetBackdropColor(0.28, 0.28, 0.55, 0.9)
                self:SetBackdropBorderColor(0.45, 0.45, 0.95, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 10)
                self.grip:SetGripColor(1, 1, 1)
            end
        end)
        
        item:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and draggingItem == self then
                local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
                local dropIndex = GetIndexFromY(cursorY)
                
                local order = GetCurrentOrder()
                local currentIdx = self.posIndex
                
                if currentIdx ~= dropIndex then
                    local draggedClass = self.class
                    table.remove(order, currentIdx)
                    table.insert(order, dropIndex, draggedClass)
                    SaveOrder(order)
                end
                
                self:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
                
                draggingItem = nil
                UpdateItemPositions()
            end
        end)
        
        item:SetScript("OnUpdate", function(self)
            if draggingItem ~= self then return end
            
            local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local containerTop = container:GetTop()
            local containerBottom = container:GetBottom()
            
            if not containerTop or not containerBottom then return end
            
            local targetY = cursorY + dragOffsetY
            local offsetFromTop = containerTop - targetY
            
            local maxOffset = (containerTop - containerBottom) - ITEM_HEIGHT + 5
            offsetFromTop = math.max(0, math.min(offsetFromTop, maxOffset))
            
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -offsetFromTop)
            self:SetWidth(container:GetWidth())
            
            -- Update other items based on where this would drop
            local dropIndex = GetIndexFromY(cursorY)
            local order = GetCurrentOrder()
            
            local tempOrder = {}
            for i, c in ipairs(order) do
                if classItems[c] ~= self then
                    table.insert(tempOrder, c)
                end
            end
            table.insert(tempOrder, dropIndex, self.class)
            
            for i, c in ipairs(tempOrder) do
                local otherItem = classItems[c]
                if otherItem and otherItem ~= self then
                    otherItem:ClearAllPoints()
                    otherItem:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ITEM_HEIGHT))
                    otherItem:SetWidth(container:GetWidth())
                    otherItem.numText:SetText(i .. ".")
                end
            end
        end)
        
        -- Hover effects
        item:SetScript("OnEnter", function(self)
            if not draggingItem then
                self:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
                self.grip:SetGripColor(0.8, 0.8, 0.8)
            end
        end)
        
        item:SetScript("OnLeave", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
            end
        end)
        
        return item
    end
    
    -- Create all class items
    for _, class in ipairs(ALL_CLASSES) do
        classItems[class] = CreateClassItem(class)
    end
    
    -- Initial layout
    UpdateItemPositions()
    
    -- Refresh function
    container.Refresh = function()
        UpdateItemPositions()
    end
    
    -- Override indicators for profile editing
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and type(globalVal) == "table" then
                    local copy = {}
                    for i, v in ipairs(globalVal) do copy[i] = v end
                    dbTable[dbKey] = copy
                end
                UpdateItemPositions()
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(dbTable[dbKey])
                end
                if callback then callback() end
            end
        end
        AddOrderListOverrideIndicators(container, dbKey, onReset)
        
        container:SetScript("OnShow", function()
            UpdateItemPositions()
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
            end
        end)
    end
    
    return container
end

-- Raid Group Order List (drag-and-drop)
function GUI:CreateGroupOrderList(parent, dbTable, dbKey, callback, playerGroupFirstKey)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(180, 250)
    
    -- Group colors for visual distinction
    local GROUP_COLORS = {
        [1] = {0.95, 0.40, 0.40},  -- Red
        [2] = {0.40, 0.95, 0.40},  -- Green
        [3] = {0.40, 0.60, 0.95},  -- Blue
        [4] = {0.95, 0.95, 0.40},  -- Yellow
        [5] = {0.95, 0.40, 0.95},  -- Magenta
        [6] = {0.40, 0.95, 0.95},  -- Cyan
        [7] = {0.95, 0.70, 0.40},  -- Orange
        [8] = {0.70, 0.40, 0.95},  -- Purple
    }
    
    local groupItems = {}
    local ITEM_HEIGHT = 28
    local draggingItem = nil
    local dragOffsetY = 0
    
    -- Get current order from db or use default
    local function GetCurrentOrder()
        if dbTable and dbKey and dbTable[dbKey] then
            -- Validate and return existing order
            local order = {}
            local seen = {}
            for _, groupNum in ipairs(dbTable[dbKey]) do
                if groupNum >= 1 and groupNum <= 8 and not seen[groupNum] then
                    table.insert(order, groupNum)
                    seen[groupNum] = true
                end
            end
            -- Add any missing groups
            for i = 1, 8 do
                if not seen[i] then
                    table.insert(order, i)
                end
            end
            return order
        end
        return {1, 2, 3, 4, 5, 6, 7, 8}
    end
    
    -- Save order to db
    local function SaveOrder(newOrder)
        if dbTable and dbKey then
            dbTable[dbKey] = newOrder
            -- Track override when editing a profile
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                local copy = {}
                for i, v in ipairs(newOrder) do copy[i] = v end
                DF.AutoProfilesUI:SetProfileSetting(dbKey, copy)
            end
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(newOrder)
            end
            if callback then callback() end
        end
    end
    
    -- Get index from Y position
    local function GetIndexFromY(y)
        local containerTop = container:GetTop()
        if not containerTop then return 1 end
        local relativeY = containerTop - y
        local index = math.floor(relativeY / ITEM_HEIGHT) + 1
        return math.max(1, math.min(index, 8))
    end
    
    -- Update visual positions
    local function UpdateItemPositions()
        local order = GetCurrentOrder()
        
        for _, item in pairs(groupItems) do
            item:Hide()
        end
        
        for displayPos, groupNum in ipairs(order) do
            local item = groupItems[groupNum]
            if item then
                item:Show()
                item.displayPos = displayPos
                item.numText:SetText(displayPos .. ".")
                if item ~= draggingItem then
                    item:ClearAllPoints()
                    item:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((displayPos - 1) * ITEM_HEIGHT))
                    item:SetWidth(container:GetWidth() > 0 and container:GetWidth() or 180)
                end
            end
        end
    end
    
    -- Create grip texture (3 horizontal lines)
    local function CreateGripTexture(parentFrame)
        local grip = CreateFrame("Frame", nil, parentFrame)
        grip:SetSize(12, 14)
        
        for i = 1, 3 do
            local line = grip:CreateTexture(nil, "ARTWORK")
            line:SetSize(10, 2)
            line:SetPoint("TOP", grip, "TOP", 0, -2 - (i - 1) * 4)
            line:SetColorTexture(0.5, 0.5, 0.5, 1)
            grip["line" .. i] = line
        end
        
        grip.SetGripColor = function(self, r, g, b)
            for i = 1, 3 do
                self["line" .. i]:SetColorTexture(r, g, b, 1)
            end
        end
        
        return grip
    end
    
    -- Create a single group item
    local function CreateGroupItem(groupNum)
        local color = GROUP_COLORS[groupNum]
        
        local item = CreateFrame("Frame", nil, container, "BackdropTemplate")
        item:SetHeight(ITEM_HEIGHT - 2)
        item:EnableMouse(true)
        item:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        item:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
        item:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        
        -- Grip texture
        local grip = CreateGripTexture(item)
        grip:SetPoint("LEFT", 6, 0)
        item.grip = grip
        
        -- Display position number
        local numText = item:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        numText:SetPoint("LEFT", grip, "RIGHT", 6, 0)
        numText:SetWidth(18)
        numText:SetJustifyH("LEFT")
        item.numText = numText
        
        -- Color swatch
        local swatch = item:CreateTexture(nil, "ARTWORK")
        swatch:SetSize(14, 14)
        swatch:SetPoint("LEFT", numText, "RIGHT", 4, 0)
        swatch:SetColorTexture(color[1], color[2], color[3], 1)
        item.swatch = swatch
        
        -- Group name
        local text = item:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("LEFT", swatch, "RIGHT", 6, 0)
        text:SetText("Group " .. groupNum)
        text:SetTextColor(color[1], color[2], color[3])
        item.text = text
        
        item.groupNum = groupNum
        item.displayPos = groupNum
        
        -- Mouse handlers for dragging
        item:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                draggingItem = self
                local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
                local itemTop = self:GetTop()
                dragOffsetY = itemTop - cursorY
                
                self:SetBackdropColor(0.28, 0.28, 0.55, 0.9)
                self:SetBackdropBorderColor(0.45, 0.45, 0.95, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 10)
                self.grip:SetGripColor(1, 1, 1)
            end
        end)
        
        item:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and draggingItem == self then
                local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
                local newIndex = GetIndexFromY(cursorY)
                
                -- Reorder
                local currentOrder = GetCurrentOrder()
                local oldIndex = self.displayPos
                
                if newIndex ~= oldIndex then
                    table.remove(currentOrder, oldIndex)
                    table.insert(currentOrder, newIndex, self.groupNum)
                    SaveOrder(currentOrder)
                end
                
                draggingItem = nil
                self:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
                
                UpdateItemPositions()
            end
        end)
        
        item:SetScript("OnUpdate", function(self)
            if draggingItem ~= self then return end
            
            local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local containerTop = container:GetTop()
            local containerBottom = container:GetBottom()
            
            if not containerTop or not containerBottom then return end
            
            local targetY = cursorY + dragOffsetY
            local offsetFromTop = containerTop - targetY
            
            local maxOffset = (containerTop - containerBottom) - ITEM_HEIGHT + 5
            offsetFromTop = math.max(0, math.min(offsetFromTop, maxOffset))
            
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -offsetFromTop)
            self:SetWidth(container:GetWidth())
            
            -- Update other items based on where this would drop
            local dropIndex = GetIndexFromY(cursorY)
            local order = GetCurrentOrder()
            
            -- Build temp order: remove self, insert at drop position
            local tempOrder = {}
            for i, g in ipairs(order) do
                if groupItems[g] ~= self then
                    table.insert(tempOrder, g)
                end
            end
            table.insert(tempOrder, dropIndex, self.groupNum)
            
            -- Position all other items according to temp order
            for i, g in ipairs(tempOrder) do
                local otherItem = groupItems[g]
                if otherItem and otherItem ~= self then
                    otherItem:ClearAllPoints()
                    otherItem:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ITEM_HEIGHT))
                    otherItem:SetWidth(container:GetWidth())
                    otherItem.numText:SetText(i .. ".")
                end
            end
        end)
        
        item:SetScript("OnEnter", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
                self.grip:SetGripColor(0.8, 0.8, 0.8)
            end
        end)
        
        item:SetScript("OnLeave", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
            end
        end)
        
        return item
    end
    
    -- Create all group items
    for i = 1, 8 do
        groupItems[i] = CreateGroupItem(i)
    end
    
    -- Initial layout
    UpdateItemPositions()
    
    -- Refresh function
    container.Refresh = function()
        UpdateItemPositions()
    end
    
    -- Override indicators for profile editing
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and type(globalVal) == "table" then
                    local copy = {}
                    for i, v in ipairs(globalVal) do copy[i] = v end
                    dbTable[dbKey] = copy
                end
                UpdateItemPositions()
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(dbTable[dbKey])
                end
                if callback then callback() end
            end
        end
        AddOrderListOverrideIndicators(container, dbKey, onReset)
        
        container:SetScript("OnShow", function()
            UpdateItemPositions()
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
            end
        end)
    end
    
    return container
end

-- ============================================================
-- HIGHLIGHT FRAMES ROSTER WIDGET
-- ============================================================
-- Dual-column widget for selecting players to highlight
-- Left: Current group roster
-- Right: Selected players (draggable for reorder)

function GUI:CreateHighlightRosterWidget(parent, getPlayersFunc, setPlayersFunc, onChangeCallback)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(460, 340)
    
    local ITEM_HEIGHT = 26
    local COL_WIDTH = 224  -- Wider columns
    local COL_GAP = 12     -- Smaller gap between columns
    
    -- State
    local rosterItems = {}
    local highlightItems = {}
    local currentRoster = {}
    local draggingItem = nil
    local dragOffsetY = 0
    
    -- Custom role icons
    local ROLE_ICONS = {
        TANK = "Interface\\AddOns\\DandersFrames\\Media\\DF_Tank",
        HEALER = "Interface\\AddOns\\DandersFrames\\Media\\DF_Healer",
        DAMAGER = "Interface\\AddOns\\DandersFrames\\Media\\DF_DPS",
    }
    local ROLE_COLORS = {
        TANK = {0.35, 0.56, 0.82},
        HEALER = {0.29, 0.62, 0.29},
        DAMAGER = {0.70, 0.35, 0.35},
    }
    
    -- Icon paths
    local ICON_ARROW = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right"
    local ICON_CHECK = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\check"
    local ICON_CLOSE = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\close"
    
    -- ========== LEFT COLUMN: Group Roster ==========
    local leftHeader = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    leftHeader:SetPoint("TOPLEFT", 0, 0)
    leftHeader:SetText("Group Roster")
    leftHeader:SetTextColor(0.7, 0.7, 0.7)
    
    local leftCount = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    leftCount:SetPoint("LEFT", leftHeader, "RIGHT", 8, 0)
    leftCount:SetTextColor(0.5, 0.5, 0.5)
    
    local leftBg = CreateFrame("Frame", nil, container, "BackdropTemplate")
    leftBg:SetPoint("TOPLEFT", 0, -18)
    leftBg:SetSize(COL_WIDTH, 240)
    leftBg:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    leftBg:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
    leftBg:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    
    local leftScroll = CreateFrame("ScrollFrame", nil, leftBg, "UIPanelScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT", 4, -4)
    leftScroll:SetPoint("BOTTOMRIGHT", -24, 4)
    
    local leftContent = CreateFrame("Frame", nil, leftScroll)
    leftContent:SetSize(COL_WIDTH - 28, 1)
    leftScroll:SetScrollChild(leftContent)
    
    -- ========== RIGHT COLUMN: Highlighted Units ==========
    local rightHeader = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rightHeader:SetPoint("TOPLEFT", leftBg, "TOPRIGHT", COL_GAP, 18)
    rightHeader:SetText("Highlighted Units")
    rightHeader:SetTextColor(0.7, 0.7, 0.7)
    
    local rightCount = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rightCount:SetPoint("LEFT", rightHeader, "RIGHT", 8, 0)
    rightCount:SetTextColor(0.5, 0.5, 0.5)
    
    local rightBg = CreateFrame("Frame", nil, container, "BackdropTemplate")
    rightBg:SetPoint("TOPLEFT", leftBg, "TOPRIGHT", COL_GAP, 0)
    rightBg:SetSize(COL_WIDTH, 240)
    rightBg:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    rightBg:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
    rightBg:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    
    local rightScroll = CreateFrame("ScrollFrame", nil, rightBg, "UIPanelScrollFrameTemplate")
    rightScroll:SetPoint("TOPLEFT", 4, -4)
    rightScroll:SetPoint("BOTTOMRIGHT", -24, 4)
    
    local rightContent = CreateFrame("Frame", nil, rightScroll)
    rightContent:SetSize(COL_WIDTH - 28, 1)
    rightScroll:SetScrollChild(rightContent)
    
    -- ========== HELPER FUNCTIONS ==========
    
    -- Get current group roster
    local function GetGroupRoster()
        local roster = {}
        local numMembers = GetNumGroupMembers()
        if numMembers == 0 then
            -- Solo - just show player
            local name = UnitName("player")
            local realm = GetRealmName()
            local _, class = UnitClass("player")
            table.insert(roster, {
                name = name,
                fullName = name .. "-" .. realm,
                class = class or "WARRIOR",
                role = "DAMAGER",
                group = 1,
            })
            return roster
        end
        
        local isRaid = IsInRaid()
        
        for i = 1, numMembers do
            local unit = isRaid and ("raid" .. i) or (i == 1 and "player" or "party" .. (i - 1))
            local name, realm = UnitName(unit)
            
            if name then
                realm = realm or GetRealmName()
                local fullName = name .. "-" .. realm
                local _, class = UnitClass(unit)
                local role = UnitGroupRolesAssigned(unit)
                if role == "NONE" then role = "DAMAGER" end
                local group = 1
                if isRaid then
                    local raidIndex = UnitInRaid(unit)
                    if raidIndex then
                        local _, _, subgroup = GetRaidRosterInfo(raidIndex + 1)
                        group = subgroup or 1
                    end
                end
                
                table.insert(roster, {
                    name = name,
                    fullName = fullName,
                    class = class or "WARRIOR",
                    role = role or "DAMAGER",
                    group = group,
                })
            end
        end
        
        -- Sort by group, then role, then name
        table.sort(roster, function(a, b)
            if a.group ~= b.group then return a.group < b.group end
            local roleOrder = { TANK = 1, HEALER = 2, DAMAGER = 3 }
            local aRole = roleOrder[a.role] or 3
            local bRole = roleOrder[b.role] or 3
            if aRole ~= bRole then return aRole < bRole end
            return a.name < b.name
        end)
        
        return roster
    end
    
    -- Check if player is in highlighted list
    local function IsPlayerHighlighted(fullName)
        local players = getPlayersFunc()
        for _, p in ipairs(players) do
            if p == fullName then return true end
        end
        return false
    end
    
    -- Check if player is in current group
    local function IsPlayerInGroup(fullName)
        for _, p in ipairs(currentRoster) do
            if p.fullName == fullName or p.name == fullName then
                return true, p
            end
        end
        return false, nil
    end
    
    -- Add player to highlight list
    local function AddPlayer(fullName)
        local players = getPlayersFunc()
        if not IsPlayerHighlighted(fullName) then
            table.insert(players, fullName)
            setPlayersFunc(players)
            if onChangeCallback then onChangeCallback() end
        end
    end
    
    -- Remove player from highlight list
    local function RemovePlayer(fullName)
        local players = getPlayersFunc()
        for i, p in ipairs(players) do
            if p == fullName then
                table.remove(players, i)
                setPlayersFunc(players)
                if onChangeCallback then onChangeCallback() end
                break
            end
        end
    end
    
    -- Create grip texture
    local function CreateGripTexture(parentFrame)
        local grip = CreateFrame("Frame", nil, parentFrame)
        grip:SetSize(12, 14)
        
        for i = 1, 3 do
            local line = grip:CreateTexture(nil, "ARTWORK")
            line:SetSize(10, 2)
            line:SetPoint("TOP", grip, "TOP", 0, -2 - (i - 1) * 4)
            line:SetColorTexture(0.5, 0.5, 0.5, 1)
            grip["line" .. i] = line
        end
        
        grip.SetGripColor = function(self, r, g, b)
            for i = 1, 3 do
                self["line" .. i]:SetColorTexture(r, g, b, 1)
            end
        end
        
        return grip
    end
    
    -- Create role icon using custom textures
    local function CreateRoleIcon(parentFrame, role)
        local icon = parentFrame:CreateTexture(nil, "ARTWORK")
        icon:SetSize(14, 14)
        icon:SetTexture(ROLE_ICONS[role] or ROLE_ICONS.DAMAGER)
        return icon
    end
    
    -- ========== ROSTER ITEM (Left Column) ==========
    local function CreateRosterItem(playerData, index)
        local item = CreateFrame("Frame", nil, leftContent, "BackdropTemplate")
        item:SetHeight(ITEM_HEIGHT - 2)
        item:SetPoint("TOPLEFT", 0, -((index - 1) * ITEM_HEIGHT))
        item:SetPoint("TOPRIGHT", 0, -((index - 1) * ITEM_HEIGHT))
        item:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
        })
        item:SetBackdropColor(0, 0, 0, 0)
        
        item.playerData = playerData
        
        -- Role icon
        local roleIcon = CreateRoleIcon(item, playerData.role)
        roleIcon:SetPoint("LEFT", 4, 0)
        item.roleIcon = roleIcon
        
        -- Name (class colored)
        local nameText = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameText:SetPoint("LEFT", roleIcon, "RIGHT", 6, 0)
        nameText:SetPoint("RIGHT", -70, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetText(playerData.name)
        local classColor = DF:GetClassColor(playerData.class)
        if classColor then
            nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
        else
            nameText:SetTextColor(0.8, 0.8, 0.8)
        end
        item.nameText = nameText
        
        -- Group number
        local groupText = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        groupText:SetPoint("RIGHT", -34, 0)
        groupText:SetText("G" .. playerData.group)
        groupText:SetTextColor(0.4, 0.4, 0.4)
        item.groupText = groupText
        
        -- Add button
        local addBtn = CreateFrame("Button", nil, item, "BackdropTemplate")
        addBtn:SetSize(26, 20)
        addBtn:SetPoint("RIGHT", -4, 0)
        addBtn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        
        local themeColor = GetThemeColor()
        
        -- Icon for button
        addBtn.icon = addBtn:CreateTexture(nil, "OVERLAY")
        addBtn.icon:SetSize(12, 12)
        addBtn.icon:SetPoint("CENTER", 0, 0)
        
        local function UpdateAddButton()
            local isHighlighted = IsPlayerHighlighted(playerData.fullName)
            if isHighlighted then
                addBtn:SetBackdropColor(0.15, 0.15, 0.15, 0.8)
                addBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
                addBtn.icon:SetTexture(ICON_CHECK)
                addBtn.icon:SetVertexColor(0.4, 0.4, 0.4)
                item:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
                nameText:SetAlpha(0.5)
                groupText:SetAlpha(0.5)
                roleIcon:SetAlpha(0.5)
            else
                addBtn:SetBackdropColor(themeColor.r * 0.2, themeColor.g * 0.2, themeColor.b * 0.2, 0.8)
                addBtn:SetBackdropBorderColor(themeColor.r * 0.5, themeColor.g * 0.5, themeColor.b * 0.5, 0.8)
                addBtn.icon:SetTexture(ICON_ARROW)
                addBtn.icon:SetVertexColor(themeColor.r, themeColor.g, themeColor.b)
                item:SetBackdropColor(0, 0, 0, 0)
                nameText:SetAlpha(1)
                groupText:SetAlpha(1)
                roleIcon:SetAlpha(1)
            end
        end
        
        addBtn:SetScript("OnClick", function()
            if not IsPlayerHighlighted(playerData.fullName) then
                AddPlayer(playerData.fullName)
                container:Refresh()
            end
        end)
        
        addBtn:SetScript("OnEnter", function(self)
            if not IsPlayerHighlighted(playerData.fullName) then
                self:SetBackdropColor(themeColor.r * 0.3, themeColor.g * 0.3, themeColor.b * 0.3, 1)
                self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
            end
        end)
        
        addBtn:SetScript("OnLeave", function(self)
            UpdateAddButton()
        end)
        
        item.addBtn = addBtn
        item.UpdateAddButton = UpdateAddButton
        UpdateAddButton()
        
        return item
    end
    
    -- ========== HIGHLIGHT ITEM (Right Column - Draggable) ==========
    local function CreateHighlightItem(fullName, index, totalCount)
        local item = CreateFrame("Frame", nil, rightContent, "BackdropTemplate")
        item:SetHeight(ITEM_HEIGHT - 2)
        item:SetPoint("TOPLEFT", 0, -((index - 1) * ITEM_HEIGHT))
        item:SetPoint("TOPRIGHT", 0, -((index - 1) * ITEM_HEIGHT))
        item:EnableMouse(true)
        item:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        item:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
        item:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
        
        item.fullName = fullName
        item.index = index
        
        -- Check if player is in current group
        local inGroup, playerData = IsPlayerInGroup(fullName)
        
        -- Grip handle
        local grip = CreateGripTexture(item)
        grip:SetPoint("LEFT", 4, 0)
        item.grip = grip
        
        -- Position number
        local themeColor = GetThemeColor()
        local numText = item:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        numText:SetPoint("LEFT", grip, "RIGHT", 6, 0)
        numText:SetWidth(20)
        numText:SetJustifyH("LEFT")
        numText:SetText(index .. ".")
        numText:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
        item.numText = numText
        
        -- Role icon
        local role = playerData and playerData.role or "DAMAGER"
        local roleIcon = CreateRoleIcon(item, role)
        roleIcon:SetPoint("LEFT", numText, "RIGHT", 4, 0)
        item.roleIcon = roleIcon
        
        -- Name
        local displayName = fullName:match("([^%-]+)") or fullName  -- Get name before realm
        local nameText = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameText:SetPoint("LEFT", roleIcon, "RIGHT", 6, 0)
        nameText:SetPoint("RIGHT", -34, 0)
        nameText:SetJustifyH("LEFT")
        
        if playerData then
            nameText:SetText(playerData.name)
            local classColor = DF:GetClassColor(playerData.class)
            if classColor then
                nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
            end
        else
            -- Player not in group
            nameText:SetText(displayName .. " (offline)")
            nameText:SetTextColor(0.5, 0.5, 0.5)
            item:SetBackdropColor(0.1, 0.1, 0.1, 0.7)
            grip:SetGripColor(0.35, 0.35, 0.35)
            roleIcon:SetAlpha(0.5)
        end
        item.nameText = nameText
        
        -- Remove button
        local removeBtn = CreateFrame("Button", nil, item, "BackdropTemplate")
        removeBtn:SetSize(26, 20)
        removeBtn:SetPoint("RIGHT", -4, 0)
        removeBtn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        removeBtn:SetBackdropColor(0.5, 0.15, 0.15, 0.5)
        removeBtn:SetBackdropBorderColor(0.6, 0.25, 0.25, 0.8)
        
        -- X icon for remove button
        removeBtn.icon = removeBtn:CreateTexture(nil, "OVERLAY")
        removeBtn.icon:SetSize(12, 12)
        removeBtn.icon:SetPoint("CENTER", 0, 0)
        removeBtn.icon:SetTexture(ICON_CLOSE)
        removeBtn.icon:SetVertexColor(0.8, 0.3, 0.3)
        
        removeBtn:SetScript("OnClick", function()
            RemovePlayer(fullName)
            container:Refresh()
        end)
        
        removeBtn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.6, 0.2, 0.2, 0.8)
            self:SetBackdropBorderColor(0.8, 0.3, 0.3, 1)
        end)
        
        removeBtn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.5, 0.15, 0.15, 0.5)
            self:SetBackdropBorderColor(0.6, 0.25, 0.25, 0.8)
        end)
        
        item.removeBtn = removeBtn
        
        -- ========== DRAG HANDLERS ==========
        item:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                draggingItem = self
                local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
                local itemTop = self:GetTop()
                dragOffsetY = itemTop - cursorY
                
                self:SetBackdropColor(0.25, 0.25, 0.4, 0.95)
                self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
                self:SetFrameLevel(rightContent:GetFrameLevel() + 10)
                self.grip:SetGripColor(1, 1, 1)
            end
        end)
        
        item:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and draggingItem == self then
                local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
                local contentTop = rightContent:GetTop()
                if contentTop then
                    local relativeY = contentTop - cursorY
                    local newIndex = math.floor(relativeY / ITEM_HEIGHT) + 1
                    newIndex = math.max(1, math.min(newIndex, totalCount))
                    
                    local oldIndex = self.index
                    if newIndex ~= oldIndex then
                        -- Reorder the players array
                        local players = getPlayersFunc()
                        local removed = table.remove(players, oldIndex)
                        table.insert(players, newIndex, removed)
                        setPlayersFunc(players)
                        if onChangeCallback then onChangeCallback() end
                    end
                end
                
                draggingItem = nil
                container:Refresh()
            end
        end)
        
        item:SetScript("OnUpdate", function(self)
            if draggingItem ~= self then return end
            
            local cursorY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local contentTop = rightContent:GetTop()
            local contentBottom = rightContent:GetBottom()
            
            if not contentTop or not contentBottom then return end
            
            local targetY = cursorY + dragOffsetY
            local offsetFromTop = contentTop - targetY
            
            local maxOffset = math.max(0, (totalCount - 1) * ITEM_HEIGHT)
            offsetFromTop = math.max(0, math.min(offsetFromTop, maxOffset))
            
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", rightContent, "TOPLEFT", 0, -offsetFromTop)
            self:SetPoint("TOPRIGHT", rightContent, "TOPRIGHT", 0, -offsetFromTop)
            
            -- Update visual positions of other items
            local dropIndex = math.floor(offsetFromTop / ITEM_HEIGHT) + 1
            dropIndex = math.max(1, math.min(dropIndex, totalCount))
            
            for _, otherItem in ipairs(highlightItems) do
                if otherItem ~= self then
                    local visualIndex = otherItem.index
                    if self.index < dropIndex then
                        -- Dragging down
                        if otherItem.index > self.index and otherItem.index <= dropIndex then
                            visualIndex = otherItem.index - 1
                        end
                    else
                        -- Dragging up
                        if otherItem.index < self.index and otherItem.index >= dropIndex then
                            visualIndex = otherItem.index + 1
                        end
                    end
                    otherItem:ClearAllPoints()
                    otherItem:SetPoint("TOPLEFT", rightContent, "TOPLEFT", 0, -((visualIndex - 1) * ITEM_HEIGHT))
                    otherItem:SetPoint("TOPRIGHT", rightContent, "TOPRIGHT", 0, -((visualIndex - 1) * ITEM_HEIGHT))
                    otherItem.numText:SetText(visualIndex .. ".")
                end
            end
        end)
        
        -- Hover effects
        item:SetScript("OnEnter", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
                self.grip:SetGripColor(0.8, 0.8, 0.8)
            end
        end)
        
        item:SetScript("OnLeave", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
                if inGroup then
                    self.grip:SetGripColor(0.5, 0.5, 0.5)
                else
                    self.grip:SetGripColor(0.35, 0.35, 0.35)
                end
            end
        end)
        
        return item
    end
    
    -- ========== QUICK ADD BUTTONS ==========
    local buttonRow = CreateFrame("Frame", nil, container)
    buttonRow:SetSize(460, 28)
    buttonRow:SetPoint("TOPLEFT", leftBg, "BOTTOMLEFT", 0, -8)
    
    local function CreateQuickAddButton(text, role, color, xOffset)
        local btn = CreateFrame("Button", nil, buttonRow, "BackdropTemplate")
        btn:SetSize(68, 24)
        btn:SetPoint("LEFT", xOffset, 0)
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(color[1] * 0.15, color[2] * 0.15, color[3] * 0.15, 0.9)
        btn:SetBackdropBorderColor(color[1] * 0.5, color[2] * 0.5, color[3] * 0.5, 0.8)
        
        btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.text:SetPoint("CENTER")
        btn.text:SetText(text)
        btn.text:SetTextColor(color[1], color[2], color[3])
        
        btn:SetScript("OnClick", function()
            local players = getPlayersFunc()
            for _, player in ipairs(currentRoster) do
                if role == "ALL" or player.role == role then
                    if not IsPlayerHighlighted(player.fullName) then
                        table.insert(players, player.fullName)
                    end
                end
            end
            setPlayersFunc(players)
            if onChangeCallback then onChangeCallback() end
            container:Refresh()
        end)
        
        btn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(color[1] * 0.25, color[2] * 0.25, color[3] * 0.25, 1)
            self:SetBackdropBorderColor(color[1], color[2], color[3], 1)
        end)
        
        btn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(color[1] * 0.15, color[2] * 0.15, color[3] * 0.15, 0.9)
            self:SetBackdropBorderColor(color[1] * 0.5, color[2] * 0.5, color[3] * 0.5, 0.8)
        end)
        
        return btn
    end
    
    local tankBtn = CreateQuickAddButton("+ Tanks", "TANK", ROLE_COLORS.TANK, 0)
    local healerBtn = CreateQuickAddButton("+ Healers", "HEALER", ROLE_COLORS.HEALER, 72)
    local dpsBtn = CreateQuickAddButton("+ DPS", "DAMAGER", ROLE_COLORS.DAMAGER, 144)
    local allBtn = CreateQuickAddButton("+ All", "ALL", {0.6, 0.6, 0.6}, 216)
    
    -- Clear All button (right side)
    local clearBtn = CreateFrame("Button", nil, buttonRow, "BackdropTemplate")
    clearBtn:SetSize(68, 24)
    clearBtn:SetPoint("RIGHT", 0, 0)
    clearBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    clearBtn:SetBackdropColor(0.5, 0.15, 0.15, 0.5)
    clearBtn:SetBackdropBorderColor(0.6, 0.25, 0.25, 0.8)
    
    clearBtn.text = clearBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clearBtn.text:SetPoint("CENTER")
    clearBtn.text:SetText("Clear All")
    clearBtn.text:SetTextColor(0.8, 0.35, 0.35)
    
    clearBtn:SetScript("OnClick", function()
        setPlayersFunc({})
        if onChangeCallback then onChangeCallback() end
        container:Refresh()
    end)
    
    clearBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.6, 0.2, 0.2, 0.8)
        self:SetBackdropBorderColor(0.8, 0.3, 0.3, 1)
    end)
    
    clearBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.5, 0.15, 0.15, 0.5)
        self:SetBackdropBorderColor(0.6, 0.25, 0.25, 0.8)
    end)
    
    -- Remove Offline button (next to Clear All)
    local removeOfflineBtn = CreateFrame("Button", nil, buttonRow, "BackdropTemplate")
    removeOfflineBtn:SetSize(90, 24)
    removeOfflineBtn:SetPoint("RIGHT", clearBtn, "LEFT", -6, 0)
    removeOfflineBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    removeOfflineBtn:SetBackdropColor(0.4, 0.3, 0.15, 0.5)
    removeOfflineBtn:SetBackdropBorderColor(0.5, 0.4, 0.2, 0.8)
    
    removeOfflineBtn.text = removeOfflineBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    removeOfflineBtn.text:SetPoint("CENTER")
    removeOfflineBtn.text:SetText("Remove Offline")
    removeOfflineBtn.text:SetTextColor(0.7, 0.55, 0.3)
    
    removeOfflineBtn:SetScript("OnClick", function()
        local players = getPlayersFunc()
        local newPlayers = {}
        
        -- Keep only players that are in the current roster
        for _, fullName in ipairs(players) do
            local inGroup = false
            for _, p in ipairs(currentRoster) do
                if p.fullName == fullName or p.name == fullName then
                    inGroup = true
                    break
                end
            end
            if inGroup then
                table.insert(newPlayers, fullName)
            end
        end
        
        setPlayersFunc(newPlayers)
        if onChangeCallback then onChangeCallback() end
        container:Refresh()
    end)
    
    removeOfflineBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.5, 0.4, 0.2, 0.8)
        self:SetBackdropBorderColor(0.7, 0.55, 0.3, 1)
    end)
    
    removeOfflineBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.4, 0.3, 0.15, 0.5)
        self:SetBackdropBorderColor(0.5, 0.4, 0.2, 0.8)
    end)
    
    -- ========== MANUAL PLAYER ENTRY ==========
    local themeColor = GetThemeColor()
    local manualHeader = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    manualHeader:SetPoint("TOPLEFT", buttonRow, "BOTTOMLEFT", 0, -12)
    manualHeader:SetText("Add Offline Player")
    manualHeader:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    
    local manualHelp = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    manualHelp:SetPoint("TOPLEFT", manualHeader, "BOTTOMLEFT", 0, -2)
    manualHelp:SetText("Pre-configure players before they join the group")
    manualHelp:SetTextColor(0.45, 0.45, 0.45)
    
    local manualInput = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    manualInput:SetPoint("TOPLEFT", manualHelp, "BOTTOMLEFT", 0, -6)
    manualInput:SetSize(380, 24)
    manualInput:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    manualInput:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    manualInput:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    manualInput:SetFontObject(GameFontHighlight)
    manualInput:SetTextInsets(8, 8, 0, 0)
    manualInput:SetAutoFocus(false)
    manualInput:SetMaxLetters(50)
    
    manualInput:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    
    manualInput:SetScript("OnEnterPressed", function(self)
        local text = self:GetText():trim()
        if text ~= "" then
            -- Add realm if not present
            if not text:find("-") then
                text = text .. "-" .. GetRealmName()
            end
            AddPlayer(text)
            self:SetText("")
            container:Refresh()
        end
        self:ClearFocus()
    end)
    
    local addManualBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    addManualBtn:SetPoint("LEFT", manualInput, "RIGHT", 6, 0)
    addManualBtn:SetSize(54, 24)
    addManualBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    addManualBtn:SetBackdropColor(themeColor.r * 0.2, themeColor.g * 0.2, themeColor.b * 0.2, 0.9)
    addManualBtn:SetBackdropBorderColor(themeColor.r * 0.5, themeColor.g * 0.5, themeColor.b * 0.5, 0.8)
    
    addManualBtn.text = addManualBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    addManualBtn.text:SetPoint("CENTER")
    addManualBtn.text:SetText("Add")
    addManualBtn.text:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    
    addManualBtn:SetScript("OnClick", function()
        local text = manualInput:GetText():trim()
        if text ~= "" then
            if not text:find("-") then
                text = text .. "-" .. GetRealmName()
            end
            AddPlayer(text)
            manualInput:SetText("")
            container:Refresh()
        end
    end)
    
    addManualBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(themeColor.r * 0.3, themeColor.g * 0.3, themeColor.b * 0.3, 1)
        self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
    end)
    
    addManualBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(themeColor.r * 0.2, themeColor.g * 0.2, themeColor.b * 0.2, 0.9)
        self:SetBackdropBorderColor(themeColor.r * 0.5, themeColor.g * 0.5, themeColor.b * 0.5, 0.8)
    end)
    
    -- ========== REFRESH FUNCTION ==========
    function container:Refresh()
        -- Get current roster
        currentRoster = GetGroupRoster()
        local players = getPlayersFunc()
        
        -- Clear existing items
        for _, item in ipairs(rosterItems) do
            item:Hide()
            item:SetParent(nil)
        end
        wipe(rosterItems)
        
        for _, item in ipairs(highlightItems) do
            item:Hide()
            item:SetParent(nil)
        end
        wipe(highlightItems)
        
        -- Update counts
        leftCount:SetText("(" .. #currentRoster .. ")")
        rightCount:SetText("(" .. #players .. ")")
        
        -- Build left column (roster)
        for i, playerData in ipairs(currentRoster) do
            local item = CreateRosterItem(playerData, i)
            table.insert(rosterItems, item)
        end
        leftContent:SetHeight(math.max(1, #currentRoster * ITEM_HEIGHT))
        
        -- Build right column (highlighted)
        for i, fullName in ipairs(players) do
            local item = CreateHighlightItem(fullName, i, #players)
            table.insert(highlightItems, item)
        end
        rightContent:SetHeight(math.max(1, #players * ITEM_HEIGHT))
        
        -- Show hint if empty
        if #players == 0 then
            if not container.emptyHint then
                container.emptyHint = rightContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                container.emptyHint:SetPoint("CENTER", rightBg, "CENTER", 0, 0)
                container.emptyHint:SetText("Add players from the roster\nor use quick add buttons")
                container.emptyHint:SetTextColor(0.35, 0.35, 0.35)
                container.emptyHint:SetJustifyH("CENTER")
            end
            container.emptyHint:Show()
        elseif container.emptyHint then
            container.emptyHint:Hide()
        end
    end
    
    -- Register for roster updates
    container:RegisterEvent("GROUP_ROSTER_UPDATE")
    container:RegisterEvent("PLAYER_ENTERING_WORLD")
    container:SetScript("OnEvent", function(self, event)
        self:Refresh()
    end)
    
    -- Initial refresh
    container:Refresh()
    
    return container
end

-- Gradient Preview Bar
function GUI:CreateGradientBar(parent, width, height, db, prefix)
    prefix = prefix or "healthColor"
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetSize(width or 360, height or 24)
    CreateElementBackdrop(f)
    
    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
    lbl:SetPoint("LEFT", f, "LEFT", 8, 0)
    lbl:SetText("0%")
    lbl:SetTextColor(1, 1, 1, 1)
    
    local lbl2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
    lbl2:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    lbl2:SetText("100%")
    lbl2:SetTextColor(1, 1, 1, 1)
    
    f.TexPool = {}
    
    f.UpdatePreview = function()
        if not db then return end
        
        for _, tex in ipairs(f.TexPool) do tex:Hide() end
        
        local _, pClass = UnitClass("player")
        local classCol = DF:GetClassColor(pClass)
        
        local function GetC(stage)
            if db[prefix .. stage .. "UseClass"] then
                return CreateColor(classCol.r, classCol.g, classCol.b, 1)
            end
            local c = db[prefix .. stage]
            if not c or not c.r then return CreateColor(1, 1, 1, 1) end
            return CreateColor(c.r, c.g, c.b, 1)
        end
        
        local lCol = GetC("Low")
        local mCol = GetC("Medium")
        local hCol = GetC("High")
        
        local lowW = math.max(1, math.floor(db[prefix .. "LowWeight"] or 1))
        local medW = math.max(1, math.floor(db[prefix .. "MediumWeight"] or 1))
        local highW = math.max(1, math.floor(db[prefix .. "HighWeight"] or 1))
        
        local points = {}
        for i = 1, lowW do table.insert(points, lCol) end
        for i = 1, medW do table.insert(points, mCol) end
        for i = 1, highW do table.insert(points, hCol) end
        
        if #points < 2 then points = {lCol, hCol} end
        
        local numSegments = #points - 1
        local segWidth = (f:GetWidth() - 4) / numSegments
        
        for i = 1, numSegments do
            local tex = f.TexPool[i]
            if not tex then
                tex = f:CreateTexture(nil, "ARTWORK")
                table.insert(f.TexPool, tex)
            end
            
            tex:Show()
            tex:ClearAllPoints()
            tex:SetPoint("LEFT", f, "LEFT", 2 + (i - 1) * segWidth, 0)
            tex:SetSize(segWidth, f:GetHeight() - 4)
            
            local c1 = points[i]
            local c2 = points[i + 1]
            
            tex:SetColorTexture(1, 1, 1, 1)
            tex:SetGradient("HORIZONTAL", c1, c2)
        end
    end
    
    f:SetScript("OnShow", f.UpdatePreview)
    f.UpdatePreview()
    return f
end

-- =========================================================================
-- MAIN GUI CREATION
-- =========================================================================

function DF:ToggleGUI()
    if DF.GUIFrame and DF.GUIFrame:IsShown() then
        DF.GUIFrame:Hide()
    else
        if not DF.GUIFrame then
            DF:CreateGUI()
        end
        
        -- Auto-detect mode based on current group status
        -- ARENA FIX: Arena returns IsInRaid()=true but uses party-style layout/settings.
        -- Check for arena first so the settings UI shows party settings, not raid.
        if DF.IsInArena and DF:IsInArena() then
            GUI.SelectedMode = "party"
        elseif IsInRaid() then
            GUI.SelectedMode = "raid"
        else
            GUI.SelectedMode = "party"
        end
        
        -- Update theme colors to match selected mode
        if GUI.UpdateThemeColors then
            GUI.UpdateThemeColors()
        end
        
        -- Show correct content for the selected mode
        if GUI.ShowNormalContent then
            GUI:ShowNormalContent()
        end
        
        -- Refresh editing UI state (re-enables tabs that were disabled when closed during editing)
        local AutoProfilesUI = DF.AutoProfilesUI
        if AutoProfilesUI and AutoProfilesUI.RefreshEditingUI then
            AutoProfilesUI:RefreshEditingUI()
        end

        -- Refresh override stars (shows if a runtime profile is active)
        if AutoProfilesUI and AutoProfilesUI.RefreshTabOverrideStars then
            AutoProfilesUI:RefreshTabOverrideStars()
        end
        
        DF.GUIFrame:Show()
        GUI:RefreshCurrentPage()

        -- Auto-show changelog on first open after update
        if DandersFramesDB_v2 and DandersFramesDB_v2.lastSeenVersion ~= DF.ADDON_VERSION then
            DandersFramesDB_v2.lastSeenVersion = DF.ADDON_VERSION
            if GUI.changelogOverlay and GUI.changelogContent and GUI.changelogScroll then
                GUI.changelogContent:SetWidth(GUI.changelogScroll:GetWidth())
                GUI.changelogContent:SetText(GUI.FormatChangelog(DF.CHANGELOG_TEXT))
                GUI.changelogContent:SetCursorPosition(0)
                GUI.changelogOverlay:Show()
            end
        end
    end
end

function DF:CreateGUI()
    if DF.GUIFrame then return end
    
    -- Default and saved sizes
    local defaultWidth, defaultHeight = 760, 520
    local minWidth, minHeight = 520, 400
    local maxWidth, maxHeight = 1200, 900
    
    -- Load saved position and size (stored in party db since it's always available)
    local guiDb = DF.db and DF.db.party or {}
    local savedScale = guiDb.guiScale or 1.0
    local savedWidth = guiDb.guiWidth or defaultWidth
    local savedHeight = guiDb.guiHeight or defaultHeight
    
    -- Main frame (matching old addon approach - no BackdropTemplate in CreateFrame)
    local frame = CreateFrame("Frame", "DandersFramesGUI", UIParent)
    frame:SetSize(savedWidth, savedHeight)
    -- Restore saved position, or default to center
    if guiDb.guiPoint and guiDb.guiX then
        frame:SetPoint(guiDb.guiPoint, UIParent, guiDb.guiRelPoint or "CENTER", guiDb.guiX, guiDb.guiY)
    else
        frame:SetPoint("CENTER")
    end
    frame:SetFrameStrata("DIALOG")  -- Match old addon
    frame:SetToplevel(true)         -- Match old addon
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(minWidth, minHeight, maxWidth, maxHeight)
    frame:EnableMouse(true)
    frame:SetScale(savedScale)
    -- Note: Dragging is handled by titleBar, not main frame
    CreatePanelBackdrop(frame)
    frame:Hide()
    DF.GUIFrame = frame
    
    -- Allow closing with Escape key
    tinsert(UISpecialFrames, "DandersFramesGUI")
    
    -- Exit profile editing when GUI is closed
    frame:SetScript("OnHide", function()
        local AutoProfilesUI = DF.AutoProfilesUI
        if AutoProfilesUI and AutoProfilesUI:IsEditing() then
            AutoProfilesUI:ExitEditing(true)  -- Skip UI updates since GUI is closing
        end
    end)
    
    -- Title bar (handles dragging like old addon)
    -- Uses FULLSCREEN_DIALOG strata so it stays above dropdown menus and popups,
    -- allowing the window to be dragged even when settings panels are open.
    local titleBar = CreateFrame("Frame", nil, frame)
    titleBar:SetHeight(30)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", -30, 0)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        -- Save position so it persists across sessions
        local point, _, relPoint, x, y = frame:GetPoint()
        if DF.db and DF.db.party then
            DF.db.party.guiPoint = point
            DF.db.party.guiRelPoint = relPoint
            DF.db.party.guiX = x
            DF.db.party.guiY = y
        end
    end)
    titleBar:SetFrameStrata("FULLSCREEN_DIALOG")
    titleBar:SetFrameLevel(200)
    
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 12, 0)
    local addonVer = DF.ADDON_VERSION
    local tocVer = DF.VERSION
    -- Prefer ADDON_VERSION from CI, fall back to TOC version, skip placeholders
    local versionStr
    if addonVer and addonVer ~= "dev" then
        versionStr = addonVer
    elseif tocVer and not tocVer:find("@") then
        versionStr = "v" .. tocVer
    else
        versionStr = "v" .. (DF.ADDON_VERSION_FALLBACK or "4.0.5")
    end
    local channelTags = { alpha = " |cffff8800alpha|r", beta = " |cffff8800beta|r" }
    local channelTag = channelTags[DF.RELEASE_CHANNEL] or ""
    title:SetText("DandersFrames " .. versionStr .. channelTag)
    local c = GetThemeColor()
    title:SetTextColor(c.r, c.g, c.b)
    title.UpdateTheme = function()
        local nc = GetThemeColor()
        title:SetTextColor(nc.r, nc.g, nc.b)
    end
    
    -- Close button with icon
    local closeBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("TOPRIGHT", -8, -5)
    closeBtn:SetFrameStrata("FULLSCREEN_DIALOG")
    closeBtn:SetFrameLevel(210)
    closeBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    closeBtn:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    closeBtn:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    local closeIcon = closeBtn:CreateTexture(nil, "OVERLAY")
    closeIcon:SetPoint("CENTER")
    closeIcon:SetSize(12, 12)
    closeIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
    closeIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    closeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(1, 0.3, 0.3, 1)
        closeIcon:SetVertexColor(1, 0.3, 0.3)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        closeIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- Info button (changelog)
    local infoBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    infoBtn:SetSize(20, 20)
    infoBtn:SetPoint("TOPRIGHT", -32, -5)
    infoBtn:SetFrameStrata("FULLSCREEN_DIALOG")
    infoBtn:SetFrameLevel(210)
    infoBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    infoBtn:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    infoBtn:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    local infoIcon = infoBtn:CreateTexture(nil, "OVERLAY")
    infoIcon:SetPoint("CENTER")
    infoIcon:SetSize(16, 16)
    infoIcon:SetAtlas("QuestNormal")
    infoIcon:SetDesaturated(true)
    infoIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    infoBtn:SetScript("OnEnter", function(self)
        local tc = GetThemeColor()
        self:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
        infoIcon:SetVertexColor(tc.r, tc.g, tc.b)
    end)
    infoBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        infoIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end)

    -- Changelog overlay (covers full content area below title bar)
    local changelogOverlay = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    changelogOverlay:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -30)
    changelogOverlay:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    changelogOverlay:SetFrameStrata("FULLSCREEN_DIALOG")
    changelogOverlay:SetFrameLevel(300)
    CreatePanelBackdrop(changelogOverlay)
    changelogOverlay:Hide()
    GUI.changelogOverlay = changelogOverlay

    -- Header bar within the overlay
    local changelogHeader = CreateFrame("Frame", nil, changelogOverlay)
    changelogHeader:SetPoint("TOPLEFT", 8, -8)
    changelogHeader:SetPoint("TOPRIGHT", -8, -8)
    changelogHeader:SetHeight(24)

    local changelogTitle = changelogHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    changelogTitle:SetPoint("LEFT", 4, 0)
    changelogTitle:SetText("Changelog — " .. versionStr)
    changelogTitle:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local backBtn = CreateFrame("Button", nil, changelogHeader, "BackdropTemplate")
    backBtn:SetSize(60, 22)
    backBtn:SetPoint("RIGHT", 0, 0)
    CreateElementBackdrop(backBtn)
    local backText = backBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    backText:SetPoint("CENTER")
    backText:SetText("Back")
    backText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    backBtn:SetScript("OnEnter", function(self)
        local tc = GetThemeColor()
        self:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
    end)
    backBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    end)
    backBtn:SetScript("OnClick", function() changelogOverlay:Hide() end)

    -- Convert markdown changelog to WoW color-coded plain text
    local function FormatChangelog(text)
        if not text or text == "" then return "No changelog available." end
        local tc = GetThemeColor()
        local themeHex = format("%02x%02x%02x", tc.r * 255, tc.g * 255, tc.b * 255)
        local dimHex = format("%02x%02x%02x", C_TEXT_DIM.r * 255, C_TEXT_DIM.g * 255, C_TEXT_DIM.b * 255)
        local textHex = format("%02x%02x%02x", C_TEXT.r * 255, C_TEXT.g * 255, C_TEXT.b * 255)

        local lines = {}
        for line in text:gmatch("[^\n]*") do
            if line:match("^# ") then
                -- Main title — skip (already shown in header bar)
            elseif line:match("^## ") then
                -- Version header
                local content = line:gsub("^##%s*", "")
                lines[#lines + 1] = format("|cff%s%s|r", themeHex, content)
            elseif line:match("^### ") then
                -- Section header
                local content = line:gsub("^###%s*", "")
                lines[#lines + 1] = format("\n|cff%s%s|r", textHex, content)
            elseif line:match("^%*%s") or line:match("^%-%s") then
                -- Bullet point
                local content = line:gsub("^[%*%-]%s*", "")
                lines[#lines + 1] = format("  |cff%s\226\128\162|r  |cff%s%s|r", themeHex, dimHex, content)
            elseif line:match("^%s*$") then
                lines[#lines + 1] = ""
            else
                lines[#lines + 1] = format("|cff%s%s|r", dimHex, line)
            end
        end

        return table.concat(lines, "\n")
    end

    local changelogScroll = CreateFrame("ScrollFrame", nil, changelogOverlay, "UIPanelScrollFrameTemplate")
    changelogScroll:SetPoint("TOPLEFT", 8, -38)
    changelogScroll:SetPoint("BOTTOMRIGHT", -26, 8)

    local changelogContent = CreateFrame("EditBox", nil, changelogScroll)
    changelogContent:SetMultiLine(true)
    changelogContent:SetAutoFocus(false)
    changelogContent:SetFontObject(GameFontHighlightSmall)
    changelogContent:SetWidth(changelogScroll:GetWidth() or 500)
    changelogContent:SetText(FormatChangelog(DF.CHANGELOG_TEXT))
    changelogContent:SetCursorPosition(0)
    changelogContent:EnableMouse(true)
    changelogContent:EnableKeyboard(false)
    changelogContent:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    changelogContent:SetScript("OnEditFocusGained", function(self) self:HighlightText(0, 0) end)
    changelogScroll:SetScrollChild(changelogContent)
    GUI.FormatChangelog = FormatChangelog
    GUI.changelogContent = changelogContent
    GUI.changelogScroll = changelogScroll

    infoBtn:SetScript("OnClick", function()
        if changelogOverlay:IsShown() then
            changelogOverlay:Hide()
        else
            changelogContent:SetWidth(changelogScroll:GetWidth())
            changelogContent:SetText(FormatChangelog(DF.CHANGELOG_TEXT))
            changelogContent:SetCursorPosition(0)
            changelogOverlay:Show()
        end
    end)

    -- =========================================================================
    -- RESIZE HANDLE (bottom-right corner)
    -- =========================================================================
    local resizeHandle = CreateFrame("Button", nil, frame)
    resizeHandle:SetSize(16, 16)
    resizeHandle:SetPoint("BOTTOMRIGHT", -2, 2)
    resizeHandle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeHandle:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeHandle:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeHandle:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizeHandle:SetScript("OnMouseUp", function(self, button)
        frame:StopMovingOrSizing()
        -- Save new size
        DF.db.party.guiWidth = frame:GetWidth()
        DF.db.party.guiHeight = frame:GetHeight()
        -- Update content layout
        if GUI.SelectedMode == "clicks" then
            -- Refresh click casting UI on resize (skip scroll reset)
            if DF.ClickCast and DF.ClickCast.RefreshSpellGrid then
                DF.ClickCast:RefreshSpellGrid(true)
            end
        elseif GUI.RefreshCurrentPage then
            GUI:RefreshCurrentPage()
        end
    end)
    
    -- Party/Raid mode toggle buttons
    local btnParty = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnParty:SetPoint("TOPLEFT", 12, -32)
    btnParty:SetSize(70, 24)
    CreateElementBackdrop(btnParty)
    btnParty.Text = btnParty:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btnParty.Text:SetPoint("CENTER")
    btnParty.Text:SetText("PARTY")
    GUI.PartyButton = btnParty  -- Store for external access
    
    local btnRaid = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnRaid:SetPoint("LEFT", btnParty, "RIGHT", 4, 0)
    btnRaid:SetSize(70, 24)
    CreateElementBackdrop(btnRaid)
    btnRaid.Text = btnRaid:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btnRaid.Text:SetPoint("CENTER")
    btnRaid.Text:SetText("RAID")
    GUI.RaidButton = btnRaid  -- Store for external access
    
    -- Click Casting tab button
    local btnClicks = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnClicks:SetPoint("LEFT", btnRaid, "RIGHT", 4, 0)
    btnClicks:SetSize(70, 24)
    CreateElementBackdrop(btnClicks)
    btnClicks.Text = btnClicks:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btnClicks.Text:SetPoint("CENTER")
    btnClicks.Text:SetText("BINDS")
    GUI.ClicksButton = btnClicks
    
    -- =========================================================================
    -- TEST MODE BUTTON (next to CLICKS tab)
    -- =========================================================================
    local btnTest = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnTest:SetPoint("LEFT", btnClicks, "RIGHT", 12, 0)
    btnTest:SetSize(75, 24)
    CreateElementBackdrop(btnTest)
    btnTest.Icon = btnTest:CreateTexture(nil, "OVERLAY")
    btnTest.Icon:SetPoint("LEFT", 6, 0)
    btnTest.Icon:SetSize(14, 14)
    btnTest.Icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\visibility")
    btnTest.Icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    btnTest.Text = btnTest:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btnTest.Text:SetPoint("LEFT", btnTest.Icon, "RIGHT", 4, 0)
    btnTest.Text:SetText("Test")
    btnTest.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    GUI.TestButton = btnTest
    
    -- =========================================================================
    -- LOCK/UNLOCK BUTTON (next to Test button)
    -- =========================================================================
    local btnLock = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnLock:SetPoint("LEFT", btnTest, "RIGHT", 4, 0)
    btnLock:SetSize(80, 24)
    CreateElementBackdrop(btnLock)
    btnLock.Icon = btnLock:CreateTexture(nil, "OVERLAY")
    btnLock.Icon:SetPoint("LEFT", 6, 0)
    btnLock.Icon:SetSize(14, 14)
    btnLock.Icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\lock")
    btnLock.Icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    btnLock.Text = btnLock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btnLock.Text:SetPoint("LEFT", btnLock.Icon, "RIGHT", 4, 0)
    btnLock.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    GUI.LockButton = btnLock
    
    -- Position override star (shown next to lock button when position is overridden)
    local positionOverrideStar = frame:CreateTexture(nil, "OVERLAY")
    positionOverrideStar:SetSize(14, 14)
    positionOverrideStar:SetPoint("LEFT", btnLock, "RIGHT", 4, 0)
    positionOverrideStar:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\star")
    positionOverrideStar:SetVertexColor(1, 0.8, 0.2)  -- Yellow/gold
    positionOverrideStar:Hide()
    GUI.PositionOverrideStar = positionOverrideStar
    
    -- Function to update position override indicator
    local function UpdatePositionOverrideIndicator()
        -- Debug mode shows indicator
        if overrideDebugMode then
            positionOverrideStar:Show()
            return
        end
        
        if GUI.SelectedMode ~= "raid" then
            positionOverrideStar:Hide()
            return
        end
        
        local AutoProfilesUI = DF.AutoProfilesUI
        if not AutoProfilesUI or not AutoProfilesUI:IsEditing() then
            positionOverrideStar:Hide()
            return
        end
        
        -- Check if position is overridden (either X or Y)
        local xOverridden = AutoProfilesUI:IsSettingOverridden("raidAnchorX")
        local yOverridden = AutoProfilesUI:IsSettingOverridden("raidAnchorY")
        
        if xOverridden or yOverridden then
            positionOverrideStar:Show()
        else
            positionOverrideStar:Hide()
        end
    end
    GUI.UpdatePositionOverrideIndicator = UpdatePositionOverrideIndicator
    
    -- Forward declaration (defined after UpdateThemeColors)
    local UpdateTestButtonState
    
    local function UpdateLockButtonState()
        local db = DF.db[GUI.SelectedMode]
        -- Raid mode uses raidLocked, party mode uses locked
        local isLocked = db and (GUI.SelectedMode == "raid" and db.raidLocked or db.locked)
        local themeColor = GetThemeColor()
        
        btnLock.Text:SetText(isLocked and "Unlock" or "Lock")
        btnLock.Icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. (isLocked and "lock" or "lock_open"))
        
        if not isLocked then
            -- Unlocked - highlight the button
            btnLock:SetBackdropColor(themeColor.r * 0.3, themeColor.g * 0.3, themeColor.b * 0.3, 1)
            btnLock:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
            btnLock.Text:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
            btnLock.Icon:SetVertexColor(themeColor.r, themeColor.g, themeColor.b)
        else
            -- Locked - normal state
            btnLock:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            btnLock:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.5)
            btnLock.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            btnLock.Icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
        
        -- Update position override indicator
        UpdatePositionOverrideIndicator()
    end
    GUI.UpdateLockButtonState = UpdateLockButtonState
    
    btnLock:SetScript("OnClick", function()
        local db = DF.db[GUI.SelectedMode]
        if not db then return end
        
        -- Check current lock state using the correct key per mode
        local isLocked = GUI.SelectedMode == "raid" and db.raidLocked or db.locked
        
        if GUI.SelectedMode == "raid" then
            if isLocked then
                DF:UnlockRaidFrames()
            else
                DF:LockRaidFrames()
            end
        else
            if isLocked then
                DF:UnlockFrames()
            else
                DF:LockFrames()
            end
        end
        
        -- Lock/Unlock functions now call UpdateLockButtonState themselves,
        -- but call it here too as a safety net
        UpdateLockButtonState()
        UpdateTestButtonState()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    
    -- =========================================================================
    -- UI SCALE SLIDER (top right, always visible with larger min frame size)
    -- =========================================================================
    local scaleContainer = CreateFrame("Frame", nil, frame)
    scaleContainer:SetSize(155, 24)
    scaleContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -32)
    
    local scaleLabel = scaleContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    scaleLabel:SetPoint("LEFT", 0, 0)
    scaleLabel:SetText("UI Scale:")
    scaleLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local scaleSlider = CreateFrame("Slider", nil, scaleContainer, "BackdropTemplate")
    scaleSlider:SetPoint("LEFT", scaleLabel, "RIGHT", 6, 0)
    scaleSlider:SetSize(65, 14)
    scaleSlider:SetOrientation("HORIZONTAL")
    scaleSlider:SetMinMaxValues(0.6, 1.4)
    scaleSlider:SetValueStep(0.05)
    scaleSlider:SetObeyStepOnDrag(true)
    scaleSlider:SetValue(savedScale)
    CreateElementBackdrop(scaleSlider)
    
    -- Thumb texture
    local thumb = scaleSlider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 14)
    thumb:SetColorTexture(0.5, 0.5, 0.5, 1)
    scaleSlider:SetThumbTexture(thumb)
    
    local scaleValue = scaleContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    scaleValue:SetPoint("LEFT", scaleSlider, "RIGHT", 4, 0)
    scaleValue:SetText(string.format("%.0f%%", savedScale * 100))
    scaleValue:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Only update text while dragging (not main frame scale - that causes cursor drift)
    -- But DO update popup panels live
    scaleSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value * 20 + 0.5) / 20  -- Round to 0.05
        scaleValue:SetText(string.format("%.0f%%", value * 100))
        -- Update popup panels live (they don't cause cursor drift)
        if DF.positionPanel then
            DF.positionPanel:SetScale(value)
        end
        if DF.TestPanel then
            DF.TestPanel:SetScale(value)
        end
    end)
    
    -- Apply scale only on mouse release to avoid cursor drift issues
    scaleSlider:SetScript("OnMouseUp", function(self)
        local value = math.floor(self:GetValue() * 20 + 0.5) / 20
        frame:SetScale(value)
        if DF.db and DF.db.party then
            DF.db.party.guiScale = value
        end
        -- Also update popup panels
        if DF.positionPanel then
            DF.positionPanel:SetScale(value)
        end
        if DF.TestPanel then
            DF.TestPanel:SetScale(value)
        end
    end)
    
    GUI.ScaleSlider = scaleSlider
    GUI.ScaleContainer = scaleContainer
    -- =========================================================================
    -- END TOP BAR CONTROLS
    -- =========================================================================
    
    local function UpdateThemeColors()
        local pc = C_ACCENT
        local rc = C_RAID
        local cc = {r = 0.2, g = 0.8, b = 0.4} -- Click casting green
        
        -- Reset all mode buttons first
        btnParty:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        btnParty:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        btnParty.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        btnRaid:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        btnRaid:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        btnRaid.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        btnClicks:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        btnClicks:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        btnClicks.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        
        -- Highlight the selected mode
        if GUI.SelectedMode == "party" then
            btnParty:SetBackdropColor(pc.r, pc.g, pc.b, 1)
            btnParty:SetBackdropBorderColor(pc.r, pc.g, pc.b, 1)
            btnParty.Text:SetTextColor(1, 1, 1)
        elseif GUI.SelectedMode == "raid" then
            btnRaid:SetBackdropColor(rc.r, rc.g, rc.b, 1)
            btnRaid:SetBackdropBorderColor(rc.r, rc.g, rc.b, 1)
            btnRaid.Text:SetTextColor(1, 1, 1)
        elseif GUI.SelectedMode == "clicks" then
            btnClicks:SetBackdropColor(cc.r, cc.g, cc.b, 1)
            btnClicks:SetBackdropBorderColor(cc.r, cc.g, cc.b, 1)
            btnClicks.Text:SetTextColor(1, 1, 1)
        end
        
        -- Update Test button colors based on whether test panel is open
        local testActive = DF.TestPanel and DF.TestPanel:IsShown()
        local themeColor = GUI.SelectedMode == "party" and pc or (GUI.SelectedMode == "raid" and rc or cc)
        
        if testActive then
            btnTest:SetBackdropColor(themeColor.r * 0.3, themeColor.g * 0.3, themeColor.b * 0.3, 1)
            btnTest:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
            btnTest.Text:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
            btnTest.Icon:SetVertexColor(themeColor.r, themeColor.g, themeColor.b)
        else
            btnTest:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            btnTest:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.5)
            btnTest.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            btnTest.Icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
        
        -- Show/hide Test and Lock buttons based on mode
        if GUI.SelectedMode == "clicks" then
            btnTest:Hide()
            btnLock:Hide()
        else
            btnTest:Show()
            btnLock:Show()
        end
        
        title.UpdateTheme()
        
        -- Update active tab
        local nc = GetThemeColor()
        for name, btn in pairs(GUI.Tabs) do
            if btn.isActive and not btn.disabled then
                btn.accent:SetColorTexture(nc.r, nc.g, nc.b, 1)
                btn.Text:SetTextColor(nc.r, nc.g, nc.b)
                btn.Text:SetAlpha(1)
            elseif btn.disabled then
                btn.Text:SetTextColor(0.2, 0.2, 0.2)
                btn.Text:SetAlpha(0.8)
                if btn.accent then btn.accent:Hide() end
            end
        end
        
        -- Update theme listeners
        if GUI.CurrentPageName and GUI.Pages[GUI.CurrentPageName] then
            local page = GUI.Pages[GUI.CurrentPageName]
            if page.child and page.child.ThemeListeners then
                for _, widget in ipairs(page.child.ThemeListeners) do
                    if widget.UpdateTheme then widget:UpdateTheme() end
                end
            end
        end
        
        -- Update test panel if open (but don't trigger circular updates)
        if DF.TestPanel and DF.TestPanel:IsShown() then
            DF.TestPanel:UpdateStateNoCallback()
        end
        
        -- Update lock button state
        UpdateLockButtonState()
    end
    GUI.UpdateThemeColors = UpdateThemeColors
    
    -- Function to update test button state (called externally)
    UpdateTestButtonState = function()
        -- Highlight based on whether the test panel popup is visible
        local pc = C_ACCENT
        local rc = C_RAID
        local cc = {r = 0.2, g = 0.8, b = 0.4}
        local testActive = DF.TestPanel and DF.TestPanel:IsShown()
        local themeColor = GUI.SelectedMode == "party" and pc or (GUI.SelectedMode == "raid" and rc or cc)
        
        if testActive then
            btnTest:SetBackdropColor(themeColor.r * 0.3, themeColor.g * 0.3, themeColor.b * 0.3, 1)
            btnTest:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
            btnTest.Text:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
            btnTest.Icon:SetVertexColor(themeColor.r, themeColor.g, themeColor.b)
        else
            btnTest:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            btnTest:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.5)
            btnTest.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            btnTest.Icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end
    GUI.UpdateTestButtonState = UpdateTestButtonState
    
    -- Test button scripts
    btnTest:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btnTest:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            -- Quick toggle test mode
            DF:ToggleTestMode()
            UpdateThemeColors()
        else
            -- Open/close test panel
            DF:ToggleTestPanel()
            UpdateTestButtonState()
        end
    end)
    
    btnTest:SetScript("OnEnter", function(self)
        local testActive = DF.TestPanel and DF.TestPanel:IsShown()
        if not testActive then
            local themeColor = GUI.SelectedMode == "party" and C_ACCENT or C_RAID
            self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.8)
        end
    end)
    btnTest:SetScript("OnLeave", function(self)
        local testActive = DF.TestPanel and DF.TestPanel:IsShown()
        if not testActive then
            local themeColor = GUI.SelectedMode == "party" and C_ACCENT or C_RAID
            self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.5)
        end
    end)
    
    btnParty:SetScript("OnClick", function()
        DF:SyncLinkedSections()

        -- Before switching tabs, clean up current mode's test mode and unlock state
        if GUI.SelectedMode == "raid" then
            -- Lock raid frames if unlocked
            local raidDb = DF:GetRaidDB()
            if not raidDb.raidLocked then
                raidDb.raidLocked = true
                if DF.raidContainer then
                    DF.raidContainer:EnableMouse(false)
                    DF.raidContainer:SetMovable(false)
                end
                if DF.LockRaidFrames then DF:LockRaidFrames() end
            end
            -- Disable raid test mode if active
            if DF.raidTestMode then
                DF:HideRaidTestFrames(true)  -- silent
            end
        end
        
        GUI.SelectedMode = "party"
        if DF.Search then 
            DF.Search:InvalidateRegistry()
            DF.Search:RefreshIfActive()
        end
        UpdateThemeColors()
        GUI:ShowNormalContent()
        GUI:RefreshCurrentPage()
    end)
    btnRaid:SetScript("OnClick", function()
        DF:SyncLinkedSections()

        -- Before switching tabs, clean up current mode's test mode and unlock state
        if GUI.SelectedMode == "party" then
            -- Lock party frames if unlocked
            local partyDb = DF:GetDB()
            if not partyDb.locked then
                partyDb.locked = true
                if DF.partyContainer then
                    DF.partyContainer:EnableMouse(false)
                    DF.partyContainer:SetMovable(false)
                end
                if DF.LockFrames then DF:LockFrames() end
            end
            -- Disable party test mode if active
            if DF.testMode then
                DF:HideTestFrames(true)  -- silent
            end
        end
        
        GUI.SelectedMode = "raid"
        if DF.Search then 
            DF.Search:InvalidateRegistry()
            DF.Search:RefreshIfActive()
        end
        UpdateThemeColors()
        GUI:ShowNormalContent()
        GUI:RefreshCurrentPage()
    end)
    
    -- Click Casting tab click handler
    btnClicks:SetScript("OnClick", function()
        -- Clean up any test/unlock state from previous mode
        if GUI.SelectedMode == "party" then
            local partyDb = DF:GetDB()
            if partyDb and not partyDb.locked then
                partyDb.locked = true
                if DF.LockFrames then DF:LockFrames() end
            end
            if DF.testMode then DF:HideTestFrames(true) end
        elseif GUI.SelectedMode == "raid" then
            local raidDb = DF:GetRaidDB()
            if raidDb and not raidDb.raidLocked then
                raidDb.raidLocked = true
                if DF.LockRaidFrames then DF:LockRaidFrames() end
            end
            if DF.raidTestMode then DF:HideRaidTestFrames(true) end
        end
        
        GUI.SelectedMode = "clicks"
        if DF.Search then 
            DF.Search:HideResults()
        end
        UpdateThemeColors()
        GUI:ShowClickCastingContent()
    end)
    
    -- Tab container (left side) - with scrolling
    local tabFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    tabFrame:SetPoint("TOPLEFT", 12, -64)
    tabFrame:SetPoint("BOTTOMLEFT", 12, 36)
    tabFrame:SetWidth(155)
    CreateElementBackdrop(tabFrame)
    tabFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.5)
    
    -- =========================================================================
    -- SEARCH BAR
    -- =========================================================================
    local searchBar = nil
    local tabScrollStartY = -4
    if DF.Search then
        searchBar = DF.Search:CreateSearchBar(tabFrame)
        searchBar:SetPoint("TOPLEFT", 4, -4)
        searchBar:SetPoint("TOPRIGHT", -14, -4)
        tabScrollStartY = -36
    end
    
    -- Use ScrollFrameTemplate like old addon (not UIPanelScrollFrameTemplate)
    local tabScroll = CreateFrame("ScrollFrame", nil, tabFrame, "ScrollFrameTemplate")
    tabScroll:SetPoint("TOPLEFT", 4, tabScrollStartY)
    tabScroll:SetPoint("BOTTOMRIGHT", -14, 4)
    
    -- Style scrollbar (matching old addon approach)
    local sb = tabScroll.ScrollBar
    if sb then
        -- Hide the default textures
        if sb.Background then sb.Background:Hide() end
        if sb.Track then 
            if sb.Track.Begin then sb.Track.Begin:Hide() end
            if sb.Track.End then sb.Track.End:Hide() end
            if sb.Track.Middle then sb.Track.Middle:Hide() end
        end
        
        -- Style the thumb
        if sb.Thumb then
            if sb.Thumb.Begin then sb.Thumb.Begin:Hide() end
            if sb.Thumb.End then sb.Thumb.End:Hide() end
            if sb.Thumb.Middle then sb.Thumb.Middle:Hide() end
            
            if not sb.Thumb.customBg then
                local thumb = sb.Thumb:CreateTexture(nil, "ARTWORK")
                thumb:SetAllPoints()
                thumb:SetColorTexture(0.4, 0.4, 0.4, 0.8)
                sb.Thumb.customBg = thumb
            end
        end
        
        -- Make scrollbar slimmer
        sb:SetWidth(10)
        sb:ClearAllPoints()
        sb:SetPoint("TOPRIGHT", tabFrame, "TOPRIGHT", -4, tabScrollStartY)
        sb:SetPoint("BOTTOMRIGHT", tabFrame, "BOTTOMRIGHT", -4, 4)
        
        -- Hide the buttons (up/down arrows)
        if sb.Back then sb.Back:Hide() sb.Back:SetSize(1, 1) end
        if sb.Forward then sb.Forward:Hide() sb.Forward:SetSize(1, 1) end
    end
    
    local tabContainer = CreateFrame("Frame", nil, tabScroll)
    tabContainer:SetWidth(130)
    tabContainer:SetHeight(600) -- Will be updated dynamically
    tabScroll:SetScrollChild(tabContainer)
    GUI.tabContainer = tabContainer
    GUI.tabScroll = tabScroll
    
    -- Content area (right side) - no BackdropTemplate in CreateFrame
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", tabFrame, "TOPRIGHT", 8, 0)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 36)
    CreateElementBackdrop(content)
    content:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.3)
    GUI.contentFrame = content
    GUI.tabFrame = tabFrame
    
    -- =========================================================================
    -- CLICK CASTING PANEL (full width, replaces normal content when active)
    -- =========================================================================
    local clickCastPanel = CreateFrame("Frame", nil, frame)
    clickCastPanel:SetPoint("TOPLEFT", 12, -64)
    clickCastPanel:SetPoint("BOTTOMRIGHT", -12, 36)
    CreateElementBackdrop(clickCastPanel)
    clickCastPanel:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.3)
    clickCastPanel:Hide()
    GUI.clickCastPanel = clickCastPanel
    
    -- =========================================================================
    -- FOOTER BAR (Discord & Donation links + bottom drag handle)
    -- =========================================================================

    -- Bottom drag bar (mirrors titleBar for dragging from the bottom)
    local bottomBar = CreateFrame("Frame", nil, frame)
    bottomBar:SetHeight(30)
    bottomBar:SetPoint("BOTTOMLEFT", 0, 0)
    bottomBar:SetPoint("BOTTOMRIGHT", -16, 0)  -- Leave space for resize handle
    bottomBar:EnableMouse(true)
    bottomBar:RegisterForDrag("LeftButton")
    bottomBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    bottomBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, y = frame:GetPoint()
        if DF.db and DF.db.party then
            DF.db.party.guiPoint = point
            DF.db.party.guiRelPoint = relPoint
            DF.db.party.guiX = x
            DF.db.party.guiY = y
        end
    end)

    local footer = CreateFrame("Frame", nil, bottomBar)
    footer:SetPoint("BOTTOMLEFT", 12, 8)
    footer:SetPoint("BOTTOMRIGHT", -12, 8)
    footer:SetHeight(22)
    
    -- URL copy popup helper
    local function ShowURLPopup(url, label)
        local popup = GUI.urlPopup
        if not popup then
            popup = CreateFrame("Frame", "DFURLPopup", UIParent, "BackdropTemplate")
            popup:SetSize(380, 80)
            popup:SetPoint("CENTER")
            popup:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
            })
            popup:SetBackdropColor(0.1, 0.1, 0.1, 0.98)
            popup:SetBackdropBorderColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 1)
            popup:SetFrameStrata("FULLSCREEN_DIALOG")
            popup:SetFrameLevel(250)
            popup:EnableMouse(true)
            
            local popupTitle = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            popupTitle:SetPoint("TOP", 0, -10)
            popupTitle:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            popup.title = popupTitle
            
            local editBox = CreateFrame("EditBox", nil, popup, "BackdropTemplate")
            editBox:SetPoint("TOPLEFT", 12, -30)
            editBox:SetPoint("TOPRIGHT", -12, -30)
            editBox:SetHeight(22)
            editBox:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
            })
            editBox:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            editBox:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
            editBox:SetFontObject(GameFontHighlightSmall)
            editBox:SetAutoFocus(true)
            editBox:SetScript("OnEscapePressed", function() popup:Hide() end)
            editBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
            popup.editBox = editBox
            
            local hint = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            hint:SetPoint("BOTTOM", 0, 8)
            hint:SetText("Press Ctrl+C to copy, then Escape to close")
            hint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            
            GUI.urlPopup = popup
        end
        
        popup.title:SetText(label)
        popup.editBox:SetText(url)
        popup:Show()
        popup.editBox:SetFocus()
        popup.editBox:HighlightText()
    end
    
    -- Create a footer link button
    local function CreateFooterLink(parent, text, color, url, popupLabel)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetHeight(22)
        
        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("CENTER")
        label:SetText(text)
        label:SetTextColor(color.r, color.g, color.b)
        btn:SetWidth(label:GetStringWidth() + 10)
        btn.label = label
        
        btn:SetScript("OnEnter", function()
            label:SetTextColor(1, 1, 1)
        end)
        btn:SetScript("OnLeave", function()
            label:SetTextColor(color.r, color.g, color.b)
        end)
        btn:SetScript("OnClick", function()
            ShowURLPopup(url, popupLabel)
        end)
        
        return btn
    end
    
    -- Discord link
    local discordColor = { r = 0.45, g = 0.53, b = 0.85 }
    local discordBtn = CreateFooterLink(footer, "Need support? Join our Discord", discordColor, 
        "https://discord.gg/SDWtduCqnT", "Join the DandersFrames Discord")
    discordBtn:SetPoint("LEFT", footer, "LEFT", 2, 0)
    
    -- Separator
    local sep = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sep:SetPoint("LEFT", discordBtn, "RIGHT", 8, 0)
    sep:SetText("|")
    sep:SetTextColor(C_BORDER.r, C_BORDER.g, C_BORDER.b)
    
    -- PayPal link
    local paypalColor = { r = 0.35, g = 0.65, b = 0.45 }
    local donateBtn = CreateFooterLink(footer, "Support development", paypalColor,
        "https://paypal.me/dandersframesaddon", "Support DandersFrames Development")
    donateBtn:SetPoint("LEFT", sep, "RIGHT", 8, 0)
    
    -- Version on the right
    local versionText = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    versionText:SetPoint("RIGHT", footer, "RIGHT", -2, 0)
    versionText:SetText(versionStr .. channelTag)
    versionText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.5)
    
    -- Create the click casting UI content
    if DF.ClickCast then
        DF.ClickCast:CreateClickCastUI(clickCastPanel)
    end
    
    -- Store min width references for tab switching
    local normalMinWidth = minWidth  -- 520
    local clicksMinWidth = 760  -- Clicks tab needs more space
    
    -- Function to show normal Party/Raid content
    function GUI:ShowNormalContent()
        if clickCastPanel then clickCastPanel:Hide() end
        if tabFrame then tabFrame:Show() end
        if content then content:Show() end
        
        -- Restore normal minimum width
        frame:SetResizeBounds(normalMinWidth, minHeight, maxWidth, maxHeight)
    end
    
    -- Function to show Click Casting content
    function GUI:ShowClickCastingContent()
        if tabFrame then tabFrame:Hide() end
        if content then content:Hide() end
        
        -- Set larger minimum width for clicks tab
        frame:SetResizeBounds(clicksMinWidth, minHeight, maxWidth, maxHeight)
        
        -- If current width is less than clicks min, expand it
        local currentWidth = frame:GetWidth()
        if currentWidth < clicksMinWidth then
            frame:SetWidth(clicksMinWidth)
        end
        
        if clickCastPanel then 
            clickCastPanel:Show()
            -- Refresh the spell grid
            if DF.ClickCast and DF.ClickCast.RefreshSpellGrid then
                DF.ClickCast:RefreshSpellGrid()
            end
        end
    end
    
    -- =========================================================================
    -- SEARCH RESULTS PANEL (inside content area)
    -- =========================================================================
    if DF.Search then
        DF.Search:CreateResultsPanel(content)
    end
    
    GUI.Tabs = {}
    GUI.Pages = {}
    
    local function SelectTab(name)
        -- Hide search results when navigating to a tab
        if DF.Search then
            DF.Search:HideResults()
        end
        
        for k, page in pairs(GUI.Pages) do page:Hide() end
        for k, btn in pairs(GUI.Tabs) do
            if btn.accent then btn.accent:Hide() end
            -- Check if tab is disabled (e.g., during Auto Profile editing)
            if btn.disabled then
                btn.Text:SetTextColor(0.2, 0.2, 0.2)
                btn.Text:SetAlpha(0.8)
            else
                btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                btn.Text:SetAlpha(1)
            end
            btn.isActive = false
            btn:SetBackdropColor(0, 0, 0, 0)  -- Reset background when deselected
        end
        
        -- Auto-expand parent category so the selected tab is visible
        local tab = GUI.Tabs[name]
        if tab and tab.categoryName then
            local cat = GUI.Categories[tab.categoryName]
            if cat and not cat.expanded then
                cat.expanded = true
                cat.arrow:SetText("-")
                -- Persist state
                if DF.db and DF.db.party then
                    if not DF.db.party.guiExpandedCategories then
                        DF.db.party.guiExpandedCategories = {}
                    end
                    DF.db.party.guiExpandedCategories[cat.name] = true
                end
                GUI:UpdateTabLayout()
            end
        end
        
        if GUI.Pages[name] then
            -- Set current tab for Search registration
            if DF.Search then
                local page = GUI.Pages[name]
                DF.Search:SetCurrentTab(page.tabName, page.tabLabel)
                DF.Search.CurrentSection = nil
            end
            
            GUI.Pages[name]:Show()
            GUI.Pages[name]:Refresh()
            if GUI.Pages[name].RefreshStates then GUI.Pages[name]:RefreshStates() end
        end
        local nc = GetThemeColor()
        if GUI.Tabs[name] then
            if GUI.Tabs[name].accent then
                GUI.Tabs[name].accent:Show()
                GUI.Tabs[name].accent:SetColorTexture(nc.r, nc.g, nc.b, 1)
            end
            GUI.Tabs[name].Text:SetTextColor(nc.r, nc.g, nc.b)
            GUI.Tabs[name].isActive = true
        end
        GUI.CurrentPageName = name
        UpdateThemeColors()
    end
    GUI.SelectTab = SelectTab
    
    GUI.RefreshCurrentPage = function()
        -- Don't refresh regular pages when in clicks mode (they use DF.db which doesn't have "clicks")
        if GUI.SelectedMode == "clicks" then
            return
        end
        if GUI.CurrentPageName and GUI.Pages[GUI.CurrentPageName] then
            GUI.Pages[GUI.CurrentPageName]:Refresh()
            if GUI.Pages[GUI.CurrentPageName].RefreshStates then
                GUI.Pages[GUI.CurrentPageName]:RefreshStates()
            end
            UpdateThemeColors()
        end
        -- Refresh override indicators
        RefreshAllOverrideIndicators()
    end
    
    -- Category system
    GUI.Categories = {}
    local categoryY = -8
    
    local function CreateCategory(name, label)
        local cat = CreateFrame("Button", nil, tabContainer, "BackdropTemplate")
        cat:SetPoint("TOPLEFT", 4, categoryY)
        cat:SetPoint("TOPRIGHT", -4, categoryY)
        cat:SetHeight(28)
        cat:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8x8"})
        cat:SetBackdropColor(0, 0, 0, 0)
        cat.name = name
        cat.children = {}
        
        -- Restore saved state (default collapsed)
        local savedStates = DF.db and DF.db.party and DF.db.party.guiExpandedCategories
        cat.expanded = savedStates and savedStates[name] or false
        
        -- Expand/collapse indicator (simple minus/plus)
        cat.arrow = cat:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        cat.arrow:SetPoint("LEFT", 6, 0)
        cat.arrow:SetText(cat.expanded and "-" or "+")
        cat.arrow:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        
        cat.Text = cat:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        cat.Text:SetPoint("LEFT", 20, 0)
        cat.Text:SetText(label)
        cat.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        
        cat:SetScript("OnEnter", function(self)
            self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 0.3)
        end)
        cat:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0, 0, 0, 0)
        end)
        cat:SetScript("OnClick", function(self)
            self.expanded = not self.expanded
            self.arrow:SetText(self.expanded and "-" or "+")
            -- Persist state
            if DF.db and DF.db.party then
                if not DF.db.party.guiExpandedCategories then
                    DF.db.party.guiExpandedCategories = {}
                end
                DF.db.party.guiExpandedCategories[self.name] = self.expanded or nil
            end
            GUI:UpdateTabLayout()
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        
        GUI.Categories[name] = cat
        categoryY = categoryY - 30
        return cat
    end
    
    local function CreateSubTab(categoryName, name, label)
        local cat = GUI.Categories[categoryName]
        if not cat then return end
        
        local btn = CreateFrame("Button", nil, tabContainer, "BackdropTemplate")
        btn:SetHeight(26)
        btn:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8x8"})
        btn:SetBackdropColor(0, 0, 0, 0)
        btn.isTab = true
        btn.tabName = name
        btn.categoryName = categoryName
        
        -- Left accent bar
        btn.accent = btn:CreateTexture(nil, "OVERLAY")
        btn.accent:SetPoint("TOPLEFT", 0, 0)
        btn.accent:SetPoint("BOTTOMLEFT", 0, 0)
        btn.accent:SetWidth(3)
        btn.accent:Hide()
        
        btn.Text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.Text:SetPoint("LEFT", 24, 0)
        btn.Text:SetText(label)
        btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        
        btn:SetScript("OnEnter", function(self)
            if not self.isActive then
                self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 0.5)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if not self.isActive then
                self:SetBackdropColor(0, 0, 0, 0)
            end
        end)
        btn:SetScript("OnClick", function()
            SelectTab(name)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        
        -- Create the page
        local page = CreateFrame("ScrollFrame", nil, content, "ScrollFrameTemplate")
        page:SetPoint("TOPLEFT", 8, -8)
        page:SetPoint("BOTTOMRIGHT", -8, 8)
        
        -- Style scrollbar (matching old addon approach)
        if page.ScrollBar then
            local sb = page.ScrollBar
            
            -- Hide the default textures
            if sb.Background then sb.Background:Hide() end
            if sb.Track then
                if sb.Track.Begin then sb.Track.Begin:Hide() end
                if sb.Track.End then sb.Track.End:Hide() end
                if sb.Track.Middle then sb.Track.Middle:Hide() end
            end
            
            -- Style the thumb
            if sb.Thumb then
                if sb.Thumb.Begin then sb.Thumb.Begin:Hide() end
                if sb.Thumb.End then sb.Thumb.End:Hide() end
                if sb.Thumb.Middle then sb.Thumb.Middle:Hide() end
                if not sb.Thumb.customBg then
                    local thumb = sb.Thumb:CreateTexture(nil, "ARTWORK")
                    thumb:SetAllPoints()
                    thumb:SetColorTexture(0.4, 0.4, 0.4, 0.8)
                    sb.Thumb.customBg = thumb
                end
            end
            
            -- Make scrollbar slimmer
            sb:SetWidth(10)
            
            -- Hide the buttons (up/down arrows) - match old addon
            if sb.Back then sb.Back:Hide() sb.Back:SetSize(1, 1) end
            if sb.Forward then sb.Forward:Hide() sb.Forward:SetSize(1, 1) end
        end
        
        local child = CreateFrame("Frame", nil, page)
        child:SetSize(content:GetWidth() - 30, 1)
        page:SetScrollChild(child)
        page.child = child
        page.tabName = name
        page.tabLabel = label
        page:Hide()
        page.Refresh = function() end
        
        GUI.Tabs[name] = btn
        GUI.Pages[name] = page
        table.insert(cat.children, btn)
        
        return page
    end
    
    -- Update tab positions based on expanded/collapsed state
    function GUI:UpdateTabLayout()
        local y = -8
        
        for _, catName in ipairs(GUI.CategoryOrder) do
            local cat = GUI.Categories[catName]
            if cat then
                cat:ClearAllPoints()
                cat:SetPoint("TOPLEFT", 0, y)
                cat:SetPoint("TOPRIGHT", 0, y)
                y = y - 30
                
                if cat.expanded then
                    for _, btn in ipairs(cat.children) do
                        btn:Show()
                        btn:ClearAllPoints()
                        btn:SetPoint("TOPLEFT", 0, y)
                        btn:SetPoint("TOPRIGHT", 0, y)
                        y = y - 28
                    end
                else
                    for _, btn in ipairs(cat.children) do
                        btn:Hide()
                    end
                end
            end
        end
        
        -- Update scroll child height
        local totalHeight = math.abs(y) + 20
        GUI.tabContainer:SetHeight(totalHeight)
    end
    
    -- Store category order
    GUI.CategoryOrder = {}
    
    local function CreateTab(name, label)
        -- Legacy single tab support - create as category with one item
        local page = CreateSubTab("tools", name, label)
        return page
    end
    
    local function BuildPage(page, builderFunc)
        page.Refresh = function(self)
            local db = DF.db[GUI.SelectedMode]
            -- Guard against nil db (e.g., when "clicks" mode is selected)
            if not db then return end
            
            if self.children then
                for _, child in ipairs(self.children) do child:Hide() end
            end
            self.children = {}
            self.child.ThemeListeners = {}
            -- Propagate RefreshStates to child so widgets can call it
            self.child.RefreshStates = function() self:RefreshStates() end
            local parent = self.child
            
            local function Add(widget, height, col)
                table.insert(self.children, widget)
                widget:SetParent(parent)
                widget.layoutHeight = height or 55
                widget.layoutCol = col or 1
                return widget
            end
            
            local function AddSpace(h, col)
                local spacer = CreateFrame("Frame", nil, parent)
                spacer:SetSize(1, h)
                spacer.layoutHeight = h
                spacer.layoutCol = col or "both"
                table.insert(self.children, spacer)
            end
            
            -- Sync point: forces both columns to align to the same Y position
            local function AddSyncPoint()
                local sync = CreateFrame("Frame", nil, parent)
                sync:SetSize(1, 1)
                sync.isSyncPoint = true
                sync.layoutHeight = 0
                sync.layoutCol = "both"
                table.insert(self.children, sync)
            end
            
            builderFunc(self, db, Add, AddSpace, AddSyncPoint)
            self:RefreshStates()
        end
        
        page.RefreshStates = function(self)
            if not self.children then return end
            local db = DF.db[GUI.SelectedMode]
            if not db then return end
            
            -- First pass: handle SettingsGroups - layout their children and calculate heights
            for _, widget in ipairs(self.children) do
                if widget.isSettingsGroup then
                    -- Layout children within the group (handles hideOn internally)
                    widget:LayoutChildren()
                    -- Process disableOn for group children
                    widget:RefreshChildStates()
                end
            end
            
            -- Second pass: handle regular widgets and group visibility
            for _, widget in ipairs(self.children) do
                -- Skip SettingsGroup children - they're handled by their parent group
                if widget.settingsGroup then
                    -- Already handled by group's LayoutChildren
                elseif widget.isSettingsGroup then
                    -- For groups, check collapsible section state AND group-level hideOn
                    local shouldHide = false
                    
                    -- Check if parent collapsible section is collapsed
                    if widget.collapsibleSection and not widget.collapsibleSection.expanded then
                        shouldHide = true
                    end
                    
                    -- Check group's own hideOn
                    if not shouldHide and widget.hideOn then
                        shouldHide = widget.hideOn(db)
                    end
                    
                    if shouldHide then
                        widget:Hide()
                    else
                        widget:Show()
                    end
                else
                    -- Regular widget processing
                    if widget.disableOn then
                        local shouldDisable = widget.disableOn(db)
                        if widget.SetEnabled then
                            widget:SetEnabled(not shouldDisable)
                        end
                    end
                    
                    -- Check if widget should be hidden
                    local shouldHide = false
                    
                    -- First check if parent collapsible section is collapsed
                    if widget.collapsibleSection and not widget.collapsibleSection.expanded then
                        shouldHide = true
                    end
                    
                    -- Then check widget's own hideOn
                    if not shouldHide and widget.hideOn then
                        shouldHide = widget.hideOn(db)
                    end
                    
                    if shouldHide then
                        widget:Hide()
                    else
                        widget:Show()
                    end
                end
            end
            
            -- Determine column layout based on content area width
            local contentWidth = GUI.contentFrame and GUI.contentFrame:GetWidth() or 540
            local minColumnWidth = 270  -- Minimum width for each column
            local usesTwoColumns = contentWidth >= (minColumnWidth * 2 + 20)
            
            -- Account for scrollbar and padding when calculating usable width
            local usableWidth = contentWidth - 40  -- Extra padding for scrollbar
            
            -- Check if editing banner is active (adds 50px at top)
            local bannerOffset = 0
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
                bannerOffset = 50
            end
            
            -- Layout - adjust column positions based on available width
            local x1, maxY = 5, 0
            local col2X = usesTwoColumns and math.floor(contentWidth / 2) or x1
            local y1, y2 = -5 - bannerOffset, -5 - bannerOffset
            
            -- First, position any right-aligned elements (like Copy buttons) at absolute top-right
            for _, widget in ipairs(self.children) do
                if widget.rightAlign and widget:IsShown() then
                    widget:ClearAllPoints()
                    widget:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", -10, -5 - bannerOffset)
                end
            end
            
            -- Reserve space below right-aligned elements
            local hasRightAligned = false
            for _, widget in ipairs(self.children) do
                if widget.rightAlign then
                    hasRightAligned = true
                    break
                end
            end
            if hasRightAligned then
                -- Add padding below the copy button (button height ~26 + 14 padding)
                y1 = y1 - 40
                y2 = y2 - 40
            end
            
            for _, widget in ipairs(self.children) do
                -- Skip widgets that belong to a SettingsGroup (they're positioned by the group)
                if widget.settingsGroup then
                    -- Do nothing - parent group handles positioning
                elseif widget.rightAlign then
                    -- Already positioned above, skip
                elseif widget.isSyncPoint then
                    -- Sync point: align both columns to the lowest Y position
                    local syncY = math.min(y1, y2)
                    y1 = syncY
                    y2 = syncY
                elseif widget:IsShown() then
                    -- For SettingsGroups, use calculated height
                    local h = widget.layoutHeight or 0
                    if widget.isSettingsGroup and widget.calculatedHeight then
                        h = widget.calculatedHeight
                    end
                    
                    widget:ClearAllPoints()
                    
                    -- Set height for frame-based widgets (like header containers)
                    if widget.text and widget.SetHeight and h > 0 then
                        widget:SetHeight(h)
                    end
                    
                    -- Apply indent offset if specified (for child/sub-options)
                    -- Supports: true (20px), or a number for multiple levels (e.g. 2 = 40px)
                    local indentOffset = 0
                    if widget.indent then
                        if type(widget.indent) == "number" then
                            indentOffset = widget.indent * 20
                        else
                            indentOffset = 20
                        end
                    end
                    
                    if widget.layoutCol == "both" then
                        local startY = math.min(y1, y2)
                        widget:SetPoint("TOPLEFT", x1 + indentOffset, startY)
                        -- Set width to span both columns (with scrollbar padding)
                        widget:SetWidth(usableWidth - indentOffset)
                        y1 = startY - h
                        y2 = startY - h
                    elseif widget.layoutCol == 2 and usesTwoColumns then
                        widget:SetPoint("TOPLEFT", col2X + indentOffset, y2)
                        -- Reduce width for indented widgets to maintain alignment
                        if indentOffset > 0 and widget.SetWidth then
                            local defaultColWidth = math.floor((usableWidth - 20) / 2)
                            widget:SetWidth(defaultColWidth - indentOffset)
                        end
                        y2 = y2 - h
                    else
                        -- Column 1, or column 2 when in single-column mode
                        widget:SetPoint("TOPLEFT", x1 + indentOffset, y1)
                        -- Reduce width for indented widgets to maintain alignment
                        if indentOffset > 0 and widget.SetWidth then
                            local defaultColWidth = math.floor((usableWidth - 20) / 2)
                            widget:SetWidth(defaultColWidth - indentOffset)
                        end
                        y1 = y1 - h
                    end
                    
                    local currentBottom = math.min(y1, y2)
                    if math.abs(currentBottom) > maxY then maxY = math.abs(currentBottom) end
                end
            end
            self.child:SetHeight(maxY + 40 + bannerOffset)
            
            -- Update scroll child width to match content area
            if self.child and GUI.contentFrame then
                self.child:SetWidth(GUI.contentFrame:GetWidth() - 30)
            end
        end
    end
    
    -- Load pages from Options file
    if DF.SetupGUIPages then
        DF:SetupGUIPages(GUI, CreateCategory, CreateSubTab, BuildPage)
    end
    
    -- Setup Auto Profiles editing banner
    if DF.AutoProfilesUI and DF.AutoProfilesUI.SetupEditingBanner then
        DF.AutoProfilesUI:SetupEditingBanner()
    end
    
    -- Update tab layout after all tabs created
    GUI:UpdateTabLayout()
    
    UpdateThemeColors()
    
    -- Select first subtab
    if GUI.CategoryOrder[1] then
        local firstCat = GUI.Categories[GUI.CategoryOrder[1]]
        if firstCat and firstCat.children[1] then
            SelectTab(firstCat.children[1].tabName)
        end
    end
end
