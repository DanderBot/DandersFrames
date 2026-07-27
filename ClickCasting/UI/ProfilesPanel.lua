local addonName, DF = ...

-- Get module namespace
local CC = DF.ClickCast
local L = DF.L
local format = string.format

-- Local aliases for helper functions (defined in Constants.lua and Profiles.lua)
local IsDefaultProfile = function(name) return CC.IsDefaultProfile(name) end

-- PROFILES PANEL UI
-- =========================================================================

function CC:CreateProfilesPanelContent()
    local panel = self.profilesPanel
    if not panel then return end
    
    local C = self.UI_COLORS
    local themeColor = C.theme
    
    -- Two-column layout
    local leftCol = CreateFrame("Frame", nil, panel)
    leftCol:SetPoint("TOPLEFT", 10, -10)
    leftCol:SetPoint("BOTTOMLEFT", 10, 10)
    leftCol:SetWidth(200)  -- Narrower for more right space
    
    local rightCol = CreateFrame("Frame", nil, panel)
    rightCol:SetPoint("TOPLEFT", leftCol, "TOPRIGHT", 10, 0)
    rightCol:SetPoint("BOTTOMRIGHT", -10, 10)
    
    -- ===== LEFT COLUMN: Profile List =====
    local profilesLabel = leftCol:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    profilesLabel:SetPoint("TOPLEFT", 0, 0)
    profilesLabel:SetText(L["YOUR PROFILES"])
    profilesLabel:SetTextColor(C.textDim.r, C.textDim.g, C.textDim.b)
    
    local profileList = CreateFrame("Frame", nil, leftCol, "BackdropTemplate")
    profileList:SetPoint("TOPLEFT", profilesLabel, "BOTTOMLEFT", 0, -4)
    profileList:SetPoint("RIGHT", 0, 0)
    profileList:SetHeight(180)
    DF.GUI:CreatePanelBackdrop(profileList, { borderColor = { r = C.border.r, g = C.border.g, b = C.border.b, a = 0.5 } })
    profileList:SetBackdropColor(0.06, 0.06, 0.06, 1)  -- darker than the shared panel fill
    CC.profileListFrame = profileList
    
    -- Profile list scroll frame
    local profileScroll = CreateFrame("ScrollFrame", nil, profileList, "ScrollFrameTemplate")
    profileScroll:SetPoint("TOPLEFT", 2, -2)
    profileScroll:SetPoint("BOTTOMRIGHT", -22, 2)
    DF.GUI.StyleScrollBar(profileScroll)

    local profileContent = CreateFrame("Frame", nil, profileScroll)
    profileContent:SetWidth(profileScroll:GetWidth())
    profileContent:SetHeight(1)
    profileScroll:SetScrollChild(profileContent)
    CC.profileListContent = profileContent
    
    -- Profile buttons
    local btnRow = CreateFrame("Frame", nil, leftCol)
    btnRow:SetPoint("TOPLEFT", profileList, "BOTTOMLEFT", 0, -8)
    btnRow:SetPoint("RIGHT", 0, 0)
    btnRow:SetHeight(22)
    
    local function CreateSmallButton(parent, text, width)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        DF.GUI:StyleButton(btn, { width = width, height = 22, text = text, accent = themeColor })
        btn.text = btn.Text
        return btn
    end
    
    -- Row 1: New and Copy buttons
    local newBtn = CreateSmallButton(btnRow, L["New"], 10)  -- Width will be set by anchors
    newBtn:SetPoint("LEFT", 0, 0)
    newBtn:SetPoint("RIGHT", btnRow, "CENTER", -2, 0)
    -- Leading icon + persistent accent tint (replaces the hand-rolled texture and
    -- the post-StyleButton SetBackdropColor that used to clobber the styler).
    DF.GUI:StyleButton(newBtn, {
        text = L["New"], accent = themeColor, tinted = true,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 12, color = C.text },
    })
    newBtn:SetScript("OnClick", function()
        CC:ShowNewProfileDialog()
    end)
    
    local copyBtn = CreateSmallButton(btnRow, L["Copy"], 10)
    copyBtn:SetPoint("LEFT", btnRow, "CENTER", 2, 0)
    copyBtn:SetPoint("RIGHT", 0, 0)
    DF.GUI:StyleButton(copyBtn, {
        text = L["Copy"], accent = themeColor,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\content_copy", size = 12, color = C.text },
    })
    copyBtn:SetScript("OnClick", function()
        if CC.selectedProfileName then
            CC:ShowCopyProfileDialog(CC.selectedProfileName)
        end
    end)
    CC.profileCopyBtn = copyBtn
    
    -- Row 2: Rename and Delete buttons
    local btnRow2 = CreateFrame("Frame", nil, leftCol)
    btnRow2:SetPoint("TOPLEFT", btnRow, "BOTTOMLEFT", 0, -3)
    btnRow2:SetPoint("RIGHT", btnRow, "RIGHT", 0, 0)
    btnRow2:SetHeight(22)
    
    local renameBtn = CreateSmallButton(btnRow2, L["Rename"], 10)
    renameBtn:SetPoint("LEFT", 0, 0)
    renameBtn:SetPoint("RIGHT", btnRow2, "CENTER", -2, 0)
    DF.GUI:StyleButton(renameBtn, {
        text = L["Rename"], accent = themeColor,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\edit", size = 12, color = C.text },
    })
    renameBtn:SetScript("OnClick", function()
        if CC.selectedProfileName then
            CC:ShowRenameProfileDialog(CC.selectedProfileName)
        end
    end)
    CC.profileRenameBtn = renameBtn
    
    local deleteBtn = CreateSmallButton(btnRow2, L["Delete"], 10)
    deleteBtn:SetPoint("LEFT", btnRow2, "CENTER", 2, 0)
    deleteBtn:SetPoint("RIGHT", 0, 0)
    -- Destructive styling via the shared helper (neutral-at-rest + red hover wash
    -- and red hover border) plus the red trash icon. Replaces the hand-rolled red
    -- border + hover scripts and the hand-attached icon texture.
    DF.GUI:StyleButton(deleteBtn, {
        text = L["Delete"], tone = "danger",
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\delete", size = 12, color = { r = 1, g = 0.5, b = 0.5 } },
    })
    deleteBtn.text:SetTextColor(1, 0.5, 0.5)
    deleteBtn:SetScript("OnClick", function()
        if CC.selectedProfileName and not IsDefaultProfile(CC.selectedProfileName) then
            CC:ShowDeleteProfileDialog(CC.selectedProfileName)
        end
    end)
    CC.profileDeleteBtn = deleteBtn
    
    -- Import/Export section
    local ioLabel = leftCol:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    ioLabel:SetPoint("TOPLEFT", btnRow2, "BOTTOMLEFT", 0, -12)
    ioLabel:SetText(L["Import/Export"])
    ioLabel:SetTextColor(C.textDim.r, C.textDim.g, C.textDim.b)
    
    local ioRow = CreateFrame("Frame", nil, leftCol)
    ioRow:SetPoint("TOPLEFT", ioLabel, "BOTTOMLEFT", 0, -4)
    ioRow:SetPoint("RIGHT", 0, 0)
    ioRow:SetHeight(22)
    
    local exportBtn = CreateSmallButton(ioRow, L["Export"], 10)
    exportBtn:SetPoint("LEFT", 0, 0)
    exportBtn:SetPoint("RIGHT", ioRow, "CENTER", -2, 0)
    -- Leading icon + persistent accent tint (replaces the hand-rolled texture and
    -- the post-StyleButton SetBackdropColor that used to clobber the styler).
    DF.GUI:StyleButton(exportBtn, {
        text = L["Export"], accent = themeColor, tinted = true,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\upload", size = 12, color = C.text },
    })
    exportBtn:SetScript("OnClick", function()
        CC:ShowExportDialog()
    end)
    
    local importBtn = CreateSmallButton(ioRow, L["Import"], 10)
    importBtn:SetPoint("LEFT", ioRow, "CENTER", 2, 0)
    importBtn:SetPoint("RIGHT", 0, 0)
    DF.GUI:StyleButton(importBtn, {
        text = L["Import"], accent = themeColor,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\download", size = 12, color = C.text },
    })
    importBtn:SetScript("OnClick", function()
        CC:ShowImportDialog()
    end)
    
    -- Auto-create profiles checkbox
    local autoCreateCb = CreateFrame("CheckButton", nil, leftCol, "BackdropTemplate")
    autoCreateCb:SetPoint("TOPLEFT", ioRow, "BOTTOMLEFT", 0, -12)
    autoCreateCb.check = DF.GUI:StyleCheckButton(autoCreateCb, { accent = CC.ACCENT, manualCheck = true })
    
    local autoCreateLabel = leftCol:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    autoCreateLabel:SetPoint("LEFT", autoCreateCb, "RIGHT", 8, 0)
    autoCreateLabel:SetText(L["Auto-create profiles for loadouts"])
    autoCreateLabel:SetTextColor(C.text.r, C.text.g, C.text.b)
    
    -- Initialize checkbox state
    local autoCreate = CC.db and CC.db.global and CC.db.global.autoCreateProfiles
    if autoCreate == nil then autoCreate = true end
    autoCreateCb:SetChecked(autoCreate)
    autoCreateCb.check:SetShown(autoCreate)
    
    autoCreateCb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        self.check:SetShown(checked)
        if CC.db and CC.db.global then
            CC.db.global.autoCreateProfiles = checked
        end
        if checked then
            print("|cff33cc33DandersFrames:|r Auto-create profiles enabled.")
        else
            print("|cffff9900DandersFrames:|r Auto-create profiles disabled. Profiles will not be created for new loadouts.")
        end
        -- Refresh to update the status text
        CC:RefreshProfilesPanel()
    end)
    
    autoCreateCb:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = L["Auto-Create Profiles"],
            anchor = "ANCHOR_RIGHT",
            lines = {
                L["When enabled, a new profile will be automatically"],
                L["created when you switch to a talent loadout that"],
                L["doesn't have a profile assigned."],
                " ",
                L["Disable this if you want to use the same profile"],
                L["for all your loadouts."],
            },
        })
    end)
    autoCreateCb:SetScript("OnLeave", function(self)
        DF.GUI:HideTooltip()
    end)
    
    CC.autoCreateCb = autoCreateCb
    
    -- Disable while mounted checkbox
    local mountCb = CreateFrame("CheckButton", nil, leftCol, "BackdropTemplate")
    mountCb:SetPoint("TOPLEFT", autoCreateCb, "BOTTOMLEFT", 0, -8)
    mountCb.check = DF.GUI:StyleCheckButton(mountCb, { accent = CC.ACCENT, manualCheck = true })
    
    local mountLabel = leftCol:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    mountLabel:SetPoint("LEFT", mountCb, "RIGHT", 8, 0)
    mountLabel:SetText(L["Disable while mounted/flying"])
    mountLabel:SetTextColor(C.text.r, C.text.g, C.text.b)
    
    -- Initialize checkbox state
    local disableMounted = CC.db and CC.db.global and CC.db.global.disableWhileMounted
    if disableMounted == nil then disableMounted = false end
    mountCb:SetChecked(disableMounted)
    mountCb.check:SetShown(disableMounted)

    mountCb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        self.check:SetShown(checked)
        -- Mutually exclusive with fly-only: turning on mounted turns off fly-only
        local disableFlying = CC.db and CC.db.global and CC.db.global.disableWhileFlying or false
        if checked and disableFlying then
            disableFlying = false
            if CC.flyingCb then
                CC.flyingCb:SetChecked(false)
                CC.flyingCb.check:SetShown(false)
            end
        end
        if CC.db and CC.db.global then
            CC.db.global.disableWhileMounted = checked
            CC.db.global.disableWhileFlying  = disableFlying
        end
        if checked then
            print("|cff33cc33DandersFrames:|r Click-casting will be disabled while mounted/flying.")
        else
            print("|cffff9900DandersFrames:|r Click-casting will stay active while mounted/flying.")
        end
        -- Rebuild bindings with new macro conditions (if not in combat)
        if not InCombatLockdown() then
            CC:ApplyBindings()
        else
            CC.needsBindingRefresh = true
        end
    end)

    mountCb:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = L["Disable While Mounted"],
            anchor = "ANCHOR_RIGHT",
            lines = {
                L["When enabled, click-casting bindings will be temporarily disabled while you are mounted or in druid flight form."],
                " ",
                L["This allows normal clicking on unit frames to select targets while traveling."],
            },
        })
    end)
    mountCb:SetScript("OnLeave", function(self)
        DF.GUI:HideTooltip()
    end)

    CC.mountCb = mountCb

    -- Disable while flying only checkbox
    local flyingCb = CreateFrame("CheckButton", nil, leftCol, "BackdropTemplate")
    flyingCb:SetPoint("TOPLEFT", mountCb, "BOTTOMLEFT", 0, -8)
    flyingCb.check = DF.GUI:StyleCheckButton(flyingCb, { accent = CC.ACCENT, manualCheck = true })

    local flyingLabel = leftCol:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    flyingLabel:SetPoint("LEFT", flyingCb, "RIGHT", 8, 0)
    flyingLabel:SetText(L["Disable Only While Flying"])
    flyingLabel:SetTextColor(C.text.r, C.text.g, C.text.b)

    local disableFlying = CC.db and CC.db.global and CC.db.global.disableWhileFlying or false
    flyingCb:SetChecked(disableFlying)
    flyingCb.check:SetShown(disableFlying)

    flyingCb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        self.check:SetShown(checked)
        -- Mutually exclusive with mounted: turning on fly-only turns off mounted
        local disableMounted = CC.db and CC.db.global and CC.db.global.disableWhileMounted or false
        if checked and disableMounted then
            disableMounted = false
            if CC.mountCb then
                CC.mountCb:SetChecked(false)
                CC.mountCb.check:SetShown(false)
            end
        end
        if CC.db and CC.db.global then
            CC.db.global.disableWhileFlying  = checked
            CC.db.global.disableWhileMounted = disableMounted
        end
        if checked then
            print("|cff33cc33DandersFrames:|r Click-casting will be disabled only while flying.")
        else
            print("|cffff9900DandersFrames:|r Click-casting will stay active while flying.")
        end
        if not InCombatLockdown() then
            CC:ApplyBindings()
        else
            CC.needsBindingRefresh = true
        end
    end)

    flyingCb:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = L["Disable Only While Flying"],
            anchor = "ANCHOR_RIGHT",
            lines = {
                L["When enabled, click-casting bindings will be temporarily disabled while you are in a flying state."],
                L["This includes druid flight form, but not ground mounts."],
                " ",
                L["This allows normal clicking on unit frames to select targets while traveling."],
            },
        })
    end)
    flyingCb:SetScript("OnLeave", function(self)
        DF.GUI:HideTooltip()
    end)

    CC.flyingCb = flyingCb

    -- Target unit when click-casting checkbox
    local targetCb = CreateFrame("CheckButton", nil, leftCol, "BackdropTemplate")
    targetCb:SetPoint("TOPLEFT", flyingCb, "BOTTOMLEFT", 0, -8)
    targetCb.check = DF.GUI:StyleCheckButton(targetCb, { accent = CC.ACCENT, manualCheck = true })

    local targetLabel = leftCol:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    targetLabel:SetPoint("LEFT", targetCb, "RIGHT", 8, 0)
    targetLabel:SetText(L["Target unit when click-casting"])
    targetLabel:SetTextColor(C.text.r, C.text.g, C.text.b)

    local targetOnCast = CC.db and CC.db.global and CC.db.global.targetOnCast or false
    targetCb:SetChecked(targetOnCast)
    targetCb.check:SetShown(targetOnCast)

    targetCb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        self.check:SetShown(checked)
        if CC.db and CC.db.global then
            CC.db.global.targetOnCast = checked
        end
        if checked then
            print("|cff33cc33DandersFrames:|r Click-casting will now also target the unit you cast on.")
        else
            print("|cffff9900DandersFrames:|r Click-casting will no longer change your target.")
        end
        if not InCombatLockdown() then
            CC:ApplyBindings()
        else
            CC.needsBindingRefresh = true
        end
    end)

    targetCb:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = L["Target unit when click-casting"],
            anchor = "ANCHOR_RIGHT",
            lines = { L["When enabled, click-casting a spell on a frame also makes that unit your target. Individual bindings can override this in the binding editor."] },
        })
    end)
    targetCb:SetScript("OnLeave", function(self)
        DF.GUI:HideTooltip()
    end)

    CC.targetCb = targetCb

    -- ===== RIGHT COLUMN: Loadout Assignments =====
    local loadoutLabel = rightCol:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    loadoutLabel:SetPoint("TOPLEFT", 0, 0)
    loadoutLabel:SetText(L["LOADOUT ASSIGNMENTS"])
    loadoutLabel:SetTextColor(C.textDim.r, C.textDim.g, C.textDim.b)
    
    local loadoutContainer = CreateFrame("Frame", nil, rightCol, "BackdropTemplate")
    loadoutContainer:SetPoint("TOPLEFT", loadoutLabel, "BOTTOMLEFT", 0, -4)
    loadoutContainer:SetPoint("RIGHT", 0, 0)
    loadoutContainer:SetPoint("BOTTOM", 0, 0)
    DF.GUI:CreatePanelBackdrop(loadoutContainer, { borderColor = { r = C.border.r, g = C.border.g, b = C.border.b, a = 0.5 } })
    loadoutContainer:SetBackdropColor(0.06, 0.06, 0.06, 1)  -- darker than the shared panel fill
    
    -- Loadout scroll frame
    local loadoutScroll = CreateFrame("ScrollFrame", nil, loadoutContainer, "ScrollFrameTemplate")
    loadoutScroll:SetPoint("TOPLEFT", 2, -2)
    loadoutScroll:SetPoint("BOTTOMRIGHT", -22, 2)
    DF.GUI.StyleScrollBar(loadoutScroll)

    local loadoutContent = CreateFrame("Frame", nil, loadoutScroll)
    loadoutContent:SetHeight(1)
    loadoutScroll:SetScrollChild(loadoutContent)
    CC.loadoutContent = loadoutContent
    CC.loadoutScroll = loadoutScroll
    
    -- Update content width on size change
    loadoutContainer:SetScript("OnSizeChanged", function()
        loadoutContent:SetWidth(math.max(loadoutScroll:GetWidth() - 10, 100))
    end)
    
    -- Auto-link indicator at bottom
    local autoLinkInfo = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    autoLinkInfo:SetPoint("BOTTOMLEFT", 10, 10)
    autoLinkInfo:SetPoint("RIGHT", panel, "RIGHT", -220, 0) -- Limit width so it doesn't overlap right column
    autoLinkInfo:SetJustifyH("LEFT")
    autoLinkInfo:SetTextColor(C.textDim.r, C.textDim.g, C.textDim.b)
    CC.autoLinkInfo = autoLinkInfo
end

function CC:RefreshProfilesPanel()
    if not self.profilesPanel or not self.profilesPanel:IsShown() then return end
    
    local C = self.UI_COLORS
    local themeColor = C.theme
    
    -- Clear existing profile items
    if self.profileListContent then
        for _, child in ipairs({self.profileListContent:GetChildren()}) do
            child:Hide()
            child:SetParent(nil)
        end
        -- StyleButton registers each row on the parent's ThemeListeners. This
        -- content frame OUTLIVES its rows (a settings page throws its whole
        -- child away and starts over), so without this the table would keep
        -- growing a reference to every row we just discarded.
        self.profileListContent.ThemeListeners = nil
    end
    
    -- Update auto-create checkbox state
    if self.autoCreateCb then
        local autoCreate = self.db and self.db.global and self.db.global.autoCreateProfiles
        if autoCreate == nil then autoCreate = true end
        self.autoCreateCb:SetChecked(autoCreate)
        if self.autoCreateCb.check then
            self.autoCreateCb.check:SetShown(autoCreate)
        end
    end
    
    -- Update mount checkbox state
    if self.mountCb then
        local disableMounted = self.db and self.db.global and self.db.global.disableWhileMounted or false
        self.mountCb:SetChecked(disableMounted)
        if self.mountCb.check then
            self.mountCb.check:SetShown(disableMounted)
        end
    end

    -- Update fly-only checkbox state
    if self.flyingCb then
        local disableFlying = self.db and self.db.global and self.db.global.disableWhileFlying or false
        self.flyingCb:SetChecked(disableFlying)
        if self.flyingCb.check then
            self.flyingCb.check:SetShown(disableFlying)
        end
    end

    -- Get profiles
    local profiles = self:GetProfileList()
    local activeProfile = self:GetActiveProfileName()
    local yOffset = 0
    
    -- Both row states ride the shared styler, so the hover is the same theme wash
    -- as every other button in the addon. These rows used to hand-roll a flat
    -- 0.15 grey in OnEnter and restate all three rest fills in OnLeave, which is
    -- how they ended up as the one hover that ignored the theme entirely.
    --   SELECTED (what Rename/Delete act on) -> SetActive's accent fill + border
    --   ACTIVE   (the profile actually in use) -> green rest border + the dot
    -- Two separate cues, so a row that is selected but NOT active still reads
    -- apart from the active one. The green is the styler's own affirmative tone
    -- (opts.tone = "success"), not a fourth colour invented here.
    local ACTIVE_BORDER = { r = 0.4, g = 0.85, b = 0.5, a = 0.8 }

    -- Create profile items
    for _, profileName in ipairs(profiles) do
        local isActive = (profileName == activeProfile)
        local isSelected = (profileName == self.selectedProfileName)

        local item = CreateFrame("Button", nil, self.profileListContent, "BackdropTemplate")
        item:SetPoint("TOPLEFT", 0, -yOffset)
        item:SetPoint("RIGHT", 0, 0)
        item:SetHeight(28)
        DF.GUI:StyleButton(item, {
            restBorderColor = isActive and ACTIVE_BORDER or nil,
        })
        item:SetActive(isSelected)

        -- Active indicator
        if isActive then
            local dot = item:CreateTexture(nil, "OVERLAY")
            dot:SetSize(8, 8)
            dot:SetPoint("LEFT", 6, 0)
            dot:SetTexture("Interface\\Buttons\\WHITE8x8")
            dot:SetVertexColor(themeColor.r, themeColor.g, themeColor.b)
        end
        
        -- Binding count (create first so nameText can anchor to it)
        local classData = self:GetClassData()
        local profile = classData.profiles[profileName]
        local bindCount = profile and profile.bindings and #profile.bindings or 0
        
        local countText = item:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        countText:SetPoint("RIGHT", -6, 0)
        countText:SetText(format(L["%d binds"], bindCount))
        countText:SetTextColor(C.textDim.r, C.textDim.g, C.textDim.b)
        
        local nameText = item:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        nameText:SetPoint("LEFT", isActive and 18 or 6, 0)
        nameText:SetPoint("RIGHT", countText, "LEFT", -8, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetWordWrap(false)
        nameText:SetText(profileName)
        nameText:SetTextColor(C.text.r, C.text.g, C.text.b)
        
        -- Store full name for tooltip
        item.fullProfileName = profileName
        
        item:SetScript("OnClick", function()
            self.selectedProfileName = profileName
            -- Switch to the profile on single click (if not in combat and not already active)
            if profileName ~= activeProfile and not InCombatLockdown() then
                if self:SetActiveProfile(profileName) then
                    self:ApplyBindings()
                    self:RefreshClickCastingUI()  -- Refresh entire UI including bindings list
                end
            elseif InCombatLockdown() then
                print("|cffff9900DandersFrames:|r Cannot switch profiles during combat")
            else
                -- Already active, just refresh to update selection highlight
                self:RefreshProfilesPanel()
            end
        end)
        
        item:SetScript("OnDoubleClick", function()
            -- Double-click does the same as single-click
        end)
        
        -- Hooked, not Set: the styler owns OnEnter/OnLeave now, and overwriting
        -- them would take the hover wash straight back out again.
        item:HookScript("OnEnter", function(self)
            -- Show tooltip with full profile name
            if self.fullProfileName and #self.fullProfileName > 20 then
                DF.GUI:ShowTooltip(self, { title = self.fullProfileName, anchor = "ANCHOR_RIGHT" })
            end
        end)

        item:HookScript("OnLeave", function(self)
            DF.GUI:HideTooltip()
        end)

        -- 4px between rows: the rows carry a real border now, and at the old
        -- 2px pitch two adjacent borders read as one thick divider.
        yOffset = yOffset + 32
    end
    
    self.profileListContent:SetHeight(math.max(yOffset, 1))
    
    -- Update button states
    local canModify = self.selectedProfileName and not IsDefaultProfile(self.selectedProfileName)
    if self.profileDeleteBtn then
        self.profileDeleteBtn:SetEnabled(canModify)
        self.profileDeleteBtn:SetAlpha(canModify and 1 or 0.5)
    end
    if self.profileRenameBtn then
        self.profileRenameBtn:SetEnabled(canModify)
        self.profileRenameBtn:SetAlpha(canModify and 1 or 0.5)
    end
    
    -- Refresh loadout assignments
    self:RefreshLoadoutAssignments()
    
    -- Update auto-link info
    if self.autoLinkInfo then
        local specIndex = GetSpecialization() or 1
        local loadoutID = 0
        if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
            loadoutID = C_ClassTalents.GetActiveConfigID() or 0
        end
        local assignedProfile, isSpecific = self:GetProfileForLoadout(specIndex, loadoutID)
        
        -- Check auto-create setting
        local autoCreate = self.db and self.db.global and self.db.global.autoCreateProfiles
        if autoCreate == nil then autoCreate = true end
        
        if isSpecific and assignedProfile and assignedProfile == activeProfile then
            self.autoLinkInfo:SetText("|cff33cc33" .. L["[Linked]"] .. "|r " .. L["Profile matched to loadout"])
        elseif isSpecific and assignedProfile then
            self.autoLinkInfo:SetText("|cffff9900" .. L["[Override]"] .. "|r " .. format(L["Loadout expects: %s"], assignedProfile))
        elseif not isSpecific and loadoutID > 0 then
            if autoCreate then
                self.autoLinkInfo:SetText("|cff888888" .. L["[Unassigned]"] .. "|r " .. L["Will auto-create on switch"])
            else
                self.autoLinkInfo:SetText("|cff888888" .. L["[Unassigned]"] .. "|r " .. L["Auto-create disabled"])
            end
        else
            self.autoLinkInfo:SetText("|cff888888" .. L["[Unassigned]"] .. "|r " .. L["No loadout detected"])
        end
    end
end

function CC:RefreshLoadoutAssignments()
    if not self.loadoutContent then return end
    
    local C = self.UI_COLORS
    local themeColor = C.theme
    
    -- Update content width
    if self.loadoutScroll then
        local scrollWidth = self.loadoutScroll:GetWidth()
        if scrollWidth and scrollWidth > 0 then
            self.loadoutContent:SetWidth(scrollWidth - 10)
        else
            self.loadoutContent:SetWidth(200)  -- Fallback width
        end
    end
    
    -- Clear existing
    for _, child in ipairs({self.loadoutContent:GetChildren()}) do
        child:Hide()
        child:SetParent(nil)
    end
    
    local yOffset = 0
    local profiles = self:GetProfileList()
    local numSpecs = self:GetNumSpecs()
    
    for specIndex = 1, numSpecs do
        local _, specName, _, specIcon = GetSpecializationInfo(specIndex)
        if specName then
            -- Spec header
            local specHeader = CreateFrame("Frame", nil, self.loadoutContent, "BackdropTemplate")
            specHeader:SetPoint("TOPLEFT", 0, -yOffset)
            specHeader:SetPoint("RIGHT", 0, 0)
            specHeader:SetHeight(24)
            DF.GUI:CreateElementBackdrop(specHeader, {
                outline = false,
                bgColor     = { 0.12, 0.12, 0.12, 1 },
            })
            
            local icon = specHeader:CreateTexture(nil, "ARTWORK")
            icon:SetSize(18, 18)
            icon:SetPoint("LEFT", 4, 0)
            icon:SetTexture(specIcon)
            
            local specText = specHeader:CreateFontString(nil, "OVERLAY", "DFFontNormal")
            specText:SetPoint("LEFT", icon, "RIGHT", 6, 0)
            specText:SetText(specName)
            specText:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
            
            yOffset = yOffset + 26
            
            -- Get loadouts for this spec
            local loadouts = self:GetSpecLoadouts(specIndex)
            
            -- Always show spec default row (fallback when no specific loadout matches)
            local row = self:CreateLoadoutRow(self.loadoutContent, specIndex, 0, L["Spec Default"], profiles, yOffset)
            yOffset = yOffset + 24
            
            -- Show individual loadout rows if any exist
            for _, loadout in ipairs(loadouts) do
                local row = self:CreateLoadoutRow(self.loadoutContent, specIndex, loadout.configID, loadout.name, profiles, yOffset)
                yOffset = yOffset + 24
            end
            
            yOffset = yOffset + 4  -- Spacing between specs
        end
    end
    
    self.loadoutContent:SetHeight(math.max(yOffset, 1))
end

function CC:CreateLoadoutRow(parent, specIndex, configID, loadoutName, profiles, yOffset)
    local C = self.UI_COLORS

    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", 12, -yOffset)  -- Reduced indent
    row:SetPoint("RIGHT", -4, 0)
    row:SetHeight(22)
    
    -- Profile dropdown opener (create first so nameText can anchor to it)
    -- Use noFallback=true to only show specifically assigned profiles
    local assignedProfile = self:GetProfileForLoadout(specIndex, configID, true)

    -- Truncate text helper
    local function TruncText(text, maxLen)
        if not text or #text <= maxLen then return text or "" end
        return string.sub(text, 1, maxLen - 2) .. ".."
    end

    -- Sentinel key for the "no assignment" / "Clear Assignment" entry
    -- (table keys can't be nil). Its display text doubles as the opener label
    -- when the loadout has no specific profile assigned ("Not Set").
    local CLEAR_KEY = "\0__df_clear__"

    -- Build the current profile option set fresh on each open (dynamic list).
    -- The sentinel is keyed by assignment state: "Clear Assignment" when there
    -- is something to clear, otherwise the inert "Not Set" opener label.
    local function BuildProfileOptions()
        local options = {}
        local order = {}
        local hasAssignment = self:GetProfileForLoadout(specIndex, configID, true)
        if hasAssignment then
            options[CLEAR_KEY] = { text = "|cff888888"..L["Clear Assignment"].."|r" }
            table.insert(order, CLEAR_KEY)
        else
            -- Inert entry so the opener can render "Not Set"; selecting it is a no-op.
            options[CLEAR_KEY] = { text = L["Not Set"] }
            table.insert(order, CLEAR_KEY)
        end
        for _, profileName in ipairs(self:GetProfileList()) do
            -- Truncate the opener/menu label but keep the full name as the key.
            options[profileName] = { text = TruncText(profileName, 14) }
            table.insert(order, profileName)
        end
        options._order = order
        return options
    end

    -- Opener text reflects the assigned profile, or the sentinel ("Not Set").
    local function GetAssigned()
        return self:GetProfileForLoadout(specIndex, configID, true) or CLEAR_KEY
    end

    local dropdown = DF.GUI:CreateDropdown(row, nil, BuildProfileOptions(), nil, nil,
        nil,  -- callback
        GetAssigned,  -- customGet
        function(key)  -- customSet: assign (or clear) then rebuild the rows
            local profileName = (key ~= CLEAR_KEY) and key or nil
            CC:AssignProfileToLoadout(specIndex, configID, profileName)
            CC:RefreshLoadoutAssignments()
        end,
        { accent = CC.ACCENT, inline = true, optionsFunc = BuildProfileOptions })

    local dropBtn = dropdown
    dropBtn:ClearAllPoints()
    dropBtn:SetPoint("RIGHT", 0, 0)
    dropBtn:SetSize(115, 18)  -- Reduced width to give more space for loadout name

    -- Name text (constrained to not overlap opener)
    local nameText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    nameText:SetPoint("LEFT", 0, 0)
    nameText:SetPoint("RIGHT", dropBtn, "LEFT", -4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    -- Truncate loadout name if needed
    local displayName = loadoutName
    if #loadoutName > 12 then
        displayName = string.sub(loadoutName, 1, 10) .. ".."
    end
    nameText:SetText(displayName)
    nameText:SetTextColor(C.text.r, C.text.g, C.text.b)
    
    -- Hover tooltip on the opener (assignment state + hint). Hook the builder's
    -- internal button (the container's sole frame child) so we add the tooltip
    -- without clobbering the builder's own hover/click handling.
    local openerBtn = select(1, dropBtn:GetChildren())
    if openerBtn then
        openerBtn:HookScript("OnEnter", function(btn)
            if assignedProfile then
                DF.GUI:ShowTooltip(btn, {
                    title = format(L["Profile: %s"], assignedProfile),
                    lines = { L["Click to change assignment"] },
                })
            elseif configID == 0 then
                DF.GUI:ShowTooltip(btn, {
                    title = L["No default profile set"],
                    lines = {
                        L["Click to assign a profile that activates"],
                        L["when switching to this spec"],
                    },
                })
            else
                DF.GUI:ShowTooltip(btn, {
                    title = L["Using spec default"],
                    lines = { L["Click to assign a specific profile"] },
                })
            end
        end)
        openerBtn:HookScript("OnLeave", function()
            DF.GUI:HideTooltip()
        end)
    end

    return row
end

-- =========================================================================

-- PROFILE DIALOGS
-- =========================================================================

-- These all used to be Blizzard StaticPopups raised above our UI by hand, because
-- the settings window sits at FULLSCREEN_DIALOG and a StaticPopup opens behind it.
-- DF's own popup lives at that strata already, so the raise helper is gone.

function CC:ShowNewProfileDialog()
    DF.GUI:PromptName({
        title       = L["New Profile"],
        message     = L["Enter new profile name:"],
        acceptLabel = L["Create"],
        onAccept    = function(name)
            if name == "" then return end
            if CC:CreateProfile(name, CC:GetActiveProfileName()) then
                CC:RefreshProfilesPanel()
            end
        end,
    })
end

function CC:ShowCopyProfileDialog(sourceName)
    DF.GUI:PromptName({
        title       = L["Copy Profile"],
        message     = format(L["Enter name for copy of '%s':"], sourceName),
        default     = sourceName .. " Copy",
        acceptLabel = L["Copy"],
        onAccept    = function(name)
            if name == "" then return end
            if CC:CreateProfile(name, sourceName) then
                CC:RefreshProfilesPanel()
            end
        end,
    })
end

function CC:ShowRenameProfileDialog(oldName)
    DF.GUI:PromptName({
        title       = L["Rename Profile"],
        message     = format(L["Enter new name for '%s':"], oldName),
        default     = oldName,
        acceptLabel = L["Rename"],
        onAccept    = function(name)
            if name == "" or name == oldName then return end
            if CC:RenameProfile(oldName, name) then
                CC.selectedProfileName = name
                CC:RefreshProfilesPanel()
            end
        end,
    })
end

function CC:ShowDeleteProfileDialog(profileName)
    DF:ShowPopupAlert({
        title   = L["Delete Profile"],
        message = format(L["Delete profile '%s'?\n\nThis cannot be undone."], profileName),
        buttons = {
            {
                label = L["Delete"],
                onClick = function()
                    if CC:DeleteProfile(profileName) then
                        CC.selectedProfileName = nil
                        CC:RefreshProfilesPanel()
                    end
                end,
            },
            { label = L["Cancel"] },
        },
    })
end

function CC:ShowClearAllConfirmation()
    local bindingCount = self.profile and self.profile.bindings and #self.profile.bindings or 0
    local profileName = self.currentProfileName or "Default"
    
    if bindingCount == 0 then
        print("|cffff9900DandersFrames:|r No bindings to clear.")
        return
    end
    
    DF:ShowPopupAlert({
        title   = L["Reset to Defaults"],
        message = format(L["Reset all bindings to defaults?\n\nThis will set:\n• Left Click = Target Unit\n• Right Click = Open Menu\n\n%sThis cannot be undone.%s"], "|c" .. DF.GUI:ToneHex("danger"), "|r"),
        buttons = {
            { label = L["Reset to Defaults"], onClick = function() CC:ResetBindingsToDefaults() end },
            { label = L["Cancel"] },
        },
        buttonWidth = 130,
    })
end

-- Reset bindings to Blizzard-style defaults (Target + Menu)
-- Same as what Blizzard uses when you reset click-casting
function CC:ResetBindingsToDefaults()
    if not self.profile then return end
    
    local count = #self.profile.bindings
    
    -- Clear all bindings
    wipe(self.profile.bindings)
    
    -- Add default bindings (same as Blizzard defaults)
    -- Left Click = Target Unit
    table.insert(self.profile.bindings, {
        enabled = true,
        bindType = "mouse",
        button = "LeftButton",
        modifiers = "",
        actionType = "target",
        combat = "always",
        frames = { dandersFrames = true, otherFrames = true },
        fallback = { mouseover = false, target = false, selfCast = false },
    })
    
    -- Right Click = Open Menu
    table.insert(self.profile.bindings, {
        enabled = true,
        bindType = "mouse",
        button = "RightButton",
        modifiers = "",
        actionType = "menu",
        combat = "always",
        frames = { dandersFrames = true, otherFrames = true },
        fallback = { mouseover = false, target = false, selfCast = false },
    })
    
    -- Rebuild secure bindings
    self:BuildKeyboardBindingSnippets()
    
    -- Re-apply to all frames
    if not InCombatLockdown() then
        self:ApplyBindings()
    end
    
    -- Refresh the UI
    self:RefreshClickCastingUI()
    
    print("|cff33cc33DandersFrames:|r Reset bindings to defaults (Target + Menu). " .. count .. " custom binding(s) removed.")
end

function CC:ShowExportDialog()
    local exportString = self:ExportProfile()
    
    if not exportString or exportString == "" then
        -- Error message already printed by ExportProfile
        DF:ShowPopupAlert({
            title   = L["Export Failed"],
            tone    = "danger",
            message = L["Export failed. Please try again or check for errors."],
            buttons = { { label = L["OK"] } },
        })
        return
    end

    -- readOnly: the string is there to be selected and copied, not edited. It
    -- opens fully selected, so Ctrl+C alone is enough.
    DF:ShowPopupInput({
        title       = L["Export Profile"],
        message     = L["Copy this string to share your profile:"],
        text        = exportString,
        multiline   = true,
        readOnly    = true,
        cancelLabel = L["Done"],
    })
end

function CC:ShowImportDialog()
    DF:ShowPopupInput({
        title       = L["Import Profile"],
        message     = L["Paste a profile string to import:"],
        multiline   = true,
        acceptLabel = L["Import"],
        onAccept    = function(importString)
            if not importString or importString == "" then return end
            local success, result = CC:ImportProfile(importString)
            if success then
                print("|cff33cc33DandersFrames:|r Profile imported: " .. result)
                CC:RefreshProfilesPanel()
            else
                print("|cffff0000DandersFrames:|r Import failed: " .. (result or "unknown error"))
            end
        end,
    })
end

-- =========================================================================
