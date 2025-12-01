local addonName, DF = ...

function DF:SetupOptions()
    local options = {
        name = "DandersFrames",
        handler = DF,
        type = 'group',
        args = {
            header = { order = 1, type = "header", name = "DandersFrames" },
            description = { order = 2, type = "description", name = "Settings moved to /df", fontSize = "medium" },
            openGUI = { order = 3, name = "Open Settings", type = "execute", width = "double", func = function() DF:ToggleGUI() end },
        },
    }
    LibStub("AceConfig-3.0"):RegisterOptionsTable("DandersFrames", options)
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions("DandersFrames", "DandersFrames")
end

function DF:SetupGUIPages(GUI, CreateTab, BuildPage)
    
    -- TAB 1: GENERAL
    BuildPage(CreateTab("general", "General"), function(self, db, Add, AddSpace)
        -- Define popups once
        if not StaticPopupDialogs["DANDERSFRAMES_DEMO_WARNING"] then
            StaticPopupDialogs["DANDERSFRAMES_DEMO_WARNING"] = {
                text = "Demo Mode is a Work in Progress.\n\nIt forces frames to show fake data for previewing.\n\nNote: You may need to /reload after disabling it to fully reset Blizzard frames.",
                button1 = "Enter Demo",
                button2 = "Cancel",
                OnAccept = function()
                    DF:ToggleDemoMode(true)
                    GUI:RefreshCurrentPage()
                end,
                OnCancel = function()
                    GUI:RefreshCurrentPage()
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
        end

        if not StaticPopupDialogs["DANDERSFRAMES_DEMO_DISABLE_CONFIRM"] then
            StaticPopupDialogs["DANDERSFRAMES_DEMO_DISABLE_CONFIRM"] = {
                text = "Disabling Demo Mode requires a UI Reload to restore frames properly.",
                button1 = "Reload UI",
                button2 = "Cancel",
                OnAccept = function()
                    DF:ToggleDemoMode(false)
                    ReloadUI()
                end,
                OnCancel = function()
                    GUI:RefreshCurrentPage()
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
        end
        
        if not StaticPopupDialogs["DF_CONFIRM_GLOBAL_FONT"] then
            StaticPopupDialogs["DF_CONFIRM_GLOBAL_FONT"] = {
                text = "Apply this font and outline to ALL text elements (Health, Name, Stacks) in %s mode?",
                button1 = "Yes",
                button2 = "No",
                OnAccept = function(self)
                     local selectedFont = self.data.font
                     local selectedOutline = self.data.outline
                     local modeDB = self.data.db
                     
                     if selectedFont then
                         modeDB.healthTextFont = selectedFont
                         modeDB.nameTextFont = selectedFont
                         modeDB.raidBuffStackFont = selectedFont
                         modeDB.raidDebuffStackFont = selectedFont
                         modeDB.raidBuffCountdownFont = selectedFont
                         modeDB.raidDebuffCountdownFont = selectedFont
                     end
                     
                     if selectedOutline then
                         modeDB.healthTextOutline = selectedOutline
                         modeDB.nameTextOutline = selectedOutline
                         modeDB.raidBuffStackOutline = selectedOutline
                         modeDB.raidDebuffStackOutline = selectedOutline
                         modeDB.raidBuffCountdownOutline = selectedOutline
                         modeDB.raidDebuffCountdownOutline = selectedOutline
                     end
                     
                     DF:UpdateAll()
                     GUI:RefreshCurrentPage()
                     print("|cff00ff00DandersFrames:|r Global settings applied to " .. self.data.modeName .. ".")
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
        end

        -- COLUMN 1: Display Options
        Add(GUI:CreateHeader(self, "Display Options"), 30, 1)
        
        local LDBIcon = LibStub("LibDBIcon-1.0", true)
        Add(GUI:CreateCheckbox(self, "Show Minimap Icon", nil, nil, nil, 
            function() return not DF.db.profile.minimap.hide end,
            function(val) 
                DF.db.profile.minimap.hide = not val
                if val then LDBIcon:Show("DandersFrames") else LDBIcon:Hide("DandersFrames") end
            end
        ), 30, 1)
        
        -- Mode-specific options
        if GUI.SelectedMode == "party" then
            Add(GUI:CreateCheckbox(self, "Solo Mode (Show frames when alone)", db, "soloMode", function()
                if db.soloMode then 
                    if CompactPartyFrame and not IsInGroup() then CompactPartyFrame:SetShown(true) end
                else
                    if CompactPartyFrame and not IsInGroup() then CompactPartyFrame:SetShown(false) end
                end
            end), 30, 1)
            Add(GUI:CreateCheckbox(self, "Hide 'Party' Title", db, "hidePartyTitle"), 30, 1)
        end
        
        if GUI.SelectedMode == "raid" then
            Add(GUI:CreateCheckbox(self, "Hide Group Numbers", db, "hideRaidGroupNumbers", function() DF:UpdateFrameTitles() end), 30, 1)
        end
        
        Add(GUI:CreateCheckbox(self, "Demo Mode (Preview)", nil, nil, nil, 
            function() return DF.demoMode end,
            function(val) 
                if val then
                    StaticPopup_Show("DANDERSFRAMES_DEMO_WARNING")
                else
                    StaticPopup_Show("DANDERSFRAMES_DEMO_DISABLE_CONFIRM")
                end
            end
        ), 30, 1)
        
        AddSpace(20, 1)

        -- NEW: Range Settings
        Add(GUI:CreateHeader(self, "Range & Connectivity"), 30, 1)
        Add(GUI:CreateSlider(self, "OOR Fade Alpha", 0.1, 1.0, 0.05, db, "rangeFadeAlpha"), 60, 1)
        
        AddSpace(20, 1)
        
        -- Global Font Section
        Add(GUI:CreateHeader(self, "Global Font"), 30, 1)
        Add(GUI:CreateDropdown(self, "Font", DF:GetFontList(), db, "globalFont"), 60, 1)
        Add(GUI:CreateDropdown(self, "Outline", {
            ["NONE"] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick", ["MONOCHROME"] = "Mono"
        }, db, "globalOutline"), 60, 1)
        Add(GUI:CreateButton(self, "Apply to All Text", 180, 28, function()
             local selectedFont = db.globalFont
             local selectedOutline = db.globalOutline
             if not selectedFont and not selectedOutline then return end
             local modeName = (GUI.SelectedMode == "party" and "Party" or "Raid")
             local dialog = StaticPopup_Show("DF_CONFIRM_GLOBAL_FONT", modeName)
             if dialog then
                 dialog.data = { font = selectedFont, outline = selectedOutline, db = db, modeName = modeName }
             end
        end), 35, 1)

        -- COLUMN 2: Quick Actions
        Add(GUI:CreateHeader(self, "Quick Actions"), 30, 2)
        Add(GUI:CreateButton(self, "Open Blizzard Edit Mode", 220, 32, function()
             if InCombatLockdown() then return end
             if EditModeManagerFrame then ShowUIPanel(EditModeManagerFrame) end
        end), 40, 2)
        Add(GUI:CreateLabel(self.child, "Use Edit Mode to position and resize frames. DandersFrames settings will apply on top.", 280), 55, 2)
    end)

    -- TAB 1.5: FRAME LAYOUT
    BuildPage(CreateTab("framelayout", "Frame Layout"), function(self, db, Add, AddSpace)
        -- COLUMN 1: Frame Size
        Add(GUI:CreateHeader(self, "Custom Frame Size"), 30, 1)
        Add(GUI:CreateCheckbox(self, "Enable Custom Size", db, "enableFrameLayout", function() 
            DF:UpdateAll()
            GUI:RefreshCurrentPage() 
        end), 30, 1)
        
        local fWidth = Add(GUI:CreateSlider(self, "Width", 40, 200, 1, db, "frameWidth", function() DF:UpdateAll() end), 60, 1)
        fWidth.disableOn = function(d) return not d.enableFrameLayout end
        
        local fHeight = Add(GUI:CreateSlider(self, "Height", 20, 150, 1, db, "frameHeight", function() DF:UpdateAll() end), 60, 1)
        fHeight.disableOn = function(d) return not d.enableFrameLayout end
        
        local fOpacity = Add(GUI:CreateSlider(self, "Opacity", 0.1, 1.0, 0.05, db, "frameOpacity", function() DF:UpdateAll() end), 60, 1)
        fOpacity.disableOn = function(d) return not d.enableFrameLayout end
        
        AddSpace(20, 1)
        
        -- Growth Behavior
        Add(GUI:CreateHeader(self, "Growth Behavior"), 30, 1)
        Add(GUI:CreateCheckbox(self, "Grow from Center", db, "growCenter", function()
             if DF.EnforceCenterAnchor then DF:EnforceCenterAnchor() end
        end), 30, 1)
        Add(GUI:CreateLabel(self.child, "When party/raid members join or leave, frames expand outward from center instead of one direction.", 300), 50, 1)

        -- COLUMN 2: Positioning Help
        Add(GUI:CreateHeader(self, "Frame Positioning"), 30, 2)
        Add(GUI:CreateLabel(self.child, "Use Blizzard's Edit Mode to position your frames on screen.", 280), 40, 2)
        Add(GUI:CreateButton(self, "Open Edit Mode", 200, 32, function()
             if InCombatLockdown() then return end
             if EditModeManagerFrame then ShowUIPanel(EditModeManagerFrame) end
        end), 40, 2)
    end)

    -- TAB 2: HEALTH BAR (Contains all health bar appearance settings)
    BuildPage(CreateTab("healthbar", "Health Bar"), function(self, db, Add, AddSpace)
        -- COLUMN 1: Health Bar Appearance
        Add(GUI:CreateHeader(self, "Health Bar Colors"), 30, 1)
        Add(GUI:CreateDropdown(self, "Color Mode", {
            ["CLASS"] = "Class Colors", ["CUSTOM"] = "Custom Color", ["PERCENT"] = "Gradient"
        }, db, "healthColorMode"), 60)

        Add(GUI:CreateDropdown(self, "Bar Texture", DF:GetTextureList(), db, "healthTexture", nil, true), 60)
        
        Add(GUI:CreateDropdown(self, "Fill Direction", {
            ["HORIZONTAL"] = "Left to Right",
            ["HORIZONTAL_INV"] = "Right to Left",
            ["VERTICAL"] = "Bottom to Top",
            ["VERTICAL_INV"] = "Top to Bottom",
        }, db, "healthOrientation"), 60)
        
        local customCol = Add(GUI:CreateColorPicker(self, "Custom Health Color", db, "healthColor", true), 30)
        customCol.hideOn = function(d) return d.healthColorMode ~= "CUSTOM" end
        
        local barAlpha = Add(GUI:CreateSlider(self, "Bar Alpha", 0, 1, 0.05, db, "classColorAlpha"), 60)
        barAlpha.hideOn = function(d) return d.healthColorMode == "CUSTOM" end
        
        AddSpace(20, 1)
        local gradHeader = Add(GUI:CreateHeader(self, "Gradient Colors"), 30)
        gradHeader.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        
        local descText = "Weights control the color distribution."
        local desc = Add(GUI:CreateLabel(self.child, descText, 315), 65)
        desc.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        
        local previewBar = GUI:CreateGradientBar(self.child, 315, 20, db)
        local pBar = Add(previewBar, 40)
        pBar.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        
        local function UpdatePreview()
            DF:UpdateColorCurve()
            if previewBar.UpdatePreview then previewBar.UpdatePreview() end
        end
        
        local cHighCB = Add(GUI:CreateCheckbox(self, "Use Class Color (High)", db, "healthColorHighUseClass", UpdatePreview), 30)
        cHighCB.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        local cHigh = Add(GUI:CreateColorPicker(self, "High Health Color", db, "healthColorHigh", false, UpdatePreview), 30)
        cHigh.hideOn = function(d) return d.healthColorMode ~= "PERCENT" or d.healthColorHighUseClass end
        local wHigh = Add(GUI:CreateSlider(self, "High Color Weight", 1, 10, 1, db, "healthColorHighWeight", UpdatePreview), 60)
        wHigh.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end

        local cMedCB = Add(GUI:CreateCheckbox(self, "Use Class Color (Medium)", db, "healthColorMediumUseClass", UpdatePreview), 30)
        cMedCB.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        local cMed = Add(GUI:CreateColorPicker(self, "Medium Health Color", db, "healthColorMedium", false, UpdatePreview), 30)
        cMed.hideOn = function(d) return d.healthColorMode ~= "PERCENT" or d.healthColorMediumUseClass end
        local wMed = Add(GUI:CreateSlider(self, "Med Color Weight", 1, 10, 1, db, "healthColorMediumWeight", UpdatePreview), 60)
        wMed.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end

        local cLowCB = Add(GUI:CreateCheckbox(self, "Use Class Color (Low)", db, "healthColorLowUseClass", UpdatePreview), 30)
        cLowCB.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        local cLow = Add(GUI:CreateColorPicker(self, "Low Health Color", db, "healthColorLow", false, UpdatePreview), 30)
        cLow.hideOn = function(d) return d.healthColorMode ~= "PERCENT" or d.healthColorLowUseClass end
        local wLow = Add(GUI:CreateSlider(self, "Low Color Weight", 1, 10, 1, db, "healthColorLowWeight", UpdatePreview), 60)
        wLow.hideOn = function(d) return d.healthColorMode ~= "PERCENT" end
        
        -- COLUMN 2: Background & Padding
        Add(GUI:CreateHeader(self, "Background"), 30, 2)
        Add(GUI:CreateCheckbox(self, "Enable Background Color", db, "enableTextureColor"), 30, 2)
        local classBg = Add(GUI:CreateCheckbox(self, "Class Color Background", db, "backgroundClassColor"), 30, 2)
        classBg.disableOn = function(d) return not d.enableTextureColor end
        local cBg = Add(GUI:CreateColorPicker(self, "Background Color", db, "textureColor", true), 30, 2)
        cBg.disableOn = function(d) return not d.enableTextureColor or d.backgroundClassColor end
        
        AddSpace(20, 2)
        
        Add(GUI:CreateHeader(self, "Health Bar Padding"), 30, 2)
        Add(GUI:CreateCheckbox(self, "Use Specific Side Padding", db, "useSpecificPadding", function() GUI:RefreshCurrentPage() end), 30, 2)
        
        local framePad = Add(GUI:CreateSlider(self, "Frame Padding (All)", 0, 20, 1, db, "framePadding"), 60, 2)
        framePad.hideOn = function(d) return d.useSpecificPadding end
        
        local pTop = Add(GUI:CreateSlider(self, "Padding Top", 0, 20, 1, db, "paddingTop"), 60, 2)
        pTop.hideOn = function(d) return not d.useSpecificPadding end
        local pBot = Add(GUI:CreateSlider(self, "Padding Bottom", 0, 20, 1, db, "paddingBottom"), 60, 2)
        pBot.hideOn = function(d) return not d.useSpecificPadding end
        local pLeft = Add(GUI:CreateSlider(self, "Padding Left", 0, 20, 1, db, "paddingLeft"), 60, 2)
        pLeft.hideOn = function(d) return not d.useSpecificPadding end
        local pRight = Add(GUI:CreateSlider(self, "Padding Right", 0, 20, 1, db, "paddingRight"), 60, 2)
        pRight.hideOn = function(d) return not d.useSpecificPadding end
    end)

    -- TAB 2: AURAS
    BuildPage(CreateTab("auras", "Auras"), function(self, db, Add, AddSpace)
        -- COLUMN 1: Buffs
        Add(GUI:CreateHeader(self, "Buffs"), 30, 1)
        Add(GUI:CreateSlider(self, "Scale", 0.5, 2.0, 0.1, db, "raidBuffScale"), 60, 1)
        Add(GUI:CreateSlider(self, "Max Shown", 1, 20, 1, db, "raidBuffMax"), 60, 1)
        Add(GUI:CreateDropdown(self, "Position", {
            ["TOPLEFT"] = "Top Left", ["TOPRIGHT"] = "Top Right",
            ["BOTTOMLEFT"] = "Bottom Left", ["BOTTOMRIGHT"] = "Bottom Right",
            ["LEFT"] = "Left", ["RIGHT"] = "Right", ["CENTER"] = "Center"
        }, db, "raidBuffAnchor"), 60, 1)
        Add(GUI:CreateDropdown(self, "Growth", {
            ["LEFT_DOWN"] = "Left / Down", ["LEFT_UP"] = "Left / Up",
            ["RIGHT_DOWN"] = "Right / Down", ["RIGHT_UP"] = "Right / Up",
        }, db, "raidBuffGrowth"), 60, 1)
        
        AddSpace(10, 1)
        Add(GUI:CreateCheckbox(self, "Show Advanced Buff Options", db, "showAdvancedBuffOptions", function() GUI:RefreshCurrentPage() end), 30, 1)
        
        -- Advanced Buff Options (hidden by default)
        local bAlpha = Add(GUI:CreateSlider(self, "Alpha", 0.1, 1.0, 0.05, db, "raidBuffAlpha"), 60, 1)
        bAlpha.hideOn = function(d) return not d.showAdvancedBuffOptions end
        local bWrap = Add(GUI:CreateSlider(self, "Wrap After", 1, 20, 1, db, "raidBuffWrap"), 60, 1)
        bWrap.hideOn = function(d) return not d.showAdvancedBuffOptions end
        local bOffX = Add(GUI:CreateSlider(self, "Offset X", -50, 50, 1, db, "raidBuffOffsetX"), 60, 1)
        bOffX.hideOn = function(d) return not d.showAdvancedBuffOptions end
        local bOffY = Add(GUI:CreateSlider(self, "Offset Y", -50, 50, 1, db, "raidBuffOffsetY"), 60, 1)
        bOffY.hideOn = function(d) return not d.showAdvancedBuffOptions end
        local bClick = Add(GUI:CreateCheckbox(self, "Click Through", db, "raidBuffClickThrough"), 30, 1)
        bClick.hideOn = function(d) return not d.showAdvancedBuffOptions end
        
        -- Buff Stack Text (hidden by default)
        local bStackHeader = Add(GUI:CreateHeader(self, "Buff Stack Text"), 25, 1)
        bStackHeader.hideOn = function(d) return not d.showAdvancedBuffOptions end
        local bStackScale = Add(GUI:CreateSlider(self, "Stack Scale", 0.5, 2.0, 0.1, db, "raidBuffStackScale"), 60, 1)
        bStackScale.hideOn = function(d) return not d.showAdvancedBuffOptions end
        local bStackFont = Add(GUI:CreateDropdown(self, "Stack Font", DF:GetFontList(), db, "raidBuffStackFont"), 60, 1)
        bStackFont.hideOn = function(d) return not d.showAdvancedBuffOptions end
        local bStackOut = Add(GUI:CreateDropdown(self, "Stack Outline", {
            ["NONE"] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick"
        }, db, "raidBuffStackOutline"), 60, 1)
        bStackOut.hideOn = function(d) return not d.showAdvancedBuffOptions end
        
        -- Buff Countdown Text Options
        local bCdHeader = Add(GUI:CreateHeader(self, "Buff Countdown Text"), 25, 1)
        bCdHeader.hideOn = function(d) return not d.showAdvancedBuffOptions end
        local bCountdown = Add(GUI:CreateCheckbox(self, "Show Countdown", db, "raidBuffShowCountdown"), 30, 1)
        bCountdown.hideOn = function(d) return not d.showAdvancedBuffOptions end
        local countdownFormats = {
            ["TENTHS"] = "Tenths (<3s)",
            ["WHOLE"] = "Whole Seconds",
        }
        local bCdScale = Add(GUI:CreateSlider(self, "Countdown Scale", 0.5, 2.0, 0.1, db, "raidBuffCountdownScale"), 60, 1)
        bCdScale.hideOn = function(d) return not d.showAdvancedBuffOptions or not d.raidBuffShowCountdown end
        local bCdFont = Add(GUI:CreateDropdown(self, "Countdown Font", DF:GetFontList(), db, "raidBuffCountdownFont"), 60, 1)
        bCdFont.hideOn = function(d) return not d.showAdvancedBuffOptions or not d.raidBuffShowCountdown end
        local bCdOutline = Add(GUI:CreateDropdown(self, "Countdown Outline", {
            ["NONE"] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick"
        }, db, "raidBuffCountdownOutline"), 60, 1)
        bCdOutline.hideOn = function(d) return not d.showAdvancedBuffOptions or not d.raidBuffShowCountdown end
        local bCdOffX = Add(GUI:CreateSlider(self, "Countdown X", -20, 20, 1, db, "raidBuffCountdownX"), 60, 1)
        bCdOffX.hideOn = function(d) return not d.showAdvancedBuffOptions or not d.raidBuffShowCountdown end
        local bCdOffY = Add(GUI:CreateSlider(self, "Countdown Y", -20, 20, 1, db, "raidBuffCountdownY"), 60, 1)
        bCdOffY.hideOn = function(d) return not d.showAdvancedBuffOptions or not d.raidBuffShowCountdown end
        local bCdFormat = Add(GUI:CreateDropdown(self, "Countdown Decimals", countdownFormats, db, "raidBuffCountdownDecimalMode"), 60, 1)
        bCdFormat.hideOn = function(d) return not d.showAdvancedBuffOptions or not d.raidBuffShowCountdown end
        local bHideSwipe = Add(GUI:CreateCheckbox(self, "Hide Cooldown Swipe", db, "raidBuffHideSwipe"), 30, 1)
        bHideSwipe.hideOn = function(d) return not d.showAdvancedBuffOptions end
        
        -- COLUMN 2: Debuffs
        Add(GUI:CreateHeader(self, "Debuffs"), 30, 2)
        Add(GUI:CreateSlider(self, "Scale", 0.5, 2.0, 0.1, db, "raidDebuffScale"), 60, 2)
        Add(GUI:CreateSlider(self, "Max Shown", 1, 20, 1, db, "raidDebuffMax"), 60, 2)
        Add(GUI:CreateDropdown(self, "Position", {
            ["TOPLEFT"] = "Top Left", ["TOPRIGHT"] = "Top Right",
            ["BOTTOMLEFT"] = "Bottom Left", ["BOTTOMRIGHT"] = "Bottom Right",
            ["LEFT"] = "Left", ["RIGHT"] = "Right", ["CENTER"] = "Center"
        }, db, "raidDebuffAnchor"), 60, 2)
        Add(GUI:CreateDropdown(self, "Growth", {
            ["LEFT_DOWN"] = "Left / Down", ["LEFT_UP"] = "Left / Up",
            ["RIGHT_DOWN"] = "Right / Down", ["RIGHT_UP"] = "Right / Up",
        }, db, "raidDebuffGrowth"), 60, 2)
        
        AddSpace(10, 2)
        Add(GUI:CreateCheckbox(self, "Show Advanced Debuff Options", db, "showAdvancedDebuffOptions", function() GUI:RefreshCurrentPage() end), 30, 2)
        
        -- Advanced Debuff Options (hidden by default)
        local dAlpha = Add(GUI:CreateSlider(self, "Alpha", 0.1, 1.0, 0.05, db, "raidDebuffAlpha"), 60, 2)
        dAlpha.hideOn = function(d) return not d.showAdvancedDebuffOptions end
        local dWrap = Add(GUI:CreateSlider(self, "Wrap After", 1, 20, 1, db, "raidDebuffWrap"), 60, 2)
        dWrap.hideOn = function(d) return not d.showAdvancedDebuffOptions end
        local dOffX = Add(GUI:CreateSlider(self, "Offset X", -50, 50, 1, db, "raidDebuffOffsetX"), 60, 2)
        dOffX.hideOn = function(d) return not d.showAdvancedDebuffOptions end
        local dOffY = Add(GUI:CreateSlider(self, "Offset Y", -50, 50, 1, db, "raidDebuffOffsetY"), 60, 2)
        dOffY.hideOn = function(d) return not d.showAdvancedDebuffOptions end
        local dClick = Add(GUI:CreateCheckbox(self, "Click Through", db, "raidDebuffClickThrough"), 30, 2)
        dClick.hideOn = function(d) return not d.showAdvancedDebuffOptions end
        
        -- Debuff Stack Text (hidden by default)
        local dStackHeader = Add(GUI:CreateHeader(self, "Debuff Stack Text"), 25, 2)
        dStackHeader.hideOn = function(d) return not d.showAdvancedDebuffOptions end
        local dStackScale = Add(GUI:CreateSlider(self, "Stack Scale", 0.5, 2.0, 0.1, db, "raidDebuffStackScale"), 60, 2)
        dStackScale.hideOn = function(d) return not d.showAdvancedDebuffOptions end
        local dStackFont = Add(GUI:CreateDropdown(self, "Stack Font", DF:GetFontList(), db, "raidDebuffStackFont"), 60, 2)
        dStackFont.hideOn = function(d) return not d.showAdvancedDebuffOptions end
        local dStackOut = Add(GUI:CreateDropdown(self, "Stack Outline", {
            ["NONE"] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick"
        }, db, "raidDebuffStackOutline"), 60, 2)
        dStackOut.hideOn = function(d) return not d.showAdvancedDebuffOptions end
        
        -- Debuff Countdown Text Options
        local dCdHeader = Add(GUI:CreateHeader(self, "Debuff Countdown Text"), 25, 2)
        dCdHeader.hideOn = function(d) return not d.showAdvancedDebuffOptions end
        local dCountdown = Add(GUI:CreateCheckbox(self, "Show Countdown", db, "raidDebuffShowCountdown"), 30, 2)
        dCountdown.hideOn = function(d) return not d.showAdvancedDebuffOptions end
        local dCdScale = Add(GUI:CreateSlider(self, "Countdown Scale", 0.5, 2.0, 0.1, db, "raidDebuffCountdownScale"), 60, 2)
        dCdScale.hideOn = function(d) return not d.showAdvancedDebuffOptions or not d.raidDebuffShowCountdown end
        local dCdFont = Add(GUI:CreateDropdown(self, "Countdown Font", DF:GetFontList(), db, "raidDebuffCountdownFont"), 60, 2)
        dCdFont.hideOn = function(d) return not d.showAdvancedDebuffOptions or not d.raidDebuffShowCountdown end
        local dCdOutline = Add(GUI:CreateDropdown(self, "Countdown Outline", {
            ["NONE"] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick"
        }, db, "raidDebuffCountdownOutline"), 60, 2)
        dCdOutline.hideOn = function(d) return not d.showAdvancedDebuffOptions or not d.raidDebuffShowCountdown end
        local dCdOffX = Add(GUI:CreateSlider(self, "Countdown X", -20, 20, 1, db, "raidDebuffCountdownX"), 60, 2)
        dCdOffX.hideOn = function(d) return not d.showAdvancedDebuffOptions or not d.raidDebuffShowCountdown end
        local dCdOffY = Add(GUI:CreateSlider(self, "Countdown Y", -20, 20, 1, db, "raidDebuffCountdownY"), 60, 2)
        dCdOffY.hideOn = function(d) return not d.showAdvancedDebuffOptions or not d.raidDebuffShowCountdown end
        local dCdFormat = Add(GUI:CreateDropdown(self, "Countdown Decimals", countdownFormats, db, "raidDebuffCountdownDecimalMode"), 60, 2)
        dCdFormat.hideOn = function(d) return not d.showAdvancedDebuffOptions or not d.raidDebuffShowCountdown end
        local dHideSwipe = Add(GUI:CreateCheckbox(self, "Hide Cooldown Swipe", db, "raidDebuffHideSwipe"), 30, 2)
        dHideSwipe.hideOn = function(d) return not d.showAdvancedDebuffOptions end
    end)
    
    -- TAB 2.5: DISPELS
    BuildPage(CreateTab("dispels", "Dispels"), function(self, db, Add, AddSpace)
        -- Column 1: Preview/Demo Settings (First)
        Add(GUI:CreateHeader(self, "Preview Settings"), 30, 1)
        Add(GUI:CreateCheckbox(self, "Show Dispel Overlay Frame Demo", db, "showDispelOverlay", function() DF:UpdateAll() end), 30, 1)
        Add(GUI:CreateLabel(self.child, "Shows a demo dispel icon on frames. Requires 'Show Dispel Icon' to be enabled. Has no effect on actual combat icons.", 280), 55, 1)
        
        AddSpace(20, 1)
        
        -- Combat Dispel Icons
        Add(GUI:CreateHeader(self, "Combat Dispel Icons"), 30, 1)
        Add(GUI:CreateCheckbox(self, "Show Dispel Icon (In Combat)", db, "showDispelIcon", function() DF:UpdateAll() end), 30, 1)
        Add(GUI:CreateLabel(self.child, "Controls whether dispel icons appear on frames during combat.", 280), 40, 1)
        
        -- Column 2: Overlay Visual Effects (All grouped together)
        Add(GUI:CreateHeader(self, "Overlay Visual Effects"), 30, 2)
        Add(GUI:CreateLabel(self.child, "These settings control the colored border/gradient effect that appears when a dispellable debuff is present.", 280), 55, 2)
        AddSpace(10, 2)
        Add(GUI:CreateCheckbox(self, "Show Background", db, "showDispelBackground"), 30, 2)
        Add(GUI:CreateCheckbox(self, "Show Border", db, "showDispelBorder"), 30, 2)
        Add(GUI:CreateCheckbox(self, "Show Gradient", db, "showDispelGradient"), 30, 2)
    end)

    -- TAB 3: HEALTH TEXT
    BuildPage(CreateTab("healthtext", "Health Text"), function(self, db, Add, AddSpace)
        Add(GUI:CreateHeader(self, "Visibility & Style"), 30)
        Add(GUI:CreateCheckbox(self, "Hide Completely", db, "healthTextHide"), 30)
        local cbEnable = Add(GUI:CreateCheckbox(self, "Enable Custom Text", db, "healthTextEnabled"), 30)
        cbEnable.disableOn = function(d) return d.healthTextHide end
        
        local showStatus = Add(GUI:CreateCheckbox(self, "Show Status Text (Dead/Offline/Ghost)", db, "showStatusText"), 30)
        showStatus.disableOn = function(d) return not d.healthTextHide end
        
        AddSpace(20, 1)
        
        local fmt = Add(GUI:CreateDropdown(self, "Format", {
            ["Current"] = "Current", ["Percent"] = "Percent",
            ["CurrentMax"] = "Curr / Max", ["Deficit"] = "Deficit"
        }, db, "healthTextFormat", function() self:RefreshStates() end), 60)
        fmt.disableOn = function(d) return d.healthTextHide or not d.healthTextEnabled end
        
        -- NEW: Abbreviate Numbers Checkbox
        local abbrev = Add(GUI:CreateCheckbox(self, "Abbreviate Numbers", db, "healthTextAbbreviate"), 30)
        abbrev.disableOn = function(d) return d.healthTextHide or not d.healthTextEnabled or d.healthTextFormat == "Percent" end

        local font = Add(GUI:CreateDropdown(self, "Font Face", DF:GetFontList(), db, "healthTextFont"), 60)
        font.disableOn = function(d) return d.healthTextHide or not d.healthTextEnabled end
        
        local out = Add(GUI:CreateDropdown(self, "Outline", {
            ["NONE"] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick", ["MONOCHROME"] = "Mono"
        }, db, "healthTextOutline"), 60)
        out.disableOn = function(d) return d.healthTextHide or not d.healthTextEnabled end
        local scale = Add(GUI:CreateSlider(self, "Font Scale", 0.5, 2.5, 0.1, db, "healthTextScale"), 60)
        scale.disableOn = function(d) return d.healthTextHide or not d.healthTextEnabled end
        
        Add(GUI:CreateHeader(self, "Position & Color"), 30, 2)
        local anch = Add(GUI:CreateDropdown(self, "Anchor", {
            ["CENTER"]="Center", ["LEFT"]="Left", ["RIGHT"]="Right", ["TOP"]="Top", ["BOTTOM"]="Bottom"
        }, db, "healthTextAnchor"), 60, 2)
        anch.disableOn = function(d) return d.healthTextHide or not d.healthTextEnabled end
        local offX = Add(GUI:CreateSlider(self, "Offset X", -100, 100, 1, db, "healthTextX"), 60, 2)
        offX.disableOn = function(d) return d.healthTextHide or not d.healthTextEnabled end
        local offY = Add(GUI:CreateSlider(self, "Offset Y", -100, 100, 1, db, "healthTextY"), 60, 2)
        offY.disableOn = function(d) return d.healthTextHide or not d.healthTextEnabled end
        
        AddSpace(20, 2)
        
        local useClass = Add(GUI:CreateCheckbox(self, "Use Class Color", db, "healthTextUseClassColor"), 30, 2)
        useClass.disableOn = function(d) return d.healthTextHide or not d.healthTextEnabled end
        local colPick = Add(GUI:CreateColorPicker(self, "Custom Text Color", db, "healthTextColor", false), 30, 2)
        colPick.disableOn = function(d) return d.healthTextHide or not d.healthTextEnabled or d.healthTextUseClassColor end
    end)

    -- TAB 4: NAME TEXT
    BuildPage(CreateTab("nametext", "Name Text"), function(self, db, Add, AddSpace)
        Add(GUI:CreateHeader(self, "Visibility & Style"), 30)
        Add(GUI:CreateCheckbox(self, "Hide Name", db, "nameTextHide"), 30)
        local realm = Add(GUI:CreateCheckbox(self, "Show Realm", db, "nameTextShowRealm"), 30)
        realm.disableOn = function(d) return d.nameTextHide end
        
        AddSpace(20, 1)
        
        local font = Add(GUI:CreateDropdown(self, "Font Face", DF:GetFontList(), db, "nameTextFont"), 60)
        font.disableOn = function(d) return d.nameTextHide end
        
        local out = Add(GUI:CreateDropdown(self, "Outline", {
            ["NONE"] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick"
        }, db, "nameTextOutline"), 60)
        out.disableOn = function(d) return d.nameTextHide end
        local scale = Add(GUI:CreateSlider(self, "Font Scale", 0.5, 2.5, 0.1, db, "nameTextScale"), 60)
        scale.disableOn = function(d) return d.nameTextHide end
        
        local len = Add(GUI:CreateSlider(self, "Max Length (0 = Unlimited)", 0, 20, 1, db, "nameTextLength", function() self:RefreshStates() end), 60)
        len.disableOn = function(d) return d.nameTextHide end
        
        local trunc = Add(GUI:CreateDropdown(self, "Length Mode", {
            ["ELLIPSIS"] = "Truncate with ...",
            ["CLIP"] = "Truncate (Clip)",
            ["WRAP"] = "Wrap to New Line"
        }, db, "nameTextTruncateMode", function() self:RefreshStates() end), 60)
        trunc.hideOn = function(d) return d.nameTextHide or d.nameTextLength == 0 end
        
        local wAlign = Add(GUI:CreateDropdown(self, "Wrap Alignment", {
            ["LEFT"] = "Left", ["CENTER"] = "Center", ["RIGHT"] = "Right"
        }, db, "nameTextWrapAlign"), 60)
        wAlign.hideOn = function(d) return d.nameTextHide or d.nameTextTruncateMode ~= "WRAP" or d.nameTextLength == 0 end

        local wDir = Add(GUI:CreateDropdown(self, "Wrap Direction", {
            ["DOWN"] = "Down (Normal)", ["UP"] = "Up (Inverted)"
        }, db, "nameTextWrapDirection"), 60)
        wDir.hideOn = function(d) return d.nameTextHide or d.nameTextTruncateMode ~= "WRAP" or d.nameTextLength == 0 end
        
        Add(GUI:CreateHeader(self, "Position & Color"), 30, 2)
        local override = Add(GUI:CreateCheckbox(self, "Override Position", db, "nameTextEnabled"), 30, 2)
        override.disableOn = function(d) return d.nameTextHide end
        local anch = Add(GUI:CreateDropdown(self, "Anchor", {
            ["CENTER"]="Center", ["LEFT"]="Left", ["RIGHT"]="Right", ["TOP"]="Top", ["BOTTOM"]="Bottom"
        }, db, "nameTextAnchor"), 60, 2)
        anch.disableOn = function(d) return d.nameTextHide or not d.nameTextEnabled end
        local x = Add(GUI:CreateSlider(self, "Offset X", -100, 100, 1, db, "nameTextX"), 60, 2)
        x.disableOn = function(d) return d.nameTextHide or not d.nameTextEnabled end
        local y = Add(GUI:CreateSlider(self, "Offset Y", -100, 100, 1, db, "nameTextY"), 60, 2)
        y.disableOn = function(d) return d.nameTextHide or not d.nameTextEnabled end
        
        AddSpace(20, 2)
        
        local useClass = Add(GUI:CreateCheckbox(self, "Use Class Color", db, "nameTextUseClassColor"), 30, 2)
        useClass.disableOn = function(d) return d.nameTextHide end
        local col = Add(GUI:CreateColorPicker(self, "Custom Name Color", db, "nameTextColor", false), 30, 2)
        col.disableOn = function(d) return d.nameTextHide or d.nameTextUseClassColor end
    end)

    -- TAB 5: RESOURCE BAR
    BuildPage(CreateTab("resource", "Resource Bar"), function(self, db, Add, AddSpace)
        Add(GUI:CreateHeader(self, "Custom Power Bar"), 30)
        Add(GUI:CreateCheckbox(self, "Show Resource Bar", db, "resourceBarEnabled"), 30)
        local heal = Add(GUI:CreateCheckbox(self, "Healer Only", db, "resourceBarHealerOnly"), 30)
        heal.disableOn = function(d) return not d.resourceBarEnabled end
        
        -- NEW ORIENTATION OPTIONS
        local orient = Add(GUI:CreateDropdown(self, "Orientation", {
            ["HORIZONTAL"] = "Horizontal", ["VERTICAL"] = "Vertical"
        }, db, "resourceBarOrientation", function() GUI:RefreshCurrentPage() end), 60)
        orient.disableOn = function(d) return not d.resourceBarEnabled end

        local rev = Add(GUI:CreateCheckbox(self, "Reverse Fill", db, "resourceBarReverseFill"), 30)
        rev.disableOn = function(d) return not d.resourceBarEnabled end

        AddSpace(20, 1)

        -- Determine Orientation Mode
        local isVertical = (db.resourceBarOrientation == "VERTICAL")
        
        -- Dynamic Label for Match Checkbox
        local matchLabel = isVertical and "Match Frame Height" or "Match Frame Width"
        local match = Add(GUI:CreateCheckbox(self, matchLabel, db, "resourceBarMatchWidth"), 30)
        match.disableOn = function(d) return not d.resourceBarEnabled end
        
        -- Dynamic Sliders
        -- "Width" slider now represents "Length" (Horizontal) or "Length" (Vertical Height)
        -- "Height" slider now represents "Thickness" (Vertical Thickness) or "Thickness" (Horizontal Width)
        local wLabel = isVertical and "Length" or "Width"
        local hLabel = isVertical and "Thickness" or "Height"
        
        local w = Add(GUI:CreateSlider(self, wLabel, 10, 200, 1, db, "resourceBarWidth"), 60)
        w.disableOn = function(d) return not d.resourceBarEnabled or d.resourceBarMatchWidth end
        
        local h = Add(GUI:CreateSlider(self, hLabel, 1, 30, 1, db, "resourceBarHeight"), 60)
        h.disableOn = function(d) return not d.resourceBarEnabled end
        
        Add(GUI:CreateHeader(self, "Positioning"), 30, 2)
        local anch = Add(GUI:CreateDropdown(self, "Anchor", {
             ["CENTER"]="Center", ["BOTTOM"]="Bottom", ["TOP"]="Top", ["LEFT"]="Left", ["RIGHT"]="Right"
        }, db, "resourceBarAnchor"), 60, 2)
        anch.disableOn = function(d) return not d.resourceBarEnabled end
        local x = Add(GUI:CreateSlider(self, "Offset X", -50, 50, 1, db, "resourceBarX"), 60, 2)
        x.disableOn = function(d) return not d.resourceBarEnabled end
        local y = Add(GUI:CreateSlider(self, "Offset Y", -50, 50, 1, db, "resourceBarY"), 60, 2)
        y.disableOn = function(d) return not d.resourceBarEnabled end
    end)
    
    -- TAB 6: ABSORBS (REVAMPED)
    BuildPage(CreateTab("absorbs", "Absorbs"), function(self, db, Add, AddSpace)
        
        -- ============================================================
        -- COLUMN 1: ABSORB BAR (Shields)
        -- ============================================================
        Add(GUI:CreateHeader(self, "Absorb Bar (Shields)"), 30, 1)
        
        local modeDropdown = Add(GUI:CreateDropdown(self, "Display Mode", {
            ["OVERLAY"] = "Overlay (Match Health)",
            ["FLOATING"] = "Floating Bar",
            ["BLIZZARD"] = "Blizzard Default"
        }, db, "absorbBarMode", function() DF:UpdateAll() GUI:RefreshCurrentPage() end), 60, 1)

        -- Texture & Color (Hidden if Blizzard Mode)
        local tex = Add(GUI:CreateDropdown(self, "Bar Texture", DF:GetTextureList(), db, "absorbBarTexture", nil, true), 60, 1)
        tex.hideOn = function(d) return d.absorbBarMode == "BLIZZARD" end
        
        local col = Add(GUI:CreateColorPicker(self, "Bar Color", db, "absorbBarColor", true), 30, 1)
        col.hideOn = function(d) return d.absorbBarMode == "BLIZZARD" end

        -- Overlay Specific: Reverse Fill
        local overlayRev = Add(GUI:CreateCheckbox(self, "Reverse Fill Direction", db, "absorbBarOverlayReverse"), 30, 1)
        overlayRev.hideOn = function(d) return d.absorbBarMode ~= "OVERLAY" end

        -- Floating Specifics
        local orient = Add(GUI:CreateDropdown(self, "Orientation", {
            ["HORIZONTAL"] = "Horizontal", ["VERTICAL"] = "Vertical"
        }, db, "absorbBarOrientation"), 60, 1)
        orient.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

        local rev = Add(GUI:CreateCheckbox(self, "Reverse Fill", db, "absorbBarReverse"), 30, 1)
        rev.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

        local w = Add(GUI:CreateSlider(self, "Width / Length", 1, 200, 1, db, "absorbBarWidth"), 60, 1)
        w.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local h = Add(GUI:CreateSlider(self, "Height / Thickness", 1, 50, 1, db, "absorbBarHeight"), 60, 1)
        h.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

        local bgCol = Add(GUI:CreateColorPicker(self, "Background Color", db, "absorbBarBackgroundColor", true, function() DF:UpdateAll() end), 30, 1)
        bgCol.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

        local strata = Add(GUI:CreateDropdown(self, "Frame Strata", {
            ["BACKGROUND"] = "Background",
            ["LOW"] = "Low",
            ["MEDIUM"] = "Medium",
            ["HIGH"] = "High",
            ["DIALOG"] = "Dialog",
            ["SANDWICH"] = "Between Health & Dispel",
            ["SANDWICH_LOW"] = "Under Dispel Overlay"
        }, db, "absorbBarStrata"), 60, 1)
        strata.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end

        local anch = Add(GUI:CreateDropdown(self, "Anchor", {
             ["CENTER"]="Center", ["BOTTOM"]="Bottom", ["TOP"]="Top", ["LEFT"]="Left", ["RIGHT"]="Right",
             ["TOPLEFT"]="Top Left", ["TOPRIGHT"]="Top Right", ["BOTTOMLEFT"]="Bottom Left", ["BOTTOMRIGHT"]="Bottom Right"
        }, db, "absorbBarAnchor"), 60, 1)
        anch.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local x = Add(GUI:CreateSlider(self, "Offset X", -100, 100, 1, db, "absorbBarX"), 60, 1)
        x.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        local y = Add(GUI:CreateSlider(self, "Offset Y", -100, 100, 1, db, "absorbBarY"), 60, 1)
        y.hideOn = function(d) return d.absorbBarMode ~= "FLOATING" end
        
        -- ============================================================
        -- COLUMN 2: HEAL ABSORB BAR (Necrotic)
        -- ============================================================
        Add(GUI:CreateHeader(self, "Heal Absorb Bar (Necrotic)"), 30, 2)
        
        local healModeDropdown = Add(GUI:CreateDropdown(self, "Display Mode", {
            ["OVERLAY"] = "Overlay (Match Health)",
            ["FLOATING"] = "Floating Bar",
            ["BLIZZARD"] = "Blizzard Default"
        }, db, "healAbsorbBarMode", function() DF:UpdateAll() GUI:RefreshCurrentPage() end), 60, 2)

        -- Texture & Color (Hidden if Blizzard Mode)
        local healTex = Add(GUI:CreateDropdown(self, "Bar Texture", DF:GetTextureList(), db, "healAbsorbBarTexture", nil, true), 60, 2)
        healTex.hideOn = function(d) return d.healAbsorbBarMode == "BLIZZARD" end
        
        local healCol = Add(GUI:CreateColorPicker(self, "Bar Color", db, "healAbsorbBarColor", true), 30, 2)
        healCol.hideOn = function(d) return d.healAbsorbBarMode == "BLIZZARD" end

        -- Overlay Specific: Reverse Fill
        local healOverlayRev = Add(GUI:CreateCheckbox(self, "Reverse Fill Direction", db, "healAbsorbBarOverlayReverse"), 30, 2)
        healOverlayRev.hideOn = function(d) return d.healAbsorbBarMode ~= "OVERLAY" end

        -- Floating Specifics
        local healOrient = Add(GUI:CreateDropdown(self, "Orientation", {
            ["HORIZONTAL"] = "Horizontal", ["VERTICAL"] = "Vertical"
        }, db, "healAbsorbBarOrientation"), 60, 2)
        healOrient.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

        local healRev = Add(GUI:CreateCheckbox(self, "Reverse Fill", db, "healAbsorbBarReverse"), 30, 2)
        healRev.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

        local healW = Add(GUI:CreateSlider(self, "Width / Length", 1, 200, 1, db, "healAbsorbBarWidth"), 60, 2)
        healW.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healH = Add(GUI:CreateSlider(self, "Height / Thickness", 1, 50, 1, db, "healAbsorbBarHeight"), 60, 2)
        healH.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

        local healBgCol = Add(GUI:CreateColorPicker(self, "Background Color", db, "healAbsorbBarBackgroundColor", true, function() DF:UpdateAll() end), 30, 2)
        healBgCol.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

        local healStrata = Add(GUI:CreateDropdown(self, "Frame Strata", {
            ["BACKGROUND"] = "Background",
            ["LOW"] = "Low",
            ["MEDIUM"] = "Medium",
            ["HIGH"] = "High",
            ["DIALOG"] = "Dialog",
            ["SANDWICH"] = "Between Health & Dispel",
            ["SANDWICH_LOW"] = "Under Dispel Overlay"
        }, db, "healAbsorbBarStrata"), 60, 2)
        healStrata.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end

        local healAnch = Add(GUI:CreateDropdown(self, "Anchor", {
             ["CENTER"]="Center", ["BOTTOM"]="Bottom", ["TOP"]="Top", ["LEFT"]="Left", ["RIGHT"]="Right",
             ["TOPLEFT"]="Top Left", ["TOPRIGHT"]="Top Right", ["BOTTOMLEFT"]="Bottom Left", ["BOTTOMRIGHT"]="Bottom Right"
        }, db, "healAbsorbBarAnchor"), 60, 2)
        healAnch.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healX = Add(GUI:CreateSlider(self, "Offset X", -100, 100, 1, db, "healAbsorbBarX"), 60, 2)
        healX.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        local healY = Add(GUI:CreateSlider(self, "Offset Y", -100, 100, 1, db, "healAbsorbBarY"), 60, 2)
        healY.hideOn = function(d) return d.healAbsorbBarMode ~= "FLOATING" end
        
        -- ============================================================
        -- ABSORB GLOW (Full Width at Bottom)
        -- ============================================================
        AddSpace(20, "both")
        
        Add(GUI:CreateHeader(self, "Absorb Glow"), 30, "both")
        
        Add(GUI:CreateSlider(self, "Glow Alpha", 0, 1, 0.05, db, "absorbGlowAlpha"), 60)
        
        local matchHealth = Add(GUI:CreateCheckbox(self, "Match Health Orientation (Glow)", db, "absorbMatchHealthOrientation", function() GUI:RefreshCurrentPage() end), 30)
        
        local anchorDropdown = Add(GUI:CreateDropdown(self, "Glow Anchor", {
            ["LEFT"] = "Left",
            ["RIGHT"] = "Right",
            ["TOP"] = "Top",
            ["BOTTOM"] = "Bottom"
        }, db, "absorbGlowAnchor"), 60)
        anchorDropdown.disableOn = function(d) return d.absorbMatchHealthOrientation end
    end)

    -- TAB 7: ICONS
    BuildPage(CreateTab("icons", "Icons"), function(self, db, Add, AddSpace)
        -- Helper for anchor dropdown options
        local anchorOptions = {
            ["CENTER"]="Center", ["LEFT"]="Left", ["RIGHT"]="Right", ["TOP"]="Top", ["BOTTOM"]="Bottom",
            ["TOPLEFT"]="Top Left", ["TOPRIGHT"]="Top Right", ["BOTTOMLEFT"]="Bottom Left", ["BOTTOMRIGHT"]="Bottom Right"
        }
        
        -- COLUMN 1: Leader & Role Icons
        Add(GUI:CreateHeader(self, "Leader Icon"), 30, 1)
        Add(GUI:CreateCheckbox(self, "Hide", db, "leaderIconHide"), 30, 1)
        local ledScale = Add(GUI:CreateSlider(self, "Scale", 0.5, 2.5, 0.1, db, "leaderIconScale"), 60, 1)
        ledScale.disableOn = function(d) return d.leaderIconHide end
        local ledAdv = Add(GUI:CreateCheckbox(self, "Custom Position", db, "leaderIconEnabled"), 30, 1)
        ledAdv.disableOn = function(d) return d.leaderIconHide end
        local ledAnch = Add(GUI:CreateDropdown(self, "    Anchor", anchorOptions, db, "leaderIconAnchor"), 60, 1)
        ledAnch.hideOn = function(d) return d.leaderIconHide or not d.leaderIconEnabled end
        local ledX = Add(GUI:CreateSlider(self, "    Offset X", -50, 50, 1, db, "leaderIconX"), 60, 1)
        ledX.hideOn = function(d) return d.leaderIconHide or not d.leaderIconEnabled end
        local ledY = Add(GUI:CreateSlider(self, "    Offset Y", -50, 50, 1, db, "leaderIconY"), 60, 1)
        ledY.hideOn = function(d) return d.leaderIconHide or not d.leaderIconEnabled end
        
        AddSpace(25, 1)
        
        Add(GUI:CreateHeader(self, "Role Icon"), 30, 1)
        Add(GUI:CreateCheckbox(self, "Hide", db, "roleIconHide"), 30, 1)
        local roleScale = Add(GUI:CreateSlider(self, "Scale", 0.5, 2.5, 0.1, db, "roleIconScale"), 60, 1)
        roleScale.disableOn = function(d) return d.roleIconHide end
        local roleAdv = Add(GUI:CreateCheckbox(self, "Custom Position", db, "roleIconEnabled"), 30, 1)
        roleAdv.disableOn = function(d) return d.roleIconHide end
        local roleAnch = Add(GUI:CreateDropdown(self, "    Anchor", anchorOptions, db, "roleIconAnchor"), 60, 1)
        roleAnch.hideOn = function(d) return d.roleIconHide or not d.roleIconEnabled end
        local roleX = Add(GUI:CreateSlider(self, "    Offset X", -50, 50, 1, db, "roleIconX"), 60, 1)
        roleX.hideOn = function(d) return d.roleIconHide or not d.roleIconEnabled end
        local roleY = Add(GUI:CreateSlider(self, "    Offset Y", -50, 50, 1, db, "roleIconY"), 60, 1)
        roleY.hideOn = function(d) return d.roleIconHide or not d.roleIconEnabled end
        
        -- COLUMN 2: Raid Target, Status, Ready Check
        Add(GUI:CreateHeader(self, "Raid Target (Skull/X)"), 30, 2)
        Add(GUI:CreateSlider(self, "Scale", 0.5, 2.5, 0.1, db, "raidIconScale"), 60, 2)
        local raidAdv = Add(GUI:CreateCheckbox(self, "Custom Position", db, "raidIconEnabled"), 30, 2)
        local raidAnch = Add(GUI:CreateDropdown(self, "    Anchor", anchorOptions, db, "raidIconAnchor"), 60, 2)
        raidAnch.hideOn = function(d) return not d.raidIconEnabled end
        local raidX = Add(GUI:CreateSlider(self, "    Offset X", -50, 50, 1, db, "raidIconX"), 60, 2)
        raidX.hideOn = function(d) return not d.raidIconEnabled end
        local raidY = Add(GUI:CreateSlider(self, "    Offset Y", -50, 50, 1, db, "raidIconY"), 60, 2)
        raidY.hideOn = function(d) return not d.raidIconEnabled end
        
        AddSpace(25, 2)
        
        -- NEW: Range Icon Hiding (Moved here from General)
        Add(GUI:CreateHeader(self, "Range Icon"), 30, 2)
        Add(GUI:CreateCheckbox(self, "Hide Range Icon (Eye)", db, "hideRangeIcon", function() DF:UpdateAll() end), 30, 2)
        
        AddSpace(25, 2)
        
        Add(GUI:CreateHeader(self, "Center Status (Res/Summon)"), 30, 2)
        Add(GUI:CreateSlider(self, "Scale", 0.5, 2.5, 0.1, db, "centerStatusIconScale"), 60, 2)
        local csAdv = Add(GUI:CreateCheckbox(self, "Custom Position", db, "centerStatusIconEnabled"), 30, 2)
        local csAnch = Add(GUI:CreateDropdown(self, "    Anchor", anchorOptions, db, "centerStatusIconAnchor"), 60, 2)
        csAnch.hideOn = function(d) return not d.centerStatusIconEnabled end
        local csX = Add(GUI:CreateSlider(self, "    Offset X", -50, 50, 1, db, "centerStatusIconX"), 60, 2)
        csX.hideOn = function(d) return not d.centerStatusIconEnabled end
        local csY = Add(GUI:CreateSlider(self, "    Offset Y", -50, 50, 1, db, "centerStatusIconY"), 60, 2)
        csY.hideOn = function(d) return not d.centerStatusIconEnabled end
        
        AddSpace(25, 2)
        
        Add(GUI:CreateHeader(self, "Ready Check"), 30, 2)
        Add(GUI:CreateSlider(self, "Scale", 0.5, 2.5, 0.1, db, "readyCheckIconScale"), 60, 2)
        local rcAdv = Add(GUI:CreateCheckbox(self, "Custom Position", db, "readyCheckIconEnabled"), 30, 2)
        local rcAnch = Add(GUI:CreateDropdown(self, "    Anchor", anchorOptions, db, "readyCheckIconAnchor"), 60, 2)
        rcAnch.hideOn = function(d) return not d.readyCheckIconEnabled end
        local rcX = Add(GUI:CreateSlider(self, "    Offset X", -50, 50, 1, db, "readyCheckIconX"), 60, 2)
        rcX.hideOn = function(d) return not d.readyCheckIconEnabled end
        local rcY = Add(GUI:CreateSlider(self, "    Offset Y", -50, 50, 1, db, "readyCheckIconY"), 60, 2)
        rcY.hideOn = function(d) return not d.readyCheckIconEnabled end
    end)

    -- NEW TAB 7.5: HIGHLIGHTS
    BuildPage(CreateTab("highlights", "Highlights"), function(self, db, Add, AddSpace)
        -- Helper function to force refresh for live updates
        -- NOTE: We do NOT call Blizzard's CompactUnitFrame_UpdateSelectionHighlight or
        -- CompactUnitFrame_UpdateAggroHighlight here as they cause taint errors.
        -- Our custom highlight system in DandersFrames_Hooks.lua handles updates via timer.
        local function Refresh()
            DF:UpdateAll()
        end

        -- COLUMN 1: Selection Highlight
        Add(GUI:CreateHeader(self, "Selection Highlight"), 30, 1)
        Add(GUI:CreateDropdown(self, "Mode", {
            ["BLIZZARD"] = "Blizzard Default",
            ["NONE"] = "Hidden",
            ["SOLID"] = "Solid Border",
            ["ANIMATED"] = "Animated Border",
            ["DASHED"] = "Dashed Border",
            ["GLOW"] = "Glow",
            ["CORNERS"] = "Corners Only"
        }, db, "selectionHighlightMode", function() self:RefreshStates() Refresh() end), 60, 1)
        
        -- Helper to check if custom options should be hidden
        local function HideSelectionOptions(d)
            return d.selectionHighlightMode == "BLIZZARD" or d.selectionHighlightMode == "NONE"
        end
        
        local selThick = Add(GUI:CreateSlider(self, "Thickness", 1, 10, 1, db, "selectionHighlightThickness", Refresh), 60, 1)
        selThick.hideOn = HideSelectionOptions
        
        local selInset = Add(GUI:CreateSlider(self, "Inset", -10, 10, 1, db, "selectionHighlightInset", Refresh), 60, 1)
        selInset.hideOn = HideSelectionOptions
        
        local selAlpha = Add(GUI:CreateSlider(self, "Alpha", 0.1, 1.0, 0.05, db, "selectionHighlightAlpha", Refresh), 60, 1)
        selAlpha.hideOn = HideSelectionOptions
        
        local selCol = Add(GUI:CreateColorPicker(self, "Color", db, "selectionHighlightColor", false, Refresh), 30, 1)
        selCol.hideOn = HideSelectionOptions
        
        -- COLUMN 2: Aggro Highlight
        Add(GUI:CreateHeader(self, "Aggro Highlight"), 30, 2)
        Add(GUI:CreateDropdown(self, "Mode", {
            ["BLIZZARD"] = "Blizzard Default",
            ["NONE"] = "Hidden",
            ["SOLID"] = "Solid Border",
            ["ANIMATED"] = "Animated Border",
            ["DASHED"] = "Dashed Border",
            ["GLOW"] = "Glow",
            ["CORNERS"] = "Corners Only"
        }, db, "aggroHighlightMode", function() self:RefreshStates() Refresh() end), 60, 2)
        
        -- Helper to check if custom options should be hidden
        local function HideAggroOptions(d)
            return d.aggroHighlightMode == "BLIZZARD" or d.aggroHighlightMode == "NONE"
        end
        
        local aggThick = Add(GUI:CreateSlider(self, "Thickness", 1, 10, 1, db, "aggroHighlightThickness", Refresh), 60, 2)
        aggThick.hideOn = HideAggroOptions
        
        local aggInset = Add(GUI:CreateSlider(self, "Inset", -10, 10, 1, db, "aggroHighlightInset", Refresh), 60, 2)
        aggInset.hideOn = HideAggroOptions
        
        local aggAlpha = Add(GUI:CreateSlider(self, "Alpha", 0.1, 1.0, 0.05, db, "aggroHighlightAlpha", Refresh), 60, 2)
        aggAlpha.hideOn = HideAggroOptions
        
        -- Note: Aggro color is determined by threat level (red/orange/yellow) from GetThreatStatusColor()
        
    end)

    -- TAB 8: PROFILES
    BuildPage(CreateTab("profiles", "Profiles"), function(self, db, Add, AddSpace)
        Add(GUI:CreateHeader(self, "Profile Management"), 30)
        local currentProfile = DF.db:GetCurrentProfile()
        local profiles = DF.db:GetProfiles()
        Add(GUI:CreateHeader(self, "Current Profile: " .. currentProfile), 30)
        
        local scrollFrame = CreateFrame("ScrollFrame", nil, self.child, "UIPanelScrollFrameTemplate")
        scrollFrame:SetSize(240, 200)
        scrollFrame:SetPoint("TOPLEFT", 10, -80) 
        GUI.CreateBackdrop(scrollFrame)
        scrollFrame:SetBackdropColor(0,0,0,0.3)
        local scrollChild = CreateFrame("Frame")
        scrollChild:SetSize(240, #profiles * 22 + 10)
        scrollFrame:SetScrollChild(scrollChild)
        table.insert(self.children, scrollFrame) 
        
        local py = 0
        for i, p in ipairs(profiles) do
             local btn = GUI:CreateButton(scrollChild, p, 235, 20)
             btn:SetPoint("TOPLEFT", 0, py)
             if p == currentProfile then
                 local c = GUI.GetThemeColor()
                 btn:SetBackdropColor(c.r, c.g, c.b, 0.5)
             end
             btn:SetScript("OnClick", function() DF.db:SetProfile(p) GUI:RefreshCurrentPage() end)
             py = py - 22
        end

        Add(GUI:CreateHeader(self, "Create New"), 30, 2)
        local input = GUI:CreateInput(self, "New Profile Name", 180)
        Add(input, 50, 2)
        Add(GUI:CreateButton(self, "Create", 100, 24, function()
             local text = input.EditBox:GetText()
             if text and text ~= "" then DF.db:SetProfile(text) GUI:RefreshCurrentPage() end
        end), 30, 2)
        
        AddSpace(20, 2)
        
        Add(GUI:CreateButton(self, "Delete Current", 140, 24, function()
             local p = DF.db:GetCurrentProfile()
             if p ~= "Default" then DF.db:DeleteProfile(p) GUI:RefreshCurrentPage()
             else print("Cannot delete Default profile.") end
        end), 30, 2)
        Add(GUI:CreateButton(self, "Reset Profile", 140, 24, function()
             DF:ResetProfile("party") DF:ResetProfile("raid") GUI:RefreshCurrentPage()
        end), 30, 2)
        
        AddSpace(20, 2)
        
        Add(GUI:CreateHeader(self, "Auto-Switching (Specs)"), 30, 2)
        Add(GUI:CreateCheckbox(self, "Enable Auto Switch", DF.db.char, "enableSpecSwitch"), 30, 2)
        
        local numSpecs = GetNumSpecializations and GetNumSpecializations() or 0
        if numSpecs > 0 then
            local pList = {}
            for _, p in ipairs(profiles) do pList[p] = p end
            for i = 1, numSpecs do
                local id, name, _, icon = GetSpecializationInfo(i)
                if name then
                    Add(GUI:CreateHeader(self, name), 20, 2)
                    if not DF.db.char.specProfiles then DF.db.char.specProfiles = {} end
                    local dd = GUI:CreateDropdown(self, "", pList, DF.db.char.specProfiles, i)
                    Add(dd, 60, 2)
                end
            end
        end
    end)

    -- TAB 9: TOOLS
    BuildPage(CreateTab("tools", "Tools"), function(self, db, Add, AddSpace)
        Add(GUI:CreateHeader(self, "Copy Settings (Current Profile)"), 30)
        Add(GUI:CreateButton(self, "Copy Party -> Raid", 200, 30, function() 
            DF:CopyProfile("party", "raid")
            print("|cff00ff00DandersFrames:|r Copied Party settings to Raid.")
            GUI:RefreshCurrentPage()
        end), 40)
        Add(GUI:CreateButton(self, "Copy Raid -> Party", 200, 30, function() 
            DF:CopyProfile("raid", "party")
            print("|cff00ff00DandersFrames:|r Copied Raid settings to Party.")
            GUI:RefreshCurrentPage()
        end), 40)
        AddSpace(20)
        Add(GUI:CreateHeader(self, "Reset Settings (Current Mode Only)"), 30)
        Add(GUI:CreateButton(self, "Reset " .. (GUI.SelectedMode == "party" and "Party" or "Raid"), 200, 30, function()
             DF:ResetProfile(GUI.SelectedMode)
             DF:UpdateAll()
             GUI:RefreshCurrentPage()
        end), 40)
    end)

    -- TAB 10: IMPORT / EXPORT
    BuildPage(CreateTab("import", "Import / Export"), function(self, db, Add, AddSpace)
        Add(GUI:CreateHeader(self, "Export / Import Settings"), 30, 1) 
        local spacer = CreateFrame("Frame", nil, self.child)
        Add(spacer, 30, 2)
        local scroll = CreateFrame("ScrollFrame", nil, self.child, "UIPanelScrollFrameTemplate")
        scroll:SetSize(320, 300) 
        GUI.CreateBackdrop(scroll)
        scroll:SetBackdropColor(0,0,0,0.5)
        local editBox = CreateFrame("EditBox", nil, scroll)
        editBox:SetMultiLine(true)
        editBox:SetFontObject(GameFontHighlightSmall)
        editBox:SetWidth(300)
        editBox:SetTextInsets(5, 5, 5, 5)
        scroll:SetScrollChild(editBox)
        Add(scroll, 310, 1) 
        
        local btnExport = GUI:CreateButton(self, "Generate Export String", 160, 24, function()
             local str = DF:ExportProfile()
             editBox:SetText(str)
             editBox:HighlightText()
             editBox:SetFocus()
        end)
        Add(btnExport, 30, 2)
        local btnImport = GUI:CreateButton(self, "Import String", 160, 24, function()
             local str = editBox:GetText()
             if str and str ~= "" then
                 DF:ImportProfile(str)
                 GUI:RefreshCurrentPage()
             end
        end)
        Add(btnImport, 30, 2)
    end)
end