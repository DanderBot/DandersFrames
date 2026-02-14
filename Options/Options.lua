local addonName, DF = ...

-- ============================================================
-- GUI PAGE SETUP - Collapsible Category System
-- ============================================================

function DF:SetupGUIPages(GUI, CreateCategory, CreateSubTab, BuildPage)
    
    -- Helper function to create a themed "Copy to Raid/Party" button for a section
    local function CreateCopyButton(parent, prefixes, sectionName)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(115, 26)
        
        -- Apply element backdrop style
        if not btn.SetBackdrop then Mixin(btn, BackdropTemplateMixin) end
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        
        -- Icon
        btn.Icon = btn:CreateTexture(nil, "OVERLAY")
        btn.Icon:SetPoint("LEFT", 8, 0)
        btn.Icon:SetSize(14, 14)
        btn.Icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\content_copy")
        
        -- Text
        btn.Text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.Text:SetPoint("LEFT", btn.Icon, "RIGHT", 4, 0)
        
        -- Update appearance based on current mode
        local function UpdateAppearance()
            local mode = GUI.SelectedMode or "party"
            local themeColor = GUI.GetThemeColor()
            
            if mode == "party" then
                btn.Text:SetText("Copy to Raid")
            else
                btn.Text:SetText("Copy to Party")
            end
            
            -- Normal state colors
            btn:SetBackdropColor(0.18, 0.18, 0.18, 1)
            btn:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.5)
            btn.Text:SetTextColor(0.6, 0.6, 0.6)
            btn.Icon:SetVertexColor(0.6, 0.6, 0.6)
        end
        
        -- Store for refresh
        btn.UpdateModeText = UpdateAppearance
        btn.rightAlign = true  -- Flag for layout system
        
        -- Hover effects
        btn:SetScript("OnEnter", function(self)
            local themeColor = GUI.GetThemeColor()
            self:SetBackdropColor(themeColor.r * 0.3, themeColor.g * 0.3, themeColor.b * 0.3, 1)
            self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
            self.Text:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
            self.Icon:SetVertexColor(themeColor.r, themeColor.g, themeColor.b)
            
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local mode = GUI.SelectedMode or "party"
            local src = mode == "party" and "Party" or "Raid"
            local dest = mode == "party" and "Raid" or "Party"
            GameTooltip:SetText("Copy " .. sectionName .. " Settings")
            GameTooltip:AddLine("Copies these settings from " .. src .. " to " .. dest .. ".", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        
        btn:SetScript("OnLeave", function(self)
            UpdateAppearance()
            GameTooltip:Hide()
        end)
        
        btn:SetScript("OnClick", function()
            local mode = GUI.SelectedMode or "party"
            local dest = mode == "party" and "Raid" or "Party"
            -- Show confirmation
            StaticPopupDialogs["DANDERSFRAMES_COPY_SECTION"] = {
                text = "Copy " .. sectionName .. " settings to " .. dest .. "?",
                button1 = "Copy",
                button2 = "Cancel",
                OnAccept = function()
                    DF:CopySectionSettings(prefixes, mode)
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
            StaticPopup_Show("DANDERSFRAMES_COPY_SECTION")
        end)
        
        -- Initial update
        UpdateAppearance()
        
        -- Register for theme updates
        if not parent.ThemeListeners then parent.ThemeListeners = {} end
        table.insert(parent.ThemeListeners, {UpdateTheme = UpdateAppearance})
        
        return btn
    end
    
    -- Define category order (updated structure)
    GUI.CategoryOrder = {"general", "clickcast", "display", "bars", "text", "auras", "indicators", "profiles"}
    
    -- ========================================
    -- CATEGORY: General
    -- ========================================
    CreateCategory("general", "General")
    
    -- ========================================
    -- CATEGORY: Display (new top-level category)
    -- ========================================
    CreateCategory("display", "Display")
    
    -- Display > Visibility
    local pageVisibility = CreateSubTab("display", "display_visibility", "Visibility")
    BuildPage(pageVisibility, function(self, db, Add, AddSpace, AddSyncPoint)
        
        -- ===== FRAME DISPLAY GROUP (Column 1) =====
        local frameDisplayGroup = GUI:CreateSettingsGroup(self.child, 280)
        frameDisplayGroup:AddWidget(GUI:CreateHeader(self.child, "Frame Display"), 40)
        
        local soloMode = frameDisplayGroup:AddWidget(GUI:CreateCheckbox(self.child, "Solo Mode", db, "soloMode", function()
            DF:UpdateAllFrames()
            DF:UpdateDefaultPlayerFrame()
        end), 30)
        soloMode.hideOn = function() return GUI.SelectedMode == "raid" end
        
        frameDisplayGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Minimap Button", db, "showMinimapButton", function()
            DF:UpdateMinimapButton()
        end), 30)
        
        local restedIndicator = frameDisplayGroup:AddWidget(GUI:CreateCheckbox(self.child, "Rested Indicator", db, "restedIndicator", function()
            DF:UpdateRestedIndicator()
        end), 30)
        restedIndicator.hideOn = function() return GUI.SelectedMode == "raid" end
        restedIndicator.disableOn = function(d) return not d.soloMode end
        restedIndicator.tooltip = "Show rested indicators when in a rested area (inn, city)."
        
        local restedIcon = frameDisplayGroup:AddWidget(GUI:CreateCheckbox(self.child, "    Show ZZZ Icon", db, "restedIndicatorIcon", function()
            DF:UpdateRestedIndicator()
        end), 30)
        restedIcon.hideOn = function() return GUI.SelectedMode == "raid" end
        restedIcon.disableOn = function(d) return not d.soloMode or not d.restedIndicator end
        restedIcon.tooltip = "Show the animated ZZZ icon on the player frame."
        
        local restedGlow = frameDisplayGroup:AddWidget(GUI:CreateCheckbox(self.child, "    Show Frame Glow", db, "restedIndicatorGlow", function()
            DF:UpdateRestedIndicator()
        end), 30)
        restedGlow.hideOn = function() return GUI.SelectedMode == "raid" end
        restedGlow.disableOn = function(d) return not d.soloMode or not d.restedIndicator end
        restedGlow.tooltip = "Show a pulsing yellow glow around the frame."
        
        local soloNote = frameDisplayGroup:AddWidget(GUI:CreateLabel(self.child, "Solo Mode: Show your player frame when not in a group.", 250), 30)
        soloNote.hideOn = function() return GUI.SelectedMode == "raid" end
        
        local hidePlayer = frameDisplayGroup:AddWidget(GUI:CreateCheckbox(self.child, "Hide Self from Party Frames", db, "hidePlayerFrame", function()
            -- Update the secure header's showPlayer attribute
            if not InCombatLockdown() and DF.partyHeader then
                DF.partyHeader:SetAttribute("showPlayer", not db.hidePlayerFrame)
            end
            -- Reapply header settings to reposition frames
            if DF.ApplyHeaderSettings then
                DF:ApplyHeaderSettings()
            end
            DF:UpdateAllFrames()
        end), 30)
        hidePlayer.hideOn = function() return GUI.SelectedMode == "raid" end
        hidePlayer.tooltip = "Removes your player frame from the DandersFrames party display."
        
        Add(frameDisplayGroup, nil, 1)
        
        -- ===== BLIZZARD FRAMES GROUP (Column 2) =====
        local blizzardGroup = GUI:CreateSettingsGroup(self.child, 280)
        blizzardGroup:AddWidget(GUI:CreateHeader(self.child, "Blizzard Frames"), 40)
        
        local hideDefaultPlayer = blizzardGroup:AddWidget(GUI:CreateCheckbox(self.child, "Hide Blizzard Player Frame", db, "hideDefaultPlayerFrame", function()
            DF:UpdateDefaultPlayerFrame()
        end), 30)
        hideDefaultPlayer.tooltip = "Hides the default Blizzard player portrait and health bar."
        
        local hidePartyCheck = blizzardGroup:AddWidget(GUI:CreateCheckbox(self.child, "Hide Blizzard Party Frames", db, "hideBlizzardPartyFrames", function()
            DF:UpdateBlizzardFrameVisibility()
        end), 30)
        hidePartyCheck.hideOn = function() return GUI.SelectedMode == "raid" end
        
        local hideRaidCheck = blizzardGroup:AddWidget(GUI:CreateCheckbox(self.child, "Hide Blizzard Raid Frames", db, "hideBlizzardRaidFrames", function()
            DF:UpdateBlizzardFrameVisibility()
        end), 30)
        hideRaidCheck.hideOn = function() return GUI.SelectedMode == "party" end
        
        blizzardGroup:AddWidget(GUI:CreateLabel(self.child, "Hides Blizzard frames but keeps them active for aura filtering.", 250), 40)
        
        local sideMenuCheck = blizzardGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Party/Raid Side Menu", db, "showBlizzardSideMenu", function()
            DF:UpdateBlizzardFrameVisibility()
        end), 30)
        sideMenuCheck.hideOn = function(d)
            if GUI.SelectedMode == "raid" then
                return not d.hideBlizzardRaidFrames
            else
                return not d.hideBlizzardPartyFrames
            end
        end
        
        local sideMenuLabel = blizzardGroup:AddWidget(GUI:CreateLabel(self.child, "Shows the ping wheel & party management menu.", 250), 30)
        sideMenuLabel.hideOn = function(d)
            if GUI.SelectedMode == "raid" then
                return not d.hideBlizzardRaidFrames
            else
                return not d.hideBlizzardPartyFrames
            end
        end
        
        Add(blizzardGroup, nil, 2)
    end)
    
    -- Display > Tooltips (moved from General)
    local pageTooltips = CreateSubTab("display", "display_tooltips", "Tooltips")
    BuildPage(pageTooltips, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top right (positioned automatically via rightAlign)
        Add(CreateCopyButton(self.child, {"tooltip"}, "Tooltips"), 25, 2)
        
        -- Anchor position values (shared)
        local anchorPositionValues = {
            TOPLEFT = "Top Left",
            TOP = "Top",
            TOPRIGHT = "Top Right",
            LEFT = "Left",
            CENTER = "Center",
            RIGHT = "Right",
            BOTTOMLEFT = "Bottom Left",
            BOTTOM = "Bottom",
            BOTTOMRIGHT = "Bottom Right",
        }
        
        -- ===== ROW 1: Frame Tooltips + Buff Tooltips =====
        
        -- Frame Tooltips (Column 1)
        local frameTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        frameTooltipGroup:AddWidget(GUI:CreateHeader(self.child, "Frame Tooltips"), 40)
        frameTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Frame Tooltips", db, "tooltipFrameEnabled", nil), 30)
        frameTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, "Disable in Combat", db, "tooltipFrameDisableInCombat", function() end), 30)
        
        local frameAnchorValues = {
            DEFAULT = "Game Default",
            CURSOR = "Cursor",
            FRAME = "Unit Frame",
        }
        frameTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor To", frameAnchorValues, db, "tooltipFrameAnchor", function() GUI:RefreshCurrentPage() end), 55)
        
        local frameAnchorPos = frameTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor Position", anchorPositionValues, db, "tooltipFrameAnchorPos", function() end), 55)
        frameAnchorPos.disableOn = function(d) return d.tooltipFrameAnchor == "DEFAULT" end
        
        local frameOffsetX = frameTooltipGroup:AddWidget(GUI:CreateSlider(self.child, "X Offset", -100, 100, 1, db, "tooltipFrameX", function() end), 55)
        frameOffsetX.disableOn = function(d) return d.tooltipFrameAnchor ~= "FRAME" end
        
        local frameOffsetY = frameTooltipGroup:AddWidget(GUI:CreateSlider(self.child, "Y Offset", -100, 100, 1, db, "tooltipFrameY", function() end), 55)
        frameOffsetY.disableOn = function(d) return d.tooltipFrameAnchor ~= "FRAME" end
        
        Add(frameTooltipGroup, nil, 1)
        
        -- Buff Tooltips (Column 2)
        local buffTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        buffTooltipGroup:AddWidget(GUI:CreateHeader(self.child, "Buff Tooltips"), 40)
        buffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Buff Tooltips", db, "tooltipBuffEnabled", nil), 30)
        buffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, "Disable in Combat", db, "tooltipBuffDisableInCombat", function() end), 30)
        
        local buffAnchorValues = {
            DEFAULT = "Game Default",
            CURSOR = "Cursor",
            FRAME = "Buff Icon",
        }
        buffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor To", buffAnchorValues, db, "tooltipBuffAnchor", function() GUI:RefreshCurrentPage() end), 55)
        
        local buffAnchorPos = buffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor Position", anchorPositionValues, db, "tooltipBuffAnchorPos", function() end), 55)
        buffAnchorPos.disableOn = function(d) return d.tooltipBuffAnchor == "DEFAULT" end
        
        local buffOffsetX = buffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, "X Offset", -100, 100, 1, db, "tooltipBuffX", function() end), 55)
        buffOffsetX.disableOn = function(d) return d.tooltipBuffAnchor ~= "FRAME" end
        
        local buffOffsetY = buffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, "Y Offset", -100, 100, 1, db, "tooltipBuffY", function() end), 55)
        buffOffsetY.disableOn = function(d) return d.tooltipBuffAnchor ~= "FRAME" end
        
        Add(buffTooltipGroup, nil, 2)
        
        -- Sync point: align row 2 to start at the same level
        AddSyncPoint()
        
        -- ===== ROW 2: Debuff Tooltips + Defensive Icon Tooltips =====
        
        -- Debuff Tooltips (Column 1)
        local debuffTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        debuffTooltipGroup:AddWidget(GUI:CreateHeader(self.child, "Debuff Tooltips"), 40)
        debuffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Debuff Tooltips", db, "tooltipDebuffEnabled", nil), 30)
        debuffTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, "Disable in Combat", db, "tooltipDebuffDisableInCombat", function() end), 30)
        
        local debuffAnchorValues = {
            DEFAULT = "Game Default",
            CURSOR = "Cursor",
            FRAME = "Debuff Icon",
        }
        debuffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor To", debuffAnchorValues, db, "tooltipDebuffAnchor", function() GUI:RefreshCurrentPage() end), 55)
        
        local debuffAnchorPos = debuffTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor Position", anchorPositionValues, db, "tooltipDebuffAnchorPos", function() end), 55)
        debuffAnchorPos.disableOn = function(d) return d.tooltipDebuffAnchor == "DEFAULT" end
        
        local debuffOffsetX = debuffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, "X Offset", -100, 100, 1, db, "tooltipDebuffX", function() end), 55)
        debuffOffsetX.disableOn = function(d) return d.tooltipDebuffAnchor ~= "FRAME" end
        
        local debuffOffsetY = debuffTooltipGroup:AddWidget(GUI:CreateSlider(self.child, "Y Offset", -100, 100, 1, db, "tooltipDebuffY", function() end), 55)
        debuffOffsetY.disableOn = function(d) return d.tooltipDebuffAnchor ~= "FRAME" end
        
        Add(debuffTooltipGroup, nil, 1)
        
        -- Defensive Icon Tooltips (Column 2)
        local defTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)
        defTooltipGroup:AddWidget(GUI:CreateHeader(self.child, "Defensive Icon Tooltips"), 40)
        defTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Defensive Icon Tooltips", db, "tooltipDefensiveEnabled", nil), 30)
        defTooltipGroup:AddWidget(GUI:CreateCheckbox(self.child, "Disable in Combat", db, "tooltipDefensiveDisableInCombat", function() end), 30)
        
        local defAnchorValues = {
            DEFAULT = "Game Default",
            CURSOR = "Cursor",
            FRAME = "Defensive Icon",
        }
        defTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor To", defAnchorValues, db, "tooltipDefensiveAnchor", function() GUI:RefreshCurrentPage() end), 55)
        
        local defAnchorPos = defTooltipGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor Position", anchorPositionValues, db, "tooltipDefensiveAnchorPos", function() end), 55)
        defAnchorPos.disableOn = function(d) return d.tooltipDefensiveAnchor == "DEFAULT" end
        
        local defOffsetX = defTooltipGroup:AddWidget(GUI:CreateSlider(self.child, "X Offset", -100, 100, 1, db, "tooltipDefensiveX", function() end), 55)
        defOffsetX.disableOn = function(d) return d.tooltipDefensiveAnchor ~= "FRAME" end
        
        local defOffsetY = defTooltipGroup:AddWidget(GUI:CreateSlider(self.child, "Y Offset", -100, 100, 1, db, "tooltipDefensiveY", function() end), 55)
        defOffsetY.disableOn = function(d) return d.tooltipDefensiveAnchor ~= "FRAME" end
        
        Add(defTooltipGroup, nil, 2)
        
        -- Sync point before See Also
        AddSyncPoint()
        AddSpace(20, "both")
        
        -- See Also links
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = "Buffs"},
            {pageId = "auras_debuffs", label = "Debuffs"},
            {pageId = "auras_bossdebuffs", label = "Boss Debuffs"},
            {pageId = "auras_defensiveicon", label = "Defensive Icon"},
        }), 30, "both")
    end)
    
    -- Display > Fading (moved from Indicators > Out of Range + Dead/Offline fading)
    local pageFading = CreateSubTab("display", "display_fading", "Fading")
    BuildPage(pageFading, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top right
        Add(CreateCopyButton(self.child, {"rangeFade", "oor", "dead", "offline", "healthFade", "hf"}, "Fading"), 25, 2)
        
        -- Sync point: ensures both columns start below the copy button
        AddSpace(10, "both")
        
        -- Helper to check if element options should be hidden
        local function HideOOROptions(d)
            return not d.oorEnabled
        end
        
        -- Helper to check if frame-level alpha should be hidden (when element-specific is enabled)
        local function HideFrameLevelAlpha(d)
            return d.oorEnabled
        end
        
        -- ===== OUT OF RANGE GROUP (Column 1) =====
        local oorGroup = GUI:CreateSettingsGroup(self.child, 280)
        oorGroup:AddWidget(GUI:CreateHeader(self.child, "Out of Range"), 40)
        
        -- Build dropdown options dynamically
        local function GetRangeSpellDropdownOptions()
            local options = {}
            if DF.GetRangeSpellOptions then
                local spellOptions = DF:GetRangeSpellOptions()
                for _, opt in ipairs(spellOptions) do
                    options[opt.value] = opt.label
                end
            else
                options[0] = "Auto (Spec Default)"
            end
            return options
        end
        
        -- Ensure db value is not nil (default to 0 = Auto)
        if db.rangeCheckSpellID == nil then
            db.rangeCheckSpellID = 0
        end
        
        -- Helper to refresh info label
        local function RefreshRangeInfoLabel()
            if self.rangeSpellInfoLabel and self.rangeSpellInfoLabel.SetText and DF.GetCurrentRangeSpellInfo then
                local info = DF:GetCurrentRangeSpellInfo()
                self.rangeSpellInfoLabel:SetText("|cFFAAAAAA" .. "Active: " .. (info.spellName or "None") .. " (" .. (info.range or "?") .. ")|r")
            end
        end
        
        -- Set value callback - called AFTER dropdown has already set db.rangeCheckSpellID
        local function SetRangeSpellValue()
            local value = db.rangeCheckSpellID or 0
            if DF.SetRangeCheckSpell then
                DF:SetRangeCheckSpell(value)
            end
            RefreshRangeInfoLabel()
            if self.rangeSpellInput and self.rangeSpellInput.EditBox then
                self.rangeSpellInput.EditBox:SetText("")
            end
        end
        
        -- Range Check Spell row
        local rangeSpellDropdown = oorGroup:AddWidget(GUI:CreateDropdown(self.child, "Range Check Spell", GetRangeSpellDropdownOptions(), db, "rangeCheckSpellID", SetRangeSpellValue), 55)
        rangeSpellDropdown.tooltip = "Select which spell to use for range checking. Auto will use your spec's default healing/friendly spell."
        
        -- Custom Spell ID Input
        local customSpellInput = oorGroup:AddWidget(GUI:CreateInput(self.child, "Custom Spell ID", 120), 55)
        customSpellInput.tooltip = "Enter any spell ID for range checking. Press Enter to apply. Leave empty to use dropdown selection."
        self.rangeSpellInput = customSpellInput
        
        -- Set initial value if it's a custom spell not in dropdown
        if db.rangeCheckSpellID and db.rangeCheckSpellID > 0 then
            local isInDropdown = false
            if DF.GetRangeSpellOptions then
                for _, opt in ipairs(DF:GetRangeSpellOptions()) do
                    if opt.value == db.rangeCheckSpellID then
                        isInDropdown = true
                        break
                    end
                end
            end
            if not isInDropdown then
                customSpellInput.EditBox:SetText(tostring(db.rangeCheckSpellID))
            end
        end
        
        customSpellInput.EditBox:SetNumeric(true)
        customSpellInput.EditBox:SetMaxLetters(8)
        
        local function ApplyCustomSpellID()
            local text = customSpellInput.EditBox:GetText()
            local spellID = tonumber(text)
            
            if not text or text == "" then
                return
            end
            
            if spellID and spellID > 0 then
                local spellName = C_Spell.GetSpellName(spellID)
                if spellName then
                    db.rangeCheckSpellID = spellID
                    if DF.SetRangeCheckSpell then
                        DF:SetRangeCheckSpell(spellID)
                    end
                    RefreshRangeInfoLabel()
                    print("|cFF00FF00[DFRange]|r Custom spell set: " .. spellName .. " (ID: " .. spellID .. ")")
                else
                    print("|cFFFF0000[DFRange]|r Invalid spell ID: " .. spellID)
                    customSpellInput.EditBox:SetText("")
                end
            end
        end
        
        customSpellInput.EditBox:SetScript("OnEnterPressed", function(self)
            ApplyCustomSpellID()
            self:ClearFocus()
        end)
        customSpellInput.EditBox:SetScript("OnEditFocusLost", function(self)
            ApplyCustomSpellID()
        end)
        
        -- Info label showing current active spell
        local rangeInfoText = "Loading..."
        if DF.GetCurrentRangeSpellInfo then
            local rangeInfo = DF:GetCurrentRangeSpellInfo()
            rangeInfoText = (rangeInfo.spellName or "None") .. " (" .. (rangeInfo.range or "?") .. ")"
        end
        local infoLabel = oorGroup:AddWidget(GUI:CreateLabel(self.child, "|cFFAAAAAA" .. "Active: " .. rangeInfoText .. "|r", 250), 25)
        self.rangeSpellInfoLabel = infoLabel
        
        -- Range update interval
        if db.rangeUpdateInterval == nil then
            db.rangeUpdateInterval = 0.5
        end
        local intervalSlider = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Range Check Interval", 0.1, 1.0, 0.05, db, "rangeUpdateInterval", nil, function()
            if DF.SetRangeUpdateInterval then
                DF:SetRangeUpdateInterval(db.rangeUpdateInterval)
            end
        end, true), 55)
        intervalSlider.tooltip = "How often to check range (seconds). Lower = more responsive but higher CPU. Default: 0.5s"
        
        -- Frame-level alpha (shown when element-specific is disabled)
        local frameLevelAlpha = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Frame Alpha (Out of Range)", 0.1, 1.0, 0.05, db, "rangeFadeAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        frameLevelAlpha.hideOn = HideFrameLevelAlpha
        
        -- Element-specific toggle
        oorGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Element-Specific Alpha", db, "oorEnabled", function()
            self:RefreshStates()
        end), 30)
        
        -- Element-specific sliders (shown when enabled)
        local oorHealth = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Health Bar Alpha", 0.0, 1.0, 0.05, db, "oorHealthBarAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorHealth.hideOn = HideOOROptions
        
        local oorBg = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Background Alpha", 0.0, 1.0, 0.05, db, "oorBackgroundAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorBg.hideOn = HideOOROptions
        
        local oorName = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Name Text Alpha", 0.0, 1.0, 0.05, db, "oorNameTextAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorName.hideOn = HideOOROptions
        
        local oorHealthText = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Health Text Alpha", 0.0, 1.0, 0.05, db, "oorHealthTextAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorHealthText.hideOn = HideOOROptions
        
        local oorAuras = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Auras Alpha", 0.0, 1.0, 0.05, db, "oorAurasAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorAuras.hideOn = HideOOROptions
        
        local oorIcons = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Icons Alpha", 0.0, 1.0, 0.05, db, "oorIconsAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorIcons.hideOn = HideOOROptions
        
        local oorDispel = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Dispel Overlay Alpha", 0.0, 1.0, 0.05, db, "oorDispelOverlayAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorDispel.hideOn = HideOOROptions
        
        local oorMyBuffIndicator = oorGroup:AddWidget(GUI:CreateSlider(self.child, "My Buff Indicator Alpha", 0.0, 1.0, 0.05, db, "oorMyBuffIndicatorAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorMyBuffIndicator.hideOn = HideOOROptions
        
        local oorPower = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Power Bar Alpha", 0.0, 1.0, 0.05, db, "oorPowerBarAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorPower.hideOn = HideOOROptions
        
        local oorMissingBuff = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Missing Buff Alpha", 0.0, 1.0, 0.05, db, "oorMissingBuffAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorMissingBuff.hideOn = HideOOROptions
        
        local oorDefensive = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Defensive Icon Alpha", 0.0, 1.0, 0.05, db, "oorDefensiveIconAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorDefensive.hideOn = HideOOROptions
        
        local oorTargetedSpell = oorGroup:AddWidget(GUI:CreateSlider(self.child, "Targeted Spell Alpha", 0.0, 1.0, 0.05, db, "oorTargetedSpellAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        oorTargetedSpell.hideOn = HideOOROptions
        
        Add(oorGroup, nil, 1)
        
        -- ===== DEAD/OFFLINE FADING GROUP (Column 2) =====
        local deadGroup = GUI:CreateSettingsGroup(self.child, 280)
        deadGroup:AddWidget(GUI:CreateHeader(self.child, "Dead/Offline Fading"), 40)
        
        deadGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Dead Fade", db, "fadeDeadFrames", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end), 30)
        
        local function HideDeadOptions(d)
            return not d.fadeDeadFrames
        end
        
        local deadBgAlpha = deadGroup:AddWidget(GUI:CreateSlider(self.child, "Background Alpha", 0.0, 1.0, 0.05, db, "fadeDeadBackground", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadBgAlpha.hideOn = HideDeadOptions
        
        local deadHealthAlpha = deadGroup:AddWidget(GUI:CreateSlider(self.child, "Health Bar Alpha", 0.0, 1.0, 0.05, db, "fadeDeadHealthBar", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadHealthAlpha.hideOn = HideDeadOptions
        
        local deadNameAlpha = deadGroup:AddWidget(GUI:CreateSlider(self.child, "Name Alpha", 0.0, 1.0, 0.05, db, "fadeDeadName", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadNameAlpha.hideOn = HideDeadOptions
        
        local deadPowerAlpha = deadGroup:AddWidget(GUI:CreateSlider(self.child, "Power Bar Alpha", 0.0, 1.0, 0.05, db, "fadeDeadPowerBar", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadPowerAlpha.hideOn = HideDeadOptions
        
        local deadIconsAlpha = deadGroup:AddWidget(GUI:CreateSlider(self.child, "Icons Alpha", 0.0, 1.0, 0.05, db, "fadeDeadIcons", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadIconsAlpha.hideOn = HideDeadOptions
        
        local deadAurasAlpha = deadGroup:AddWidget(GUI:CreateSlider(self.child, "Auras Alpha", 0.0, 1.0, 0.05, db, "fadeDeadAuras", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadAurasAlpha.hideOn = HideDeadOptions
        
        local deadTextAlpha = deadGroup:AddWidget(GUI:CreateSlider(self.child, "Status Text Alpha", 0.0, 1.0, 0.05, db, "fadeDeadStatusText", function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        deadTextAlpha.hideOn = HideDeadOptions
        
        local deadCustomBg = deadGroup:AddWidget(GUI:CreateCheckbox(self.child, "Custom Dead Background", db, "fadeDeadUseCustomColor", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end), 30)
        deadCustomBg.hideOn = HideDeadOptions
        
        local function HideDeadBgColor(d)
            return not d.fadeDeadFrames or not d.fadeDeadUseCustomColor
        end
        
        local deadBgColor = deadGroup:AddWidget(GUI:CreateColorPicker(self.child, "Dead Background Color", db, "fadeDeadBackgroundColor", false, function() DF:RefreshAllVisibleFrames() end, function() DF:RefreshAllVisibleFrames() end, true), 35)
        deadBgColor.hideOn = HideDeadBgColor
        
        Add(deadGroup, nil, 2)
        
        -- ===== HEALTH THRESHOLD FADING (above health threshold) =====
        AddSpace(20, "both")
        local hfGroup = GUI:CreateSettingsGroup(self.child, 560)
        hfGroup:AddWidget(GUI:CreateHeader(self.child, "Health Threshold Fading"), 40)
        hfGroup.tooltip = "Fade frames or elements when a unit's health is above the set threshold (e.g. 100% or 80%)."

        hfGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Health Threshold Fade", db, "healthFadeEnabled", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end), 30)

        local function HideHFOptions(d)
            return not d.healthFadeEnabled
        end
        local function HideHFElementOptions(d)
            return not d.healthFadeEnabled or not d.hfElementSpecific
        end
        local function HideHFFrameAlpha(d)
            return not d.healthFadeEnabled or d.hfElementSpecific
        end

        local hfThreshold = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Health Threshold (%)", 50, 100, 1, db, "healthFadeThreshold", nil, function()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end, false), 55)
        hfThreshold.hideOn = HideHFOptions
        hfThreshold.tooltip = "Units at or above this health percent are faded."

        local hfCancelDispel = hfGroup:AddWidget(GUI:CreateCheckbox(self.child, "Cancel Fade on Dispellable Debuff", db, "hfCancelOnDispel", function()
            DF:UpdateAllFrames()
            DF:RefreshAllVisibleFrames()
        end), 30)
        hfCancelDispel.hideOn = HideHFOptions

        -- Health fade sliders need UpdateAllFrameAppearances to force an immediate visual refresh.
        -- Unlike OOR/dead fade which refresh on range/state changes, health fade alpha values
        -- are only re-read during appearance updates, not triggered by FullFrameRefresh alone.
        local function RefreshHealthFade()
            DF:RefreshAllVisibleFrames()
            if DF.UpdateAllFrameAppearances then DF:UpdateAllFrameAppearances() end
        end

        local hfFrameAlpha = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Frame Alpha (Above Threshold)", 0.1, 1.0, 0.05, db, "healthFadeAlpha", nil, RefreshHealthFade, true), 55)
        hfFrameAlpha.hideOn = HideHFFrameAlpha
        hfFrameAlpha.tooltip = "Frame opacity when health is above the threshold (element-specific disabled)."

        local hfElementSpecific = hfGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Element-Specific Alpha", db, "hfElementSpecific", function()
            self:RefreshStates()
            RefreshHealthFade()
        end), 30)
        hfElementSpecific.hideOn = HideHFOptions

        local hfHealth = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Health Bar Alpha", 0.0, 1.0, 0.05, db, "hfHealthBarAlpha", nil, RefreshHealthFade, true), 55)
        hfHealth.hideOn = HideHFElementOptions
        local hfBg = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Background Alpha", 0.0, 1.0, 0.05, db, "hfBackgroundAlpha", nil, RefreshHealthFade, true), 55)
        hfBg.hideOn = HideHFElementOptions
        local hfName = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Name Text Alpha", 0.0, 1.0, 0.05, db, "hfNameTextAlpha", nil, RefreshHealthFade, true), 55)
        hfName.hideOn = HideHFElementOptions
        local hfHealthText = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Health Text Alpha", 0.0, 1.0, 0.05, db, "hfHealthTextAlpha", nil, RefreshHealthFade, true), 55)
        hfHealthText.hideOn = HideHFElementOptions
        local hfAuras = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Auras Alpha", 0.0, 1.0, 0.05, db, "hfAurasAlpha", nil, RefreshHealthFade, true), 55)
        hfAuras.hideOn = HideHFElementOptions
        local hfIcons = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Icons Alpha", 0.0, 1.0, 0.05, db, "hfIconsAlpha", nil, RefreshHealthFade, true), 55)
        hfIcons.hideOn = HideHFElementOptions
        local hfDispel = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Dispel Overlay Alpha", 0.0, 1.0, 0.05, db, "hfDispelOverlayAlpha", nil, RefreshHealthFade, true), 55)
        hfDispel.hideOn = HideHFElementOptions
        local hfMyBuff = hfGroup:AddWidget(GUI:CreateSlider(self.child, "My Buff Indicator Alpha", 0.0, 1.0, 0.05, db, "hfMyBuffIndicatorAlpha", nil, RefreshHealthFade, true), 55)
        hfMyBuff.hideOn = HideHFElementOptions
        local hfPower = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Power Bar Alpha", 0.0, 1.0, 0.05, db, "hfPowerBarAlpha", nil, RefreshHealthFade, true), 55)
        hfPower.hideOn = HideHFElementOptions
        local hfMissingBuff = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Missing Buff Alpha", 0.0, 1.0, 0.05, db, "hfMissingBuffAlpha", nil, RefreshHealthFade, true), 55)
        hfMissingBuff.hideOn = HideHFElementOptions
        local hfDefensive = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Defensive Icon Alpha", 0.0, 1.0, 0.05, db, "hfDefensiveIconAlpha", nil, RefreshHealthFade, true), 55)
        hfDefensive.hideOn = HideHFElementOptions
        local hfTargetedSpell = hfGroup:AddWidget(GUI:CreateSlider(self.child, "Targeted Spell Alpha", 0.0, 1.0, 0.05, db, "hfTargetedSpellAlpha", nil, RefreshHealthFade, true), 55)
        hfTargetedSpell.hideOn = HideHFElementOptions

        Add(hfGroup, nil, "both")
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "display_visibility", label = "Visibility"},
            {pageId = "text_status", label = "Status Text"},
        }), 30, "both")
    end)
    
    -- Display > Pet Frames
    local pagePets = CreateSubTab("display", "display_pets", "Pet Frames")
    BuildPage(pagePets, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top right
        Add(CreateCopyButton(self.child, {"pet"}, "Pet Frames"), 25, 2)
        
        -- Check modes for conditional content
        local isGroupedMode = db.petGroupMode == "GROUPED"
        local isRaidMode = GUI.SelectedMode == "raid"
        
        -- ===== GENERAL GROUP (full width) =====
        local generalGroup = GUI:CreateSettingsGroup(self.child, 560)
        generalGroup:AddWidget(GUI:CreateHeader(self.child, "Pet Frame Settings"), 40)
        generalGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Pet Frames", db, "petEnabled", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end), 30)
        generalGroup:AddWidget(GUI:CreateLabel(self.child, "Show health bars for player and party/raid member pets, anchored to their owner's frame. Pet frames hide when owner dies.", 530), 30)
        Add(generalGroup, nil, "both")
        
        -- ===== LAYOUT MODE GROUP (full width) =====
        local layoutGroup = GUI:CreateSettingsGroup(self.child, 560)
        layoutGroup:AddWidget(GUI:CreateHeader(self.child, "Layout Mode"), 40)
        
        local groupModeValues = {
            ATTACHED = "Attached to Owner",
            GROUPED = "Separate Pet Group",
        }
        layoutGroup:AddWidget(GUI:CreateDropdown(self.child, "Layout Mode", groupModeValues, db, "petGroupMode", function()
            if DF.UpdateAllPetFrames then DF:UpdateAllPetFrames() end
            if DF.UpdateAllRaidPetFrames then DF:UpdateAllRaidPetFrames() end
            GUI:RefreshCurrentPage()
        end), 55)
        
        if not isGroupedMode then
            layoutGroup:AddWidget(GUI:CreateLabel(self.child, "Pet frames are positioned relative to their owner's frame.", 530), 25)
        else
            layoutGroup:AddWidget(GUI:CreateLabel(self.child, "Pet frames are grouped together in a separate container.", 530), 25)
        end
        Add(layoutGroup, nil, "both")
        
        -- ===== COLUMN 1 GROUPS =====
        
        -- GROUPED MODE: Group Settings (col1)
        if isGroupedMode then
            local groupedSettingsGroup = GUI:CreateSettingsGroup(self.child, 280)
            groupedSettingsGroup:AddWidget(GUI:CreateHeader(self.child, "Group Settings"), 40)
            
            local groupAnchorValues = {
                BOTTOM = isRaidMode and "Below Raid" or "Below Party",
                TOP = isRaidMode and "Above Raid" or "Above Party",
                LEFT = isRaidMode and "Left of Raid" or "Left of Party",
                RIGHT = isRaidMode and "Right of Raid" or "Right of Party",
            }
            local updateFunc = isRaidMode 
                and function() if DF.UpdateRaidPetGroupLayout then DF:UpdateRaidPetGroupLayout() end end
                or function() if DF.UpdatePetGroupLayout then DF:UpdatePetGroupLayout() end end
            
            groupedSettingsGroup:AddWidget(GUI:CreateDropdown(self.child, "Group Position", groupAnchorValues, db, "petGroupAnchor", updateFunc), 55)
            
            local growthValues = { HORIZONTAL = "Horizontal", VERTICAL = "Vertical" }
            groupedSettingsGroup:AddWidget(GUI:CreateDropdown(self.child, "Growth Direction", growthValues, db, "petGroupGrowth", updateFunc), 55)
            groupedSettingsGroup:AddWidget(GUI:CreateSlider(self.child, "Pet Spacing", 0, 20, 1, db, "petGroupSpacing", updateFunc, updateFunc, true), 55)
            groupedSettingsGroup:AddWidget(GUI:CreateSlider(self.child, "Group X Offset", -100, 100, 1, db, "petGroupOffsetX", updateFunc, updateFunc, true), 55)
            groupedSettingsGroup:AddWidget(GUI:CreateSlider(self.child, "Group Y Offset", -100, 100, 1, db, "petGroupOffsetY", updateFunc, updateFunc, true), 55)
            
            if isRaidMode then
                groupedSettingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Group Label", db, "petGroupShowLabel", function()
                    if DF.UpdateRaidPetGroupLayout then DF:UpdateRaidPetGroupLayout() end
                end), 30)
            end
            
            Add(groupedSettingsGroup, nil, 1)
        end
        
        -- SIZE GROUP (col1)
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, "Size"), 40)
        
        if not isGroupedMode then
            sizeGroup:AddWidget(GUI:CreateCheckbox(self.child, "Match Owner Width", db, "petMatchOwnerWidth", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
                GUI:RefreshCurrentPage()
            end), 30)
            sizeGroup:AddWidget(GUI:CreateCheckbox(self.child, "Match Owner Height", db, "petMatchOwnerHeight", function()
                if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
                GUI:RefreshCurrentPage()
            end), 30)
        end
        
        local widthSlider = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Width", 40, 150, 1, db, "petFrameWidth", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        if not isGroupedMode then
            widthSlider.disableOn = function(d) return d.petMatchOwnerWidth end
        end
        
        local heightSlider = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Height", 10, 40, 1, db, "petFrameHeight", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        if not isGroupedMode then
            heightSlider.disableOn = function(d) return d.petMatchOwnerHeight end
        end
        
        Add(sizeGroup, nil, 1)
        
        -- HEALTH BAR GROUP (col1)
        local healthBarGroup = GUI:CreateSettingsGroup(self.child, 280)
        healthBarGroup:AddWidget(GUI:CreateHeader(self.child, "Health Bar"), 40)
        
        local healthColorValues = {
            GREEN = "Always Green",
            CLASS = "Owner's Class Color",
            HEALTH = "By Health %",
            CUSTOM = "Custom Color",
        }
        healthBarGroup:AddWidget(GUI:CreateDropdown(self.child, "Health Bar Color", healthColorValues, db, "petHealthColorMode", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            GUI:RefreshCurrentPage()
        end), 55)
        
        local customHealthColor = healthBarGroup:AddWidget(GUI:CreateColorPicker(self.child, "Custom Health Color", db, "petHealthColor", false, function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
        customHealthColor.hideOn = function(d) return d.petHealthColorMode ~= "CUSTOM" end
        
        healthBarGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Health Percentage", db, "petShowHealthText", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end), 30)
        Add(healthBarGroup, nil, 1)
        
        -- NAME TEXT GROUP (col1)
        local outlineValues = {
            [""] = "None",
            OUTLINE = "Outline",
            THICKOUTLINE = "Thick Outline",
            SHADOW = "Shadow",
            MONOCHROME = "Monochrome",
        }
        local textAnchorValues = {
            TOPLEFT = "Top Left", TOP = "Top", TOPRIGHT = "Top Right",
            LEFT = "Left", CENTER = "Center", RIGHT = "Right",
            BOTTOMLEFT = "Bottom Left", BOTTOM = "Bottom", BOTTOMRIGHT = "Bottom Right",
        }
        
        local nameTextGroup = GUI:CreateSettingsGroup(self.child, 280)
        nameTextGroup:AddWidget(GUI:CreateHeader(self.child, "Name Text"), 40)
        nameTextGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "petNameFont", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        nameTextGroup:AddWidget(GUI:CreateSlider(self.child, "Font Size", 6, 16, 1, db, "petNameFontSize", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        nameTextGroup:AddWidget(GUI:CreateDropdown(self.child, "Font Outline", outlineValues, db, "petNameFontOutline", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        nameTextGroup:AddWidget(GUI:CreateSlider(self.child, "Max Name Length", 4, 20, 1, db, "petNameMaxLength", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end), 55)
        nameTextGroup:AddWidget(GUI:CreateDropdown(self.child, "Name Anchor", textAnchorValues, db, "petNameAnchor", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        nameTextGroup:AddWidget(GUI:CreateColorPicker(self.child, "Name Color", db, "petNameColor", false, function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
        nameTextGroup:AddWidget(GUI:CreateSlider(self.child, "Name X Offset", -30, 30, 1, db, "petNameX", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        nameTextGroup:AddWidget(GUI:CreateSlider(self.child, "Name Y Offset", -15, 15, 1, db, "petNameY", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        Add(nameTextGroup, nil, 1)
        
        -- ===== COLUMN 2 GROUPS =====
        
        -- POSITION GROUP (col2, Attached mode only)
        if not isGroupedMode then
            local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
            positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
            
            local anchorValues = {
                BOTTOM = "Below Owner",
                TOP = "Above Owner",
                LEFT = "Left of Owner",
                RIGHT = "Right of Owner",
            }
            positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor Position", anchorValues, db, "petAnchor", function()
                if DF.UpdateAllPetFramePositions then DF:UpdateAllPetFramePositions() end
            end), 55)
            positionGroup:AddWidget(GUI:CreateSlider(self.child, "X Offset", -50, 50, 1, db, "petOffsetX", function()
                if DF.UpdateAllPetFramePositions then DF:UpdateAllPetFramePositions() end
            end, function() if DF.UpdateAllPetFramePositions then DF:UpdateAllPetFramePositions() end end, true), 55)
            positionGroup:AddWidget(GUI:CreateSlider(self.child, "Y Offset", -50, 50, 1, db, "petOffsetY", function()
                if DF.UpdateAllPetFramePositions then DF:UpdateAllPetFramePositions() end
            end, function() if DF.UpdateAllPetFramePositions then DF:UpdateAllPetFramePositions() end end, true), 55)
            
            Add(positionGroup, nil, 2)
        end
        
        -- APPEARANCE GROUP (col2)
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, "Appearance"), 40)
        appearanceGroup:AddWidget(GUI:CreateTextureDropdown(self.child, "Health Bar Texture", db, "petTexture", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        appearanceGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Border", db, "petShowBorder", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 30)
        appearanceGroup:AddWidget(GUI:CreateColorPicker(self.child, "Border Color", db, "petBorderColor", true, function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
        appearanceGroup:AddWidget(GUI:CreateColorPicker(self.child, "Background Color", db, "petBackgroundColor", true, function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
        Add(appearanceGroup, nil, 2)
        
        -- HEALTH TEXT GROUP (col2)
        local healthTextGroup = GUI:CreateSettingsGroup(self.child, 280)
        healthTextGroup:AddWidget(GUI:CreateHeader(self.child, "Health Text"), 40)
        healthTextGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "petHealthFont", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        healthTextGroup:AddWidget(GUI:CreateSlider(self.child, "Font Size", 6, 14, 1, db, "petHealthFontSize", function()
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        healthTextGroup:AddWidget(GUI:CreateDropdown(self.child, "Font Outline", outlineValues, db, "petHealthFontOutline", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        healthTextGroup:AddWidget(GUI:CreateColorPicker(self.child, "Health Text Color", db, "petHealthTextColor", false, function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 35)
        healthTextGroup:AddWidget(GUI:CreateDropdown(self.child, "Health Text Anchor", textAnchorValues, db, "petHealthAnchor", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end), 55)
        healthTextGroup:AddWidget(GUI:CreateSlider(self.child, "Health X Offset", -30, 30, 1, db, "petHealthX", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        healthTextGroup:AddWidget(GUI:CreateSlider(self.child, "Health Y Offset", -15, 15, 1, db, "petHealthY", function()
            if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end
        end, function() if DF.LightweightUpdatePetFrames then DF:LightweightUpdatePetFrames() end end, true), 55)
        Add(healthTextGroup, nil, 2)
    end)
    
    -- General > Frame
    local pageFrame = CreateSubTab("general", "general_frame", "Frame")
    BuildPage(pageFrame, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"frame", "background", "missingHealth", "border", "anchor"}, "Frame"), 25, 2)
        
        -- Migration: Ensure new flat raid settings have defaults
        if db.raidFlatGrowthAnchor == nil then db.raidFlatGrowthAnchor = "START" end
        if db.raidFlatFrameAnchor == nil then db.raidFlatFrameAnchor = "START" end
        if db.raidFlatColumnAnchor == nil then db.raidFlatColumnAnchor = "START" end
        
        -- Function to update the correct frames based on mode
        local function UpdateFrames()
            if DF.headersInitialized then
                DF:ApplyHeaderSettings()
            end
            if GUI.SelectedMode == "raid" then
                DF:UpdateRaidLayout()
                if DF.SecureSort and DF.SecureSort.raidFramesRegistered then
                    DF.SecureSort:PushRaidLayoutConfig()
                    DF.SecureSort:PushRaidGroupLayoutConfig()
                    DF.SecureSort:TriggerSecureRaidSort()
                end
            else
                DF:UpdateAllFrames()
            end
        end
        
        -- Store references to sliders so we can update their labels
        local groupsPerRowSlider, rowColSpacingSlider, playersPerRowSlider
        
        -- Function to update dynamic labels based on growth direction
        local function UpdateDynamicLabels()
            if groupsPerRowSlider and groupsPerRowSlider.label then
                groupsPerRowSlider.label:SetText(db.growDirection == "VERTICAL" and "Groups Per Column" or "Groups Per Row")
            end
            if rowColSpacingSlider and rowColSpacingSlider.label then
                rowColSpacingSlider.label:SetText(db.growDirection == "VERTICAL" and "Column Spacing" or "Row Spacing")
            end
            if playersPerRowSlider and playersPerRowSlider.label then
                playersPerRowSlider.label:SetText(db.growDirection == "VERTICAL" and "Players Per Column" or "Players Per Row")
            end
        end
        
        -- Custom callback for growth direction
        local function OnGrowthDirectionChanged()
            UpdateDynamicLabels()
            UpdateFrames()
            if GUI.SelectedMode == "raid" and not db.raidUseGroups and not InCombatLockdown() then
                C_Timer.After(0, function()
                    if not InCombatLockdown() then
                        if DF.headersInitialized then DF:ApplyHeaderSettings() end
                        if DF.UpdateRaidLayout then DF:UpdateRaidLayout() end
                    end
                end)
            end
        end
        
        -- ===== FRAME SIZE GROUP (Column 1) =====
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, "Frame Size"), 40)
        sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Frame Width", 60, 300, 1, db, "frameWidth", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
        sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Frame Height", 20, 300, 1, db, "frameHeight", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
        sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Frame Padding", 0, 10, 1, db, "framePadding", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
        local frameSpacingSlider = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Frame Spacing", -5, 50, 1, db, "frameSpacing", UpdateFrames, function() DF:LightweightUpdateFrameSpacing() end, true), 55)
        frameSpacingSlider.hideOn = function() return GUI.SelectedMode == "raid" and not db.raidUseGroups end
        Add(sizeGroup, nil, 1)
        
        -- ===== APPEARANCE GROUP (Column 2) =====
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, "Appearance"), 40)
        appearanceGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Frame Border", db, "showFrameBorder", UpdateFrames), 30)
        local borderColorPicker = appearanceGroup:AddWidget(GUI:CreateColorPicker(self.child, "Border Color", db, "borderColor", true, UpdateFrames, function() DF:LightweightUpdateBorderColor() end, true), 35)
        borderColorPicker.hideOn = function(d) return not d.showFrameBorder end
        appearanceGroup:AddWidget(GUI:CreateCheckbox(self.child, "Pixel-Perfect Scaling", db, "pixelPerfect", UpdateFrames), 30)
        appearanceGroup:AddWidget(GUI:CreateLabel(self.child, "Snaps sizes and borders to exact pixels for crisp rendering.", 250), 30)
        Add(appearanceGroup, nil, 2)
        
        -- ===== LAYOUT DIRECTION GROUP (Column 1) =====
        local layoutGroup = GUI:CreateSettingsGroup(self.child, 280)
        layoutGroup:AddWidget(GUI:CreateHeader(self.child, "Layout Direction"), 40)
        
        -- Party dropdown
        local partyGrowOptions = { HORIZONTAL = "Rows", VERTICAL = "Columns" }
        local partyArrangeDropdown = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, "Arrange In", partyGrowOptions, db, "growDirection", OnGrowthDirectionChanged), 55)
        partyArrangeDropdown.hideOn = function() return GUI.SelectedMode == "raid" end
        
        -- Raid GROUP dropdown (groups mode)
        local raidGrowOptions = { HORIZONTAL = "Columns", VERTICAL = "Rows" }
        local raidArrangeDropdown = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, "Arrange Groups In", raidGrowOptions, db, "growDirection", OnGrowthDirectionChanged), 55)
        raidArrangeDropdown.hideOn = function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end
        
        -- Raid FLAT dropdown
        local flatGrowOptions = { HORIZONTAL = "Rows", VERTICAL = "Columns" }
        local flatArrangeDropdown = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, "Arrange Players In", flatGrowOptions, db, "growDirection", OnGrowthDirectionChanged), 55)
        flatArrangeDropdown.hideOn = function() return GUI.SelectedMode ~= "raid" or db.raidUseGroups end
        
        -- Growth anchor (party only)
        local anchorOptions = { START = "Start", CENTER = "Center", END = "End" }
        local anchorDropdown = layoutGroup:AddWidget(GUI:CreateDropdown(self.child, "Frames Grow From", anchorOptions, db, "growthAnchor", UpdateFrames), 55)
        anchorDropdown.hideOn = function() return GUI.SelectedMode == "raid" end
        
        local helpText = layoutGroup:AddWidget(GUI:CreateLabel(self.child, "Start = Left/Top, End = Right/Bottom depending on direction.", 250), 30)
        helpText.hideOn = function() return GUI.SelectedMode == "raid" end
        
        Add(layoutGroup, nil, 1)
        
        -- ===== RAID LAYOUT MODE GROUP (Column 2, raid only) =====
        local raidModeGroup = GUI:CreateSettingsGroup(self.child, 280)
        raidModeGroup:AddWidget(GUI:CreateHeader(self.child, "Raid Layout Mode"), 40)
        raidModeGroup.hideOn = function() return GUI.SelectedMode ~= "raid" end
        
        local useGroupsCheck = raidModeGroup:AddWidget(GUI:CreateCheckbox(self.child, "Use Group-Based Layout", db, "raidUseGroups", function()
            UpdateFrames()
            if DF.SecureSort then
                DF.SecureSort:PushRaidGroupLayoutConfig()
                DF.SecureSort:TriggerSecureRaidSort()
            end
            if not db.raidUseGroups and not InCombatLockdown() then
                if DF.UpdateRaidGroupLabels then DF:UpdateRaidGroupLabels() end
                C_Timer.After(0, function()
                    if not InCombatLockdown() then
                        if DF.FlatRaidFrames then
                            if not DF.FlatRaidFrames.initialized then DF.FlatRaidFrames:Initialize() end
                            if DF.FlatRaidFrames.initialized then DF.FlatRaidFrames:SetEnabled(true) end
                        end
                        if DF.headersInitialized then DF:ApplyHeaderSettings() end
                        if DF.UpdateRaidLayout then DF:UpdateRaidLayout() end
                    end
                end)
            else
                if DF.FlatRaidFrames and DF.FlatRaidFrames.initialized then
                    DF.FlatRaidFrames:SetEnabled(false)
                end
            end
            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
        end), 30)
        
        raidModeGroup:AddWidget(GUI:CreateLabel(self.child, "Enabled: Players organized by raid groups (1-8).\nDisabled: All players in one flat grid.", 250), 45)
        Add(raidModeGroup, nil, 2)
        
        -- ===== GROUP LAYOUT SETTINGS (Column 1, raid+groups only) =====
        local groupLayoutGroup = GUI:CreateSettingsGroup(self.child, 280)
        groupLayoutGroup:AddWidget(GUI:CreateHeader(self.child, "Group Layout Settings"), 40)
        groupLayoutGroup.hideOn = function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end
        
        groupLayoutGroup:AddWidget(GUI:CreateLabel(self.child, "Horizontal: Players stack vertically, groups grow left-to-right.", 250), 25)
        
        groupLayoutGroup:AddWidget(GUI:CreateSlider(self.child, "Group Spacing", -5, 100, 1, db, "raidGroupSpacing", UpdateFrames, function() DF:LightweightUpdateRaidLayout() end, true), 55)
        
        local rowColLabel = db.growDirection == "VERTICAL" and "Column Spacing" or "Row Spacing"
        rowColSpacingSlider = groupLayoutGroup:AddWidget(GUI:CreateSlider(self.child, rowColLabel, -5, 100, 1, db, "raidRowColSpacing", UpdateFrames, function() DF:LightweightUpdateRaidLayout() end, true), 55)
        
        local groupsLabel = db.growDirection == "VERTICAL" and "Groups Per Column" or "Groups Per Row"
        groupsPerRowSlider = groupLayoutGroup:AddWidget(GUI:CreateSlider(self.child, groupsLabel, 1, 8, 1, db, "raidGroupsPerRow", UpdateFrames, function() DF:LightweightUpdateRaidLayout() end, true), 55)
        
        groupLayoutGroup:AddWidget(GUI:CreateDropdown(self.child, "Groups Grow From", anchorOptions, db, "raidGroupAnchor", UpdateFrames), 55)
        
        local playerAnchorOptions = { START = "Start", END = "End" }
        groupLayoutGroup:AddWidget(GUI:CreateDropdown(self.child, "Players Grow From", playerAnchorOptions, db, "raidPlayerAnchor", UpdateFrames), 55)
        
        Add(groupLayoutGroup, nil, 1)
        
        -- ===== GROUP VISIBILITY (Column 1, raid only) =====
        local groupVisGroup = GUI:CreateSettingsGroup(self.child, 280)
        groupVisGroup:AddWidget(GUI:CreateHeader(self.child, "Group Visibility"), 40)
        groupVisGroup.hideOn = function() return GUI.SelectedMode ~= "raid" end
        
        groupVisGroup:AddWidget(GUI:CreateLabel(self.child, "Choose which groups to display.", 250), 25)
        
        -- Initialize raidGroupVisible if it doesn't exist
        if not db.raidGroupVisible then
            db.raidGroupVisible = {[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,[7]=true,[8]=true}
        end
        
        for i = 1, 8 do
            local groupIndex = i
            local overrideKey = "raidGroupVisible_" .. i
            groupVisGroup:AddWidget(GUI:CreateCheckbox(self.child, "Group " .. i, nil, nil, 
                function()
                    if db.raidUseGroups then
                        -- Separated mode
                        DF:UpdateRaidHeaderVisibility(); DF:PositionRaidHeaders()
                    else
                        -- Flat mode - rebuild groupFilter and nameList
                        if DF.FlatRaidFrames then
                            DF.FlatRaidFrames:UpdateContainerSize()
                            DF.FlatRaidFrames:UpdateSorting()
                        end
                    end
                end,
                function() return db.raidGroupVisible[groupIndex] ~= false end,
                function(val) db.raidGroupVisible[groupIndex] = val end,
                overrideKey
            ), 25)
        end
        
        Add(groupVisGroup, nil, 1)
        
        -- ===== GROUP DISPLAY ORDER (Column 2, raid+groups only) =====
        local groupOrderGroup = GUI:CreateSettingsGroup(self.child, 280)
        groupOrderGroup:AddWidget(GUI:CreateHeader(self.child, "Group Display Order"), 40)
        groupOrderGroup.hideOn = function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end
        
        groupOrderGroup:AddWidget(GUI:CreateLabel(self.child, "Drag to reorder groups. Top = first.", 250), 25)
        
        local playerGroupFirstCheck = groupOrderGroup:AddWidget(GUI:CreateCheckbox(self.child, "My Group First", db, "raidPlayerGroupFirst", function()
            if DF.UpdatePlayerGroupTracking then DF:UpdatePlayerGroupTracking() end
            if DF.UpdateRaidGroupOrderAttributes then DF:UpdateRaidGroupOrderAttributes() end
            DF:TriggerRaidPosition()
        end), 25)
        playerGroupFirstCheck.tooltip = "When enabled, the group you are in will always be displayed first."
        
        -- Initialize raidGroupDisplayOrder if it doesn't exist
        if not db.raidGroupDisplayOrder then
            db.raidGroupDisplayOrder = {1, 2, 3, 4, 5, 6, 7, 8}
        end
        
        local groupOrderWidget = GUI:CreateGroupOrderList(self.child, db, "raidGroupDisplayOrder", function()
            if DF.UpdateRaidGroupOrderAttributes then DF:UpdateRaidGroupOrderAttributes() end
            DF:TriggerRaidPosition()
        end)
        groupOrderGroup:AddWidget(groupOrderWidget, 230)
        
        Add(groupOrderGroup, nil, 2)
        
        -- ===== FLAT GRID SETTINGS (Column 1, raid+flat only) =====
        local flatGridGroup = GUI:CreateSettingsGroup(self.child, 280)
        flatGridGroup:AddWidget(GUI:CreateHeader(self.child, "Flat Grid Settings"), 40)
        flatGridGroup.hideOn = function() return GUI.SelectedMode ~= "raid" or db.raidUseGroups end
        
        flatGridGroup:AddWidget(GUI:CreateLabel(self.child, "All players in a unified grid. Sorting applies raid-wide.", 250), 25)
        
        local function UpdateFlatLayoutFull()
            if InCombatLockdown() then return end
            if DF.headersInitialized then DF:ApplyHeaderSettings() end
            if GUI.SelectedMode == "raid" then DF:UpdateRaidLayout() end
        end
        
        local playersPerLabel = db.growDirection == "VERTICAL" and "Players Per Column" or "Players Per Row"
        playersPerRowSlider = flatGridGroup:AddWidget(GUI:CreateSlider(self.child, playersPerLabel, 1, 40, 1, db, "raidPlayersPerRow", UpdateFlatLayoutFull, UpdateFlatLayoutFull, true), 55)
        
        local growthAnchorOptions = { START = "Start", CENTER = "Centre", END = "End" }
        flatGridGroup:AddWidget(GUI:CreateDropdown(self.child, "Frames Grow From", growthAnchorOptions, db, "raidFlatGrowthAnchor", UpdateFrames), 55)
        
        local columnAnchorOptions = { START = "Start (Top/Left)", END = "End (Bottom/Right)" }
        flatGridGroup:AddWidget(GUI:CreateDropdown(self.child, "Columns Grow From", columnAnchorOptions, db, "raidFlatColumnAnchor", UpdateFrames), 55)
        
        flatGridGroup:AddWidget(GUI:CreateCheckbox(self.child, "Reverse Order", db, "raidFlatFrameAnchor", UpdateFrames, 
            function() return db.raidFlatFrameAnchor == "END" end,
            function(val) db.raidFlatFrameAnchor = val and "END" or "START" end
        ), 30)
        
        flatGridGroup:AddWidget(GUI:CreateSlider(self.child, "Horizontal Spacing", -5, 100, 1, db, "raidFlatHorizontalSpacing", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
        flatGridGroup:AddWidget(GUI:CreateSlider(self.child, "Vertical Spacing", -5, 100, 1, db, "raidFlatVerticalSpacing", UpdateFrames, function() DF:LightweightUpdateFrameSize() end, true), 55)
        
        Add(flatGridGroup, nil, 1)
        
        -- Update labels on show
        if groupsPerRowSlider and groupsPerRowSlider.label then
            groupsPerRowSlider:HookScript("OnShow", UpdateDynamicLabels)
        end
        if rowColSpacingSlider and rowColSpacingSlider.label then
            rowColSpacingSlider:HookScript("OnShow", UpdateDynamicLabels)
        end
        if playersPerRowSlider and playersPerRowSlider.label then
            playersPerRowSlider:HookScript("OnShow", UpdateDynamicLabels)
        end
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "general_sorting", label = "Sorting"},
            {pageId = "bars_health", label = "Health Bar"},
            {pageId = "text_name", label = "Name Text"},
        }), 30, "both")
    end)
    
    -- General > Global Fonts
    local pageGlobalFonts = CreateSubTab("general", "general_fonts", "Global Fonts")
    BuildPage(pageGlobalFonts, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Initialize temp storage for selections (persists during session)
        if not DF.GlobalFontTemp then
            DF.GlobalFontTemp = {
                font = db.nameFont or "Fonts\\FRIZQT__.TTF",
                outline = db.nameTextOutline or "OUTLINE",
            }
        end
        
        -- ===== FONT SELECTION GROUP (Column 1) =====
        local fontSelectGroup = GUI:CreateSettingsGroup(self.child, 280)
        fontSelectGroup:AddWidget(GUI:CreateHeader(self.child, "Global Font Settings"), 40)
        fontSelectGroup:AddWidget(GUI:CreateLabel(self.child, "Set a font and outline style, then click Apply to update ALL text elements.", 250), 40)
        
        fontSelectGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", DF.GlobalFontTemp, "font", function() end), 55)
        
        local outlineOptions = {
            NONE = "None",
            OUTLINE = "Outline",
            THICKOUTLINE = "Thick Outline",
            SHADOW = "Shadow",
        }
        fontSelectGroup:AddWidget(GUI:CreateDropdown(self.child, "Outline", outlineOptions, DF.GlobalFontTemp, "outline", function() end), 55)
        
        -- Themed Apply button
        local applyBtn = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        applyBtn:SetSize(120, 28)
        applyBtn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        applyBtn:SetBackdropColor(0.18, 0.18, 0.18, 1)
        applyBtn:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
        
        applyBtn.text = applyBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        applyBtn.text:SetPoint("CENTER", 0, 0)
        applyBtn.text:SetText("Apply to All")
        applyBtn.text:SetTextColor(0.9, 0.9, 0.9, 1)
        
        applyBtn:SetScript("OnEnter", function(s)
            s:SetBackdropColor(0.45, 0.45, 0.95, 0.3)
            s:SetBackdropBorderColor(0.45, 0.45, 0.95, 1)
            s.text:SetTextColor(1, 1, 1, 1)
        end)
        applyBtn:SetScript("OnLeave", function(s)
            s:SetBackdropColor(0.18, 0.18, 0.18, 1)
            s:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
            s.text:SetTextColor(0.9, 0.9, 0.9, 1)
        end)
        applyBtn:SetScript("OnMouseDown", function(s) s:SetBackdropColor(0.45, 0.45, 0.95, 0.5) end)
        applyBtn:SetScript("OnMouseUp", function(s) s:SetBackdropColor(0.45, 0.45, 0.95, 0.3) end)
        applyBtn:SetScript("OnClick", function()
            local font = DF.GlobalFontTemp.font
            local outline = DF.GlobalFontTemp.outline
            
            -- Clear font family cache so new fonts are created
            if DF.ClearFontCache then DF:ClearFontCache() end
            
            -- Apply to all font settings
            db.nameFont = font; db.nameTextOutline = outline
            db.healthFont = font; db.healthTextOutline = outline
            db.statusTextFont = font; db.statusTextOutline = outline
            db.buffStackFont = font; db.buffStackOutline = outline
            db.buffDurationFont = font; db.buffDurationOutline = outline
            db.debuffStackFont = font; db.debuffStackOutline = outline
            db.debuffDurationFont = font; db.debuffDurationOutline = outline
            db.petNameFont = font; db.petNameFontOutline = outline
            db.petHealthFont = font; db.petHealthFontOutline = outline
            db.targetedSpellDurationFont = font; db.targetedSpellDurationOutline = outline
            db.personalTargetedSpellDurationFont = font; db.personalTargetedSpellDurationOutline = outline
            db.defensiveIconDurationFont = font; db.defensiveIconDurationOutline = outline
            db.statusIconFont = font; db.statusIconFontOutline = outline
            if db.groupLabelFont ~= nil then
                db.groupLabelFont = font; db.groupLabelOutline = outline
            end
            
            DF:UpdateAllFrames()
            if GUI.SelectedMode == "raid" and DF.UpdateRaidLayout then DF:UpdateRaidLayout() end
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
            if DF.UpdateAllTargetedSpellLayouts then DF:UpdateAllTargetedSpellLayouts() end
            if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestTargetedSpell then DF:UpdateAllTestTargetedSpell() end
            if DF.UpdateTestPersonalTargetedSpells then DF:UpdateTestPersonalTargetedSpells() end
            if DF.UpdateAllFramesStatusIcons then DF:UpdateAllFramesStatusIcons() end
            
            -- Refresh test frames to apply new fonts
            if DF.RefreshTestFrames then DF:RefreshTestFrames() end
            
            print("|cff00ff00DandersFrames:|r Applied global font settings to all text elements.")
        end)
        fontSelectGroup:AddWidget(applyBtn, 35)
        
        Add(fontSelectGroup, nil, 1)
        
        -- ===== SHADOW SETTINGS GROUP (Column 1) =====
        local shadowGroup = GUI:CreateSettingsGroup(self.child, 280)
        shadowGroup:AddWidget(GUI:CreateHeader(self.child, "Shadow Settings"), 40)
        shadowGroup:AddWidget(GUI:CreateLabel(self.child, "These settings apply when using 'Shadow' outline style. Use larger offsets for more dramatic shadows.", 250), 40)
        
        local function UpdateShadowSettings()
            -- Full update on release
            if DF.ClearFontCache then DF:ClearFontCache() end
            DF:UpdateAllFrames()
            if GUI.SelectedMode == "raid" and DF.UpdateRaidLayout then DF:UpdateRaidLayout() end
            if DF.ApplyPetSettings then DF:ApplyPetSettings() end
        end
        
        local function LightweightShadowUpdate()
            if DF.LightweightUpdateFontShadows then DF:LightweightUpdateFontShadows() end
        end
        
        shadowGroup:AddWidget(GUI:CreateSlider(self.child, "Shadow X Offset", -10, 10, 0.5, db, "fontShadowOffsetX", UpdateShadowSettings, LightweightShadowUpdate), 50)
        shadowGroup:AddWidget(GUI:CreateSlider(self.child, "Shadow Y Offset", -10, 10, 0.5, db, "fontShadowOffsetY", UpdateShadowSettings, LightweightShadowUpdate), 50)
        shadowGroup:AddWidget(GUI:CreateColorPicker(self.child, "Shadow Color", db, "fontShadowColor", true, UpdateShadowSettings, LightweightShadowUpdate, true), 40)
        
        Add(shadowGroup, nil, 1)
        
        -- ===== AFFECTED ELEMENTS GROUP (Column 2) =====
        local infoGroup = GUI:CreateSettingsGroup(self.child, 280)
        infoGroup:AddWidget(GUI:CreateHeader(self.child, "Affected Elements"), 40)
        infoGroup:AddWidget(GUI:CreateLabel(self.child, "• Name Text\n• Health Text\n• Status Text (Dead/Offline)\n• Buff Stack & Duration\n• Debuff Stack & Duration\n• Pet Frame Text\n• Targeted Spell Duration\n• Defensive Icon Duration\n• Status Icon Text (Res, Summon, etc.)\n• Group Labels (Raid)", 250), 175)
        infoGroup:AddWidget(GUI:CreateLabel(self.child, "Note: Font sizes are not changed. Adjust sizes in each element's page.", 250), 40)
        Add(infoGroup, nil, 2)
    end)
    
    -- General > Group Labels (Raid only, group-based layout only)
    local pageGroupLabels = CreateSubTab("general", "general_labels", "Group Labels")
    BuildPage(pageGroupLabels, function(self, db, Add, AddSpace, AddSyncPoint)
        local function HideGroupLabelOptions(d)
            return GUI.SelectedMode ~= "raid" or not d.raidUseGroups or not d.groupLabelEnabled
        end
        
        local function UpdateLabels()
            if DF.UpdateRaidGroupLabels then DF:UpdateRaidGroupLabels() end
        end
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Raid Group Labels"), 40)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, "Display labels above or beside each raid group.", 250), 25)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Group Labels", db, "groupLabelEnabled", UpdateLabels), 30)
        settingsGroup.hideOn = function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end
        Add(settingsGroup, nil, 1)
        
        -- ===== TEXT FORMAT GROUP (Column 1) =====
        local formatGroup = GUI:CreateSettingsGroup(self.child, 280)
        formatGroup:AddWidget(GUI:CreateHeader(self.child, "Text Format"), 40)
        
        local formatOptions = {
            ["GROUP_NUM"] = "Group 1",
            ["SHORT"] = "G1",
            ["NUM_ONLY"] = "1",
            ["ROMAN"] = "I, II, III...",
        }
        formatGroup:AddWidget(GUI:CreateDropdown(self.child, "Label Format", formatOptions, db, "groupLabelFormat", UpdateLabels), 55)
        formatGroup.hideOn = HideGroupLabelOptions
        Add(formatGroup, nil, 1)
        
        -- ===== FONT GROUP (Column 1) =====
        local fontGroup = GUI:CreateSettingsGroup(self.child, 280)
        fontGroup:AddWidget(GUI:CreateHeader(self.child, "Font Settings"), 40)
        fontGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "groupLabelFont", UpdateLabels), 55)
        fontGroup:AddWidget(GUI:CreateSlider(self.child, "Font Size", 8, 24, 1, db, "groupLabelFontSize", UpdateLabels, function() DF:LightweightUpdateGroupLabels() end, true), 55)
        
        local outlineOptions = {
            ["NONE"] = "None",
            ["OUTLINE"] = "Outline",
            ["THICKOUTLINE"] = "Thick Outline",
            ["SHADOW"] = "Shadow",
        }
        fontGroup:AddWidget(GUI:CreateDropdown(self.child, "Outline", outlineOptions, db, "groupLabelOutline", UpdateLabels), 55)
        fontGroup:AddWidget(GUI:CreateColorPicker(self.child, "Label Color", db, "groupLabelColor", true, UpdateLabels, function() DF:LightweightUpdateGroupLabelColor() end, true), 35)
        fontGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Shadow", db, "groupLabelShadow", UpdateLabels), 30)
        fontGroup.hideOn = HideGroupLabelOptions
        Add(fontGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
        
        local positionOptions = {
            ["START"] = "Start of Group",
            ["CENTER"] = "Center of Group",
            ["END"] = "End of Group",
        }
        positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Label Position", positionOptions, db, "groupLabelPosition", UpdateLabels), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -100, 100, 1, db, "groupLabelOffsetX", UpdateLabels, function() DF:LightweightUpdateGroupLabels() end, true), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -100, 100, 1, db, "groupLabelOffsetY", UpdateLabels, function() DF:LightweightUpdateGroupLabels() end, true), 55)
        positionGroup:AddWidget(GUI:CreateLabel(self.child, "Start: Above/left of groups.\nCenter: Middle of the group.\nEnd: Below/right of groups.", 250), 50)
        positionGroup.hideOn = HideGroupLabelOptions
        Add(positionGroup, nil, 2)
        
        -- Party mode message
        local partyMsg = Add(GUI:CreateLabel(self.child, "Group labels are only available for raid frames.\n\nSwitch to Raid mode using the toggle at the top\nof the settings panel to configure group labels.", 400), 80, "both")
        partyMsg.hideOn = function() return GUI.SelectedMode == "raid" end
        
        -- Flat mode message
        local flatMsg = Add(GUI:CreateLabel(self.child, "Group labels are not available in Flat Grid layout.\n\nEnable 'Use Group-Based Layout' in Frame settings\nto use group labels.", 400), 80, "both")
        flatMsg.hideOn = function() return GUI.SelectedMode ~= "raid" or db.raidUseGroups end
    end)
    
    -- General > Pinned Frames
    local pagePinnedFrames = CreateSubTab("general", "general_pinnedframes", "Pinned Frames")
    BuildPage(pagePinnedFrames, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Constants
        local HIGHLIGHT_MAX_SETS = 2
        
        -- Initialize pinnedFrames in db if needed
        if not db.pinnedFrames then
            db.pinnedFrames = {
                sets = {
                    [1] = {
                        enabled = false, name = "Pinned 1", players = {},
                        growDirection = "HORIZONTAL", unitsPerRow = 5,
                        horizontalSpacing = 2, verticalSpacing = 2, scale = 1.0,
                        position = { point = "CENTER", x = 0, y = 200 },
                        locked = false, showLabel = false,
                        autoAddTanks = false, autoAddHealers = false, autoAddDPS = false,
                        keepOfflinePlayers = true,
                    },
                    [2] = {
                        enabled = false, name = "Pinned 2", players = {},
                        growDirection = "HORIZONTAL", unitsPerRow = 5,
                        horizontalSpacing = 2, verticalSpacing = 2, scale = 1.0,
                        position = { point = "CENTER", x = 0, y = -200 },
                        locked = false, showLabel = false,
                        autoAddTanks = false, autoAddHealers = false, autoAddDPS = false,
                        keepOfflinePlayers = true,
                    },
                },
            }
        end
        
        -- Migration: add new options to existing sets
        for i = 1, 2 do
            local set = db.pinnedFrames.sets[i]
            if set then
                if set.autoAddTanks == nil then set.autoAddTanks = false end
                if set.autoAddHealers == nil then set.autoAddHealers = false end
                if set.autoAddDPS == nil then set.autoAddDPS = false end
                if set.keepOfflinePlayers == nil then set.keepOfflinePlayers = true end
                if set.columnAnchor == nil then set.columnAnchor = "START" end
                if set.frameAnchor == nil then set.frameAnchor = "START" end
            end
        end
        
        -- Current active tab
        local activeHighlightTab = 1
        local tabButtons = {}
        local controlsToRefresh = {}
        
        local function GetCurrentSet()
            return db.pinnedFrames.sets[activeHighlightTab]
        end
        
        local function RefreshControls()
            for _, ctrl in ipairs(controlsToRefresh) do
                if ctrl.Refresh then ctrl:Refresh() end
            end
        end
        
        local function RefreshTabs()
            local themeColor = GUI.GetThemeColor()
            for i, tab in ipairs(tabButtons) do
                local set = db.pinnedFrames.sets[i]
                local isActive = (i == activeHighlightTab)
                if isActive then
                    tab:SetBackdropColor(0.18, 0.18, 0.18, 1)
                    tab:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
                    tab.text:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
                else
                    tab:SetBackdropColor(0.1, 0.1, 0.1, 1)
                    tab:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
                    tab.text:SetTextColor(0.5, 0.5, 0.5)
                end
                local displayName = set.name
                if displayName == "Highlight " .. i or displayName == "" then displayName = "Highlight " .. i end
                tab.text:SetText(displayName)
            end
        end
        
        -- ===== HEADER GROUP (full width) =====
        local headerGroup = GUI:CreateSettingsGroup(self.child, 560)
        headerGroup:AddWidget(GUI:CreateHeader(self.child, "Pinned Frames"), 40)
        headerGroup:AddWidget(GUI:CreateLabel(self.child, "Create separate frame groups to pin specific players like tanks, healers, or key raid members. Drag players from your group roster to add them.", 530), 40)
        Add(headerGroup, nil, "both")
        
        -- Tab container
        local tabContainer = CreateFrame("Frame", nil, self.child)
        tabContainer:SetSize(460, 32)
        Add(tabContainer, 32, "both")
        
        for i = 1, HIGHLIGHT_MAX_SETS do
            local tab = CreateFrame("Button", nil, tabContainer, "BackdropTemplate")
            tab:SetSize(120, 28)
            tab:SetPoint("LEFT", tabContainer, "LEFT", (i - 1) * 124, 0)
            tab:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
            tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            tab.text:SetPoint("CENTER")
            tab.text:SetText("Highlight " .. i)
            tab:SetScript("OnClick", function() activeHighlightTab = i; RefreshTabs(); RefreshControls() end)
            tab:SetScript("OnEnter", function(s) if activeHighlightTab ~= i then s:SetBackdropBorderColor(0.4, 0.4, 0.4, 1); s.text:SetTextColor(0.7, 0.7, 0.7) end end)
            tab:SetScript("OnLeave", function() RefreshTabs() end)
            tabButtons[i] = tab
        end
        RefreshTabs()
        
        AddSpace(10, "both")
        
        -- Helper function to create refreshable checkbox
        local function CreateRefreshableCheckbox(parent, label, dbKey, callback)
            local container = CreateFrame("Frame", nil, parent)
            container:SetSize(250, 24)
            local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
            cb:SetSize(18, 18)
            cb:SetPoint("LEFT", 0, 0)
            cb:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
            cb:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            cb:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
            cb.Check = cb:CreateTexture(nil, "OVERLAY")
            cb.Check:SetTexture("Interface\\Buttons\\WHITE8x8")
            local tc = GUI.GetThemeColor()
            cb.Check:SetVertexColor(tc.r, tc.g, tc.b)
            cb.Check:SetPoint("CENTER")
            cb.Check:SetSize(10, 10)
            cb:SetCheckedTexture(cb.Check)
            local txt = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            txt:SetPoint("LEFT", cb, "RIGHT", 8, 0)
            txt:SetText(label)
            txt:SetTextColor(0.8, 0.8, 0.8)
            cb:SetScript("OnClick", function(s) GetCurrentSet()[dbKey] = s:GetChecked(); if callback then callback(GetCurrentSet()) end; DF:UpdateAll() end)
            container.Refresh = function() cb:SetChecked(GetCurrentSet()[dbKey]) end
            container.Refresh()
            table.insert(controlsToRefresh, container)
            return container
        end
        
        -- Helper function to create refreshable slider
        local function CreateRefreshableSlider(parent, label, minVal, maxVal, step, dbKey, callback)
            local container = CreateFrame("Frame", nil, parent)
            container:SetSize(250, 50)
            local lbl = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lbl:SetPoint("TOPLEFT", 0, 0)
            lbl:SetText(label)
            lbl:SetTextColor(0.8, 0.8, 0.8)
            local track = CreateFrame("Frame", nil, container, "BackdropTemplate")
            track:SetPoint("TOPLEFT", 0, -18)
            track:SetSize(170, 8)
            track:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
            track:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            track:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
            local fill = track:CreateTexture(nil, "ARTWORK")
            fill:SetPoint("LEFT", 1, 0)
            fill:SetHeight(6)
            local tc = GUI.GetThemeColor()
            fill:SetColorTexture(tc.r, tc.g, tc.b, 0.8)
            local slider = CreateFrame("Slider", nil, container)
            slider:SetPoint("TOPLEFT", 0, -18)
            slider:SetSize(170, 8)
            slider:SetOrientation("HORIZONTAL")
            slider:SetMinMaxValues(minVal, maxVal)
            slider:SetValueStep(step)
            slider:SetObeyStepOnDrag(true)
            slider:SetHitRectInsets(-4, -4, -8, -8)
            local thumb = slider:CreateTexture(nil, "OVERLAY")
            thumb:SetSize(12, 16)
            thumb:SetColorTexture(tc.r, tc.g, tc.b, 1)
            slider:SetThumbTexture(thumb)
            local input = CreateFrame("EditBox", nil, container, "BackdropTemplate")
            input:SetPoint("LEFT", track, "RIGHT", 8, 0)
            input:SetSize(50, 20)
            input:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
            input:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            input:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
            input:SetFontObject(GameFontHighlightSmall)
            input:SetJustifyH("CENTER")
            input:SetAutoFocus(false)
            input:SetTextInsets(2, 2, 0, 0)
            local function UpdateFill() local pct = (slider:GetValue() - minVal) / (maxVal - minVal); fill:SetWidth(math.max(1, pct * 168)) end
            local function UpdateValue(val) slider:SetValue(val); input:SetText(step < 1 and string.format("%.1f", val) or string.format("%d", val)); UpdateFill() end
            slider:SetScript("OnValueChanged", function(_, value) GetCurrentSet()[dbKey] = value; input:SetText(step < 1 and string.format("%.1f", value) or string.format("%d", value)); UpdateFill(); if callback then callback() end end)
            input:SetScript("OnEnterPressed", function(s) local val = tonumber(s:GetText()); if val then val = math.max(minVal, math.min(maxVal, val)); GetCurrentSet()[dbKey] = val; slider:SetValue(val); s:SetText(step < 1 and string.format("%.1f", val) or string.format("%d", val)); UpdateFill(); if callback then callback() end; DF:UpdateAll() end; s:ClearFocus() end)
            input:SetScript("OnEscapePressed", function(s) s:ClearFocus(); UpdateValue(GetCurrentSet()[dbKey]) end)
            container.Refresh = function() UpdateValue(GetCurrentSet()[dbKey] or minVal) end
            container.Refresh()
            table.insert(controlsToRefresh, container)
            return container
        end
        
        -- Helper function to create refreshable dropdown
        local function CreateRefreshableDropdown(parent, label, options, dbKey, callback)
            local wrapper = CreateFrame("Frame", nil, parent)
            wrapper:SetSize(250, 50)
            local lbl = wrapper:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lbl:SetPoint("TOPLEFT", 0, 0)
            lbl:SetText(label)
            lbl:SetTextColor(0.8, 0.8, 0.8)
            local btn = CreateFrame("Button", nil, wrapper, "BackdropTemplate")
            btn:SetPoint("TOPLEFT", 0, -16)
            btn:SetSize(220, 24)
            btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
            btn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            btn.Text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.Text:SetPoint("LEFT", 8, 0)
            btn.Text:SetPoint("RIGHT", -20, 0)
            btn.Text:SetJustifyH("LEFT")
            btn.Text:SetTextColor(0.8, 0.8, 0.8)
            local arrow = btn:CreateTexture(nil, "OVERLAY")
            arrow:SetPoint("RIGHT", -8, 0)
            arrow:SetSize(12, 12)
            arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            arrow:SetVertexColor(0.5, 0.5, 0.5)
            local function UpdateText() btn.Text:SetText(options[GetCurrentSet()[dbKey]] or "Select...") end
            local menuFrame = CreateFrame("Frame", nil, btn, "BackdropTemplate")
            menuFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
            menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
            menuFrame:SetClampedToScreen(true)
            menuFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
            menuFrame:SetBackdropColor(0.12, 0.12, 0.12, 0.98)
            menuFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            menuFrame:Hide()
            local menuHeight = 0
            local sortedOptions = {}
            for k, v in pairs(options) do table.insert(sortedOptions, {key = k, value = v}) end
            table.sort(sortedOptions, function(a, b) return tostring(a.value) < tostring(b.value) end)
            for idx, opt in ipairs(sortedOptions) do
                local menuBtn = CreateFrame("Button", nil, menuFrame)
                menuBtn:SetPoint("TOPLEFT", 2, -2 - (idx - 1) * 22)
                menuBtn:SetPoint("TOPRIGHT", -2, -2 - (idx - 1) * 22)
                menuBtn:SetHeight(22)
                menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                menuBtn.Text:SetPoint("LEFT", 8, 0)
                menuBtn.Text:SetText(opt.value)
                menuBtn.Text:SetTextColor(0.8, 0.8, 0.8)
                menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
                menuBtn.Highlight:SetAllPoints()
                local tc = GUI.GetThemeColor()
                menuBtn.Highlight:SetColorTexture(tc.r, tc.g, tc.b, 0.3)
                menuBtn:SetScript("OnClick", function() GetCurrentSet()[dbKey] = opt.key; UpdateText(); menuFrame:Hide(); if callback then callback() end end)
                menuHeight = menuHeight + 22
            end
            menuFrame:SetSize(220, menuHeight + 4)
            btn:SetScript("OnClick", function() if menuFrame:IsShown() then menuFrame:Hide() else menuFrame:Show() end end)
            btn:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(0.5, 0.5, 0.5, 1) end)
            btn:SetScript("OnLeave", function(s) s:SetBackdropBorderColor(0.3, 0.3, 0.3, 1) end)
            wrapper.Refresh = function() UpdateText() end
            UpdateText()
            table.insert(controlsToRefresh, wrapper)
            return wrapper
        end
        
        -- Helper function to update layout
        local function UpdateHighlightLayout()
            if DF.PinnedFrames then
                DF.PinnedFrames:ApplyLayoutSettings(activeHighlightTab)
                DF.PinnedFrames:ResizeContainer(activeHighlightTab)
            end
        end
        
        -- Forward declaration for roster widget
        local rosterWidget
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Settings"), 40)
        
        settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, "Enable", "enabled", function()
            if DF.PinnedFrames then DF.PinnedFrames:SetEnabled(activeHighlightTab, GetCurrentSet().enabled) end
        end), 28)
        settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, "Lock Position", "locked", function()
            if DF.PinnedFrames then DF.PinnedFrames:SetLocked(activeHighlightTab, GetCurrentSet().locked) end
        end), 28)
        settingsGroup:AddWidget(CreateRefreshableCheckbox(self.child, "Show Label", "showLabel", function()
            if DF.PinnedFrames then DF.PinnedFrames:SetShowLabel(activeHighlightTab, GetCurrentSet().showLabel) end
        end), 28)
        
        -- Label name input
        local nameInputContainer = CreateFrame("Frame", nil, self.child)
        nameInputContainer:SetSize(250, 44)
        local nameLabel = nameInputContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameLabel:SetPoint("TOPLEFT", 0, 0)
        nameLabel:SetText("Label Name")
        nameLabel:SetTextColor(0.8, 0.8, 0.8)
        local nameInput = CreateFrame("EditBox", nil, nameInputContainer, "BackdropTemplate")
        nameInput:SetPoint("TOPLEFT", 0, -15)
        nameInput:SetSize(220, 24)
        nameInput:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        nameInput:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        nameInput:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        nameInput:SetFontObject(GameFontHighlight)
        nameInput:SetTextInsets(8, 8, 0, 0)
        nameInput:SetAutoFocus(false)
        nameInput:SetMaxLetters(30)
        nameInput:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        nameInput:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
        nameInput:SetScript("OnEditFocusLost", function(s)
            GetCurrentSet().name = s:GetText()
            RefreshTabs()
            if DF.PinnedFrames then DF.PinnedFrames:UpdateLabel(activeHighlightTab) end
        end)
        nameInputContainer.Refresh = function() nameInput:SetText(GetCurrentSet().name or "") end
        table.insert(controlsToRefresh, nameInputContainer)
        settingsGroup:AddWidget(nameInputContainer, 48)
        
        Add(settingsGroup, nil, 1)
        
        -- ===== LAYOUT GROUP (Column 2) =====
        local layoutGroup = GUI:CreateSettingsGroup(self.child, 280)
        layoutGroup:AddWidget(GUI:CreateHeader(self.child, "Layout"), 40)
        
        local directionOptions = { HORIZONTAL = "Horizontal", VERTICAL = "Vertical" }
        layoutGroup:AddWidget(CreateRefreshableDropdown(self.child, "Direction", directionOptions, "growDirection", UpdateHighlightLayout), 55)
        
        local frameAnchorOptions = { START = "Start (Left/Top)", END = "End (Right/Bottom)" }
        layoutGroup:AddWidget(CreateRefreshableDropdown(self.child, "Frame Growth", frameAnchorOptions, "frameAnchor", UpdateHighlightLayout), 55)
        
        local columnAnchorOptions = { START = "Start (Left/Top)", END = "End (Right/Bottom)" }
        layoutGroup:AddWidget(CreateRefreshableDropdown(self.child, "Column Growth", columnAnchorOptions, "columnAnchor", UpdateHighlightLayout), 55)
        
        layoutGroup:AddWidget(CreateRefreshableSlider(self.child, "Units Per Row", 1, 10, 1, "unitsPerRow", UpdateHighlightLayout), 55)
        layoutGroup:AddWidget(CreateRefreshableSlider(self.child, "Scale", 0.5, 2.0, 0.1, "scale", UpdateHighlightLayout), 55)
        
        Add(layoutGroup, nil, 2)
        
        -- ===== SPACING GROUP (Column 1) =====
        local spacingGroup = GUI:CreateSettingsGroup(self.child, 280)
        spacingGroup:AddWidget(GUI:CreateHeader(self.child, "Spacing"), 40)
        spacingGroup:AddWidget(CreateRefreshableSlider(self.child, "Horizontal Spacing", -5, 50, 1, "horizontalSpacing", UpdateHighlightLayout), 55)
        spacingGroup:AddWidget(CreateRefreshableSlider(self.child, "Vertical Spacing", -5, 50, 1, "verticalSpacing", UpdateHighlightLayout), 55)
        Add(spacingGroup, nil, 1)
        
        -- ===== AUTO-POPULATE GROUP (Column 2) =====
        local autoPopGroup = GUI:CreateSettingsGroup(self.child, 280)
        autoPopGroup:AddWidget(GUI:CreateHeader(self.child, "Auto-Populate"), 40)
        autoPopGroup:AddWidget(GUI:CreateLabel(self.child, "Automatically add players by role when they join your group.", 250), 30)
        
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, "Auto-add Tanks", "autoAddTanks", function()
            if GetCurrentSet().autoAddTanks and DF.PinnedFrames then
                DF.PinnedFrames:AutoPopulateSet(GetCurrentSet())
                DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab)
                if rosterWidget then rosterWidget:Refresh() end
            end
        end), 28)
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, "Auto-add Healers", "autoAddHealers", function()
            if GetCurrentSet().autoAddHealers and DF.PinnedFrames then
                DF.PinnedFrames:AutoPopulateSet(GetCurrentSet())
                DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab)
                if rosterWidget then rosterWidget:Refresh() end
            end
        end), 28)
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, "Auto-add DPS", "autoAddDPS", function()
            if GetCurrentSet().autoAddDPS and DF.PinnedFrames then
                DF.PinnedFrames:AutoPopulateSet(GetCurrentSet())
                DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab)
                if rosterWidget then rosterWidget:Refresh() end
            end
        end), 28)
        autoPopGroup:AddWidget(CreateRefreshableCheckbox(self.child, "Keep when offline/left", "keepOfflinePlayers", function() end), 28)
        
        Add(autoPopGroup, nil, 2)
        
        -- ===== UNIT SELECTION (full width) =====
        AddSpace(10, "both")
        Add(GUI:CreateHeader(self.child, "Unit Selection"), 40, "both")
        
        rosterWidget = GUI:CreateHighlightRosterWidget(
            self.child,
            function() return GetCurrentSet().players end,
            function(players) GetCurrentSet().players = players end,
            function()
                if DF.PinnedFrames then DF.PinnedFrames:UpdateHeaderNameList(activeHighlightTab) end
            end
        )
        
        local originalRefresh = rosterWidget.Refresh
        rosterWidget.Refresh = function(s) if originalRefresh then originalRefresh(s) end end
        table.insert(controlsToRefresh, rosterWidget)
        Add(rosterWidget, 340, "both")
        
        RefreshControls()
    end)
    
    -- General > Sorting
    local pageSorting = CreateSubTab("general", "general_sorting", "Sorting")
    BuildPage(pageSorting, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"sort", "selfPosition", "rolePriority", "classPriority"}, "Sorting"), 25, 2)
        
        -- Helper function to trigger sort for current mode
        local function TriggerSortForCurrentMode()
            if DF.testMode or DF.raidTestMode then
                if DF.RefreshTestFramesWithLayout then DF:RefreshTestFramesWithLayout() end
                return
            end
            if DF.headersInitialized then DF:ApplyHeaderSettings() end
            -- Arena: ApplyHeaderSettings handles orientation but not sorting.
            -- Call ApplyArenaHeaderSorting directly for settings changes from the GUI.
            if DF.IsInArena and DF:IsInArena() then
                if not InCombatLockdown() and DF.ApplyArenaHeaderSorting then
                    DF:ApplyArenaHeaderSorting()
                end
            elseif GUI.SelectedMode == "raid" then
                if DF.SecureSort then
                    DF.SecureSort:PushRaidSortSettings()
                    DF.SecureSort:TriggerSecureRaidSort()
                end
            else
                if DF.Sort then DF.Sort:TriggerResort() end
            end
        end
        
        local function HideSortOptions(d)
            return not d.sortEnabled
        end
        
        -- Store reference to role widget so we can refresh it
        local roleOrderWidget = nil
        
        -- ===== COMBAT STATUS BANNER (full width) =====
        local combatBanner = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
        combatBanner:SetSize(560, 45)
        combatBanner:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        
        local combatBannerIcon = combatBanner:CreateTexture(nil, "OVERLAY")
        combatBannerIcon:SetSize(20, 20)
        combatBannerIcon:SetPoint("LEFT", 12, 0)
        
        local combatBannerText = combatBanner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        combatBannerText:SetPoint("LEFT", combatBannerIcon, "RIGHT", 8, 0)
        combatBannerText:SetPoint("RIGHT", -12, 0)
        combatBannerText:SetJustifyH("LEFT")
        combatBannerText:SetWordWrap(true)
        
        local function UpdateCombatBanner()
            if not db.sortEnabled then
                combatBanner:Hide()
                return
            end
            
            combatBanner:Show()
            
            local selfPos = db.sortSelfPosition or "SORTED"
            local hasAdvancedOptions = db.sortSeparateMeleeRanged or db.sortByClass or db.sortAlphabetical
            
            if hasAdvancedOptions then
                -- All groups limited
                combatBanner:SetBackdropColor(0.6, 0.3, 0.1, 0.9)
                combatBanner:SetBackdropBorderColor(0.8, 0.4, 0.1, 1)
                combatBannerIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\warning")
                combatBannerIcon:SetVertexColor(1, 0.6, 0.2)
                combatBannerText:SetText("Combat Limitation: All groups will not update with new players that join mid-combat.")
                combatBannerText:SetTextColor(1, 0.85, 0.7)
            elseif selfPos == "FIRST" or selfPos == "LAST" then
                -- Player's group limited
                combatBanner:SetBackdropColor(0.5, 0.45, 0.1, 0.9)
                combatBanner:SetBackdropBorderColor(0.7, 0.6, 0.1, 1)
                combatBannerIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\info")
                combatBannerIcon:SetVertexColor(1, 0.9, 0.3)
                combatBannerText:SetText("Combat Limitation: Your group will not update with new players that join mid-combat.")
                combatBannerText:SetTextColor(1, 0.95, 0.7)
            else
                -- Fully combat safe
                combatBanner:SetBackdropColor(0.1, 0.4, 0.2, 0.9)
                combatBanner:SetBackdropBorderColor(0.2, 0.6, 0.3, 1)
                combatBannerIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
                combatBannerIcon:SetVertexColor(0.3, 1, 0.5)
                combatBannerText:SetText("Fully Combat Safe: Frames will update normally during combat.")
                combatBannerText:SetTextColor(0.7, 1, 0.8)
            end
        end
        
        combatBanner.hideOn = HideSortOptions
        combatBanner.UpdateBanner = UpdateCombatBanner
        Add(combatBanner, 50, "both")
        
        -- Initial update
        UpdateCombatBanner()
        
        -- ===== SORTING OPTIONS GROUP (Column 1) =====
        local sortOptionsGroup = GUI:CreateSettingsGroup(self.child, 280)
        sortOptionsGroup:AddWidget(GUI:CreateHeader(self.child, "Unit Frame Sorting"), 40)
        sortOptionsGroup:AddWidget(GUI:CreateLabel(self.child, "Sort party members by role, class, and name.\n\nSort order: Self Position > Role > Class > Name", 250), 60)
        
        local raidSortNote = sortOptionsGroup:AddWidget(GUI:CreateLabel(self.child, "Raid: Group layout sorts within each group.\nFlat grid layout sorts all players together.", 250), 35)
        raidSortNote.hideOn = function() return GUI.SelectedMode ~= "raid" end
        
        sortOptionsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Custom Sorting", db, "sortEnabled", function()
            TriggerSortForCurrentMode()
            UpdateCombatBanner()
        end), 30)
        
        local sortMeleeRanged = sortOptionsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Separate Melee & Ranged DPS", db, "sortSeparateMeleeRanged", function()
            TriggerSortForCurrentMode()
            if roleOrderWidget and roleOrderWidget.Refresh then roleOrderWidget.Refresh() end
            UpdateCombatBanner()
        end), 30)
        sortMeleeRanged.hideOn = HideSortOptions
        
        local sortByClass = sortOptionsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Sort by Class (within role)", db, "sortByClass", function()
            TriggerSortForCurrentMode()
            self:RefreshStates()
            UpdateCombatBanner()
        end), 30)
        sortByClass.hideOn = HideSortOptions
        
        local sortAlphaValues = {
            [false] = "Off",
            ["AZ"] = "A to Z",
            ["ZA"] = "Z to A",
            _order = {false, "AZ", "ZA"},
        }
        local sortAlpha = sortOptionsGroup:AddWidget(GUI:CreateDropdown(self.child, "Alphabetical (within class/role)", sortAlphaValues, db, "sortAlphabetical", function()
            TriggerSortForCurrentMode()
            UpdateCombatBanner()
        end), 55)
        sortAlpha.hideOn = HideSortOptions
        
        Add(sortOptionsGroup, nil, 1)
        
        -- ===== SELF POSITION GROUP (Column 1) =====
        local selfPosGroup = GUI:CreateSettingsGroup(self.child, 280)
        selfPosGroup:AddWidget(GUI:CreateHeader(self.child, "Self Position"), 40)
        
        local selfPosValues = {
            ["FIRST"] = "Always First",
            ["LAST"] = "Always Last",
            ["SORTED"] = "Sorted with Group",
            ["NORMAL"] = "Sorted with Group",
            _order = {"FIRST", "LAST", "SORTED"},
        }
        selfPosGroup:AddWidget(GUI:CreateDropdown(self.child, "Position", selfPosValues, db, "sortSelfPosition", function()
            TriggerSortForCurrentMode()
            UpdateCombatBanner()
        end), 55)
        selfPosGroup.hideOn = HideSortOptions
        Add(selfPosGroup, nil, 1)
        
        -- ===== ROLE PRIORITY GROUP (Column 2) =====
        local rolePriorityGroup = GUI:CreateSettingsGroup(self.child, 280)
        rolePriorityGroup:AddWidget(GUI:CreateHeader(self.child, "Role Priority"), 40)
        rolePriorityGroup:AddWidget(GUI:CreateLabel(self.child, "Drag to reorder. Top = first.", 250), 25)
        
        roleOrderWidget = GUI:CreateRoleOrderList(self.child, db, "sortRoleOrder", function()
            TriggerSortForCurrentMode()
        end, "sortSeparateMeleeRanged")
        rolePriorityGroup:AddWidget(roleOrderWidget, 135)
        rolePriorityGroup.hideOn = HideSortOptions
        Add(rolePriorityGroup, nil, 2)
        
        -- ===== CLASS PRIORITY GROUP (Column 2) =====
        local classPriorityGroup = GUI:CreateSettingsGroup(self.child, 280)
        classPriorityGroup:AddWidget(GUI:CreateHeader(self.child, "Class Priority"), 40)
        classPriorityGroup:AddWidget(GUI:CreateLabel(self.child, "Drag to reorder. Top = first.", 250), 25)
        
        local classOrderWidget = GUI:CreateClassOrderList(self.child, db, "sortClassOrder", function()
            TriggerSortForCurrentMode()
        end)
        classPriorityGroup:AddWidget(classOrderWidget, 320)
        classPriorityGroup.hideOn = function(d) return not d.sortEnabled or not d.sortByClass end
        Add(classPriorityGroup, nil, 2)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "general_frame", label = "Frame"},
            {pageId = "general_labels", label = "Group Labels"},
        }), 30, "both")
    end)
    
    -- General > Integrations
    local pageIntegrations = CreateSubTab("general", "general_integrations", "Integrations")
    BuildPage(pageIntegrations, function(self, db, Add, AddSpace, AddSyncPoint)
        -- ===== COLOR PICKER GROUP (Column 1) =====
        local colorPickerGroup = GUI:CreateSettingsGroup(self.child, 280)
        colorPickerGroup:AddWidget(GUI:CreateHeader(self.child, "Color Picker"), 40)
        
        colorPickerGroup:AddWidget(GUI:CreateCheckbox(self.child, "Use DF Color Picker", db, "colorPickerOverride", function()
            if db.colorPickerOverride or db.colorPickerGlobalOverride then
                local success = GUI:InstallColorPickerHook()
                if success then print("|cff00ff00DandersFrames:|r Color picker override enabled")
                elseif GUI:IsColorPickerHookInstalled() then print("|cff00ff00DandersFrames:|r Color picker override already active") end
            else
                GUI:UninstallColorPickerHook()
                print("|cffff9900DandersFrames:|r Color picker override disabled")
            end
        end), 30)
        colorPickerGroup:AddWidget(GUI:CreateLabel(self.child, "Replace Blizzard's color picker with the DandersFrames color picker for this addon.", 250), 40)
        
        colorPickerGroup:AddWidget(GUI:CreateCheckbox(self.child, "Use DF Color Picker for All Addons", db, "colorPickerGlobalOverride", function()
            if db.colorPickerOverride or db.colorPickerGlobalOverride then
                local success = GUI:InstallColorPickerHook()
                if success then print("|cff00ff00DandersFrames:|r Custom color picker enabled for all addons")
                elseif GUI:IsColorPickerHookInstalled() then print("|cff00ff00DandersFrames:|r Color picker hook already active") end
            else
                GUI:UninstallColorPickerHook()
                print("|cffff9900DandersFrames:|r Color picker hook disabled")
            end
        end), 30)
        colorPickerGroup:AddWidget(GUI:CreateLabel(self.child, "Show the DF color picker when any addon opens a color picker.", 250), 30)
        
        Add(colorPickerGroup, nil, 1)
        
        -- ===== MASQUE GROUP (Column 2) =====
        local masqueGroup = GUI:CreateSettingsGroup(self.child, 280)
        masqueGroup:AddWidget(GUI:CreateHeader(self.child, "Masque Integration"), 40)
        
        if DF.Masque then
            masqueGroup:AddWidget(GUI:CreateCheckbox(self.child, "Let Masque Control Aura Borders", db, "masqueBorderControl", function()
                if DF.ApplyLayout then DF:ApplyLayout() end
                if DF.UpdateAllFrames then DF:UpdateAllFrames() end
                print("|cff00ff00DandersFrames:|r Masque border control " .. (db.masqueBorderControl and "enabled" or "disabled") .. ". A /reload may be needed.")
            end), 30)
            masqueGroup:AddWidget(GUI:CreateLabel(self.child, "When enabled, Masque skins aura icons and borders. DF border settings will be disabled.", 250), 45)
        else
            masqueGroup:AddWidget(GUI:CreateLabel(self.child, "Masque addon is not installed.\n\nMasque allows you to skin buff/debuff icons with custom textures. Install Masque from CurseForge to enable.", 250), 75)
        end
        
        Add(masqueGroup, nil, 2)
        
        -- ===== CLICK-THROUGH GROUP (Column 1) =====
        local clickThroughGroup = GUI:CreateSettingsGroup(self.child, 280)
        clickThroughGroup:AddWidget(GUI:CreateHeader(self.child, "Click-Through Icons"), 40)
        clickThroughGroup:AddWidget(GUI:CreateLabel(self.child, "Make icons click-through for external click-casting addons. Not needed for DF built-in click-casting.", 250), 45)
        
        local buffDisableMouse = clickThroughGroup:AddWidget(GUI:CreateCheckbox(self.child, "Buff Icons Click-Through", db, "buffDisableMouse", function()
            if DF.UpdateAuraClickThrough then DF:UpdateAuraClickThrough() end
        end), 30)
        buffDisableMouse.disableOn = function(d) return not d.showBuffs end
        
        local debuffDisableMouse = clickThroughGroup:AddWidget(GUI:CreateCheckbox(self.child, "Debuff Icons Click-Through", db, "debuffDisableMouse", function()
            if DF.UpdateAuraClickThrough then DF:UpdateAuraClickThrough() end
        end), 30)
        debuffDisableMouse.disableOn = function(d) return not d.showDebuffs end
        
        local defensiveDisableMouse = clickThroughGroup:AddWidget(GUI:CreateCheckbox(self.child, "Defensive Icon Click-Through", db, "defensiveIconDisableMouse", function()
            if DF.UpdateAuraClickThrough then DF:UpdateAuraClickThrough() end
        end), 30)
        defensiveDisableMouse.disableOn = function(d) return not d.defensiveIconEnabled end
        
        local tsDisableMouse = clickThroughGroup:AddWidget(GUI:CreateCheckbox(self.child, "Targeted Spell Click-Through", db, "targetedSpellDisableMouse", function()
            if DF.UpdateAuraClickThrough then DF:UpdateAuraClickThrough() end
        end), 30)
        tsDisableMouse.disableOn = function(d) return not d.targetedSpellEnabled end
        
        clickThroughGroup:AddWidget(GUI:CreateLabel(self.child, "⚠ Note: Click-through icons will not show tooltips.", 250), 25)
        
        Add(clickThroughGroup, nil, 1)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = "Buffs"},
            {pageId = "auras_debuffs", label = "Debuffs"},
            {pageId = "auras_defensiveicon", label = "Defensive Icon"},
            {pageId = "indicators_targetedspells", label = "Targeted Spells"},
        }), 30, "both")
    end)
    
    -- Display > Class Colors
    local pageClassColors = CreateSubTab("display", "display_classcolors", "Class Colors")
    BuildPage(pageClassColors, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Class colors are shared across party/raid, stored at profile level
        local classColorsDB = DF.db.classColors
        if not classColorsDB then
            DF.db.classColors = {}
            classColorsDB = DF.db.classColors
        end
        
        -- Ordered list of all classes with display names
        local CLASS_LIST = {
            { token = "WARRIOR",      name = "Warrior" },
            { token = "PALADIN",      name = "Paladin" },
            { token = "HUNTER",       name = "Hunter" },
            { token = "ROGUE",        name = "Rogue" },
            { token = "PRIEST",       name = "Priest" },
            { token = "DEATHKNIGHT",  name = "Death Knight" },
            { token = "SHAMAN",       name = "Shaman" },
            { token = "MAGE",         name = "Mage" },
            { token = "WARLOCK",      name = "Warlock" },
            { token = "MONK",         name = "Monk" },
            { token = "DRUID",        name = "Druid" },
            { token = "DEMONHUNTER",  name = "Demon Hunter" },
            { token = "EVOKER",       name = "Evoker" },
        }
        
        -- ===== Column 1 =====
        local col1 = GUI:CreateSettingsGroup(self.child, 280)
        col1:AddWidget(GUI:CreateHeader(self.child, "Class Colors"), 40)
        col1:AddWidget(GUI:CreateLabel(self.child, "Customize class colors used throughout DandersFrames. Changes apply to health bars, name text, borders, and all other class-colored elements.", 260), 50)
        
        -- Reset All button
        local resetAllBtn = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        resetAllBtn:SetSize(260, 24)
        resetAllBtn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        resetAllBtn:SetBackdropColor(0.15, 0.15, 0.15, 1)
        resetAllBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        local resetAllText = resetAllBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        resetAllText:SetPoint("CENTER")
        resetAllText:SetText("Reset All to Default")
        resetAllBtn:SetScript("OnClick", function()
            -- Reset all to Blizzard defaults
            for _, info in ipairs(CLASS_LIST) do
                local default = RAID_CLASS_COLORS[info.token]
                if default then
                    classColorsDB[info.token] = { r = default.r, g = default.g, b = default.b, a = 1 }
                end
            end
            DF:RefreshAllVisibleFrames()
            -- Refresh the options page to update swatches
            if pageClassColors and pageClassColors.Refresh then
                pageClassColors:Refresh()
            end
        end)
        resetAllBtn:SetScript("OnEnter", function(s) s:SetBackdropColor(0.25, 0.25, 0.25, 1) end)
        resetAllBtn:SetScript("OnLeave", function(s) s:SetBackdropColor(0.15, 0.15, 0.15, 1) end)
        col1:AddWidget(resetAllBtn, 30)
        
        -- First half of classes in column 1
        for i = 1, 7 do
            local info = CLASS_LIST[i]
            local token = info.token
            -- Initialize from Blizzard defaults if not customized
            if not classColorsDB[token] then
                local default = RAID_CLASS_COLORS[token]
                if default then
                    classColorsDB[token] = { r = default.r, g = default.g, b = default.b, a = 1 }
                end
            end
            col1:AddWidget(GUI:CreateColorPicker(self.child, info.name, classColorsDB, token, false, function()
                DF:RefreshAllVisibleFrames()
            end, function()
                DF:RefreshAllVisibleFrames()
            end, true), 30)
        end
        
        Add(col1, nil, 1)
        
        -- ===== Column 2 =====
        local col2 = GUI:CreateSettingsGroup(self.child, 280)
        col2:AddWidget(GUI:CreateHeader(self.child, " "), 40)
        col2:AddWidget(GUI:CreateLabel(self.child, "Click a color swatch to open the color picker. These settings are shared across party and raid frames.", 260), 50)
        
        -- Spacer to match Reset button height in column 1
        local spacer = CreateFrame("Frame", nil, self.child)
        spacer:SetSize(260, 24)
        col2:AddWidget(spacer, 30)
        
        -- Second half of classes in column 2
        for i = 8, #CLASS_LIST do
            local info = CLASS_LIST[i]
            local token = info.token
            if not classColorsDB[token] then
                local default = RAID_CLASS_COLORS[token]
                if default then
                    classColorsDB[token] = { r = default.r, g = default.g, b = default.b, a = 1 }
                end
            end
            col2:AddWidget(GUI:CreateColorPicker(self.child, info.name, classColorsDB, token, false, function()
                DF:RefreshAllVisibleFrames()
            end, function()
                DF:RefreshAllVisibleFrames()
            end, true), 30)
        end
        
        Add(col2, nil, 2)
    end)
    
    -- ========================================
    -- CATEGORY: Bars
    -- ========================================
    CreateCategory("bars", "Bars")
    
    -- Bars > Health Bar
    local pageHealthBar = CreateSubTab("bars", "bars_health", "Health Bar")
    BuildPage(pageHealthBar, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"health", "classColor", "smoothBars"}, "Health Bar"), 25, 2)
        
        -- ===== COLOR GROUP (Column 1) =====
        local colorGroup = GUI:CreateSettingsGroup(self.child, 280)
        colorGroup:AddWidget(GUI:CreateHeader(self.child, "Health Bar Color"), 40)
        
        local colorModes = { CLASS = "Class Color", CUSTOM = "Custom Color", PERCENT = "Health Gradient" }
        colorGroup:AddWidget(GUI:CreateDropdown(self.child, "Color Mode", colorModes, db, "healthColorMode", function()
            self:RefreshStates()
            DF:UpdateColorCurve()
            -- Refresh health colors on all frames (same as alpha slider)
            DF:RefreshAllVisibleFrames()
        end), 55)
        
        local classAlpha = colorGroup:AddWidget(GUI:CreateSlider(self.child, "Health Bar Alpha", 0, 1, 0.05, db, "classColorAlpha", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        classAlpha.hideOn = function(d) return d.healthColorMode ~= "CLASS" and d.healthColorMode ~= "PERCENT" end
        
        local customColor = colorGroup:AddWidget(GUI:CreateColorPicker(self.child, "Custom Health Color", db, "healthColor", true, nil, function() DF:LightweightUpdateHealthColor() end, true), 35)
        customColor.hideOn = function(d) return d.healthColorMode ~= "CUSTOM" end
        
        Add(colorGroup, nil, 1)
        
        -- ===== TEXTURE GROUP (Column 2) =====
        local textureGroup = GUI:CreateSettingsGroup(self.child, 280)
        textureGroup:AddWidget(GUI:CreateHeader(self.child, "Health Bar Texture"), 40)
        textureGroup:AddWidget(GUI:CreateTextureDropdown(self.child, "Texture", db, "healthTexture"), 55)
        
        local orientOptions = {
            HORIZONTAL = "Left to Right", HORIZONTAL_INV = "Right to Left",
            VERTICAL = "Bottom to Top", VERTICAL_INV = "Top to Bottom",
        }
        textureGroup:AddWidget(GUI:CreateDropdown(self.child, "Fill Direction", orientOptions, db, "healthOrientation", function() DF:UpdateAllFrames() end), 55)
        textureGroup:AddWidget(GUI:CreateCheckbox(self.child, "Smooth Bar Animation", db, "smoothBars", function() DF:UpdateAllFrames() end), 30)
        
        Add(textureGroup, nil, 2)
        
        -- ===== GRADIENT PREVIEW (full width, conditional) =====
        local gradHeader = Add(GUI:CreateHeader(self.child, "Gradient Colors"), 40, "both")
        gradHeader.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        
        local gradBar = Add(GUI:CreateGradientBar(self.child, 550, 24, db), 35, "both")
        gradBar.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        
        -- ===== HIGH HEALTH GROUP (Column 1, conditional) =====
        local highGroup = GUI:CreateSettingsGroup(self.child, 280)
        highGroup:AddWidget(GUI:CreateHeader(self.child, "High Health (100%)"), 40)
        highGroup:AddWidget(GUI:CreateColorPicker(self.child, "Color", db, "healthColorHigh", false, function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 35)
        highGroup:AddWidget(GUI:CreateCheckbox(self.child, "Use Class Color", db, "healthColorHighUseClass", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end), 30)
        highGroup:AddWidget(GUI:CreateSlider(self.child, "Weight", 1, 5, 1, db, "healthColorHighWeight", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 55)
        highGroup.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        Add(highGroup, nil, 1)
        
        -- ===== MEDIUM HEALTH GROUP (Column 2, conditional) =====
        local medGroup = GUI:CreateSettingsGroup(self.child, 280)
        medGroup:AddWidget(GUI:CreateHeader(self.child, "Medium Health (50%)"), 40)
        medGroup:AddWidget(GUI:CreateColorPicker(self.child, "Color", db, "healthColorMedium", false, function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 35)
        medGroup:AddWidget(GUI:CreateCheckbox(self.child, "Use Class Color", db, "healthColorMediumUseClass", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end), 30)
        medGroup:AddWidget(GUI:CreateSlider(self.child, "Weight", 1, 5, 1, db, "healthColorMediumWeight", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 55)
        medGroup.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        Add(medGroup, nil, 2)
        
        -- ===== LOW HEALTH GROUP (Column 1, conditional) =====
        local lowGroup = GUI:CreateSettingsGroup(self.child, 280)
        lowGroup:AddWidget(GUI:CreateHeader(self.child, "Low Health (0%)"), 40)
        lowGroup:AddWidget(GUI:CreateColorPicker(self.child, "Color", db, "healthColorLow", false, function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 35)
        lowGroup:AddWidget(GUI:CreateCheckbox(self.child, "Use Class Color", db, "healthColorLowUseClass", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end), 30)
        lowGroup:AddWidget(GUI:CreateSlider(self.child, "Weight", 1, 5, 1, db, "healthColorLowWeight", function() if gradBar.UpdatePreview then gradBar.UpdatePreview() end DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() end, function() DF:UpdateColorCurve() DF:RefreshAllVisibleFrames() if gradBar.UpdatePreview then gradBar.UpdatePreview() end end, true), 55)
        lowGroup.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        Add(lowGroup, nil, 1)
        
        -- ===== BACKGROUND GROUP (Column 1) =====
        local bgGroup = GUI:CreateSettingsGroup(self.child, 280)
        bgGroup:AddWidget(GUI:CreateHeader(self.child, "Background"), 40)
        
        local bgModes = { CUSTOM = "Custom Color", CLASS = "Class Color" }
        bgGroup:AddWidget(GUI:CreateDropdown(self.child, "Background Mode", bgModes, db, "backgroundColorMode", function()
            self:RefreshStates()
            DF:LightweightUpdateBackgroundColor()
        end), 55)
        
        local bgTextureOptions = DF:GetTextureList(true)
        bgGroup:AddWidget(GUI:CreateTextureDropdown(self.child, "Background Texture", db, "backgroundTexture", function()
            DF:LightweightUpdateBackgroundColor()
        end, bgTextureOptions), 55)
        
        local bgColor = bgGroup:AddWidget(GUI:CreateColorPicker(self.child, "Background Color", db, "backgroundColor", true, nil, function() DF:LightweightUpdateBackgroundColor() end, true), 35)
        bgColor.hideOn = function(d) return d.backgroundColorMode ~= "CUSTOM" end
        
        local bgClassAlpha = bgGroup:AddWidget(GUI:CreateSlider(self.child, "Background Alpha", 0, 1, 0.05, db, "backgroundClassAlpha", nil, function() DF:LightweightUpdateBackgroundColor() end, true), 55)
        bgClassAlpha.hideOn = function(d) return d.backgroundColorMode ~= "CLASS" end
        
        Add(bgGroup, nil, 1)
        
        -- ===== MISSING HEALTH GROUP (Column 2) =====
        local missingGroup = GUI:CreateSettingsGroup(self.child, 280)
        missingGroup:AddWidget(GUI:CreateHeader(self.child, "Missing Health"), 40)
        
        local bgFillModes = { BACKGROUND = "Background Only", MISSING_HEALTH = "Missing Health Only", BOTH = "Both" }
        local bgFillMode = missingGroup:AddWidget(GUI:CreateDropdown(self.child, "Background Fill", bgFillModes, db, "backgroundMode", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 55)
        bgFillMode.tooltip = "Background Only: Normal solid background\nMissing Health Only: Shows colored bar where health is missing\nBoth: Shows both"
        
        local missingHealthTextureOptions = DF:GetTextureList(false)
        local missingHealthTexture = missingGroup:AddWidget(GUI:CreateTextureDropdown(self.child, "Missing Health Texture", db, "missingHealthTexture", function()
            DF:UpdateAllFrames()
        end, missingHealthTextureOptions), 55)
        missingHealthTexture.hideOn = function(d) return d.backgroundMode == "BACKGROUND" end
        
        local missingHealthColorModes = { CUSTOM = "Custom Color", CLASS = "Class Color" }
        local missingHealthColorMode = missingGroup:AddWidget(GUI:CreateDropdown(self.child, "Color Mode", missingHealthColorModes, db, "missingHealthColorMode", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 55)
        missingHealthColorMode.hideOn = function(d) return d.backgroundMode == "BACKGROUND" end
        
        local missingHealthColor = missingGroup:AddWidget(GUI:CreateColorPicker(self.child, "Missing Health Color", db, "missingHealthColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
        missingHealthColor.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "CUSTOM" end
        
        local missingHealthClassAlpha = missingGroup:AddWidget(GUI:CreateSlider(self.child, "Class Color Alpha", 0, 1, 0.05, db, "missingHealthClassAlpha", nil, function() DF:UpdateAllFrames() end, true), 55)
        missingHealthClassAlpha.hideOn = function(d) return d.backgroundMode == "BACKGROUND" or d.missingHealthColorMode ~= "CLASS" end
        
        Add(missingGroup, nil, 2)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "general_frame", label = "Frame"},
            {pageId = "text_health", label = "Health Text"},
            {pageId = "bars_absorbs", label = "Absorbs"},
        }), 30, "both")
    end)
    
    -- Bars > Resource Bar
    local pageResource = CreateSubTab("bars", "bars_resource", "Resource Bar")
    BuildPage(pageResource, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"resourceBar"}, "Resource Bar"), 25, 2)
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Resource Bar Settings"), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Resource Bar", db, "resourceBarEnabled", function() 
            DF:UpdateAllPowerEventRegistration()
            DF:UpdateAllFrames() 
        end), 30)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Healer Only", db, "resourceBarHealerOnly", function() DF:UpdateAllFrames() end), 30)
        local showInSolo = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show in Solo Mode", db, "resourceBarShowInSoloMode", function() DF:UpdateAllFrames() end), 30)
        showInSolo.disableOn = function(d) return not d.resourceBarHealerOnly end
        showInSolo.hideOn = function() return GUI.SelectedMode == "raid" end
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Smooth Bar Animation", db, "resourceBarSmooth", function() DF:UpdateAllFrames() end), 30)
        Add(settingsGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
        
        local anchorOptions = {
            TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right", CENTER = "Center",
            TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
        }
        positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor Point", anchorOptions, db, "resourceBarAnchor", function() DF:UpdateAllFrames() end), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "resourceBarX", nil, function() DF:LightweightUpdatePowerBarPosition() end, true), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "resourceBarY", nil, function() DF:LightweightUpdatePowerBarPosition() end, true), 55)
        Add(positionGroup, nil, 2)
        
        -- ===== ORIENTATION GROUP (Column 1) =====
        local orientGroup = GUI:CreateSettingsGroup(self.child, 280)
        orientGroup:AddWidget(GUI:CreateHeader(self.child, "Orientation"), 40)
        local orientOptions = { HORIZONTAL = "Horizontal", VERTICAL = "Vertical" }
        orientGroup:AddWidget(GUI:CreateDropdown(self.child, "Orientation", orientOptions, db, "resourceBarOrientation", function() DF:UpdateAllFrames() end), 55)
        orientGroup:AddWidget(GUI:CreateCheckbox(self.child, "Reverse Fill Direction", db, "resourceBarReverseFill", function() DF:UpdateAllFrames() end), 30)
        Add(orientGroup, nil, 1)
        
        -- ===== BACKGROUND GROUP (Column 2) =====
        local bgGroup = GUI:CreateSettingsGroup(self.child, 280)
        bgGroup:AddWidget(GUI:CreateHeader(self.child, "Background"), 40)
        bgGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Background", db, "resourceBarBackgroundEnabled", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)
        local bgColor = bgGroup:AddWidget(GUI:CreateColorPicker(self.child, "Background Color", db, "resourceBarBackgroundColor", true, nil, function() DF:LightweightUpdateResourceBarBackgroundColor() end, true), 35)
        bgColor.disableOn = function(d) return not d.resourceBarBackgroundEnabled end
        Add(bgGroup, nil, 2)
        
        -- ===== BORDER GROUP (Column 1) =====
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, "Border"), 40)
        borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Border", db, "resourceBarBorderEnabled", function()
            self:RefreshStates()
            DF:LightweightUpdateResourceBarBorder()
        end), 30)
        local borderColor = borderGroup:AddWidget(GUI:CreateColorPicker(self.child, "Border Color", db, "resourceBarBorderColor", true, nil, function() DF:LightweightUpdateResourceBarBorderColor() end, true), 35)
        borderColor.disableOn = function(d) return not d.resourceBarBorderEnabled end
        Add(borderGroup, nil, 1)
        
        -- ===== FRAME LEVEL GROUP (Column 2) =====
        local frameLevelGroup = GUI:CreateSettingsGroup(self.child, 280)
        frameLevelGroup:AddWidget(GUI:CreateHeader(self.child, "Frame Level"), 40)
        frameLevelGroup:AddWidget(GUI:CreateSlider(self.child, "Frame Level Offset", 0, 20, 1, db, "resourceBarFrameLevel", nil, function() DF:LightweightUpdateResourceBarFrameLevel() end, true), 55)
        frameLevelGroup:AddWidget(GUI:CreateLabel(self.child, "Higher values render the bar above other elements. Frame border is at level 10.", 250), 50)
        Add(frameLevelGroup, nil, 2)
        
        -- ===== SIZE GROUP (Column 1) =====
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, "Size"), 40)
        sizeGroup:AddWidget(GUI:CreateCheckbox(self.child, "Match Health Bar Width/Height", db, "resourceBarMatchWidth", function() DF:UpdateAllFrames() end), 30)
        local widthSlider = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Width / Length", 10, 200, 1, db, "resourceBarWidth", nil, function() DF:LightweightUpdatePowerBarSize() end, true), 55)
        widthSlider.disableOn = function(d) return d.resourceBarMatchWidth end
        sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Height / Thickness", 1, 20, 1, db, "resourceBarHeight", nil, function() DF:LightweightUpdatePowerBarSize() end, true), 55)
        Add(sizeGroup, nil, 1)
        
        -- ===== RESOURCE COLORS GROUP (Column 2) =====
        local colorGroup = GUI:CreateSettingsGroup(self.child, 280)
        colorGroup:AddWidget(GUI:CreateHeader(self.child, "Resource Colors"), 40)
        colorGroup:AddWidget(GUI:CreateLabel(self.child, "Customize resource bar colors per power type. Shared across party and raid frames.", 260), 40)
        
        local powerColorsDB = DF.db.powerColors
        if not powerColorsDB then
            DF.db.powerColors = {}
            powerColorsDB = DF.db.powerColors
        end
        
        local POWER_LIST = {
            { token = "MANA",         name = "Mana" },
            { token = "RAGE",         name = "Rage" },
            { token = "FOCUS",        name = "Focus" },
            { token = "ENERGY",       name = "Energy" },
            { token = "RUNIC_POWER",  name = "Runic Power" },
            { token = "INSANITY",     name = "Insanity" },
            { token = "FURY",         name = "Fury" },
            { token = "LUNAR_POWER",  name = "Lunar Power" },
        }
        
        for _, info in ipairs(POWER_LIST) do
            local token = info.token
            if not powerColorsDB[token] then
                local default = PowerBarColor[token]
                if default then
                    powerColorsDB[token] = { r = default.r, g = default.g, b = default.b, a = 1 }
                end
            end
            colorGroup:AddWidget(GUI:CreateColorPicker(self.child, info.name, powerColorsDB, token, false, function()
                DF:RefreshAllVisibleFrames()
            end, function()
                DF:RefreshAllVisibleFrames()
            end, true), 30)
        end
        
        -- Reset button
        local resetPowerBtn = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        resetPowerBtn:SetSize(260, 24)
        resetPowerBtn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        resetPowerBtn:SetBackdropColor(0.15, 0.15, 0.15, 1)
        resetPowerBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        local resetPowerText = resetPowerBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        resetPowerText:SetPoint("CENTER")
        resetPowerText:SetText("Reset All to Default")
        resetPowerBtn:SetScript("OnClick", function()
            for _, info in ipairs(POWER_LIST) do
                local default = PowerBarColor[info.token]
                if default then
                    powerColorsDB[info.token] = { r = default.r, g = default.g, b = default.b, a = 1 }
                end
            end
            DF:RefreshAllVisibleFrames()
            if pageResource and pageResource.Refresh then
                pageResource:Refresh()
            end
        end)
        resetPowerBtn:SetScript("OnEnter", function(s) s:SetBackdropColor(0.25, 0.25, 0.25, 1) end)
        resetPowerBtn:SetScript("OnLeave", function(s) s:SetBackdropColor(0.15, 0.15, 0.15, 1) end)
        colorGroup:AddWidget(resetPowerBtn, 30)
        
        Add(colorGroup, nil, 2)
    end)
    
    -- Bars > Absorbs (combined Absorb Shield + Heal Absorb with collapsible sections)
    local pageAbsorb = CreateSubTab("bars", "bars_absorb", "Absorbs")
    BuildPage(pageAbsorb, function(self, db, Add, AddSpace)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"absorbBar", "healAbsorb"}, "Absorbs"), 25, 2)
        
        local currentSection = nil
        
        -- Helper to add widgets to current section
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then
                currentSection:RegisterChild(widget)
            end
            return widget
        end
        
        -- ===== ABSORB SHIELD SECTION =====
        local absorbSection = Add(GUI:CreateCollapsibleSection(self.child, "Absorb Shield", true), 36, "both")
        currentSection = absorbSection
        
        local modeOptions = {
            OVERLAY = "Overlay (on health bar)",
            ATTACHED = "Attached to Health",
            ATTACHED_OVERFLOW = "Attached + Overflow",
            FLOATING = "Floating Bar",
        }
        AddToSection(GUI:CreateDropdown(self.child, "Display Mode", modeOptions, db, "absorbBarMode", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 55, 1)
        
        local textureOptions = DF:GetTextureList()
        -- Add stripe textures if not already present
        local stripeTextures = {
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft"] = "DF Stripes Soft",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft_Wide"] = "DF Stripes Soft Wide",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes"] = "DF Stripes",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Sparse"] = "DF Stripes Sparse",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Medium"] = "DF Stripes Medium",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Dense"] = "DF Stripes Dense",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Very_Dense"] = "DF Stripes Very Dense",
        }
        for path, name in pairs(stripeTextures) do
            if not textureOptions[path] then
                textureOptions[path] = name
            end
        end
        AddToSection(GUI:CreateTextureDropdown(self.child, "Texture", db, "absorbBarTexture", function() DF:UpdateAllFrames() end, textureOptions), 55, 1)
        
        AddToSection(GUI:CreateColorPicker(self.child, "Bar Color", db, "absorbBarColor", true, nil, function() DF:LightweightUpdateAbsorbBarColor() end, true), 35, 1)
        
        local blendOptions = { BLEND = "Normal (BLEND)", ADD = "Additive (ADD)" }
        AddToSection(GUI:CreateDropdown(self.child, "Blend Mode", blendOptions, db, "absorbBarBlendMode", function() DF:UpdateAllFrames() end), 55, 1)
        
        local overlayRev = AddToSection(GUI:CreateCheckbox(self.child, "Reverse Overlay Fill", db, "absorbBarOverlayReverse", function() DF:UpdateAllFrames() end), 25, 1)
        overlayRev.hideOn = function(d) return d.absorbBarMode ~= "OVERLAY" and d.absorbBarMode ~= "ATTACHED_OVERFLOW" end
        
        local absorbClampOptions = {
            [0] = "None (no clamping)",
            [1] = "Missing Health",
            [2] = "Max Health",
        }
        local absorbClampDropdown = AddToSection(GUI:CreateDropdown(self.child, "Clamp Mode", absorbClampOptions, db, "absorbBarAttachedClampMode", function() DF:UpdateAllFrames() end), 55, 1)
        absorbClampDropdown.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" and d.absorbBarMode ~= "ATTACHED_OVERFLOW" end
        
        local absorbShowOvershield = AddToSection(GUI:CreateCheckbox(self.child, "Show Overshield Glow", db, "absorbBarShowOvershield", function() DF:UpdateAllFrames() end), 25, 1)
        absorbShowOvershield.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" end
        absorbShowOvershield.tooltip = "Shows a glow at max health when absorb exceeds the clamp limit."
        
        local absorbOvershieldStyleOptions = {
            SPARK = "Spark",
            LINE = "Line",
            GRADIENT = "Gradient",
            GLOW = "Glow",
        }
        local absorbOvershieldStyle = AddToSection(GUI:CreateDropdown(self.child, "Glow Style", absorbOvershieldStyleOptions, db, "absorbBarOvershieldStyle", function() DF:UpdateAllFrames() end), 55, 1)
        absorbOvershieldStyle.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" or not d.absorbBarShowOvershield end
        
        local absorbOvershieldColor = AddToSection(GUI:CreateColorPicker(self.child, "Glow Color", db, "absorbBarOvershieldColor", false, nil, function() DF:UpdateAllFrames() end), 35, 1)
        absorbOvershieldColor.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" or not d.absorbBarShowOvershield end
        
        local absorbOvershieldAlpha = AddToSection(GUI:CreateSlider(self.child, "Glow Alpha", 0.1, 1, 0.05, db, "absorbBarOvershieldAlpha", nil, function() DF:UpdateAllFrames() end, true), 55, 1)
        absorbOvershieldAlpha.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" or not d.absorbBarShowOvershield end
        
        local absorbOvershieldReverse = AddToSection(GUI:CreateCheckbox(self.child, "Reverse Position", db, "absorbBarOvershieldReverse", function() DF:UpdateAllFrames() end), 25, 1)
        absorbOvershieldReverse.hideOn = function(d) return d.absorbBarMode ~= "ATTACHED" or not d.absorbBarShowOvershield end
        absorbOvershieldReverse.tooltip = "Moves the glow to the opposite side (no HP side instead of max HP side)."
        
        -- Floating mode settings (column 2)
        local floatingHeader = AddToSection(GUI:CreateHeader(self.child, "Floating Bar Position"), 45, 2)
        floatingHeader.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local orientOptions = { HORIZONTAL = "Horizontal", VERTICAL = "Vertical" }
        local orientDropdown = AddToSection(GUI:CreateDropdown(self.child, "Orientation", orientOptions, db, "absorbBarOrientation", function() DF:UpdateAllFrames() end), 55, 1)
        orientDropdown.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local revFill = AddToSection(GUI:CreateCheckbox(self.child, "Reverse Fill", db, "absorbBarReverse", function() DF:UpdateAllFrames() end), 25, 2)
        revFill.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local widthSlider = AddToSection(GUI:CreateSlider(self.child, "Width", 10, 200, 1, db, "absorbBarWidth", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
        widthSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local heightSlider = AddToSection(GUI:CreateSlider(self.child, "Height", 1, 30, 1, db, "absorbBarHeight", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
        heightSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local anchorOptions = {
            TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right", CENTER = "Center",
            TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
        }
        local anchorDropdown = AddToSection(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "absorbBarAnchor", function() DF:UpdateAllFrames() end), 55, 1)
        anchorDropdown.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local xSlider = AddToSection(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "absorbBarX", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
        xSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local ySlider = AddToSection(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "absorbBarY", nil, function() DF:LightweightUpdateAbsorbBar() end, true), 55, 1)
        ySlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local bgColorPicker = AddToSection(GUI:CreateColorPicker(self.child, "Background Color", db, "absorbBarBackgroundColor", true, nil, function() DF:LightweightUpdateAbsorbBarColor() end, true), 35, 2)
        bgColorPicker.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local strataOptions = {
            BACKGROUND = "Background",
            LOW = "Low",
            MEDIUM = "Medium",
            HIGH = "High",
            DIALOG = "Dialog",
        }
        local strataDropdown = AddToSection(GUI:CreateDropdown(self.child, "Frame Strata", strataOptions, db, "absorbBarStrata", function() DF:UpdateAllFrames() end), 55, 1)
        strataDropdown.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local levelSlider = AddToSection(GUI:CreateSlider(self.child, "Frame Level", 1, 100, 1, db, "absorbBarFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("absorb") end, true), 55, 1)
        levelSlider.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== HEAL ABSORB SECTION =====
        local healAbsorbSection = Add(GUI:CreateCollapsibleSection(self.child, "Heal Absorb", true), 36, "both")
        currentSection = healAbsorbSection
        
        AddToSection(GUI:CreateLabel(self.child, "Shows effects that reduce incoming healing (like Necrotic stacks).", 260), 25, 1)
        
        local healModeOptions = {
            OVERLAY = "Overlay (on health bar)",
            ATTACHED = "Attached to Health",
            FLOATING = "Floating Bar",
        }
        AddToSection(GUI:CreateDropdown(self.child, "Display Mode", healModeOptions, db, "healAbsorbBarMode", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 55, 1)
        
        local healTextureOptions = DF:GetTextureList()
        -- Add stripe textures if not already present
        local healStripeTextures = {
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft"] = "DF Stripes Soft",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft_Wide"] = "DF Stripes Soft Wide",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes"] = "DF Stripes",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Sparse"] = "DF Stripes Sparse",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Medium"] = "DF Stripes Medium",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Dense"] = "DF Stripes Dense",
            ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Very_Dense"] = "DF Stripes Very Dense",
        }
        for path, name in pairs(healStripeTextures) do
            if not healTextureOptions[path] then
                healTextureOptions[path] = name
            end
        end
        AddToSection(GUI:CreateTextureDropdown(self.child, "Texture", db, "healAbsorbBarTexture", function() DF:UpdateAllFrames() end, healTextureOptions), 55, 1)
        
        AddToSection(GUI:CreateColorPicker(self.child, "Bar Color", db, "healAbsorbBarColor", true, nil, function() DF:LightweightUpdateHealAbsorbBarColor() end, true), 35, 1)
        
        local healBlendOptions = { BLEND = "Normal (BLEND)", ADD = "Additive (ADD)" }
        AddToSection(GUI:CreateDropdown(self.child, "Blend Mode", healBlendOptions, db, "healAbsorbBarBlendMode", function() DF:UpdateAllFrames() end), 55, 1)
        
        local healOverlayRev = AddToSection(GUI:CreateCheckbox(self.child, "Reverse Overlay Fill", db, "healAbsorbBarOverlayReverse", function() DF:UpdateAllFrames() end), 25, 1)
        healOverlayRev.hideOn = function(d) return d.healAbsorbBarMode ~= "OVERLAY" end
        
        -- Heal Absorb Floating mode settings (column 2)
        local healFloatingHeader = AddToSection(GUI:CreateHeader(self.child, "Floating Bar Position"), 45, 2)
        healFloatingHeader.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healOrientDropdown = AddToSection(GUI:CreateDropdown(self.child, "Orientation", orientOptions, db, "healAbsorbBarOrientation", function() DF:UpdateAllFrames() end), 55, 1)
        healOrientDropdown.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healRevFill = AddToSection(GUI:CreateCheckbox(self.child, "Reverse Fill", db, "healAbsorbBarReverse", function() DF:UpdateAllFrames() end), 25, 2)
        healRevFill.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healWidthSlider = AddToSection(GUI:CreateSlider(self.child, "Width", 10, 200, 1, db, "healAbsorbBarWidth", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
        healWidthSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healHeightSlider = AddToSection(GUI:CreateSlider(self.child, "Height", 1, 30, 1, db, "healAbsorbBarHeight", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
        healHeightSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healAnchorDropdown = AddToSection(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "healAbsorbBarAnchor", function() DF:UpdateAllFrames() end), 55, 1)
        healAnchorDropdown.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healXSlider = AddToSection(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "healAbsorbBarX", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
        healXSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healYSlider = AddToSection(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "healAbsorbBarY", nil, function() DF:LightweightUpdateHealAbsorbBar() end, true), 55, 1)
        healYSlider.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healBgColorPicker = AddToSection(GUI:CreateColorPicker(self.child, "Background Color", db, "healAbsorbBarBackgroundColor", true, nil, function() DF:LightweightUpdateHealAbsorbBarColor() end, true), 35, 2)
        healBgColorPicker.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        currentSection = nil
    end)
    
    -- Bars > Heal Prediction
    local pageHealPrediction = CreateSubTab("bars", "bars_healpred", "Heal Prediction")
    BuildPage(pageHealPrediction, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"healPrediction"}, "Heal Prediction"), 25, 2)
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Heal Prediction"), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Heal Prediction", db, "healPredictionEnabled", function() 
            self:RefreshStates()
            DF:UpdateAllFrames() 
        end), 30)
        
        local modeOptions = { OVERLAY = "Attached to Health", FLOATING = "Floating Bar" }
        local modeDropdown = settingsGroup:AddWidget(GUI:CreateDropdown(self.child, "Display Mode", modeOptions, db, "healPredictionMode", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 55)
        modeDropdown.disableOn = function(d) return not d.healPredictionEnabled end
        
        local textureOptions = DF:GetTextureList()
        local texDropdown = settingsGroup:AddWidget(GUI:CreateTextureDropdown(self.child, "Texture", db, "healPredictionTexture", function() DF:UpdateAllFrames() end, textureOptions), 55)
        texDropdown.disableOn = function(d) return not d.healPredictionEnabled end
        
        local blendOptions = { BLEND = "Normal (BLEND)", ADD = "Additive (ADD)" }
        local blendDropdown = settingsGroup:AddWidget(GUI:CreateDropdown(self.child, "Blend Mode", blendOptions, db, "healPredictionBlendMode", function() DF:UpdateAllFrames() end), 55)
        blendDropdown.disableOn = function(d) return not d.healPredictionEnabled end
        
        Add(settingsGroup, nil, 1)
        
        -- ===== APPEARANCE GROUP (Column 2) =====
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, "Appearance"), 40)
        
        local overhealCheckbox = appearanceGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Overheal", db, "healPredictionShowOverheal", function() DF:UpdateAllFrames() end), 30)
        overhealCheckbox.disableOn = function(d) return not d.healPredictionEnabled end
        overhealCheckbox.tooltip = "When enabled, shows incoming heals even if they would overheal."
        
        local myColor = appearanceGroup:AddWidget(GUI:CreateColorPicker(self.child, "Heal Prediction Color", db, "healPredictionMyColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
        myColor.disableOn = function(d) return not d.healPredictionEnabled end
        
        Add(appearanceGroup, nil, 2)
        
        -- ===== FLOATING POSITION GROUP (Column 1, conditional) =====
        local floatingGroup = GUI:CreateSettingsGroup(self.child, 280)
        floatingGroup:AddWidget(GUI:CreateHeader(self.child, "Floating Bar Position"), 40)
        
        local orientOptions = { HORIZONTAL = "Horizontal", VERTICAL = "Vertical" }
        local orientDropdown = floatingGroup:AddWidget(GUI:CreateDropdown(self.child, "Orientation", orientOptions, db, "healPredictionOrientation", function() DF:UpdateAllFrames() end), 55)
        orientDropdown.disableOn = function(d) return not d.healPredictionEnabled end
        
        local revFill = floatingGroup:AddWidget(GUI:CreateCheckbox(self.child, "Reverse Fill", db, "healPredictionReverse", function() DF:UpdateAllFrames() end), 30)
        revFill.disableOn = function(d) return not d.healPredictionEnabled end
        
        local widthSlider = floatingGroup:AddWidget(GUI:CreateSlider(self.child, "Width", 10, 200, 1, db, "healPredictionWidth", nil, function() DF:UpdateAllFrames() end, true), 55)
        widthSlider.disableOn = function(d) return not d.healPredictionEnabled end
        
        local heightSlider = floatingGroup:AddWidget(GUI:CreateSlider(self.child, "Height", 1, 30, 1, db, "healPredictionHeight", nil, function() DF:UpdateAllFrames() end, true), 55)
        heightSlider.disableOn = function(d) return not d.healPredictionEnabled end
        
        floatingGroup.hideOn = function(d) return d.healPredictionMode ~= "FLOATING" end
        Add(floatingGroup, nil, 1)
        
        -- ===== FLOATING ANCHOR GROUP (Column 2, conditional) =====
        local anchorGroup = GUI:CreateSettingsGroup(self.child, 280)
        anchorGroup:AddWidget(GUI:CreateHeader(self.child, "Floating Bar Anchor"), 40)
        
        local anchorOptions = {
            CENTER = "Center", TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
            TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
        }
        local anchorDropdown = anchorGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "healPredictionAnchor", function() DF:UpdateAllFrames() end), 55)
        anchorDropdown.disableOn = function(d) return not d.healPredictionEnabled end
        
        local xSlider = anchorGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "healPredictionX", nil, function() DF:UpdateAllFrames() end, true), 55)
        xSlider.disableOn = function(d) return not d.healPredictionEnabled end
        
        local ySlider = anchorGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "healPredictionY", nil, function() DF:UpdateAllFrames() end, true), 55)
        ySlider.disableOn = function(d) return not d.healPredictionEnabled end
        
        local bgColorPicker = anchorGroup:AddWidget(GUI:CreateColorPicker(self.child, "Background Color", db, "healPredictionBackgroundColor", true, nil, function() DF:UpdateAllFrames() end, true), 35)
        bgColorPicker.disableOn = function(d) return not d.healPredictionEnabled end
        
        anchorGroup.hideOn = function(d) return d.healPredictionMode ~= "FLOATING" end
        Add(anchorGroup, nil, 2)
    end)
    
    -- ========================================
    -- CATEGORY: Text
    -- ========================================
    CreateCategory("text", "Text")
    
    -- Text > Health Text
    local pageHealthText = CreateSubTab("text", "text_health", "Health Text")
    BuildPage(pageHealthText, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"healthText", "healthFont"}, "Health Text"), 25, 2)
        
        -- ===== FORMAT GROUP (Column 1) =====
        local formatGroup = GUI:CreateSettingsGroup(self.child, 280)
        formatGroup:AddWidget(GUI:CreateHeader(self.child, "Health Text"), 40)
        
        local formatOptions = {
            PERCENT = "Percentage", CURRENT = "Current Health", CURRENTMAX = "Current / Max",
            DEFICIT = "Health Deficit", NONE = "Hidden",
            _order = {"PERCENT", "CURRENT", "CURRENTMAX", "DEFICIT", "NONE"},
        }
        formatGroup:AddWidget(GUI:CreateDropdown(self.child, "Health Format", formatOptions, db, "healthTextFormat", function() DF:RefreshAllVisibleFrames() end), 55)
        formatGroup:AddWidget(GUI:CreateCheckbox(self.child, "Abbreviate (K/M)", db, "healthTextAbbreviate", function() DF:RefreshAllVisibleFrames() end), 30)
        Add(formatGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
        
        local anchorOptions = {
            CENTER = "Center", TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
            TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
        }
        positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "healthTextAnchor", function() DF:UpdateAllFrames() end), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "healthTextX", nil, function() DF:LightweightUpdateTextPosition("health") end, true), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "healthTextY", nil, function() DF:LightweightUpdateTextPosition("health") end, true), 55)
        Add(positionGroup, nil, 2)
        
        -- ===== FONT GROUP (Column 1) =====
        local fontGroup = GUI:CreateSettingsGroup(self.child, 280)
        fontGroup:AddWidget(GUI:CreateHeader(self.child, "Font"), 40)
        fontGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "healthFont", function() DF:UpdateAllFrames() end), 55)
        fontGroup:AddWidget(GUI:CreateSlider(self.child, "Font Size", 6, 24, 1, db, "healthFontSize", nil, function() DF:LightweightUpdateFontSize("health") end, true), 55)
        
        local outlineOptions = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline", SHADOW = "Shadow" }
        fontGroup:AddWidget(GUI:CreateDropdown(self.child, "Outline", outlineOptions, db, "healthTextOutline", function() DF:LightweightUpdateFontSize("health") end), 55)
        fontGroup:AddWidget(GUI:CreateCheckbox(self.child, "Use Class Color", db, "healthTextUseClassColor", function()
            self:RefreshStates()
            DF:RefreshAllVisibleFrames()
        end), 30)
        local healthColor = fontGroup:AddWidget(GUI:CreateColorPicker(self.child, "Text Color", db, "healthTextColor", true, nil, function() DF:LightweightUpdateTextColor("health") end, true), 35)
        healthColor.disableOn = function(d) return d.healthTextUseClassColor end
        Add(fontGroup, nil, 1)
    end)
    
    -- Text > Status Text (Dead/Offline)
    local pageStatusText = CreateSubTab("text", "text_status", "Status Text")
    BuildPage(pageStatusText, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"statusText"}, "Status Text"), 25, 2)
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Status Text (Dead/Offline)"), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Status Text", db, "statusTextEnabled", function() 
            -- Force full refresh of all frames to update status text visibility
            if DF.testMode or DF.raidTestMode then
                -- In test mode, refresh test frames
                if DF.RefreshTestFrames then DF:RefreshTestFrames() end
                if DF.UpdateRaidTestFrames then DF:UpdateRaidTestFrames() end
            else
                -- Live mode - update live frames
                if DF.IterateAllFrames then
                    DF:IterateAllFrames(function(frame)
                        if frame and frame.unit and UnitExists(frame.unit) then
                            DF:UpdateUnitFrame(frame)
                        end
                    end)
                end
            end
        end), 30)
        Add(settingsGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
        
        local anchorOptions = {
            CENTER = "Center", TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
            TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
        }
        positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "statusTextAnchor", function() DF:UpdateAllFrames() end), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "statusTextX", nil, function() DF:LightweightUpdateTextPosition("status") end, true), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "statusTextY", nil, function() DF:LightweightUpdateTextPosition("status") end, true), 55)
        Add(positionGroup, nil, 2)
        
        -- ===== FONT GROUP (Column 1) =====
        local fontGroup = GUI:CreateSettingsGroup(self.child, 280)
        fontGroup:AddWidget(GUI:CreateHeader(self.child, "Font"), 40)
        fontGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "statusTextFont", function() DF:UpdateAllFrames() end), 55)
        fontGroup:AddWidget(GUI:CreateSlider(self.child, "Font Size", 6, 24, 1, db, "statusTextFontSize", nil, function() DF:LightweightUpdateFontSize("status") end, true), 55)
        
        local outlineOptions = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline", SHADOW = "Shadow" }
        fontGroup:AddWidget(GUI:CreateDropdown(self.child, "Outline", outlineOptions, db, "statusTextOutline", function() DF:LightweightUpdateFontSize("status") end), 55)
        fontGroup:AddWidget(GUI:CreateColorPicker(self.child, "Text Color", db, "statusTextColor", true, nil, function() DF:LightweightUpdateTextColor("status") end, true), 35)
        Add(fontGroup, nil, 1)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "display_fading", label = "Dead/Offline Fading"},
        }), 30, "both")
    end)
    
    -- Text > Name Text
    local pageNameText = CreateSubTab("text", "text_name", "Name Text")
    BuildPage(pageNameText, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"name"}, "Name Text"), 25, 2)
        
        -- ===== FONT GROUP (Column 1) =====
        local fontGroup = GUI:CreateSettingsGroup(self.child, 280)
        fontGroup:AddWidget(GUI:CreateHeader(self.child, "Name Text"), 40)
        fontGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "nameFont", nil), 55)
        fontGroup:AddWidget(GUI:CreateSlider(self.child, "Font Size", 6, 24, 1, db, "nameFontSize", nil, function() DF:LightweightUpdateFontSize("name") end, true), 55)
        
        local outlineOptions = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline", SHADOW = "Shadow" }
        fontGroup:AddWidget(GUI:CreateDropdown(self.child, "Outline", outlineOptions, db, "nameTextOutline", function() DF:LightweightUpdateFontSize("name") end), 55)
        Add(fontGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
        
        local anchorOptions = {
            CENTER = "Center", TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
            TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
        }
        positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "nameTextAnchor", nil), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "nameTextX", nil, function() DF:LightweightUpdateTextPosition("name") end, true), 55)
        positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "nameTextY", nil, function() DF:LightweightUpdateTextPosition("name") end, true), 55)
        Add(positionGroup, nil, 2)
        
        -- ===== COLOR GROUP (Column 1) =====
        local colorGroup = GUI:CreateSettingsGroup(self.child, 280)
        colorGroup:AddWidget(GUI:CreateHeader(self.child, "Color"), 40)
        colorGroup:AddWidget(GUI:CreateCheckbox(self.child, "Use Class Color", db, "nameTextUseClassColor", function()
            self:RefreshStates()
            DF:RefreshAllVisibleFrames()
        end), 30)
        local nameColor = colorGroup:AddWidget(GUI:CreateColorPicker(self.child, "Name Color", db, "nameTextColor", true, nil, function() DF:LightweightUpdateTextColor("name") end, true), 35)
        nameColor.disableOn = function(d) return d.nameTextUseClassColor end
        Add(colorGroup, nil, 1)
        
        -- ===== TRUNCATION GROUP (Column 2) =====
        local truncGroup = GUI:CreateSettingsGroup(self.child, 280)
        truncGroup:AddWidget(GUI:CreateHeader(self.child, "Truncation"), 40)
        truncGroup:AddWidget(GUI:CreateSlider(self.child, "Max Length (0=off)", 0, 20, 1, db, "nameTextLength", function()
            self:RefreshStates()
            DF:RefreshAllVisibleFrames()
        end, function() DF:RefreshAllVisibleFrames() end, true), 55)
        
        local truncOptions = { ELLIPSIS = "Ellipsis (...)", CUT = "Cut" }
        local truncDropdown = truncGroup:AddWidget(GUI:CreateDropdown(self.child, "Truncate Mode", truncOptions, db, "nameTextTruncateMode", function() DF:RefreshAllVisibleFrames() end), 55)
        truncDropdown.disableOn = function(d) return (d.nameTextLength or 0) == 0 end
        Add(truncGroup, nil, 2)
    end)
    
    -- ========================================
    -- CATEGORY: Auras
    -- ========================================
    CreateCategory("auras", "Auras")
    
    -- Auras > Buffs (combined Layout + Appearance with collapsible sections)
    local pageBuffs = CreateSubTab("auras", "auras_buffs", "Buffs")
    BuildPage(pageBuffs, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top right
        Add(CreateCopyButton(self.child, {"buff"}, "Buffs"), 25, 2)
        
        AddSpace(10, "both")
        
        local currentSection = nil
        
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then currentSection:RegisterChild(widget) end
            return widget
        end
        
        local anchorOptions = {
            CENTER = "Center", TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
            TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
        }
        local growthOptions = {
            LEFT_UP = "Left, then Up", LEFT_DOWN = "Left, then Down",
            RIGHT_UP = "Right, then Up", RIGHT_DOWN = "Right, then Down",
            UP_LEFT = "Up, then Left", UP_RIGHT = "Up, then Right",
            DOWN_LEFT = "Down, then Left", DOWN_RIGHT = "Down, then Right",
            CENTER_UP = "Center, then Up", CENTER_DOWN = "Center, then Down",
            CENTER_LEFT = "Center, then Left", CENTER_RIGHT = "Center, then Right",
        }
        local outlineOptions = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline", SHADOW = "Shadow" }
        
        -- ===== LAYOUT SECTION =====
        local layoutSection = Add(GUI:CreateCollapsibleSection(self.child, "Layout", true), 36, "both")
        currentSection = layoutSection
        
        -- Settings Group (col1)
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 260)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Settings"), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Buffs", db, "showBuffs", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)
        local buffMax = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Max Buffs", 0, 5, 1, db, "buffMax", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        buffMax.disableOn = function(d) return not d.showBuffs end
        local buffSize = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Size", 10, 40, 1, db, "buffSize", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffSize.disableOn = function(d) return not d.showBuffs end
        local buffScale = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 2.0, 0.05, db, "buffScale", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffScale.disableOn = function(d) return not d.showBuffs end
        local buffAlpha = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Alpha", 0.0, 1.0, 0.05, db, "buffAlpha", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffAlpha.disableOn = function(d) return not d.showBuffs end
        AddToSection(settingsGroup, nil, 1)
        
        -- Position Group (col2)
        local positionGroup = GUI:CreateSettingsGroup(self.child, 260)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
        local buffAnchor = positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "buffAnchor", nil), 55)
        buffAnchor.disableOn = function(d) return not d.showBuffs end
        local buffGrowth = positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Growth", growthOptions, db, "buffGrowth", nil), 55)
        buffGrowth.disableOn = function(d) return not d.showBuffs end
        local buffOffsetX = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "buffOffsetX", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffOffsetX.disableOn = function(d) return not d.showBuffs end
        local buffOffsetY = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "buffOffsetY", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffOffsetY.disableOn = function(d) return not d.showBuffs end
        AddToSection(positionGroup, nil, 2)
        
        -- Grid Layout Group (col1)
        local gridGroup = GUI:CreateSettingsGroup(self.child, 260)
        gridGroup:AddWidget(GUI:CreateHeader(self.child, "Grid Layout"), 40)
        local buffWrap = gridGroup:AddWidget(GUI:CreateSlider(self.child, "Icons Per Row", 1, 8, 1, db, "buffWrap", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffWrap.disableOn = function(d) return not d.showBuffs end
        local buffPaddingX = gridGroup:AddWidget(GUI:CreateSlider(self.child, "Spacing X", -5, 10, 1, db, "buffPaddingX", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffPaddingX.disableOn = function(d) return not d.showBuffs end
        local buffPaddingY = gridGroup:AddWidget(GUI:CreateSlider(self.child, "Spacing Y", -5, 10, 1, db, "buffPaddingY", nil, function() DF:LightweightUpdateAuraPosition("buff") end, true), 55)
        buffPaddingY.disableOn = function(d) return not d.showBuffs end
        AddToSection(gridGroup, nil, 1)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== APPEARANCE SECTION =====
        local appearanceSection = Add(GUI:CreateCollapsibleSection(self.child, "Appearance", true), 36, "both")
        currentSection = appearanceSection
        
        local function MasqueControlsBorders(d)
            return DF.Masque and d.masqueBorderControl
        end
        
        -- Border Group (col1)
        local borderGroup = GUI:CreateSettingsGroup(self.child, 260)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, "Border"), 40)
        local buffMasqueNote = borderGroup:AddWidget(GUI:CreateLabel(self.child, "|cffff9900Borders controlled by Masque.|r See Integrations.", 230), 30)
        buffMasqueNote.hideOn = function(d) return not MasqueControlsBorders(d) end
        local buffBorderEnabled = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Border", db, "buffBorderEnabled", nil), 30)
        buffBorderEnabled.disableOn = function(d) return not d.showBuffs or MasqueControlsBorders(d) end
        buffBorderEnabled.hideOn = function(d) return MasqueControlsBorders(d) end
        local buffBorderThickness = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Border Thickness", 1, 5, 1, db, "buffBorderThickness", nil, function() DF:LightweightUpdateAuraBorder("buff") end, true), 55)
        buffBorderThickness.disableOn = function(d) return not d.showBuffs or not d.buffBorderEnabled or MasqueControlsBorders(d) end
        buffBorderThickness.hideOn = function(d) return MasqueControlsBorders(d) end
        local buffBorderInset = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Border Inset", -3, 3, 1, db, "buffBorderInset", nil, function() DF:LightweightUpdateAuraBorder("buff") end, true), 55)
        buffBorderInset.disableOn = function(d) return not d.showBuffs or not d.buffBorderEnabled or MasqueControlsBorders(d) end
        buffBorderInset.hideOn = function(d) return MasqueControlsBorders(d) end
        borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Hide Cooldown Swipe", db, "buffHideSwipe", nil), 30)
        AddToSection(borderGroup, nil, 1)
        
        -- Stack Count Group (col1)
        local stackCountGroup = GUI:CreateSettingsGroup(self.child, 260)
        stackCountGroup:AddWidget(GUI:CreateHeader(self.child, "Stack Count"), 40)
        stackCountGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "buffStackFont", function() DF:LightweightUpdateAuraStackText("buff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 2.0, 0.05, db, "buffStackScale", nil, function() DF:LightweightUpdateAuraStackText("buff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateDropdown(self.child, "Outline", outlineOptions, db, "buffStackOutline", function() DF:LightweightUpdateAuraStackText("buff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "buffStackAnchor", function() DF:LightweightUpdateAuraStackText("buff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -20, 20, 1, db, "buffStackX", nil, function() DF:LightweightUpdateAuraStackText("buff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -20, 20, 1, db, "buffStackY", nil, function() DF:LightweightUpdateAuraStackText("buff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, "Min Stacks to Show", 1, 10, 1, db, "buffStackMinimum", nil), 55)
        AddToSection(stackCountGroup, nil, 1)
        
        -- Duration Text Group (col2)
        local durationGroup = GUI:CreateSettingsGroup(self.child, 260)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, "Duration Text"), 40)
        local durShow = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Duration", db, "buffShowDuration", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)
        local durFont = durationGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "buffDurationFont", nil), 55)
        durFont.disableOn = function(d) return not d.buffShowDuration end
        local durScale = durationGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 2.0, 0.05, db, "buffDurationScale", nil, function() DF:LightweightUpdateAuraDurationText("buff") end, true), 55)
        durScale.disableOn = function(d) return not d.buffShowDuration end
        local durOutline = durationGroup:AddWidget(GUI:CreateDropdown(self.child, "Outline", outlineOptions, db, "buffDurationOutline", function() DF:LightweightUpdateAuraDurationText("buff") end), 55)
        durOutline.disableOn = function(d) return not d.buffShowDuration end
        local durAnchor = durationGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "buffDurationAnchor", function() DF:LightweightUpdateAuraDurationText("buff") end), 55)
        durAnchor.disableOn = function(d) return not d.buffShowDuration end
        local durX = durationGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -20, 20, 1, db, "buffDurationX", nil, function() DF:LightweightUpdateAuraDurationText("buff") end, true), 55)
        durX.disableOn = function(d) return not d.buffShowDuration end
        local durY = durationGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -20, 20, 1, db, "buffDurationY", nil, function() DF:LightweightUpdateAuraDurationText("buff") end, true), 55)
        durY.disableOn = function(d) return not d.buffShowDuration end
        local durColor = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, "Color by Time Remaining", db, "buffDurationColorByTime", function() DF:RefreshDurationColorSettings() end), 30)
        durColor.disableOn = function(d) return not d.buffShowDuration end
        AddToSection(durationGroup, nil, 2)
        
        -- Expiring Indicator Group (col2)
        local expiringGroup = GUI:CreateSettingsGroup(self.child, 260)
        expiringGroup:AddWidget(GUI:CreateHeader(self.child, "Expiring Indicator"), 40)
        expiringGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Expiring Indicators", db, "buffExpiringEnabled", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)
        local function HideExpiring(d) return not d.buffExpiringEnabled end
        local thresholdSlider = expiringGroup:AddWidget(GUI:CreateSlider(self.child, "Expiring Threshold (%)", 5, 95, 5, db, "buffExpiringThreshold", nil), 55)
        thresholdSlider.disableOn = HideExpiring
        local borderEnabled = expiringGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Expiring Border", db, "buffExpiringBorderEnabled", function() 
            self:RefreshStates()
            DF:UpdateAllFrames() 
        end), 30)
        borderEnabled.disableOn = HideExpiring
        local borderColorByTime = expiringGroup:AddWidget(GUI:CreateCheckbox(self.child, "Color by Time Remaining", db, "buffExpiringBorderColorByTime", function() 
            self:RefreshStates()
            DF:UpdateAllFrames() 
        end), 30)
        borderColorByTime.disableOn = function(d) return not d.buffExpiringEnabled or not d.buffExpiringBorderEnabled end
        local borderColor = expiringGroup:AddWidget(GUI:CreateColorPicker(self.child, "Border Color", db, "buffExpiringBorderColor", true, nil, function() DF:LightweightUpdateExpiringBorderColor() end, true), 35)
        borderColor.disableOn = function(d) return not d.buffExpiringEnabled or not d.buffExpiringBorderEnabled or d.buffExpiringBorderColorByTime end
        borderColor.hideOn = function(d) return d.buffExpiringBorderColorByTime end
        local borderPulsate = expiringGroup:AddWidget(GUI:CreateCheckbox(self.child, "Pulsate Border", db, "buffExpiringBorderPulsate", nil), 30)
        borderPulsate.disableOn = function(d) return not d.buffExpiringEnabled or not d.buffExpiringBorderEnabled end
        local borderThickness = expiringGroup:AddWidget(GUI:CreateSlider(self.child, "Border Thickness", 1, 5, 1, db, "buffExpiringBorderThickness", nil, function() DF:LightweightUpdateAuraBorder("buff") end, true), 55)
        borderThickness.disableOn = function(d) return not d.buffExpiringEnabled or not d.buffExpiringBorderEnabled end
        local borderInset = expiringGroup:AddWidget(GUI:CreateSlider(self.child, "Border Inset", -3, 3, 1, db, "buffExpiringBorderInset", nil, function() DF:LightweightUpdateAuraBorder("buff") end, true), 55)
        borderInset.disableOn = function(d) return not d.buffExpiringEnabled or not d.buffExpiringBorderEnabled end
        local tintEnabled = expiringGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Expiring Tint", db, "buffExpiringTintEnabled", nil), 30)
        tintEnabled.disableOn = HideExpiring
        local tintColor = expiringGroup:AddWidget(GUI:CreateColorPicker(self.child, "Tint Color", db, "buffExpiringTintColor", true, nil, function() DF:LightweightUpdateExpiringTintColor() end, true), 35)
        tintColor.disableOn = function(d) return not d.buffExpiringEnabled or not d.buffExpiringTintEnabled end
        AddToSection(expiringGroup, nil, 2)
        
        currentSection = nil
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "display_tooltips", label = "Buff Tooltips"},
            {pageId = "general_integrations", label = "Integrations"},
            {pageId = "auras_missingbuffs", label = "Missing Buffs"},
            {pageId = "auras_mybuffindicators", label = "My Buff Indicators"},
        }), 30, "both")
    end)
    
    -- Auras > My Buff Indicators
    local pageMyBuffIndicators = CreateSubTab("auras", "auras_mybuffindicators", "My Buff Indicators")
    BuildPage(pageMyBuffIndicators, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"myBuffIndicator"}, "My Buff Indicators"), 25, 2)
        
        AddSpace(10, "both")
        
        local function HideMyBuffOptions(d)
            return not d.myBuffIndicatorEnabled
        end
        
        local function HideGradientOptions(d)
            return not d.myBuffIndicatorEnabled or not d.myBuffIndicatorShowGradient
        end
        
        local function RefreshIndicators()
            if DF.UpdateAllMyBuffIndicators then DF:UpdateAllMyBuffIndicators() end
        end
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Settings"), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable My Buff Indicators", db, "myBuffIndicatorEnabled", function()
            self:RefreshStates()
            RefreshIndicators()
        end), 30)
        
        local apiWarning = settingsGroup:AddWidget(GUI:CreateWarningBox(self.child, 
            "Due to Blizzard API restrictions, this feature cannot track individual buffs. It activates when ANY of your buffs are present on a unit — it cannot distinguish between specific spells.", 
            250, 75), 80)
        apiWarning.hideOn = HideMyBuffOptions
        
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, "Shows a colored border/gradient when YOU have any buff active on this unit. Useful for tracking HoTs, shields, and other beneficial effects you've applied.", 250), 50)
        
        local showBorder = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Border", db, "myBuffIndicatorShowBorder", RefreshIndicators), 30)
        showBorder.hideOn = HideMyBuffOptions
        
        local showGradient = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Gradient", db, "myBuffIndicatorShowGradient", function()
            self:RefreshStates()
            RefreshIndicators()
        end), 30)
        showGradient.hideOn = HideMyBuffOptions
        
        local animate = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Pulse Animation", db, "myBuffIndicatorAnimate", RefreshIndicators), 30)
        animate.hideOn = HideMyBuffOptions
        
        Add(settingsGroup, nil, 1)
        
        -- ===== APPEARANCE GROUP (Column 2) =====
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, "Border Appearance"), 40)
        
        local color = appearanceGroup:AddWidget(GUI:CreateColorPicker(self.child, "Indicator Color", db, "myBuffIndicatorColor", false, RefreshIndicators), 30)
        color.hideOn = HideMyBuffOptions
        
        local borderSize = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, "Border Thickness", 1, 6, 1, db, "myBuffIndicatorBorderSize", nil, RefreshIndicators, true), 55)
        borderSize.hideOn = HideMyBuffOptions
        
        local borderInset = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, "Border Inset", -4, 4, 1, db, "myBuffIndicatorBorderInset", nil, RefreshIndicators, true), 55)
        borderInset.hideOn = HideMyBuffOptions
        
        local borderAlpha = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, "Border Opacity", 0.1, 1.0, 0.1, db, "myBuffIndicatorBorderAlpha", nil, RefreshIndicators, true), 55)
        borderAlpha.hideOn = HideMyBuffOptions
        
        appearanceGroup.hideOn = HideMyBuffOptions
        Add(appearanceGroup, nil, 2)
        
        -- ===== GRADIENT GROUP (Column 1, row 2) =====
        local gradientGroup = GUI:CreateSettingsGroup(self.child, 280)
        gradientGroup:AddWidget(GUI:CreateHeader(self.child, "Gradient Appearance"), 40)
        
        local gradientStyleOptions = {
            FULL = "Full Frame",
            TOP = "Top Edge",
            BOTTOM = "Bottom Edge",
            LEFT = "Left Edge",
            RIGHT = "Right Edge",
            EDGE = "Edge Glow (All Sides)",
        }
        local gradientStyle = gradientGroup:AddWidget(GUI:CreateDropdown(self.child, "Gradient Style", gradientStyleOptions, db, "myBuffIndicatorGradientStyle", function()
            self:RefreshStates()
            RefreshIndicators()
        end), 55)
        gradientStyle.hideOn = HideGradientOptions
        
        local function HideOnCurrentHealthOption(d)
            return not d.myBuffIndicatorEnabled or not d.myBuffIndicatorShowGradient or d.myBuffIndicatorGradientStyle ~= "FULL"
        end
        local onHealthCheck = gradientGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show On Current Health Only", db, "myBuffIndicatorGradientOnCurrentHealth", RefreshIndicators), 30)
        onHealthCheck.hideOn = HideOnCurrentHealthOption
        
        local gradientAlpha = gradientGroup:AddWidget(GUI:CreateSlider(self.child, "Gradient Opacity", 0.1, 1.0, 0.05, db, "myBuffIndicatorGradientAlpha", nil, RefreshIndicators, true), 55)
        gradientAlpha.hideOn = HideGradientOptions
        
        local gradientSize = gradientGroup:AddWidget(GUI:CreateSlider(self.child, "Gradient Size", 0.1, 1.0, 0.05, db, "myBuffIndicatorGradientSize", nil, RefreshIndicators, true), 55)
        gradientSize.hideOn = HideGradientOptions
        
        gradientGroup.hideOn = HideGradientOptions
        Add(gradientGroup, nil, 1)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = "Buffs"},
            {pageId = "auras_debuffs", label = "Debuffs"},
            {pageId = "auras_dispel", label = "Dispel Overlay"},
        }), 30, "both")
    end)
    
    -- Auras > Debuffs (combined Layout + Appearance with collapsible sections)
    local pageDebuffs = CreateSubTab("auras", "auras_debuffs", "Debuffs")
    BuildPage(pageDebuffs, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"debuff"}, "Debuffs"), 25, 2)
        
        AddSpace(10, "both")
        
        local currentSection = nil
        
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then currentSection:RegisterChild(widget) end
            return widget
        end
        
        local anchorOptions = {
            CENTER = "Center", TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
            TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
        }
        local growthOptions = {
            LEFT_UP = "Left, then Up", LEFT_DOWN = "Left, then Down",
            RIGHT_UP = "Right, then Up", RIGHT_DOWN = "Right, then Down",
            UP_LEFT = "Up, then Left", UP_RIGHT = "Up, then Right",
            DOWN_LEFT = "Down, then Left", DOWN_RIGHT = "Down, then Right",
            CENTER_UP = "Center, then Up", CENTER_DOWN = "Center, then Down",
            CENTER_LEFT = "Center, then Left", CENTER_RIGHT = "Center, then Right",
        }
        local outlineOptions = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline", SHADOW = "Shadow" }
        
        -- ===== LAYOUT SECTION =====
        local layoutSection = Add(GUI:CreateCollapsibleSection(self.child, "Layout", true), 36, "both")
        currentSection = layoutSection
        
        -- Settings Group (col1)
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 260)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Settings"), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Debuffs", db, "showDebuffs", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)
        local dispelHighlight = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Highlight Dispellable", db, "dispellableHighlight", nil), 30)
        dispelHighlight.disableOn = function(d) return not d.showDebuffs end
        local debuffMax = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Max Debuffs", 0, 5, 1, db, "debuffMax", nil, function() DF:RefreshAllVisibleFrames() end, true), 55)
        debuffMax.disableOn = function(d) return not d.showDebuffs end
        local debuffSize = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Size", 10, 40, 1, db, "debuffSize", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffSize.disableOn = function(d) return not d.showDebuffs end
        local debuffScale = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 2.0, 0.05, db, "debuffScale", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffScale.disableOn = function(d) return not d.showDebuffs end
        local debuffAlpha = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Alpha", 0.0, 1.0, 0.05, db, "debuffAlpha", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffAlpha.disableOn = function(d) return not d.showDebuffs end
        AddToSection(settingsGroup, nil, 1)
        
        -- Position Group (col2)
        local positionGroup = GUI:CreateSettingsGroup(self.child, 260)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
        local debuffAnchor = positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "debuffAnchor", nil), 55)
        debuffAnchor.disableOn = function(d) return not d.showDebuffs end
        local debuffGrowth = positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Growth", growthOptions, db, "debuffGrowth", nil), 55)
        debuffGrowth.disableOn = function(d) return not d.showDebuffs end
        local debuffOffsetX = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "debuffOffsetX", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffOffsetX.disableOn = function(d) return not d.showDebuffs end
        local debuffOffsetY = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "debuffOffsetY", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffOffsetY.disableOn = function(d) return not d.showDebuffs end
        AddToSection(positionGroup, nil, 2)
        
        -- Grid Layout Group (col1)
        local gridGroup = GUI:CreateSettingsGroup(self.child, 260)
        gridGroup:AddWidget(GUI:CreateHeader(self.child, "Grid Layout"), 40)
        local debuffWrap = gridGroup:AddWidget(GUI:CreateSlider(self.child, "Icons Per Row", 1, 8, 1, db, "debuffWrap", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffWrap.disableOn = function(d) return not d.showDebuffs end
        local debuffPaddingX = gridGroup:AddWidget(GUI:CreateSlider(self.child, "Spacing X", -5, 10, 1, db, "debuffPaddingX", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffPaddingX.disableOn = function(d) return not d.showDebuffs end
        local debuffPaddingY = gridGroup:AddWidget(GUI:CreateSlider(self.child, "Spacing Y", -5, 10, 1, db, "debuffPaddingY", nil, function() DF:LightweightUpdateAuraPosition("debuff") end, true), 55)
        debuffPaddingY.disableOn = function(d) return not d.showDebuffs end
        AddToSection(gridGroup, nil, 1)
        
        -- Blizzard Settings Group (col2)
        local blizzGroup = GUI:CreateSettingsGroup(self.child, 260)
        blizzGroup:AddWidget(GUI:CreateHeader(self.child, "Blizzard Frame Settings"), 40)
        blizzGroup:AddWidget(GUI:CreateLabel(self.child, "Controls Blizzard's debuff filtering (affects our display too).", 230), 35)
        local partyDb = DF.db.party
        blizzGroup:AddWidget(GUI:CreateCheckbox(self.child, "Only Dispellable Debuffs", partyDb, "_blizzOnlyDispellable", function()
            local newValue = partyDb._blizzOnlyDispellable
            SetCVar("raidFramesDisplayOnlyDispellableDebuffs", newValue and 1 or 0)
        end), 30)
        AddToSection(blizzGroup, nil, 2)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== APPEARANCE SECTION =====
        local appearanceSection = Add(GUI:CreateCollapsibleSection(self.child, "Appearance", true), 36, "both")
        currentSection = appearanceSection
        
        local function MasqueControlsBorders(d)
            return DF.Masque and d.masqueBorderControl
        end
        
        local function InvalidateAndUpdate()
            DF.debuffBorderCurve = nil
            DF:UpdateAllFrames()
        end
        
        -- Border Group (col1)
        local borderGroup = GUI:CreateSettingsGroup(self.child, 260)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, "Border"), 40)
        local debuffMasqueNote = borderGroup:AddWidget(GUI:CreateLabel(self.child, "|cffff9900Borders controlled by Masque.|r See Integrations.", 230), 30)
        debuffMasqueNote.hideOn = function(d) return not MasqueControlsBorders(d) end
        local debuffBorderEnabled = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Border", db, "debuffBorderEnabled", InvalidateAndUpdate), 30)
        debuffBorderEnabled.disableOn = function(d) return not d.showDebuffs or MasqueControlsBorders(d) end
        debuffBorderEnabled.hideOn = function(d) return MasqueControlsBorders(d) end
        local debuffBorderThickness = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Border Thickness", 1, 5, 1, db, "debuffBorderThickness", nil, function() DF:LightweightUpdateAuraBorder("debuff") end, true), 55)
        debuffBorderThickness.disableOn = function(d) return not d.showDebuffs or not d.debuffBorderEnabled or MasqueControlsBorders(d) end
        debuffBorderThickness.hideOn = function(d) return MasqueControlsBorders(d) end
        local debuffBorderInset = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Border Inset", -3, 3, 1, db, "debuffBorderInset", nil, function() DF:LightweightUpdateAuraBorder("debuff") end, true), 55)
        debuffBorderInset.disableOn = function(d) return not d.showDebuffs or not d.debuffBorderEnabled or MasqueControlsBorders(d) end
        debuffBorderInset.hideOn = function(d) return MasqueControlsBorders(d) end
        local colorByType = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Color by Dispel Type", db, "debuffBorderColorByType", InvalidateAndUpdate), 30)
        colorByType.disableOn = function(d) return not d.debuffBorderEnabled or MasqueControlsBorders(d) end
        colorByType.hideOn = function(d) return MasqueControlsBorders(d) end
        borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Hide Cooldown Swipe", db, "debuffHideSwipe", nil), 30)
        AddToSection(borderGroup, nil, 1)
        
        -- Dispel Colors Group (col2)
        local colorsGroup = GUI:CreateSettingsGroup(self.child, 260)
        colorsGroup:AddWidget(GUI:CreateHeader(self.child, "Dispel Type Colors"), 40)
        local magicColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, "Magic", db, "debuffBorderColorMagic", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        magicColor.disableOn = function(d) return not d.debuffBorderEnabled or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        local curseColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, "Curse", db, "debuffBorderColorCurse", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        curseColor.disableOn = function(d) return not d.debuffBorderEnabled or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        local diseaseColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, "Disease", db, "debuffBorderColorDisease", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        diseaseColor.disableOn = function(d) return not d.debuffBorderEnabled or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        local poisonColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, "Poison", db, "debuffBorderColorPoison", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        poisonColor.disableOn = function(d) return not d.debuffBorderEnabled or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        local bleedColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, "Bleed / Enrage", db, "debuffBorderColorBleed", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        bleedColor.disableOn = function(d) return not d.debuffBorderEnabled or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        local noneColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, "None / Physical", db, "debuffBorderColorNone", false, InvalidateAndUpdate, function() DF:LightweightUpdateDebuffBorderColors() end, true), 30)
        noneColor.disableOn = function(d) return not d.debuffBorderEnabled or not d.debuffBorderColorByType or MasqueControlsBorders(d) end
        colorsGroup.hideOn = function(d) return MasqueControlsBorders(d) end
        AddToSection(colorsGroup, nil, 2)
        
        -- Stack Count Group (col1)
        local stackCountGroup = GUI:CreateSettingsGroup(self.child, 260)
        stackCountGroup:AddWidget(GUI:CreateHeader(self.child, "Stack Count"), 40)
        stackCountGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "debuffStackFont", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 2.0, 0.05, db, "debuffStackScale", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateDropdown(self.child, "Outline", outlineOptions, db, "debuffStackOutline", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "debuffStackAnchor", function() DF:LightweightUpdateAuraStackText("debuff") end), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -20, 20, 1, db, "debuffStackX", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -20, 20, 1, db, "debuffStackY", nil, function() DF:LightweightUpdateAuraStackText("debuff") end, true), 55)
        stackCountGroup:AddWidget(GUI:CreateSlider(self.child, "Min Stacks to Show", 1, 10, 1, db, "debuffStackMinimum", nil), 55)
        AddToSection(stackCountGroup, nil, 1)
        
        -- Duration Text Group (col2)
        local durationGroup = GUI:CreateSettingsGroup(self.child, 260)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, "Duration Text"), 40)
        local durShow = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Duration", db, "debuffShowDuration", function()
            self:RefreshStates()
            DF:UpdateAllFrames()
        end), 30)
        local durFont = durationGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "debuffDurationFont", nil), 55)
        durFont.disableOn = function(d) return not d.debuffShowDuration end
        local durScale = durationGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 2.0, 0.05, db, "debuffDurationScale", nil, function() DF:LightweightUpdateAuraDurationText("debuff") end, true), 55)
        durScale.disableOn = function(d) return not d.debuffShowDuration end
        local durOutline = durationGroup:AddWidget(GUI:CreateDropdown(self.child, "Outline", outlineOptions, db, "debuffDurationOutline", function() DF:LightweightUpdateAuraDurationText("debuff") end), 55)
        durOutline.disableOn = function(d) return not d.debuffShowDuration end
        local durAnchor = durationGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "debuffDurationAnchor", function() DF:LightweightUpdateAuraDurationText("debuff") end), 55)
        durAnchor.disableOn = function(d) return not d.debuffShowDuration end
        local durX = durationGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -20, 20, 1, db, "debuffDurationX", nil, function() DF:LightweightUpdateAuraDurationText("debuff") end, true), 55)
        durX.disableOn = function(d) return not d.debuffShowDuration end
        local durY = durationGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -20, 20, 1, db, "debuffDurationY", nil, function() DF:LightweightUpdateAuraDurationText("debuff") end, true), 55)
        durY.disableOn = function(d) return not d.debuffShowDuration end
        local durColor = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, "Color by Time Remaining", db, "debuffDurationColorByTime", function() DF:RefreshDurationColorSettings() end), 30)
        durColor.disableOn = function(d) return not d.debuffShowDuration end
        AddToSection(durationGroup, nil, 2)
        
        currentSection = nil
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "display_tooltips", label = "Debuff Tooltips"},
            {pageId = "general_integrations", label = "Integrations"},
            {pageId = "auras_mybuffindicators", label = "My Buff Indicators"},
            {pageId = "auras_dispel", label = "Dispel Overlay"},
            {pageId = "auras_bossdebuffs", label = "Boss Debuffs"},
        }), 30, "both")
    end)
    
    -- Auras > Boss Debuffs (Private Auras)
    local pageBossDebuffs = CreateSubTab("auras", "auras_bossdebuffs", "Boss Debuffs")
    BuildPage(pageBossDebuffs, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"bossDebuff"}, "Boss Debuffs"), 25, 2)
        
        AddSpace(10, "both")
        
        local anchorOptions = {
            ["TOPLEFT"] = "Top Left", ["TOP"] = "Top", ["TOPRIGHT"] = "Top Right",
            ["LEFT"] = "Left", ["CENTER"] = "Center", ["RIGHT"] = "Right",
            ["BOTTOMLEFT"] = "Bottom Left", ["BOTTOM"] = "Bottom", ["BOTTOMRIGHT"] = "Bottom Right",
        }
        
        local function HideBossDebuffOptions(d)
            return not d.bossDebuffsEnabled
        end
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Settings"), 40)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, "Boss Debuffs (Private Auras) are special debuffs that Blizzard hides from addons.", 250), 35)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Boss Debuffs", db, "bossDebuffsEnabled", function()
            self:RefreshStates()
            if DF.UpdateAllPrivateAuraVisibility then DF:UpdateAllPrivateAuraVisibility() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end), 30)
        local maxCount = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Max Icons", 1, 4, 1, db, "bossDebuffsMax", nil, function()
            if DF.RefreshAllPrivateAuraAnchors then DF:RefreshAllPrivateAuraAnchors() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end, true), 55)
        maxCount.hideOn = HideBossDebuffOptions
        local showCountdown = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Cooldown Swipe", db, "bossDebuffsShowCountdown", function()
            self:RefreshStates()
            if DF.RefreshAllPrivateAuraAnchors then DF:RefreshAllPrivateAuraAnchors() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end), 30)
        showCountdown.hideOn = HideBossDebuffOptions
        local showNumbers = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Duration Numbers", db, "bossDebuffsShowNumbers", function()
            self:RefreshStates()
            if DF.RefreshAllPrivateAuraAnchors then DF:RefreshAllPrivateAuraAnchors() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end), 30)
        showNumbers.hideOn = function(d) return not d.bossDebuffsEnabled end
        local textScale = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Text Scale", 0.1, 5.0, 0.1, db, "bossDebuffsTextScale", nil, function()
            if DF.PreviewPrivateAuraAnchors then DF:PreviewPrivateAuraAnchors() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end, true), 55)
        textScale.hideOn = function(d) return not d.bossDebuffsEnabled or not d.bossDebuffsShowNumbers end
        local textOffsetX = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Text Offset X", -50, 50, 1, db, "bossDebuffsTextOffsetX", nil, function()
            if DF.PreviewPrivateAuraAnchors then DF:PreviewPrivateAuraAnchors() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end, true), 55)
        textOffsetX.hideOn = function(d) return not d.bossDebuffsEnabled or not d.bossDebuffsShowNumbers end
        local textOffsetY = settingsGroup:AddWidget(GUI:CreateSlider(self.child, "Text Offset Y", -50, 50, 1, db, "bossDebuffsTextOffsetY", nil, function()
            if DF.PreviewPrivateAuraAnchors then DF:PreviewPrivateAuraAnchors() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end, true), 55)
        textOffsetY.hideOn = function(d) return not d.bossDebuffsEnabled or not d.bossDebuffsShowNumbers end
        Add(settingsGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
        local anchor = positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "bossDebuffsAnchor", function()
            if DF.UpdateAllPrivateAuraPositions then DF:UpdateAllPrivateAuraPositions() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end), 55)
        anchor.hideOn = HideBossDebuffOptions
        local growthOptions4 = { RIGHT = "Right", LEFT = "Left", DOWN = "Down", UP = "Up" }
        local growth = positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Growth Direction", growthOptions4, db, "bossDebuffsGrowth", function()
            if DF.UpdateAllPrivateAuraPositions then DF:UpdateAllPrivateAuraPositions() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end), 55)
        growth.hideOn = HideBossDebuffOptions
        local offsetX = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -100, 100, 1, db, "bossDebuffsOffsetX", nil, function()
            if DF.UpdateAllPrivateAuraPositions then DF:UpdateAllPrivateAuraPositions() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end, true), 55)
        offsetX.hideOn = HideBossDebuffOptions
        local offsetY = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -100, 100, 1, db, "bossDebuffsOffsetY", nil, function()
            if DF.UpdateAllPrivateAuraPositions then DF:UpdateAllPrivateAuraPositions() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end, true), 55)
        offsetY.hideOn = HideBossDebuffOptions
        Add(positionGroup, nil, 2)
        
        -- ===== SIZE GROUP (Column 1) =====
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 280)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, "Size & Spacing"), 40)
        local iconWidth = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Width", 10, 60, 1, db, "bossDebuffsIconWidth", nil, function()
            if DF.PreviewPrivateAuraAnchors then DF:PreviewPrivateAuraAnchors() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end, true), 55)
        iconWidth.hideOn = HideBossDebuffOptions
        local iconHeight = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Height", 10, 60, 1, db, "bossDebuffsIconHeight", nil, function()
            if DF.PreviewPrivateAuraAnchors then DF:PreviewPrivateAuraAnchors() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end, true), 55)
        iconHeight.hideOn = HideBossDebuffOptions
        local borderScale = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Border Scale", 0, 2.0, 0.1, db, "bossDebuffsBorderScale", nil, function()
            if DF.PreviewPrivateAuraAnchors then DF:PreviewPrivateAuraAnchors() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end, true), 55)
        borderScale.hideOn = HideBossDebuffOptions
        local spacing = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Spacing", 0, 20, 1, db, "bossDebuffsSpacing", nil, function()
            if DF.UpdateAllPrivateAuraPositions then DF:UpdateAllPrivateAuraPositions() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end, true), 55)
        spacing.hideOn = HideBossDebuffOptions
        local frameLevel = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "bossDebuffsFrameLevel", nil, function()
            if DF.UpdateAllPrivateAuraFrameLevel then DF:UpdateAllPrivateAuraFrameLevel() end
            if DF.UpdateAllTestBossDebuffs then DF:UpdateAllTestBossDebuffs() end
        end, true), 55)
        frameLevel.hideOn = HideBossDebuffOptions
        sizeGroup.hideOn = HideBossDebuffOptions
        Add(sizeGroup, nil, 1)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_debuffs", label = "Debuffs"},
            {pageId = "auras_dispel", label = "Dispel Overlay"},
        }), 30, "both")
    end)
    
    -- Auras > Missing Buffs
    local pageMissingBuffs = CreateSubTab("auras", "auras_missingbuffs", "Missing Buffs")
    BuildPage(pageMissingBuffs, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"missingBuff"}, "Missing Buffs"), 25, 2)
        
        AddSpace(10, "both")
        
        local function HideMissingBuffOptions(d)
            return not d.missingBuffIconEnabled
        end
        
        local function HideManualBuffOptions(d)
            return not d.missingBuffIconEnabled or d.missingBuffClassDetection
        end
        
        local anchorOptions = {
            ["TOPLEFT"] = "Top Left", ["TOP"] = "Top", ["TOPRIGHT"] = "Top Right",
            ["LEFT"] = "Left", ["CENTER"] = "Center", ["RIGHT"] = "Right",
            ["BOTTOMLEFT"] = "Bottom Left", ["BOTTOM"] = "Bottom", ["BOTTOMRIGHT"] = "Bottom Right",
        }
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Settings"), 40)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, "Shows icon when party members are missing raid buffs.", 250), 30)
        settingsGroup:AddWidget(GUI:CreateWarningBox(self.child, "|cffff6666NOTE:|r Only works OUT OF COMBAT. Does NOT work in Mythic+ keystones.", 250, 55), 60)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Missing Buff Icon", db, "missingBuffIconEnabled", function()
            self:RefreshStates()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 30)
        local classDetect = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Auto-detect (your class's buff)", db, "missingBuffClassDetection", function()
            self:RefreshStates()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 30)
        classDetect.hideOn = HideMissingBuffOptions
        local hideBar = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Hide raid buffs from buff bar", db, "missingBuffHideFromBar", function()
            DF:UpdateAllAuras()
        end), 30)
        hideBar.hideOn = HideMissingBuffOptions
        local chkDebug = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Debug Mode (print to chat)", db, "missingBuffIconDebug", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 30)
        chkDebug.hideOn = HideMissingBuffOptions
        Add(settingsGroup, nil, 1)
        
        -- ===== BUFFS TO CHECK GROUP (Column 2) =====
        local buffsGroup = GUI:CreateSettingsGroup(self.child, 280)
        buffsGroup:AddWidget(GUI:CreateHeader(self.child, "Buffs to Check (Manual Mode)"), 40)
        buffsGroup:AddWidget(GUI:CreateLabel(self.child, "When auto-detect is OFF, select which raid buffs to monitor manually.", 250), 35)
        local chkInt = buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Arcane Intellect (Mage)", db, "missingBuffCheckIntellect", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 30)
        chkInt.hideOn = HideManualBuffOptions
        local chkStam = buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Power Word: Fortitude (Priest)", db, "missingBuffCheckStamina", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 30)
        chkStam.hideOn = HideManualBuffOptions
        local chkAP = buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Battle Shout (Warrior)", db, "missingBuffCheckAttackPower", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 30)
        chkAP.hideOn = HideManualBuffOptions
        local chkVers = buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Mark of the Wild (Druid)", db, "missingBuffCheckVersatility", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 30)
        chkVers.hideOn = HideManualBuffOptions
        local chkSky = buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Skyfury (Shaman)", db, "missingBuffCheckSkyfury", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 30)
        chkSky.hideOn = HideManualBuffOptions
        local chkBronze = buffsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Blessing of the Bronze (Evoker)", db, "missingBuffCheckBronze", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 30)
        chkBronze.hideOn = HideManualBuffOptions
        buffsGroup.hideOn = HideMissingBuffOptions
        Add(buffsGroup, nil, 2)
        
        -- ===== APPEARANCE GROUP (Column 1) =====
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, "Appearance"), 40)
        local mbSize = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Size", 12, 48, 1, db, "missingBuffIconSize", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        mbSize.hideOn = HideMissingBuffOptions
        local mbScale = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 3.0, 0.1, db, "missingBuffIconScale", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        mbScale.hideOn = HideMissingBuffOptions
        local mbLevel = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "missingBuffIconFrameLevel", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end, function() DF:LightweightUpdateFrameLevel("missingBuff") end, true), 55)
        mbLevel.hideOn = HideMissingBuffOptions
        appearanceGroup.hideOn = HideMissingBuffOptions
        Add(appearanceGroup, nil, 1)
        
        -- ===== POSITION GROUP (Column 2) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
        local mbAnchor = positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "missingBuffIconAnchor", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 55)
        mbAnchor.hideOn = HideMissingBuffOptions
        local mbX = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "missingBuffIconX", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        mbX.hideOn = HideMissingBuffOptions
        local mbY = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "missingBuffIconY", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        mbY.hideOn = HideMissingBuffOptions
        positionGroup.hideOn = HideMissingBuffOptions
        Add(positionGroup, nil, 2)
        
        -- ===== BORDER GROUP (Column 1) =====
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, "Border"), 40)
        local mbShowBorder = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Border", db, "missingBuffIconShowBorder", function()
            self:RefreshStates()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end), 30)
        mbShowBorder.hideOn = HideMissingBuffOptions
        local function HideMissingBuffBorderOptions(d)
            return not d.missingBuffIconEnabled or not d.missingBuffIconShowBorder
        end
        local mbBorder = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Border Size", 1, 6, 1, db, "missingBuffIconBorderSize", function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end, function() DF:LightweightUpdateMissingBuff() end, true), 55)
        mbBorder.hideOn = HideMissingBuffBorderOptions
        local mbColor = borderGroup:AddWidget(GUI:CreateColorPicker(self.child, "Border Color", db, "missingBuffIconBorderColor", true, function()
            if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
        end, function() DF:LightweightUpdateMissingBuffBorderColor() end, true), 35)
        mbColor.hideOn = HideMissingBuffBorderOptions
        borderGroup.hideOn = HideMissingBuffOptions
        Add(borderGroup, nil, 1)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = "Buffs"},
        }), 30, "both")
    end)
    
    -- Auras > Defensive Icon
    local pageDefensiveIcon = CreateSubTab("auras", "auras_defensiveicon", "Defensive Icon")
    BuildPage(pageDefensiveIcon, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"defensiveIcon"}, "Defensive Icon"), 25, 2)
        
        local anchorOptions = {
            CENTER = "Center", TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
            TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
        }
        
        local function HideDefensiveIconOptions(d)
            return not d.defensiveIconEnabled
        end
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Settings"), 40)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, "Shows an icon when party members have a defensive cooldown active (Pain Suppression, Ironbark, etc.).", 250), 45)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Defensive Icon", db, "defensiveIconEnabled", function()
            self:RefreshStates()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 30)
        
        local hideSwipe = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Hide Cooldown Swipe", db, "defensiveIconHideSwipe", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 30)
        hideSwipe.hideOn = HideDefensiveIconOptions
        Add(settingsGroup, nil, 1)
        
        -- ===== APPEARANCE GROUP (Column 2) =====
        local appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)
        appearanceGroup:AddWidget(GUI:CreateHeader(self.child, "Appearance"), 40)
        
        local diIconSize = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Size", 12, 48, 1, db, "defensiveIconSize", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)
        diIconSize.hideOn = HideDefensiveIconOptions
        
        local diScale = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 4.0, 0.1, db, "defensiveIconScale", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)
        diScale.hideOn = HideDefensiveIconOptions
        
        local diLevel = appearanceGroup:AddWidget(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "defensiveIconFrameLevel", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateFrameLevel("defensive") end, true), 55)
        diLevel.hideOn = HideDefensiveIconOptions
        
        local levelNote = appearanceGroup:AddWidget(GUI:CreateLabel(self.child, "0=Auto, Higher=On top of more elements", 230), 25)
        levelNote.hideOn = HideDefensiveIconOptions
        Add(appearanceGroup, nil, 2)
        
        -- ===== POSITION GROUP (Column 1) =====
        local positionGroup = GUI:CreateSettingsGroup(self.child, 280)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
        
        local diAnchor = positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "defensiveIconAnchor", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 55)
        diAnchor.hideOn = HideDefensiveIconOptions
        
        local diX = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -100, 100, 1, db, "defensiveIconX", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)
        diX.hideOn = HideDefensiveIconOptions
        
        local diY = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -100, 100, 1, db, "defensiveIconY", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)
        diY.hideOn = HideDefensiveIconOptions
        Add(positionGroup, nil, 1)
        
        -- ===== BORDER GROUP (Column 2) =====
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, "Border"), 40)
        
        local diShowBorder = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Border", db, "defensiveIconShowBorder", function()
            self:RefreshStates()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 30)
        diShowBorder.hideOn = HideDefensiveIconOptions
        
        local function HideDefensiveBorderOptions(d)
            return not d.defensiveIconEnabled or not d.defensiveIconShowBorder
        end
        
        local diBorder = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Border Size", 0, 8, 1, db, "defensiveIconBorderSize", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)
        diBorder.hideOn = HideDefensiveBorderOptions
        
        local diColor = borderGroup:AddWidget(GUI:CreateColorPicker(self.child, "Border Color", db, "defensiveIconBorderColor", true, function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIconColors() end, true), 35)
        diColor.hideOn = HideDefensiveBorderOptions
        Add(borderGroup, nil, 2)
        
        -- ===== DURATION GROUP (Column 1) =====
        local durationGroup = GUI:CreateSettingsGroup(self.child, 280)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, "Duration Text"), 40)
        
        local showDur = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Duration Text", db, "defensiveIconShowDuration", function()
            self:RefreshStates()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 30)
        showDur.hideOn = HideDefensiveIconOptions
        
        local function HideDefensiveDurationOptions(d)
            return not d.defensiveIconEnabled or not d.defensiveIconShowDuration
        end
        
        local diDurFont = durationGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Duration Font", db, "defensiveIconDurationFont", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 55)
        diDurFont.hideOn = HideDefensiveDurationOptions
        
        local diDurScale = durationGroup:AddWidget(GUI:CreateSlider(self.child, "Duration Scale", 0.5, 2.0, 0.05, db, "defensiveIconDurationScale", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)
        diDurScale.hideOn = HideDefensiveDurationOptions
        
        local outlineOptions = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline", SHADOW = "Shadow" }
        local diDurOutline = durationGroup:AddWidget(GUI:CreateDropdown(self.child, "Duration Outline", outlineOptions, db, "defensiveIconDurationOutline", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 55)
        diDurOutline.hideOn = HideDefensiveDurationOptions
        
        durationGroup.hideOn = HideDefensiveIconOptions
        Add(durationGroup, nil, 1)
        
        -- ===== DURATION POSITION GROUP (Column 2) =====
        local durPosGroup = GUI:CreateSettingsGroup(self.child, 280)
        durPosGroup:AddWidget(GUI:CreateHeader(self.child, "Duration Position"), 40)
        
        local diDurX = durPosGroup:AddWidget(GUI:CreateSlider(self.child, "Duration X Offset", -20, 20, 1, db, "defensiveIconDurationX", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)
        diDurX.hideOn = HideDefensiveDurationOptions
        
        local diDurY = durPosGroup:AddWidget(GUI:CreateSlider(self.child, "Duration Y Offset", -20, 20, 1, db, "defensiveIconDurationY", function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIcons() end, true), 55)
        diDurY.hideOn = HideDefensiveDurationOptions
        
        local diDurColor = durPosGroup:AddWidget(GUI:CreateColorPicker(self.child, "Duration Color", db, "defensiveIconDurationColor", false, function()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end, function() DF:LightweightUpdateDefensiveIconColors() end, true), 35)
        diDurColor.hideOn = HideDefensiveDurationOptions
        diDurColor.disableOn = function(d) return d.defensiveIconDurationColorByTime end
        
        local diDurColorByTime = durPosGroup:AddWidget(GUI:CreateCheckbox(self.child, "Color by Time Remaining", db, "defensiveIconDurationColorByTime", function()
            self:RefreshStates()
            if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
        end), 30)
        diDurColorByTime.hideOn = HideDefensiveDurationOptions
        
        durPosGroup.hideOn = HideDefensiveIconOptions
        Add(durPosGroup, nil, 2)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = "Buffs"},
            {pageId = "auras_debuffs", label = "Debuffs"},
            {pageId = "general_integrations", label = "Integrations"},
        }), 30, "both")
    end)
    
    -- ========================================
    -- CATEGORY: Indicators
    -- ========================================
    CreateCategory("indicators", "Indicators")
    
    -- Indicators > Targeted Spells (moved from Auras)
    local pageTargetedSpells = CreateSubTab("indicators", "indicators_targetedspells", "Targeted Spells")
    BuildPage(pageTargetedSpells, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"targetedSpell"}, "Targeted Spells"), 25, 2)
        
        AddSpace(10, "both")
        
        local currentSection = nil
        
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then currentSection:RegisterChild(widget) end
            return widget
        end
        
        local anchorOptions = {
            CENTER = "Center", TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
            TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
        }
        local outlineOptions = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline", SHADOW = "Shadow" }
        local growthOptions = { UP = "Up", DOWN = "Down", LEFT = "Left", RIGHT = "Right", CENTER_H = "Center (Horizontal)", CENTER_V = "Center (Vertical)" }
        
        local function HideTargetedSpellOptions(d) return not d.targetedSpellEnabled end
        local function HideTargetedDurationOptions(d) return not d.targetedSpellEnabled or not d.targetedSpellShowDuration end
        local function HideBorderOptions(d) return not d.targetedSpellEnabled or not d.targetedSpellShowBorder end
        
        local function TargetedSpellLightweightUpdate()
            if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestTargetedSpell then DF:UpdateAllTestTargetedSpell() end
        end
        
        local function FullUpdate()
            if DF.UpdateAllTargetedSpellLayouts then DF:UpdateAllTargetedSpellLayouts() end
            TargetedSpellLightweightUpdate()
        end
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Settings"), 40)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, "Shows an icon when an enemy is casting a spell targeting a party/raid member.", 250), 35)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Targeted Spells", db, "targetedSpellEnabled", function()
            self:RefreshStates()
            if DF.ToggleTargetedSpells then DF:ToggleTargetedSpells(db.targetedSpellEnabled) end
        end), 30)
        local tsImportantOnly = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Important Spells Only", db, "targetedSpellImportantOnly", function()
            self:RefreshStates()
            FullUpdate()
        end), 30)
        tsImportantOnly.disableOn = HideTargetedSpellOptions
        local tsNameplateOffscreen = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Offscreen Nameplates", db, "targetedSpellNameplateOffscreen", function()
            if DF.SetNameplateOffscreen then DF:SetNameplateOffscreen(db.targetedSpellNameplateOffscreen) end
            FullUpdate()
        end), 30)
        tsNameplateOffscreen.disableOn = HideTargetedSpellOptions
        Add(settingsGroup, nil, 1)
        
        -- ===== CONTENT TYPES GROUP (Column 2) =====
        local contentGroup = GUI:CreateSettingsGroup(self.child, 280)
        contentGroup:AddWidget(GUI:CreateHeader(self.child, "Content Types"), 40)
        contentGroup:AddWidget(GUI:CreateLabel(self.child, "Show in content types:", 250), 25)
        local tsOpenWorld = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, "Open World", db, "targetedSpellInOpenWorld", nil), 25)
        tsOpenWorld.disableOn = HideTargetedSpellOptions
        local tsDungeons = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, "Dungeons", db, "targetedSpellInDungeons", nil), 25)
        tsDungeons.disableOn = HideTargetedSpellOptions
        tsDungeons.hideOn = function() return GUI.SelectedMode == "raid" end
        local tsArena = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, "Arena", db, "targetedSpellInArena", nil), 25)
        tsArena.disableOn = HideTargetedSpellOptions
        tsArena.hideOn = function() return GUI.SelectedMode == "raid" end
        local tsRaids = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, "Raids", db, "targetedSpellInRaids", nil), 25)
        tsRaids.disableOn = HideTargetedSpellOptions
        tsRaids.hideOn = function() return GUI.SelectedMode ~= "raid" end
        local tsBattlegrounds = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, "Battlegrounds", db, "targetedSpellInBattlegrounds", nil), 25)
        tsBattlegrounds.disableOn = HideTargetedSpellOptions
        tsBattlegrounds.hideOn = function() return GUI.SelectedMode ~= "raid" end
        contentGroup.hideOn = HideTargetedSpellOptions
        Add(contentGroup, nil, 2)
        
        -- Cast History button
        local historyBtn = GUI:CreateButton(self.child, "Open Cast History", 140, 24, function()
            if DF.ShowCastHistoryUI then DF:ShowCastHistoryUI() end
        end)
        Add(historyBtn, 30, 1)
        
        AddSpace(10, "both")
        
        -- ===== LAYOUT SECTION =====
        local layoutSection = Add(GUI:CreateCollapsibleSection(self.child, "Layout", true), 36, "both")
        currentSection = layoutSection
        
        -- Position Group (col1)
        local positionGroup = GUI:CreateSettingsGroup(self.child, 260)
        positionGroup:AddWidget(GUI:CreateHeader(self.child, "Position"), 40)
        local tsAnchor = positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "targetedSpellAnchor", FullUpdate), 55)
        tsAnchor.disableOn = HideTargetedSpellOptions
        local tsX = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset X", -100, 100, 1, db, "targetedSpellX", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsX.disableOn = HideTargetedSpellOptions
        local tsY = positionGroup:AddWidget(GUI:CreateSlider(self.child, "Offset Y", -100, 100, 1, db, "targetedSpellY", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsY.disableOn = HideTargetedSpellOptions
        local tsGrowth = positionGroup:AddWidget(GUI:CreateDropdown(self.child, "Growth Direction", growthOptions, db, "targetedSpellGrowth", FullUpdate), 55)
        tsGrowth.disableOn = HideTargetedSpellOptions
        AddToSection(positionGroup, nil, 1)
        
        -- Size Group (col2)
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 260)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, "Size"), 40)
        local tsIconSize = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Size", 12, 48, 1, db, "targetedSpellSize", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsIconSize.disableOn = HideTargetedSpellOptions
        local tsScale = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 4.0, 0.1, db, "targetedSpellScale", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsScale.disableOn = HideTargetedSpellOptions
        local tsSpacing = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Spacing", 0, 10, 1, db, "targetedSpellSpacing", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsSpacing.disableOn = HideTargetedSpellOptions
        local tsMaxIcons = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Max Icons", 1, 10, 1, db, "targetedSpellMaxIcons", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsMaxIcons.disableOn = HideTargetedSpellOptions
        local tsLevel = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "targetedSpellFrameLevel", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsLevel.disableOn = HideTargetedSpellOptions
        AddToSection(sizeGroup, nil, 2)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== APPEARANCE SECTION =====
        local appearanceSection = Add(GUI:CreateCollapsibleSection(self.child, "Appearance", true), 36, "both")
        currentSection = appearanceSection
        
        -- Border Group (col1)
        local borderGroup = GUI:CreateSettingsGroup(self.child, 260)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, "Border"), 40)
        local tsAlpha = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Alpha", 0.0, 1.0, 0.05, db, "targetedSpellAlpha", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsAlpha.disableOn = HideTargetedSpellOptions
        local hideSwipe = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Hide Cooldown Swipe", db, "targetedSpellHideSwipe", FullUpdate), 30)
        hideSwipe.disableOn = HideTargetedSpellOptions
        local tsShowBorder = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Border", db, "targetedSpellShowBorder", function()
            self:RefreshStates()
            FullUpdate()
        end), 30)
        tsShowBorder.disableOn = HideTargetedSpellOptions
        local tsBorderSize = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Border Size", 0, 8, 1, db, "targetedSpellBorderSize", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsBorderSize.disableOn = HideBorderOptions
        local tsColor = borderGroup:AddWidget(GUI:CreateColorPicker(self.child, "Border Color", db, "targetedSpellBorderColor", false, FullUpdate), 35)
        tsColor.disableOn = HideBorderOptions
        AddToSection(borderGroup, nil, 1)
        
        -- Duration Group (col2)
        local durationGroup = GUI:CreateSettingsGroup(self.child, 260)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, "Duration Text"), 40)
        local showDur = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Duration Text", db, "targetedSpellShowDuration", function()
            self:RefreshStates()
            FullUpdate()
        end), 30)
        showDur.disableOn = HideTargetedSpellOptions
        local tsDurFont = durationGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "targetedSpellDurationFont", FullUpdate), 55)
        tsDurFont.disableOn = HideTargetedDurationOptions
        local tsDurScale = durationGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 2.0, 0.05, db, "targetedSpellDurationScale", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsDurScale.disableOn = HideTargetedDurationOptions
        local tsDurOutline = durationGroup:AddWidget(GUI:CreateDropdown(self.child, "Outline", outlineOptions, db, "targetedSpellDurationOutline", FullUpdate), 55)
        tsDurOutline.disableOn = HideTargetedDurationOptions
        local tsDurX = durationGroup:AddWidget(GUI:CreateSlider(self.child, "X Offset", -20, 20, 1, db, "targetedSpellDurationX", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsDurX.disableOn = HideTargetedDurationOptions
        local tsDurY = durationGroup:AddWidget(GUI:CreateSlider(self.child, "Y Offset", -20, 20, 1, db, "targetedSpellDurationY", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsDurY.disableOn = HideTargetedDurationOptions
        local tsDurColor = durationGroup:AddWidget(GUI:CreateColorPicker(self.child, "Color", db, "targetedSpellDurationColor", false, FullUpdate), 35)
        tsDurColor.disableOn = HideTargetedDurationOptions
        AddToSection(durationGroup, nil, 2)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== IMPORTANT SPELLS SECTION =====
        local importantSection = Add(GUI:CreateCollapsibleSection(self.child, "Important Spells", true), 36, "both")
        currentSection = importantSection
        
        local function HideHighlightOptions(d) return not d.targetedSpellEnabled or not d.targetedSpellHighlightImportant end
        local highlightStyleOptions = { glow = "Glow", marchingAnts = "Marching Ants", solidBorder = "Solid Border", pulse = "Pulse", none = "None" }
        
        local highlightGroup = GUI:CreateSettingsGroup(self.child, 260)
        highlightGroup:AddWidget(GUI:CreateHeader(self.child, "Highlight Settings"), 40)
        local tsHighlightImportant = highlightGroup:AddWidget(GUI:CreateCheckbox(self.child, "Highlight Important Spells", db, "targetedSpellHighlightImportant", function()
            self:RefreshStates()
            FullUpdate()
        end), 30)
        tsHighlightImportant.disableOn = HideTargetedSpellOptions
        local tsHighlightStyle = highlightGroup:AddWidget(GUI:CreateDropdown(self.child, "Highlight Style", highlightStyleOptions, db, "targetedSpellHighlightStyle", FullUpdate), 55)
        tsHighlightStyle.disableOn = HideHighlightOptions
        local tsHighlightColor = highlightGroup:AddWidget(GUI:CreateColorPicker(self.child, "Highlight Color", db, "targetedSpellHighlightColor", false, FullUpdate), 35)
        tsHighlightColor.disableOn = HideHighlightOptions
        local tsHighlightSize = highlightGroup:AddWidget(GUI:CreateSlider(self.child, "Border Thickness", 1, 8, 1, db, "targetedSpellHighlightSize", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsHighlightSize.disableOn = HideHighlightOptions
        local tsHighlightInset = highlightGroup:AddWidget(GUI:CreateSlider(self.child, "Border Inset", -4, 8, 1, db, "targetedSpellHighlightInset", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsHighlightInset.disableOn = HideHighlightOptions
        AddToSection(highlightGroup, nil, 1)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== INTERRUPTED VISUAL SECTION =====
        local interruptedSection = Add(GUI:CreateCollapsibleSection(self.child, "Interrupted Visual", true), 36, "both")
        currentSection = interruptedSection
        
        local function HideInterruptedOptions(d) return not d.targetedSpellEnabled or not d.targetedSpellShowInterrupted end
        local function HideXOptions(d) return not d.targetedSpellEnabled or not d.targetedSpellShowInterrupted or not d.targetedSpellInterruptedShowX end
        
        local interruptGroup = GUI:CreateSettingsGroup(self.child, 260)
        interruptGroup:AddWidget(GUI:CreateHeader(self.child, "Interrupt Settings"), 40)
        local tsShowInterrupted = interruptGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Interrupted Visual", db, "targetedSpellShowInterrupted", function()
            self:RefreshStates()
            FullUpdate()
        end), 30)
        tsShowInterrupted.disableOn = HideTargetedSpellOptions
        local tsInterruptedDuration = interruptGroup:AddWidget(GUI:CreateSlider(self.child, "Duration", 0.1, 2.0, 0.1, db, "targetedSpellInterruptedDuration", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsInterruptedDuration.disableOn = HideInterruptedOptions
        local tsInterruptedTintColor = interruptGroup:AddWidget(GUI:CreateColorPicker(self.child, "Tint Color", db, "targetedSpellInterruptedTintColor", false, FullUpdate), 35)
        tsInterruptedTintColor.disableOn = HideInterruptedOptions
        local tsInterruptedTintAlpha = interruptGroup:AddWidget(GUI:CreateSlider(self.child, "Tint Opacity", 0, 1, 0.1, db, "targetedSpellInterruptedTintAlpha", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsInterruptedTintAlpha.disableOn = HideInterruptedOptions
        AddToSection(interruptGroup, nil, 1)
        
        local xMarkGroup = GUI:CreateSettingsGroup(self.child, 260)
        xMarkGroup:AddWidget(GUI:CreateHeader(self.child, "X Mark"), 40)
        local tsInterruptedShowX = xMarkGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show X Mark", db, "targetedSpellInterruptedShowX", function()
            self:RefreshStates()
            FullUpdate()
        end), 30)
        tsInterruptedShowX.disableOn = HideInterruptedOptions
        local tsInterruptedXColor = xMarkGroup:AddWidget(GUI:CreateColorPicker(self.child, "X Color", db, "targetedSpellInterruptedXColor", false, FullUpdate), 35)
        tsInterruptedXColor.disableOn = HideXOptions
        local tsInterruptedXSize = xMarkGroup:AddWidget(GUI:CreateSlider(self.child, "X Size", 8, 32, 1, db, "targetedSpellInterruptedXSize", FullUpdate, TargetedSpellLightweightUpdate, true), 55)
        tsInterruptedXSize.disableOn = HideXOptions
        xMarkGroup.hideOn = HideInterruptedOptions
        AddToSection(xMarkGroup, nil, 2)
        
        currentSection = nil
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_buffs", label = "Buffs"},
            {pageId = "auras_debuffs", label = "Debuffs"},
            {pageId = "general_integrations", label = "Integrations"},
            {pageId = "indicators_personal_targeted", label = "Personal Targeted Spells"},
        }), 30, "both")
    end)
    
    -- Indicators > Personal Targeted Spells (center of screen display for player)
    local pagePersonalTargeted = CreateSubTab("indicators", "indicators_personal_targeted", "Personal Targeted")
    BuildPage(pagePersonalTargeted, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"personalTargeted"}, "Personal Targeted"), 25, 2)
        
        AddSpace(10, "both")
        
        local currentSection = nil
        
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then currentSection:RegisterChild(widget) end
            return widget
        end
        
        local growthOptions = { UP = "Up", DOWN = "Down", LEFT = "Left", RIGHT = "Right", CENTER_H = "Center (Horizontal)", CENTER_V = "Center (Vertical)" }
        local outlineOptions = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline", SHADOW = "Shadow" }
        
        local function HidePersonalOptions(d) return not d.personalTargetedSpellEnabled end
        local function HidePersonalDurationOptions(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellShowDuration end
        local function HideBorderOptions(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellShowBorder end
        
        local function PersonalTargetedUpdate()
            if DF.UpdatePersonalTargetedSpellsPosition then DF:UpdatePersonalTargetedSpellsPosition() end
            if DF.UpdateTestPersonalTargetedSpells then DF:UpdateTestPersonalTargetedSpells() end
        end
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Settings"), 40)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, "Shows incoming targeted spells on YOU in the center of your screen.", 250), 30)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, "To reposition: Unlock frames (/df unlock) and drag the mover.", 250), 30)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Personal Targeted Spells", db, "personalTargetedSpellEnabled", function()
            self:RefreshStates()
            if DF.TogglePersonalTargetedSpells then DF:TogglePersonalTargetedSpells(db.personalTargetedSpellEnabled) end
        end), 30)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Important Spells Only", db, "personalTargetedSpellImportantOnly", PersonalTargetedUpdate), 30)
        Add(settingsGroup, nil, 1)
        
        -- ===== CONTENT TYPES GROUP (Column 2) =====
        local contentGroup = GUI:CreateSettingsGroup(self.child, 280)
        contentGroup:AddWidget(GUI:CreateHeader(self.child, "Content Types"), 40)
        contentGroup:AddWidget(GUI:CreateLabel(self.child, "Show in content types:", 250), 25)
        local ptsOpenWorld = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, "Open World", db, "personalTargetedSpellInOpenWorld", nil), 25)
        ptsOpenWorld.disableOn = HidePersonalOptions
        ptsOpenWorld.hideOn = function() return GUI.SelectedMode == "raid" end
        local ptsDungeons = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, "Dungeons", db, "personalTargetedSpellInDungeons", nil), 25)
        ptsDungeons.disableOn = HidePersonalOptions
        ptsDungeons.hideOn = function() return GUI.SelectedMode == "raid" end
        local ptsRaids = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, "Raids", db, "personalTargetedSpellInRaids", nil), 25)
        ptsRaids.disableOn = HidePersonalOptions
        ptsRaids.hideOn = function() return GUI.SelectedMode == "raid" end
        local ptsArena = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, "Arena", db, "personalTargetedSpellInArena", nil), 25)
        ptsArena.disableOn = HidePersonalOptions
        ptsArena.hideOn = function() return GUI.SelectedMode == "raid" end
        local ptsBattlegrounds = contentGroup:AddWidget(GUI:CreateCheckbox(self.child, "Battlegrounds", db, "personalTargetedSpellInBattlegrounds", nil), 25)
        ptsBattlegrounds.disableOn = HidePersonalOptions
        ptsBattlegrounds.hideOn = function() return GUI.SelectedMode == "raid" end
        contentGroup:AddWidget(GUI:CreateLabel(self.child, "Content type filters configured in Party tab.", 250), 25)
        contentGroup.hideOn = HidePersonalOptions
        Add(contentGroup, nil, 2)
        
        AddSpace(10, "both")
        
        -- ===== LAYOUT SECTION =====
        local layoutSection = Add(GUI:CreateCollapsibleSection(self.child, "Layout", true), 36, "both")
        currentSection = layoutSection
        
        -- Size Group (col1)
        local sizeGroup = GUI:CreateSettingsGroup(self.child, 260)
        sizeGroup:AddWidget(GUI:CreateHeader(self.child, "Size"), 40)
        local ptsSize = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Size", 20, 80, 1, db, "personalTargetedSpellSize", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsSize.disableOn = HidePersonalOptions
        local ptsScale = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 2.0, 0.05, db, "personalTargetedSpellScale", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsScale.disableOn = HidePersonalOptions
        local ptsSpacing = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Spacing", 0, 20, 1, db, "personalTargetedSpellSpacing", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsSpacing.disableOn = HidePersonalOptions
        local ptsMaxIcons = sizeGroup:AddWidget(GUI:CreateSlider(self.child, "Max Icons", 1, 10, 1, db, "personalTargetedSpellMaxIcons", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsMaxIcons.disableOn = HidePersonalOptions
        AddToSection(sizeGroup, nil, 1)
        
        -- Growth Group (col2)
        local growthGroup = GUI:CreateSettingsGroup(self.child, 260)
        growthGroup:AddWidget(GUI:CreateHeader(self.child, "Growth"), 40)
        local ptsGrowth = growthGroup:AddWidget(GUI:CreateDropdown(self.child, "Growth Direction", growthOptions, db, "personalTargetedSpellGrowth", PersonalTargetedUpdate), 55)
        ptsGrowth.disableOn = HidePersonalOptions
        AddToSection(growthGroup, nil, 2)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== APPEARANCE SECTION =====
        local appearanceSection = Add(GUI:CreateCollapsibleSection(self.child, "Appearance", true), 36, "both")
        currentSection = appearanceSection
        
        -- Border Group (col1)
        local borderGroup = GUI:CreateSettingsGroup(self.child, 260)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, "Border"), 40)
        local ptsAlpha = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Alpha", 0.0, 1.0, 0.05, db, "personalTargetedSpellAlpha", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsAlpha.disableOn = HidePersonalOptions
        local ptsSwipe = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Cooldown Swipe", db, "personalTargetedSpellShowSwipe", PersonalTargetedUpdate), 30)
        ptsSwipe.disableOn = HidePersonalOptions
        local ptsBorder = borderGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Border", db, "personalTargetedSpellShowBorder", function()
            self:RefreshStates()
            PersonalTargetedUpdate()
        end), 30)
        ptsBorder.disableOn = HidePersonalOptions
        local ptsBorderSize = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Border Size", 1, 5, 1, db, "personalTargetedSpellBorderSize", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsBorderSize.disableOn = HideBorderOptions
        local ptsBorderColor = borderGroup:AddWidget(GUI:CreateColorPicker(self.child, "Border Color", db, "personalTargetedSpellBorderColor", false, PersonalTargetedUpdate), 35)
        ptsBorderColor.disableOn = HideBorderOptions
        AddToSection(borderGroup, nil, 1)
        
        -- Duration Group (col2)
        local durationGroup = GUI:CreateSettingsGroup(self.child, 260)
        durationGroup:AddWidget(GUI:CreateHeader(self.child, "Duration Text"), 40)
        local ptsDuration = durationGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Duration Text", db, "personalTargetedSpellShowDuration", function()
            self:RefreshStates()
            PersonalTargetedUpdate()
        end), 30)
        ptsDuration.disableOn = HidePersonalOptions
        local ptsDurFont = durationGroup:AddWidget(GUI:CreateFontDropdown(self.child, "Font", db, "personalTargetedSpellDurationFont", PersonalTargetedUpdate), 55)
        ptsDurFont.disableOn = HidePersonalDurationOptions
        local ptsDurScale = durationGroup:AddWidget(GUI:CreateSlider(self.child, "Scale", 0.5, 2.0, 0.1, db, "personalTargetedSpellDurationScale", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsDurScale.disableOn = HidePersonalDurationOptions
        local ptsDurOutline = durationGroup:AddWidget(GUI:CreateDropdown(self.child, "Outline", outlineOptions, db, "personalTargetedSpellDurationOutline", PersonalTargetedUpdate), 55)
        ptsDurOutline.disableOn = HidePersonalDurationOptions
        local ptsDurX = durationGroup:AddWidget(GUI:CreateSlider(self.child, "X Offset", -20, 20, 1, db, "personalTargetedSpellDurationX", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsDurX.disableOn = HidePersonalDurationOptions
        local ptsDurY = durationGroup:AddWidget(GUI:CreateSlider(self.child, "Y Offset", -20, 20, 1, db, "personalTargetedSpellDurationY", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsDurY.disableOn = HidePersonalDurationOptions
        local ptsDurColor = durationGroup:AddWidget(GUI:CreateColorPicker(self.child, "Color", db, "personalTargetedSpellDurationColor", false, PersonalTargetedUpdate), 35)
        ptsDurColor.disableOn = HidePersonalDurationOptions
        AddToSection(durationGroup, nil, 2)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== IMPORTANT SPELLS SECTION =====
        local highlightSection = Add(GUI:CreateCollapsibleSection(self.child, "Important Spells", true), 36, "both")
        currentSection = highlightSection
        
        local personalHighlightStyleOptions = { glow = "Glow", marchingAnts = "Marching Ants", solidBorder = "Solid Border", pulse = "Pulse", none = "None" }
        
        local highlightGroup = GUI:CreateSettingsGroup(self.child, 260)
        highlightGroup:AddWidget(GUI:CreateHeader(self.child, "Highlight Settings"), 40)
        local ptsHighlight = highlightGroup:AddWidget(GUI:CreateCheckbox(self.child, "Highlight Important Spells", db, "personalTargetedSpellHighlightImportant", PersonalTargetedUpdate), 30)
        ptsHighlight.disableOn = HidePersonalOptions
        local ptsHighlightStyle = highlightGroup:AddWidget(GUI:CreateDropdown(self.child, "Highlight Style", personalHighlightStyleOptions, db, "personalTargetedSpellHighlightStyle", PersonalTargetedUpdate), 55)
        ptsHighlightStyle.disableOn = function(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellHighlightImportant end
        local ptsHighlightColor = highlightGroup:AddWidget(GUI:CreateColorPicker(self.child, "Highlight Color", db, "personalTargetedSpellHighlightColor", false, PersonalTargetedUpdate), 35)
        ptsHighlightColor.disableOn = function(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellHighlightImportant end
        local ptsHighlightSize = highlightGroup:AddWidget(GUI:CreateSlider(self.child, "Border Thickness", 1, 6, 1, db, "personalTargetedSpellHighlightSize", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsHighlightSize.disableOn = function(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellHighlightImportant end
        local ptsHighlightInset = highlightGroup:AddWidget(GUI:CreateSlider(self.child, "Border Inset", -4, 8, 1, db, "personalTargetedSpellHighlightInset", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsHighlightInset.disableOn = function(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellHighlightImportant end
        AddToSection(highlightGroup, nil, 1)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ===== INTERRUPTED VISUAL SECTION =====
        local interruptSection = Add(GUI:CreateCollapsibleSection(self.child, "Interrupted Visual", true), 36, "both")
        currentSection = interruptSection
        
        local function HideInterruptOptions(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellShowInterrupted end
        local function HideInterruptXOptions(d) return not d.personalTargetedSpellEnabled or not d.personalTargetedSpellShowInterrupted or not d.personalTargetedSpellInterruptedShowX end
        
        local interruptGroup = GUI:CreateSettingsGroup(self.child, 260)
        interruptGroup:AddWidget(GUI:CreateHeader(self.child, "Interrupt Settings"), 40)
        local ptsInterrupted = interruptGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Interrupted Visual", db, "personalTargetedSpellShowInterrupted", function()
            self:RefreshStates()
            PersonalTargetedUpdate()
        end), 30)
        ptsInterrupted.disableOn = HidePersonalOptions
        local ptsInterruptDur = interruptGroup:AddWidget(GUI:CreateSlider(self.child, "Duration", 0.1, 2.0, 0.1, db, "personalTargetedSpellInterruptedDuration", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsInterruptDur.disableOn = HideInterruptOptions
        local ptsInterruptTint = interruptGroup:AddWidget(GUI:CreateColorPicker(self.child, "Tint Color", db, "personalTargetedSpellInterruptedTintColor", false, PersonalTargetedUpdate), 35)
        ptsInterruptTint.disableOn = HideInterruptOptions
        local ptsInterruptTintAlpha = interruptGroup:AddWidget(GUI:CreateSlider(self.child, "Tint Opacity", 0, 1, 0.1, db, "personalTargetedSpellInterruptedTintAlpha", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsInterruptTintAlpha.disableOn = HideInterruptOptions
        AddToSection(interruptGroup, nil, 1)
        
        local xMarkGroup = GUI:CreateSettingsGroup(self.child, 260)
        xMarkGroup:AddWidget(GUI:CreateHeader(self.child, "X Mark"), 40)
        local ptsShowX = xMarkGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show X Mark", db, "personalTargetedSpellInterruptedShowX", function()
            self:RefreshStates()
            PersonalTargetedUpdate()
        end), 30)
        ptsShowX.disableOn = HideInterruptOptions
        local ptsXColor = xMarkGroup:AddWidget(GUI:CreateColorPicker(self.child, "X Color", db, "personalTargetedSpellInterruptedXColor", false, PersonalTargetedUpdate), 35)
        ptsXColor.disableOn = HideInterruptXOptions
        local ptsXSize = xMarkGroup:AddWidget(GUI:CreateSlider(self.child, "X Size", 8, 40, 1, db, "personalTargetedSpellInterruptedXSize", PersonalTargetedUpdate, PersonalTargetedUpdate, true), 55)
        ptsXSize.disableOn = HideInterruptXOptions
        xMarkGroup.hideOn = HideInterruptOptions
        AddToSection(xMarkGroup, nil, 2)
        
        currentSection = nil
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "indicators_targetedspells", label = "Targeted Spells (on frames)"},
        }), 30, "both")
    end)
    
    -- Indicators > Icons (All icons with collapsible sections)
    local pageIcons = CreateSubTab("indicators", "indicators_icons", "Icons")
    BuildPage(pageIcons, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"roleIcon", "leaderIcon", "raidTargetIcon", "readyCheckIcon", "summonIcon", "resurrectionIcon", "phasedIcon", "afkIcon", "vehicleIcon", "raidRoleIcon", "statusIconFont", "statusIconFontSize", "statusIconFontOutline"}, "Icons"), 25, 2)
        
        local anchorOptions = {
            CENTER = "Center",
            TOP = "Top",
            BOTTOM = "Bottom",
            LEFT = "Left",
            RIGHT = "Right",
            TOPLEFT = "Top Left",
            TOPRIGHT = "Top Right",
            BOTTOMLEFT = "Bottom Left",
            BOTTOMRIGHT = "Bottom Right",
        }
        
        local roleStyleOptions = {
            BLIZZARD = "Blizzard",
            CUSTOM = "Custom",
        }
        
        local outlineOptions = {
            [""] = "None",
            ["OUTLINE"] = "Outline",
            ["THICKOUTLINE"] = "Thick Outline",
            ["SHADOW"] = "Shadow",
        }
        
        -- ============================================
        -- STATUS ICON TEXT SETTINGS (Collapsible, at top)
        -- ============================================
        local textSection = Add(GUI:CreateCollapsibleSection(self.child, "Status Icon Text Settings", false, 250), 28, 1)
        
        local textLabel = Add(GUI:CreateLabel(self.child, "Font settings for icons displayed as text (Summon, Res, AFK, etc.)", 240), 30, 1)
        textSection:RegisterChild(textLabel)
        
        local textFont = Add(GUI:CreateFontDropdown(self.child, "Font", db, "statusIconFont", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 55, 1)
        textSection:RegisterChild(textFont)
        
        local textSize = Add(GUI:CreateSlider(self.child, "Font Size", 8, 24, 1, db, "statusIconFontSize", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 55, 1)
        textSection:RegisterChild(textSize)
        
        local textOutline = Add(GUI:CreateDropdown(self.child, "Outline", outlineOptions, db, "statusIconFontOutline", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 55, 1)
        textSection:RegisterChild(textOutline)
        
        local shadowNote = Add(GUI:CreateLabel(self.child, "Shadow settings are controlled in General > Global Fonts.", 240), 30, 1)
        textSection:RegisterChild(shadowNote)
        shadowNote.hideOn = function(d) return d.statusIconFontOutline ~= "SHADOW" end
        
        -- Text Colors header
        local colorsLabel = Add(GUI:CreateLabel(self.child, "Text Colors:", 240), 25, 1)
        textSection:RegisterChild(colorsLabel)
        
        local summonColor = Add(GUI:CreateColorPicker(self.child, "Summon", db, "summonIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(summonColor)
        
        local resColor = Add(GUI:CreateColorPicker(self.child, "Resurrection", db, "resurrectionIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(resColor)
        
        local afkColor = Add(GUI:CreateColorPicker(self.child, "AFK", db, "afkIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(afkColor)
        
        local phasedColor = Add(GUI:CreateColorPicker(self.child, "Phased", db, "phasedIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(phasedColor)
        
        local vehicleColor = Add(GUI:CreateColorPicker(self.child, "Vehicle", db, "vehicleIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(vehicleColor)
        
        local raidRoleColor = Add(GUI:CreateColorPicker(self.child, "Raid Role (MT/MA)", db, "raidRoleIconTextColor", false, nil, function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end, true), 30, 1)
        textSection:RegisterChild(raidRoleColor)
        
        -- ============================================
        -- ROLE ICON (Collapsible)
        -- ============================================
        local roleSection = Add(GUI:CreateCollapsibleSection(self.child, "Role Icon", false, 250), 28, 1)
        
        local roleOnlyInCombat = Add(GUI:CreateCheckbox(self.child, "Only Apply Settings in Combat", db, "roleIconOnlyInCombat", function() DF:UpdateAllRoleIcons() end), 30, 1)
        roleSection:RegisterChild(roleOnlyInCombat)
        
        local roleStyle = Add(GUI:CreateDropdown(self.child, "Icon Style", roleStyleOptions, db, "roleIconStyle", nil), 55, 1)
        roleSection:RegisterChild(roleStyle)
        
        local roleShowTank = Add(GUI:CreateCheckbox(self.child, "Show Tank", db, "roleIconShowTank", nil), 30, 1)
        roleSection:RegisterChild(roleShowTank)
        
        local roleShowHealer = Add(GUI:CreateCheckbox(self.child, "Show Healer", db, "roleIconShowHealer", nil), 30, 1)
        roleSection:RegisterChild(roleShowHealer)
        
        local roleShowDPS = Add(GUI:CreateCheckbox(self.child, "Show DPS", db, "roleIconShowDPS", nil), 30, 1)
        roleSection:RegisterChild(roleShowDPS)
        
        local roleScale = Add(GUI:CreateSlider(self.child, "Scale", 0.5, 2.5, 0.1, db, "roleIconScale", nil, function() DF:LightweightUpdateIconPosition("role") end, true), 55, 1)
        roleSection:RegisterChild(roleScale)
        
        local roleAlpha = Add(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "roleIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("role") end, true), 55, 1)
        roleSection:RegisterChild(roleAlpha)
        
        local roleHide = Add(GUI:CreateCheckbox(self.child, "Hide in Combat", db, "roleIconHideInCombat", function() DF:UpdateAllRoleIcons() end), 30, 1)
        roleSection:RegisterChild(roleHide)
        
        local roleAnchor = Add(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "roleIconAnchor", function() DF:LightweightUpdateIconPosition("role") end), 55, 1)
        roleSection:RegisterChild(roleAnchor)
        
        local roleX = Add(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "roleIconX", nil, function() DF:LightweightUpdateIconPosition("role") end, true), 55, 1)
        roleSection:RegisterChild(roleX)
        
        local roleY = Add(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "roleIconY", nil, function() DF:LightweightUpdateIconPosition("role") end, true), 55, 1)
        roleSection:RegisterChild(roleY)
        
        local roleLevel = Add(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "roleIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("role") end, true), 55, 1)
        roleSection:RegisterChild(roleLevel)
        
        -- ============================================
        -- LEADER ICON (Collapsible)
        -- ============================================
        local leaderSection = Add(GUI:CreateCollapsibleSection(self.child, "Leader Icon", false, 250), 28, 1)
        
        local leaderEnabled = Add(GUI:CreateCheckbox(self.child, "Enable Leader Icon", db, "leaderIconEnabled", function() DF:UpdateAllFrames() end), 30, 1)
        leaderSection:RegisterChild(leaderEnabled)
        
        local leaderScale = Add(GUI:CreateSlider(self.child, "Scale", 0.5, 2.5, 0.1, db, "leaderIconScale", nil, function() DF:LightweightUpdateIconPosition("leader") end, true), 55, 1)
        leaderSection:RegisterChild(leaderScale)
        
        local leaderAlpha = Add(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "leaderIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("leader") end, true), 55, 1)
        leaderSection:RegisterChild(leaderAlpha)
        
        local leaderHide = Add(GUI:CreateCheckbox(self.child, "Hide in Combat", db, "leaderIconHideInCombat", function() DF:UpdateAllFrames() end), 30, 1)
        leaderSection:RegisterChild(leaderHide)
        
        local leaderAnchor = Add(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "leaderIconAnchor", function() DF:LightweightUpdateIconPosition("leader") end), 55, 1)
        leaderSection:RegisterChild(leaderAnchor)
        
        local leaderX = Add(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "leaderIconX", nil, function() DF:LightweightUpdateIconPosition("leader") end, true), 55, 1)
        leaderSection:RegisterChild(leaderX)
        
        local leaderY = Add(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "leaderIconY", nil, function() DF:LightweightUpdateIconPosition("leader") end, true), 55, 1)
        leaderSection:RegisterChild(leaderY)
        
        local leaderLevel = Add(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "leaderIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("leader") end, true), 55, 1)
        leaderSection:RegisterChild(leaderLevel)
        
        -- ============================================
        -- RAID TARGET ICON (Collapsible)
        -- ============================================
        local raidTargetSection = Add(GUI:CreateCollapsibleSection(self.child, "Raid Target Icon", false, 250), 28, 1)
        
        local rtEnabled = Add(GUI:CreateCheckbox(self.child, "Enable Raid Target Icon", db, "raidTargetIconEnabled", function() DF:UpdateAllFrames() end), 30, 1)
        raidTargetSection:RegisterChild(rtEnabled)
        
        local rtScale = Add(GUI:CreateSlider(self.child, "Scale", 0.5, 2.5, 0.1, db, "raidTargetIconScale", nil, function() DF:LightweightUpdateIconPosition("raidTarget") end, true), 55, 1)
        raidTargetSection:RegisterChild(rtScale)
        
        local rtAlpha = Add(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "raidTargetIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("raidTarget") end, true), 55, 1)
        raidTargetSection:RegisterChild(rtAlpha)
        
        local rtHide = Add(GUI:CreateCheckbox(self.child, "Hide in Combat", db, "raidTargetIconHideInCombat", function() DF:UpdateAllFrames() end), 30, 1)
        raidTargetSection:RegisterChild(rtHide)
        
        local rtAnchor = Add(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "raidTargetIconAnchor", function() DF:LightweightUpdateIconPosition("raidTarget") end), 55, 1)
        raidTargetSection:RegisterChild(rtAnchor)
        
        local rtX = Add(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "raidTargetIconX", nil, function() DF:LightweightUpdateIconPosition("raidTarget") end, true), 55, 1)
        raidTargetSection:RegisterChild(rtX)
        
        local rtY = Add(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "raidTargetIconY", nil, function() DF:LightweightUpdateIconPosition("raidTarget") end, true), 55, 1)
        raidTargetSection:RegisterChild(rtY)
        
        local rtLevel = Add(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "raidTargetIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("raidTarget") end, true), 55, 1)
        raidTargetSection:RegisterChild(rtLevel)
        
        -- ============================================
        -- READY CHECK ICON (Collapsible)
        -- ============================================
        local readySection = Add(GUI:CreateCollapsibleSection(self.child, "Ready Check Icon", false, 250), 28, 1)
        
        local rcEnabled = Add(GUI:CreateCheckbox(self.child, "Enable Ready Check Icon", db, "readyCheckIconEnabled", function() DF:UpdateAllFrames() end), 30, 1)
        readySection:RegisterChild(rcEnabled)
        
        local rcScale = Add(GUI:CreateSlider(self.child, "Scale", 0.5, 2.5, 0.1, db, "readyCheckIconScale", nil, function() DF:LightweightUpdateIconPosition("readyCheck") end, true), 55, 1)
        readySection:RegisterChild(rcScale)
        
        local rcAlpha = Add(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "readyCheckIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("readyCheck") end, true), 55, 1)
        readySection:RegisterChild(rcAlpha)
        
        local rcHide = Add(GUI:CreateCheckbox(self.child, "Hide in Combat", db, "readyCheckIconHideInCombat", function() DF:UpdateAllFrames() end), 30, 1)
        readySection:RegisterChild(rcHide)
        
        local rcAnchor = Add(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "readyCheckIconAnchor", function() DF:LightweightUpdateIconPosition("readyCheck") end), 55, 1)
        readySection:RegisterChild(rcAnchor)
        
        local rcX = Add(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "readyCheckIconX", nil, function() DF:LightweightUpdateIconPosition("readyCheck") end, true), 55, 1)
        readySection:RegisterChild(rcX)
        
        local rcY = Add(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "readyCheckIconY", nil, function() DF:LightweightUpdateIconPosition("readyCheck") end, true), 55, 1)
        readySection:RegisterChild(rcY)
        
        local rcPersist = Add(GUI:CreateSlider(self.child, "Persist (sec)", 0, 15, 1, db, "readyCheckIconPersist"), 55, 1)
        readySection:RegisterChild(rcPersist)
        
        local rcLevel = Add(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "readyCheckIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("readyCheck") end, true), 55, 1)
        readySection:RegisterChild(rcLevel)
        
        -- ============================================
        -- SUMMON ICON (Collapsible)
        -- ============================================
        local summonSection = Add(GUI:CreateCollapsibleSection(self.child, "Summon Icon", false, 250), 28, 1)
        
        local sumEnabled = Add(GUI:CreateCheckbox(self.child, "Enable Summon Icon", db, "summonIconEnabled", function() DF:UpdateAllFrames() end), 30, 1)
        summonSection:RegisterChild(sumEnabled)
        
        local sumShowText = Add(GUI:CreateCheckbox(self.child, "Show as Text", db, "summonIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30, 1)
        summonSection:RegisterChild(sumShowText)
        
        local sumTextPending = Add(GUI:CreateEditBox(self.child, "Pending Text", db, "summonIconTextPending", function() DF:UpdateAllFramesStatusIcons() end, 120), 55, 1)
        summonSection:RegisterChild(sumTextPending)
        
        local sumTextAccepted = Add(GUI:CreateEditBox(self.child, "Accepted Text", db, "summonIconTextAccepted", function() DF:UpdateAllFramesStatusIcons() end, 120), 55, 1)
        summonSection:RegisterChild(sumTextAccepted)
        
        local sumTextDeclined = Add(GUI:CreateEditBox(self.child, "Declined Text", db, "summonIconTextDeclined", function() DF:UpdateAllFramesStatusIcons() end, 120), 55, 1)
        summonSection:RegisterChild(sumTextDeclined)
        
        local sumScale = Add(GUI:CreateSlider(self.child, "Scale", 0.5, 2.5, 0.1, db, "summonIconScale", nil, function() DF:LightweightUpdateIconPosition("summon") end, true), 55, 1)
        summonSection:RegisterChild(sumScale)
        
        local sumAlpha = Add(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "summonIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("summon") end, true), 55, 1)
        summonSection:RegisterChild(sumAlpha)
        
        local sumHide = Add(GUI:CreateCheckbox(self.child, "Hide in Combat", db, "summonIconHideInCombat", function() DF:UpdateAllFrames() end), 30, 1)
        summonSection:RegisterChild(sumHide)
        
        local sumAnchor = Add(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "summonIconAnchor", function() DF:LightweightUpdateIconPosition("summon") end), 55, 1)
        summonSection:RegisterChild(sumAnchor)
        
        local sumX = Add(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "summonIconX", nil, function() DF:LightweightUpdateIconPosition("summon") end, true), 55, 1)
        summonSection:RegisterChild(sumX)
        
        local sumY = Add(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "summonIconY", nil, function() DF:LightweightUpdateIconPosition("summon") end, true), 55, 1)
        summonSection:RegisterChild(sumY)
        
        local sumLevel = Add(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "summonIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("summon") end, true), 55, 1)
        summonSection:RegisterChild(sumLevel)
        
        -- ============================================
        -- RESURRECTION ICON (Collapsible)
        -- ============================================
        local resSection = Add(GUI:CreateCollapsibleSection(self.child, "Resurrection Icon", false, 250), 28, 1)
        
        local resEnabled = Add(GUI:CreateCheckbox(self.child, "Enable Resurrection Icon", db, "resurrectionIconEnabled", function() DF:UpdateAllFrames() end), 30, 1)
        resSection:RegisterChild(resEnabled)
        
        local resShowText = Add(GUI:CreateCheckbox(self.child, "Show as Text", db, "resurrectionIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30, 1)
        resSection:RegisterChild(resShowText)
        
        local resTextCasting = Add(GUI:CreateEditBox(self.child, "Casting Text", db, "resurrectionIconTextCasting", function() DF:UpdateAllFramesStatusIcons() end, 120), 55, 1)
        resSection:RegisterChild(resTextCasting)
        
        local resTextPending = Add(GUI:CreateEditBox(self.child, "Pending Text", db, "resurrectionIconTextPending", function() DF:UpdateAllFramesStatusIcons() end, 120), 55, 1)
        resSection:RegisterChild(resTextPending)
        
        local resScale = Add(GUI:CreateSlider(self.child, "Scale", 0.5, 2.5, 0.1, db, "resurrectionIconScale", nil, function() DF:LightweightUpdateIconPosition("resurrection") end, true), 55, 1)
        resSection:RegisterChild(resScale)
        
        local resAlpha = Add(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "resurrectionIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("resurrection") end, true), 55, 1)
        resSection:RegisterChild(resAlpha)
        
        local resAnchor = Add(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "resurrectionIconAnchor", function() DF:LightweightUpdateIconPosition("resurrection") end), 55, 1)
        resSection:RegisterChild(resAnchor)
        
        local resX = Add(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "resurrectionIconX", nil, function() DF:LightweightUpdateIconPosition("resurrection") end, true), 55, 1)
        resSection:RegisterChild(resX)
        
        local resY = Add(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "resurrectionIconY", nil, function() DF:LightweightUpdateIconPosition("resurrection") end, true), 55, 1)
        resSection:RegisterChild(resY)
        
        local resLevel = Add(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "resurrectionIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("resurrection") end, true), 55, 1)
        resSection:RegisterChild(resLevel)
        
        -- ============================================
        -- PHASED ICON (Collapsible)
        -- ============================================
        local phasedSection = Add(GUI:CreateCollapsibleSection(self.child, "Phased Icon", false, 250), 28, 1)
        
        local phEnabled = Add(GUI:CreateCheckbox(self.child, "Enable Phased Icon", db, "phasedIconEnabled", function() DF:UpdateAllFrames() end), 30, 1)
        phasedSection:RegisterChild(phEnabled)
        
        local phShowText = Add(GUI:CreateCheckbox(self.child, "Show as Text", db, "phasedIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30, 1)
        phasedSection:RegisterChild(phShowText)
        
        local phText = Add(GUI:CreateEditBox(self.child, "Status Text", db, "phasedIconText", function() DF:UpdateAllFramesStatusIcons() end, 120), 55, 1)
        phasedSection:RegisterChild(phText)
        
        local phLFG = Add(GUI:CreateCheckbox(self.child, "Show LFG Eye for Cross-Instance", db, "phasedIconShowLFGEye", function() DF:UpdateAllFrames() end), 30, 1)
        phasedSection:RegisterChild(phLFG)
        
        local phScale = Add(GUI:CreateSlider(self.child, "Scale", 0.5, 2.5, 0.1, db, "phasedIconScale", nil, function() DF:LightweightUpdateIconPosition("phased") end, true), 55, 1)
        phasedSection:RegisterChild(phScale)
        
        local phAlpha = Add(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "phasedIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("phased") end, true), 55, 1)
        phasedSection:RegisterChild(phAlpha)
        
        local phHide = Add(GUI:CreateCheckbox(self.child, "Hide in Combat", db, "phasedIconHideInCombat", function() DF:UpdateAllFrames() end), 30, 1)
        phasedSection:RegisterChild(phHide)
        
        local phAnchor = Add(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "phasedIconAnchor", function() DF:LightweightUpdateIconPosition("phased") end), 55, 1)
        phasedSection:RegisterChild(phAnchor)
        
        local phX = Add(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "phasedIconX", nil, function() DF:LightweightUpdateIconPosition("phased") end, true), 55, 1)
        phasedSection:RegisterChild(phX)
        
        local phY = Add(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "phasedIconY", nil, function() DF:LightweightUpdateIconPosition("phased") end, true), 55, 1)
        phasedSection:RegisterChild(phY)
        
        local phLevel = Add(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "phasedIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("phased") end, true), 55, 1)
        phasedSection:RegisterChild(phLevel)
        
        -- ============================================
        -- AFK ICON (Collapsible)
        -- ============================================
        local afkSection = Add(GUI:CreateCollapsibleSection(self.child, "AFK Icon", false, 250), 28, 1)
        
        local afkEnabled = Add(GUI:CreateCheckbox(self.child, "Enable AFK Icon", db, "afkIconEnabled", function() DF:UpdateAllFrames() end), 30, 1)
        afkSection:RegisterChild(afkEnabled)
        
        local afkShowText = Add(GUI:CreateCheckbox(self.child, "Show as Text", db, "afkIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30, 1)
        afkSection:RegisterChild(afkShowText)
        
        local afkText = Add(GUI:CreateEditBox(self.child, "Status Text", db, "afkIconText", function() DF:UpdateAllFramesStatusIcons() end, 120), 55, 1)
        afkSection:RegisterChild(afkText)
        
        local afkTimer = Add(GUI:CreateCheckbox(self.child, "Show Timer", db, "afkIconShowTimer", function() DF:UpdateAllFramesStatusIcons() end), 30, 1)
        afkSection:RegisterChild(afkTimer)
        
        local afkScale = Add(GUI:CreateSlider(self.child, "Scale", 0.5, 2.5, 0.1, db, "afkIconScale", nil, function() DF:LightweightUpdateIconPosition("afk") end, true), 55, 1)
        afkSection:RegisterChild(afkScale)
        
        local afkAlpha = Add(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "afkIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("afk") end, true), 55, 1)
        afkSection:RegisterChild(afkAlpha)
        
        local afkHide = Add(GUI:CreateCheckbox(self.child, "Hide in Combat", db, "afkIconHideInCombat", function() DF:UpdateAllFrames() end), 30, 1)
        afkSection:RegisterChild(afkHide)
        
        local afkAnchor = Add(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "afkIconAnchor", function() DF:LightweightUpdateIconPosition("afk") end), 55, 1)
        afkSection:RegisterChild(afkAnchor)
        
        local afkX = Add(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "afkIconX", nil, function() DF:LightweightUpdateIconPosition("afk") end, true), 55, 1)
        afkSection:RegisterChild(afkX)
        
        local afkY = Add(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "afkIconY", nil, function() DF:LightweightUpdateIconPosition("afk") end, true), 55, 1)
        afkSection:RegisterChild(afkY)
        
        local afkLevel = Add(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "afkIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("afk") end, true), 55, 1)
        afkSection:RegisterChild(afkLevel)
        
        -- ============================================
        -- VEHICLE ICON (Collapsible)
        -- ============================================
        local vehSection = Add(GUI:CreateCollapsibleSection(self.child, "Vehicle Icon", false, 250), 28, 1)
        
        local vehEnabled = Add(GUI:CreateCheckbox(self.child, "Enable Vehicle Icon", db, "vehicleIconEnabled", function() DF:UpdateAllFrames() end), 30, 1)
        vehSection:RegisterChild(vehEnabled)
        
        local vehShowText = Add(GUI:CreateCheckbox(self.child, "Show as Text", db, "vehicleIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30, 1)
        vehSection:RegisterChild(vehShowText)
        
        local vehText = Add(GUI:CreateEditBox(self.child, "Status Text", db, "vehicleIconText", function() DF:UpdateAllFramesStatusIcons() end, 120), 55, 1)
        vehSection:RegisterChild(vehText)
        
        local vehScale = Add(GUI:CreateSlider(self.child, "Scale", 0.5, 2.5, 0.1, db, "vehicleIconScale", nil, function() DF:LightweightUpdateIconPosition("vehicle") end, true), 55, 1)
        vehSection:RegisterChild(vehScale)
        
        local vehAlpha = Add(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "vehicleIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("vehicle") end, true), 55, 1)
        vehSection:RegisterChild(vehAlpha)
        
        local vehHide = Add(GUI:CreateCheckbox(self.child, "Hide in Combat", db, "vehicleIconHideInCombat", function() DF:UpdateAllFrames() end), 30, 1)
        vehSection:RegisterChild(vehHide)
        
        local vehAnchor = Add(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "vehicleIconAnchor", function() DF:LightweightUpdateIconPosition("vehicle") end), 55, 1)
        vehSection:RegisterChild(vehAnchor)
        
        local vehX = Add(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "vehicleIconX", nil, function() DF:LightweightUpdateIconPosition("vehicle") end, true), 55, 1)
        vehSection:RegisterChild(vehX)
        
        local vehY = Add(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "vehicleIconY", nil, function() DF:LightweightUpdateIconPosition("vehicle") end, true), 55, 1)
        vehSection:RegisterChild(vehY)
        
        local vehLevel = Add(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "vehicleIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("vehicle") end, true), 55, 1)
        vehSection:RegisterChild(vehLevel)
        
        -- ============================================
        -- RAID ROLE ICON (Collapsible)
        -- ============================================
        local rrSection = Add(GUI:CreateCollapsibleSection(self.child, "Raid Role Icon (MT/MA)", false, 250), 28, 1)
        
        local rrEnabled = Add(GUI:CreateCheckbox(self.child, "Enable Raid Role Icon", db, "raidRoleIconEnabled", function() DF:UpdateAllFrames() end), 30, 1)
        rrSection:RegisterChild(rrEnabled)
        
        local rrShowTank = Add(GUI:CreateCheckbox(self.child, "Show Main Tank", db, "raidRoleIconShowTank", function() DF:UpdateAllFrames() end), 30, 1)
        rrSection:RegisterChild(rrShowTank)
        
        local rrShowAssist = Add(GUI:CreateCheckbox(self.child, "Show Main Assist", db, "raidRoleIconShowAssist", function() DF:UpdateAllFrames() end), 30, 1)
        rrSection:RegisterChild(rrShowAssist)
        
        local rrShowText = Add(GUI:CreateCheckbox(self.child, "Show as Text", db, "raidRoleIconShowText", function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end), 30, 1)
        rrSection:RegisterChild(rrShowText)
        
        local rrTextTank = Add(GUI:CreateEditBox(self.child, "Tank Text", db, "raidRoleIconTextTank", function() DF:UpdateAllFramesStatusIcons() end, 120), 55, 1)
        rrSection:RegisterChild(rrTextTank)
        
        local rrTextAssist = Add(GUI:CreateEditBox(self.child, "Assist Text", db, "raidRoleIconTextAssist", function() DF:UpdateAllFramesStatusIcons() end, 120), 55, 1)
        rrSection:RegisterChild(rrTextAssist)
        
        local rrScale = Add(GUI:CreateSlider(self.child, "Scale", 0.5, 2.5, 0.1, db, "raidRoleIconScale", nil, function() DF:LightweightUpdateIconPosition("raidRole") end, true), 55, 1)
        rrSection:RegisterChild(rrScale)
        
        local rrAlpha = Add(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "raidRoleIconAlpha", nil, function() DF:LightweightUpdateIconAlpha("raidRole") end, true), 55, 1)
        rrSection:RegisterChild(rrAlpha)
        
        local rrHide = Add(GUI:CreateCheckbox(self.child, "Hide in Combat", db, "raidRoleIconHideInCombat", function() DF:UpdateAllFrames() end), 30, 1)
        rrSection:RegisterChild(rrHide)
        
        local rrAnchor = Add(GUI:CreateDropdown(self.child, "Anchor", anchorOptions, db, "raidRoleIconAnchor", function() DF:LightweightUpdateIconPosition("raidRole") end), 55, 1)
        rrSection:RegisterChild(rrAnchor)
        
        local rrX = Add(GUI:CreateSlider(self.child, "Offset X", -50, 50, 1, db, "raidRoleIconX", nil, function() DF:LightweightUpdateIconPosition("raidRole") end, true), 55, 1)
        rrSection:RegisterChild(rrX)
        
        local rrY = Add(GUI:CreateSlider(self.child, "Offset Y", -50, 50, 1, db, "raidRoleIconY", nil, function() DF:LightweightUpdateIconPosition("raidRole") end, true), 55, 1)
        rrSection:RegisterChild(rrY)
        
        local rrLevel = Add(GUI:CreateSlider(self.child, "Frame Level", 0, 100, 1, db, "raidRoleIconFrameLevel", nil, function() DF:LightweightUpdateFrameLevel("raidRole") end, true), 55, 1)
        rrSection:RegisterChild(rrLevel)
    end)
    
    -- Indicators > Highlights
    local pageHighlights = CreateSubTab("indicators", "indicators_highlights", "Highlights")
    BuildPage(pageHighlights, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"selectionHighlight", "hoverHighlight", "aggroHighlight", "aggro"}, "Highlights"), 25, 2)
        
        AddSpace(10, "both")
        
        local currentSection = nil
        
        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then currentSection:RegisterChild(widget) end
            return widget
        end
        
        local highlightModes = {
            ["NONE"] = "Hidden",
            ["SOLID"] = "Solid Border",
            ["ANIMATED"] = "Animated Border",
            ["DASHED"] = "Dashed Border",
            ["GLOW"] = "Glow",
            ["CORNERS"] = "Corners Only",
        }
        
        -- ========================================
        -- SELECTION HIGHLIGHT SECTION
        -- ========================================
        local selectionSection = Add(GUI:CreateCollapsibleSection(self.child, "Selection Highlight", true), 36, "both")
        currentSection = selectionSection
        
        local function HideSelectionOptions(d) return d.selectionHighlightMode == "NONE" end
        
        local selGroup = GUI:CreateSettingsGroup(self.child, 260)
        selGroup:AddWidget(GUI:CreateHeader(self.child, "Selection Settings"), 40)
        selGroup:AddWidget(GUI:CreateDropdown(self.child, "Mode", highlightModes, db, "selectionHighlightMode", function()
            self:RefreshStates()
        end), 55)
        local selThick = selGroup:AddWidget(GUI:CreateSlider(self.child, "Thickness", 1, 10, 1, db, "selectionHighlightThickness", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
        selThick.hideOn = HideSelectionOptions
        local selInset = selGroup:AddWidget(GUI:CreateSlider(self.child, "Inset", -10, 10, 1, db, "selectionHighlightInset", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
        selInset.hideOn = HideSelectionOptions
        local selAlpha = selGroup:AddWidget(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "selectionHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
        selAlpha.hideOn = HideSelectionOptions
        local selCol = selGroup:AddWidget(GUI:CreateColorPicker(self.child, "Color", db, "selectionHighlightColor", false, nil, function() DF:LightweightUpdateSelectionHighlightColor() end, true), 35)
        selCol.hideOn = HideSelectionOptions
        AddToSection(selGroup, nil, 1)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ========================================
        -- HOVER HIGHLIGHT SECTION
        -- ========================================
        local hoverSection = Add(GUI:CreateCollapsibleSection(self.child, "Hover Highlight", true), 36, "both")
        currentSection = hoverSection
        
        local function HideHoverOptions(d) return d.hoverHighlightMode == "NONE" end
        
        local hoverGroup = GUI:CreateSettingsGroup(self.child, 260)
        hoverGroup:AddWidget(GUI:CreateHeader(self.child, "Hover Settings"), 40)
        hoverGroup:AddWidget(GUI:CreateDropdown(self.child, "Mode", highlightModes, db, "hoverHighlightMode", function()
            self:RefreshStates()
        end), 55)
        local hoverThick = hoverGroup:AddWidget(GUI:CreateSlider(self.child, "Thickness", 1, 10, 1, db, "hoverHighlightThickness", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
        hoverThick.hideOn = HideHoverOptions
        local hoverInset = hoverGroup:AddWidget(GUI:CreateSlider(self.child, "Inset", -10, 10, 1, db, "hoverHighlightInset", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
        hoverInset.hideOn = HideHoverOptions
        local hoverAlpha = hoverGroup:AddWidget(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "hoverHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
        hoverAlpha.hideOn = HideHoverOptions
        local hoverCol = hoverGroup:AddWidget(GUI:CreateColorPicker(self.child, "Color", db, "hoverHighlightColor", false, nil, function() DF:LightweightUpdateHighlight("hover") end, true), 35)
        hoverCol.hideOn = HideHoverOptions
        AddToSection(hoverGroup, nil, 1)
        
        currentSection = nil
        AddSpace(10, "both")
        
        -- ========================================
        -- AGGRO HIGHLIGHT SECTION
        -- ========================================
        local aggroSection = Add(GUI:CreateCollapsibleSection(self.child, "Aggro Highlight", true), 36, "both")
        currentSection = aggroSection
        
        local function HideAggroOptions(d) return d.aggroHighlightMode == "NONE" or d.aggroHighlightMode == "HEALTH_COLOR" end
        local function HideAggroModeNone(d) return d.aggroHighlightMode == "NONE" end
        local function HideCustomColorOptions(d) return d.aggroHighlightMode == "NONE" or not d.aggroUseCustomColors end
        local function HideNonTankingColors(d) return d.aggroHighlightMode == "NONE" or not d.aggroUseCustomColors or d.aggroOnlyTanking end
        
        local aggroModes = {
            ["NONE"] = "Hidden",
            ["HEALTH_COLOR"] = "Health Bar Color",
            ["SOLID"] = "Solid Border",
            ["ANIMATED"] = "Animated Border",
            ["DASHED"] = "Dashed Border",
            ["GLOW"] = "Glow",
            ["CORNERS"] = "Corners Only",
        }
        
        -- Aggro Settings Group (col1)
        local aggroGroup = GUI:CreateSettingsGroup(self.child, 260)
        aggroGroup:AddWidget(GUI:CreateHeader(self.child, "Aggro Settings"), 40)
        aggroGroup:AddWidget(GUI:CreateDropdown(self.child, "Mode", aggroModes, db, "aggroHighlightMode", function()
            self:RefreshStates()
            if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
        end), 55)
        local aggroOnlyTanking = aggroGroup:AddWidget(GUI:CreateCheckbox(self.child, "Only Show When Tanking", db, "aggroOnlyTanking", function()
            self:RefreshStates()
            if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
        end), 28)
        aggroOnlyTanking.hideOn = HideAggroModeNone
        local aggroThick = aggroGroup:AddWidget(GUI:CreateSlider(self.child, "Thickness", 1, 10, 1, db, "aggroHighlightThickness", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
        aggroThick.hideOn = HideAggroOptions
        local aggroInset = aggroGroup:AddWidget(GUI:CreateSlider(self.child, "Inset", -10, 10, 1, db, "aggroHighlightInset", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
        aggroInset.hideOn = HideAggroOptions
        local aggroAlpha = aggroGroup:AddWidget(GUI:CreateSlider(self.child, "Alpha", 0.1, 1.0, 0.05, db, "aggroHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
        aggroAlpha.hideOn = HideAggroOptions
        AddToSection(aggroGroup, nil, 1)
        
        -- Threat Colors Group (col2)
        local threatGroup = GUI:CreateSettingsGroup(self.child, 260)
        threatGroup:AddWidget(GUI:CreateHeader(self.child, "Threat Colors"), 40)
        local useCustomColors = threatGroup:AddWidget(GUI:CreateCheckbox(self.child, "Use Custom Colors", db, "aggroUseCustomColors", function()
            self:RefreshStates()
            if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
        end), 28)
        useCustomColors.hideOn = HideAggroModeNone
        local colorHighThreat = threatGroup:AddWidget(GUI:CreateColorPicker(self.child, "High Threat (Yellow)", db, "aggroColorHighThreat", false, nil, function()
            DF:LightweightUpdateHighlight("aggro")
        end, true), 30)
        colorHighThreat.hideOn = HideNonTankingColors
        local colorHighestThreat = threatGroup:AddWidget(GUI:CreateColorPicker(self.child, "Highest Threat (Orange)", db, "aggroColorHighestThreat", false, nil, function()
            DF:LightweightUpdateHighlight("aggro")
        end, true), 30)
        colorHighestThreat.hideOn = HideNonTankingColors
        local colorTanking = threatGroup:AddWidget(GUI:CreateColorPicker(self.child, "Tanking (Red)", db, "aggroColorTanking", false, nil, function()
            DF:LightweightUpdateHighlight("aggro")
        end, true), 30)
        colorTanking.hideOn = HideCustomColorOptions
        threatGroup:AddWidget(GUI:CreateLabel(self.child, "Yellow=high, Orange=highest, Red=tanking.", 230), 25)
        threatGroup.hideOn = HideAggroModeNone
        AddToSection(threatGroup, nil, 2)
        
        currentSection = nil
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_dispel", label = "Dispel Overlay"},
        }), 30, "both")
    end)
    
    -- Auras > Dispel Overlay (moved from Indicators)
    local pageDispel = CreateSubTab("auras", "auras_dispel", "Dispel Overlay")
    BuildPage(pageDispel, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"dispel"}, "Dispel Overlay"), 25, 2)
        
        AddSpace(10, "both")
        
        local function HideDispelOptions(d)
            return not d.dispelOverlayEnabled
        end
        
        local function InvalidateCurves()
            if DF.InvalidateDispelColorCurve then DF:InvalidateDispelColorCurve() end
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end
        
        -- ===== SETTINGS GROUP (Column 1) =====
        local settingsGroup = GUI:CreateSettingsGroup(self.child, 280)
        settingsGroup:AddWidget(GUI:CreateHeader(self.child, "Settings"), 40)
        settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Dispel Overlay", db, "dispelOverlayEnabled", function()
            self:RefreshStates()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end), 30)
        settingsGroup:AddWidget(GUI:CreateLabel(self.child, "Shows a colored border/glow when a dispellable debuff is present.", 250), 35)
        local partyDbDispel = DF.db.party
        local dispelIndicatorOptions = { [1] = "Dispellable By Me", [2] = "All Dispellable" }
        local dispelIndicatorDropdown = settingsGroup:AddWidget(GUI:CreateDropdown(self.child, "Show Overlay For", dispelIndicatorOptions, partyDbDispel, "_blizzDispelIndicator", function()
            local newValue = partyDbDispel._blizzDispelIndicator or 1
            if newValue == 0 then partyDbDispel._blizzDispelIndicator = 1; newValue = 1 end
            SetCVar("raidFramesDispelIndicatorType", newValue)
            InvalidateCurves()
        end), 55)
        dispelIndicatorDropdown.hideOn = HideDispelOptions
        local showBorder = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Border", db, "dispelShowBorder", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end), 30)
        showBorder.hideOn = HideDispelOptions
        local showGradient = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Gradient", db, "dispelShowGradient", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end), 30)
        showGradient.hideOn = HideDispelOptions
        local animate = settingsGroup:AddWidget(GUI:CreateCheckbox(self.child, "Pulse Animation", db, "dispelAnimate", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end), 30)
        animate.hideOn = HideDispelOptions
        Add(settingsGroup, nil, 1)
        
        -- ===== ICON GROUP (Column 2) =====
        local iconGroup = GUI:CreateSettingsGroup(self.child, 280)
        iconGroup:AddWidget(GUI:CreateHeader(self.child, "Dispel Type Icon"), 40)
        local showIcon = iconGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show Dispel Icon", db, "dispelShowIcon", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end), 30)
        showIcon.hideOn = HideDispelOptions
        local HideIconOptions = function(d) return not d.dispelOverlayEnabled or d.dispelShowIcon == false end
        local iconSize = iconGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Size", 10, 40, 1, db, "dispelIconSize", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        iconSize.hideOn = HideIconOptions
        local iconAlpha = iconGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Opacity", 0.1, 1.0, 0.1, db, "dispelIconAlpha", function()
            InvalidateCurves()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        iconAlpha.hideOn = HideIconOptions
        local iconPositions = {
            ["CENTER"] = "Center", ["TOP"] = "Top", ["BOTTOM"] = "Bottom",
            ["LEFT"] = "Left", ["RIGHT"] = "Right",
            ["TOPLEFT"] = "Top Left", ["TOPRIGHT"] = "Top Right",
            ["BOTTOMLEFT"] = "Bottom Left", ["BOTTOMRIGHT"] = "Bottom Right",
        }
        local iconPos = iconGroup:AddWidget(GUI:CreateDropdown(self.child, "Icon Position", iconPositions, db, "dispelIconPosition", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end), 55)
        iconPos.hideOn = HideIconOptions
        local iconOffsetX = iconGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Offset X", -50, 50, 1, db, "dispelIconOffsetX", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        iconOffsetX.hideOn = HideIconOptions
        local iconOffsetY = iconGroup:AddWidget(GUI:CreateSlider(self.child, "Icon Offset Y", -50, 50, 1, db, "dispelIconOffsetY", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        iconOffsetY.hideOn = HideIconOptions
        iconGroup.hideOn = HideDispelOptions
        Add(iconGroup, nil, 2)
        
        -- ===== BORDER GROUP (Column 1) =====
        local borderGroup = GUI:CreateSettingsGroup(self.child, 280)
        borderGroup:AddWidget(GUI:CreateHeader(self.child, "Border"), 40)
        local borderSize = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Border Thickness", 1, 6, 1, db, "dispelBorderSize", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        borderSize.hideOn = HideDispelOptions
        local borderInset = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Border Inset", -4, 4, 1, db, "dispelBorderInset", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        borderInset.hideOn = HideDispelOptions
        local borderAlpha = borderGroup:AddWidget(GUI:CreateSlider(self.child, "Border Opacity", 0.1, 1.0, 0.1, db, "dispelBorderAlpha", function()
            InvalidateCurves()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        borderAlpha.hideOn = HideDispelOptions
        borderGroup.hideOn = HideDispelOptions
        Add(borderGroup, nil, 1)
        
        -- ===== COLORS GROUP (Column 2) =====
        local colorsGroup = GUI:CreateSettingsGroup(self.child, 280)
        colorsGroup:AddWidget(GUI:CreateHeader(self.child, "Custom Dispel Colors"), 40)
        local magicColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, "Magic", db, "dispelMagicColor", false, InvalidateCurves, function() DF:LightweightUpdateDispelColors() end, true), 30)
        magicColor.hideOn = HideDispelOptions
        local curseColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, "Curse", db, "dispelCurseColor", false, InvalidateCurves, function() DF:LightweightUpdateDispelColors() end, true), 30)
        curseColor.hideOn = HideDispelOptions
        local diseaseColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, "Disease", db, "dispelDiseaseColor", false, InvalidateCurves, function() DF:LightweightUpdateDispelColors() end, true), 30)
        diseaseColor.hideOn = HideDispelOptions
        local poisonColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, "Poison", db, "dispelPoisonColor", false, InvalidateCurves, function() DF:LightweightUpdateDispelColors() end, true), 30)
        poisonColor.hideOn = HideDispelOptions
        local bleedColor = colorsGroup:AddWidget(GUI:CreateColorPicker(self.child, "Bleed / Enrage", db, "dispelBleedColor", false, InvalidateCurves, function() DF:LightweightUpdateDispelColors() end, true), 30)
        bleedColor.hideOn = HideDispelOptions
        local resetColors = colorsGroup:AddWidget(GUI:CreateButton(self.child, "Reset to Defaults", 130, 22, function()
            db.dispelMagicColor = {r = 0.2, g = 0.6, b = 1.0}
            db.dispelCurseColor = {r = 0.6, g = 0.0, b = 1.0}
            db.dispelDiseaseColor = {r = 0.6, g = 0.4, b = 0.0}
            db.dispelPoisonColor = {r = 0.0, g = 0.6, b = 0.0}
            db.dispelBleedColor = {r = 1.0, g = 0.0, b = 0.0}
            InvalidateCurves()
            self:Refresh()
        end), 30)
        resetColors.hideOn = HideDispelOptions
        colorsGroup.hideOn = HideDispelOptions
        Add(colorsGroup, nil, 2)
        
        -- ===== GRADIENT GROUP (Column 1) =====
        local gradientGroup = GUI:CreateSettingsGroup(self.child, 280)
        gradientGroup:AddWidget(GUI:CreateHeader(self.child, "Gradient"), 40)
        local gradientStyles = {
            ["FULL"] = "Full Frame", ["TOP"] = "Top Edge", ["BOTTOM"] = "Bottom Edge",
            ["LEFT"] = "Left Edge", ["RIGHT"] = "Right Edge", ["EDGE"] = "Edge Glow (All Sides)",
        }
        local gradStyle = gradientGroup:AddWidget(GUI:CreateDropdown(self.child, "Gradient Position", gradientStyles, db, "dispelGradientStyle", function()
            self:RefreshStates()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end), 55)
        gradStyle.hideOn = HideDispelOptions
        local onHealthCheck = gradientGroup:AddWidget(GUI:CreateCheckbox(self.child, "Show On Current Health Only", db, "dispelGradientOnCurrentHealth", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end), 30)
        onHealthCheck.hideOn = function(d) return not d.dispelOverlayEnabled or d.dispelGradientStyle ~= "FULL" end
        local gradSize = gradientGroup:AddWidget(GUI:CreateSlider(self.child, "Gradient Size", 0.1, 1.0, 0.1, db, "dispelGradientSize", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        gradSize.hideOn = HideDispelOptions
        local gradAlpha = gradientGroup:AddWidget(GUI:CreateSlider(self.child, "Gradient Opacity", 0.1, 1.0, 0.1, db, "dispelGradientAlpha", function()
            InvalidateCurves()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        gradAlpha.hideOn = HideDispelOptions
        local gradIntensity = gradientGroup:AddWidget(GUI:CreateSlider(self.child, "Gradient Intensity", 0.5, 3.0, 0.1, db, "dispelGradientIntensity", function()
            InvalidateCurves()
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        gradIntensity.hideOn = HideDispelOptions
        local blendModes = { ["ADD"] = "Glow (ADD)", ["BLEND"] = "Solid (BLEND)" }
        local blendDropdown = gradientGroup:AddWidget(GUI:CreateDropdown(self.child, "Blend Mode", blendModes, db, "dispelGradientBlendMode", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end), 55)
        blendDropdown.hideOn = HideDispelOptions
        gradientGroup.hideOn = HideDispelOptions
        Add(gradientGroup, nil, 1)
        
        -- ===== DARKEN GROUP (Column 2) =====
        local darkenGroup = GUI:CreateSettingsGroup(self.child, 280)
        darkenGroup:AddWidget(GUI:CreateHeader(self.child, "Darken Effect"), 40)
        local darkenCheck = darkenGroup:AddWidget(GUI:CreateCheckbox(self.child, "Darken Behind Gradient", db, "dispelGradientDarkenEnabled", function()
            self:RefreshStates()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end), 30)
        darkenCheck.hideOn = HideDispelOptions
        local darkenAlpha = darkenGroup:AddWidget(GUI:CreateSlider(self.child, "Darken Amount", 0.1, 1.0, 0.05, db, "dispelGradientDarkenAlpha", function()
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
        darkenAlpha.hideOn = function(d) return not d.dispelOverlayEnabled or not d.dispelGradientDarkenEnabled end
        darkenGroup.hideOn = HideDispelOptions
        Add(darkenGroup, nil, 2)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_debuffs", label = "Debuffs"},
            {pageId = "auras_mybuffindicators", label = "My Buff Indicators"},
            {pageId = "indicators_highlights", label = "Highlights"},
        }), 30, "both")
    end)
    
    -- ========================================
    -- CATEGORY: Profiles
    -- ========================================
    CreateCategory("profiles", "Profiles")
    
    -- ========================================
    -- Profiles > Auto Profiles (Raid only)
    -- ========================================
    local pageAutoProfiles = CreateSubTab("profiles", "profiles_auto", "Auto Profiles")
    BuildPage(pageAutoProfiles, function(self, db, Add, AddSpace)
        if DF.AutoProfilesUI and DF.AutoProfilesUI.BuildPage then
            DF.AutoProfilesUI:BuildPage(GUI, self, db, Add, AddSpace)
        else
            Add(GUI:CreateHeader(self.child, "Auto Profiles"), 40, "both")
            Add(GUI:CreateLabel(self.child, "Auto Profiles module not loaded.", 400), 30, "both")
        end
    end)
    
    -- Profiles > Manage
    local pageManage = CreateSubTab("profiles", "profiles_manage", "Manage")
    BuildPage(pageManage, function(self, db, Add, AddSpace, AddSyncPoint)
        local currentProfile = DF:GetCurrentProfile()
        local profiles = DF:GetProfiles()
        
        -- Helper to add to current section (for collapsible sections this pattern won't apply, but we use groups)
        local currentSection = nil
        local function AddToSection(widget, col, colNum)
            widget.layoutCol = colNum or col
            table.insert(self.children, widget)
        end
        
        -- ============================================
        -- COLUMN 1: Profile List & Creation
        -- ============================================
        
        -- Current Profile Info Group
        local currentGroup = GUI:CreateSettingsGroup(self.child, 260)
        currentGroup:AddWidget(GUI:CreateHeader(self.child, "Current Profile"), 40)
        currentGroup:AddWidget(GUI:CreateLabel(self.child, "|cff00ff00" .. currentProfile .. "|r", 240), 25)
        AddToSection(currentGroup, nil, 1)
        
        -- Available Profiles Group
        local listGroup = GUI:CreateSettingsGroup(self.child, 260)
        listGroup:AddWidget(GUI:CreateHeader(self.child, "Available Profiles"), 40)
        
        -- Create a container frame for profile list with fixed width and max height
        local maxListHeight = 180
        local contentHeight = #profiles * 28 + 10
        local listHeight = math.min(contentHeight, maxListHeight)
        local listContainer = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
        listContainer:SetSize(240, listHeight)
        listContainer:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        listContainer:SetBackdropColor(0, 0, 0, 0.3)
        listContainer:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        listGroup:AddWidget(listContainer, listHeight + 5)
        
        -- Create scroll frame for the profile list
        local profileScroll = CreateFrame("ScrollFrame", nil, listContainer, "UIPanelScrollFrameTemplate")
        profileScroll:SetPoint("TOPLEFT", 2, -2)
        profileScroll:SetPoint("BOTTOMRIGHT", -22, 2)
        
        -- Style the scrollbar
        local scrollBar = profileScroll.ScrollBar or _G[profileScroll:GetName() .. "ScrollBar"]
        if scrollBar then
            scrollBar:SetWidth(10)
            if contentHeight <= maxListHeight then
                scrollBar:Hide()
                profileScroll:SetPoint("BOTTOMRIGHT", -4, 2)
            end
        end
        
        -- Create scroll child to hold profile buttons
        local profileScrollChild = CreateFrame("Frame", nil, profileScroll)
        profileScrollChild:SetSize(210, contentHeight)
        profileScroll:SetScrollChild(profileScrollChild)
        
        -- Profile buttons inside scroll child
        local py = -3
        for i, p in ipairs(profiles) do
            local btn = CreateFrame("Button", nil, profileScrollChild, "BackdropTemplate")
            btn:SetSize(206, 24)
            btn:SetPoint("TOPLEFT", 2, py)
            btn:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
            })
            btn:SetBackdropColor(0.15, 0.15, 0.15, 1)
            btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            
            local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            text:SetPoint("CENTER")
            text:SetText(p)
            
            if p == currentProfile then
                local c = GUI.GetThemeColor()
                btn:SetBackdropColor(c.r * 0.3, c.g * 0.3, c.b * 0.3, 1)
                btn:SetBackdropBorderColor(c.r, c.g, c.b, 1)
            end
            
            btn:SetScript("OnEnter", function(self)
                self:SetBackdropColor(0.25, 0.25, 0.25, 1)
            end)
            btn:SetScript("OnLeave", function(self)
                if p == currentProfile then
                    local c = GUI.GetThemeColor()
                    self:SetBackdropColor(c.r * 0.3, c.g * 0.3, c.b * 0.3, 1)
                else
                    self:SetBackdropColor(0.15, 0.15, 0.15, 1)
                end
            end)
            btn:SetScript("OnClick", function() 
                DF:SetProfile(p) 
                if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
            end)
            py = py - 28
        end
        
        AddToSection(listGroup, nil, 1)
        
        -- Create New Profile Group
        local createGroup = GUI:CreateSettingsGroup(self.child, 260)
        createGroup:AddWidget(GUI:CreateHeader(self.child, "Create New Profile"), 40)
        
        local input = GUI:CreateInput(self.child, "Profile Name", 240)
        createGroup:AddWidget(input, 50)
        
        -- Button row for create actions
        local btnRow = CreateFrame("Frame", nil, self.child)
        btnRow:SetSize(240, 28)
        
        local createBtn = GUI:CreateButton(self.child, "Create Empty", 115, 24, function()
            local text = input.EditBox:GetText()
            if not text or text == "" then
                print("|cffff6666DandersFrames:|r Please enter a profile name.")
                return
            end
            DF:SetProfile(text) 
            input.EditBox:SetText("")
            if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
        end)
        createBtn:SetParent(btnRow)
        createBtn:SetPoint("LEFT", 0, 0)
        
        local dupeBtn = GUI:CreateButton(self.child, "Duplicate Current", 115, 24, function()
            local text = input.EditBox:GetText()
            if not text or text == "" then
                print("|cffff6666DandersFrames:|r Please enter a name for the duplicated profile.")
                return
            end
            if DF:DuplicateProfile(text) then
                input.EditBox:SetText("")
                if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
            end
        end)
        dupeBtn:SetParent(btnRow)
        dupeBtn:SetPoint("LEFT", createBtn, "RIGHT", 10, 0)
        
        createGroup:AddWidget(btnRow, 32)
        AddToSection(createGroup, nil, 1)
        
        -- ============================================
        -- COLUMN 2: Actions & Settings
        -- ============================================
        
        -- Profile Actions Group
        local actionsGroup = GUI:CreateSettingsGroup(self.child, 260)
        actionsGroup:AddWidget(GUI:CreateHeader(self.child, "Profile Actions"), 40)
        
        -- Register delete confirmation popup
        if not StaticPopupDialogs["DANDERSFRAMES_DELETE_PROFILE_CONFIRM"] then
            StaticPopupDialogs["DANDERSFRAMES_DELETE_PROFILE_CONFIRM"] = {
                text = "Delete profile '%s'?\nThis cannot be undone.",
                button1 = "Delete",
                button2 = "Cancel",
                OnAccept = function(self, data)
                    DF:SetProfile("Default")
                    DF:DeleteProfile(data)
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
        end
        
        actionsGroup:AddWidget(GUI:CreateIconButton(self.child, "delete", "Delete Current Profile", 240, 26, function()
            local p = DF:GetCurrentProfile()
            if p == "Default" then 
                print("|cffff6666DandersFrames:|r Cannot delete Default profile.") 
            else
                local dialog = StaticPopup_Show("DANDERSFRAMES_DELETE_PROFILE_CONFIRM", p)
                if dialog then
                    dialog.data = p
                end
            end
        end), 32)
        
        -- Register reset confirmation popup
        if not StaticPopupDialogs["DANDERSFRAMES_RESET_PROFILE_CONFIRM"] then
            StaticPopupDialogs["DANDERSFRAMES_RESET_PROFILE_CONFIRM"] = {
                text = "Reset current profile to defaults?\nThis will reset BOTH Party and Raid settings.",
                button1 = "Yes",
                button2 = "No",
                OnAccept = function()
                    DF:ResetProfile("party")
                    DF:ResetProfile("raid")
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
        end
        
        actionsGroup:AddWidget(GUI:CreateIconButton(self.child, "refresh", "Reset Profile to Defaults", 240, 26, function()
            StaticPopup_Show("DANDERSFRAMES_RESET_PROFILE_CONFIRM")
        end), 32)
        
        AddToSection(actionsGroup, nil, 2)
        
        -- Copy Settings Group
        local copyGroup = GUI:CreateSettingsGroup(self.child, 260)
        copyGroup:AddWidget(GUI:CreateHeader(self.child, "Copy Settings"), 40)
        copyGroup:AddWidget(GUI:CreateLabel(self.child, "Copy all settings between Party and Raid modes.", 240), 25)
        
        -- Register copy confirmation popups
        if not StaticPopupDialogs["DANDERSFRAMES_COPY_PARTY_TO_RAID"] then
            StaticPopupDialogs["DANDERSFRAMES_COPY_PARTY_TO_RAID"] = {
                text = "Copy Party settings to Raid?\n\nThis will overwrite all Raid settings with your current Party settings.",
                button1 = "Copy",
                button2 = "Cancel",
                OnAccept = function()
                    DF:CopyProfile("party", "raid")
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
        end
        
        if not StaticPopupDialogs["DANDERSFRAMES_COPY_RAID_TO_PARTY"] then
            StaticPopupDialogs["DANDERSFRAMES_COPY_RAID_TO_PARTY"] = {
                text = "Copy Raid settings to Party?\n\nThis will overwrite all Party settings with your current Raid settings.",
                button1 = "Copy",
                button2 = "Cancel",
                OnAccept = function()
                    DF:CopyProfile("raid", "party")
                    if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
        end
        
        copyGroup:AddWidget(GUI:CreateIconButton(self.child, "chevron_right", "Party to Raid", 240, 26, function()
            StaticPopup_Show("DANDERSFRAMES_COPY_PARTY_TO_RAID")
        end), 32)
        
        copyGroup:AddWidget(GUI:CreateIconButton(self.child, "chevron_right", "Raid to Party", 240, 26, function()
            StaticPopup_Show("DANDERSFRAMES_COPY_RAID_TO_PARTY")
        end), 32)
        
        AddToSection(copyGroup, nil, 2)
        
        -- Auto-Switch by Spec Group
        local specGroup = GUI:CreateSettingsGroup(self.child, 260)
        specGroup:AddWidget(GUI:CreateHeader(self.child, "Auto-Switch by Spec"), 40)
        
        -- Initialize per-character data if needed
        if not DandersFramesCharDB then 
            DandersFramesCharDB = { enableSpecSwitch = false, specProfiles = {} } 
        end
        
        specGroup:AddWidget(GUI:CreateCheckbox(self.child, "Enable Spec Auto-Switch", DandersFramesCharDB, "enableSpecSwitch"), 30)
        
        local numSpecs = GetNumSpecializations and GetNumSpecializations() or 0
        if numSpecs > 0 then
            -- Build profile list for dropdown
            local pList = { [""] = "None" }
            for _, p in ipairs(profiles) do 
                pList[p] = p 
            end
            
            if not DandersFramesCharDB.specProfiles then 
                DandersFramesCharDB.specProfiles = {} 
            end
            
            for i = 1, numSpecs do
                local id, name, _, icon = GetSpecializationInfo(i)
                if name then
                    specGroup:AddWidget(GUI:CreateDropdown(self.child, name, pList, DandersFramesCharDB.specProfiles, i), 55)
                end
            end
        else
            specGroup:AddWidget(GUI:CreateLabel(self.child, "Specialization data not available.", 240), 25)
        end
        
        AddToSection(specGroup, nil, 2)
        
        -- See Also links
        AddSpace(20, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "profiles_importexport", label = "Import/Export"},
        }), 30, "both")
    end)
    
    -- Profiles > Import/Export
    local pageImportExport = CreateSubTab("profiles", "profiles_importexport", "Import/Export")
    BuildPage(pageImportExport, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Store references
        self.exportCheckboxes = {}
        self.importCheckboxes = {}
        self.exportFrameTypes = {party = true, raid = true}
        self.importFrameTypes = {party = true, raid = true}
        
        local categoryOrder = {"position", "layout", "bars", "auras", "text", "icons", "other"}
        
        -- Helper to add to section
        local function AddToSection(widget, col, colNum)
            widget.layoutCol = colNum or col
            table.insert(self.children, widget)
        end
        
        -- Helper to create themed small checkbox
        local function CreateSmallCheckbox(parent, label, initialChecked)
            local container = CreateFrame("Frame", nil, parent)
            container:SetSize(100, 18)
            
            local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
            cb:SetSize(14, 14)
            cb:SetPoint("LEFT", 0, 0)
            cb:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
            })
            cb:SetBackdropColor(0.18, 0.18, 0.18, 1)
            cb:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
            
            cb.Check = cb:CreateTexture(nil, "OVERLAY")
            cb.Check:SetTexture("Interface\\Buttons\\WHITE8x8")
            local tc = GUI.GetThemeColor()
            cb.Check:SetVertexColor(tc.r, tc.g, tc.b)
            cb.Check:SetPoint("CENTER")
            cb.Check:SetSize(8, 8)
            cb:SetCheckedTexture(cb.Check)
            
            local txt = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            txt:SetPoint("LEFT", cb, "RIGHT", 4, 0)
            txt:SetText(label)
            txt:SetTextColor(0.85, 0.85, 0.85)
            cb.label = txt
            
            cb:SetChecked(initialChecked or false)
            
            container.UpdateTheme = function()
                local c = GUI.GetThemeColor()
                cb.Check:SetVertexColor(c.r, c.g, c.b)
            end
            if not parent.ThemeListeners then parent.ThemeListeners = {} end
            table.insert(parent.ThemeListeners, container)
            
            container.checkbox = cb
            container.SetChecked = function(self, val) cb:SetChecked(val) end
            container.GetChecked = function(self) return cb:GetChecked() end
            container.Enable = function(self) cb:Enable(); container:SetAlpha(1) end
            container.Disable = function(self) cb:Disable(); container:SetAlpha(0.35) end
            
            return container
        end
        
        -- Helper to create small themed button
        local function CreateSmallButton(parent, text, width)
            local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
            btn:SetSize(width, 20)
            btn:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
            })
            btn:SetBackdropColor(0.15, 0.15, 0.15, 1)
            btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
            
            btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.text:SetPoint("CENTER")
            btn.text:SetText(text)
            btn.text:SetTextColor(0.8, 0.8, 0.8)
            
            btn:SetScript("OnEnter", function(s) s:SetBackdropColor(0.25, 0.25, 0.25, 1) end)
            btn:SetScript("OnLeave", function(s) s:SetBackdropColor(0.15, 0.15, 0.15, 1) end)
            
            return btn
        end
        
        -- ========================================
        -- COLUMN 1: EXPORT
        -- ========================================
        
        -- Export Settings Group
        local exportSettingsGroup = GUI:CreateSettingsGroup(self.child, 260)
        exportSettingsGroup:AddWidget(GUI:CreateHeader(self.child, "Export Settings"), 40)
        
        -- Profile name input
        local nameInput = GUI:CreateInput(self.child, "Profile Name", 240)
        local currentProfileName = (DF.db and DF.db.keys and DF.db.keys.profile) or "My Profile"
        nameInput.EditBox:SetText(currentProfileName)
        self.exportNameEdit = nameInput.EditBox
        exportSettingsGroup:AddWidget(nameInput, 50)
        
        -- Preset buttons row
        local presetRow = CreateFrame("Frame", nil, self.child)
        presetRow:SetSize(240, 24)
        
        local presets = {
            {name = "All", x = 0, cats = {"position", "layout", "bars", "auras", "text", "icons", "other"}},
            {name = "Look", x = 60, cats = {"bars", "auras", "text", "icons", "other"}},
            {name = "Layout", x = 120, cats = {"position", "layout"}},
            {name = "None", x = 180, cats = {}},
        }
        
        for _, p in ipairs(presets) do
            local btn = CreateSmallButton(presetRow, p.name, 56)
            btn:SetPoint("LEFT", p.x, 0)
            btn:SetScript("OnClick", function()
                local sel = {}
                for _, c in ipairs(p.cats) do sel[c] = true end
                for cat, cb in pairs(self.exportCheckboxes) do cb:SetChecked(sel[cat] or false) end
            end)
        end
        exportSettingsGroup:AddWidget(presetRow, 28)
        
        -- Frame types row
        local ftRow = CreateFrame("Frame", nil, self.child)
        ftRow:SetSize(240, 20)
        
        local partyExp = CreateSmallCheckbox(ftRow, "Party", true)
        partyExp:SetPoint("LEFT", 0, 0)
        partyExp.checkbox:SetScript("OnClick", function(s) self.exportFrameTypes.party = s:GetChecked() end)
        
        local raidExp = CreateSmallCheckbox(ftRow, "Raid", true)
        raidExp:SetPoint("LEFT", 80, 0)
        raidExp.checkbox:SetScript("OnClick", function(s) self.exportFrameTypes.raid = s:GetChecked() end)
        exportSettingsGroup:AddWidget(ftRow, 24)
        
        -- Categories
        for _, cat in ipairs(categoryOrder) do
            local info = DF.ExportCategoryInfo[cat]
            local catRow = CreateFrame("Frame", nil, self.child)
            catRow:SetSize(240, 18)
            
            local cb = CreateSmallCheckbox(catRow, info.name, true)
            cb:SetPoint("LEFT", 0, 0)
            self.exportCheckboxes[cat] = cb
            exportSettingsGroup:AddWidget(catRow, 20)
        end
        
        AddToSection(exportSettingsGroup, nil, 1)
        
        -- Export Actions Group
        local exportActionsGroup = GUI:CreateSettingsGroup(self.child, 260)
        exportActionsGroup:AddWidget(GUI:CreateHeader(self.child, "Export"), 40)
        
        -- Export button
        exportActionsGroup:AddWidget(GUI:CreateIconButton(self.child, "upload", "Generate Export String", 240, 26, function()
            local selectedCats = {}
            local allSelected = true
            for _, cat in ipairs(categoryOrder) do
                if self.exportCheckboxes[cat]:GetChecked() then
                    table.insert(selectedCats, cat)
                else
                    allSelected = false
                end
            end
            if allSelected then selectedCats = nil end
            
            local profileName = self.exportNameEdit:GetText()
            if profileName == "" then profileName = nil end
            
            local str = DF:ExportProfile(selectedCats, self.exportFrameTypes, profileName)
            if str and self.exportEditBox then
                self.exportEditBox:SetText(str)
                self.exportEditBox:HighlightText()
                self.exportEditBox:SetFocus()
                print("|cff00ff00DandersFrames:|r Export generated.")
            elseif not str then
                print("|cffff0000DandersFrames:|r Export failed - no string returned")
            end
        end), 32)
        
        -- Export text area
        local exportScrollContainer = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
        exportScrollContainer:SetSize(240, 100)
        exportScrollContainer:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        exportScrollContainer:SetBackdropColor(0.08, 0.08, 0.08, 0.9)
        exportScrollContainer:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
        
        local exportScroll = CreateFrame("ScrollFrame", nil, exportScrollContainer, "UIPanelScrollFrameTemplate")
        exportScroll:SetPoint("TOPLEFT", 4, -4)
        exportScroll:SetPoint("BOTTOMRIGHT", -22, 4)
        
        local exportEditBox = CreateFrame("EditBox", nil, exportScroll)
        exportEditBox:SetMultiLine(true)
        exportEditBox:SetFontObject(GameFontHighlightSmall)
        exportEditBox:SetWidth(210)
        exportEditBox:SetHeight(90)
        exportEditBox:SetAutoFocus(false)
        exportEditBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        exportScroll:SetScrollChild(exportEditBox)
        self.exportEditBox = exportEditBox
        
        exportScrollContainer:EnableMouse(true)
        exportScrollContainer:SetScript("OnMouseDown", function() exportEditBox:SetFocus() end)
        exportScroll:EnableMouse(true)
        exportScroll:SetScript("OnMouseDown", function() exportEditBox:SetFocus() end)
        
        exportActionsGroup:AddWidget(exportScrollContainer, 105)
        
        -- Select All button
        exportActionsGroup:AddWidget(GUI:CreateButton(self.child, "Select All Text", 240, 24, function()
            if self.exportEditBox then 
                self.exportEditBox:HighlightText()
                self.exportEditBox:SetFocus()
            end
        end), 28)
        
        AddToSection(exportActionsGroup, nil, 1)
        
        -- ========================================
        -- COLUMN 2: IMPORT
        -- ========================================
        
        -- Import String Group
        local importStringGroup = GUI:CreateSettingsGroup(self.child, 260)
        importStringGroup:AddWidget(GUI:CreateHeader(self.child, "Import String"), 40)
        
        -- Import text area
        local importScrollContainer = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
        importScrollContainer:SetSize(240, 80)
        importScrollContainer:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        importScrollContainer:SetBackdropColor(0.08, 0.08, 0.08, 0.9)
        importScrollContainer:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
        
        local importScroll = CreateFrame("ScrollFrame", nil, importScrollContainer, "UIPanelScrollFrameTemplate")
        importScroll:SetPoint("TOPLEFT", 4, -4)
        importScroll:SetPoint("BOTTOMRIGHT", -22, 4)
        
        local importEditBox = CreateFrame("EditBox", nil, importScroll)
        importEditBox:SetMultiLine(true)
        importEditBox:SetFontObject(GameFontHighlightSmall)
        importEditBox:SetWidth(210)
        importEditBox:SetHeight(70)
        importEditBox:SetAutoFocus(false)
        importEditBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        importScroll:SetScrollChild(importEditBox)
        self.importEditBox = importEditBox
        
        importScrollContainer:EnableMouse(true)
        importScrollContainer:SetScript("OnMouseDown", function() importEditBox:SetFocus() end)
        importScroll:EnableMouse(true)
        importScroll:SetScript("OnMouseDown", function() importEditBox:SetFocus() end)
        
        importStringGroup:AddWidget(importScrollContainer, 85)
        
        -- Parse button
        importStringGroup:AddWidget(GUI:CreateButton(self.child, "Parse String", 240, 26, function()
            if not self.importEditBox then return end
            local str = self.importEditBox:GetText()
            if not str or str == "" then
                print("|cffff6666DandersFrames:|r Paste a string first.")
                return
            end
            
            local importData, errMsg = DF:ValidateImportString(str)
            if not importData then
                print("|cffff0000DandersFrames:|r " .. errMsg)
                if self.importInfoLabel then self.importInfoLabel:SetText("|cffff6666Error: " .. errMsg .. "|r") end
                return
            end
            
            self.parsedImportData = importData
            local info = DF:GetImportInfo(importData)
            
            if self.importInfoLabel then
                self.importInfoLabel:SetText(string.format("|cff00ff00OK|r v%s %s%s",
                    tostring(info.version),
                    info.hasParty and "[Party]" or "",
                    info.hasRaid and "[Raid]" or ""))
            end
            
            if self.importNameEdit and info.profileName then
                self.importNameEdit:SetText(info.profileName)
            end
            
            if self.createNewProfileCheck then
                self.createNewProfileCheck:Enable()
                self.createNewProfileCheck:SetChecked(true)
            end
            
            local availableCats = {}
            for _, cat in ipairs(info.detectedCategories) do availableCats[cat] = true end
            
            for cat, cb in pairs(self.importCheckboxes) do
                if availableCats[cat] then cb:Enable(); cb:SetChecked(true)
                else cb:Disable(); cb:SetChecked(false) end
            end
            
            if self.importPartyCheck then
                if info.hasParty then self.importPartyCheck:Enable() else self.importPartyCheck:Disable() end
                self.importPartyCheck:SetChecked(info.hasParty)
            end
            if self.importRaidCheck then
                if info.hasRaid then self.importRaidCheck:Enable() else self.importRaidCheck:Disable() end
                self.importRaidCheck:SetChecked(info.hasRaid)
            end
            
            print("|cff00ff00DandersFrames:|r Parsed. Select options and Import.")
        end), 30)
        
        -- Info label
        local infoLabel = self.child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        infoLabel:SetWidth(240)
        infoLabel:SetJustifyH("LEFT")
        infoLabel:SetText("|cff888888Paste string above, then Parse|r")
        self.importInfoLabel = infoLabel
        
        local infoContainer = CreateFrame("Frame", nil, self.child)
        infoContainer:SetSize(240, 18)
        infoLabel:SetParent(infoContainer)
        infoLabel:SetPoint("LEFT", 0, 0)
        importStringGroup:AddWidget(infoContainer, 22)
        
        AddToSection(importStringGroup, nil, 2)
        
        -- Import Settings Group
        local importSettingsGroup = GUI:CreateSettingsGroup(self.child, 260)
        importSettingsGroup:AddWidget(GUI:CreateHeader(self.child, "Import Settings"), 40)
        
        -- Profile name input for import
        local impNameInput = GUI:CreateInput(self.child, "Profile Name", 240)
        impNameInput.EditBox:SetText("Imported Profile")
        self.importNameEdit = impNameInput.EditBox
        importSettingsGroup:AddWidget(impNameInput, 50)
        
        -- Create new profile checkbox
        local createNewRow = CreateFrame("Frame", nil, self.child)
        createNewRow:SetSize(240, 20)
        
        local createNewCheck = CreateSmallCheckbox(createNewRow, "Create New Profile", true)
        createNewCheck:SetPoint("LEFT", 0, 0)
        createNewCheck:Disable()
        self.createNewProfileCheck = createNewCheck
        importSettingsGroup:AddWidget(createNewRow, 24)
        
        -- Frame types row
        local ftRowImp = CreateFrame("Frame", nil, self.child)
        ftRowImp:SetSize(240, 20)
        
        local partyImp = CreateSmallCheckbox(ftRowImp, "Party", false)
        partyImp:SetPoint("LEFT", 0, 0)
        partyImp:Disable()
        partyImp.checkbox:SetScript("OnClick", function(s) self.importFrameTypes.party = s:GetChecked() end)
        self.importPartyCheck = partyImp
        
        local raidImp = CreateSmallCheckbox(ftRowImp, "Raid", false)
        raidImp:SetPoint("LEFT", 80, 0)
        raidImp:Disable()
        raidImp.checkbox:SetScript("OnClick", function(s) self.importFrameTypes.raid = s:GetChecked() end)
        self.importRaidCheck = raidImp
        importSettingsGroup:AddWidget(ftRowImp, 24)
        
        -- Categories
        for _, cat in ipairs(categoryOrder) do
            local info = DF.ExportCategoryInfo[cat]
            local catRow = CreateFrame("Frame", nil, self.child)
            catRow:SetSize(240, 18)
            
            local cb = CreateSmallCheckbox(catRow, info.name, false)
            cb:SetPoint("LEFT", 0, 0)
            cb:Disable()
            self.importCheckboxes[cat] = cb
            importSettingsGroup:AddWidget(catRow, 20)
        end
        
        AddToSection(importSettingsGroup, nil, 2)
        
        -- Import Actions Group
        local importActionsGroup = GUI:CreateSettingsGroup(self.child, 260)
        importActionsGroup:AddWidget(GUI:CreateHeader(self.child, "Import"), 40)
        
        -- Import button
        importActionsGroup:AddWidget(GUI:CreateIconButton(self.child, "download", "Import Selected", 240, 26, function()
            if not self.parsedImportData then
                print("|cffff6666DandersFrames:|r Parse a string first.")
                return
            end
            
            local selectedCats = {}
            for _, cat in ipairs(categoryOrder) do
                if self.importCheckboxes[cat]:GetChecked() then
                    table.insert(selectedCats, cat)
                end
            end
            
            if #selectedCats == 0 then
                print("|cffff6666DandersFrames:|r Select at least one category.")
                return
            end
            
            local selectedFrameTypes = {
                party = self.importPartyCheck:GetChecked(),
                raid = self.importRaidCheck:GetChecked(),
            }
            
            if not selectedFrameTypes.party and not selectedFrameTypes.raid then
                print("|cffff6666DandersFrames:|r Select Party or Raid.")
                return
            end
            
            local createNew = self.createNewProfileCheck and self.createNewProfileCheck:GetChecked()
            local profileName = self.importNameEdit and self.importNameEdit:GetText()
            if profileName == "" then profileName = nil end
            
            local confirmText
            if createNew then
                confirmText = "Create new profile '" .. (profileName or "Imported Profile") .. "'?\n\nThis will copy your current settings, then apply the selected import categories on top."
            else
                local currentProfile = DF:GetCurrentProfile() or "Default"
                confirmText = "Import settings into current profile?\n\n|cffff6666WARNING: This will permanently overwrite settings in your '" .. currentProfile .. "' profile.|r\n\nTip: Check 'Create New Profile' to import without affecting your current settings."
            end
            
            StaticPopupDialogs["DANDERSFRAMES_IMPORT_CONFIRM"] = {
                text = confirmText,
                button1 = "Import",
                button2 = "Cancel",
                OnAccept = function(dialog)
                    local data = dialog.data
                    if data and data.importData then
                        DF:ApplyImportedProfile(data.importData, data.selectedCats, data.selectedFrameTypes, data.profileName, data.createNew)
                        if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                    end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
            
            local dialog = StaticPopup_Show("DANDERSFRAMES_IMPORT_CONFIRM")
            if dialog then
                dialog.data = {
                    importData = self.parsedImportData,
                    selectedCats = selectedCats,
                    selectedFrameTypes = selectedFrameTypes,
                    profileName = profileName,
                    createNew = createNew,
                }
            end
        end), 32)
        
        -- Clear button
        importActionsGroup:AddWidget(GUI:CreateIconButton(self.child, "close", "Clear", 240, 24, function()
            if self.importEditBox then self.importEditBox:SetText("") end
            if self.importInfoLabel then self.importInfoLabel:SetText("|cff888888Paste string above, then Parse|r") end
            if self.importNameEdit then self.importNameEdit:SetText("Imported Profile") end
            if self.createNewProfileCheck then self.createNewProfileCheck:Disable(); self.createNewProfileCheck:SetChecked(true) end
            for _, cb in pairs(self.importCheckboxes) do cb:SetChecked(false); cb:Disable() end
            if self.importPartyCheck then self.importPartyCheck:Disable(); self.importPartyCheck:SetChecked(false) end
            if self.importRaidCheck then self.importRaidCheck:Disable(); self.importRaidCheck:SetChecked(false) end
            self.parsedImportData = nil
        end), 28)
        
        AddToSection(importActionsGroup, nil, 2)
        
        -- See Also
        AddSpace(15, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "profiles_manage", label = "Manage Profiles"},
        }), 30, "both")
    end)
    
end
