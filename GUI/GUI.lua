local addonName, DF = ...
local GUI = {}
DF.GUI = GUI
local L = DF.L

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

-- Exported palette: other files should theme against these shared tables instead
-- of re-declaring private copies or hardcoding the raw numbers. These are the
-- SAME table references as the locals above. For the mode-aware accent, use
-- GUI.GetThemeColor() (returns party purple or raid orange).
GUI.Colors = {
    background = C_BACKGROUND,
    panel      = C_PANEL,
    element    = C_ELEMENT,
    border     = C_BORDER,
    accent     = C_ACCENT,   -- party purple
    raid       = C_RAID,     -- raid orange
    hover      = C_HOVER,
    text       = C_TEXT,
    textDim    = C_TEXT_DIM,
}

DF.SectionRegistry = DF.SectionRegistry or {}

-- Track selected mode
GUI.SelectedMode = "party"

-- Registry of tabs that should show a "New" badge until opened.
-- Add tab IDs here for new features; the badge auto-hides once viewed.
-- Reset each release cycle to the tabs that are new since the last stable
-- (prior entries are persisted as seen and would otherwise show stale badges).
GUI.NewTabs = {
    ["text_designer"] = true,
    ["general_nicknames"] = true,
}

-- Registry of section headers (inside a tab) that should show a "New" badge
-- until the user visits the tab and then navigates away. Keyed by
-- "<tabName>.<sectionId>" so entries are unambiguous across tabs.
-- The badge is created by GUI:AddSectionNewBadge and cleared by SelectTab
-- when the user leaves the owning tab (persisted via seenSections).
GUI.NewSections = {
}

-- Live-tracked badges pending a "seen" mark, keyed by tabName → { key = badge }.
-- Populated by AddSectionNewBadge, drained by SelectTab on tab leave.
GUI.pendingSectionBadges = {}

-- Add a gold "New" badge to the right of a section header's text. Returns the
-- badge FontString, or nil if the section isn't registered in NewSections or
-- has already been marked seen. The badge clears (and is persisted as seen)
-- the next time the user navigates away from `tabName`.
function GUI:AddSectionNewBadge(widget, tabName, sectionId)
    -- Anchor to whichever label FontString the widget exposes:
    --   * CreateHeader containers use `.text`
    --   * CreateDropdown containers use `.label`
    local anchor = widget and (widget.text or widget.label)
    if not anchor or not tabName or not sectionId then return end
    local key = tabName .. "." .. sectionId
    if not GUI.NewSections[key] then return end

    local seen = DandersFramesDB_v2 and DandersFramesDB_v2.seenSections
                 and DandersFramesDB_v2.seenSections[key]
    if seen then return end

    local badge = widget:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    badge:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
    badge:SetText(L["New"])
    badge:SetTextColor(1, 0.82, 0)

    GUI.pendingSectionBadges[tabName] = GUI.pendingSectionBadges[tabName] or {}
    GUI.pendingSectionBadges[tabName][key] = badge
    return badge
end

-- Pages that remain fully accessible regardless of whether party or raid
-- mode is disabled via General settings. All other mode-specific tabs
-- are greyed out and non-interactive when viewing a disabled mode.
-- Auto Layouts is intentionally NOT whitelisted: it edits per-profile
-- settings that would have no effect if all frames are disabled.
GUI.AlwaysAccessiblePages = {
    ["general_settings"]             = true,  -- the toggles themselves
    ["profiles_manage"]              = true,
    ["profiles_importexport"]        = true,
    ["debug_console"]                = true,
    ["indicators_targetedlist"]      = true,
    ["indicators_personal_targeted"] = true,
}

-- Returns true if the given tab should be disabled for the currently
-- selected mode (i.e. the tab is mode-specific and that mode is off).
function GUI:IsTabDisabledForCurrentMode(tabName)
    if not tabName then return false end
    if GUI.AlwaysAccessiblePages[tabName] then return false end
    if GUI.SelectedMode == "party" and DF.db and DF.db.partyEnabled == false then return true end
    if GUI.SelectedMode == "raid"  and DF.db and DF.db.raidEnabled  == false then return true end
    return false
end

-- Walk all registered tabs and update their .disabled flag + visuals
-- based on the current mode and enable flags. Call after mode switches.
function GUI:UpdateTabAvailability()
    if not GUI.Tabs then return end
    for name, btn in pairs(GUI.Tabs) do
        local disabled = GUI:IsTabDisabledForCurrentMode(name)
        btn.disabled = disabled
        if btn.Text then
            if disabled then
                btn.Text:SetTextColor(0.45, 0.45, 0.45)
            else
                btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end
        end
        if disabled and not btn.isActive then
            btn:SetBackdropColor(0, 0, 0, 0)
        end
    end

    -- Refresh the sidebar so party-only tabs (e.g. Visibility) hide/show for
    -- the current mode.
    if GUI.UpdateTabLayout then GUI:UpdateTabLayout() end

    -- If the active tab just became hidden (party-only while in raid), move to a
    -- safe always-present tab so the user isn't left on a hidden/empty page.
    if not GUI._redirectingTab and GUI.SelectedMode == "raid" and GUI.CurrentPageName then
        local cur = GUI.Tabs[GUI.CurrentPageName]
        if cur and cur.partyOnly and GUI.SelectTab then
            GUI._redirectingTab = true
            GUI.SelectTab("general_settings")
            GUI._redirectingTab = false
        end
    end
end

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

-- Style a ScrollFrameTemplate scrollbar to use the pill-shaped thumb
-- All scroll frames must use ScrollFrameTemplate (not UIPanelScrollFrameTemplate)
local function StyleScrollBar(scrollFrame)
    local sb = scrollFrame.ScrollBar
    if not sb then return end

    -- Hide track background and track end caps
    if sb.Background then sb.Background:Hide() end
    if sb.Track then
        if sb.Track.Begin then sb.Track.Begin:Hide() end
        if sb.Track.End then sb.Track.End:Hide() end
        if sb.Track.Middle then sb.Track.Middle:Hide() end
    end

    -- Style the pill-shaped thumb — hide default textures, overlay with themed color
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

    -- Hide navigation buttons
    if sb.Back then sb.Back:Hide() sb.Back:SetSize(1, 1) end
    if sb.Forward then sb.Forward:Hide() sb.Forward:SetSize(1, 1) end

    -- Slim width
    sb:SetWidth(10)
end
GUI.StyleScrollBar = StyleScrollBar

-- =========================================================================
-- WIDGET FACTORY
-- =========================================================================

function GUI:CreateHeader(parent, text)
    -- Use a frame container so we can position text at bottom (padding above)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(200, 25)
    container:Show()
    
    local h = container:CreateFontString(nil, "OVERLAY", "DFFontNormal")
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

-- Collapsible section for grouping related settings.
-- Collapsed state is persisted in DandersFramesDB_v2.collapsedGroups keyed by
-- `text` (shared store with CreateSettingsGroup's collapsible header), so the
-- user's fold preference survives reloads.
function GUI:CreateCollapsibleSection(parent, text, defaultExpanded, width)
    local section = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    section:SetSize(width or 500, 28)  -- Header height
    -- Resolve initial expanded state: SavedVariables override the default.
    local savedStates = GUI:GetCollapsedGroups()
    if text and savedStates[text] ~= nil then
        section.expanded = not savedStates[text]
    else
        section.expanded = defaultExpanded ~= false
    end
    section.sectionTitleText = text
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
    section.title = section:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    section.title:SetPoint("LEFT", 26, 0)
    section.title:SetText(text)
    local c = GetThemeColor()
    section.title:SetTextColor(c.r, c.g, c.b)
    section.title.UpdateTheme = function()
        if section.previewDimmed then
            section.title:SetTextColor(0.5, 0.5, 0.5)
        else
            local nc = GetThemeColor()
            section.title:SetTextColor(nc.r, nc.g, nc.b)
        end
    end
    -- Grey the header title when the section's feature is disabled (driven by
    -- the preview wiring). Routes through UpdateTheme so theme changes respect it.
    section.SetPreviewDimmed = function(self, dimmed)
        self.previewDimmed = dimmed and true or false
        self.title.UpdateTheme()
    end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, section.title)

    -- Optional inline tag — small yellow text placed after the title to
    -- stand out as a status summary (e.g. "[Normal Dispels]"). Call
    -- section:SetTag(text) at any time; pass nil or empty string to clear.
    section.tag = section:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    section.tag:SetPoint("LEFT", section.title, "RIGHT", 8, 0)
    section.tag:SetTextColor(1, 0.82, 0, 1)  -- WoW standard gold/yellow
    section.tag:SetText("")
    section.SetTag = function(self, text)
        if text and text ~= "" then
            self.tag:SetText(text)
            self.tag:Show()
        else
            self.tag:SetText("")
            self.tag:Hide()
        end
    end

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
        -- Persist collapsed state to SavedVariables (only store true, remove when expanded)
        if self.sectionTitleText then
            local saved = GUI:GetCollapsedGroups()
            saved[self.sectionTitleText] = (not self.expanded) or nil
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
    
    -- Optional header preview thumbnails — a right-aligned row of small icon
    -- swatches on the header bar, used to show the actual icon(s) a section
    -- controls (e.g. the Role Icon section previews the Tank/Healer/DPS icons in
    -- the currently selected style). Always visible on the header, so the page
    -- reads as a gallery whether sections are expanded or collapsed.
    --
    -- icons: array of entries, each EITHER an icon or a text label:
    --   { texture = "atlas-or-path", coords = {l,r,t,b}?, desaturate = bool? }
    --   { text = "MT", desaturate = bool? }
    -- Icon entries are fixed-width swatches; text entries are sized to the
    -- string. Entries flow right-to-left from the header's right edge so the
    -- first entry sits leftmost. nil/empty clears the preview.
    section.previewIcons = {}
    section.SetPreviewIcons = function(self, icons)
        local pool = self.previewIcons
        local n = icons and #icons or 0
        local SIZE, GAP, RIGHT_INSET = 18, 4, -10
        local x = RIGHT_INSET
        for i = n, 1, -1 do  -- right-to-left so entry 1 ends up leftmost
            local data = icons[i]
            local slot = pool[i]
            if not slot then
                slot = CreateFrame("Frame", nil, self)
                slot:SetHeight(SIZE)
                slot.tex = slot:CreateTexture(nil, "OVERLAY")
                slot.tex:SetAllPoints()
                slot.fs = slot:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                slot.fs:SetAllPoints()
                slot.fs:SetJustifyH("CENTER")
                pool[i] = slot
            end
            local dim = data.desaturate and true or false
            local w = SIZE
            if data.text and data.text ~= "" then
                slot.tex:Hide()
                slot.fs:SetText(data.text)
                if dim then
                    slot.fs:SetTextColor(0.5, 0.5, 0.5, 1)
                elseif data.color then
                    slot.fs:SetTextColor(data.color.r or 1, data.color.g or 1, data.color.b or 1, data.color.a or 1)
                else
                    slot.fs:SetTextColor(1, 0.82, 0, 1)
                end
                slot.fs:Show()
                w = math.max(SIZE, (slot.fs:GetStringWidth() or 0) + 4)
            else
                slot.fs:Hide()
                -- data.texture may be an atlas name or a texture path; the helper
                -- prefers the atlas and falls back to the path (+ optional coords).
                local co = data.coords
                DF:SetIconTextureOrAtlas(slot.tex, data.texture, co and co[1], co and co[2], co and co[3], co and co[4])
                slot.tex:SetDesaturated(dim)
                -- Optional per-entry inset: textures that fill their cell edge-to-edge
                -- (e.g. raid-target markers) read bigger than the padded status-icon
                -- atlases. data.inset shrinks the swatch to match.
                local pad = data.inset or 0
                slot.tex:ClearAllPoints()
                slot.tex:SetPoint("TOPLEFT", slot, "TOPLEFT", pad, -pad)
                slot.tex:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -pad, pad)
                slot.tex:Show()
            end
            slot:SetWidth(w)
            slot:ClearAllPoints()
            slot:SetPoint("RIGHT", self, "RIGHT", x, 0)
            slot:Show()
            x = x - w - GAP
        end
        for i = n + 1, #pool do pool[i]:Hide() end
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
-- Collapsed state persistence (stored in SavedVariables, survives logout)
-- Lazily initialized from DandersFramesDB_v2.collapsedGroups on first access
function GUI:GetCollapsedGroups()
    if not DandersFramesDB_v2 then return {} end
    if not DandersFramesDB_v2.collapsedGroups then
        DandersFramesDB_v2.collapsedGroups = {}
    end
    return DandersFramesDB_v2.collapsedGroups
end

function GUI:CreateSettingsGroup(parent, width, opts)
    -- opts can be a boolean (legacy: collapsible) or a table { collapsible, showSummary, onCollapseChanged }
    if type(opts) == "boolean" then opts = { collapsible = opts } end
    opts = opts or {}

    local group = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    group.onCollapseChanged = opts.onCollapseChanged
    group:SetSize(width or 280, 10)  -- Height will be calculated dynamically
    group.groupChildren = {}
    group.isSettingsGroup = true
    group.collapsible = opts.collapsible or false
    group.showSummary = opts.showSummary or false
    -- Optional saved-state key override: lets several boxes share a standard
    -- display header (e.g. "Appearance") while persisting collapse state under a
    -- unique key (e.g. "afkIcon:Appearance"), so they don't toggle together.
    group.collapseKey = opts.collapseKey
    group.collapsed = false

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

    -- Bottom collapse bar (only for collapsible groups, shown when expanded)
    if group.collapsible then
        local collapseBar = CreateFrame("Button", nil, group)
        collapseBar:SetHeight(14)
        collapseBar:SetPoint("BOTTOMLEFT", group, "BOTTOMLEFT", 1, 1)
        collapseBar:SetPoint("BOTTOMRIGHT", group, "BOTTOMRIGHT", -1, 1)

        local barBg = collapseBar:CreateTexture(nil, "BACKGROUND")
        barBg:SetAllPoints()
        barBg:SetColorTexture(1, 1, 1, 0.03)

        local barIcon = collapseBar:CreateTexture(nil, "OVERLAY")
        barIcon:SetSize(12, 12)
        barIcon:SetPoint("CENTER", 0, 0)
        local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
        -- "expand_more" is a down chevron; rotate 180° so it points UP — this bar
        -- collapses the (expanded) section, so an up arrow reads correctly.
        barIcon:SetTexture(mediaPath .. "expand_more")
        barIcon:SetRotation(math.pi)
        barIcon:SetVertexColor(1, 1, 1, 0.5)

        collapseBar:SetScript("OnEnter", function()
            barBg:SetColorTexture(1, 1, 1, 0.06)
            barIcon:SetVertexColor(1, 1, 1, 0.85)
        end)
        collapseBar:SetScript("OnLeave", function()
            barBg:SetColorTexture(1, 1, 1, 0.03)
            barIcon:SetVertexColor(1, 1, 1, 0.5)
        end)
        collapseBar:SetScript("OnClick", function()
            group.collapsed = true
            local headerText = group.headerWidget and group.headerWidget.text and group.headerWidget.text:GetText()
            local stateKey = group.collapseKey or headerText
            if stateKey then
                local saved = GUI:GetCollapsedGroups()
                saved[stateKey] = true
            end
            if group.collapseArrow then
                group.collapseArrow:SetTexture(mediaPath .. "chevron_right")
            end
            if DF.AuraDesigner_RefreshPage then
                DF:AuraDesigner_RefreshPage()
            end
            local pageChild = group:GetParent()
            if pageChild and pageChild.RefreshStates then pageChild.RefreshStates() end
            if group.onCollapseChanged then group.onCollapseChanged(group) end
        end)

        collapseBar:Hide()
        group.collapseBar = collapseBar
    end

    -- Add a widget to this group
    group.AddWidget = function(self, widget, height)
        widget:SetParent(self)
        table.insert(self.groupChildren, {
            widget = widget,
            height = height or 55,
        })
        -- Mark widget as belonging to this group
        widget.settingsGroup = self

        -- If collapsible and this is the first widget (header), set up collapse toggle
        if self.collapsible and #self.groupChildren == 1 and widget.text then
            self.headerWidget = widget

            -- Resolve collapsed state: default to expanded unless saved state says collapsed
            local headerText = widget.text:GetText()
            local stateKey = self.collapseKey or headerText
            local savedStates = GUI:GetCollapsedGroups()
            if stateKey and savedStates[stateKey] then
                self.collapsed = true
            else
                self.collapsed = false
            end

            -- Shift header text right to make room for the arrow icon
            widget.text:ClearAllPoints()
            widget.text:SetPoint("BOTTOMLEFT", widget, "BOTTOMLEFT", 14, 2)

            -- Add toggle arrow icon (texture from Media folder)
            local arrow = widget:CreateTexture(nil, "OVERLAY")
            arrow:SetSize(10, 10)
            arrow:SetPoint("RIGHT", widget.text, "LEFT", -2, 0)
            local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
            arrow:SetTexture(self.collapsed and (mediaPath .. "chevron_right") or (mediaPath .. "expand_more"))
            local c = GetThemeColor()
            arrow:SetVertexColor(c.r, c.g, c.b)
            self.collapseArrow = arrow

            -- Theme listener for arrow color
            arrow.UpdateTheme = function()
                local nc = GetThemeColor()
                arrow:SetVertexColor(nc.r, nc.g, nc.b)
            end
            if not parent.ThemeListeners then parent.ThemeListeners = {} end
            table.insert(parent.ThemeListeners, arrow)

            -- Make the header clickable
            widget:EnableMouse(true)
            widget:SetScript("OnMouseDown", function()
                self.collapsed = not self.collapsed
                -- Persist collapsed state to SavedVariables
                if stateKey then
                    local saved = GUI:GetCollapsedGroups()
                    saved[stateKey] = self.collapsed or nil  -- only store true, remove when expanded
                end
                arrow:SetTexture(self.collapsed and (mediaPath .. "chevron_right") or (mediaPath .. "expand_more"))
                -- Refresh the page to recalculate layout. The Aura Designer page
                -- has its own refresh; BuildPage pages (icons, frame settings…)
                -- expose RefreshStates on the group's parent (self.child).
                if DF.AuraDesigner_RefreshPage then
                    DF:AuraDesigner_RefreshPage()
                end
                local pageChild = self:GetParent()
                if pageChild and pageChild.RefreshStates then pageChild.RefreshStates() end
                if self.onCollapseChanged then self.onCollapseChanged(self) end
            end)

            -- Highlight arrow on hover to indicate clickable
            widget:SetScript("OnEnter", function()
                arrow:SetVertexColor(1, 1, 1)
            end)
            widget:SetScript("OnLeave", function()
                local nc = GetThemeColor()
                arrow:SetVertexColor(nc.r, nc.g, nc.b)
            end)
        end

        return widget
    end

    -- Calculate total height based on visible children and layout them
    group.LayoutChildren = function(self)
        local y = -self.padding  -- Start with top padding
        local visibleCount = 0
        local innerWidth = self:GetWidth() - (self.padding * 2)  -- Width for child widgets

        for i, entry in ipairs(self.groupChildren) do
            local widget = entry.widget
            local height = entry.height

            -- If collapsed, only show the header (first widget)
            if self.collapsed and i > 1 then
                widget:Hide()
            else
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
        end

        -- Show/hide collapsed summary and bottom collapse bar
        if self.collapsible then
            if self.collapsed then
                if self.showSummary then
                    -- Build summary fontstring lazily on first use
                    if not self.collapseSummary then
                        self.collapseSummary = self:CreateFontString(nil, "OVERLAY")
                        DF:SafeSetFont(self.collapseSummary, nil, 9, "")
                        self.collapseSummary:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b, 0.5)
                        self.collapseSummary:SetJustifyH("LEFT")
                        self.collapseSummary:SetWordWrap(true)
                    end

                    -- Collect labels from child widgets (skip header at index 1)
                    local labels = {}
                    for i = 2, #self.groupChildren do
                        local w = self.groupChildren[i].widget
                        -- Scan the widget's regions for a FontString with text
                        for _, region in ipairs({w:GetRegions()}) do
                            if region.GetText and region:GetText() and region:GetText() ~= "" then
                                labels[#labels + 1] = region:GetText()
                                break
                            end
                        end
                    end

                    local summaryText = table.concat(labels, "  \194\183  ")  -- separated by  ·
                    self.collapseSummary:SetText(summaryText)
                    self.collapseSummary:ClearAllPoints()
                    self.collapseSummary:SetPoint("TOPLEFT", self, "TOPLEFT", self.padding, y)
                    self.collapseSummary:SetWidth(innerWidth)
                    self.collapseSummary:Show()
                    -- Measure actual wrapped height
                    local summaryHeight = self.collapseSummary:GetStringHeight() or 12
                    y = y - summaryHeight - 2
                else
                    if self.collapseSummary then self.collapseSummary:Hide() end
                end

                if self.collapseBar then self.collapseBar:Hide() end
            else
                if self.collapseSummary then self.collapseSummary:Hide() end
                if self.collapseBar then
                    self.collapseBar:Show()
                    y = y - self.collapseBar:GetHeight()
                end
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

        -- Group-level grey-out: set self.disableChildrenOn = function(db) ... end to
        -- grey EVERY child when it returns true, EXCEPT the header and any widget
        -- flagged widget.keepEnabled (the feature's own Enable toggle). Saves putting a
        -- disableOn on every control; composes with per-widget disableOn (a child is
        -- disabled if either says so). CreateCheckbox auto-calls RefreshStates on
        -- toggle, so the grey state updates live.
        local hasGroupGate = self.disableChildrenOn ~= nil
        local groupOff = hasGroupGate and self.disableChildrenOn(db) or false

        for i, entry in ipairs(self.groupChildren) do
            local widget = entry.widget
            if widget.SetEnabled and (widget.disableOn or hasGroupGate) then
                local shouldDisable = (widget.disableOn and widget.disableOn(db)) or false
                if groupOff and i > 1 and not widget.keepEnabled then
                    shouldDisable = true
                end
                widget:SetEnabled(not shouldDisable)
            end
            if widget.refreshContent and widget:IsShown() then
                widget:refreshContent(db)
            end
        end
    end

    return group
end

function GUI:CreateLabel(parent, text, width, color)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 380, 40)
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    -- Anchor both top corners so the wrap width tracks the frame's width. The
    -- layout engine (settings-group LayoutChildren / page column sizing) resizes
    -- the frame to the available width, so the text now uses the full width and
    -- wraps when the window is narrow instead of overflowing/clipping at a fixed
    -- width. Standalone (un-laid-out) labels keep the frame's initial `width`.
    lbl:SetPoint("TOPLEFT", 0, -5)
    lbl:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -5)
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(true)
    lbl:SetText(text)
    
    if color then
        lbl:SetTextColor(color.r, color.g, color.b, color.a or 1)
    else
        lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
    end
    
    frame.SetText = function(self, newText) lbl:SetText(newText) end
    return frame
end

-- CreateNote: a lightweight LEVELLED note (NO box — that is CreateInfoBanner's
-- job) for an inline caveat/tip attached to a field or section. It is the middle
-- tier between a plain CreateLabel and a full banner.
--   opts.tone    info | caution | danger | success — tints the note from the
--                SAME palette as the banners (via ToneHex), so notes and banners
--                speak one colour language. Omit for a neutral dim note.
--   opts.prefix  optional lead word ("Note", "Warning", "Recommendation") shown
--                in the tone colour, followed by ": " and the body in dim text.
--   opts.width   wrap width.
-- Returns a CreateLabel frame, so it is a drop-in anywhere a label goes.
function GUI:CreateNote(parent, text, opts)
    opts = opts or {}
    local str
    if opts.tone and opts.prefix then
        -- Route the prefix through L so "Note"/"Tip"/etc. are localizable (the
        -- locale metatable returns the key unchanged when a locale lacks it).
        local prefix = (L and L[opts.prefix]) or opts.prefix
        str = "|c" .. self:ToneHex(opts.tone) .. prefix .. ":|r " .. text
    elseif opts.tone then
        str = "|c" .. self:ToneHex(opts.tone) .. text .. "|r"
    else
        str = text
    end
    return self:CreateLabel(parent, str, opts.width)
end

-- Segmented button group: a row of mutually-exclusive buttons, one selected at
-- a time. Each option shows a primary label and an optional subtitle on a
-- second line. Selected button gets a themed border + tinted fill; unselected
-- buttons use the standard element backdrop.
--
--   options: ordered array of { value=, label=, subtitle= }
--   dbTable/dbKey: reads/writes the selected value
--   callback: called after a selection change
--   totalWidth: total container width (buttons divide it evenly with small gaps)
function GUI:CreateSegmentedButtonGroup(parent, options, dbTable, dbKey, callback, totalWidth, minBtnWidthOpt)
    local container = CreateFrame("Frame", nil, parent)
    totalWidth = totalWidth or 560
    local btnHeight = 38  -- compact modern height: label + subtitle fit snugly
    local gap = 4
    -- minBtnWidth governs when buttons wrap. The default suits 2-3 segment
    -- groups with full-word labels in the standard ~560px settings panels;
    -- caller can pass a smaller value when packing more / shorter segments
    -- into a narrower group (e.g. a 260px border-controls column).
    local minBtnWidth = minBtnWidthOpt or 110
    container:SetSize(totalWidth, btnHeight)

    local n = #options

    local buttons = {}
    container.buttons = buttons

    -- Reposition buttons to fill the container's current width. Wraps to
    -- additional rows when per-button width would drop below minBtnWidth.
    -- Called on creation and on OnSizeChanged so buttons reflow when the
    -- page stretches or shrinks the container.
    local function Relayout()
        -- Re-entry guard: OnSizeChanged can fire again when we SetHeight
        -- below, and we might also be called during a deferred RefreshStates.
        -- Without this guard the widget rebuild chain loops infinitely and
        -- drops the framerate to single digits.
        if container._relayouting then return end
        container._relayouting = true

        local w = container:GetWidth() or totalWidth
        if w <= 0 then w = totalWidth end

        local perRow = math.max(1, math.min(n, math.floor((w + gap) / (minBtnWidth + gap))))
        local rows = math.ceil(n / perRow)
        local bw = math.floor((w - gap * (perRow - 1)) / perRow)

        for i, btn in ipairs(buttons) do
            local rowIdx = math.ceil(i / perRow) - 1
            local colIdx = (i - 1) % perRow
            btn:SetWidth(bw)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", colIdx * (bw + gap), -(rowIdx * (btnHeight + gap)))
        end

        local newHeight = rows * btnHeight + (rows - 1) * gap
        if math.abs((container:GetHeight() or 0) - newHeight) > 0.5 then
            container:SetHeight(newHeight)
        end

        -- If the row count changed the required layout space, bump
        -- layoutHeight so the page reserves the right amount on the next
        -- layout pass, and defer a layout-only refresh (NOT page:Refresh()
        -- which would rebuild all widgets and re-enter this path forever).
        local desiredLayoutH = newHeight + 4
        if container.layoutHeight ~= desiredLayoutH then
            container.layoutHeight = desiredLayoutH
            if not container._relayoutPending then
                container._relayoutPending = true
                C_Timer.After(0, function()
                    container._relayoutPending = false
                    if parent and parent.RefreshStates then
                        parent:RefreshStates()
                    end
                end)
            end
        end

        container._relayouting = false
    end
    container:SetScript("OnSizeChanged", function() Relayout() end)

    local function Refresh()
        local currentVal = dbTable and dbTable[dbKey]
        for _, btn in ipairs(buttons) do
            local selected = (btn.value == currentVal)
            btn.selected = selected
            btn:SetActive(selected)  -- shared toggle look (accent border + fill)
        end
    end
    container.Refresh = Refresh
    -- refreshContent hook used by the page layout so external changes to the
    -- db value (e.g. profile switches) re-sync the selected button.
    container.refreshContent = function(self) Refresh() end

    for i, opt in ipairs(options) do
        local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
        btn:SetHeight(btnHeight)
        -- Width and position set by Relayout() below (called at end of setup
        -- and on every OnSizeChanged).
        -- Shared button styling: hover wash + SetActive() selection state.
        GUI:StyleButton(btn)

        btn.value = opt.value

        btn.Label = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        btn.Label:SetPoint("TOP", 0, -5)
        btn.Label:SetText(opt.label or "")
        btn.Label:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        if opt.subtitle and opt.subtitle ~= "" then
            btn.Subtitle = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            btn.Subtitle:SetPoint("BOTTOM", 0, 5)
            btn.Subtitle:SetText(opt.subtitle)
            btn.Subtitle:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            -- Nudge subtitle down by ~1 pt for a clearer visual hierarchy.
            local fPath, fSize, fFlags = btn.Subtitle:GetFont()
            if fPath and fSize and fSize > 9 then
                btn.Subtitle:SetFont(fPath, fSize - 1, fFlags or "")
            end
        end

        btn:SetScript("OnClick", function(self)
            if dbTable[dbKey] == self.value then return end
            dbTable[dbKey] = self.value
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            Refresh()
            if callback then callback() end
        end)

        buttons[i] = btn
    end

    Relayout()
    Refresh()

    container.UpdateTheme = function() Refresh() end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, container)

    return container
end

-- ============================================================
-- CreateInfoBanner
-- ------------------------------------------------------------
-- A self-resizing banner with an icon, body text, and a "tone"
-- (info / caution / danger / success) that controls background,
-- border, default text colour, and default icon. ("warning" is a
-- legacy alias of "caution".) Do NOT pass fontTemplate — banners
-- share one font on purpose; only the tone should vary.
--
-- Usage:
--   local banner = GUI:CreateInfoBanner(parent, { tone = "caution", text = "..." })
--   Add(banner, banner.layoutHeight, "both")
--
-- Methods on the returned frame:
--   :SetTone(name)                  apply a preset (see TONES below)
--   :SetText(text, optColor)        plain text mode, auto-wraps + auto-resizes
--   :SetHTML(html, onLinkClick)     flow-layout body with clickable link buttons
--   :SetIcon(texture, r, g, b)      icon texture + optional vertex colour
--   :SetIconTexture(path)           icon texture only
--   :SetIconColor(r, g, b)          icon vertex colour only
--
-- The body word-wraps automatically; banner height is recomputed via
-- OnSizeChanged so resizing the GUI (or calling SetText/SetHTML) grows
-- or shrinks the banner to fit. The host page is re-laid out so widgets
-- below the banner reposition.
-- ============================================================
-- Each tone carries FOUR colour roles so all three consumers (banners,
-- inline ToneHex text, and tooltips) stay in sync:
--   bg / border / textColor / icon+iconColor  drive the BANNER box itself.
--   accent                                     is the vivid emphasis colour
--     used for INLINE text (ToneHex) and tooltip titles, read against the
--     dark GUI background rather than the banner's own tinted bg. It is a
--     SEPARATE role from iconColor: e.g. the danger icon is a light warm so
--     the triangle pops on the orange banner, but inline "Warning" text must
--     be a real red to out-rank a caution — deriving one from the other
--     (the original bug) made inline danger paler than caution.
local INFO_BANNER_TONES = {
    info = {
        bg = {0.15, 0.18, 0.28, 1},
        useThemeBorder = true, borderAlpha = 0.5,
        icon = "info",
        textColor = {0.85, 0.85, 0.85},
        accent = {0.6, 0.8, 1},          -- light blue
    },
    -- NOTE: "warning" was merged into "caution" (they were near-duplicate golds).
    -- SetTone("warning") still resolves via the alias below for safety.
    caution = {
        bg = {0.5, 0.45, 0.1, 0.9},
        border = {0.7, 0.6, 0.1, 1},
        icon = "warning", iconColor = {1, 0.9, 0.3},
        textColor = {1, 0.95, 0.7},
        accent = {1, 0.82, 0},           -- gold
    },
    danger = {
        bg = {0.6, 0.3, 0.1, 0.9},
        border = {0.8, 0.4, 0.1, 1},
        -- icon kept a light warm (not the mid-orange bg hue) so the triangle pops
        icon = "warning", iconColor = {1, 0.9, 0.72},
        textColor = {1, 0.85, 0.7},
        accent = {1, 0.27, 0.27},        -- real red (destructive), NOT the pale icon warm
    },
    success = {
        bg = {0.1, 0.4, 0.2, 0.9},
        border = {0.2, 0.6, 0.3, 1},
        icon = "check", iconColor = {0.3, 1, 0.5},
        textColor = {0.7, 1, 0.8},
        accent = {0.4, 0.85, 0.5},       -- green
    },
}
-- Legacy alias: "warning" was merged into "caution" (near-duplicate golds).
INFO_BANNER_TONES.warning = INFO_BANNER_TONES.caution

-- Hex accent ("ffRRGGBB", for inline |c...|r escapes) matching a banner tone, so
-- inline caveat text (e.g. a warning word in a subtitle) reads as the SAME
-- info/caution/danger/success language as the banners instead of an ad-hoc colour.
-- Uses the tone's dedicated inline `accent` (NOT the banner iconColor, which is
-- tuned to sit on the banner's own bg and would make danger paler than caution).
function GUI:ToneHex(toneName)
    local t = INFO_BANNER_TONES[toneName] or INFO_BANNER_TONES.caution
    local c = t.accent or t.iconColor or t.textColor or {1, 1, 1}
    return string.format("ff%02x%02x%02x",
        math.floor((c[1] or 1) * 255 + 0.5),
        math.floor((c[2] or 1) * 255 + 0.5),
        math.floor((c[3] or 1) * 255 + 0.5))
end

local INFO_BANNER_ICON_PATH = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"

function GUI:CreateInfoBanner(parent, opts)
    opts = opts or {}

    local banner = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    if not banner.SetBackdrop then Mixin(banner, BackdropTemplateMixin) end
    banner:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    -- Give the banner a defined initial height so child frames have valid positions
    -- from the very first frame (before DoRecomputeHeight has run).
    banner:SetHeight(opts.minHeight or 34)

    -- Icon: top-left anchored so it stays put when content wraps to multiple lines.
    local icon = banner:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("TOPLEFT", 12, -10)
    icon:SetSize(22, 22)
    banner.icon = icon

    -- Plain-text body. Anchored top + right (no bottom) so the FontString
    -- auto-grows to its natural wrapped height; the banner then resizes
    -- to fit it via RecomputeHeight. SetWordWrap is on so long text wraps
    -- at the width defined by the LEFT/RIGHT anchors.
    local fontTemplate = opts.fontTemplate or "DFFontHighlight"
    local body = banner:CreateFontString(nil, "OVERLAY", fontTemplate)
    if not opts.fontTemplate then
        -- Default body a touch below DFFontHighlight (12px) — 11px reads cleaner
        -- in the banner while staying bigger than the old Small (10px). Icon stays 22.
        GUI:SetSettingsFont(body, 11, "")
    end
    -- Y offset centres the first line on the icon (body 11px, icon 22px). The
    -- text sits a few px below the icon's top so its centre lines up with the
    -- icon's centre.
    body:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -5)
    body:SetPoint("RIGHT", banner, "RIGHT", -12, 0)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetWordWrap(true)
    body:SetNonSpaceWrap(true)
    if body.SetMaxLines then body:SetMaxLines(0) end
    banner.body = body

    banner.layoutHeight = (opts.minHeight or 28) + 6

    local cachedH, recomputing = nil, false

    local function TriggerHostRelayout()
        -- If this banner was added to a SettingsGroup, sync its stored
        -- height entry and re-lay out the group.
        if banner.settingsGroup and banner.settingsGroup.LayoutChildren then
            local g = banner.settingsGroup
            for _, entry in ipairs(g.groupChildren or {}) do
                if entry.widget == banner then
                    entry.height = banner.layoutHeight
                    break
                end
            end
            g:LayoutChildren()
            -- Also bubble up to the page so its column layout sees the
            -- group's new calculatedHeight. Without this, sibling groups
            -- in the same column stay anchored to the OLD bottom of this
            -- group, and the group's backdrop (now taller) visibly
            -- overshoots past those siblings' anchor — rendering as an
            -- empty rectangle of group backdrop above the next group.
            -- Hit when an animation type is first selected in a border
            -- panel: banner appears, async recompute grows the group,
            -- next group below stays put, gap shows.
            local p = g:GetParent()
            while p do
                if type(p.RefreshStates) == "function" and p.children then
                    p:RefreshStates()
                    return
                end
                p = p:GetParent()
            end
            return
        end
        -- Otherwise, walk up to find a host page.
        local p = banner:GetParent()
        while p do
            if type(p.RefreshStates) == "function" and p.children then
                p:RefreshStates()
                return
            end
            p = p:GetParent()
        end
    end

    local function MeasureContent()
        if banner._isHTML then
            -- For HTML mode the flow layout positions all widgets and returns
            -- the total pixel height of all lines. Re-running it here keeps
            -- positions fresh and gives us an accurate height in one step.
            return math.max(18, banner._DoFlowLayout and banner._DoFlowLayout() or 18)
        end
        return math.max(18, body:GetStringHeight())
    end

    local pending = false
    -- Set whenever a RecomputeHeight() request was deferred because the
    -- banner was invisible.  Cleared once a real recompute runs after the
    -- banner becomes visible.  OnShow checks this flag to decide whether to
    -- trigger a fresh recompute when the widget surfaces.
    local deferredWhileHidden = false
    local function DoRecomputeHeight()
        pending = false
        if recomputing then return end
        -- Skip when the banner is hidden — GetStringHeight on a hidden
        -- FontString returns an unreliable value (width depends on the
        -- parent's layout having run, and LayoutChildren doesn't SetWidth
        -- on hidden widgets), and the resulting SetHeight + Trigger­Host­
        -- Relayout cascade costs real work proportional to the host
        -- SettingsGroup's widget count.  For consumers that mount banners
        -- behind hideOn predicates that default to true (animation perf
        -- warning at type=NONE) this used to fire one cascade per banner
        -- at every GUI open — N indicator cards × ~25-widget group ×
        -- proxy-backed dbTable in Aura Designer = sustained lockup.
        if not banner:IsVisible() then
            deferredWhileHidden = true
            return
        end
        local h = math.ceil(MeasureContent())
        -- Chrome: 13 px top (icon at -10, text nudged -3) + 9 px bottom = 22 px.
        local newH = math.max(opts.minHeight or 28, h + 22)
        if cachedH ~= newH then
            cachedH = newH
            recomputing = true
            banner:SetHeight(newH)
            banner.layoutHeight = newH + 6
            TriggerHostRelayout()
            recomputing = false
        end
        -- Schedule one more measurement next frame: GetStringHeight can
        -- return a stale single-line value the first time it's read after
        -- a width change, before the FontString has finished re-rendering.
        -- A second pass converges to the true wrapped height.
        if not banner._secondPassDone then
            banner._secondPassDone = true
            if C_Timer and C_Timer.After then
                C_Timer.After(0, DoRecomputeHeight)
            end
        end
    end

    -- Defer measurement to next frame so FontString has rendered with its
    -- current width — GetStringHeight can return a stale single-line value
    -- if called immediately after a width change. Coalesce multiple calls
    -- per frame via the `pending` flag.
    local function RecomputeHeight()
        banner._secondPassDone = false  -- allow follow-up pass on every fresh trigger
        if pending then return end
        pending = true
        if C_Timer and C_Timer.After then
            C_Timer.After(0, DoRecomputeHeight)
        else
            DoRecomputeHeight()
        end
    end

    -- opts.staticHeight: skip ALL recompute machinery (no OnSizeChanged
    -- binding, no OnShow re-measure, no DoRecomputeHeight cascade).
    -- For consumers whose text never changes after construction AND who
    -- can predict a sensible fixed height up front (e.g. animation perf
    -- warning).  Avoids the SetHeight → OnSizeChanged → TriggerHostRelayout
    -- → g:LayoutChildren feedback loop that, in container layouts where
    -- LayoutChildren re-fires SetWidth on every pass (Aura Designer's
    -- indicator card body), drops FPS the moment the banner surfaces.
    if not opts.staticHeight then
        -- Only width changes affect the wrapped string height — height
        -- changes (which our own SetHeight inside DoRecomputeHeight triggers)
        -- don't.  Filtering on width breaks part of the feedback loop, but
        -- doesn't help when the host layout fires OnSizeChanged per frame
        -- with same-or-different widths (some scroll-frame containers do).
        local lastMeasuredWidth
        banner:SetScript("OnSizeChanged", function(self, w, _)
            if w == lastMeasuredWidth then return end
            lastMeasuredWidth = w
            RecomputeHeight()
        end)
        banner:SetScript("OnShow", function()
            if deferredWhileHidden then
                deferredWhileHidden = false
                cachedH = nil
                lastMeasuredWidth = nil
                RecomputeHeight()
            end
        end)
    end
    banner._RecomputeHeight = RecomputeHeight

    function banner:SetIconTexture(path)
        self.icon:SetTexture(path)
    end

    function banner:SetIconColor(r, g, b)
        self.icon:SetVertexColor(r or 1, g or 1, b or 1)
    end

    function banner:SetIcon(path, r, g, b)
        self:SetIconTexture(path)
        if r then self:SetIconColor(r, g, b) end
    end

    function banner:SetTone(toneName)
        local tone = INFO_BANNER_TONES[toneName]
        if not tone then return end
        self._tone = toneName
        if tone.bg then self:SetBackdropColor(tone.bg[1], tone.bg[2], tone.bg[3], tone.bg[4] or 1) end
        if tone.useThemeBorder then
            local tc = (GUI.GetThemeColor and GUI.GetThemeColor()) or {r = 1, g = 1, b = 1}
            self:SetBackdropBorderColor(tc.r, tc.g, tc.b, tone.borderAlpha or 1)
        elseif tone.border then
            self:SetBackdropBorderColor(tone.border[1], tone.border[2], tone.border[3], tone.border[4] or 1)
        end
        if tone.icon then
            self:SetIconTexture(INFO_BANNER_ICON_PATH .. tone.icon)
        end
        if tone.iconColor then
            self:SetIconColor(tone.iconColor[1], tone.iconColor[2], tone.iconColor[3])
        else
            self:SetIconColor(1, 1, 1)
        end
        if tone.textColor then
            self.body:SetTextColor(tone.textColor[1], tone.textColor[2], tone.textColor[3])
        end
    end

    function banner:SetText(text, color)
        text = text or ""
        -- Idempotent guard (same freeze class as SetHTML): when already showing this
        -- exact plain text, skip the cachedH reset + RecomputeHeight + host relayout
        -- so a refreshContent-driven SetText can't loop. Colour is cheap to re-apply
        -- without a recompute. (SetContent bakes its themed title into `text`, so a
        -- mode switch changes the string and correctly re-renders.)
        if not self._isHTML and self._plainText == text then
            if color then
                local r = color[1] or color.r
                local g = color[2] or color.g
                local b = color[3] or color.b
                if r then self.body:SetTextColor(r, g, b) end
            end
            return
        end
        self._plainText = text
        -- Hide any flow widgets from a previous SetHTML call.
        if self._flowWidgets then
            for _, w in ipairs(self._flowWidgets) do w:Hide() end
        end
        self._isHTML = false
        self.body:Show()
        self.body:SetText(text)
        if color then
            local r = color[1] or color.r
            local g = color[2] or color.g
            local b = color[3] or color.b
            if r then self.body:SetTextColor(r, g, b) end
        end
        cachedH = nil
        banner._secondPassDone = false
        RecomputeHeight()
    end

    -- Theme-coloured "Title: body" content with a live-updating title colour +
    -- theme border (folds in the old CreateInfoCallout). Registers the banner as
    -- a ThemeListener so the title/border re-colour on party/raid mode switch.
    function banner:SetContent(title, body)
        self._contentTitle, self._contentBody = title, body
        if title and title ~= "" then
            local tc = (GUI.GetThemeColor and GUI.GetThemeColor()) or { r = 1, g = 1, b = 1 }
            local hex = string.format("ff%02x%02x%02x",
                math.floor(tc.r * 255), math.floor(tc.g * 255), math.floor(tc.b * 255))
            self:SetText("|c" .. hex .. title .. ":|r " .. (body or ""))
        else
            self:SetText(body or "")
        end
        if not self._themeRegistered then
            self._themeRegistered = true
            local p = self:GetParent()
            if p then
                p.ThemeListeners = p.ThemeListeners or {}
                table.insert(p.ThemeListeners, self)
            end
        end
    end

    function banner:UpdateTheme()
        if self._tone then self:SetTone(self._tone) end
        if self._contentTitle ~= nil or self._contentBody ~= nil then
            self:SetContent(self._contentTitle, self._contentBody)
        end
    end

    -- SetHTML renders text + clickable links using real Button widgets in a
    -- flow layout. This mirrors the original per-link-button approach that
    -- reliably dispatches OnClick in WoW, unlike SimpleHTML whose
    -- OnHyperlinkClick failed to fire consistently.
    --
    -- Input text uses WoW hyperlink markup: |cCOLOR|HlinkData|hText|h|r
    -- and \n for explicit line breaks. Plain text is word-split so wrapping
    -- occurs at word boundaries when the banner is narrow.

    -- Parse text into a flat list of typed tokens.
    local function ParseHTMLSegments(s)
        local segs = {}
        local function addWords(chunk)
            local pos = 1
            while pos <= #chunk do
                local nl = chunk:find("\n", pos, true)
                local line = nl and chunk:sub(pos, nl - 1) or chunk:sub(pos)
                for _, w in ipairs({strsplit(" ", line)}) do
                    if #w > 0 then segs[#segs + 1] = {type = "word", text = w} end
                end
                if nl then
                    segs[#segs + 1] = {type = "newline"}
                    pos = nl + 1
                else
                    break
                end
            end
        end
        local rem = s
        while #rem > 0 do
            local pre, color, data, lt, rest =
                rem:match("^(.-)|c(%x%x%x%x%x%x%x%x)|H([^|]*)|h([^|]*)|h|r(.*)")
            if pre ~= nil then
                addWords(pre)
                segs[#segs + 1] = {type = "link", text = lt, data = data, color = color}
                rem = rest or ""
            else
                addWords(rem)
                break
            end
        end
        return segs
    end

    -- Position all flow widgets left-to-right with wrapping; returns total
    -- content height. Punctuation tokens attach to the preceding element
    -- with no leading gap so "Foo," renders without extra space before the comma.
    local FLOW_LINE_H = 14
    local function DoFlowLayout()
        if not banner._flowSegs then return 0 end
        local availW = banner:GetWidth() - (12 + 18 + 8) - 12
        if availW < 20 then return FLOW_LINE_H end
        local x, lineY = 0, -3
        for _, seg in ipairs(banner._flowSegs) do
            if seg.type == "newline" then
                x = 0; lineY = lineY - FLOW_LINE_H - 2
            elseif seg._widget then
                local w = seg._w
                local isPunct = seg.type == "word" and seg.text:match("^[%p]") and true or false
                local gap = (x > 0 and not isPunct) and 3 or 0
                if x > 0 and (x + gap + w) > availW then
                    x = 0; lineY = lineY - FLOW_LINE_H - 2; gap = 0
                end
                seg._widget:ClearAllPoints()
                seg._widget:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8 + x + gap, lineY)
                x = x + gap + w
            end
        end
        return math.abs(lineY - (-3)) + FLOW_LINE_H
    end
    banner._DoFlowLayout = DoFlowLayout

    function banner:SetHTML(text, onLinkClick)
        text = text or ""
        -- The link words are tinted with the theme colour at render time (below),
        -- NOT baked into `text`, so a party/raid mode switch must re-render even
        -- when the text is identical — fold the theme into the dedupe key.
        local _tc = GUI.GetThemeColor and GUI.GetThemeColor() or {r = 1, g = 0.82, b = 0}
        local themeKey = string.format("%.3f,%.3f,%.3f", _tc.r or 1, _tc.g or 1, _tc.b or 1)
        -- Idempotent guard (FREEZE FIX): tearing down + rebuilding the flow widgets
        -- resets cachedH and re-fires RecomputeHeight -> TriggerHostRelayout ->
        -- host:RefreshStates. This banner's SetHTML is driven from a refreshContent
        -- hook that RefreshStates calls on EVERY pass, so an unguarded rebuild loops
        -- forever (game freeze — seen on the Buffs page when the Aura Designer banner
        -- is shown). Skip the rebuild when neither the text nor the link-tint theme
        -- changed; just keep the click handler current.
        if self._isHTML and self._htmlText == text and self._htmlThemeKey == themeKey then
            self._onLinkClick = onLinkClick
            return
        end
        self._htmlThemeKey = themeKey
        self._htmlText = text
        self._onLinkClick = onLinkClick
        self._isHTML = true
        self.body:Hide()

        -- Tear down widgets from any previous call.
        if self._flowWidgets then
            for _, w in ipairs(self._flowWidgets) do w:Hide() end
        end
        self._flowWidgets = {}

        local tc = GUI.GetThemeColor and GUI.GetThemeColor() or {r = 1, g = 0.82, b = 0}
        local segs = ParseHTMLSegments(self._htmlText)
        self._flowSegs = segs

        for _, seg in ipairs(segs) do
            if seg.type == "word" then
                local fs = self:CreateFontString(nil, "OVERLAY", fontTemplate)
                if not opts.fontTemplate then GUI:SetSettingsFont(fs, 11, "") end  -- match the 11px plain body
                fs:SetText(seg.text)
                fs:SetTextColor(0.85, 0.85, 0.85)
                seg._w = fs:GetStringWidth()
                -- Give an explicit size matching the button height so TOPLEFT
                -- anchors place both text words and link buttons on the same baseline.
                fs:SetSize(seg._w, FLOW_LINE_H)
                seg._widget = fs
                self._flowWidgets[#self._flowWidgets + 1] = fs
            elseif seg.type == "link" then
                local btn = CreateFrame("Button", nil, self)
                local fs = btn:CreateFontString(nil, "OVERLAY", fontTemplate)
                if not opts.fontTemplate then GUI:SetSettingsFont(fs, 11, "") end  -- match the 11px plain body
                fs:SetAllPoints()
                fs:SetText(seg.text)
                fs:SetTextColor(tc.r, tc.g, tc.b)
                local w = fs:GetStringWidth() + 2
                btn:SetSize(w, FLOW_LINE_H)
                btn:SetScript("OnEnter", function() fs:SetTextColor(1, 1, 1) end)
                btn:SetScript("OnLeave", function()
                    local c = GUI.GetThemeColor and GUI.GetThemeColor() or tc
                    fs:SetTextColor(c.r, c.g, c.b)
                end)
                local segData = seg.data
                btn:SetScript("OnClick", function()
                    if self._onLinkClick then
                        local _, pageId = strsplit(":", segData)
                        self._onLinkClick(pageId or segData)
                    end
                end)
                seg._widget = btn
                seg._w = w
                self._flowWidgets[#self._flowWidgets + 1] = btn
            end
        end

        DoFlowLayout()
        cachedH = nil
        banner._secondPassDone = false
        RecomputeHeight()
    end

    -- Apply opts at creation
    if opts.tone then banner:SetTone(opts.tone) end
    if opts.iconTexture then banner:SetIconTexture(opts.iconTexture) end
    if opts.iconColor then banner:SetIconColor(opts.iconColor[1], opts.iconColor[2], opts.iconColor[3]) end
    if opts.html then
        banner:SetHTML(opts.text, opts.onLinkClick)
    elseif opts.text then
        banner:SetText(opts.text, opts.textColor)
    end

    return banner
end

-- Apply the standard button look to an existing Button frame — the single
-- source of truth for button styling, shared by GUI:CreateButton AND by
-- hand-rolled buttons that need the same look (the button analogue of
-- GUI:StyleCheckButton). opts:
--   width/height  resize the button
--   text          create/set a centered DFFontHighlightSmall label (btn.Text)
--   accent        {r,g,b} — fixes the accent colour (e.g. ClickCasting green).
--                 Omit to use the mode accent (party purple / raid orange),
--                 tracking the theme.
--   primary       true → a prominent CTA: a persistent accent-tinted fill +
--                 accent border at rest (the hover wash just brightens it). Use
--                 for the main/confirming action; normal buttons are grey at rest.
--   fadeActiveText true → on SetActive(true) dim btn.Text/btn.Icon to ~0.7 alpha
--                 (back to full when inactive). For an "almost always on" status
--                 toggle like Sync, where the active (synced) state is the resting
--                 norm so the label can recede. Leave OFF for momentary toggles
--                 (Test/Unlock) and selection toggles (chips/segmented), whose
--                 active text should stay bright/white.
-- Hover respects the isTab/isActive convention used by the tab bar. Hover uses
-- SetScript (matching the original CreateButton); buttons that also need a
-- tooltip should HookScript their OnEnter so it composes with the hover.
-- ============================================================
-- GUI TOOLTIP  (settings-UI tooltips only — NOT unit-frame/aura tooltips)
-- Single source for our own widget tooltips. Call from OnEnter — use HookScript
-- on StyleButton'd widgets so it composes with the hover wash; SetScript on
-- plain frames. Pair with OnLeave -> GameTooltip:Hide().
--   opts.title  (string)   white by default, or tone-coloured
--   opts.tone   nil | "warning" (gold) | "danger" (red)
--   opts.anchor "ANCHOR_RIGHT" (default; edge-safe — avoid ANCHOR_TOP which
--               clamps over the owner near the frame top)
--   opts.lines  array; each element is one of:
--       "text"                     -> body grey (0.7), wrapped
--       " "                        -> blank spacer
--       { text = , hint = true }   -> dim grey (0.55) action hint, wrapped
--       { text = , accent = true } -> mode/context accent colour, wrapped
--       { text = , color = {r,g,b} } -> explicit colour, wrapped
-- ============================================================
function GUI:ShowTooltip(owner, opts)
    if not owner or not opts or not opts.title then return end
    GameTooltip:SetOwner(owner, opts.anchor or "ANCHOR_RIGHT")
    -- Title colour is single-sourced from the tone's inline accent so a tooltip
    -- title reads the same as inline ToneHex text of the same tone. Untoned = white.
    local toneDef = opts.tone and INFO_BANNER_TONES[opts.tone]
    local ac = toneDef and toneDef.accent
    if ac then
        GameTooltip:SetText(opts.title, ac[1], ac[2], ac[3])
    else
        GameTooltip:SetText(opts.title, 1, 1, 1)
    end
    if opts.lines then
        local acc
        for _, line in ipairs(opts.lines) do
            if line == " " or line == "" then
                GameTooltip:AddLine(" ")
            elseif type(line) == "string" then
                GameTooltip:AddLine(line, 0.7, 0.7, 0.7, true)
            elseif type(line) == "table" and line.text then
                local r, g, b = 0.7, 0.7, 0.7
                if line.hint then
                    r, g, b = 0.55, 0.55, 0.55
                elseif line.accent then
                    acc = acc or GetThemeColor()
                    r, g, b = acc.r, acc.g, acc.b
                elseif line.color then
                    r, g, b = line.color.r, line.color.g, line.color.b
                end
                GameTooltip:AddLine(line.text, r, g, b, true)
            end
        end
    end
    GameTooltip:Show()
end

-- Counterpart to ShowTooltip: hide the shared GameTooltip. Wrapped so callers
-- route through GUI instead of poking GameTooltip directly.
function GUI:HideTooltip()
    GameTooltip:Hide()
end

function GUI:StyleButton(btn, opts)
    opts = opts or {}
    if opts.width or opts.height then
        btn:SetSize(opts.width or btn:GetWidth(), opts.height or btn:GetHeight())
    end
    CreateElementBackdrop(btn)  -- mixes in BackdropTemplate if needed

    -- Optional label + leading icon. opts.icon = { texture, size (14),
    -- color {r,g,b}, gap (4) }. opts.align controls layout:
    --   "center" (default) — centre the icon+label as a GROUP (text-only centres
    --     the label; icon-only centres the icon). Best for compact buttons whose
    --     width ~ their content.
    --   "left" — pin the icon at opts.leftPad (12) with the label after it. Best
    --     for wide / full-width list-style buttons, where centred content floats
    --     in a sea of empty space.
    local iconOpt = opts.icon
    local iconGap = (iconOpt and iconOpt.gap) or 4
    local iconW = (iconOpt and (iconOpt.size or 18)) or 0
    local hasText = opts.text ~= nil and opts.text ~= ""
    local align = opts.align or "center"
    local leftPad = opts.leftPad or 12
    -- Toned buttons (danger / success): neutral at rest with an accent-coloured
    -- label+icon — soft red for destructive, soft green for affirmative — plus the
    -- accent hover wash. A coloured-text button, NOT a filled CTA (the accent set
    -- below drives the hover). Mirrors each other so Delete/Save read as a pair.
    local toneLabel = (opts.tone == "danger" and { 0.9, 0.45, 0.45 })
        or (opts.tone == "success" and { 0.4, 0.85, 0.5 }) or nil

    if opts.text ~= nil then
        btn.Text = btn.Text or btn:CreateFontString(nil, "OVERLAY", opts.font or "DFFontHighlightSmall")
        btn.Text:SetText(opts.text)
        if toneLabel then
            btn.Text:SetTextColor(toneLabel[1], toneLabel[2], toneLabel[3])
        else
            btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        end
    end

    if iconOpt then
        btn.Icon = btn.Icon or btn:CreateTexture(nil, "OVERLAY")
        btn.Icon:SetTexture(iconOpt.texture)
        btn.Icon:SetSize(iconW, iconW)
        if iconOpt.color then
            btn.Icon:SetVertexColor(iconOpt.color.r, iconOpt.color.g, iconOpt.color.b)
        elseif toneLabel then
            btn.Icon:SetVertexColor(toneLabel[1], toneLabel[2], toneLabel[3])
        end
    end

    -- Anchor the icon/label per alignment.
    if align == "left" then
        if iconOpt then
            btn.Icon:ClearAllPoints()
            btn.Icon:SetPoint("LEFT", leftPad, 0)
        end
        if btn.Text then
            btn.Text:ClearAllPoints()
            if iconOpt then
                btn.Text:SetPoint("LEFT", btn.Icon, "RIGHT", iconGap, 0)
            else
                btn.Text:SetPoint("LEFT", leftPad, 0)
            end
        end
    else
        if btn.Text then
            btn.Text:ClearAllPoints()
            -- Offset right by half the icon+gap so the icon+label GROUP centres.
            btn.Text:SetPoint("CENTER", btn, "CENTER", (iconOpt and hasText) and (iconW + iconGap) / 2 or 0, 0)
        end
        if iconOpt then
            btn.Icon:ClearAllPoints()
            if hasText then
                btn.Icon:SetPoint("RIGHT", btn.Text, "LEFT", -iconGap, 0)
            else
                btn.Icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
            end
        end
    end

    -- Hover: an accent wash via the native HIGHLIGHT layer (auto-shown on
    -- mouseover, like StyleCheckButton / the menu buttons) PLUS a darker accent
    -- border for definition. `primary` buttons additionally keep a persistent
    -- accent-tinted fill + accent border at rest. Accent = explicit opts.accent
    -- (e.g. ClickCasting green) or the mode accent (party purple / raid orange).
    local accent = opts.accent
    -- tone presets: a destructive "danger" button reuses ALL the accent
    -- machinery (hover wash, hover border, primary fill) with a fixed FF4444 red.
    -- So a plain danger button is neutral-at-rest with a red hover, and
    -- danger+primary is a filled red CTA. Fixed colour ⇒ it won't theme-track
    -- (correct — destructive red shouldn't follow the party/raid accent).
    if not accent then
        if opts.tone == "danger" then
            accent = { r = 1, g = 0.27, b = 0.27 }
        elseif opts.tone == "success" then
            accent = { r = 0.3, g = 0.8, b = 0.45 }
        end
    end
    local primary = opts.primary
    local fadeActiveText = opts.fadeActiveText
    -- Underline TAB style (opts.tab): the button is transparent (no fill/border)
    -- and its active cue is a 2px accent stripe along the bottom + an accent label
    -- (dim label when inactive). Driven by SetActive, like a toggle. Distinct from
    -- the legacy `isTab` filled-sidebar branch in restBackdrop.
    local isTabStyle = opts.tab
    -- Ghost action (opts.ghost): transparent like a tab but with no underline — an
    -- accent label + faint hover wash. For quiet inline actions (e.g. "+ Add").
    local ghost = opts.ghost
    -- Persistent semantic accent (opts.tinted): the accent is meaningful and stays
    -- ON at rest — faint accent fill + accent border + accent label — rather than
    -- being a neutral button with an accent hover. For role quick-add buttons etc.
    -- where the colour IS the button's identity. Pass a fixed opts.accent.
    local tinted = opts.tinted
    local hl = btn:GetHighlightTexture() or btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\Buttons\\WHITE8x8")
    hl:SetAllPoints(btn)
    btn.Highlight = hl

    if isTabStyle then
        local stripe = btn:CreateTexture(nil, "OVERLAY")
        stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
        stripe:SetHeight(3)
        stripe:SetPoint("BOTTOMLEFT", 0, 0)   -- full-width underline (no insets)
        stripe:SetPoint("BOTTOMRIGHT", 0, 0)
        stripe:Hide()
        btn.dfTabStripe = stripe
    end

    -- The resting backdrop the button returns to on mouse-out (and that primary
    -- buttons also wear permanently): accent-tinted for primary, the active-tab
    -- panel colour for active tabs, otherwise the neutral element colour.
    local function restBackdrop(self, a)
        if isTabStyle then
            -- Underline tab: a faint neutral cell when inactive (so every tab's
            -- bounds stay visible and the active one doesn't appear to "grow"),
            -- and a stronger accent fill when active (a held-hover highlight)
            -- beneath its stripe.
            if self.dfActive then
                self:SetBackdropColor(a.r, a.g, a.b, 0.18)
            else
                self:SetBackdropColor(1, 1, 1, 0.05)
            end
            self:SetBackdropBorderColor(0, 0, 0, 0)
            return
        end
        if ghost then
            -- Ghost action: a faint neutral cell (matching inactive tabs) with an
            -- accent label, so it sits consistently in a tab strip; the wash
            -- brightens it on hover.
            self:SetBackdropColor(1, 1, 1, 0.05)
            self:SetBackdropBorderColor(0, 0, 0, 0)
            return
        end
        if tinted then
            -- Persistent semantic accent: faint accent fill + medium accent border
            -- at rest (label/icon accent-coloured in ApplyThemeColor). Hover adds a
            -- full-accent border + the wash brightens the fill.
            self:SetBackdropColor(a.r * 0.15, a.g * 0.15, a.b * 0.15, 0.9)
            self:SetBackdropBorderColor(a.r * 0.5, a.g * 0.5, a.b * 0.5, 0.8)
            return
        end
        if self.dfActive then
            -- Selected toggle/segmented button: a subtle accent fill + a clear
            -- accent border (more than the muted hover border, but toned down from
            -- full so it doesn't read as a heavy bright outline).
            self:SetBackdropColor(a.r * 0.3, a.g * 0.3, a.b * 0.3, 1)
            self:SetBackdropBorderColor(a.r * 0.6, a.g * 0.6, a.b * 0.6, 1)
        elseif primary then
            -- Filled accent CTA: a medium accent fill with a slightly darker
            -- accent border (the same border-darker-than-fill relationship as the
            -- standard hover) so it reads like an emphasised standard button, not
            -- a dark fill ringed by a harsh bright outline.
            self:SetBackdropColor(a.r * 0.5, a.g * 0.5, a.b * 0.5, 1)
            self:SetBackdropBorderColor(a.r * 0.4, a.g * 0.4, a.b * 0.4, 1)
        elseif self.isTab and self.isActive then
            self:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 1)
            self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        else
            self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        end
    end

    btn.ApplyThemeColor = function(c)
        hl:SetVertexColor(c.r, c.g, c.b, (isTabStyle or ghost) and 0.15 or 0.30)
        if isTabStyle then
            restBackdrop(btn, c)  -- keep the tab transparent (no fill/border)
            -- refresh the stripe colour + the active label to the new accent
            if btn.dfTabStripe then btn.dfTabStripe:SetColorTexture(c.r, c.g, c.b, 1) end
            if btn.dfActive and btn.Text then btn.Text:SetTextColor(c.r, c.g, c.b) end
        elseif ghost or tinted then
            restBackdrop(btn, c)  -- faint cell / tinted fill; accent-coloured label
            if btn.Text then btn.Text:SetTextColor(c.r, c.g, c.b) end
            if btn.Icon then btn.Icon:SetVertexColor(c.r, c.g, c.b) end  -- icon matches the accent label
        elseif primary or btn.dfActive then
            restBackdrop(btn, c)  -- refresh persistent accent
        end
    end

    -- Toggle/segmented selection: btn:SetActive(true) marks the button as the
    -- current selection (prominent accent border via restBackdrop); false returns
    -- it to its normal rest. The owning group is responsible for clearing the
    -- previously-active button. Works on any StyleButton'd button.
    btn.SetActive = function(self, active)
        self.dfActive = active and true or false
        restBackdrop(self, accent or GetThemeColor())
        if isTabStyle then
            -- Underline tab: show the accent stripe + accent label when active,
            -- dim label when inactive.
            local a = accent or GetThemeColor()
            if self.dfTabStripe then
                self.dfTabStripe:SetColorTexture(a.r, a.g, a.b, 1)
                self.dfTabStripe:SetShown(self.dfActive)
            end
            if self.Text then
                if self.dfActive then
                    self.Text:SetTextColor(a.r, a.g, a.b)
                else
                    self.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                end
            end
        end
        if fadeActiveText then
            -- Status toggles: the active fill+border carry the "on" emphasis, so
            -- the label/icon recede slightly when active (settled) and stay bright
            -- when inactive (a clearer call to action). Alpha keeps this
            -- independent of whatever colour the owner sets on the text/icon.
            local a = self.dfActive and 0.7 or 1
            if self.Text then self.Text:SetAlpha(a) end
            if self.Icon then self.Icon:SetAlpha(a) end
        end
    end

    -- Disabled / "greyed out": a dim backdrop + faint border, label/icon dimmed
    -- via alpha (keeps their own colour, just recedes), and the hover wash +
    -- border suppressed. The button stays natively enabled so a HookScript
    -- tooltip can still explain WHY it's disabled; the owner's OnClick must
    -- early-out on self.dfDisabled. SetDisabled(false) restores the normal/
    -- active/primary rest.
    btn.SetDisabled = function(self, disabled)
        self.dfDisabled = disabled and true or false
        if self.dfDisabled then
            self:SetBackdropColor(C_ELEMENT.r * 0.55, C_ELEMENT.g * 0.55, C_ELEMENT.b * 0.55, 0.6)
            self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.25)
            hl:SetAlpha(0)  -- kill the auto hover wash while disabled
            if self.Text then self.Text:SetAlpha(0.35) end
            if self.Icon then self.Icon:SetAlpha(0.35) end
        else
            hl:SetAlpha(1)
            restBackdrop(self, accent or GetThemeColor())
            if self.Text then self.Text:SetAlpha(1) end
            if self.Icon then self.Icon:SetAlpha(1) end
        end
    end
    -- The grey loop (RefreshChildStates) greys gated children via widget:SetEnabled.
    -- Native Button:SetEnabled blocks clicks but won't dim a custom-backdrop button
    -- (its backdrop/Text are custom, not native button regions), so layer a SetAlpha
    -- dim on top. We route through native + SetAlpha, NOT SetDisabled — SetDisabled
    -- stays natively clickable (it relies on an OnClick dfDisabled early-out the
    -- consumer may not have) and fights the hover wash on SetActive toggles.
    local nativeSetEnabled = btn.SetEnabled
    btn.SetEnabled = function(self, enabled)
        nativeSetEnabled(self, enabled)
        self:SetAlpha(enabled and 1 or 0.4)
    end

    btn.ApplyThemeColor(accent or GetThemeColor())
    if not accent then
        btn.UpdateTheme = function() btn.ApplyThemeColor(GetThemeColor()) end
        local root = opts.themeRoot or btn:GetParent()
        if root then
            root.ThemeListeners = root.ThemeListeners or {}
            table.insert(root.ThemeListeners, btn)
        end
    end

    btn:SetScript("OnEnter", function(self)
        if isTabStyle or ghost then return end  -- tab/ghost: only the auto wash, no border
        if self:IsEnabled() and not self.dfDisabled then
            local a = accent or GetThemeColor()
            if tinted then
                self:SetBackdropBorderColor(a.r, a.g, a.b, 1)  -- full accent border on hover
            elseif self.dfActive then
                -- keep the active border on hover (the wash still brightens the
                -- fill, giving the hover cue).
                self:SetBackdropBorderColor(a.r * 0.6, a.g * 0.6, a.b * 0.6, 1)
            else
                -- border darkens to a shade of the accent; the HIGHLIGHT wash
                -- brightens the fill. The wash is translucent (0.3), so the
                -- full-opacity border still reads DARKER than the fill. Same for
                -- primary — it keeps its edge and the brightening fill is the cue.
                self:SetBackdropBorderColor(a.r * 0.4, a.g * 0.4, a.b * 0.4, 1)
            end
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if isTabStyle or ghost then return end
        if self:IsEnabled() and not self.dfDisabled then
            restBackdrop(self, accent or GetThemeColor())
        end
    end)
    return btn
end

function GUI:CreateButton(parent, text, width, height, func, iconName)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    local opts = { width = width or 120, height = height or 22, text = text }
    -- Optional leading icon by Media\Icons name (14px to suit the small buttons).
    if iconName then
        opts.icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. iconName, size = 14 }
    end
    GUI:StyleButton(btn, opts)
    btn:SetScript("OnClick", function(self)
        if func then func(self) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    return btn
end

-- Standard close/dismiss button: a small square danger-toned button showing a
-- "×" glyph. Replaces the many hand-rolled red close buttons on dialogs/panels.
-- opts = { size (20), onClick, tooltip, tone }.
--   tone = nil      → dim grey "×" at rest → white on hover (close/dismiss; default)
--   tone = "danger" → RED "×" at rest → brighter red on hover (inline destructive
--                     removes: list-item / tag removes). Both keep the red hover wash.
function GUI:CreateCloseButton(parent, opts)
    opts = opts or {}
    local size = opts.size or 20
    -- Rest/hover glyph colours: grey→white for dismiss, red→brighter-red for inline
    -- destructive removes. The StyleButton red wash + border is shared by both.
    local restColor  = (opts.tone == "danger") and { r = 0.9, g = 0.45, b = 0.45 } or C_TEXT_DIM
    local hoverColor = (opts.tone == "danger") and { r = 1, g = 0.4, b = 0.4 } or { r = 1, g = 1, b = 1 }
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    GUI:StyleButton(btn, {
        width = size, height = size,
        tone = "danger",
        icon = {
            texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\close",
            size = math.max(8, math.floor(size * 0.55)),
            color = restColor,
        },
    })
    btn:HookScript("OnEnter", function(self) self.Icon:SetVertexColor(hoverColor.r, hoverColor.g, hoverColor.b) end)
    btn:HookScript("OnLeave", function(self) self.Icon:SetVertexColor(restColor.r, restColor.g, restColor.b) end)
    btn:SetScript("OnClick", function(self)
        if opts.onClick then opts.onClick(self) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    if opts.tooltip then
        btn:HookScript("OnEnter", function(self)
            GUI:ShowTooltip(self, { title = opts.tooltip, anchor = "ANCHOR_TOP" })
        end)
        btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
    end
    return btn
end

-- Shared panel/dialog root backdrop: a solid dark panel with an optional 1px
-- border. Centralises the inline SetBackdrop blocks scattered across dialogs and
-- floating panels. opts = { bgAlpha (0.95), border (true), borderColor {r,g,b,a}
-- or {r,g,b,a array} }.
function GUI:CreatePanelBackdrop(frame, opts)
    opts = opts or {}
    if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
    -- Choose the edge with an explicit branch, NOT `cond and nil or X` — in Lua
    -- that idiom always yields X (the `and nil` falls through the `or`), so
    -- border=false would still draw an (untinted, i.e. WHITE) edge.
    local edgeFile = "Interface\\Buttons\\WHITE8x8"
    if opts.border == false then edgeFile = nil end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = edgeFile,
        edgeSize = 1,
    })
    local bg = opts.bgColor or C_PANEL
    frame:SetBackdropColor(bg.r or bg[1], bg.g or bg[2], bg.b or bg[3], opts.bgAlpha or bg.a or 0.95)
    if opts.border ~= false then
        local bc = opts.borderColor
        if bc then
            frame:SetBackdropBorderColor(bc.r or bc[1], bc.g or bc[2], bc.b or bc[3], bc.a or bc[4] or 1)
        else
            frame:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 1)
        end
    end
    return frame
end

-- Element backdrop as a GUI method (the file-local CreateElementBackdrop is used
-- internally by the stylers; this exposes it to consumer files). Base look =
-- C_ELEMENT fill + C_BORDER border. opts = { bgColor, borderColor } ({r,g,b[,a]})
-- override either when an element panel wants a darker/custom fill or accent edge.
function GUI:CreateElementBackdrop(frame, opts)
    CreateElementBackdrop(frame)
    if opts then
        if opts.bgColor then
            local c = opts.bgColor
            frame:SetBackdropColor(c.r or c[1], c.g or c[2], c.b or c[3], c.a or c[4] or 1)
        end
        if opts.borderColor then
            local c = opts.borderColor
            frame:SetBackdropBorderColor(c.r or c[1], c.g or c[2], c.b or c[3], c.a or c[4] or 1)
        end
    end
    return frame
end

-- ============================================================
-- DESIGNER PRESET BAR (shared by the Aura / Text Designer editors)
-- Compact row: "Preset: [dropdown ▾]  [New][Duplicate][Rename][Delete]".
-- Picking a preset assigns it to the mode (opts.getMode()) AND retargets the
-- editor; the buttons manage the library. After any change the bar calls
-- opts.onChange() so the host page can rebuild + refresh live frames.
-- opts = { kind = "aura"|"text", getMode = fn->mode, onChange = fn }.
-- Returns the bar frame; call bar:Refresh() to resync.
-- ============================================================

-- One reusable name-input popup (callback + default passed via `data`).
-- Structural dialog definitions; per-call handlers are assigned in the launchers
-- below (closures capturing default/callback) — the StaticPopup `data` field and
-- the editbox field name both vary across client versions, so we avoid relying
-- on them. The editbox is `self.EditBox` on current retail (12.0 GameDialog).
StaticPopupDialogs["DANDERSFRAMES_PRESET_NAME"] = {
    text = "%s",
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    editBoxWidth = 220,
    maxLetters = 40,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["DANDERSFRAMES_PRESET_DELETE"] = {
    text = "%s",
    button1 = DELETE or "Delete",
    button2 = CANCEL or "Cancel",
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function PromptPresetName(titleText, default, callback)
    local dialog = StaticPopupDialogs["DANDERSFRAMES_PRESET_NAME"]
    dialog.OnShow = function(self)
        local eb = self.EditBox or self.editBox or (self.GetEditBox and self:GetEditBox())
        if eb then
            eb:SetText(default or "")
            eb:HighlightText()
            eb:SetFocus()
        end
    end
    dialog.OnAccept = function(self)
        local eb = self.EditBox or self.editBox or (self.GetEditBox and self:GetEditBox())
        if callback and eb then callback(eb:GetText()) end
    end
    dialog.EditBoxOnEnterPressed = function(self)
        if callback then callback(self:GetText()) end
        local p = self:GetParent()
        if p then p:Hide() end
    end
    StaticPopup_Show("DANDERSFRAMES_PRESET_NAME", titleText)
end

local function ConfirmDeletePreset(kind, name, onDone)
    local dialog = StaticPopupDialogs["DANDERSFRAMES_PRESET_DELETE"]
    dialog.OnAccept = function()
        if DF.DeleteDesignerPreset then
            DF:DeleteDesignerPreset(kind, name)
            if onDone then onDone() end
        end
    end
    StaticPopup_Show("DANDERSFRAMES_PRESET_DELETE",
        format(L["Delete preset \"%s\"? Anything using it reverts to Default."], name))
end

function GUI:CreateDesignerPresetBar(parent, opts)
    opts = opts or {}
    local kind = opts.kind or "aura"
    local getMode = opts.getMode or function() return "party" end
    local onChange = opts.onChange or function() end

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(24)

    local label = bar:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    label:SetPoint("LEFT", 0, 0)
    label:SetText(L["Preset:"])
    label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local function CurrentName()
        return DF:GetModeDesignerPresetName(kind, getMode())
    end

    -- True while editing a raid auto-layout (the only context with an "inherit
    -- the global preset" choice — normal party/raid modes ARE the base).
    -- Mode-gated: auto-layouts are RAID-only, but the GUI can be reopened on
    -- the party tab while editing (ToggleGUI re-derives SelectedMode) — the
    -- PARTY preset bar must not show layout state, and its "Inherit (Global)"
    -- click must never clear the RAID layout's override.
    local function IsEditingLayout()
        return getMode() == "raid"
            and DF.AutoProfilesUI and DF.AutoProfilesUI.IsEditing and DF.AutoProfilesUI:IsEditing()
    end

    -- The label to show on the dropdown button: "Inherit (Global)" when the
    -- edited layout has no override, otherwise the resolved preset name.
    local function CurrentLabel()
        if IsEditingLayout() and DF.IsLayoutDesignerInheriting and DF:IsLayoutDesignerInheriting(kind) then
            return L["Inherit (Global)"]
        end
        return CurrentName()
    end

    -- Dropdown button + menu (rebuilt on each open so it always reflects the lib)
    local ddBtn = CreateFrame("Button", nil, bar, "BackdropTemplate")
    ddBtn:SetSize(150, 22)
    ddBtn:SetPoint("LEFT", label, "RIGHT", 6, 0)
    CreateElementBackdrop(ddBtn)
    ddBtn.text = ddBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    ddBtn.text:SetPoint("LEFT", 6, 0)
    ddBtn.text:SetPoint("RIGHT", -16, 0)
    ddBtn.text:SetJustifyH("LEFT")
    ddBtn.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    local arrow = ddBtn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -4, 0)
    arrow:SetSize(10, 10)
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local menu = CreateFrame("Frame", nil, ddBtn, "BackdropTemplate")
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetPoint("TOPLEFT", ddBtn, "BOTTOMLEFT", 0, -1)
    menu:SetWidth(150)
    CreatePanelBackdrop(menu)
    menu:Hide()

    -- Row pool: frames can't be garbage-collected in WoW, so recreating the
    -- items on every open (the old Hide+SetParent(nil) approach) leaked a row
    -- set per click. Reuse instead.
    local menuRows = {}
    local function BuildMenu()
        for _, row in ipairs(menuRows) do row:Hide() end
        local used = 0
        local y = -4
        local function AddItem(label, onClick)
            used = used + 1
            local item = menuRows[used]
            if not item then
                item = CreateFrame("Button", nil, menu)
                item:SetHeight(20)
                item.text = item:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                item.text:SetPoint("LEFT", 4, 0)
                item:SetScript("OnEnter", function(s) s.text:SetTextColor(1, 1, 1) end)
                item:SetScript("OnLeave", function(s) s.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b) end)
                item:SetScript("OnClick", function(s)
                    s.onClick()
                    menu:Hide()
                    bar:Refresh()
                    onChange()
                end)
                menuRows[used] = item
            end
            item:ClearAllPoints()
            item:SetPoint("TOPLEFT", 4, y)
            item:SetPoint("TOPRIGHT", -4, y)
            item.text:SetText(label)
            item.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            item.onClick = onClick
            item:Show()
            y = y - 20
        end
        -- "Inherit (Global)" — only while editing a raid auto-layout. Clears the
        -- layout's preset override so it follows your global preset.
        if IsEditingLayout() then
            AddItem(L["Inherit (Global)"], function()
                if DF.InheritLayoutDesignerPreset then DF:InheritLayoutDesignerPreset(kind) end
            end)
        end
        for _, name in ipairs(DF:ListDesignerPresets(kind)) do
            AddItem(name, function() DF:SetModeDesignerPreset(kind, getMode(), name) end)
        end
        menu:SetHeight(-y + 4)
    end
    ddBtn:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide() else BuildMenu(); menu:Show() end
    end)

    -- When editing a raid auto-layout, default the NEW preset name to the
    -- layout's name (e.g. editing "31-40" → prefill "31-40") so making a
    -- per-layout preset is one click + Enter. nil (blank) otherwise. (Duplicate
    -- names after its source preset, not the layout.)
    local function EditingLayoutName()
        if not IsEditingLayout() then return nil end  -- mode-gated (raid only)
        local apu = DF.AutoProfilesUI
        if apu and apu.editingProfile then
            return apu.editingProfile.name
        end
        return nil
    end

    -- Action buttons
    local newBtn = GUI:CreateButton(bar, L["New"], 48, 22, function()
        PromptPresetName(L["Name the new preset:"], EditingLayoutName() or "", function(text)
            local n = DF:CreateDesignerPreset(kind, text)
            if n then
                DF:SetModeDesignerPreset(kind, getMode(), n)
                bar:Refresh(); onChange()
            end
        end)
    end)
    newBtn:SetPoint("LEFT", ddBtn, "RIGHT", 6, 0)

    local dupBtn = GUI:CreateButton(bar, L["Duplicate"], 72, 22, function()
        local cur = CurrentName()
        -- Duplicate defaults to "<source> copy" (New uses the layout name, but a
        -- duplicate is of a specific preset, so name it after the source).
        PromptPresetName(L["Name the duplicated preset:"], cur .. " copy", function(text)
            local n = DF:DuplicateDesignerPreset(kind, cur, text)
            if n then
                DF:SetModeDesignerPreset(kind, getMode(), n)
                bar:Refresh(); onChange()
            end
        end)
    end)
    dupBtn:SetPoint("LEFT", newBtn, "RIGHT", 4, 0)

    local renameBtn = GUI:CreateButton(bar, L["Rename"], 62, 22, function()
        local cur = CurrentName()
        if cur == DF.DEFAULT_PRESET then return end
        PromptPresetName(L["Rename preset:"], cur, function(text)
            DF:RenameDesignerPreset(kind, cur, text)
            bar:Refresh(); onChange()
        end)
    end)
    renameBtn:SetPoint("LEFT", dupBtn, "RIGHT", 4, 0)

    local delBtn = GUI:CreateButton(bar, L["Delete"], 56, 22, function()
        local cur = CurrentName()
        if cur == DF.DEFAULT_PRESET then return end
        ConfirmDeletePreset(kind, cur, function() bar:Refresh(); onChange() end)
    end)
    delBtn:SetPoint("LEFT", renameBtn, "RIGHT", 4, 0)

    local function SetActionEnabled(btn, on)
        if on then
            btn:Enable()
            btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            btn:Disable()
            btn.Text:SetTextColor(0.4, 0.4, 0.4)   -- greyed: Default can't be renamed/deleted
        end
    end

    function bar:Refresh()
        ddBtn.text:SetText(CurrentLabel())
        -- Rename/Delete act on the resolved preset; disable for the non-editable
        -- Default and while a layout is inheriting (you're following the global,
        -- not sitting on a layout-specific preset).
        local inheriting = IsEditingLayout() and DF.IsLayoutDesignerInheriting
            and DF:IsLayoutDesignerInheriting(kind)
        local canModify = (CurrentName() ~= DF.DEFAULT_PRESET) and not inheriting
        SetActionEnabled(renameBtn, canModify)
        SetActionEnabled(delBtn, canModify)
    end

    bar:Refresh()
    return bar
end

-- Creates a button with an icon and text
-- iconName is the name of the icon file (without path/extension)
-- iconSize is optional (defaults to 16)
-- align: "center" (default) or "left". Pass "left" for wide / full-width
-- list-style buttons where centred content floats (see GUI:StyleButton).
function GUI:CreateIconButton(parent, iconName, text, width, height, func, iconSize, align)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    GUI:StyleButton(btn, {
        width = width or 120, height = height or 22,
        text = text,
        align = align,
        icon = {
            texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. iconName,
            size = iconSize or 18,
            color = C_TEXT,
        },
    })

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
    
    local label = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    label:SetPoint("TOPLEFT", 8, -10)
    label:SetText(L["See Also:"])
    label:SetTextColor(0.7, 0.7, 0.7)
    
    local linkButtons = {}
    local separators = {}
    
    for i, linkData in ipairs(links) do
        local link = CreateFrame("Button", nil, container)
        link:SetHeight(16)
        
        local linkText = link:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
            local sep = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
DF:RegisterDebugSlash("DFOVERRIDEDEBUG", "Auto layout override table dump", true, "/dfoverridedebug")
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

local function AddOverrideIndicators(container, lbl, dbKey, onReset, verticalOffset, optionsMap, dbTable)
    -- Skip for proxy tables (e.g. Aura Designer) that don't support per-key override tracking
    if dbTable and rawget(dbTable, "_skipOverrideIndicators") then return end
    verticalOffset = verticalOffset or 0
    container.overrideOptionsMap = optionsMap
    
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
        GUI:ShowTooltip(self, { title = L["Reset to Global"] })
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
            GUI:ShowTooltip(s, { title = s.tooltipText, lines = s.tooltipSubText and { s.tooltipSubText } or nil })
        end
    end)
    starBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    container.overrideStar = starBtn

    -- Global value text (shown when in edit mode) - positioned inline after label
    local globalText = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
            self.overrideStar.tooltipText = L["Overridden by Auto Layout"]
            self.overrideStar.tooltipSubText = L["This setting is being overridden by the active auto layout profile. To change it, edit the profile in the Auto Layouts tab."]
            self.overrideStar:Show()
            self.overrideResetBtn:Hide()  -- Can't reset runtime overrides from controls
            self.overrideCheckIcon:Hide()

            local globalValue = AutoProfilesUI:GetRuntimeGlobalValue(dbKey)

            -- Format global value for display
            local globalDisplay
            if type(globalValue) == "boolean" then
                globalDisplay = globalValue and L["Yes"] or L["No"]
            elseif type(globalValue) == "number" then
                if globalValue == math.floor(globalValue) then
                    globalDisplay = tostring(globalValue)
                else
                    globalDisplay = string.format("%.2f", globalValue)
                end
            elseif type(globalValue) == "table" then
                if globalValue.r then
                    globalDisplay = L["Color"]
                else
                    globalDisplay = "..."
                end
            elseif type(globalValue) == "string" and self.overrideOptionsMap and self.overrideOptionsMap[globalValue] then
                local mapped = self.overrideOptionsMap[globalValue]
                if type(mapped) == "table" then
                    globalDisplay = mapped.text or mapped.label or globalValue
                else
                    globalDisplay = tostring(mapped)
                end
            else
                globalDisplay = tostring(globalValue or L["None"])
            end

            self.overrideGlobalText:SetText(string.format(L["(Global: %s)"], globalDisplay))
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
            self.overrideStar.tooltipText = L["Overridden in this layout"]
            self.overrideStar.tooltipSubText = L["This setting differs from the global profile value. Click the reset button to revert."]
            self.overrideStar:Show()
            self.overrideResetBtn:Show()
        else
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
        end

        -- Format global value for display
        local globalDisplay
        if type(globalValue) == "boolean" then
            globalDisplay = globalValue and L["Yes"] or L["No"]
        elseif type(globalValue) == "number" then
            if globalValue == math.floor(globalValue) then
                globalDisplay = tostring(globalValue)
            else
                globalDisplay = string.format("%.2f", globalValue)
            end
        elseif type(globalValue) == "table" then
            -- Color table
            if globalValue.r then
                globalDisplay = L["Color"]
            else
                globalDisplay = "..."
            end
        elseif type(globalValue) == "string" and self.overrideOptionsMap and self.overrideOptionsMap[globalValue] then
            local mapped = self.overrideOptionsMap[globalValue]
            if type(mapped) == "table" then
                globalDisplay = mapped.text or mapped.label or globalValue
            else
                globalDisplay = tostring(mapped)
            end
        else
            globalDisplay = tostring(globalValue or L["None"])
        end

        -- Show global value inline with label
        self.overrideGlobalText:SetText(string.format(L["(Global: %s)"], globalDisplay))
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
        GUI:ShowTooltip(self, { title = L["Reset to Global Order"] })
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
            GUI:ShowTooltip(s, { title = s.tooltipText, lines = s.tooltipSubText and { s.tooltipSubText } or nil })
        end
    end)
    starBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    container.overrideStar = starBtn

    -- "Modified" text to the left of star
    local modifiedText = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    modifiedText:SetPoint("RIGHT", starIcon, "LEFT", -2, 0)
    modifiedText:SetText(L["Modified"])
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
            self.overrideStar.tooltipText = L["Overridden in this layout"]
            self.overrideStar.tooltipSubText = L["This setting differs from the global profile value. Click the reset button to revert."]
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

-- ============================================================
-- SHARED CHECK / RADIO LOOK — single source of truth
-- Applies the standard square look to a CheckButton: element
-- backdrop + a pixel-snapped, themed WHITE8x8 check. Every box
-- and radio (the full builders below AND the hand-rolled ones
-- elsewhere) should call this, so a restyle is ONE edit.
--   opts.size      box size (default 18)
--   opts.checkSize check-square size (default 10)
--   opts.accent    fixed tint {r,g,b} — e.g. ClickCasting's green.
--                  Omit to follow the party/raid theme (and auto-
--                  register a theme listener on opts.themeRoot).
--   opts.themeRoot frame whose .ThemeListeners drive recolor
--                  (default the button's parent); only used when
--                  no accent is given.
-- Returns the check texture (also stored as cb.Check).
-- ============================================================
function GUI:StyleCheckButton(cb, opts)
    opts = opts or {}
    PixelUtil.SetSize(cb, opts.size or 18, opts.size or 18)
    CreateElementBackdrop(cb)

    local check = cb.Check or cb:CreateTexture(nil, "OVERLAY")
    check:SetTexture("Interface\\Buttons\\WHITE8x8")
    local cs = opts.checkSize or 10
    PixelUtil.SetSize(check, cs, cs)
    PixelUtil.SetPoint(check, "CENTER", cb, "CENTER", 0, 0)

    local accent = opts.accent
    local col = accent or GetThemeColor()
    cb.Check = check
    -- Native checkboxes let WoW show/hide the check via the checked state; a few
    -- consumers (and plain Button-based pseudo-checkboxes) drive it manually via
    -- cb.Check:SetShown(). opts.manualCheck supports those without SetCheckedTexture.
    if opts.manualCheck then
        check:Hide()
    else
        cb:SetCheckedTexture(check)
    end

    -- Hover feedback: a subtle accent wash on the native HIGHLIGHT layer. WoW
    -- shows it on mouseover automatically, so it works regardless of any OnEnter
    -- the consumer sets (no clobbering), and it doesn't recolor the 1px border
    -- (which can render unevenly at fractional UI scales).
    local hl = cb:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\Buttons\\WHITE8x8")
    hl:SetAllPoints(cb)
    cb.Highlight = hl

    -- Single source for the themed tint: check colour + hover-wash strength.
    -- Consumers that drive their own theme refresh call cb.ApplyThemeColor(c) too,
    -- so the wash alpha (0.35) is defined in exactly one place.
    cb.ApplyThemeColor = function(c)
        check:SetVertexColor(c.r, c.g, c.b)
        hl:SetVertexColor(c.r, c.g, c.b, 0.35)
    end
    cb.ApplyThemeColor(col)

    if not accent then
        cb.UpdateTheme = function()
            cb.ApplyThemeColor(GetThemeColor())
        end
        local root = opts.themeRoot or cb:GetParent()
        if root then
            root.ThemeListeners = root.ThemeListeners or {}
            table.insert(root.ThemeListeners, cb)
        end
    end
    return check
end

function GUI:CreateCheckbox(parent, label, dbTable, dbKey, callback, customGet, customSet, overrideKey)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(220, 24)

    local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
    cb:SetPoint("LEFT", 0, 0)
    -- Box + themed check come from the shared styler (single source of truth).
    GUI:StyleCheckButton(cb, { themeRoot = parent })

    -- Label
    local txt = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    txt:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    txt:SetText(label)
    txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    container.label = txt  -- exposed so callers can re-font / anchor a subtitle

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
        AddOverrideIndicators(container, txt, effectiveOverrideKey, onReset, nil, nil, dbTable)
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
        -- Dim the whole widget (box + check fill + label) so a disabled CHECKED
        -- box greys too: native SetEnabled has no DisabledCheckedTexture, so the
        -- accent check would otherwise stay full-bright.
        self:SetAlpha(enabled and 1 or 0.4)
        cb:SetEnabled(enabled)
        if enabled then
            txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            txt:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end

    -- Tooltip support: show container.tooltip on hover
    container:EnableMouse(true)
    container:SetScript("OnEnter", function(self)
        if self.tooltip then
            GUI:ShowTooltip(self, { title = label, anchor = "ANCHOR_CURSOR", lines = { self.tooltip } })
        end
    end)
    container:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdateState()
    
    -- SEARCH: Register this setting
    if DF.Search then
        local hasCustomGetSet = (customGet ~= nil or customSet ~= nil)
        if dbKey and type(dbKey) == "string" then
            container.searchEntry = DF.Search:RegisterCheckbox(label, dbKey, nil, false, callback)
        elseif hasCustomGetSet then
            container.searchEntry = DF.Search:RegisterCheckbox(label, nil, nil, true, callback)
        end
    end
    
    return container
end

-- ============================================================
-- TOGGLE SWITCH
-- A two-state toggle for mutually exclusive options. Two labels
-- flank a pill-shaped track with a sliding thumb. The active
-- label is bright, the inactive label is dimmed.
--
-- API: GUI:CreateToggleSwitch(parent, labelA, labelB, dbTable,
--        dbKey, valueA, valueB, callback)
--   labelA / labelB : display text for each state
--   valueA / valueB : the db values those states map to
-- ============================================================
function GUI:CreateToggleSwitch(parent, labelA, labelB, dbTable, dbKey, valueA, valueB, callback)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 24)

    -- Left label
    local txtA = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    txtA:SetPoint("LEFT", 0, 0)
    txtA:SetText(labelA)

    -- Track (pill shape, fixed width)
    local trackWidth, trackHeight = 36, 18
    local track = CreateFrame("Frame", nil, container, "BackdropTemplate")
    track:SetSize(trackWidth, trackHeight)
    track:SetPoint("LEFT", txtA, "RIGHT", 8, 0)

    -- Right label (anchored to track)
    local txtB = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    txtB:SetPoint("LEFT", track, "RIGHT", 8, 0)
    txtB:SetText(labelB)
    track:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    track:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    track:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 1)

    -- Thumb
    local thumbSize = trackHeight - 4
    local thumb = track:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(thumbSize, thumbSize)
    thumb:SetTexture("Interface\\Buttons\\WHITE8x8")

    -- Fill highlight spanning the full track interior
    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetTexture("Interface\\Buttons\\WHITE8x8")
    fill:SetPoint("TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMRIGHT", -2, 2)

    -- Override indicator support
    local effectiveOverrideKey = dbKey
    if effectiveOverrideKey and type(effectiveOverrideKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(effectiveOverrideKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(effectiveOverrideKey)
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
        AddOverrideIndicators(container, txtB, effectiveOverrideKey, onReset, nil, nil, dbTable)
    end

    -- Visual refresh
    local function UpdateVisuals()
        local val
        if dbTable and dbKey then val = dbTable[dbKey] end
        local isB = (val == valueB)

        local tc = GetThemeColor()
        thumb:ClearAllPoints()
        if isB then
            thumb:SetPoint("RIGHT", track, "RIGHT", -2, 0)
        else
            thumb:SetPoint("LEFT", track, "LEFT", 2, 0)
        end

        thumb:SetVertexColor(tc.r, tc.g, tc.b, 1)
        fill:SetVertexColor(tc.r, tc.g, tc.b, 0.25)

        -- Label colors
        if isB then
            txtA:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            txtB:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            txtA:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            txtB:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end

        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(val)
        end
    end

    -- Click handler (shared by track and both labels)
    local function Toggle()
        local current = dbTable and dbKey and dbTable[dbKey]
        local newVal = (current == valueB) and valueA or valueB

        -- Runtime override protection
        if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
           and DF.AutoProfilesUI:HandleRuntimeWrite(effectiveOverrideKey, newVal) then
            if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(newVal) end
            return
        end

        if dbTable and dbKey then dbTable[dbKey] = newVal end

        -- Profile editing
        if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and effectiveOverrideKey then
            DF.AutoProfilesUI:SetProfileSetting(effectiveOverrideKey, newVal)
        end

        UpdateVisuals()

        if callback then callback() end
        if parent.RefreshStates then parent:RefreshStates() end
        DF:UpdateAll()
    end

    track:EnableMouse(true)
    track:SetScript("OnMouseUp", function() Toggle() end)
    txtA:SetParent(container)
    txtB:SetParent(container)
    -- Make labels clickable via the container
    container:EnableMouse(true)
    container:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then Toggle() end
    end)

    -- Theme support
    track.UpdateTheme = function()
        UpdateVisuals()
    end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, track)

    container:SetScript("OnShow", UpdateVisuals)

    -- Tooltip support
    container:SetScript("OnEnter", function(self)
        if self.tooltip then
            GUI:ShowTooltip(self, { title = labelA .. " / " .. labelB, anchor = "ANCHOR_CURSOR", lines = { self.tooltip } })
        end
        -- Hover highlight on track
        track:SetBackdropBorderColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
    end)
    container:SetScript("OnLeave", function()
        GameTooltip:Hide()
        track:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 1)
    end)

    -- Enable/disable
    container.SetEnabled = function(self, enabled)
        track:EnableMouse(enabled)
        self:EnableMouse(enabled)
        if enabled then
            UpdateVisuals()
        else
            txtA:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            txtB:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            thumb:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.5)
            fill:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.1)
        end
    end

    -- Search registration
    if DF.Search and dbKey and type(dbKey) == "string" then
        container.searchEntry = DF.Search:RegisterCheckbox(labelA .. " / " .. labelB, dbKey, nil, false, callback)
    end

    UpdateVisuals()
    return container
end

-- ============================================================
-- DEBUG CATEGORY ROW
-- A wide row with checkbox + bold category name + description.
-- The whole row is clickable, hover shows a background highlight,
-- and the description is also surfaced as a tooltip on hover so it
-- remains accessible even if it gets visually truncated.
--
-- Used by the Debug > Categories sub-tab. The categoryKey writes
-- directly to DandersFramesDB_v2.debug.filters.
-- ============================================================
function GUI:CreateDebugCategoryRow(parent, categoryKey, description, width)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width or 520, 28)
    row:EnableMouse(true)

    -- Hover background
    row.hoverBg = row:CreateTexture(nil, "BACKGROUND")
    row.hoverBg:SetAllPoints()
    row.hoverBg:SetColorTexture(1, 1, 1, 0.05)
    row.hoverBg:Hide()

    -- Checkbox
    local cb = CreateFrame("CheckButton", nil, row, "BackdropTemplate")
    cb:SetPoint("LEFT", 4, 0)
    GUI:StyleCheckButton(cb, { size = 16, checkSize = 9, themeRoot = parent })
    cb:EnableMouse(false)  -- forward clicks to the row

    -- Category name (bold, full opacity)
    local nameTxt = row:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    nameTxt:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    nameTxt:SetWidth(86)
    nameTxt:SetJustifyH("LEFT")
    nameTxt:SetText(categoryKey)
    nameTxt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- Description (dim, fills remaining space, wraps if too long)
    if description and description ~= "" then
        local descTxt = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        descTxt:SetPoint("LEFT", nameTxt, "RIGHT", 12, 0)
        descTxt:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        descTxt:SetJustifyH("LEFT")
        descTxt:SetText(description)
        descTxt:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        row.descTxt = descTxt
    end

    -- State helpers — read/write filters[categoryKey]
    -- Absent or true = logged, explicit false = not logged
    row.RefreshState = function()
        local filters = DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug.filters
        local checked = (not filters) or filters[categoryKey] ~= false
        cb:SetChecked(checked)
    end

    local function ToggleState()
        local filters = DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug.filters
        if not filters then return end
        -- Toggle: false -> true, anything else -> false
        if filters[categoryKey] == false then
            filters[categoryKey] = true
        else
            filters[categoryKey] = false
        end
        row.RefreshState()
        if DF.DebugConsole then DF.DebugConsole:RefreshDisplay() end
    end

    row:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then ToggleState() end
    end)

    row:SetScript("OnEnter", function(self)
        self.hoverBg:Show()
        if description and description ~= "" then
            GUI:ShowTooltip(self, { title = categoryKey, lines = { description } })
        end
    end)
    row:SetScript("OnLeave", function(self)
        self.hoverBg:Hide()
        GameTooltip:Hide()
    end)

    row:SetScript("OnShow", row.RefreshState)
    row.RefreshState()

    return row
end

-- StyleEditBox: normalize a bare (label-less) EditBox to the standard input
-- chrome used by CreateInput/CreateEditBox — translucent-black fill + dim border
-- + standard font/insets. The caller still owns size/position/scripts. Pass
-- opts.skipFont to keep a custom font (e.g. multi-line / monospace inputs).
function GUI:StyleEditBox(eb, opts)
    opts = opts or {}
    if not eb.SetBackdrop then Mixin(eb, BackdropTemplateMixin) end
    eb:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    eb:SetBackdropColor(0, 0, 0, 0.5)
    eb:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    if not opts.skipFont then
        eb:SetFontObject(DFFontHighlightSmall)
        eb:SetTextInsets(5, 5, opts.multiline and 5 or 0, opts.multiline and 5 or 0)
    end
    -- Multiline mode: for text areas (export/import blobs, macro bodies). The
    -- caller owns the ScrollFrame/sizing; this just flags the editbox + relaxes
    -- the vertical insets. Enter inserts a newline (no auto clear-focus).
    if opts.multiline then
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
    end
    return eb
end

function GUI:CreateInput(parent, label, width)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 180, 44)
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
    editbox:SetFontObject(DFFontHighlightSmall)
    editbox:SetTextInsets(5, 5, 0, 0)
    editbox:SetAutoFocus(false)
    editbox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editbox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- Grey-when-disabled parity with CreateEditBox (cheap insurance if ever placed
    -- in a gated group): dim the whole widget + block editing.
    frame.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1 or 0.4)
        editbox:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end

    frame.EditBox = editbox
    return frame
end

-- CreateEditBox: Text input with db binding (for settings like custom text)
function GUI:CreateEditBox(parent, label, dbTable, dbKey, callback, width, placeholder)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 180, 44)
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
        AddOverrideIndicators(frame, lbl, dbKey, onReset, 6, nil, dbTable)
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
    editbox:SetFontObject(DFFontHighlightSmall)
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
    
    -- Optional placeholder: greyed example text shown while the box is empty
    -- and unfocused. Purely cosmetic — never written to the db.
    if placeholder and placeholder ~= "" then
        local ph = editbox:CreateFontString(nil, "ARTWORK", "DFFontHighlightSmall")
        ph:SetPoint("LEFT", 5, 0)
        ph:SetPoint("RIGHT", -5, 0)
        ph:SetJustifyH("LEFT")
        ph:SetText(placeholder)
        ph:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.55)
        local function UpdatePlaceholder()
            ph:SetShown(not editbox:HasFocus() and editbox:GetText() == "")
        end
        editbox.UpdatePlaceholder = UpdatePlaceholder
        editbox:HookScript("OnTextChanged", UpdatePlaceholder)
        editbox:HookScript("OnEditFocusGained", UpdatePlaceholder)
        editbox:HookScript("OnEditFocusLost", UpdatePlaceholder)
        UpdatePlaceholder()
    end

    -- Refresh override indicators on show
    frame:SetScript("OnShow", function()
        if dbTable and dbKey then
            editbox:SetText(dbTable[dbKey] or "")
        end
        if frame.UpdateOverrideIndicators then
            frame:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
        end
        if editbox.UpdatePlaceholder then editbox.UpdatePlaceholder() end
    end)

    -- Grey-when-disabled: the grey loop (RefreshChildStates) calls widget:SetEnabled,
    -- but this frame had none, so a disabled group left the input full-bright AND
    -- editable. Dim the whole widget + block editing, matching the other helpers.
    frame.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1 or 0.4)
        editbox:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end

    frame.EditBox = editbox
    return frame
end

-- customGet / customSet (optional, matches CreateDropdown's pattern): when
-- provided, the slider routes its reads and writes through these functions
-- instead of dbTable[dbKey] directly. Used by widgets whose underlying value
-- lives inside a nested table (e.g. Border Alpha → <prefix>BorderColor.a),
-- where the plain `dbTable[dbKey] = v` path can't express the nesting.
-- Consumers that pass customSet typically pass dbKey = nil so the
-- auto-profile override system doesn't track a key that doesn't exist at the
-- top level of dbTable.
-- accentColor (optional {r,g,b}): fixed thumb/fill colour instead of the mode
-- theme — for ClickCasting (green) / Search (blue) which keep their identity.
function GUI:CreateSlider(parent, label, minVal, maxVal, step, dbTable, dbKey, callback, lightweightUpdate, usePreviewMode, customGet, customSet, accentColor)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)
    
    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
        AddOverrideIndicators(container, lbl, dbKey, onReset, 6, nil, dbTable)
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
    local c = accentColor or GetThemeColor()
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
    input:SetFontObject(DFFontHighlightSmall)
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
        -- Grey the numeric value box too: it was only EnableMouse'd (clicks blocked
        -- but still full-bright + typeable), so it stayed lit while the track dimmed.
        input:EnableMouse(enabled)
        input:SetEnabled(enabled)
        input:SetAlpha(enabled and 1 or 0.4)
        local tc = accentColor or GetThemeColor()
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
        local nc = accentColor or GetThemeColor()
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
    
    -- Wrapper for both pathways: customGet/Set when provided, dbTable[dbKey]
    -- otherwise. Centralising this avoids a sprinkling of `if customGet then`
    -- across every place the slider touches its value.
    local function ReadValue()
        if customGet then return customGet() end
        if dbTable then return dbTable[dbKey] end
        return nil
    end
    local function WriteValue(v)
        if customSet then return customSet(v) end
        if dbTable then dbTable[dbKey] = v end
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
            local funcName = lightweightUpdate and ((dbKey or label or "slider") .. " lightweight") or nil
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
        local v = ReadValue()
        if v ~= nil then UpdateValue(v) end
    end)

    slider:SetScript("OnValueChanged", function(self, value)
        if suppressCallback then return end
        if not (dbTable or customSet) then return end
        if step >= 1 then
            value = math.floor(value + 0.5)
        else
            value = math.floor(value / step + 0.5) * step
        end

        -- Runtime override protection: redirect to baseline, skip refresh
        if dbKey and GUI.SelectedMode == "raid" and DF.AutoProfilesUI
           and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, value) then
            if not input:HasFocus() then input:SetText(FormatValue(value)) end
            UpdateFill()
            if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(value) end
            return
        end

        WriteValue(value)

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
            if dbKey and GUI.SelectedMode == "raid" and DF.AutoProfilesUI
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

            WriteValue(val)
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
            local v = ReadValue(); if v ~= nil then UpdateValue(v) end
        end
        self:ClearFocus()
    end)

    input:SetScript("OnEscapePressed", function(self)
        local v = ReadValue(); if v ~= nil then UpdateValue(v) end
        self:ClearFocus()
    end)

    local initial = ReadValue()
    if initial ~= nil then UpdateValue(initial) end
    
    -- SEARCH: Register this setting with slider metadata
    if DF.Search and dbKey and type(dbKey) == "string" then
        container.searchEntry = DF.Search:RegisterSlider(label, dbKey, minVal, maxVal, step, nil, callback)
    end
    
    -- Expose label for dynamic updates
    container.label = lbl

    return container
end

-- Dual-handle range slider: two draggable handles select a [lo, hi] sub-range of
-- [minRange, maxRange]. Self-contained — the caller anchors the returned track
-- frame and reads values via :GetValues() / the onChange callback. Drag is
-- tracked on the track's own OnUpdate (no dependence on parent scripts), and a
-- mouse-button check releases the drag even if the cursor leaves the handle.
-- opts:
--   width(336), accent({r,g,b}=theme), minRange, maxRange, lo, hi,
--   scaleLabels({...} optional tick labels), scaleMin/scaleMax (label scale,
--   default minRange/maxRange — lets ticks stay on a fixed scale while the
--   handle range changes), display(FontString updated each change),
--   formatRange(fn(lo,hi)->str), formatOne(fn(v)->str),
--   onChange(fn(lo,hi) — fired on user-driven changes only, not SetValues).
-- Methods on the returned frame: :SetRange(min,max), :SetValues(lo,hi),
-- :GetValues()->lo,hi.
function GUI:CreateRangeSlider(parent, opts)
    opts = opts or {}
    local width = opts.width or 336
    local accent = opts.accent or GetThemeColor()

    local track = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    track:SetSize(width, 12)
    track:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    track:SetBackdropColor(0.03, 0.03, 0.03, 1)
    track:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)

    track.minRange = opts.minRange or 1
    track.maxRange = opts.maxRange or 40
    track.lo = opts.lo or track.minRange
    track.hi = opts.hi or track.maxRange

    local rangeFill = track:CreateTexture(nil, "ARTWORK")
    rangeFill:SetTexture("Interface\\Buttons\\WHITE8x8")
    rangeFill:SetVertexColor(accent.r, accent.g, accent.b, 0.5)
    rangeFill:SetHeight(10)
    rangeFill:SetPoint("TOP", 0, -1)

    local function MakeHandle()
        local h = CreateFrame("Button", nil, track)
        h:SetSize(8, 16)
        h:EnableMouse(true)
        local tex = h:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetTexture("Interface\\Buttons\\WHITE8x8")
        tex:SetVertexColor(accent.r, accent.g, accent.b, 1)
        return h
    end
    local minHandle, maxHandle = MakeHandle(), MakeHandle()
    track.minHandle, track.maxHandle = minHandle, maxHandle

    local function ValueToPos(value)
        local pct = (value - track.minRange) / (track.maxRange - track.minRange)
        return pct * (width - 4) + 2
    end
    local function PosToValue(pos)
        local pct = (pos - 2) / (width - 4)
        return math.floor(pct * (track.maxRange - track.minRange) + track.minRange + 0.5)
    end

    local function Redraw()
        local minPos, maxPos = ValueToPos(track.lo), ValueToPos(track.hi)
        minHandle:ClearAllPoints()
        minHandle:SetPoint("CENTER", track, "LEFT", minPos, 0)
        maxHandle:ClearAllPoints()
        maxHandle:SetPoint("CENTER", track, "LEFT", maxPos, 0)
        rangeFill:ClearAllPoints()
        rangeFill:SetPoint("LEFT", track, "LEFT", minPos, 0)
        rangeFill:SetWidth(math.max(maxPos - minPos, 2))
        if opts.display then
            if track.lo == track.hi then
                opts.display:SetText(opts.formatOne and opts.formatOne(track.lo) or tostring(track.lo))
            else
                opts.display:SetText(opts.formatRange and opts.formatRange(track.lo, track.hi)
                    or (track.lo .. " - " .. track.hi))
            end
        end
    end

    local dragging = nil
    local function ApplyCursor()
        local x = select(1, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local trackLeft = track:GetLeft()
        if not trackLeft then return end
        local pos = math.max(2, math.min(x - trackLeft, width - 2))
        local value = math.max(track.minRange, math.min(PosToValue(pos), track.maxRange))
        if dragging == "min" then
            if value <= track.hi then track.lo = value end
        elseif dragging == "max" then
            if value >= track.lo then track.hi = value end
        end
        Redraw()
        if opts.onChange then opts.onChange(track.lo, track.hi) end
    end

    minHandle:SetScript("OnMouseDown", function(_, b) if b == "LeftButton" then dragging = "min" end end)
    maxHandle:SetScript("OnMouseDown", function(_, b) if b == "LeftButton" then dragging = "max" end end)
    track:SetScript("OnUpdate", function()
        if not dragging then return end
        if not IsMouseButtonDown("LeftButton") then dragging = nil; return end
        ApplyCursor()
    end)

    track:EnableMouse(true)
    track:SetScript("OnMouseDown", function(_, b)
        if b ~= "LeftButton" then return end
        local x = select(1, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local trackLeft = track:GetLeft()
        if not trackLeft then return end
        local value = PosToValue(x - trackLeft)
        if math.abs(value - track.lo) <= math.abs(value - track.hi) then
            if value <= track.hi then track.lo = math.max(track.minRange, value) end
        else
            if value >= track.lo then track.hi = math.min(track.maxRange, value) end
        end
        Redraw()
        if opts.onChange then opts.onChange(track.lo, track.hi) end
    end)

    if opts.scaleLabels then
        local sMin = opts.scaleMin or track.minRange
        local sMax = opts.scaleMax or track.maxRange
        for _, num in ipairs(opts.scaleLabels) do
            local pct = (num - sMin) / (sMax - sMin)
            local xPos = pct * (width - 4) + 2
            local lbl = track:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            lbl:SetText(num)
            lbl:SetTextColor(0.35, 0.35, 0.35)
            lbl:SetPoint("TOP", track, "BOTTOM", xPos - width / 2, -2)
        end
    end

    function track:SetRange(minR, maxR)
        self.minRange, self.maxRange = minR, maxR
        self.lo = math.max(minR, math.min(self.lo, maxR))
        self.hi = math.max(minR, math.min(self.hi, maxR))
        Redraw()
    end
    function track:SetValues(lo, hi)
        self.lo = math.max(self.minRange, math.min(lo, self.maxRange))
        self.hi = math.max(self.minRange, math.min(hi, self.maxRange))
        Redraw()
    end
    function track:GetValues() return self.lo, self.hi end

    Redraw()
    return track
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
    local txt = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
        AddOverrideIndicators(container, txt, dbKey, onReset, nil, nil, dbTable)
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
        
        -- Attach default colour so the picker can offer a Default button
        -- dbTable.__dfDefaults is set by callers (e.g. Aura Designer proxies) that
        -- store their defaults outside DF.PartyDefaults / DF.RaidDefaults. Read via
        -- rawget so proxies' __index doesn't see this lookup as a regular setting.
        local defaultVal = (dbTable and rawget(dbTable, "__dfDefaults") and dbTable.__dfDefaults[dbKey])
                        or (DF.PartyDefaults and DF.PartyDefaults[dbKey])
                        or (DF.RaidDefaults  and DF.RaidDefaults[dbKey])
        -- Fallback: power bar colours use WoW's PowerBarColor table as their default
        if not defaultVal and PowerBarColor and dbKey then
            defaultVal = PowerBarColor[dbKey]
        end
        if defaultVal and type(defaultVal) == "table" and defaultVal.r then
            info.dfDefaultColor = {r = defaultVal.r or 1, g = defaultVal.g or 1, b = defaultVal.b or 1, a = defaultVal.a or 1}
            -- Populate ElvUI's "Default" button (ColorPPDefault) so it enables and
            -- pastes the DF setting default when the native Blizzard picker is shown
            local elvDefault = _G["ColorPPDefault"]
            if elvDefault then
                elvDefault.colors = info.dfDefaultColor
            end
        end

        -- Mark this as a DandersFrames color picker call
        GUI:MarkColorPickerCall()
        ColorPickerFrame:SetupColorPickerAndShow(info)
    end)
    
    container.SetEnabled = function(self, enabled)
        -- Dim the whole widget so the colour swatch greys even when it's a dark
        -- colour (SetDesaturated alone is invisible on near-black swatches).
        self:SetAlpha(enabled and 1 or 0.4)
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
        container.searchEntry = DF.Search:RegisterColorPicker(label, dbKey, hasAlpha, nil, callback)
    end
    
    return container
end

function GUI:CreateDropdown(parent, label, options, dbTable, dbKey, callback, customGet, customSet, opts)
    opts = opts or {}
    local accentColor = opts.accent
    local optionsFunc = opts.optionsFunc

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, opts.inline and 24 or 50)

    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    -- Expose label so helpers like AddSectionNewBadge can anchor a badge to it.
    container.label = lbl
    if opts.inline then
        lbl:Hide()
    end
    
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
        AddOverrideIndicators(container, lbl, dbKey, onReset, 6, options, dbTable)
    end

    -- Button - use relative anchoring so it resizes with container
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    if opts.inline then
        -- Fill the container so the caller's SetSize(w, h) controls the opener
        -- size + vertical centering (inline callers add their own left label and
        -- size the container to match the surrounding row, e.g. 140x18 / 110x16).
        btn:SetAllPoints(container)
    else
        btn:SetPoint("TOPLEFT", 0, -16)
        btn:SetPoint("TOPRIGHT", 0, -16)
        btn:SetHeight(24)
    end
    CreateElementBackdrop(btn)

    btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
        if customGet or (dbTable and dbKey) then
            local val = customGet and customGet() or dbTable[dbKey]
            local displayVal = options[val]
            -- Handle table format: {value = X, text = "text"} or {text = "text"}
            if type(displayVal) == "table" then
                displayVal = displayVal.text or displayVal.label or tostring(val)
            end
            btn.Text:SetText(displayVal or tostring(val) or L["Select..."])
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

    -- Build (or rebuild) the menu buttons from the current `options` upvalue.
    -- Hide + drop any previously-built buttons first so dynamic dropdowns can
    -- regenerate their list. Static callers call this exactly once below.
    local menuContentW = 0   -- widest item text; sizes the menu to fit long options
    local function BuildMenuButtons()
        for _, b in ipairs(menuButtons) do b:Hide() end
        wipe(menuButtons)
        wipe(sortedOptions)
        menuHeight = 0

        -- Check for custom order array
        if options._order then
            -- Use specified order
            for _, k in ipairs(options._order) do
                local v = options[k]
                if v then
                    -- Handle both formats: KEY = "text" or KEY = {value=, text=, color=}
                    local displayValue = type(v) == "table" and (v.text or v.label or tostring(k)) or v
                    local optColor = type(v) == "table" and v.color or nil
                    table.insert(sortedOptions, {key = k, value = displayValue, color = optColor})
                end
            end
        else
            -- Default: sort alphabetically by display value
            for k, v in pairs(options) do
                -- Handle both formats: KEY = "text" or KEY = {value = X, text = "text", color =}
                local displayValue = type(v) == "table" and (v.text or v.label or tostring(k)) or v
                local optColor = type(v) == "table" and v.color or nil
                table.insert(sortedOptions, {key = k, value = displayValue, color = optColor})
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

            menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            menuBtn.Text:SetPoint("LEFT", 8, 0)
            menuBtn.Text:SetText(opt.value)
            if opt.color then
                menuBtn.Text:SetTextColor(opt.color.r, opt.color.g, opt.color.b)
            else
                menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end

            menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
            menuBtn.Highlight:SetAllPoints()
            local c = accentColor or GetThemeColor()
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

                if customSet then
                    customSet(opt.key)
                else
                    dbTable[dbKey] = opt.key
                end

                -- If editing a profile, also set the override
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                    DF.AutoProfilesUI:SetProfileSetting(dbKey, customGet and customGet() or opt.key)
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

        -- Width fits the widest item so long options aren't clipped by a narrow
        -- opener (refined to max(opener, content) on open, once btn is sized).
        menuContentW = 0
        for _, mb in ipairs(menuButtons) do
            menuContentW = math.max(menuContentW, mb.Text:GetStringWidth() or 0)
        end
        menuFrame:SetWidth(menuContentW + 24)
        menuFrame:SetHeight(menuHeight + 4)
    end

    BuildMenuButtons()

    -- Allow dynamic dropdowns to swap their option set and regenerate buttons.
    container.RebuildOptions = function(_, newOptions)
        if newOptions then options = newOptions end
        BuildMenuButtons()
        UpdateText()
    end

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
            -- Dynamic dropdowns regenerate their option list each open.
            if optionsFunc then container:RebuildOptions(optionsFunc()) end
            local currentVal = customGet and customGet() or dbTable[dbKey]
            local selColor = accentColor or GetThemeColor()
            for i, menuBtn in ipairs(menuButtons) do
                local opt = sortedOptions[i]
                if opt.color then
                    -- per-option colour (e.g. class-coloured spec list) always wins
                    menuBtn.Text:SetTextColor(opt.color.r, opt.color.g, opt.color.b)
                elseif currentVal == opt.key then
                    menuBtn.Text:SetTextColor(selColor.r, selColor.g, selColor.b)
                else
                    menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                end
            end
            menuFrame:SetWidth(math.max(btn:GetWidth() or 0, menuContentW + 24))
            menuFrame:Show()
            currentOpenDropdown = menuFrame
        end
    end)
    
    btn:SetScript("OnShow", UpdateText)
    UpdateText()
    
    container.SetEnabled = function(self, enabled)
        -- Dim the whole widget so its preview/value (texture swatch, font preview,
        -- selected text) greys with the label rather than staying full-bright.
        self:SetAlpha(enabled and 1 or 0.4)
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
        container.searchEntry = DF.Search:RegisterDropdown(label, dbKey, options, nil, callback)
    end

    return container
end

-- ============================================================
-- OUTLINE + SHADOW CONTROLS
-- A flag dropdown and a shadow checkbox that both bind to a single stored
-- outline value (see DF:OutlineFlag / OutlineHasShadow / ComposeOutline in
-- Config.lua). Shadow is decoupled from the outline flag so any flag can be
-- combined with a drop shadow, mirroring Grid2's font options.
-- ============================================================

local OUTLINE_FLAG_ORDER = { "NONE", "OUTLINE", "THICKOUTLINE", "MONOCHROME", "MONOCHROME, OUTLINE", "MONOCHROME, THICKOUTLINE" }

function GUI:CreateOutlineDropdown(parent, label, dbTable, dbKey, callback, inheritKey)
    local options = {
        NONE = L["None"],
        OUTLINE = L["Outline"],
        THICKOUTLINE = L["Thick Outline"],
        MONOCHROME = L["Monochrome"],
        ["MONOCHROME, OUTLINE"] = L["Monochrome Outline"],
        ["MONOCHROME, THICKOUTLINE"] = L["Monochrome Thick Outline"],
        _order = OUTLINE_FLAG_ORDER,
    }
    local get = function() return DF:OutlineFlag(dbTable[dbKey] or (inheritKey and dbTable[inheritKey])) end
    local set = function(flag) dbTable[dbKey] = DF:ComposeOutline(flag, DF:OutlineHasShadow(dbTable[dbKey] or (inheritKey and dbTable[inheritKey]))) end
    return GUI:CreateDropdown(parent, label or L["Outline"], options, dbTable, dbKey, callback, get, set)
end

function GUI:CreateShadowCheckbox(parent, label, dbTable, dbKey, callback)
    local get = function() return DF:OutlineHasShadow(dbTable[dbKey]) end
    local set = function(val) dbTable[dbKey] = DF:ComposeOutline(DF:OutlineFlag(dbTable[dbKey]), val) end
    return GUI:CreateCheckbox(parent, label or L["Shadow"], dbTable, dbKey, callback, get, set)
end

-- ============================================================
-- UNIFIED BORDER CONTROL SET
-- Drops the canonical Show / Style / Texture / Size / Colour controls plus
-- whichever optional Phase B controls the consumer opts into (offset, inset,
-- blendMode, gradient, shadow). Saved-variable keys are built from a single
-- camelCase `prefix` (e.g. "defensiveIcon" → "defensiveIconBorderSize"), so
-- consumers add one call instead of hand-rolling ~6-15 widgets each.
--
-- Each opts.include flag is per-element: "tailor-made to what makes logical
-- sense" — the API exposes everything, but consumers opt in only to what fits
-- their element. Returns a table of widget references so the caller can add
-- per-element extras (dispel-type colour, pulsate, etc.) afterwards.
--
-- opts = {
--   parent       = the panel widget (e.g. self.child) — same first arg the
--                  underlying CreateCheckbox/Slider/etc. take
--   include      = { offset=, inset=, blendMode=, gradient=, shadow=,
--                    classColor=, roleColor=, colorByTime=, colorByType= }
--   fullUpdate   = callback for full re-render (drop / value-set)
--   lightUpdate  = callback for slider-drag (size, offsets, shadow sliders)
--   lightColors  = callback for live colour-picker preview
--   refreshStates = optional hook fired when Show/Gradient/Shadow toggles
--                   change visibility of other widgets
--   hideWhen     = optional predicate fn(db) → bool. When true, EVERY widget
--                  (including the Show toggle itself) hides — used by
--                  consumers whose border section sits inside a parent panel
--                  with its own enable toggle (e.g. defensiveIconEnabled).
--   sizeMin / sizeMax / sizeStep      = slider range overrides
--   offsetMin / offsetMax / offsetStep
-- }
-- ============================================================
-- CreateAnimationControls — the Border Animation control set
-- (Type dropdown + every per-effect tunable), extracted so the base
-- Border Animation panel (CreateBorderControls / include.animate) AND
-- Aura Designer's Expiring Animation override render an IDENTICAL set of
-- widgets from ONE source. Add or remove an effect / tunable here and both
-- panels update together — no drift.
--
--   group       = SettingsGroup the widgets are added to
--   dbTable     = db / proxy the widgets read & write
--   animPrefix  = key namespace; widgets target dbTable[animPrefix .. suffix]
--                 (base border: "<prefix>BorderAnimation"; AD expiring:
--                 "ExpiringAnimation")
-- opts:
--   parent        = frame parent for the widgets
--   fullUpdate    = heavy refresh callback (dropdown / slider-release / colour)
--   lightUpdate   = light refresh callback (slider-drag)
--   lightColors   = live colour-picker preview callback (needed for AD's
--                   proxy, whose sub-table colour writes skip __newindex)
--   typeLabel     = label for the Type dropdown
--   hideExtra     = optional predicate; when true the WHOLE block hides
--                   (the border panel folds the block under Show Border;
--                   the always-visible Expiring override omits it)
--   onTypeChange  = runs after the Type dropdown changes (re-layout / reflow)
--   perfBanner    = show the per-border FPS warning banner (default true)
-- Returns the widget table (animationType, animationColor, … ) so the caller
-- can merge the handles into its own control table.
-- ============================================================
function GUI:CreateAnimationControls(group, dbTable, animPrefix, opts)
    opts = opts or {}
    local parent       = opts.parent
    local fullUpdate   = opts.fullUpdate or function() end
    local lightUpdate  = opts.lightUpdate
    local lightColors  = opts.lightColors
    local typeLabel    = opts.typeLabel or L["Border Animation"]
    local hideExtra    = opts.hideExtra
    local onTypeChange = opts.onTypeChange or function() end
    local showPerfBanner = opts.perfBanner ~= false

    local function aKey(suffix) return animPrefix .. suffix end
    local animTypeKey = aKey("Type")
    local function animType() return dbTable[animTypeKey] or "NONE" end
    local function extraOff() return (hideExtra and hideExtra()) or false end
    local function animOff()  return extraOff() or animType() == "NONE" end

    -- Sets of effect types each tunable applies to (truthiness on a
    -- string-keyed set). Mirrors the per-effect parameter map — keep in
    -- sync with StartAnimation's branches in Frames/Border.lua.
    -- DF_DASH: Frequency = march SPEED (0 = static dashed), Thickness = dash
    -- thickness, Inset = dash inset.
    local hasFrequency = { PULSATE=1, DF_PULSATE=1, CHASE=1, FLASH=1, PROC=1,
                           WIPE=1, RIPPLE=1, SEGMENT_REVEAL=1, DF_DASH=1 }
    local hasParticles = { PULSATE=1, CHASE=1 }
    local hasThickness = { PULSATE=1, WIPE=1, RIPPLE=1, SEGMENT_REVEAL=1,
                           SIDES_ONLY=1, CORNERS_ONLY=1, DF_DASH=1 }
    -- Inset / Offset apply to every non-NONE effect EXCEPT DF_PULSATE (which
    -- modulates the border's own edges and has no separate animRect).
    local hasPositioning = { PULSATE=1, CHASE=1, FLASH=1, PROC=1, WIPE=1, RIPPLE=1,
                             SEGMENT_REVEAL=1, SIDES_ONLY=1, CORNERS_ONLY=1, DF_DASH=1 }
    local pulsateOnly  = { PULSATE=1 }
    local chaseOnly    = { CHASE=1 }
    local sidesOnly    = { SIDES_ONLY=1 }
    local cornersOnly  = { CORNERS_ONLY=1 }
    local function hideUnless(set)
        return function()
            if animOff() then return true end
            return not set[animType()]
        end
    end

    local w = {}

    -- DF_PULSATE sits next to PULSATE so users compare them at a glance —
    -- both "pulse" effects, but the LCG one renders a particle ring outside
    -- the border while DF Pulsate fades the border's own edge alpha.
    w.animationType = group:AddWidget(GUI:CreateDropdown(parent, typeLabel,
        {
            NONE = L["None"],
            PULSATE = L["Pulsate"],
            DF_PULSATE = L["DF Pulsate"],
            CHASE = L["Chase"],
            FLASH = L["Flash"],
            PROC = L["Proc"],
            WIPE = L["Wipe"],
            RIPPLE = L["Ripple"],
            SEGMENT_REVEAL = L["Segment Reveal"],
            SIDES_ONLY = L["Sides Only"],
            CORNERS_ONLY = L["Corners Only"],
            DF_DASH = L["DF Dash"],
            -- None first (the "off" option), then alphabetical by label.
            _order = { "NONE", "CHASE", "CORNERS_ONLY", "DF_DASH", "DF_PULSATE",
                       "FLASH", "PROC", "PULSATE", "RIPPLE", "SEGMENT_REVEAL",
                       "SIDES_ONLY", "WIPE" },
        },
        dbTable, animTypeKey, onTypeChange), 55)
    -- Type dropdown respects only the extra gate (e.g. Show Border). With no
    -- extra gate (Expiring override) it's always visible.
    w.animationType.hideOn = hideExtra or function() return false end

    -- Perf warning: animations run an OnUpdate (or LCG internal animation)
    -- per active border, which adds up in 20-30 player raids.
    if showPerfBanner then
        local perfBanner = GUI:CreateInfoBanner(parent, {
            tone = "caution",
            text = L["Animations run per-border and may impact FPS in larger raids. Use sparingly on high-priority alerts."],
            staticHeight = true,
            minHeight    = 56,
        })
        w.animationPerfBanner = group:AddWidget(perfBanner, perfBanner.layoutHeight)
        w.animationPerfBanner.hideOn = animOff
    end

    -- Animation colour applies to every effect except DF_PULSATE (which
    -- modulates the border's own edge alpha — no separate colour). lightColors
    -- is threaded through so AD's proxy gets live preview while dragging.
    w.animationColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Animation Color"],
        dbTable, aKey("Color"), true, fullUpdate, lightColors, lightColors ~= nil), 35)
    w.animationColor.hideOn = function()
        return animOff() or animType() == "DF_PULSATE"
    end

    -- Min 0: DF_DASH reads Frequency as march speed, so 0 = static dashed.
    -- The LCG glows treat 0 as their default rate (clamped in StartAnimation),
    -- and the OnUpdate effects fall back to a sensible default period at 0.
    w.animationFrequency = group:AddWidget(GUI:CreateSlider(parent, L["Animation Frequency"],
        0, 4, 0.05, dbTable, aKey("Frequency"),
        fullUpdate, lightUpdate, true), 55)
    w.animationFrequency.hideOn = hideUnless(hasFrequency)

    w.animationParticles = group:AddWidget(GUI:CreateSlider(parent, L["Animation Particles"],
        1, 16, 1, dbTable, aKey("Particles"),
        fullUpdate, lightUpdate, true), 55)
    w.animationParticles.hideOn = hideUnless(hasParticles)

    w.animationLength = group:AddWidget(GUI:CreateSlider(parent, L["Animation Length"],
        1, 30, 1, dbTable, aKey("Length"),
        fullUpdate, lightUpdate, true), 55)
    w.animationLength.hideOn = hideUnless(pulsateOnly)

    w.animationThickness = group:AddWidget(GUI:CreateSlider(parent, L["Animation Thickness"],
        1, 12, 1, dbTable, aKey("Thickness"),
        fullUpdate, lightUpdate, true), 55)
    w.animationThickness.hideOn = hideUnless(hasThickness)

    w.animationScale = group:AddWidget(GUI:CreateSlider(parent, L["Animation Scale"],
        0.5, 3, 0.05, dbTable, aKey("Scale"),
        fullUpdate, lightUpdate, true), 55)
    w.animationScale.hideOn = hideUnless(chaseOnly)

    w.animationInset = group:AddWidget(GUI:CreateSlider(parent, L["Animation Inset"],
        -50, 50, 1, dbTable, aKey("Inset"),
        fullUpdate, lightUpdate, true), 55)
    w.animationInset.hideOn = hideUnless(hasPositioning)

    w.animationOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Animation Offset X"],
        -50, 50, 1, dbTable, aKey("OffsetX"),
        fullUpdate, lightUpdate, true), 55)
    w.animationOffsetX.hideOn = hideUnless(hasPositioning)

    w.animationOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Animation Offset Y"],
        -50, 50, 1, dbTable, aKey("OffsetY"),
        fullUpdate, lightUpdate, true), 55)
    w.animationOffsetY.hideOn = hideUnless(hasPositioning)

    w.animationMask = group:AddWidget(GUI:CreateCheckbox(parent, L["Pulsate Backing Frame"],
        dbTable, aKey("Mask"), fullUpdate), 30)
    w.animationMask.hideOn = hideUnless(pulsateOnly)

    -- PROC only: opt in to the one-shot "proc start" flash (off by default —
    -- see ProcGlow_Start in Frames/Border.lua for why it's not on for a
    -- continuous border animation).
    w.animationProcStart = group:AddWidget(GUI:CreateCheckbox(parent, L["Proc Start Flash"],
        dbTable, aKey("ProcStart"), fullUpdate), 30)
    w.animationProcStart.hideOn = hideUnless({ PROC = 1 })

    w.animationSidesAxis = group:AddWidget(GUI:CreateDropdown(parent, L["Sides Axis"],
        { HORIZONTAL = L["Horizontal"], VERTICAL = L["Vertical"] },
        dbTable, aKey("SidesAxis"), fullUpdate), 55)
    w.animationSidesAxis.hideOn = hideUnless(sidesOnly)

    w.animationCornerLength = group:AddWidget(GUI:CreateSlider(parent, L["Corner Length"],
        2, 40, 1, dbTable, aKey("CornerLength"),
        fullUpdate, lightUpdate, true), 55)
    w.animationCornerLength.hideOn = hideUnless(cornersOnly)

    return w
end

-- ============================================================
function GUI:CreateBorderControls(group, dbTable, prefix, opts)
    opts = opts or {}
    local parent       = opts.parent
    local include      = opts.include or {}
    local fullUpdate   = opts.fullUpdate or function() end
    local lightUpdate  = opts.lightUpdate
    local lightColors  = opts.lightColors
    local refreshStates = opts.refreshStates
    local hideWhen     = opts.hideWhen

    local sizeMin, sizeMax, sizeStep = opts.sizeMin or 0, opts.sizeMax or 8, opts.sizeStep or 1
    local offMin, offMax, offStep    = opts.offsetMin or -50, opts.offsetMax or 50, opts.offsetStep or 1

    local function key(suffix) return prefix .. suffix end
    local showKey = key("ShowBorder")
    -- The Show toggle only respects the parent-level hideWhen. Everything
    -- else respects hideWhen OR the Show toggle being off.
    --
    -- hideOn predicates IGNORE the table arg LayoutChildren passes (which is
    -- always `DF.db[GUI.SelectedMode]`) and read from the captured `dbTable`
    -- instead.  For consumers whose dbTable == DF.db[mode] (Frame Border,
    -- Defensive Icon, etc.) the two are identical so behaviour is unchanged.
    -- For consumers with a different dbTable — notably Aura Designer's
    -- per-aura proxy — this is the only way the visibility predicates see
    -- the actual border state (e.g. proxy.BorderStyle, not the unrelated
    -- DF.db.party.BorderStyle which doesn't exist).
    local function hideShow() return hideWhen and hideWhen(dbTable) or false end
    -- Show Border OFF no longer HIDES the border controls — they stay visible and
    -- GREY OUT (disableOn = borderOff, applied by the loop at the end of this
    -- function) so the panel previews them. `hideOff` now means "hidden by the
    -- parent/variant gate only" (whatever the consumer passes via hideWhen); the
    -- name is kept so the existing `.hideOn = hideOff` references read unchanged.
    local function hideOff()  return hideShow() end
    local function borderOff() return dbTable[showKey] == false end

    local w = {}

    -- opts.noShowToggle: suppress the built-in "Show Border" checkbox for
    -- consumers that gate the whole border on an external toggle (e.g. the
    -- Targeted Spells "Highlight Important Spells" master). With the checkbox
    -- gone, showKey stays nil so hideOff() reduces to hideShow() — the toolkit
    -- shows/hides purely on the external hideWhen.
    if not opts.noShowToggle then
        w.show = group:AddWidget(GUI:CreateCheckbox(parent, L["Show Border"], dbTable, showKey, function()
            if refreshStates then refreshStates() end
            fullUpdate()
        end), 30)
        w.show.hideOn = hideShow
    end

    -- Slider label reads "Border Thickness" (more meaningful than "Size") but
    -- the underlying db key stays `<prefix>BorderSize` and spec.size in the
    -- backend stays the same — purely a user-facing rename, no migration.
    w.size = group:AddWidget(GUI:CreateSlider(parent, L["Border Thickness"], sizeMin, sizeMax, sizeStep,
        dbTable, key("BorderSize"), fullUpdate, lightUpdate, true), 55)
    w.size.hideOn = hideOff

    -- Gradient is a STYLE, not a separate toggle. When the consumer opts into
    -- gradient via include.gradient, we expose GRADIENT as a third dropdown
    -- option. Otherwise the dropdown is the original SOLID / TEXTURE pair.
    local styleOptions = { SOLID = L["Solid"], TEXTURE = L["Texture"],
        _order = { "SOLID", "TEXTURE" } }
    if include.gradient then
        styleOptions.GRADIENT = L["Gradient"]
        -- Insert GRADIENT between SOLID and TEXTURE so the order reads
        -- "simple colour → two colours → custom texture" in the dropdown.
        styleOptions._order = { "SOLID", "GRADIENT", "TEXTURE" }
    end
    w.style = group:AddWidget(GUI:CreateDropdown(parent, L["Border Style"],
        styleOptions, dbTable, key("BorderStyle"), function()
            -- Match the frame border: pick the first LSM border when switching
            -- to Texture without one configured.
            if dbTable[key("BorderStyle")] == "TEXTURE" then
                local list = DF.GetBorderList and DF:GetBorderList() or nil
                local t = dbTable[key("BorderTexture")]
                if list and (not t or t == "" or t == "SOLID") then
                    dbTable[key("BorderTexture")] = next(list)
                end
            end
            if refreshStates then refreshStates() end
            fullUpdate()
        end), 55)
    w.style.hideOn = hideOff

    -- isGradient is declared up here so the Style-dependent widget cluster
    -- (Texture under TEXTURE style, gradient pickers under GRADIENT style)
    -- can sit immediately below the Style dropdown — the consequence of the
    -- user's style choice reads top-to-bottom without scrolling past
    -- unrelated inset / offset / blend controls first.
    local function isGradient() return dbTable[key("BorderStyle")] == "GRADIENT" end

    w.texture = group:AddWidget(GUI:CreateDropdown(parent, L["Border Texture"],
        DF:GetBorderList(), dbTable, key("BorderTexture"), fullUpdate), 55)
    w.texture.hideOn = function()
        return hideOff() or dbTable[key("BorderStyle")] ~= "TEXTURE"
    end

    -- Gradient pickers — only visible under Style = GRADIENT.  Grouped here
    -- (between Texture and the Colour Source dropdown) so all style-dependent
    -- widgets sit directly under the Style dropdown that controls them.
    -- The standalone "Border Gradient" checkbox was removed when Style
    -- absorbed it; Style is now the single source of truth so it's not
    -- possible to pick "Solid + Class Color" then have a Gradient checkbox
    -- stomp the class colour (the previous UX bug).  Legacy
    -- `<prefix>BorderGradientEnabled = true` profiles are migrated to
    -- `<prefix>BorderStyle = "GRADIENT"` on db load.
    if include.gradient then
        local function gradHide() return hideOff() or not isGradient() end

        w.gradientStart = group:AddWidget(GUI:CreateColorPicker(parent, L["Gradient Start Color"],
            dbTable, key("BorderGradientStartColor"), true, fullUpdate), 35)
        w.gradientStart.hideOn = gradHide
        w.gradientEnd = group:AddWidget(GUI:CreateColorPicker(parent, L["Gradient End Color"],
            dbTable, key("BorderGradientEndColor"), true, fullUpdate), 35)
        w.gradientEnd.hideOn = gradHide
        w.gradientDirection = group:AddWidget(GUI:CreateDropdown(parent, L["Gradient Direction"],
            { HORIZONTAL = L["Horizontal"], VERTICAL = L["Vertical"] },
            dbTable, key("BorderGradientDirection"), fullUpdate), 55)
        w.gradientDirection.hideOn = gradHide
    end

    -- Colour Source dropdown sits ABOVE the colour picker so the relationship
    -- "source → resulting colour" reads top-to-bottom in the panel. The
    -- options table is built dynamically: Static is always present; Class
    -- and Role are added if the consumer opted in via the matching include.
    -- Hidden in GRADIENT style — gradient owns its own colours, no resolver
    -- chain applies (see Border:BuildSpec).
    local sourceKey = key("BorderColorSource")
    local hasSourceDropdown = include.classColor or include.roleColor
    if hasSourceDropdown then
        local sourceOptions = { STATIC = L["Static"], _order = { "STATIC" } }
        if include.classColor then
            sourceOptions.CLASS = L["Class"]
            sourceOptions._order[#sourceOptions._order + 1] = "CLASS"
        end
        if include.roleColor then
            sourceOptions.ROLE = L["Role"]
            sourceOptions._order[#sourceOptions._order + 1] = "ROLE"
        end
        -- Default the source from the legacy boolean keys when first opened.
        if dbTable[sourceKey] == nil then
            if dbTable[key("BorderUseClassColor")]     then dbTable[sourceKey] = "CLASS"
            elseif dbTable[key("BorderUseRoleColor")]  then dbTable[sourceKey] = "ROLE"
            else                                            dbTable[sourceKey] = "STATIC" end
        end
        w.colorSource = group:AddWidget(GUI:CreateDropdown(parent, L["Border Color Source"],
            sourceOptions, dbTable, sourceKey, function()
                if refreshStates then refreshStates() end
                fullUpdate()
            end), 55)
        w.colorSource.hideOn = function() return hideOff() or isGradient() end
    end

    -- Static colour picker — only visible when source is STATIC (or when the
    -- consumer didn't enable any resolver at all, so source doesn't exist).
    -- Hidden in GRADIENT style (gradient uses its own start/end pickers).
    w.color = group:AddWidget(GUI:CreateColorPicker(parent, L["Border Color"], dbTable, key("BorderColor"),
        true, fullUpdate, lightColors, lightColors ~= nil), 35)
    w.color.hideOn = function()
        if hideOff() or isGradient() then return true end
        if hasSourceDropdown then
            local src = dbTable[sourceKey] or "STATIC"
            return src ~= "STATIC"
        end
        return false
    end

    -- Unified Border Alpha slider — opt-in via include.alpha. Reads / writes
    -- the SAME alpha component the colour picker exposes
    -- (<prefix>BorderColor.a), so the slider is just a convenient handle for
    -- the picker's alpha bar — no separate alpha key to migrate or keep in
    -- sync. Visible in STATIC / CLASS / ROLE; hidden in GRADIENT (where the
    -- two gradient pickers each carry their own alpha, and a single slider
    -- has no obvious meaning).
    if include.alpha then
        -- Ensure the underlying colour table has an alpha component so the
        -- slider doesn't read nil on first open. The picker also seeds .a but
        -- we don't depend on widget-creation order.
        local c = dbTable[key("BorderColor")]
        if type(c) ~= "table" then
            c = { r = 0, g = 0, b = 0, a = 1 }
            dbTable[key("BorderColor")] = c
        end
        if c.a == nil then c.a = 1 end

        w.alpha = group:AddWidget(GUI:CreateSlider(parent, L["Border Alpha"], 0, 1, 0.05,
            nil, nil, fullUpdate, lightColors or lightUpdate, true,
            function() return dbTable[key("BorderColor")].a or 1 end,
            function(v)  dbTable[key("BorderColor")].a = v end), 55)
        w.alpha.hideOn = function() return hideOff() or isGradient() end
    end

    if include.inset then
        w.inset = group:AddWidget(GUI:CreateSlider(parent, L["Border Inset"], -20, 20, 1,
            dbTable, key("BorderInset"), fullUpdate, lightUpdate, true), 55)
        w.inset.hideOn = hideOff
    end

    if include.offset then
        w.offsetX = group:AddWidget(GUI:CreateSlider(parent, L["Border Offset X"], offMin, offMax, offStep,
            dbTable, key("BorderOffsetX"), fullUpdate, lightUpdate, true), 55)
        w.offsetX.hideOn = hideOff
        w.offsetY = group:AddWidget(GUI:CreateSlider(parent, L["Border Offset Y"], offMin, offMax, offStep,
            dbTable, key("BorderOffsetY"), fullUpdate, lightUpdate, true), 55)
        w.offsetY.hideOn = hideOff
    end

    if include.blendMode then
        w.blendMode = group:AddWidget(GUI:CreateDropdown(parent, L["Border Blend Mode"],
            { BLEND = L["Blend"], ADD = L["Add"], MOD = L["Modulate"], DISABLE = L["Disable"] },
            dbTable, key("BorderBlendMode"), fullUpdate), 55)
        w.blendMode.hideOn = hideOff
    end

    if include.shadow then
        local shadowOnKey = key("BorderShadowEnabled")
        w.shadowEnabled = group:AddWidget(GUI:CreateCheckbox(parent, L["Border Shadow"], dbTable, shadowOnKey, function()
            if refreshStates then refreshStates() end
            fullUpdate()
        end), 30)
        w.shadowEnabled.hideOn = hideOff
        -- Border Shadow OFF greys (not hides) its sub-controls — a nested boolean
        -- toggle, same grey-everything rule. The end-of-function loop OR-composes
        -- borderOff, so these also grey when Show Border is off.
        local function shadowOff() return dbTable[shadowOnKey] == false end

        w.shadowColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Shadow Color"],
            dbTable, key("BorderShadowColor"), true, fullUpdate), 35)
        w.shadowColor.hideOn = hideOff
        w.shadowColor.disableOn = shadowOff
        w.shadowSize = group:AddWidget(GUI:CreateSlider(parent, L["Shadow Size"], 0, 10, 1,
            dbTable, key("BorderShadowSize"), fullUpdate, lightUpdate, true), 55)
        w.shadowSize.hideOn = hideOff
        w.shadowSize.disableOn = shadowOff
        w.shadowOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Shadow Offset X"], -10, 10, 1,
            dbTable, key("BorderShadowOffsetX"), fullUpdate, lightUpdate, true), 55)
        w.shadowOffsetX.hideOn = hideOff
        w.shadowOffsetX.disableOn = shadowOff
        w.shadowOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Shadow Offset Y"], -10, 10, 1,
            dbTable, key("BorderShadowOffsetY"), fullUpdate, lightUpdate, true), 55)
        w.shadowOffsetY.hideOn = hideOff
        w.shadowOffsetY.disableOn = shadowOff
    end

    -- ===== Animation (Stage 3) =====
    -- include.animate drops the full Border Animation control set (Type
    -- dropdown + per-effect tunables, each with a hideOn keyed to the effect
    -- it applies to). Built from the shared GUI:CreateAnimationControls so the
    -- base panel and AD's Expiring override never drift. The whole block folds
    -- under Show Border via hideExtra = hideOff. Widget handles are merged back
    -- onto `w` so existing references (w.animationType, …) are preserved.
    if include.animate then
        local aw = GUI:CreateAnimationControls(group, dbTable, key("BorderAnimation"), {
            parent       = parent,
            fullUpdate   = fullUpdate,
            lightUpdate  = lightUpdate,
            lightColors  = lightColors,
            typeLabel    = L["Border Animation"],
            hideExtra    = hideOff,
            onTypeChange = function()
                if refreshStates then refreshStates() end
                fullUpdate()
            end,
        })
        for k, v in pairs(aw) do w[k] = v end
    end

    -- ===== Colour resolver toggles (Stage 2) =====
    -- These flip BorderColor's source from the static picker to a per-unit /
    -- per-aura / per-tick computation. BuildSpec applies them in priority
    -- order (type > time > class > role > static) when the consumer passes
    -- ctx to BuildSpec. The static colour picker still controls the fallback
    -- (when ctx is missing or the resolver yields nil).

    -- (Colour Source dropdown + Static colour picker + Alpha slider are wired
    -- earlier, above the inset/offset/blendMode/gradient/shadow block, so the
    -- relationship "source → colour" reads top-to-bottom in the panel.)

    if include.colorByTime then
        w.colorByTime = group:AddWidget(GUI:CreateCheckbox(parent, L["Color by Time Remaining"], dbTable, key("BorderColorByTime"), fullUpdate), 30)
        w.colorByTime.hideOn = hideOff
        -- The actual colour curve picker is consumer-specific (e.g. AD's
        -- existing expiring colour curve) and is added by the consumer
        -- alongside this checkbox.
    end

    if include.colorByType then
        w.colorByType = group:AddWidget(GUI:CreateCheckbox(parent, L["Color by Aura Type"], dbTable, key("BorderColorByType"), fullUpdate), 30)
        w.colorByType.hideOn = hideOff
    end

    -- Grey (don't hide) every border control when "Show Border" is OFF, so the panel
    -- still previews the controls. Composes with each control's own disableOn (e.g.
    -- the shadow sub-controls) and leaves the variant/parent hideOn untouched. Skips
    -- the "Show Border" checkbox itself so it stays clickable. RefreshChildStates
    -- applies disableOn to group children, and CreateCheckbox auto-refreshes on
    -- toggle, so the grey updates live.
    for k, widget in pairs(w) do
        if k ~= "show" and type(widget) == "table" and widget.SetEnabled then
            local prev = widget.disableOn
            widget.disableOn = function(d) return borderOff() or (prev and prev(d)) end
        end
    end

    return w
end

-- ============================================================
-- EXPIRING CONTROLS (shared) — the Aura Designer expiring panel is the
-- reference design; this helper reproduces it EXACTLY (master enable →
-- Percent/Seconds toggle threshold → State Overrides → thickness / colour /
-- alpha / animation → optional extras) so EVERY expiring consumer (AD
-- icon/square/bar AND the standard buff aura icons) renders the same flow and
-- look.  Per-consumer differences are `include.*` flags + an explicit `keys`
-- map (expiring DB key names diverge: AD uses `expiring*`/`Expiring*` on a
-- proxy, buff uses `buffExpiring*`), so a row simply HIDES when it doesn't apply
-- to that consumer — never a separate hand-built panel.
-- ============================================================

-- Small dim inline subheader (section divider inside a SettingsGroup), matching
-- AD's "State Overrides" / "Icon Effects" dividers.
function GUI:CreateExpiringSubheader(parent, text)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(18)
    local label = frame:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(label, 8, "")
    label:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 2, 1)
    label:SetText(text)
    local c = GetThemeColor()
    label:SetTextColor(c.r, c.g, c.b, 0.75)
    return frame
end

-- Threshold slider + a compact Percent/Seconds TOGGLE BUTTON (AD's design).
-- The slider's label/range switch with the mode, so the row rebuilds the page
-- on toggle via opts.refreshPage.  Keys are parameterised (thresholdKey /
-- thresholdModeKey) so any consumer's DB schema works.
function GUI:CreateExpiringThresholdRow(parent, dbTable, opts)
    opts = opts or {}
    local tKey = opts.thresholdKey
    local mKey = opts.thresholdModeKey
    local refresh = opts.refreshPage or function() end
    local width = opts.width or 248
    local isSeconds = mKey and dbTable[mKey] == "SECONDS"

    local container = CreateFrame("Frame", nil, parent)
    container:SetHeight(54)
    container:SetWidth(width)

    local label, minV, maxV, step
    if isSeconds then
        label = L["Expiring Threshold (seconds)"]
        minV, maxV, step = 1, 60, 1
        if tKey and dbTable[tKey] and dbTable[tKey] > 60 then dbTable[tKey] = 10 end
    else
        label = L["Expiring Threshold (%)"]
        minV, maxV, step = 5, 100, 5
        if tKey and dbTable[tKey] and dbTable[tKey] < 5 then dbTable[tKey] = 30 end
    end

    local slider = GUI:CreateSlider(container, label, minV, maxV, step, dbTable, tKey)
    slider:SetPoint("TOPLEFT", 0, 0)
    slider:SetWidth(width)

    local modeBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    modeBtn:SetPoint("BOTTOMRIGHT", slider, "TOPRIGHT", -10, 2)
    GUI:StyleButton(modeBtn, {
        width = 56, height = 18,
        text = isSeconds and L["Seconds"] or L["Percent"],
    })
    GUI:SetSettingsFont(modeBtn.Text, 9, "")
    modeBtn:SetActive(isSeconds)

    modeBtn:HookScript("OnEnter", function(self)
        GUI:ShowTooltip(self, {
            title = L["Threshold Mode"],
            lines = { isSeconds and L["Currently: Seconds. Click for Percent."] or L["Currently: Percent. Click for Seconds."] },
        })
    end)
    modeBtn:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    modeBtn:SetScript("OnClick", function()
        if not mKey then return end
        if dbTable[mKey] == "SECONDS" then
            dbTable[mKey] = "PERCENT"
            if tKey then dbTable[tKey] = 30 end
        else
            dbTable[mKey] = "SECONDS"
            if tKey then dbTable[tKey] = 10 end
        end
        refresh()
    end)

    -- Composite row: forward grey-out (disableOn) to its slider + mode button so the
    -- whole row dims when the expiring feature is off. Dim the row uniformly via
    -- SetAlpha and block interaction with slider:SetEnabled + modeBtn:EnableMouse —
    -- NOT modeBtn:SetDisabled (which fights the hover wash) nor native
    -- modeBtn:SetEnabled alone (blocks clicks but leaves the custom backdrop/label
    -- full-brightness, so the toggle wouldn't visually grey with its row).
    container.SetEnabled = function(_, enabled)
        container:SetAlpha(enabled and 1 or 0.4)
        if slider.SetEnabled then slider:SetEnabled(enabled) end
        modeBtn:EnableMouse(enabled)
    end

    return container
end

-- The full shared expiring panel.  opts:
--   parent, fullUpdate, lightColors, lightGeometry, refreshStates, refreshPage,
--   width, masterLabel, colorLabel,
--   keys = { master, threshold, thresholdMode, borderEnable, colorByTime,
--            colorOverride, color, borderColor, alphaHandleColor, thickness,
--            inset, animPrefix, tintEnable, tintColor,
--            fillPulsate, wholeAlpha, bounce },
--   include = { threshold, borderEnable, colorByTime, colorOverride, alpha,
--               dualColor, thickness, thicknessMin, thicknessMax, inset,
--               animation, tint, iconEffects = {fillPulsate,wholeAlpha,bounce} }
function GUI:CreateExpiringControls(group, dbTable, opts)
    opts = opts or {}
    local parent        = opts.parent
    local K             = opts.keys or {}
    local inc           = opts.include or {}
    local fullUpdate    = opts.fullUpdate or function() end
    local lightColors   = opts.lightColors
    local lightGeometry = opts.lightGeometry
    local refreshStates = opts.refreshStates or function() end
    local refreshPage   = opts.refreshPage or function() end

    local w = {}

    -- Master gate (whole feature off) and the border-row gate (master off OR a
    -- separate Show-Expiring-Border toggle off, when the consumer has one).
    local function masterOff()
        return (K.master and dbTable[K.master] == false) or false
    end
    local function borderOff()
        if masterOff() then return true end
        if K.borderEnable and dbTable[K.borderEnable] == false then return true end
        return false
    end
    -- GREY (not hide) rows that don't apply, so the panel previews them. The gate
    -- (masterOff / borderOff — both boolean enables) drives disableOn; refreshStates
    -- + RefreshChildStates re-apply on toggle. Labels/subheaders have no SetEnabled
    -- so they stay full-color (fine).
    local function addGated(widget, h, gate)
        widget.disableOn = gate or masterOff
        return group:AddWidget(widget, h)
    end

    if K.master then
        w.master = group:AddWidget(GUI:CreateCheckbox(parent, opts.masterLabel or L["Enable Expiring"], dbTable, K.master, function()
            -- Reflow (collapse/expand the gated rows) + repaint; no full page
            -- rebuild — only the threshold-mode toggle needs refreshPage.
            refreshStates(); fullUpdate()
        end), 30)
    end

    if inc.threshold ~= false and K.threshold then
        addGated(GUI:CreateExpiringThresholdRow(parent, dbTable, {
            thresholdKey = K.threshold, thresholdModeKey = K.thresholdMode,
            width = opts.width,
            refreshPage = function() refreshStates(); refreshPage() end,
        }), 54)
    end

    -- Consumer hook for an extra row directly under the threshold (e.g. AD bar's
    -- duration-priority row).  Receives addGated(widget, height[, gate]).
    if opts.afterThreshold then opts.afterThreshold(addGated, masterOff) end

    if inc.borderEnable and K.borderEnable then
        w.borderEnable = group:AddWidget(GUI:CreateCheckbox(parent, L["Show Expiring Border"], dbTable, K.borderEnable, function()
            refreshStates(); fullUpdate()
        end), 30)
        w.borderEnable.disableOn = masterOff
    end

    addGated(GUI:CreateExpiringSubheader(parent, L["State Overrides"]), 18, borderOff)

    if inc.thickness ~= false and K.thickness then
        addGated(GUI:CreateSlider(parent, L["Expiring Border Thickness"],
            inc.thicknessMin or 0, inc.thicknessMax or 5, 1,
            dbTable, K.thickness, fullUpdate, lightGeometry, true), 55, borderOff)
    end

    if inc.inset and K.inset then
        addGated(GUI:CreateSlider(parent, L["Expiring Border Inset"],
            -3, 3, 1, dbTable, K.inset, fullUpdate, lightGeometry, true), 55, borderOff)
    end

    if inc.colorByTime and K.colorByTime then
        w.colorByTime = addGated(GUI:CreateCheckbox(parent, L["Color by Time Remaining"], dbTable, K.colorByTime, function()
            refreshStates(); fullUpdate()
        end), 30, borderOff)
    end

    if inc.colorOverride and K.colorOverride then
        addGated(GUI:CreateCheckbox(parent, L["Expiring Color Override"], dbTable, K.colorOverride, fullUpdate), 30, borderOff)
    end

    if K.color then
        -- Single-colour consumers (icon / bar / buff) label it "Expiring Border
        -- Color" to match the square's border picker; the square's dual case adds
        -- a separate "Expiring Fill Color" above it.
        local label = opts.colorLabel or (inc.dualColor and L["Expiring Fill Color"] or L["Expiring Border Color"])
        local cp = GUI:CreateColorPicker(parent, label, dbTable, K.color, true, fullUpdate, lightColors, lightColors ~= nil)
        -- Greyed when the border is off; HIDDEN only when (buff) Color-by-Time owns
        -- the colour (a variant — the time curve replaces this static picker).
        cp.disableOn = borderOff
        cp.hideOn = function()
            return (K.colorByTime and dbTable[K.colorByTime]) and true or false
        end
        group:AddWidget(cp, 35)
        w.color = cp
    end

    if inc.dualColor and K.borderColor then
        addGated(GUI:CreateColorPicker(parent, L["Expiring Border Color"], dbTable, K.borderColor, true, fullUpdate, lightColors, lightColors ~= nil), 35, borderOff)
    end

    if inc.alpha then
        local alphaKey = K.alphaHandleColor or K.color
        addGated(GUI:CreateSlider(parent, L["Expiring Border Alpha"], 0, 1, 0.05, nil, nil, fullUpdate, lightColors, true,
            function() local c = dbTable[alphaKey]; return (c and (c.a or c[4])) or 1 end,
            function(v) local c = dbTable[alphaKey]; if type(c) == "table" then c.a = v end end), 55, borderOff)
    end

    if inc.animation ~= false and K.animPrefix then
        local aw = GUI:CreateAnimationControls(group, dbTable, K.animPrefix, {
            parent      = parent,
            fullUpdate  = fullUpdate,
            lightUpdate = lightGeometry,
            lightColors = lightColors,
            typeLabel   = L["Expiring Animation"],
            perfBanner  = true,
            -- No hideExtra gate: animation rows stay visible and GREY when the
            -- expiring border is off (post-loop below); only their per-type variant
            -- gating (internal to CreateAnimationControls) still hides.
            onTypeChange = function() refreshStates() end,
        })
        for k, v in pairs(aw) do
            w[k] = v
            if type(v) == "table" and v.SetEnabled then
                local prev = v.disableOn
                v.disableOn = function(d) return borderOff() or (prev and prev(d)) end
            end
        end
    end

    -- "Expiring Effects" — whole-element responses to the aura crossing its
    -- threshold (anim effects + Tint), under ONE shared subheader so every
    -- consumer reads the same.  Rows appear per consumer via include flags.
    local fx = inc.iconEffects
    local hasTint = inc.tint and K.tintEnable
    if fx or hasTint then
        addGated(GUI:CreateExpiringSubheader(parent, L["Expiring Effects"]), 18)
    end
    if fx then
        if fx.fillPulsate and K.fillPulsate then addGated(GUI:CreateCheckbox(parent, L["Pulsate"], dbTable, K.fillPulsate, fullUpdate), 30) end
        if fx.wholeAlpha and K.wholeAlpha then addGated(GUI:CreateCheckbox(parent, L["Whole Alpha Pulse"], dbTable, K.wholeAlpha, fullUpdate), 30) end
        if fx.bounce and K.bounce then addGated(GUI:CreateCheckbox(parent, L["Bounce"], dbTable, K.bounce, fullUpdate), 30) end
    end
    if hasTint then
        -- Toggling tint must reflow the section so the Tint Color picker's hideOn
        -- re-evaluates (else the picker only appears after a full page rebuild).
        addGated(GUI:CreateCheckbox(parent, L["Show Expiring Tint"], dbTable, K.tintEnable, function()
            refreshStates(); fullUpdate()
        end), 30)
        if K.tintColor then
            local lightTint = opts.lightTint
            local tc = GUI:CreateColorPicker(parent, L["Tint Color"], dbTable, K.tintColor, true, fullUpdate, lightTint, lightTint ~= nil)
            tc.disableOn = function() return masterOff() or dbTable[K.tintEnable] == false end
            group:AddWidget(tc, 35)
        end
    end

    return w
end

-- ============================================================
-- GROWTH DIRECTION CONTROL
-- Three linked dropdowns (Orientation, Wrap, Direction) that
-- compose into a single growth value like "LEFT_UP"
-- ============================================================

-- Decompose "LEFT_UP" into {orientation, wrap, direction}
local function DecomposeGrowth(growth)
    local primary, secondary = strsplit("_", growth or "LEFT_UP")
    if not secondary then
        -- Malformed value (no underscore) — fall back to LEFT_UP
        return "HORIZONTAL", "UP", "LEFT"
    end
    if primary == "CENTER" then
        if secondary == "UP" or secondary == "DOWN" then
            return "HORIZONTAL", secondary, "CENTER"
        else
            return "VERTICAL", secondary, "CENTER"
        end
    elseif primary == "LEFT" or primary == "RIGHT" then
        return "HORIZONTAL", secondary, primary
    else
        return "VERTICAL", secondary, primary
    end
end

-- Compose {orientation, wrap, direction} back into "LEFT_UP"
local function ComposeGrowth(orientation, wrap, direction)
    -- Safety: if wrap is nil, pick a sensible default for the orientation
    if not wrap then
        wrap = (orientation == "HORIZONTAL") and "UP" or "LEFT"
    end
    if direction == "CENTER" then
        return "CENTER_" .. wrap
    else
        return direction .. "_" .. (wrap or "UP")
    end
end

-- Map values when switching orientation so the selection stays sensible
local ORIENTATION_MAP = {
    UP = "LEFT", DOWN = "RIGHT", LEFT = "UP", RIGHT = "DOWN",
}

function GUI:CreateGrowthControl(parent, db, dbKey, callback)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 155)

    -- Read current decomposed state
    local curOrientation, curWrap, curDirection = DecomposeGrowth(db[dbKey] or "LEFT_UP")

    -- Option tables per orientation
    -- Display text is localized; the value-keys (HORIZONTAL, UP, …) and _order
    -- arrays are raw identifiers and must NOT be localized.
    local ORIENT_OPTIONS = {
        HORIZONTAL = L["Horizontal"],
        VERTICAL = L["Vertical"],
        _order = {"HORIZONTAL", "VERTICAL"},
    }
    local WRAP_OPTIONS = {
        HORIZONTAL = { UP = L["Up"], DOWN = L["Down"], _order = {"UP", "DOWN"} },
        VERTICAL = { LEFT = L["Left"], RIGHT = L["Right"], _order = {"LEFT", "RIGHT"} },
    }
    local DIR_OPTIONS = {
        HORIZONTAL = { LEFT = L["Left"], CENTER = L["Center"], RIGHT = L["Right"], _order = {"LEFT", "CENTER", "RIGHT"} },
        VERTICAL = { UP = L["Up"], CENTER = L["Center"], DOWN = L["Down"], _order = {"UP", "CENTER", "DOWN"} },
    }

    -- Shared write-back: recompose and save
    local function WriteBack()
        db[dbKey] = ComposeGrowth(curOrientation, curWrap, curDirection)
        DF:UpdateAll()
        if callback then callback() end
        if parent.RefreshStates then parent:RefreshStates() end
    end

    -- Sub-dropdown builder (simplified version of CreateDropdown, no override indicators)
    local function BuildMiniDropdown(yOffset, label, options, getValue, setValue)
        local frame = CreateFrame("Frame", nil, container)
        frame:SetPoint("TOPLEFT", 0, yOffset)
        frame:SetPoint("TOPRIGHT", 0, yOffset)
        frame:SetHeight(50)

        local lbl = frame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        lbl:SetPoint("TOPLEFT", 0, 0)
        lbl:SetText(label)
        lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
        btn:SetPoint("TOPLEFT", 0, -16)
        btn:SetPoint("TOPRIGHT", 0, -16)
        btn:SetHeight(24)
        CreateElementBackdrop(btn)

        btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        btn.Text:SetPoint("LEFT", 8, 0)
        btn.Text:SetPoint("RIGHT", -20, 0)
        btn.Text:SetJustifyH("LEFT")
        btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        local arrow = btn:CreateTexture(nil, "OVERLAY")
        arrow:SetPoint("RIGHT", -8, 0)
        arrow:SetSize(12, 12)
        arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
        arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        local menuFrame = CreateFrame("Frame", nil, btn, "BackdropTemplate")
        menuFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
        menuFrame:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
        menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        menuFrame:SetClampedToScreen(true)
        CreateElementBackdrop(menuFrame)
        menuFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.98)
        menuFrame:Hide()

        menuFrame:SetScript("OnHide", function()
            if currentOpenDropdown == menuFrame then
                currentOpenDropdown = nil
            end
        end)

        local menuButtons = {}

        -- Rebuild populates menu items from current options
        frame.Rebuild = function(self, newOptions)
            for _, mb in ipairs(menuButtons) do mb:Hide() end
            wipe(menuButtons)

            local sorted = {}
            if newOptions._order then
                for _, k in ipairs(newOptions._order) do
                    if newOptions[k] then
                        sorted[#sorted + 1] = { key = k, value = newOptions[k] }
                    end
                end
            else
                for k, v in pairs(newOptions) do
                    if k ~= "_order" then
                        sorted[#sorted + 1] = { key = k, value = v }
                    end
                end
                table.sort(sorted, function(a, b) return a.value < b.value end)
            end

            local menuHeight = 0
            for i, opt in ipairs(sorted) do
                local menuBtn = CreateFrame("Button", nil, menuFrame)
                menuBtn:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 22)
                menuBtn:SetPoint("TOPRIGHT", -2, -2 - (i - 1) * 22)
                menuBtn:SetHeight(22)

                menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                menuBtn.Text:SetPoint("LEFT", 8, 0)
                menuBtn.Text:SetText(opt.value)
                menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
                menuBtn.Highlight:SetAllPoints()
                local c = GetThemeColor()
                menuBtn.Highlight:SetColorTexture(c.r, c.g, c.b, 0.3)

                menuBtn:SetScript("OnClick", function()
                    setValue(opt.key)
                    WriteBack()
                    btn.Text:SetText(opt.value)
                    menuFrame:Hide()
                end)

                menuButtons[#menuButtons + 1] = menuBtn
                menuHeight = menuHeight + 22
            end
            menuFrame:SetHeight(menuHeight + 4)

            -- Update displayed text
            local curVal = getValue()
            btn.Text:SetText(newOptions[curVal] or tostring(curVal) or L["Select..."])
        end

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
                CloseOpenDropdown()
                -- Highlight current selection
                local curVal = getValue()
                local curDisplay = options[curVal]
                for _, mb in ipairs(menuButtons) do
                    if mb.Text:GetText() == curDisplay then
                        mb.Text:SetTextColor(GetThemeColor().r, GetThemeColor().g, GetThemeColor().b)
                    else
                        mb.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                    end
                end
                menuFrame:Show()
                currentOpenDropdown = menuFrame
            end
        end)

        -- Expose btn for external enable/disable
        frame.btn = btn
        frame:Rebuild(options)
        return frame
    end

    -- Build the three dropdowns (forward-declare wrap/dir so orientation callback can reference them)
    local wrapDD, dirDD
    local orientDD = BuildMiniDropdown(0, L["Orientation"], ORIENT_OPTIONS,
        function() return curOrientation end,
        function(val)
            if val ~= curOrientation then
                -- Map wrap and direction to the new orientation
                curWrap = ORIENTATION_MAP[curWrap] or curWrap
                curDirection = (curDirection == "CENTER") and "CENTER" or (ORIENTATION_MAP[curDirection] or curDirection)
                curOrientation = val
                -- Rebuild dependent dropdowns with new options
                wrapDD:Rebuild(WRAP_OPTIONS[curOrientation])
                dirDD:Rebuild(DIR_OPTIONS[curOrientation])
            end
        end
    )

    wrapDD = BuildMiniDropdown(-50, L["Wrap"], WRAP_OPTIONS[curOrientation],
        function() return curWrap end,
        function(val) curWrap = val end
    )

    dirDD = BuildMiniDropdown(-100, L["Direction"], DIR_OPTIONS[curOrientation],
        function() return curDirection end,
        function(val) curDirection = val end
    )

    -- SetEnabled support for disableOn (disable the actual clickable buttons)
    container.SetEnabled = function(self, enabled)
        local alpha = enabled and 1.0 or 0.4
        self:SetAlpha(alpha)
        orientDD.btn:SetEnabled(enabled)
        wrapDD.btn:SetEnabled(enabled)
        dirDD.btn:SetEnabled(enabled)
    end

    -- Refresh from db (e.g., after profile switch)
    container.refreshContent = function(self)
        curOrientation, curWrap, curDirection = DecomposeGrowth(db[dbKey] or "LEFT_UP")
        orientDD:Rebuild(ORIENT_OPTIONS)
        wrapDD:Rebuild(WRAP_OPTIONS[curOrientation])
        dirDD:Rebuild(DIR_OPTIONS[curOrientation])
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
    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
        AddOverrideIndicators(container, lbl, dbKey, onReset, 6, nil, dbTable)
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
    
    btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
            btn.Text:SetText(displayName or L["Select..."])
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
    searchBox:SetFontObject(DFFontHighlightSmall)
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
    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    placeholder:SetPoint("LEFT", 24, 0)
    placeholder:SetText(L["Search textures..."])
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
    local scrollFrame = CreateFrame("ScrollFrame", nil, menuFrame, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 2, -(SEARCH_HEIGHT + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", -20, 2)
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(234)  -- Match button width for texture dropdown
    scrollFrame:SetScrollChild(scrollChild)
    
    StyleScrollBar(scrollFrame)

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
            
            menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
        -- Dim the whole widget so its preview/value (texture swatch, font preview,
        -- selected text) greys with the label rather than staying full-bright.
        self:SetAlpha(enabled and 1 or 0.4)
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
        container.searchEntry = DF.Search:RegisterDropdown(label, dbKey, currentOptions, nil, callback)
    end
    
    return container
end

-- ============================================================
-- FONT DROPDOWN WITH PREVIEW
-- ============================================================

-- inheritKey (optional): when dbTable[dbKey] is nil (no per-element override),
-- the dropdown DISPLAYS dbTable[inheritKey] instead so it shows the inherited
-- (e.g. global) font. Selecting a font still writes dbKey (the override).
function GUI:CreateFontDropdown(parent, label, dbTable, dbKey, callback, inheritKey)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)

    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
        AddOverrideIndicators(container, lbl, dbKey, onReset, 6, nil, dbTable)
    end
    
    -- Button - use relative anchoring so it resizes with container
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    CreateElementBackdrop(btn)
    
    btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
            local val = dbTable[dbKey] or (inheritKey and dbTable[inheritKey])
            -- Get font display name (handles both names and legacy paths)
            local displayName = DF:GetFontNameFromPath(val)
            btn.Text:SetText(displayName or L["Select..."])
            -- Try to set the button text to the selected font for preview
            local fontPath = DF:GetFontPath(val)
            if fontPath then
                local success = pcall(function()
                    btn.Text:SetFont(fontPath, 12, "")
                end)
                if not success then
                    btn.Text:SetFontObject(DFFontHighlightSmall)
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
    searchBox:SetFontObject(DFFontHighlightSmall)
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
    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    placeholder:SetPoint("LEFT", 24, 0)
    placeholder:SetText(L["Search fonts..."])
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
    local scrollFrame = CreateFrame("ScrollFrame", nil, menuFrame, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 2, -(SEARCH_HEIGHT + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", -20, 2)
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(234)  -- Match button width for font dropdown
    scrollFrame:SetScrollChild(scrollChild)
    
    StyleScrollBar(scrollFrame)

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
            menuBtn.Text:SetFontObject(DFFontHighlightSmall)
            
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
        -- Dim the whole widget so its preview/value (texture swatch, font preview,
        -- selected text) greys with the label rather than staying full-bright.
        self:SetAlpha(enabled and 1 or 0.4)
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
        container.searchEntry = DF.Search:RegisterDropdown(label, dbKey, DF:GetFontList(), nil, callback)
    end
    
    return container
end

-- ============================================================
-- SOUND DROPDOWN (Searchable, scrollable — mirrors font dropdown)
-- ============================================================

function GUI:CreateSoundDropdown(parent, label, dbTable, dbKey, callback)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)

    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- Button
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    CreateElementBackdrop(btn)

    btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
            btn.Text:SetText(val or L["Select..."])
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
    searchBox:SetFontObject(DFFontHighlightSmall)
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
    local searchPlaceholder = searchBox:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    searchPlaceholder:SetPoint("LEFT", 24, 0)
    searchPlaceholder:SetText(L["Search sounds..."])
    searchPlaceholder:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)

    searchBox:SetScript("OnEditFocusGained", function() searchPlaceholder:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function()
        if searchBox:GetText() == "" then searchPlaceholder:Show() end
    end)

    menuFrame:SetScript("OnHide", function()
        if currentOpenDropdown == menuFrame then
            currentOpenDropdown = nil
        end
        searchBox:SetText("")
        searchBox:ClearFocus()
        searchPlaceholder:Show()
    end)

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, menuFrame, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 2, -(SEARCH_HEIGHT + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", -20, 2)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(234)
    scrollFrame:SetScrollChild(scrollChild)

    StyleScrollBar(scrollFrame)

    local menuButtons = {}
    local ITEM_HEIGHT = 22
    local MAX_VISIBLE = 10

    local function RebuildMenu(filterText)
        for _, menuBtn in ipairs(menuButtons) do
            menuBtn:Hide()
            menuBtn:SetParent(nil)
        end
        wipe(menuButtons)

        local options = DF:GetSoundList()
        local sortedOptions = {}

        filterText = filterText and filterText:lower() or ""

        for k, v in pairs(options) do
            if filterText == "" or v:lower():find(filterText, 1, true) then
                table.insert(sortedOptions, {key = k, value = v})
            end
        end
        table.sort(sortedOptions, function(a, b) return a.value < b.value end)

        local menuHeight = math.min(#sortedOptions, MAX_VISIBLE) * ITEM_HEIGHT + SEARCH_HEIGHT + 8
        menuFrame:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
        menuFrame:SetHeight(menuHeight)
        scrollChild:SetHeight(#sortedOptions * ITEM_HEIGHT)

        if scrollBar then
            if #sortedOptions <= MAX_VISIBLE then
                scrollBar:Hide()
            else
                scrollBar:Show()
            end
        end

        for i, opt in ipairs(sortedOptions) do
            local menuBtn = CreateFrame("Button", nil, scrollChild)
            menuBtn:SetSize(234, ITEM_HEIGHT)
            menuBtn:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM_HEIGHT)

            menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            menuBtn.Text:SetPoint("LEFT", 8, 0)
            menuBtn.Text:SetPoint("RIGHT", -8, 0)
            menuBtn.Text:SetJustifyH("LEFT")
            menuBtn.Text:SetText(opt.value)

            -- Highlight selected item
            local currentValue = dbTable[dbKey]
            if currentValue == opt.key then
                menuBtn.Text:SetTextColor(GetThemeColor().r, GetThemeColor().g, GetThemeColor().b)
            else
                menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end

            menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
            menuBtn.Highlight:SetAllPoints()
            local c = GetThemeColor()
            menuBtn.Highlight:SetColorTexture(c.r, c.g, c.b, 0.3)

            menuBtn:SetScript("OnClick", function()
                dbTable[dbKey] = opt.key
                UpdateText()
                menuFrame:Hide()
                DF:UpdateAll()
                if callback then callback() end
            end)

            table.insert(menuButtons, menuBtn)
        end
    end

    searchBox:SetScript("OnTextChanged", function(self)
        RebuildMenu(self:GetText())
    end)

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
            CloseOpenDropdown()
            RebuildMenu()
            menuFrame:Show()
            currentOpenDropdown = menuFrame
            searchBox:SetFocus()
        end
    end)

    btn:SetScript("OnShow", UpdateText)
    UpdateText()

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
        TANK = { name = L["Tank"], color = {0.53, 0.77, 0.84}, coords = {0, 19/64, 22/64, 41/64} },
        HEALER = { name = L["Healer"], color = {0.25, 0.78, 0.25}, coords = {20/64, 39/64, 1/64, 20/64} },
        MELEE = { name = L["Melee DPS"], color = {0.82, 0.65, 0.47}, coords = {20/64, 39/64, 22/64, 41/64} },
        RANGED = { name = L["Ranged DPS"], color = {1.0, 0.49, 0.04}, coords = {20/64, 39/64, 22/64, 41/64} },
        DAMAGER = { name = L["DPS"], color = {0.82, 0.65, 0.47}, coords = {20/64, 39/64, 22/64, 41/64} },
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
        
        local icon = grip:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(grip)
        icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\reorder")
        icon:SetVertexColor(0.5, 0.5, 0.5, 1)
        grip.icon = icon
        
        grip.SetGripColor = function(self, r, g, b)
            self.icon:SetVertexColor(r, g, b, 1)
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
        local numText = item:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
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
        local text = item:CreateFontString(nil, "OVERLAY", "DFFontNormal")
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
                
                local tc = GetThemeColor()
                self:SetBackdropColor(tc.r * 0.6, tc.g * 0.6, tc.b * 0.6, 0.9)
                self:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
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
    if dbKey and type(dbKey) == "string" and not (dbTable and rawget(dbTable, "_skipOverrideIndicators")) then
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
        DEATHKNIGHT = { name = L["Death Knight"], color = {0.77, 0.12, 0.23} },
        DEMONHUNTER = { name = L["Demon Hunter"], color = {0.64, 0.19, 0.79} },
        DRUID = { name = L["Druid"], color = {1.0, 0.49, 0.04} },
        EVOKER = { name = L["Evoker"], color = {0.20, 0.58, 0.50} },
        HUNTER = { name = L["Hunter"], color = {0.67, 0.83, 0.45} },
        MAGE = { name = L["Mage"], color = {0.25, 0.78, 0.92} },
        MONK = { name = L["Monk"], color = {0.0, 1.0, 0.59} },
        PALADIN = { name = L["Paladin"], color = {0.96, 0.55, 0.73} },
        PRIEST = { name = L["Priest"], color = {1.0, 1.0, 1.0} },
        ROGUE = { name = L["Rogue"], color = {1.0, 0.96, 0.41} },
        SHAMAN = { name = L["Shaman"], color = {0.0, 0.44, 0.87} },
        WARLOCK = { name = L["Warlock"], color = {0.53, 0.53, 0.93} },
        WARRIOR = { name = L["Warrior"], color = {0.78, 0.61, 0.43} },
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
        
        local icon = grip:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(grip)
        icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\reorder")
        icon:SetVertexColor(0.5, 0.5, 0.5, 1)
        grip.icon = icon
        
        grip.SetGripColor = function(self, r, g, b)
            self.icon:SetVertexColor(r, g, b, 1)
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
        local numText = item:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
        local text = item:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
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
                
                local tc = GetThemeColor()
                self:SetBackdropColor(tc.r * 0.6, tc.g * 0.6, tc.b * 0.6, 0.9)
                self:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
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
    if dbKey and type(dbKey) == "string" and not (dbTable and rawget(dbTable, "_skipOverrideIndicators")) then
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
        
        local icon = grip:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(grip)
        icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\reorder")
        icon:SetVertexColor(0.5, 0.5, 0.5, 1)
        grip.icon = icon
        
        grip.SetGripColor = function(self, r, g, b)
            self.icon:SetVertexColor(r, g, b, 1)
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
        local numText = item:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
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
        local text = item:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        text:SetPoint("LEFT", swatch, "RIGHT", 6, 0)
        text:SetText(string.format(L["Group %d"], groupNum))
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
                
                local tc = GetThemeColor()
                self:SetBackdropColor(tc.r * 0.6, tc.g * 0.6, tc.b * 0.6, 0.9)
                self:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
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
    if dbKey and type(dbKey) == "string" and not (dbTable and rawget(dbTable, "_skipOverrideIndicators")) then
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
    local leftHeader = container:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    leftHeader:SetPoint("TOPLEFT", 0, 0)
    leftHeader:SetText(L["Group Roster"])
    leftHeader:SetTextColor(0.7, 0.7, 0.7)
    
    local leftCount = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    leftCount:SetPoint("LEFT", leftHeader, "RIGHT", 8, 0)
    leftCount:SetTextColor(0.5, 0.5, 0.5)
    
    local leftBg = CreateFrame("Frame", nil, container, "BackdropTemplate")
    leftBg:SetPoint("TOPLEFT", 0, -18)
    leftBg:SetSize(COL_WIDTH, 240)
    GUI:CreateElementBackdrop(leftBg, { bgColor = GUI.Colors.background })
    
    local leftScroll = CreateFrame("ScrollFrame", nil, leftBg, "ScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT", 4, -4)
    leftScroll:SetPoint("BOTTOMRIGHT", -24, 4)
    
    local leftContent = CreateFrame("Frame", nil, leftScroll)
    leftContent:SetSize(COL_WIDTH - 28, 1)
    leftScroll:SetScrollChild(leftContent)
    StyleScrollBar(leftScroll)

    -- ========== RIGHT COLUMN: Pinned Units ==========
    local rightHeader = container:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    rightHeader:SetPoint("TOPLEFT", leftBg, "TOPRIGHT", COL_GAP, 18)
    rightHeader:SetText(L["Pinned Units"])
    rightHeader:SetTextColor(0.7, 0.7, 0.7)
    
    local rightCount = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    rightCount:SetPoint("LEFT", rightHeader, "RIGHT", 8, 0)
    rightCount:SetTextColor(0.5, 0.5, 0.5)
    
    local rightBg = CreateFrame("Frame", nil, container, "BackdropTemplate")
    rightBg:SetPoint("TOPLEFT", leftBg, "TOPRIGHT", COL_GAP, 0)
    rightBg:SetSize(COL_WIDTH, 240)
    GUI:CreateElementBackdrop(rightBg, { bgColor = GUI.Colors.background })
    
    local rightScroll = CreateFrame("ScrollFrame", nil, rightBg, "ScrollFrameTemplate")
    rightScroll:SetPoint("TOPLEFT", 4, -4)
    rightScroll:SetPoint("BOTTOMRIGHT", -24, 4)
    
    local rightContent = CreateFrame("Frame", nil, rightScroll)
    rightContent:SetSize(COL_WIDTH - 28, 1)
    rightScroll:SetScrollChild(rightContent)
    StyleScrollBar(rightScroll)

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
        
        local icon = grip:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(grip)
        icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\reorder")
        icon:SetVertexColor(0.5, 0.5, 0.5, 1)
        grip.icon = icon
        
        grip.SetGripColor = function(self, r, g, b)
            self.icon:SetVertexColor(r, g, b, 1)
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
        local nameText = item:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
        local groupText = item:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
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
        local numText = item:CreateFontString(nil, "OVERLAY", "DFFontNormal")
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
        local nameText = item:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
            nameText:SetText(displayName .. " " .. L["(offline)"])
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
        btn:SetPoint("LEFT", xOffset, 0)
        -- Persistent role colour via the shared tinted variant — the colour IS the
        -- button's identity, so it stays on at rest and brightens on hover.
        GUI:StyleButton(btn, {
            width = 68, height = 24,
            tinted = true,
            accent = { r = color[1], g = color[2], b = color[3] },
            text = text,
        })
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
        return btn
    end
    
    local tankBtn = CreateQuickAddButton("+ " .. L["Tanks"], "TANK", ROLE_COLORS.TANK, 0)
    local healerBtn = CreateQuickAddButton("+ " .. L["Healers"], "HEALER", ROLE_COLORS.HEALER, 72)
    local dpsBtn = CreateQuickAddButton("+ " .. L["DPS"], "DAMAGER", ROLE_COLORS.DAMAGER, 144)
    local allBtn = CreateQuickAddButton("+ " .. L["All"], "ALL", {0.6, 0.6, 0.6}, 216)
    
    -- Clear All button (right side) — persistent red via the tinted variant.
    local clearBtn = CreateFrame("Button", nil, buttonRow, "BackdropTemplate")
    clearBtn:SetPoint("RIGHT", 0, 0)
    GUI:StyleButton(clearBtn, {
        width = 68, height = 24,
        tinted = true,
        accent = { r = 0.85, g = 0.35, b = 0.35 },
        text = L["Clear All"],
    })
    clearBtn:SetScript("OnClick", function()
        setPlayersFunc({})
        if onChangeCallback then onChangeCallback() end
        container:Refresh()
    end)
    
    -- Remove Offline button (next to Clear All) — persistent gold via tinted.
    local removeOfflineBtn = CreateFrame("Button", nil, buttonRow, "BackdropTemplate")
    removeOfflineBtn:SetPoint("RIGHT", clearBtn, "LEFT", -6, 0)
    GUI:StyleButton(removeOfflineBtn, {
        width = 90, height = 24,
        tinted = true,
        accent = { r = 0.85, g = 0.65, b = 0.35 },
        text = L["Remove Offline"],
    })
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

    -- ========== MANUAL PLAYER ENTRY ==========
    local themeColor = GetThemeColor()
    local manualHeader = container:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    manualHeader:SetPoint("TOPLEFT", buttonRow, "BOTTOMLEFT", 0, -12)
    manualHeader:SetText(L["Add Offline Player"])
    manualHeader:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    
    local manualHelp = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    manualHelp:SetPoint("TOPLEFT", manualHeader, "BOTTOMLEFT", 0, -2)
    manualHelp:SetText(L["Pre-configure players before they join the group"])
    manualHelp:SetTextColor(0.45, 0.45, 0.45)
    
    local manualInput = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    manualInput:SetPoint("TOPLEFT", manualHelp, "BOTTOMLEFT", 0, -6)
    manualInput:SetSize(380, 24)
    GUI:StyleEditBox(manualInput, { skipFont = true })
    manualInput:SetFontObject(DFFontHighlight)
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
    GUI:StyleButton(addManualBtn, {
        width = 54, height = 24,
        tinted = true,
        text = L["Add"],
    })
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
                container.emptyHint = rightContent:CreateFontString(nil, "OVERLAY", "DFFontNormal")
                container.emptyHint:SetPoint("CENTER", rightBg, "CENTER", 0, 0)
                container.emptyHint:SetText(L["Add players from the roster\nor use quick add buttons"])
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
    
    local lbl = f:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmallOutline")
    lbl:SetPoint("LEFT", f, "LEFT", 8, 0)
    lbl:SetText("0%")
    lbl:SetTextColor(1, 1, 1, 1)
    
    local lbl2 = f:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmallOutline")
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
-- SELECTABLE LIST WIDGET
-- Scrollable list of selectable items with hover highlight and accent
-- selection bar. Used by the Wizard Builder for wizard/step lists.
-- =========================================================================

-- =========================================================================
-- SEARCHABLE DROPDOWN WIDGET
-- Dropdown with a search/filter box. Used for the DB key picker (800+ keys)
-- and any large option set. Groups items by category headers.
-- =========================================================================

-- =========================================================================
-- KEY-VALUE EDITOR WIDGET
-- Editable list of key=value rows for the wizard builder settings map.
-- Each row: [Searchable Key Dropdown] = [Value Input] [X Delete]
-- =========================================================================

-- =========================================================================
-- BRANCH EDITOR WIDGET
-- Visual editor for conditional wizard branching rules.
-- Each row: IF [step] [operator] [value] → [goto step] [X]
-- Plus: ELSE → [fallback step]
-- =========================================================================

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
        if DandersFramesDB_v2 and DandersFramesDB_v2.lastSeenVersion ~= DF.VERSION then
            DandersFramesDB_v2.lastSeenVersion = DF.VERSION
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
    
    local title = titleBar:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("LEFT", 12, 0)
    local versionStr = DF.VERSION or "Unknown"
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
    local closeBtn = GUI:CreateCloseButton(frame, { size = 20, onClick = function() frame:Hide() end })
    closeBtn:SetPoint("TOPRIGHT", -8, -5)
    closeBtn:SetFrameStrata("FULLSCREEN_DIALOG")
    closeBtn:SetFrameLevel(210)

    -- Info button (changelog)
    local infoBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    infoBtn:SetPoint("TOPRIGHT", -32, -5)
    infoBtn:SetFrameStrata("FULLSCREEN_DIALOG")
    infoBtn:SetFrameLevel(210)
    -- Icon-only changelog button via the shared styler (backdrop + hover); the hook
    -- brightens the icon to the theme colour on hover.
    GUI:StyleButton(infoBtn, {
        width = 20, height = 20,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\notes", size = 16, color = C_TEXT_DIM },
    })
    infoBtn:HookScript("OnEnter", function(self)
        local tc = GetThemeColor()
        self.Icon:SetVertexColor(tc.r, tc.g, tc.b)
    end)
    infoBtn:HookScript("OnLeave", function(self)
        self.Icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
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

    local changelogTitle = changelogHeader:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    changelogTitle:SetPoint("LEFT", 4, 0)
    changelogTitle:SetText(L["Changelog"] .. " — " .. versionStr)
    changelogTitle:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local backBtn = CreateFrame("Button", nil, changelogHeader, "BackdropTemplate")
    backBtn:SetPoint("RIGHT", 0, 0)
    GUI:StyleButton(backBtn, { width = 60, height = 22, text = L["Close"] })
    backBtn:SetScript("OnClick", function() changelogOverlay:Hide() end)

    -- Convert markdown changelog to WoW color-coded plain text
    local function FormatChangelog(text)
        if not text or text == "" then return L["No changelog available."] end
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

    local changelogScroll = CreateFrame("ScrollFrame", nil, changelogOverlay, "ScrollFrameTemplate")
    changelogScroll:SetPoint("TOPLEFT", 8, -38)
    changelogScroll:SetPoint("BOTTOMRIGHT", -26, 8)

    local changelogContent = CreateFrame("EditBox", nil, changelogScroll)
    changelogContent:SetMultiLine(true)
    changelogContent:SetAutoFocus(false)
    changelogContent:SetFontObject(DFFontHighlightSmall)
    changelogContent:SetWidth(changelogScroll:GetWidth() or 500)
    changelogContent:SetText(FormatChangelog(DF.CHANGELOG_TEXT))
    changelogContent:SetCursorPosition(0)
    changelogContent:EnableMouse(true)
    changelogContent:EnableKeyboard(false)
    changelogContent:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    changelogContent:SetScript("OnEditFocusGained", function(self) self:HighlightText(0, 0) end)
    changelogScroll:SetScrollChild(changelogContent)
    StyleScrollBar(changelogScroll)
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
    -- Shared underline-tab style; SetActive (in UpdateThemeColors) drives it.
    GUI:StyleButton(btnParty, { tab = true, text = L["PARTY"], accent = C_ACCENT, width = 70, height = 24, font = "DFFontHighlight" })
    GUI.PartyButton = btnParty  -- Store for external access
    
    local btnRaid = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnRaid:SetPoint("LEFT", btnParty, "RIGHT", 4, 0)
    GUI:StyleButton(btnRaid, { tab = true, text = L["RAID"], accent = C_RAID, width = 70, height = 24, font = "DFFontHighlight" })
    GUI.RaidButton = btnRaid  -- Store for external access
    
    -- Click Casting tab button
    local btnClicks = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnClicks:SetPoint("LEFT", btnRaid, "RIGHT", 4, 0)
    GUI:StyleButton(btnClicks, { tab = true, text = L["BINDS"], accent = { r = 0.2, g = 0.8, b = 0.4 }, width = 70, height = 24, font = "DFFontHighlight" })
    GUI.ClicksButton = btnClicks

    -- =========================================================================
    -- TEST MODE BUTTON (next to CLICKS tab)
    -- =========================================================================
    local btnTest = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnTest:SetPoint("LEFT", btnClicks, "RIGHT", 12, 0)
    GUI:StyleButton(btnTest, {
        width = 75, height = 24,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\preview_off", size = 18, color = C_TEXT_DIM },
        text = L["Test"],
    })
    GUI:SetSettingsFont(btnTest.Text, 11, "")  -- 11px (between Small 10 and Highlight 12)
    btnTest.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    -- Content-fit width (less dead space)
    btnTest:SetWidth(math.ceil(btnTest.Text:GetStringWidth()) + 38)
    GUI.TestButton = btnTest
    
    -- =========================================================================
    -- LOCK/UNLOCK BUTTON (next to Test button)
    -- =========================================================================
    local btnLock = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnLock:SetPoint("LEFT", btnTest, "RIGHT", 4, 0)
    GUI:StyleButton(btnLock, {
        width = 80, height = 24,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\lock", size = 18, color = C_TEXT_DIM },
        text = L["Unlock"],
    })
    GUI:SetSettingsFont(btnLock.Text, 11, "")  -- 11px (between Small 10 and Highlight 12)
    btnLock.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    -- Size to the wider "Unlock" label so toggling Lock/Unlock doesn't resize the
    -- button (real label set in UpdateLockButtonState).
    btnLock:SetWidth(math.ceil(btnLock.Text:GetStringWidth()) + 38)
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
        -- Raid mode uses raidLocked, party mode uses locked. Use an explicit
        -- branch (NOT `a and b or c`) so an unlocked raid (raidLocked=false)
        -- doesn't fall through to the party `locked` value and read as locked.
        local isLocked
        if db then
            if GUI.SelectedMode == "raid" then isLocked = db.raidLocked else isLocked = db.locked end
        end

        -- While an auto layout drives the raid frames, dragging the base position by
        -- accident is the bug we're preventing: disable the toolbar Unlock and steer
        -- users to the active layout's own Unlock button (Auto Layouts page). Only the
        -- UNLOCK action is blocked (isLocked) — locking from here still works to finish
        -- a session.
        local layoutActive = (GUI.SelectedMode == "raid") and DF.AutoProfilesUI
            and DF.AutoProfilesUI.IsLayoutActive and DF.AutoProfilesUI:IsLayoutActive()
        if layoutActive and isLocked then
            btnLock.dfDisabled = true
            btnLock.Text:SetText(L["Unlock"])
            btnLock.Icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\lock")
            btnLock:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.5)
            btnLock:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
            btnLock.Text:SetTextColor(0.4, 0.4, 0.4)
            btnLock.Icon:SetVertexColor(0.4, 0.4, 0.4)
            UpdatePositionOverrideIndicator()
            return
        end
        btnLock.dfDisabled = false

        btnLock.Text:SetText(isLocked and L["Unlock"] or L["Lock"])
        btnLock.Icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. (isLocked and "lock" or "lock_open"))
        
        if not isLocked then
            -- Unlocked - active/selected toggle look (white text/icon like the others)
            btnLock:SetActive(true)
            btnLock.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            btnLock.Icon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            -- Locked - normal rest (white text/icon; state shown by the border/fill)
            btnLock:SetActive(false)
            btnLock.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            btnLock.Icon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        end
        
        -- Update position override indicator
        UpdatePositionOverrideIndicator()
    end
    GUI.UpdateLockButtonState = UpdateLockButtonState
    
    -- HookScript (not SetScript) so the disabled tooltip composes with the
    -- StyleButton hover instead of clobbering it.
    btnLock:HookScript("OnEnter", function(self)
        if self.dfDisabled then
            local name = DF.AutoProfilesUI and DF.AutoProfilesUI.GetActiveLayoutName
                and DF.AutoProfilesUI:GetActiveLayoutName()
            GUI:ShowTooltip(self, {
                title = L["Locked by Auto Layout"],
                tone = "warning",
                lines = { format(L["Auto layout \"%s\" is active. Unlock it from the Auto Layouts page to move its frames."], name or "?") },
            })
        end
    end)
    btnLock:HookScript("OnLeave", function() GameTooltip:Hide() end)

    btnLock:SetScript("OnClick", function()
        if btnLock.dfDisabled then
            local name = DF.AutoProfilesUI and DF.AutoProfilesUI.GetActiveLayoutName
                and DF.AutoProfilesUI:GetActiveLayoutName()
            print("|cffff9900DandersFrames:|r " .. format(L["Auto layout \"%s\" is active. Unlock it from the Auto Layouts page to move its frames."], name or "?"))
            return
        end

        local db = DF.db[GUI.SelectedMode]
        if not db then return end

        -- Check current lock state using the correct key per mode (explicit
        -- branch — `a and b or c` would misread an unlocked raid as locked).
        local isLocked
        if GUI.SelectedMode == "raid" then isLocked = db.raidLocked else isLocked = db.locked end
        
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
    
    local scaleLabel = scaleContainer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    scaleLabel:SetPoint("LEFT", 0, 0)
    scaleLabel:SetText(L["UI Scale:"])
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
    
    local scaleValue = scaleContainer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
        -- Mode buttons use the shared underline-tab style; SetActive drives the
        -- underline + accent label (each button's per-mode accent set at creation).
        btnParty:SetActive(GUI.SelectedMode == "party")
        btnRaid:SetActive(GUI.SelectedMode == "raid")
        btnClicks:SetActive(GUI.SelectedMode == "clicks")

        -- Test button look via the shared toggle styling (matches how the Lock
        -- button is refreshed below). The old inline version painted a stray
        -- theme-coloured border even at rest.
        if UpdateTestButtonState then UpdateTestButtonState() end

        -- Refresh the toolbar buttons' hover wash to the current mode accent.
        -- They live on the main frame (not a page child), so the page
        -- ThemeListeners loop below never reaches them — without this their hover
        -- stays the party colour after switching to raid. (UpdateTestButtonState/
        -- SetActive only fix the resting backdrop, not the HIGHLIGHT wash.)
        if btnTest.UpdateTheme then btnTest.UpdateTheme() end
        if btnLock.UpdateTheme then btnLock.UpdateTheme() end
        -- infoBtn (changelog) also lives on the main frame, not a page child, so
        -- the ThemeListeners loop below never reaches it either — refresh its hover
        -- wash to the current mode accent here alongside Test/Lock.
        if infoBtn and infoBtn.UpdateTheme then infoBtn.UpdateTheme() end
        
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
                btn.Text:SetTextColor(0.4, 0.4, 0.4)
                btn.Text:SetAlpha(1)
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
        -- Active toggle look based on whether the test panel is visible.
        local testActive = DF.TestPanel and DF.TestPanel:IsShown()
        btnTest:SetActive(testActive)
        -- Swap the framed-eye glyph: open (preview) when test mode is showing the
        -- preview frames, slashed (preview_off) when it's off.
        btnTest.Icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
            .. (testActive and "preview" or "preview_off"))
        -- White text/icon in both states (state shown by the toggle border/fill).
        btnTest.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        btnTest.Icon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
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
    
    -- Hover is handled by StyleButton (resets to grey on leave). The old manual
    -- OnEnter/OnLeave left a stuck theme-coloured border because its OnLeave reset
    -- to themeColor@0.5 rather than the neutral border.

    btnParty:SetScript("OnClick", function()
        DF:SyncLinkedSections()

        -- Carry test mode across the mode switch (raid test -> party test)
        local carryTest = false
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
                carryTest = true
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
        GUI:UpdateTabAvailability()
        GUI:RefreshCurrentPage()

        -- Keep test mode active when switching modes (just switch which mode it runs in)
        if carryTest and DF.ShowTestFrames then
            DF:ShowTestFrames(true)  -- silent
            -- ShowTestFrames (unlike ShowRaidTestFrames) doesn't refresh the GUI,
            -- so the test panel's toggle label would stay on "Enable Test Mode".
            -- Refresh it now that party test mode is active.
            if DF.TestPanel and DF.TestPanel:IsShown() then
                DF.TestPanel:UpdateStateNoCallback()
            end
        end
    end)
    btnRaid:SetScript("OnClick", function()
        DF:SyncLinkedSections()

        -- Carry test mode across the mode switch (party test -> raid test)
        local carryTest = false
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
                carryTest = true
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
        GUI:UpdateTabAvailability()
        GUI:RefreshCurrentPage()

        -- Keep test mode active when switching modes (just switch which mode it runs in)
        if carryTest and DF.ShowRaidTestFrames then
            DF:ShowRaidTestFrames()
        end
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
    
    local tabScroll = CreateFrame("ScrollFrame", nil, tabFrame, "ScrollFrameTemplate")
    tabScroll:SetPoint("TOPLEFT", 4, tabScrollStartY)
    tabScroll:SetPoint("BOTTOMRIGHT", -14, 4)
    
    StyleScrollBar(tabScroll)
    -- Custom positioning for tab scrollbar
    if tabScroll.ScrollBar then
        tabScroll.ScrollBar:ClearAllPoints()
        tabScroll.ScrollBar:SetPoint("TOPRIGHT", tabFrame, "TOPRIGHT", -4, tabScrollStartY)
        tabScroll.ScrollBar:SetPoint("BOTTOMRIGHT", tabFrame, "BOTTOMRIGHT", -4, 4)
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
            GUI:CreatePanelBackdrop(popup, { bgAlpha = 0.98, borderColor = C_ACCENT })
            popup:SetFrameStrata("FULLSCREEN_DIALOG")
            popup:SetFrameLevel(250)
            popup:EnableMouse(true)
            
            local popupTitle = popup:CreateFontString(nil, "OVERLAY", "DFFontNormal")
            popupTitle:SetPoint("TOP", 0, -10)
            popupTitle:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            popup.title = popupTitle
            
            local editBox = CreateFrame("EditBox", nil, popup, "BackdropTemplate")
            editBox:SetPoint("TOPLEFT", 12, -30)
            editBox:SetPoint("TOPRIGHT", -12, -30)
            editBox:SetHeight(22)
            GUI:StyleEditBox(editBox)
            editBox:SetAutoFocus(true)
            editBox:SetScript("OnEscapePressed", function() popup:Hide() end)
            editBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
            popup.editBox = editBox
            
            local hint = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            hint:SetPoint("BOTTOM", 0, 8)
            hint:SetText(L["Press Ctrl+C to copy, then Escape to close"])
            hint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            
            GUI.urlPopup = popup
        end
        
        popup.title:SetText(label)
        popup.editBox:SetText(url)
        popup:Show()
        popup.editBox:SetFocus()
        popup.editBox:HighlightText()
    end
    GUI.ShowURLPopup = ShowURLPopup

    -- Create a footer link button
    local function CreateFooterLink(parent, text, color, url, popupLabel)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetHeight(22)
        
        local label = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
    local discordBtn = CreateFooterLink(footer, L["Need support? Join our Discord"], discordColor,
        "https://discord.gg/SDWtduCqnT", L["Join the DandersFrames Discord"])
    discordBtn:SetPoint("LEFT", footer, "LEFT", 2, 0)
    
    -- Separator
    local sep = footer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    sep:SetPoint("LEFT", discordBtn, "RIGHT", 8, 0)
    sep:SetText("|")
    sep:SetTextColor(C_BORDER.r, C_BORDER.g, C_BORDER.b)
    
    -- PayPal link
    local paypalColor = { r = 0.35, g = 0.65, b = 0.45 }
    local donateBtn = CreateFooterLink(footer, L["Support with PayPal"], paypalColor,
        "https://paypal.me/dandersframesaddon", L["Support DandersFrames Development"])
    donateBtn:SetPoint("LEFT", sep, "RIGHT", 8, 0)

    -- Separator 2
    local sep2 = footer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    sep2:SetPoint("LEFT", donateBtn, "RIGHT", 8, 0)
    sep2:SetText("|")
    sep2:SetTextColor(C_BORDER.r, C_BORDER.g, C_BORDER.b)

    -- Patreon link
    local patreonColor = { r = 0.90, g = 0.35, b = 0.30 }
    local patreonBtn = CreateFooterLink(footer, L["Support with Patreon"], patreonColor,
        "https://www.patreon.com/DandersFrames", L["Support DandersFrames on Patreon"])
    patreonBtn:SetPoint("LEFT", sep2, "RIGHT", 8, 0)

    -- Version on the right
    local versionText = footer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    versionText:SetPoint("RIGHT", footer, "RIGHT", -2, 0)
    versionText:SetText(versionStr .. channelTag)
    versionText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.5)
    
    -- Create the click casting UI content
    if DF.ClickCast then
        DF.ClickCast:CreateClickCastUI(clickCastPanel)
    end
    
    -- Store min width references for tab switching
    local normalMinWidth = minWidth  -- 520
    -- Shared minimum width for the "wide" pages (Binds/Click Casting, Aura
    -- Designer, Text Designer, Pinned Frames) — their two-panel / tab-strip
    -- layouts squash below this.
    local wideMinWidth = 850
    
    -- Function to show normal Party/Raid content
    function GUI:ShowNormalContent()
        if clickCastPanel then clickCastPanel:Hide() end
        if tabFrame then tabFrame:Show() end
        if content then content:Show() end

        -- Restore normal minimum width
        frame:SetResizeBounds(normalMinWidth, minHeight, maxWidth, maxHeight)

        -- Update tab availability for current mode (greys out tabs for disabled modes)
        GUI:UpdateTabAvailability()
    end
    
    -- Function to show Click Casting content
    function GUI:ShowClickCastingContent()
        if tabFrame then tabFrame:Hide() end
        if content then content:Hide() end
        
        -- Set larger minimum width for clicks tab
        frame:SetResizeBounds(wideMinWidth, minHeight, maxWidth, maxHeight)
        
        -- If current width is less than clicks min, expand it
        local currentWidth = frame:GetWidth()
        if currentWidth < wideMinWidth then
            frame:SetWidth(wideMinWidth)
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

        -- Clear any "New" section-header badges on the tab we're leaving.
        -- The user has had their chance to see the badges; mark them seen
        -- persistently so they don't reappear on the next visit.
        local leavingTab = GUI.CurrentPageName
        if leavingTab and leavingTab ~= name and GUI.pendingSectionBadges[leavingTab] then
            for key, badge in pairs(GUI.pendingSectionBadges[leavingTab]) do
                if badge and badge.Hide then badge:Hide() end
                if DandersFramesDB_v2 then
                    DandersFramesDB_v2.seenSections = DandersFramesDB_v2.seenSections or {}
                    DandersFramesDB_v2.seenSections[key] = true
                end
            end
            GUI.pendingSectionBadges[leavingTab] = nil
        end

        for k, page in pairs(GUI.Pages) do page:Hide() end
        for k, btn in pairs(GUI.Tabs) do
            if btn.accent then btn.accent:Hide() end
            -- Check if tab is disabled (e.g., during Auto Profile editing)
            if btn.disabled then
                btn.Text:SetTextColor(0.4, 0.4, 0.4)
                btn.Text:SetAlpha(1)
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
        
        -- Wide pages (AD/TD/Pinned) need extra width; set the resize bounds +
        -- expand BEFORE building the page so its content lays out at the final
        -- width instead of building narrow then staying squashed until a resize.
        local WIDE_PAGES = {
            auras_auradesigner = true,    -- two-panel preview + controls
            text_designer = true,         -- two-panel preview + controls
            general_pinnedframes = true,  -- tab strip + active-set meter
            general_nicknames = true,     -- wide add-row (Match+Char+Nick+Add) + list columns
        }
        if WIDE_PAGES[name] then
            frame:SetResizeBounds(wideMinWidth, minHeight, maxWidth, maxHeight)
            if frame:GetWidth() < wideMinWidth then
                frame:SetWidth(wideMinWidth)
            end
            -- Belt-and-braces: re-assert the width next frame so size-dependent
            -- layout settles without a manual resize. A page can build at a
            -- pre-layout width (tabs overflow the panel / cards squashed); nudging
            -- the width fires the same OnSizeChanged re-flows a resize would.
            C_Timer.After(0, function()
                if GUI.CurrentPageName ~= name or not frame:IsShown() then return end
                local w = frame:GetWidth()
                frame:SetWidth(w + 1)
                frame:SetWidth(w)
            end)
        else
            frame:SetResizeBounds(normalMinWidth, minHeight, maxWidth, maxHeight)
        end

        if GUI.Pages[name] then
            -- Set current tab for Search registration
            if DF.Search then
                local page = GUI.Pages[name]
                DF.Search:SetCurrentTab(page.tabName, page.tabLabel)
                DF.Search.CurrentSection = nil
            end
            
            GUI.Pages[name]:Show()
            -- Tab switching uses the cache-aware path so revisiting a tab is cheap.
            GUI.Pages[name]:RefreshCached()
            if GUI.Pages[name].RefreshStates then GUI.Pages[name]:RefreshStates() end
            -- Reapply picker overlays if in picker mode
            if DF.settingsPickerMode and DF.ApplyPickerOverlaysToCurrentPage then
                C_Timer.After(0.05, function() DF:ApplyPickerOverlaysToCurrentPage() end)
            end
        end
        local nc = GetThemeColor()
        if GUI.Tabs[name] then
            if GUI.Tabs[name].accent then
                GUI.Tabs[name].accent:Show()
                GUI.Tabs[name].accent:SetColorTexture(nc.r, nc.g, nc.b, 1)
            end
            GUI.Tabs[name].Text:SetTextColor(nc.r, nc.g, nc.b)
            GUI.Tabs[name].isActive = true
            -- Mark "New" badge as seen
            if GUI.Tabs[name].newBadge and GUI.Tabs[name].newBadge:IsShown() then
                GUI.Tabs[name].newBadge:Hide()
                if DandersFramesDB_v2 then
                    DandersFramesDB_v2.seenTabs = DandersFramesDB_v2.seenTabs or {}
                    DandersFramesDB_v2.seenTabs[name] = true
                end
                -- Hide parent category badge if no remaining children have new badges
                local catName = GUI.Tabs[name].categoryName
                local cat = catName and GUI.Categories[catName]
                if cat and cat.newBadge and cat.newBadge:IsShown() then
                    local anyNew = false
                    for _, child in ipairs(cat.children) do
                        if child.newBadge and child.newBadge:IsShown() then
                            anyNew = true
                            break
                        end
                    end
                    if not anyNew then cat.newBadge:Hide() end
                end
            end
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

    -- Invalidate EVERY page's build cache so the next time each tab is shown it
    -- rebuilds from scratch (via RefreshCached -> DoBuild). The page cache is
    -- keyed on mode (party/raid) only, NOT on the active auto-layout/profile, so
    -- switching between raid auto-layouts leaves cacheValid=true and tabs re-show
    -- stale geometry — most visibly the Aura Designer / Text Designer frame
    -- previews, which size their mock frame to the layout's frameWidth/Height at
    -- build time and so stay stuck at the first-edited layout's size. Call this
    -- whenever the active layout changes (enter/exit auto-profile editing).
    GUI.InvalidateAllPages = function()
        if not GUI.Pages then return end
        for _, page in pairs(GUI.Pages) do
            if page.Invalidate then page:Invalidate() end
        end
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
        cat.arrow = cat:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        cat.arrow:SetPoint("LEFT", 6, 0)
        cat.arrow:SetText(cat.expanded and "-" or "+")
        cat.arrow:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        
        cat.Text = cat:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        cat.Text:SetPoint("LEFT", 20, 0)
        cat.Text:SetText(label)
        cat.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        -- "New" badge for categories — shown when any child tab has a new badge
        local catNewBadge = cat:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        catNewBadge:SetPoint("RIGHT", cat, "RIGHT", -8, 0)
        catNewBadge:SetText(L["New"])
        catNewBadge:SetTextColor(1, 0.82, 0)
        catNewBadge:Hide()
        cat.newBadge = catNewBadge

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
        -- Only add to CategoryOrder if not already in the explicit list (Options.lua sets it)
        local found = false
        for _, v in ipairs(GUI.CategoryOrder) do
            if v == name then found = true break end
        end
        if not found then
            tinsert(GUI.CategoryOrder, name)
        end
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
        
        btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        btn.Text:SetPoint("LEFT", 24, 0)
        btn.Text:SetText(label)
        btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        -- "New" badge — shown for tabs in GUI.NewTabs until the user opens them
        local newBadge = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        newBadge:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
        newBadge:SetText(L["New"])
        newBadge:SetTextColor(1, 0.82, 0)
        newBadge:Hide()
        btn.newBadge = newBadge
        if GUI.NewTabs[name]
           and not (DandersFramesDB_v2 and DandersFramesDB_v2.seenTabs
                    and DandersFramesDB_v2.seenTabs[name]) then
            newBadge:Show()
            -- Also show "New" on the parent category
            if cat and cat.newBadge then
                cat.newBadge:Show()
            end
        end

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
        btn:SetScript("OnClick", function(self)
            if self.disabled then return end
            SelectTab(name)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        
        -- Create the page
        local page = CreateFrame("ScrollFrame", nil, content, "ScrollFrameTemplate")
        page:SetPoint("TOPLEFT", 8, -8)
        page:SetPoint("BOTTOMRIGHT", -8, 8)
        
        StyleScrollBar(page)

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
                        -- Party-only tabs are hidden entirely in raid mode.
                        if btn.partyOnly and GUI.SelectedMode == "raid" then
                            btn:Hide()
                        else
                            btn:Show()
                            btn:ClearAllPoints()
                            btn:SetPoint("TOPLEFT", 0, y)
                            btn:SetPoint("TOPRIGHT", 0, y)
                            y = y - 28
                        end
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

    -- Re-sync each category's expanded state from the current profile's saved
    -- state and relayout the sidebar. Categories read their state once at
    -- creation, so a profile switch needs this to reflect the new profile's
    -- expanded/collapsed tabs without a /reload.
    function GUI:RefreshCategoryStates()
        local saved = DF.db and DF.db.party and DF.db.party.guiExpandedCategories
        for name, cat in pairs(self.Categories) do
            cat.expanded = (saved and saved[name]) or false
            if cat.arrow then cat.arrow:SetText(cat.expanded and "-" or "+") end
        end
        self:UpdateTabLayout()
    end

    -- Store category order
    GUI.CategoryOrder = {}
    
    local function CreateTab(name, label)
        -- Legacy single tab support - create as category with one item
        local page = CreateSubTab("tools", name, label)
        return page
    end
    
    local function BuildPage(page, builderFunc)
        -- Internal: construct all widget frames for the current mode.
        -- Called on first visit and whenever the cache is invalidated.
        -- Always finishes by calling RefreshStates() so callers don't need to.
        local function DoBuild(self)
            local db = DF.db[GUI.SelectedMode]
            if not db then return end

            -- Retire old children: hide, detach anchors, and reparent to the
            -- trash frame so they leave the GUI frame hierarchy entirely.
            -- WoW cannot GC frames, but a detached subtree is not traversed
            -- during drag layout recalculation.
            if self.children then
                local trash = GUI._trashFrame
                for _, child in ipairs(self.children) do
                    child:Hide()
                    child:ClearAllPoints()
                    if trash then child:SetParent(trash) end
                end
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

            -- Disabled-mode handling: when the current mode is off in General
            -- settings, replace the page content with a single banner instead
            -- of rendering any controls. Whitelisted pages (General, Profiles,
            -- Debug, Targeted List, Personal Targeted) always render normally.
            if GUI:IsTabDisabledForCurrentMode(self.tabName) then
                local banner = GUI:CreateInfoBanner(parent, { tone = "info" })
                banner:SetText(GUI.SelectedMode == "raid"
                    and (L["Raid frames are currently disabled. Changes here will apply after re-enabling Raid in the General tab and reloading."])
                    or  (L["Party frames are currently disabled. Changes here will apply after re-enabling Party in the General tab and reloading."]))
                table.insert(self.children, banner)
                banner.layoutCol = "both"
                self.builtForMode = GUI.SelectedMode
                self.builtForDisabled = true
                self.cacheValid = true
                self:RefreshStates()
                return
            end

            local function AddSpace(h, col)
                local spacer = CreateFrame("Frame", nil, parent)
                spacer:SetSize(1, h)
                spacer.layoutHeight = h
                spacer.layoutCol = col or "both"
                table.insert(self.children, spacer)
                return spacer
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
            self.builtForMode = GUI.SelectedMode
            self.builtForDisabled = false
            self.cacheValid = true
            self:RefreshStates()
        end

        -- Invalidate this page's cache so the next RefreshCached() rebuilds.
        page.Invalidate = function(self)
            self.cacheValid = false
            self.builtForMode = nil
        end

        -- Cache-aware refresh — used ONLY by tab switching. If the cached build
        -- is still valid for the current mode and enabled/disabled state, run the
        -- cheap visibility/layout pass; otherwise rebuild. This is the perf path
        -- that makes revisiting a tab cheap.
        page.RefreshCached = function(self)
            local db = DF.db[GUI.SelectedMode]
            -- Guard against nil db (e.g., when "clicks" mode is selected)
            if not db then return end

            local isDisabled = GUI:IsTabDisabledForCurrentMode(self.tabName)
            if self.cacheValid
               and self.builtForMode == GUI.SelectedMode
               and self.builtForDisabled == isDisabled then
                self:RefreshStates()
                return
            end

            -- Cache miss: build fresh for this mode.
            -- DoBuild sets cacheValid and calls RefreshStates() before returning.
            DoBuild(self)
        end

        -- Refresh() ALWAYS rebuilds. This is its historical contract: callers
        -- invoke it after mutating data (adding/removing list items, reset/copy/
        -- sync, profile changes, etc.) and rely on the page being reconstructed.
        -- Only tab switching uses the cache, via RefreshCached().
        page.Refresh = function(self)
            local db = DF.db[GUI.SelectedMode]
            -- Guard against nil db (e.g., when "clicks" mode is selected)
            if not db then return end
            DoBuild(self)
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
                        -- Call refreshContent hook for dynamic content updates
                        if widget.refreshContent then
                            widget:refreshContent(db)
                        end
                    end
                end
            end
            
            -- Determine column layout based on content area width.
            -- Two-column settings groups are 280px wide and placed at x=5 (right
            -- edge 285), while column 2 starts at contentWidth/2 — so they begin to
            -- overlap once contentWidth drops below ~570. minColumnWidth must exceed
            -- the 280 group width (was a stale 270) so the layout collapses to one
            -- column BEFORE the columns touch, leaving a ~10px gutter at the cutover
            -- instead of overlapping for the last ~10px.
            local contentWidth = GUI.contentFrame and GUI.contentFrame:GetWidth() or 540
            local minColumnWidth = 285  -- ≥ the 280 group width + a small gutter
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
    
    -- Trash frame: detached from the GUI hierarchy. Old page children are
    -- reparented here on rebuild so they don't contribute to the frame
    -- traversal cost during window drag layout recalculation.
    GUI._trashFrame = CreateFrame("Frame")
    GUI._trashFrame:Hide()

    -- Invalidate all page caches (call before profile/mode switches so each
    -- page rebuilds with a fresh db reference on its next visit).
    function GUI:InvalidateAllPages()
        for _, page in pairs(self.Pages) do
            if page.Invalidate then page:Invalidate() end
        end
    end

    -- Invalidate a single page by name.
    function GUI:InvalidatePage(name)
        local page = self.Pages[name]
        if page and page.Invalidate then page:Invalidate() end
    end

    -- Load pages from Options file
    if DF.SetupGUIPages then
        DF:SetupGUIPages(GUI, CreateCategory, CreateSubTab, BuildPage)
    end
    
    -- Setup Auto Profiles editing banner
    if DF.AutoProfilesUI and DF.AutoProfilesUI.SetupEditingBanner then
        DF.AutoProfilesUI:SetupEditingBanner()
    end
    
    -- Apply Aura Designer tab disabled state before first SelectTab
    if DF.ApplyAuraDesignerTabState then
        DF:ApplyAuraDesignerTabState()
    end

    -- Update tab layout after all tabs created
    GUI:UpdateTabLayout()

    UpdateThemeColors()

    -- Apply tab availability for current mode (greys out disabled-mode tabs)
    GUI:UpdateTabAvailability()

    -- Select first subtab
    if GUI.CategoryOrder[1] then
        local firstCat = GUI.Categories[GUI.CategoryOrder[1]]
        if firstCat and firstCat.children[1] then
            SelectTab(firstCat.children[1].tabName)
        end
    end
end
