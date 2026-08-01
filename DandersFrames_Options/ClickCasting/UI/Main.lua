-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames

-- Get module namespace
local CC = DF.ClickCast
local L = DF.L
local format = string.format

-- HOOKS INTO DANDERSFRAMES
-- ============================================================

-- Hook frame creation to auto-register new frames
local originalCreateUnitFrame = DF.CreateUnitFrame
if originalCreateUnitFrame then
    DF.CreateUnitFrame = function(self, ...)
        local frame = originalCreateUnitFrame(self, ...)
        if frame and CC.db and CC.db.enabled then
            CC:RegisterFrame(frame)
        end
        return frame
    end
end

-- ============================================================
-- INITIALIZATION HOOK
-- ============================================================

-- ============================================================

-- NEW CLICK CASTING UI (Spell Grid with instant binding)
-- ============================================================

-- Shared tables for UI elements (accessible from other files)
CC.spellCells = CC.spellCells or {}
CC.bindingRows = CC.bindingRows or {}
local spellCells = CC.spellCells
local bindingRows = CC.bindingRows
local clickCastUIFrame = nil

-- Constants for Active Bindings section (shared with BindingEditor.lua)
CC.BINDING_ROW_HEIGHT = 48  -- Taller for two-line display with wrapping
CC.LEFT_PANEL_WIDTH = 300   -- Width of expanded bindings panel
CC.LEFT_PANEL_COLLAPSED_WIDTH = 85  -- Width when collapsed (wider for scrollbar)

local BINDING_ROW_HEIGHT = CC.BINDING_ROW_HEIGHT
local LEFT_PANEL_WIDTH = CC.LEFT_PANEL_WIDTH
local LEFT_PANEL_COLLAPSED_WIDTH = CC.LEFT_PANEL_COLLAPSED_WIDTH

-- Local alias for helper functions (defined in Bindings.lua)
local function GetSpellDisplayInfo(a, b) 
    if CC.GetSpellDisplayInfo then 
        return CC.GetSpellDisplayInfo(a, b) 
    else
        -- Fallback if function not available
        local name = b or (a and C_Spell.GetSpellName and C_Spell.GetSpellName(a)) or "Unknown"
        local icon = a and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(a) or 134400
        return name, icon, a
    end
end

-- Helper function to convert fallback settings to human-readable text
local function GetFallbackDisplayText(fallback)
    if not fallback then return nil end
    
    local parts = {}
    if fallback.mouseover then table.insert(parts, L["Mouseover"]) end
    if fallback.target then table.insert(parts, L["Target"]) end
    if fallback.selfCast then table.insert(parts, L["Self"]) end

    if #parts == 0 then return nil end
    return table.concat(parts, L[" then "])
end

-- Export to CC namespace for use in other UI files
CC.GetFallbackDisplayText = GetFallbackDisplayText

function CC:CreateClickCastUI(parent)
    if clickCastUIFrame then return end
    clickCastUIFrame = parent
    CC.clickCastUIFrame = parent
    
    local themeColor = CC.ACCENT
    -- Neutral chrome colours alias the shared GUI palette (identical RGB values),
    -- so theme tweaks stay in one place. The CC accent is green (themeColor) and
    -- the combat/no-combat status colours are CC-specific, so those stay local.
    local Colors = DF.GUI.Colors
    local C_BACKGROUND = Colors.background
    local C_PANEL = Colors.panel
    local C_ELEMENT = Colors.element
    local C_BORDER = Colors.border
    local C_TEXT = Colors.text
    local C_TEXT_DIM = Colors.textDim
    local C_COMBAT = {r = 1.0, g = 0.3, b = 0.3}
    local C_NOCOMBAT = {r = 0.3, g = 1.0, b = 0.3}
    
    -- Store colors for later use
    CC.UI_COLORS = {
        theme = themeColor,
        background = C_BACKGROUND,
        panel = C_PANEL,
        element = C_ELEMENT,
        border = C_BORDER,
        text = C_TEXT,
        textDim = C_TEXT_DIM,
        combat = C_COMBAT,
        nocombat = C_NOCOMBAT,
    }
    
    -- =========================================================================
    -- HEADER: Two rows for better organization
    -- =========================================================================
    -- Panel row only -- deliberately NOT stored on CC. `CC.header` holds the
    -- SECURE click-cast header (DandersFramesClickCastHeader), which owns every
    -- hover bind, the mouseoverstate driver, and all WrapScript install/removal.
    -- Assigning this plain panel row over that field replaced the secure frame
    -- for the rest of the session, silently disabling hover-bind setup on every
    -- frame created afterwards. Nothing ever read it back.
    local header = CreateFrame("Frame", nil, parent)
    header:SetPoint("TOPLEFT", 10, -8)
    header:SetPoint("TOPRIGHT", -10, -8)
    header:SetHeight(48)  -- Two rows

    -- === ROW 1: Title + Enable + Profile Dropdown ===
    local row1 = CreateFrame("Frame", nil, header)
    row1:SetPoint("TOPLEFT", 0, 0)
    row1:SetPoint("TOPRIGHT", 0, 0)
    row1:SetHeight(22)
    
    -- Title
    local title = row1:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    title:SetPoint("LEFT", 0, 0)
    title:SetText(L["Click-Casting"])
    title:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    
    -- Enable checkbox (next to title)
    local enableCb = CreateFrame("CheckButton", nil, row1, "BackdropTemplate")
    enableCb:SetPoint("LEFT", title, "RIGHT", 15, 0)
    DF.GUI:StyleCheckButton(enableCb, { accent = themeColor })
    
    local enableLabel = row1:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    enableLabel:SetPoint("LEFT", enableCb, "RIGHT", 3, 0)
    enableLabel:SetText(L["Enabled"])
    enableLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    enableCb:SetScript("OnClick", function(self)
        local wantEnabled = self:GetChecked()
        
        if wantEnabled then
            -- Check for conflicting addons
            local conflicts = {}
            if C_AddOns and C_AddOns.IsAddOnLoaded then
                if C_AddOns.IsAddOnLoaded("Clique") then
                    table.insert(conflicts, "Clique")
                end
                if C_AddOns.IsAddOnLoaded("Clicked") then
                    table.insert(conflicts, "Clicked")
                end
            elseif IsAddOnLoaded then
                if IsAddOnLoaded("Clique") then
                    table.insert(conflicts, "Clique")
                end
                if IsAddOnLoaded("Clicked") then
                    table.insert(conflicts, "Clicked")
                end
            end
            
            if #conflicts > 0 then
                -- Show conflict popup
                CC:ShowClickCastConflictPopup(conflicts, self)
                return
            end
            
            -- No addon conflicts - show Blizzard warning
            CC:ShowBlizzardClickCastWarning(self, function()
                -- Proceed with enabling
                CC.db.enabled = true
                CC:SetEnabled(true)
            end)
            return
        end
        
        -- Disabling - proceed normally
        CC.db.enabled = false
        CC:SetEnabled(false)
    end)
    
    -- Profile settings cogwheel (far right of row 1)
    local profileCogwheel = CreateFrame("Button", nil, row1, "BackdropTemplate")
    profileCogwheel:SetPoint("RIGHT", 0, 0)
    profileCogwheel:SetSize(18, 18)
    -- Icon-only button: shared styler owns the backdrop + accent-wash hover and
    -- builds the centred icon. The hook adds the icon-brighten + tooltip.
    DF.GUI:StyleButton(profileCogwheel, {
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\settings", size = 18, color = C_TEXT_DIM },
    })

    profileCogwheel:HookScript("OnEnter", function(self)
        self.Icon:SetVertexColor(themeColor.r, themeColor.g, themeColor.b)
        DF.GUI:ShowTooltip(self, {
            title = L["Profile Settings"],
            lines = { L["Open the Profiles tab to manage profiles"] },
        })
    end)
    profileCogwheel:HookScript("OnLeave", function(self)
        self.Icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        DF.GUI:HideTooltip()
    end)
    profileCogwheel:SetScript("OnClick", function()
        if CC.SetActiveTab then
            CC.SetActiveTab("profiles")
        end
    end)
    
    -- Profile dropdown (to the left of cogwheel) -- DYNAMIC list.
    -- Ported to the shared DF.GUI:CreateDropdown builder (inline opener, CC
    -- green accent). The profile list changes at runtime, so opts.optionsFunc
    -- rebuilds the options on every open. customGet = active profile name;
    -- customSet = switch + load the profile (with combat guard).
    local function GetProfileOptions()
        local opts = { _order = {} }
        for _, profileName in ipairs(CC:GetProfileList()) do
            opts[profileName] = profileName
            table.insert(opts._order, profileName)
        end
        return opts
    end

    local profileDropdown = DF.GUI:CreateDropdown(row1, nil, GetProfileOptions(), nil, nil, nil,
        function()
            return CC:GetActiveProfileName()
        end,
        function(profileName)
            if InCombatLockdown() then
                DF:Say(L["Cannot switch profiles during combat"])
                return
            end
            if profileName ~= CC:GetActiveProfileName() then
                if CC:SetActiveProfile(profileName) then
                    CC:ApplyBindings()
                    CC:RefreshClickCastingUI()
                end
            end
        end,
        { inline = true, accent = CC.ACCENT, optionsFunc = GetProfileOptions })
    profileDropdown:SetPoint("RIGHT", profileCogwheel, "LEFT", -4, 0)
    profileDropdown:SetSize(140, 18)

    local profileLabel = row1:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    profileLabel:SetPoint("RIGHT", profileDropdown, "LEFT", -4, 0)
    profileLabel:SetText(L["Profile:"])
    profileLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- External refreshers expect this to repaint the button text only.
    local function UpdateProfileDropdown()
        profileDropdown:UpdateText()
    end

    CC.profileDropdown = profileDropdown
    CC.UpdateProfileDropdown = UpdateProfileDropdown
    
    -- === ROW 2: Options (Cast on DOWN, Quick Bind, Smart Res, Search) ===
    local row2 = CreateFrame("Frame", nil, header)
    row2:SetPoint("TOPLEFT", 0, -24)
    row2:SetPoint("TOPRIGHT", 0, -24)
    row2:SetHeight(22)
    
    -- Cast on down checkbox
    local downCb = CreateFrame("CheckButton", nil, row2, "BackdropTemplate")
    downCb:SetPoint("LEFT", 0, 0)
    DF.GUI:StyleCheckButton(downCb, { accent = themeColor })
    
    local downLabel = row2:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    downLabel:SetPoint("LEFT", downCb, "RIGHT", 3, 0)
    downLabel:SetText(L["Cast on mouse down"])
    downLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    downCb:SetScript("OnClick", function(self)
        CC.db.options.castOnDown = self:GetChecked()
        CC:ApplyBindings()
    end)
    downCb:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = L["Cast on mouse down"],
            anchor = "ANCHOR_RIGHT",
            lines = { L["Click-casting on a unit frame fires when you press the mouse button (down) instead of releasing it (up). Applies to mouse clicks on frames only — keyboard binds are unaffected."] },
        })
    end)
    downCb:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)
    
    -- Quick Bind toggle
    local quickBindCb = CreateFrame("CheckButton", nil, row2, "BackdropTemplate")
    quickBindCb:SetPoint("LEFT", downLabel, "RIGHT", 15, 0)
    DF.GUI:StyleCheckButton(quickBindCb, { accent = themeColor })
    
    local quickBindLabel = row2:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    quickBindLabel:SetPoint("LEFT", quickBindCb, "RIGHT", 3, 0)
    quickBindLabel:SetText(L["Quick Bind"])
    quickBindLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    quickBindCb:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = L["Quick Bind Mode"],
            lines = {
                L["When enabled: Click spell, press key to bind instantly."],
                L["When disabled: Click spell to open Binding Editor."],
            },
        })
    end)
    quickBindCb:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)
    
    quickBindCb:SetScript("OnClick", function(self)
        CC.db.options.quickBindEnabled = self:GetChecked()
    end)

    -- Smart Resurrection dropdown
    local smartResLabel = row2:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    smartResLabel:SetPoint("LEFT", quickBindLabel, "RIGHT", 15, 0)
    smartResLabel:SetText(L["Smart Res:"])
    smartResLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Smart Res options are fixed; what changes is the CURRENT value source
    -- (CC.profile.options.smartResurrection — the active-profile reference
    -- swaps when profiles change). The shared builder reads that via customGet
    -- on every open / UpdateText, so the displayed selection always tracks the
    -- active profile without rebuilding the (static) option list.
    local smartResOptions = {
        disabled = L["Disabled"],
        normal = L["Res + Mass"],
        ["normal+combat"] = L["Res + Mass + Combat"],
        _order = { "disabled", "normal", "normal+combat" },
    }

    local smartResDropdown = DF.GUI:CreateDropdown(row2, nil, smartResOptions, nil, nil, nil,
        function()
            return CC.profile and CC.profile.options and CC.profile.options.smartResurrection or "disabled"
        end,
        function(value)
            if CC.profile and CC.profile.options then
                CC.profile.options.smartResurrection = value
            end
            CC:ApplyBindings()
        end,
        { inline = true, accent = CC.ACCENT })
    smartResDropdown:SetPoint("LEFT", smartResLabel, "RIGHT", 4, 0)
    smartResDropdown:SetSize(110, 16)

    -- External refreshers expect this to repaint the button text only.
    local function UpdateSmartResText()
        smartResDropdown:UpdateText()
    end

    -- Re-attach the rich Smart Res tooltip. The builder puts its hover scripts
    -- on the inner button (the container's sole child since dbKey is nil), so
    -- hook the tooltip there to ride alongside the builder's backdrop hover.
    local smartResBtn = select(1, smartResDropdown:GetChildren())
    if smartResBtn then
        smartResBtn:HookScript("OnEnter", function(self)
            -- ANCHOR_RIGHT, not TOP: this dropdown sits near the frame top, so a
            -- tall ANCHOR_TOP tooltip gets clamped down over the dropdown itself.
            -- Sub-headers use the CC green accent explicitly (color=themeColor)
            -- rather than the shared accent line, which tracks the mode colour.
            DF.GUI:ShowTooltip(self, {
                title = L["Smart Resurrection"],
                anchor = "ANCHOR_RIGHT",
                lines = {
                    L["When using any spell binding on a dead target,"],
                    L["cast a resurrection spell instead."],
                    " ",
                    { text = L["Disabled"] .. ":", color = themeColor },
                    L["Bindings only cast their assigned spell"],
                    " ",
                    { text = L["Res + Mass"] .. ":", color = themeColor },
                    L["Dead + Out of combat: Cast Mass Res or normal Res"],
                    " ",
                    { text = L["Res + Mass + Combat"] .. ":", color = themeColor },
                    L["Dead + In combat: Cast Battle Res (Rebirth, etc.)"],
                    L["Dead + Out of combat: Cast Mass Res or normal Res"],
                },
            })
        end)
        smartResBtn:HookScript("OnLeave", function()
            DF.GUI:HideTooltip()
        end)
    end

    CC.smartResDropdown = smartResDropdown
    CC.UpdateSmartResText = UpdateSmartResText
    
    -- Search box (right side of row 2)
    local searchBox = CreateFrame("EditBox", nil, row2, "BackdropTemplate")
    searchBox:SetPoint("RIGHT", 0, 0)
    searchBox:SetSize(120, 16)
    DF.GUI:StyleEditBox(searchBox, { skipFont = true })
    DF.GUI:SetSettingsFont(searchBox, 10, "")
    searchBox:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    searchBox:SetTextInsets(18, 6, 0, 0)
    searchBox:SetAutoFocus(false)
    
    local searchIcon = searchBox:CreateTexture(nil, "OVERLAY")
    searchIcon:SetPoint("LEFT", 4, 0)
    searchIcon:SetSize(10, 10)
    searchIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\search")
    searchIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local searchPlaceholder = searchBox:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    searchPlaceholder:SetPoint("LEFT", 18, 0)
    searchPlaceholder:SetText(L["Search..."])
    searchPlaceholder:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    searchBox:SetScript("OnEditFocusGained", function() searchPlaceholder:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function() 
        if searchBox:GetText() == "" then searchPlaceholder:Show() end 
    end)
    searchBox:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        if text == "" then searchPlaceholder:Show() else searchPlaceholder:Hide() end
        CC:RefreshSpellGrid()
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    
    CC.searchBox = searchBox
    CC.enableCb = enableCb
    CC.downCb = downCb
    CC.quickBindCb = quickBindCb
    
    -- =========================================================================
    -- MAIN CONTENT: Side-by-side layout
    -- =========================================================================
    local mainContent = CreateFrame("Frame", nil, parent)
    mainContent:SetPoint("TOPLEFT", 10, -60)
    mainContent:SetPoint("BOTTOMRIGHT", -10, 10)
    CC.mainContent = mainContent
    
    -- =========================================================================
    -- LEFT PANEL: Active Bindings (collapsible)
    -- =========================================================================
    local leftPanel = CreateFrame("Frame", nil, mainContent, "BackdropTemplate")
    leftPanel:SetPoint("TOPLEFT", 0, 0)
    leftPanel:SetPoint("BOTTOMLEFT", 0, 0)
    leftPanel:SetWidth(LEFT_PANEL_WIDTH)
    DF.GUI:CreatePanelBackdrop(leftPanel, {
        bgColor = DF.GUI.Colors.background, bgAlpha = 0.95,
        borderColor = {C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.8},
    })
    CC.leftPanel = leftPanel
    CC.bindingsSection = leftPanel  -- Alias for compatibility
    
    -- Panel header
    local bindingsHeader = CreateFrame("Frame", nil, leftPanel)
    bindingsHeader:SetPoint("TOPLEFT", 0, 0)
    bindingsHeader:SetPoint("TOPRIGHT", 0, 0)
    bindingsHeader:SetHeight(28)
    
    -- Collapse/Expand button (left side of header)
    local collapseBtn = CreateFrame("Button", nil, bindingsHeader, "BackdropTemplate")
    collapseBtn:SetPoint("LEFT", 4, 0)
    collapseBtn:SetSize(20, 20)
    DF.GUI:CreateElementBackdrop(collapseBtn, {
        bgColor     = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1 },
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5 },
    })
    
    local collapseIcon = collapseBtn:CreateTexture(nil, "OVERLAY")
    collapseIcon:SetPoint("CENTER")
    collapseIcon:SetSize(12, 12)
    collapseIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
    collapseIcon:SetTexCoord(1, 0, 0, 1)  -- Flip horizontally to point left (expanded state)
    collapseIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    collapseBtn.icon = collapseIcon
    
    collapseBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.8)
        self.icon:SetVertexColor(themeColor.r, themeColor.g, themeColor.b)
    end)
    collapseBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        self.icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end)
    
    CC.collapseBtn = collapseBtn
    CC.collapseIcon = collapseIcon
    CC.leftPanelCollapsed = false
    
    -- Title
    local bindingsTitle = bindingsHeader:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    bindingsTitle:SetPoint("LEFT", collapseBtn, "RIGHT", 6, 0)
    bindingsTitle:SetText(L["Active Bindings"])
    bindingsTitle:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    CC.bindingsTitle = bindingsTitle
    
    -- Hint text
    local bindingsHint = bindingsHeader:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    bindingsHint:SetPoint("LEFT", bindingsTitle, "RIGHT", 6, 0)
    bindingsHint:SetText(L["— click to edit"])
    bindingsHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    CC.bindingsHint = bindingsHint
    
    -- Clear All button
    local clearAllBtn = CreateFrame("Button", nil, bindingsHeader, "BackdropTemplate")
    clearAllBtn:SetPoint("RIGHT", -6, 0)
    -- Destructive Clear: shared danger tone (red label/icon + red hover) + delete
    -- icon; tooltip via HookScript so it composes with the styler's hover.
    DF.GUI:StyleButton(clearAllBtn, {
        width = 72, height = 18,
        tone = "danger",
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\delete", size = 12 },
        text = L["Clear All"],
    })
    clearAllBtn:HookScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = L["Clear All Bindings"],
            tone = "danger",
            lines = { L["Remove all bindings from the current profile."] },
        })
    end)
    clearAllBtn:HookScript("OnLeave", function() DF.GUI:HideTooltip() end)
    clearAllBtn:SetScript("OnClick", function()
        CC:ShowClearAllConfirmation()
    end)
    CC.clearAllBtn = clearAllBtn
    
    -- Bindings scroll frame (full height)
    local bindingsScroll = CreateFrame("ScrollFrame", nil, leftPanel, "ScrollFrameTemplate")
    bindingsScroll:SetPoint("TOPLEFT", 5, -30)
    bindingsScroll:SetPoint("BOTTOMRIGHT", -25, 5)
    
    DF.GUI.StyleScrollBar(bindingsScroll)

    local bindingsContent = CreateFrame("Frame", nil, bindingsScroll)
    bindingsContent:SetWidth(LEFT_PANEL_WIDTH - 35)
    bindingsContent:SetHeight(1)
    bindingsScroll:SetScrollChild(bindingsContent)
    
    CC.bindingsScroll = bindingsScroll
    CC.bindingsContent = bindingsContent
    
    -- Mouse wheel scrolling for bindings
    bindingsScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = self:GetVerticalScrollRange()
        if maxScroll <= 0 then return end
        local currentScroll = self:GetVerticalScroll()
        local scrollStep = BINDING_ROW_HEIGHT
        local newScroll = currentScroll - (delta * scrollStep)
        newScroll = math.max(0, math.min(newScroll, maxScroll))
        self:SetVerticalScroll(newScroll)
    end)
    
    leftPanel:EnableMouseWheel(true)
    leftPanel:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = bindingsScroll:GetVerticalScrollRange()
        if maxScroll <= 0 then return end
        local currentScroll = bindingsScroll:GetVerticalScroll()
        local scrollStep = BINDING_ROW_HEIGHT
        local newScroll = currentScroll - (delta * scrollStep)
        newScroll = math.max(0, math.min(newScroll, maxScroll))
        bindingsScroll:SetVerticalScroll(newScroll)
    end)
    
    -- Collapse/Expand functionality
    local function ToggleLeftPanel()
        CC.leftPanelCollapsed = not CC.leftPanelCollapsed
        
        if CC.leftPanelCollapsed then
            -- Collapse
            leftPanel:SetWidth(LEFT_PANEL_COLLAPSED_WIDTH)
            collapseIcon:SetTexCoord(0, 1, 0, 1)  -- Point right (expand direction)
            bindingsTitle:Hide()
            bindingsHint:Hide()
            clearAllBtn:Hide()
            bindingsContent:SetWidth(LEFT_PANEL_COLLAPSED_WIDTH - 20)  -- Narrower for icons only
            -- Adjust scroll frame to use less padding when collapsed
            bindingsScroll:SetPoint("TOPLEFT", 3, -30)
            bindingsScroll:SetPoint("BOTTOMRIGHT", -18, 5)
            -- Update binding rows to collapsed mode
            CC:RefreshActiveBindings()
        else
            -- Expand
            leftPanel:SetWidth(LEFT_PANEL_WIDTH)
            collapseIcon:SetTexCoord(1, 0, 0, 1)  -- Point left (collapse direction)
            bindingsTitle:Show()
            bindingsHint:Show()
            clearAllBtn:Show()
            bindingsContent:SetWidth(LEFT_PANEL_WIDTH - 35)
            -- Restore scroll frame padding
            bindingsScroll:SetPoint("TOPLEFT", 5, -30)
            bindingsScroll:SetPoint("BOTTOMRIGHT", -25, 5)
            -- Update binding rows to expanded mode
            CC:RefreshActiveBindings()
        end
    end
    
    collapseBtn:SetScript("OnClick", ToggleLeftPanel)
    CC.ToggleLeftPanel = ToggleLeftPanel
    
    -- Store expand button references for compatibility
    CC.bindingsExpanded = true  -- Now means "not collapsed"
    CC.expandBtn = collapseBtn
    CC.expandIcon = collapseIcon
    
    -- =========================================================================
    -- RIGHT PANEL: Selection Section (Tabs + Spell Grid)
    -- =========================================================================
    local rightPanel = CreateFrame("Frame", nil, mainContent)
    rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 5, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", 0, 0)
    CC.rightPanel = rightPanel
    CC.selectionSection = rightPanel  -- Alias for compatibility
    local selectionSection = rightPanel  -- Local alias for use below
    
    -- Selection header - TWO ROWS: tabs row + filter row
    local selectionHeader = CreateFrame("Frame", nil, rightPanel, "BackdropTemplate")
    selectionHeader:SetPoint("TOPLEFT", 0, 0)
    selectionHeader:SetPoint("TOPRIGHT", 0, 0)
    selectionHeader:SetHeight(60)  -- Two rows: 28 + 28 + spacing
    -- Solid panel fill, no border (matches the original bgFile-only backdrop).
    DF.GUI:CreatePanelBackdrop(selectionHeader, { bgAlpha = 1, border = false })
    selectionHeader:SetFrameLevel(rightPanel:GetFrameLevel() + 1)
    CC.selectionHeader = selectionHeader
    
    -- ROW 1: Tabs
    local tabsRow = CreateFrame("Frame", nil, selectionHeader)
    tabsRow:SetPoint("TOPLEFT", 0, 0)
    tabsRow:SetPoint("TOPRIGHT", 0, 0)
    tabsRow:SetHeight(28)

    -- Baseline under the tabs (the active tab's underline sits on it) — matches AD/TD/Pinned.
    local tabBaseline = tabsRow:CreateTexture(nil, "ARTWORK")
    tabBaseline:SetTexture("Interface\\Buttons\\WHITE8x8")
    tabBaseline:SetHeight(1)
    tabBaseline:SetPoint("BOTTOMLEFT", 0, 0)
    tabBaseline:SetPoint("BOTTOMRIGHT", 0, 0)
    tabBaseline:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    
    -- ROW 2: Filters and view controls
    local filterRow = CreateFrame("Frame", nil, selectionHeader)
    filterRow:SetPoint("TOPLEFT", 0, -30)
    filterRow:SetPoint("TOPRIGHT", 0, -30)
    filterRow:SetHeight(26)
    CC.filterRow = filterRow
    
    -- Helper to create a tab button
    local function CreateTabButton(parent, text, width)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        -- Shared underline-tab style (CC green accent), matching the Aura/Text
        -- Designer + Pinned Frames tabs. StyleButton provides :SetActive.
        DF.GUI:StyleButton(btn, { tab = true, text = text, width = width, height = 28, accent = CC.ACCENT, font = "DFFontHighlight" })
        
        -- (label handled by StyleButton)
        
        -- (hover handled by StyleButton)
        
        -- (active state handled by StyleButton tab mode)
        
        return btn
    end
    
    -- Helper to create a dropdown button.
    -- Delegates to the shared DF.GUI:CreateDropdown builder (inline opener,
    -- CC green accent). Preserves the legacy signature
    -- (parent, defaultText, width, {{key=,label=},...}, onSelect) and the
    -- return contract: callers do :Hide()/:SetShown()/:SetPoint()/:SetValue(key).
    -- Note: this file shadows the global CreateDropdown, so the shared builder
    -- must be called explicitly as DF.GUI:CreateDropdown.
    local function CreateDropdown(parent, defaultText, width, options, onSelect)
        -- Map the {key,label} array into the builder's value->display table
        -- plus an explicit _order so menu order matches the source array.
        local builderOptions = { _order = {} }
        for _, opt in ipairs(options) do
            builderOptions[opt.key] = opt.label
            table.insert(builderOptions._order, opt.key)
        end

        -- Current selection lives locally; seed from the option whose label
        -- matches defaultText, else the first option. customGet/customSet keep
        -- the button text + selected-item highlight in sync and fire onSelect.
        local currentKey = options[1] and options[1].key
        for _, opt in ipairs(options) do
            if opt.label == defaultText then currentKey = opt.key break end
        end

        local container = DF.GUI:CreateDropdown(parent, nil, builderOptions, nil, nil, nil,
            function() return currentKey end,
            function(key)
                currentKey = key
                if onSelect then onSelect(key) end
            end,
            { inline = true, accent = CC.ACCENT })

        container:SetWidth(width)

        -- Legacy contract: callers (e.g. BindingEditor) call dropdown:SetValue(key)
        -- to set the selection without firing onSelect.
        container.SetValue = function(_, key)
            currentKey = key
            container:UpdateText()
        end

        return container
    end
    
    -- Helper to create view toggle buttons
    local function CreateViewButton(parent, tooltip)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        -- Shared styler: backdrop + accent-wash hover + the active/selected look.
        -- Icon-only (no text=); the icon textures/text are added by callers.
        DF.GUI:StyleButton(btn, { width = 22, height = 22, accent = CC.ACCENT })
        btn.iconLines = {}

        -- Tooltip rides on top of the styler's own hover scripts.
        if tooltip then
            btn:HookScript("OnEnter", function(self)
                DF.GUI:ShowTooltip(self, { title = tooltip })
            end)
            btn:HookScript("OnLeave", function()
                DF.GUI:HideTooltip()
            end)
        end

        -- Route the selected state through the styler's SetActive (accent fill +
        -- toned accent border), then tint the icon lines / AZ text to match.
        local styleSetActive = btn.SetActive
        function btn:SetActive(active)
            self.isActive = active
            styleSetActive(self, active)
            if active then
                for _, line in ipairs(self.iconLines) do
                    line:SetColorTexture(themeColor.r, themeColor.g, themeColor.b, 1)
                end
                if self.azText then self.azText:SetTextColor(themeColor.r, themeColor.g, themeColor.b) end
            else
                for _, line in ipairs(self.iconLines) do
                    line:SetColorTexture(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
                end
                if self.azText then self.azText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b) end
            end
        end

        return btn
    end
    
    -- Create tabs (in tabs row)
    local spellsTab = CreateTabButton(tabsRow, L["Spells"], 58)
    spellsTab:SetPoint("BOTTOMLEFT", 4, 0)
    spellsTab:SetActive(true)
    CC.spellsTab = spellsTab
    
    local macrosTab = CreateTabButton(tabsRow, L["Macros"], 60)
    macrosTab:SetPoint("BOTTOMLEFT", spellsTab, "BOTTOMRIGHT", 4, 0)
    macrosTab:SetActive(false)
    CC.macrosTab = macrosTab
    
    local itemsTab = CreateTabButton(tabsRow, L["Items"], 52)
    itemsTab:SetPoint("BOTTOMLEFT", macrosTab, "BOTTOMRIGHT", 4, 0)
    itemsTab:SetActive(false)
    CC.itemsTab = itemsTab
    
    local profilesTab = CreateTabButton(tabsRow, L["Profiles"], 66)
    profilesTab:SetPoint("BOTTOMLEFT", itemsTab, "BOTTOMRIGHT", 4, 0)
    profilesTab:SetActive(false)
    CC.profilesTab = profilesTab
    
    CC.activeTab = "spells"
    CC.selectedMacroSource = "all"
    
    -- Macro-specific controls (in filter row, anchored from LEFT to avoid overlap)
    -- Macro source dropdown (leftmost)
    local macroSourceDropdown = CreateDropdown(filterRow, L["All"], 65, {
        {key = "all", label = L["All"]},
        {key = "custom", label = L["Custom"]},
        {key = "global_import", label = L["General"]},
        {key = "char_import", label = L["Character"]},
    }, function(key)
        CC.selectedMacroSource = key
        CC:RefreshSpellGrid()
    end)
    macroSourceDropdown:Hide()
    CC.macroSourceDropdown = macroSourceDropdown
    
    -- New Macro button (green, prominent)
    local newMacroBtn = CreateFrame("Button", nil, filterRow, "BackdropTemplate")
    -- Green primary CTA: shared styler owns fill/border/hover + the leading icon
    -- and centred label. Force white icon/label to match the original.
    DF.GUI:StyleButton(newMacroBtn, {
        width = 55, height = 20, primary = true, accent = CC.ACCENT,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 12, color = { r = 1, g = 1, b = 1 } },
        text = L["New"],
    })
    newMacroBtn.Text:SetTextColor(1, 1, 1)
    newMacroBtn:SetScript("OnClick", function()
        CC:ShowMacroEditorDialog()
    end)
    newMacroBtn:Hide()
    CC.newMacroBtn = newMacroBtn
    
    -- Import button
    local importMacroBtn = CreateFrame("Button", nil, filterRow, "BackdropTemplate")
    -- Shared styler owns fill/border/hover + the leading icon and centred label
    -- (neutral C_TEXT icon/label is the styler default).
    DF.GUI:StyleButton(importMacroBtn, {
        width = 60, height = 20, accent = CC.ACCENT,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\download", size = 12, color = C_TEXT },
        text = L["Import"],
    })
    importMacroBtn:SetScript("OnClick", function()
        CC:ShowImportMacroDialog()
    end)
    importMacroBtn:Hide()
    CC.importMacroBtn = importMacroBtn
    
    -- Quick Macro button
    local quickMacroBtn = CreateFrame("Button", nil, filterRow, "BackdropTemplate")
    -- Shared styler owns fill/border/hover + the leading icon and centred label.
    DF.GUI:StyleButton(quickMacroBtn, {
        width = 86, height = 20, accent = CC.ACCENT,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\edit", size = 12, color = C_TEXT },
        text = L["Quick Macro"],
    })
    quickMacroBtn:HookScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = L["Quick Macro"],
            lines = { L["Create a simple macro without opening the full editor."] },
        })
    end)
    quickMacroBtn:HookScript("OnLeave", function(self)
        DF.GUI:HideTooltip()
    end)
    quickMacroBtn:SetScript("OnClick", function()
        CC:ShowQuickMacroDialog()
    end)
    quickMacroBtn:Hide()
    CC.quickMacroBtn = quickMacroBtn
    
    -- Macro hint (after buttons)
    local macroHint = filterRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    macroHint:SetText(L["Click macro to bind"])
    macroHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    macroHint:Hide()
    CC.macroHint = macroHint
    
    -- Remove macroSourceLabel since dropdown is self-explanatory
    local macroSourceLabel = filterRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    macroSourceLabel:SetPoint("LEFT", 0, 0)  -- Hidden, not used
    macroSourceLabel:SetText("")
    macroSourceLabel:Hide()
    CC.macroSourceLabel = macroSourceLabel
    
    -- =============================================
    -- SPELLS TAB CONTROLS (in filter row, anchor left of view buttons)
    -- =============================================
    -- "Click spell to bind" hint
    local bindHint = filterRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    -- Anchored dynamically after view buttons are created
    bindHint:SetText(L["Click spell to bind"])
    bindHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Show dropdown
    local showDropdown = CreateDropdown(filterRow, L["All"], 70, {
        {key = "all", label = L["All"]},
        {key = "helpful", label = L["Helpful"]},
        {key = "harmful", label = L["Harmful"]},
    }, function(key)
        CC.selectedSpellType = key
        CC:RefreshSpellGrid()
    end)
    CC.showDropdown = showDropdown
    CC.selectedSpellType = "all"
    
    local showLabel = filterRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    showLabel:SetText(L["Show:"])
    showLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- =============================================
    -- ITEMS TAB CONTROLS
    -- =============================================
    local itemsHint = filterRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    itemsHint:SetText(L["Click item slot to bind"])
    itemsHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    itemsHint:Hide()
    CC.itemsHint = itemsHint
    
    -- Tab switching function (defined after all controls exist)
    local function SetActiveTab(tabName)
        CC.activeTab = tabName
        spellsTab:SetActive(tabName == "spells")
        macrosTab:SetActive(tabName == "macros")
        itemsTab:SetActive(tabName == "items")
        profilesTab:SetActive(tabName == "profiles")
        
        -- Toggle spell controls
        local showSpellControls = (tabName == "spells")
        showLabel:SetShown(showSpellControls)
        showDropdown:SetShown(showSpellControls)
        bindHint:SetShown(showSpellControls)
        
        -- Toggle macro controls
        local showMacroControls = (tabName == "macros")
        macroSourceLabel:SetShown(showMacroControls)
        macroSourceDropdown:SetShown(showMacroControls)
        newMacroBtn:SetShown(showMacroControls)
        importMacroBtn:SetShown(showMacroControls)
        quickMacroBtn:SetShown(showMacroControls)
        macroHint:SetShown(showMacroControls)
        
        -- Toggle items controls
        local showItemsControls = (tabName == "items")
        itemsHint:SetShown(showItemsControls)
        
        -- Toggle profiles panel
        local showProfiles = (tabName == "profiles")
        if CC.profilesPanel then
            CC.profilesPanel:SetShown(showProfiles)
        end
        if CC.spellGrid then
            CC.spellGrid:SetShown(not showProfiles)
        end
        
        if not showProfiles then
            CC:RefreshSpellGrid()
        else
            CC:RefreshProfilesPanel()
        end
    end
    
    spellsTab:SetScript("OnClick", function() SetActiveTab("spells") end)
    macrosTab:SetScript("OnClick", function() SetActiveTab("macros") end)
    itemsTab:SetScript("OnClick", function() SetActiveTab("items") end)
    profilesTab:SetScript("OnClick", function() SetActiveTab("profiles") end)
    
    -- Store reference for external access (e.g., from profile settings cogwheel)
    CC.SetActiveTab = SetActiveTab
    
    -- View buttons (in filter row, far right side)
    local alphabeticalSortBtn = CreateViewButton(filterRow, L["A-Z"])
    alphabeticalSortBtn:SetPoint("RIGHT", -4, 0)
    local az = alphabeticalSortBtn:CreateFontString(nil, "ARTWORK", "DFFontNormalSmall")
    az:SetPoint("CENTER", 0, 0)
    az:SetText("AZ")
    az:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
    alphabeticalSortBtn.azText = az
    
    local sectionedSortBtn = CreateViewButton(filterRow, L["Categories"])
    sectionedSortBtn:SetPoint("RIGHT", alphabeticalSortBtn, "LEFT", -2, 0)
    local h1 = sectionedSortBtn:CreateTexture(nil, "ARTWORK")
    h1:SetSize(4, 2)
    h1:SetPoint("TOPLEFT", sectionedSortBtn, "CENTER", -6, 4)
    h1:SetColorTexture(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
    table.insert(sectionedSortBtn.iconLines, h1)
    local l1 = sectionedSortBtn:CreateTexture(nil, "ARTWORK")
    l1:SetSize(10, 2)
    l1:SetPoint("CENTER", 1, 0)
    l1:SetColorTexture(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
    table.insert(sectionedSortBtn.iconLines, l1)
    local h2 = sectionedSortBtn:CreateTexture(nil, "ARTWORK")
    h2:SetSize(4, 2)
    h2:SetPoint("TOPLEFT", sectionedSortBtn, "CENTER", -6, -4)
    h2:SetColorTexture(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
    table.insert(sectionedSortBtn.iconLines, h2)
    
    local gridViewBtn = CreateViewButton(filterRow, L["Grid"])
    gridViewBtn:SetPoint("RIGHT", sectionedSortBtn, "LEFT", -8, 0)
    local positions = {{-4, 3}, {4, 3}, {-4, -5}, {4, -5}}
    for _, pos in ipairs(positions) do
        local square = gridViewBtn:CreateTexture(nil, "ARTWORK")
        square:SetSize(5, 5)
        square:SetPoint("CENTER", pos[1], pos[2])
        square:SetColorTexture(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
        table.insert(gridViewBtn.iconLines, square)
    end
    
    local listViewBtn = CreateViewButton(filterRow, L["List"])
    listViewBtn:SetPoint("RIGHT", gridViewBtn, "LEFT", -2, 0)
    for i = 0, 2 do
        local line = listViewBtn:CreateTexture(nil, "ARTWORK")
        line:SetSize(12, 2)
        line:SetPoint("CENTER", 0, 3 - i * 4)
        line:SetColorTexture(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
        table.insert(listViewBtn.iconLines, line)
    end
    
    -- Layout/Sort toggle functions
    local function SetActiveLayout(layout)
        listViewBtn:SetActive(layout == "list")
        gridViewBtn:SetActive(layout == "grid")
    end
    
    local function SetActiveSort(sort)
        sectionedSortBtn:SetActive(sort == "sectioned")
        alphabeticalSortBtn:SetActive(sort == "alphabetical")
    end
    
    listViewBtn:SetScript("OnClick", function()
        CC.viewLayout = "list"
        CC.db.options.viewLayout = "list"
        SetActiveLayout("list")
        CC:RefreshSpellGrid()
    end)
    
    gridViewBtn:SetScript("OnClick", function()
        CC.viewLayout = "grid"
        CC.db.options.viewLayout = "grid"
        SetActiveLayout("grid")
        CC:RefreshSpellGrid()
    end)
    
    sectionedSortBtn:SetScript("OnClick", function()
        CC.viewSort = "sectioned"
        CC.db.options.viewSort = "sectioned"
        SetActiveSort("sectioned")
        CC:RefreshSpellGrid()
    end)
    
    alphabeticalSortBtn:SetScript("OnClick", function()
        CC.viewSort = "alphabetical"
        CC.db.options.viewSort = "alphabetical"
        SetActiveSort("alphabetical")
        CC:RefreshSpellGrid()
    end)
    
    CC.gridViewBtn = gridViewBtn
    CC.listViewBtn = listViewBtn
    CC.sectionedSortBtn = sectionedSortBtn
    CC.alphabeticalSortBtn = alphabeticalSortBtn
    CC.SetActiveLayout = SetActiveLayout
    CC.SetActiveSort = SetActiveSort
    
    -- Now anchor the tab-specific controls relative to view buttons
    bindHint:SetPoint("RIGHT", listViewBtn, "LEFT", -15, 0)
    showDropdown:SetPoint("RIGHT", bindHint, "LEFT", -8, 0)
    showLabel:SetPoint("RIGHT", showDropdown, "LEFT", -4, 0)
    itemsHint:SetPoint("RIGHT", listViewBtn, "LEFT", -15, 0)

    -- Macro controls: right-aligned to match the Spells/Items tabs. Anchored
    -- here (after the view buttons exist) and chained leftward from the hint.
    macroHint:SetPoint("RIGHT", listViewBtn, "LEFT", -15, 0)
    quickMacroBtn:SetPoint("RIGHT", macroHint, "LEFT", -12, 0)
    importMacroBtn:SetPoint("RIGHT", quickMacroBtn, "LEFT", -4, 0)
    newMacroBtn:SetPoint("RIGHT", importMacroBtn, "LEFT", -4, 0)
    macroSourceDropdown:SetPoint("RIGHT", newMacroBtn, "LEFT", -8, 0)
    
    -- Load saved preferences
    CC.viewLayout = CC.db.options.viewLayout or "grid"
    CC.viewSort = CC.db.options.viewSort or "sectioned"
    
    -- =========================================================================
    -- SPELL GRID CONTAINER
    -- =========================================================================
    local gridContainer = CreateFrame("Frame", nil, selectionSection, "BackdropTemplate")
    gridContainer:SetPoint("TOPLEFT", selectionHeader, "BOTTOMLEFT", 0, -2)
    gridContainer:SetPoint("BOTTOMRIGHT", 0, 0)
    DF.GUI:CreatePanelBackdrop(gridContainer, {
        bgColor = DF.GUI.Colors.background, bgAlpha = 0.5,
        borderColor = {C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5},
    })
    CC.gridContainer = gridContainer
    
    -- Scroll frame for spell grid
    local scrollFrame = CreateFrame("ScrollFrame", nil, gridContainer, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 5, -5)
    scrollFrame:SetPoint("BOTTOMRIGHT", -25, 5)
    
    local scrollContent = CreateFrame("Frame", nil, scrollFrame)
    scrollContent:SetWidth(scrollFrame:GetWidth() - 10)
    scrollContent:SetHeight(1)
    scrollFrame:SetScrollChild(scrollContent)
    DF.GUI.StyleScrollBar(scrollFrame)

    CC.scrollContent = scrollContent
    CC.scrollFrame = scrollFrame

    -- Mouse wheel scrolling with smaller step
    -- Override the template's default scroll behavior
    local SCROLL_STEP = 30 -- Smaller step for smoother feel
    
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = self:GetVerticalScrollRange()
        if maxScroll <= 0 then return end
        
        local currentScroll = self:GetVerticalScroll()
        local newScroll = currentScroll - (delta * SCROLL_STEP)
        newScroll = math.max(0, math.min(newScroll, maxScroll))
        self:SetVerticalScroll(newScroll)
    end)
    
    -- Also handle on container for when cursor is outside scroll frame
    gridContainer:EnableMouseWheel(true)
    gridContainer:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = scrollFrame:GetVerticalScrollRange()
        if maxScroll <= 0 then return end
        
        local currentScroll = scrollFrame:GetVerticalScroll()
        local newScroll = currentScroll - (delta * SCROLL_STEP)
        newScroll = math.max(0, math.min(newScroll, maxScroll))
        scrollFrame:SetVerticalScroll(newScroll)
    end)
    
    -- Handle resize
    local resizeTimer = nil
    gridContainer:SetScript("OnSizeChanged", function(self, width, height)
        if resizeTimer then resizeTimer:Cancel() end
        resizeTimer = C_Timer.NewTimer(0.05, function()
            resizeTimer = nil
            if scrollFrame and scrollContent then
                scrollContent:SetWidth(scrollFrame:GetWidth() - 10)
            end
            if CC.RefreshSpellGrid then
                CC:RefreshSpellGrid(true)
            end
        end)
    end)
    
    -- =========================================================================
    -- PROFILES PANEL (hidden by default, shown when Profiles tab is active)
    -- =========================================================================
    local profilesPanel = CreateFrame("Frame", nil, selectionSection, "BackdropTemplate")
    profilesPanel:SetPoint("TOPLEFT", selectionHeader, "BOTTOMLEFT", 0, -2)
    profilesPanel:SetPoint("BOTTOMRIGHT", 0, 0)
    DF.GUI:CreatePanelBackdrop(profilesPanel, {
        bgColor = DF.GUI.Colors.background, bgAlpha = 0.5,
        borderColor = {C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5},
    })
    profilesPanel:Hide()
    CC.profilesPanel = profilesPanel
    
    -- Store reference for spellGrid (so we can show/hide it)
    CC.spellGrid = gridContainer
    
    -- Create the keybind capture popup
    CC:CreateKeybindPopup()
    
    -- Create the profiles panel content
    CC:CreateProfilesPanelContent()
end

-- =========================================================================

-- REFRESH ACTIVE BINDINGS LIST
-- =========================================================================
function CC:RefreshActiveBindings()
    if not self.bindingsContent then return end
    
    -- Clear existing rows
    for _, row in ipairs(bindingRows) do
        row:Hide()
        row:SetParent(nil)
    end
    wipe(bindingRows)
    
    -- Get all bindings
    local bindings = self.db.bindings or {}
    
    -- Count enabled bindings (default to enabled if not specified)
    local enabledCount = 0
    for _, binding in ipairs(bindings) do
        if binding.enabled ~= false then  -- Default to enabled
            enabledCount = enabledCount + 1
        end
    end
    
    -- Update title with count (only shown when expanded)
    if self.bindingsTitle then
        self.bindingsTitle:SetText(format(L["Active Bindings (%d)"], enabledCount))
    end
    
    -- Determine content width based on collapsed state
    local isCollapsed = self.leftPanelCollapsed
    local contentWidth
    if isCollapsed then
        contentWidth = LEFT_PANEL_COLLAPSED_WIDTH - 20  -- Narrower for icons only
    else
        contentWidth = LEFT_PANEL_WIDTH - 35
    end
    self.bindingsContent:SetWidth(contentWidth)
    
    -- Create rows for each binding
    local yOffset = 0
    local rowHeight = isCollapsed and 60 or BINDING_ROW_HEIGHT  -- Taller rows when collapsed for icon + text
    
    for i, binding in ipairs(bindings) do
        if binding.enabled ~= false then  -- Default to enabled
            if isCollapsed then
                -- Create collapsed binding row (icon + keybind vertically)
                local row = self:CreateCollapsedBindingRow(self.bindingsContent, binding, i)
                row:SetPoint("TOPLEFT", 0, -yOffset)
                row:SetPoint("TOPRIGHT", 0, -yOffset)
                table.insert(bindingRows, row)
                yOffset = yOffset + rowHeight
            else
                -- Create full binding row
                local row = self:CreateBindingRow(self.bindingsContent, binding, i)
                row:SetPoint("TOPLEFT", 0, -yOffset)
                row:SetPoint("TOPRIGHT", 0, -yOffset)
                table.insert(bindingRows, row)
                yOffset = yOffset + BINDING_ROW_HEIGHT
            end
        end
    end
    
    -- Update content height
    self.bindingsContent:SetHeight(math.max(yOffset, 1))
end

-- Create a collapsed binding row (icon + keybind stacked vertically)
function CC:CreateCollapsedBindingRow(parent, binding, index)
    local C = self.UI_COLORS
    local themeColor = C.theme
    
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(58)
    DF.GUI:CreateElementBackdrop(row, {
        bgColor     = { C.element.r, C.element.g, C.element.b, 0.8 },
        borderColor = { C.border.r, C.border.g, C.border.b, 0.5 },
    })
    
    -- Icon (centered, larger)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(36, 36)
    icon:SetPoint("TOP", 0, -3)
    
    -- Icon for the binding's action (shared resolver in Bindings.lua)
    icon:SetTexture(CC:GetBindingDisplayIcon(binding))
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    
    -- Keybind text (below icon, centered)
    local bindText = ""
    if binding.bindType == "mouse" then
        local modDisplay = ""
        if binding.modifiers and binding.modifiers ~= "" then
            local mods = binding.modifiers:lower()
            if mods:find("shift") then modDisplay = modDisplay .. "S+" end
            if mods:find("ctrl") then modDisplay = modDisplay .. "C+" end
            if mods:find("alt") then modDisplay = modDisplay .. "A+" end
            if mods:find("meta") then modDisplay = modDisplay .. "⌘+" end
        end
        local buttonName = CC.BUTTON_DISPLAY_NAMES[binding.button] or binding.button
        bindText = modDisplay .. buttonName
    elseif binding.bindType == "key" then
        local modDisplay = ""
        if binding.modifiers and binding.modifiers ~= "" then
            local mods = binding.modifiers:lower()
            if mods:find("shift") then modDisplay = modDisplay .. "S+" end
            if mods:find("ctrl") then modDisplay = modDisplay .. "C+" end
            if mods:find("alt") then modDisplay = modDisplay .. "A+" end
            if mods:find("meta") then modDisplay = modDisplay .. "⌘+" end
        end
        local keyName = CC.KEY_DISPLAY_NAMES[binding.key] or binding.key
        bindText = modDisplay .. keyName
    elseif binding.bindType == "scroll" then
        local modDisplay = ""
        if binding.modifiers and binding.modifiers ~= "" then
            local mods = binding.modifiers:lower()
            if mods:find("shift") then modDisplay = modDisplay .. "S+" end
            if mods:find("ctrl") then modDisplay = modDisplay .. "C+" end
            if mods:find("alt") then modDisplay = modDisplay .. "A+" end
            if mods:find("meta") then modDisplay = modDisplay .. "⌘+" end
        end
        local scrollName = CC.SCROLL_DISPLAY_NAMES[binding.key] or binding.key
        bindText = modDisplay .. scrollName
    end
    
    local keybind = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    keybind:SetPoint("BOTTOM", 0, 3)
    keybind:SetJustifyH("CENTER")
    keybind:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    keybind:SetText(bindText)
    keybind:SetWidth(LEFT_PANEL_COLLAPSED_WIDTH - 16)
    keybind:SetWordWrap(false)
    
    row.binding = binding
    row.bindingIndex = index
    
    -- Hover effect
    local displayName = CC:GetActionDisplayString(binding)
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.element.r + 0.08, C.element.g + 0.08, C.element.b + 0.08, 1)
        self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.8)
        DF.GUI:ShowTooltip(self, {
            title = displayName,
            lines = {
                { text = bindText, color = themeColor },
                " ",
                { text = L["Click to edit"], hint = true },
            },
        })
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.element.r, C.element.g, C.element.b, 0.8)
        self:SetBackdropBorderColor(C.border.r, C.border.g, C.border.b, 0.5)
        DF.GUI:HideTooltip()
    end)
    
    -- Click to edit
    row:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            local bindingIcon = nil
            local actionType = binding.actionType or CC.ACTION_TYPES.SPELL
            
            if binding.spellId or binding.spellName then
                local _, displayIcon = GetSpellDisplayInfo(binding.spellId, binding.spellName)
                bindingIcon = displayIcon
            end
            
            local displayName, displayIcon, displaySpellId = GetSpellDisplayInfo(binding.spellId, binding.spellName)
            local spellInfo = {
                name = displayName or binding.spellName or binding.macroName or binding.actionType,
                spellId = binding.spellId,
                spellName = binding.spellName,
                icon = displayIcon or bindingIcon,
                isMacro = actionType == CC.ACTION_TYPES.MACRO,
                macroId = binding.macroId,
                actionType = actionType,
                displaySpellId = displaySpellId,
            }
            CC:ShowEditBindingPanel(spellInfo, binding, self.bindingIndex)
        end
    end)
    
    return row
end

-- Full UI refresh - call this when talents or profiles change
function CC:RefreshClickCastingUI()
    -- Refresh spell grid (includes bindings list)
    if self.scrollContent then
        self:RefreshSpellGrid()
    end
    
    -- Refresh profiles panel if visible
    if self.activeTab == "profiles" and self.profilesPanel then
        self:RefreshProfilesPanel()
    end
    
    -- Update profile dropdown
    if self.UpdateProfileDropdown then
        self.UpdateProfileDropdown()
    end
    
    -- Update smart res dropdown
    if self.UpdateSmartResText then
        self.UpdateSmartResText()
    end
end

-- Keybind capture popup
function CC:CreateKeybindPopup()
    if self.keybindPopup then return end
    
    local themeColor = CC.ACCENT
    local C_BACKGROUND = DF.GUI.Colors.background  -- shared neutral (identical RGB)

    -- Global capture frame (invisible, captures input anywhere on screen)
    local captureFrame = CreateFrame("Frame", "DFKeybindCapture", UIParent)
    captureFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    captureFrame:SetAllPoints(UIParent)
    captureFrame:EnableKeyboard(true)
    captureFrame:EnableMouse(true)
    captureFrame:EnableMouseWheel(true)
    captureFrame:Hide()
    
    -- Helper to check if a key is a valid bindable key
    local function IsBindableKey(key)
        -- Modifier keys shouldn't be captured as the main key
        if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL" or key == "LALT" or key == "RALT" or key == "LMETA" or key == "RMETA" then
            return false
        end
        -- Accept any other key that WoW reports - this supports international keyboards
        -- Keys like ^ on German keyboards, ñ on Spanish, etc.
        return key and key ~= ""
    end
    
    -- Keyboard capture on global frame
    captureFrame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            CC:HideKeybindPopup()
            return
        end
        
        if IsBindableKey(key) then
            CC:ProcessKeybind("key", key)
        end
    end)
    
    -- Mouse capture moved after popup creation to allow cancel button check
    
    -- Scroll wheel capture on global frame
    captureFrame:SetScript("OnMouseWheel", function(self, delta)
        local scrollKey = delta > 0 and "SCROLLUP" or "SCROLLDOWN"
        CC:ProcessKeybind("scroll", scrollKey)
    end)
    
    self.keybindCaptureFrame = captureFrame
    
    -- Visual popup (displays info, positioned on our UI)
    local popup = CreateFrame("Frame", "DFKeybindPopup", UIParent, "BackdropTemplate")
    local popupHeight = (IsMacClient and IsMacClient()) and 155 or 140
    popup:SetSize(280, popupHeight)
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(captureFrame:GetFrameLevel() + 10)
    DF.GUI:CreateElementBackdrop(popup, {
        edgeSize = 2,
        bgColor     = { C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b, 0.98 },
        borderColor = { themeColor.r, themeColor.g, themeColor.b, 1 },
    })
    popup:Hide()
    
    -- Title
    local title = popup:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    popup.title = title
    
    -- Spell name
    local spellName = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    spellName:SetPoint("TOP", title, "BOTTOM", 0, -8)
    spellName:SetTextColor(1, 1, 1)
    popup.spellName = spellName
    
    -- Instructions
    local instructions = popup:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    instructions:SetPoint("TOP", spellName, "BOTTOM", 0, -12)
    instructions:SetText(L["Press any key, mouse button, or scroll wheel\n(with modifiers if desired)"])
    instructions:SetTextColor(0.7, 0.7, 0.7)
    instructions:SetJustifyH("CENTER")
    
    -- Mac warning (only visible on Mac)
    local isMac = IsMacClient and IsMacClient()
    local macWarning = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    macWarning:SetPoint("TOP", instructions, "BOTTOM", 0, -4)
    macWarning:SetText("|c" .. DF.GUI:ToneHex("caution") .. L["Note"] .. ":|r " .. L["Cmd + Left Click unavailable on Mac"])
    macWarning:SetTextColor(0.6, 0.6, 0.6)
    if isMac then
        macWarning:Show()
    else
        macWarning:Hide()
    end
    popup.macWarning = macWarning
    
    -- Modifier display
    local modDisplay = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    modDisplay:SetPoint("TOP", instructions, "BOTTOM", 0, isMac and -18 or -8)
    modDisplay:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    popup.modDisplay = modDisplay
    
    -- Cancel button - create as separate frame at highest strata to avoid capture frame blocking
    local cancelBtn = CreateFrame("Button", "DFKeybindCancelBtn", UIParent, "BackdropTemplate")
    cancelBtn:SetFrameStrata("TOOLTIP")  -- Highest strata, above FULLSCREEN_DIALOG
    cancelBtn:SetFrameLevel(9999)  -- Very high frame level
    cancelBtn:EnableMouse(true)  -- Ensure mouse is enabled
    DF.GUI:StyleButton(cancelBtn, { width = 80, height = 24, text = L["Cancel"], accent = CC.ACCENT })
    cancelBtn:Hide()

    cancelBtn:SetScript("OnClick", function(self)
        CC:HideKeybindPopup()
    end)
    
    -- Store reference and link to popup
    popup.cancelBtn = cancelBtn
    CC.keybindCancelBtn = cancelBtn
    
    -- Update the capture frame mouse handler - check if over cancel button first
    captureFrame:SetScript("OnMouseDown", function(self, button)
        -- Check if left-clicking on the cancel button using bounds check
        if button == "LeftButton" and cancelBtn and cancelBtn:IsShown() then
            local x, y = GetCursorPosition()
            local scale = cancelBtn:GetEffectiveScale()
            x, y = x / scale, y / scale
            local left, bottom, width, height = cancelBtn:GetRect()
            if left and x >= left and x <= (left + width) and y >= bottom and y <= (bottom + height) then
                CC:HideKeybindPopup()
                return
            end
        end
        
        -- Accept standard buttons and Button4-Button31 for gaming mice
        if button == "LeftButton" or button == "RightButton" or button == "MiddleButton" or button:match("^Button%d+$") then
            CC:ProcessKeybind("mouse", button)
        end
    end)
    
    -- Update modifier display on update
    popup:SetScript("OnUpdate", function(self)
        local mods = ""
        if IsShiftKeyDown() then mods = mods .. "Shift + " end
        if IsControlKeyDown() then mods = mods .. "Ctrl + " end
        if IsAltKeyDown() then mods = mods .. "Alt + " end
        if IsMetaKeyDown() then mods = mods .. "Cmd + " end
        if mods == "" then
            self.modDisplay:SetText("")
        else
            self.modDisplay:SetText(mods .. "...")
        end
    end)
    
    self.keybindPopup = popup
end

-- Hide the keybind popup and capture frame
function CC:HideKeybindPopup()
    if self.keybindPopup then
        self.keybindPopup:Hide()
    end
    if self.keybindCaptureFrame then
        self.keybindCaptureFrame:Hide()
    end
    if self.keybindCancelBtn then
        self.keybindCancelBtn:Hide()
    end
    self.pendingSpellData = nil
end

-- Show the keybind popup for a spell or action
function CC:ShowKeybindPopup(spellData)
    if not self.keybindPopup then return end
    
    self.pendingSpellData = spellData
    
    if spellData.isItem then
        -- Item binding
        self.keybindPopup.title:SetText(L["Bind Item"])
        self.keybindPopup.spellName:SetText(spellData.name or "Unknown Item")
    elseif spellData.actionType and not spellData.spellName then
        -- Special action (Target, Menu)
        self.keybindPopup.title:SetText(L["Bind Action"])
        self.keybindPopup.spellName:SetText(spellData.name or spellData.actionType)
    else
        -- Regular spell - show current override name for display
        self.keybindPopup.title:SetText(L["Bind Spell"])
        local displayName = GetSpellDisplayInfo(spellData.spellId, spellData.spellName or spellData.name)
        self.keybindPopup.spellName:SetText(displayName or spellData.spellName or spellData.name or "Unknown")
    end
    
    -- Position centered on our click casting UI frame
    self.keybindPopup:ClearAllPoints()
    if self.clickCastUIFrame then
        self.keybindPopup:SetPoint("CENTER", self.clickCastUIFrame, "CENTER", 0, 0)
    else
        self.keybindPopup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    
    -- Show both capture frame and popup
    self.keybindCaptureFrame:Show()
    self.keybindPopup:Show()
    self.keybindPopup:Raise()
    
    -- Position and show cancel button (separate frame at TOOLTIP strata)
    if self.keybindCancelBtn then
        self.keybindCancelBtn:ClearAllPoints()
        self.keybindCancelBtn:SetPoint("BOTTOM", self.keybindPopup, "BOTTOM", 0, 10)
        self.keybindCancelBtn:Show()
        self.keybindCancelBtn:Raise()
    end
end

-- ============================================================
