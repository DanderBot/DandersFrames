-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). See the same note at the head of GUI/Panel.lua.
local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local format = string.format
local tinsert, tsort = table.insert, table.sort

-- ============================================================
-- PROFILES PAGES
-- The Profiles rail item's own sidebar (GUI/ModuleRegistry.lua): Manage,
-- Spec & Character, Auto Layouts, Click Casting, Import / Export and Changed
-- Settings, in that order. DF:SetupProfilesPages is called from the page chain
-- (GUI/Pages/Modules.lua) where the old "profiles" category used to be built.
--
-- ★ EVERY PAGE HERE IS MODE-NEUTRAL (THE PROFILES SIDEBAR, DandersFrames/GUI/GUI.lua):
-- BuildPage keeps one build for it whatever mode sits under the Profiles view,
-- and hands the builder the PARTY table as `db`, which none of them reads. A
-- page that needs a mode asks for it on the page: Import / Export's "Export
-- for" / "Import for", Changed Settings' scope picker. Auto Layouts is always
-- Raid's.
-- ============================================================

-- A rename changes no setting, so there is no FullProfileRefresh: the pages that
-- print profile NAMES are told directly.
local function RefreshAfterRename()
    GUI:InvalidatePage("profiles_spec")
    GUI:InvalidatePage("profiles_importexport")
    local page = GUI.Pages and GUI.Pages.profiles_manage
    if page and page:IsShown() and page.Refresh then page:Refresh() end
end

-- Helper to add a group to a column without the Add() row-height pass: a group
-- sizes itself.
local function Adder(self)
    return function(widget, col, colNum)
        widget.layoutCol = colNum or col
        tinsert(self.children, widget)
    end
end

-- Small themed checkbox (the Import / Export rows). Moved here with the page.
local function CreateSmallCheckbox(parent, label, initialChecked)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(100, 18)

    local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
    cb:SetPoint("LEFT", 0, 0)
    GUI:StyleCheckButton(cb, { size = 14, checkSize = 8, themeRoot = parent })

    local txt = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    txt:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    txt:SetText(label)
    txt:SetTextColor(0.85, 0.85, 0.85)
    cb.label = txt

    cb:SetChecked(initialChecked or false)

    container.checkbox = cb
    container.SetChecked = function(self, val) cb:SetChecked(val) end
    container.GetChecked = function(self) return cb:GetChecked() end
    container.Enable = function(self) cb:Enable(); container:SetAlpha(1) end
    container.Disable = function(self) cb:Disable(); container:SetAlpha(0.35) end

    return container
end

local function CreateSmallButton(parent, text, width)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    GUI:StyleButton(btn, { width = width, height = 20, text = text })
    btn.text = btn.Text
    return btn
end

-- A one-line status the page writes into after it is built (the import box's
-- result, the click-cast export's profile name). The settings label factory
-- measures its text once; these change on every click.
local function CreateStatusLine(parent, width)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(width, 32)
    local fs = holder:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 0, -2)
    fs:SetPoint("TOPRIGHT", 0, -2)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    holder.Text = fs
    return holder
end

local function DimText(text)
    local c = GUI.Colors.textDim
    return format("|cff%02x%02x%02x%s|r", math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255), text)
end

local function ToneText(tone, text)
    return "|c" .. GUI:ToneHex(tone) .. text .. "|r"
end

-- ============================================================
-- MANAGE
-- ============================================================
local function BuildManage(self, db, Add, AddSpace, AddSyncPoint)
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
    local currentGroup = GUI:CreateSettingsGroup(self.child, 280)
    currentGroup:AddWidget(GUI:CreateHeader(self.child, L["Current Profile"]), 40)
    currentGroup:AddWidget(GUI:CreateLabel(self.child, "|cff00ff00" .. currentProfile .. "|r", 240), 25)
    AddToSection(currentGroup, nil, 1)
    
    -- Available Profiles Group
    local listGroup = GUI:CreateSettingsGroup(self.child, 280)
    listGroup:AddWidget(GUI:CreateHeader(self.child, L["Available Profiles"]), 40)
    
    -- Container for the profile list. Width comes from the group rather than a
    -- literal, so the rows reach the group's right edge.
    local maxListHeight = 180
    local contentHeight = #profiles * 28 + 10
    local listHeight = math.min(contentHeight, maxListHeight)
    local listContainer = CreateFrame("Frame", nil, self.child, "BackdropTemplate")
    local listWidth = GUI:GroupInnerWidth(listGroup)
    listContainer:SetSize(listWidth, listHeight)
    GUI:CreateElementBackdrop(listContainer, { bgColor = {0, 0, 0, 0.3}, borderColor = {0.3, 0.3, 0.3, 1} })
    listGroup:AddWidget(listContainer, listHeight + 5)
    
    -- Create scroll frame for the profile list
    local profileScroll = CreateFrame("ScrollFrame", nil, listContainer, "ScrollFrameTemplate")
    profileScroll:SetPoint("TOPLEFT", 2, -2)
    profileScroll:SetPoint("BOTTOMRIGHT", -22, 2)
    
    GUI.StyleScrollBar(profileScroll)
    -- ☠ The right inset differs by whether the bar is showing, and the scroll
    -- child has to follow it — a ScrollFrame child needs an explicit width, so it
    -- cannot just anchor to the frame. Get this wrong and the rows either tuck
    -- under the scrollbar or leave a fresh gap, and only once you have enough
    -- profiles to trigger the bar (7+ at 28px in a 180px list), which is exactly
    -- the case nobody tests.
    local rightInset = 22
    if contentHeight <= maxListHeight and profileScroll.ScrollBar then
        profileScroll.ScrollBar:Hide()
        profileScroll:SetPoint("BOTTOMRIGHT", -4, 2)
        rightInset = 4
    end

    -- Create scroll child to hold profile buttons
    local profileScrollChild = CreateFrame("Frame", nil, profileScroll)
    profileScrollChild:SetSize(listWidth - 2 - rightInset, contentHeight)
    profileScroll:SetScrollChild(profileScrollChild)
    
    -- Profile buttons inside scroll child
    local py = -3
    for i, p in ipairs(profiles) do
        -- Standard theme hover: picking a profile IS the action of this page,
        -- so the row gets the same accent wash as any other button rather than
        -- the neutral "this is a place" grey. The "this is the active profile"
        -- cue is SetActive's accent fill + border, which stays visible under
        -- the hover (applyHoverState keeps the active border).
        -- Anchored on BOTH sides so the row fills the list, matching the click-cast
        -- profiles panel. StyleButton only calls SetSize when given a width, so
        -- passing height alone leaves the anchors to drive it.
        local btn = CreateFrame("Button", nil, profileScrollChild, "BackdropTemplate")
        btn:SetPoint("TOPLEFT", 2, py)
        btn:SetPoint("TOPRIGHT", -2, py)
        DF.GUI:StyleButton(btn, {
            height = 24,
            text = p, font = "DFFontHighlightSmall",
        })
        btn:SetActive(p == currentProfile)
        btn:SetScript("OnClick", function() 
            DF:SetProfile(p) 
            -- SetProfile ended in FullProfileRefresh, which already rebuilt this page.
            if GUI.RefreshCurrentPageAfterFullRefresh then GUI.RefreshCurrentPageAfterFullRefresh() elseif GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
        end)
        py = py - 28
    end
    
    AddToSection(listGroup, nil, 1)
    
    -- Create New Profile Group
    local createGroup = GUI:CreateSettingsGroup(self.child, 280)
    createGroup:AddWidget(GUI:CreateHeader(self.child, L["Create New Profile"]), 40)
    
    local input = GUI:CreateInput(self.child, L["Profile Name"], 240)
    createGroup:AddWidget(input, 50)
    
    -- Button row for create actions
    local btnRow = CreateFrame("Frame", nil, self.child)
    btnRow:SetSize(240, 28)
    
    local createBtn = GUI:CreateButton(self.child, L["Create Empty"], 115, 24, function()
        local text = input.EditBox:GetText()
        if not text or text == "" then
            DF:Err("Please enter a profile name.")
            return
        end
        DF:SetProfile(text) 
        input.EditBox:SetText("")
        -- SetProfile ended in FullProfileRefresh, which already rebuilt this page.
        if GUI.RefreshCurrentPageAfterFullRefresh then GUI.RefreshCurrentPageAfterFullRefresh() elseif GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
    end)
    createBtn:SetParent(btnRow)
    createBtn:SetPoint("LEFT", 0, 0)
    
    local dupeBtn = GUI:CreateButton(self.child, L["Duplicate Current"], 115, 24, function()
        local text = input.EditBox:GetText()
        if not text or text == "" then
            DF:Err("Please enter a name for the duplicated profile.")
            return
        end
        if DF:DuplicateProfile(text) then
            input.EditBox:SetText("")
            -- DuplicateProfile ended in FullProfileRefresh, which already rebuilt this page.
            if GUI.RefreshCurrentPageAfterFullRefresh then GUI.RefreshCurrentPageAfterFullRefresh() elseif GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
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
    local actionsGroup = GUI:CreateSettingsGroup(self.child, 280)
    actionsGroup:AddWidget(GUI:CreateHeader(self.child, L["Profile Actions"]), 40)
    
    actionsGroup:AddWidget(GUI:CreateIconButton(self.child, "delete", L["Delete Current Profile"], 240, 26, function()
        local p = DF:GetCurrentProfile()
        if p == "Default" then
            DF:Err("Cannot delete Default profile.")
            return
        end
        DF:ShowPopupAlert({
            title   = L["Delete Profile"],
            message = format(L["Delete profile '%s'?\n\nThis cannot be undone."], p),
            buttons = {
                {
                    label = L["Delete"],
                    onClick = function()
                        DF:SetProfile("Default")
                        DF:DeleteProfile(p)
                        if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                    end,
                },
                { label = L["Cancel"] },
            },
        })
    end, nil, "left"), 32)

    -- Rename (DF:RenameProfile, Core/Profile.lua). The prompt says what happens
    -- to OTHER characters on the old name: their saved choice cannot be reached
    -- from this one, and they fall back to Default at their next login.
    actionsGroup:AddWidget(GUI:CreateIconButton(self.child, "edit", L["Rename Current Profile"], 240, 26, function()
        local p = DF:GetCurrentProfile()
        if p == "Default" then
            DF:Err(L["The Default profile can't be renamed."])
            return
        end
        GUI:PromptName({
            title       = L["Rename Profile"],
            message     = format(L["Enter new name for '%s':"], p) .. "\n\n"
                .. L["Other characters using this profile switch to Default at their next login."],
            default     = p,
            acceptLabel = L["Rename"],
            onAccept    = function(name)
                if name == "" or name == p then return end
                if DF:RenameProfile(p, name) then RefreshAfterRename() end
            end,
        })
    end, nil, "left"), 32)

    actionsGroup:AddWidget(GUI:CreateIconButton(self.child, "refresh", L["Reset Profile to Defaults"], 240, 26, function()
        DF:ShowPopupAlert({
            title   = L["Reset Profile to Defaults"],
            message = L["Reset current profile to defaults?\nEverything in it goes back to how a new profile starts, including Party, Raid, colours and auto layouts."],
            buttons = {
                {
                    label = L["Reset"],
                    onClick = function()
                        DF:ResetFullProfile()
                        -- It ended in FullProfileRefresh, which already rebuilt this page.
                        if GUI.RefreshCurrentPageAfterFullRefresh then GUI.RefreshCurrentPageAfterFullRefresh() elseif GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                    end,
                },
                { label = L["Cancel"] },
            },
        })
    end, nil, "left"), 32)
    
    AddToSection(actionsGroup, nil, 2)
    
    -- Copy Settings Group
    local copyGroup = GUI:CreateSettingsGroup(self.child, 280)
    copyGroup:AddWidget(GUI:CreateHeader(self.child, L["Copy Settings"]), 40)
    copyGroup:AddWidget(GUI:CreateLabel(self.child, L["Copy all settings between Party and Raid modes."], 240), 25)
    
    -- Both directions are the same confirm with the modes swapped.
    local function ConfirmCopyProfile(src, dest, message)
        DF:ShowPopupAlert({
            title   = L["Copy Settings"],
            message = message,
            buttons = {
                {
                    label = L["Copy"],
                    onClick = function()
                        DF:CopyProfile(src, dest)
                        -- It ended in FullProfileRefresh, which already rebuilt this page.
                        if GUI.RefreshCurrentPageAfterFullRefresh then GUI.RefreshCurrentPageAfterFullRefresh() elseif GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
                    end,
                },
                { label = L["Cancel"] },
            },
        })
    end

    copyGroup:AddWidget(GUI:CreateIconButton(self.child, "chevron_right", L["Party to Raid"], 240, 26, function()
        ConfirmCopyProfile("party", "raid",
            L["Copy Party settings to Raid?\n\nThis will overwrite all Raid settings with your current Party settings."])
    end, nil, "left"), 32)

    copyGroup:AddWidget(GUI:CreateIconButton(self.child, "chevron_right", L["Raid to Party"], 240, 26, function()
        ConfirmCopyProfile("raid", "party",
            L["Copy Raid settings to Party?\n\nThis will overwrite all Party settings with your current Raid settings."])
    end, nil, "left"), 32)
    
    AddToSection(copyGroup, nil, 2)
    
    -- See Also links
    AddSpace(GUI.Space.block, "both")
    Add(GUI:CreateSeeAlso(self.child, {
        {pageId = "profiles_spec", label = L["Spec & Character"]},
        {pageId = "profiles_importexport", label = L["Import/Export"]},
    }), 30, "both")
end

-- ============================================================
-- SPEC & CHARACTER
-- The auto-switch-by-spec panel, moved out of Manage. Per CHARACTER
-- (DandersFramesCharDB), where everything on Manage is per account.
-- ============================================================
local function BuildSpec(self, db, Add, AddSpace, AddSyncPoint)
    local profiles = DF:GetProfiles()
    local AddToSection = Adder(self)

    local charGroup = GUI:CreateSettingsGroup(self.child, 280)
    charGroup:AddWidget(GUI:CreateHeader(self.child, L["Character"]), 40)
    charGroup:AddWidget(GUI:CreateLabel(self.child,
        format(L["This character uses the profile: %s"], DF:GetCurrentProfile()), 240), nil)
    charGroup:AddWidget(GUI:CreateLabel(self.child,
        L["Everything on this page is saved for this character only."], 240), nil)
    AddToSection(charGroup, nil, 1)

    -- Auto-Switch by Spec Group
    local specGroup = GUI:CreateSettingsGroup(self.child, 280)
    specGroup:AddWidget(GUI:CreateHeader(self.child, L["Auto-Switch by Spec"]), 40)
    
    -- Initialize per-character data if needed
    if not DandersFramesCharDB then 
        DandersFramesCharDB = { enableSpecSwitch = false, specProfiles = {} } 
    end
    
    local specEnableCb = specGroup:AddWidget(GUI:CreateCheckbox(self.child, L["Enable Spec Auto-Switch"], DandersFramesCharDB, "enableSpecSwitch"), 30)
    specEnableCb.keepEnabled = true
    -- The enable flag lives on the per-character DB (not the page db arg), so
    -- the grey predicate reads DandersFramesCharDB directly.
    specGroup.disableChildrenOn = function() return not (DandersFramesCharDB and DandersFramesCharDB.enableSpecSwitch) end

    local numSpecs = GetNumSpecializations and GetNumSpecializations() or 0
    if numSpecs > 0 then
        -- Build profile list for dropdown
        local pList = { [""]= L["None"] }
        for _, p in ipairs(profiles) do 
            pList[p] = p 
        end
        
        if not DandersFramesCharDB.specProfiles then 
            DandersFramesCharDB.specProfiles = {} 
        end
        
        for i = 1, numSpecs do
            local _, name = C_SpecializationInfo.GetSpecializationInfo(i)
            if name then
                local specIdx = i  -- capture for the get/set closures
                -- Custom get/set: an unset spec reads back as "" so it displays
                -- the "None" option instead of the raw nil ("nil") value. None is
                -- stored as nil to keep the DB tidy; CheckProfileAutoSwitch treats
                -- both nil and "" as "don't switch".
                specGroup:AddWidget(GUI:CreateDropdown(self.child, name, pList, nil, nil, nil,
                    function() return DandersFramesCharDB.specProfiles[specIdx] or "" end,
                    function(v) DandersFramesCharDB.specProfiles[specIdx] = (v ~= "" and v) or nil end), 55)
            end
        end
    else
        specGroup:AddWidget(GUI:CreateLabel(self.child, L["Specialization data not available."], 240), 25)
    end
    

    AddToSection(specGroup, nil, 2)
end

-- ============================================================
-- CLICK CASTING
-- The click-cast profiles panel (ClickCasting/UI/ProfilesPanel.lua) HOSTED
-- here, not copied: Binds builds it once (ClickCasting/UI/Main.lua) and this
-- page re-parents that one frame into a holder of its own on every build and
-- every show. Binds' old internal Profiles tab now opens this page.
-- ⚠ Click-cast profiles stay their own system -- per class, switched by talent
-- loadout -- and are NOT linked to DandersFrames profiles. The page says so.
-- ============================================================
local CLICKCAST_PANEL_H = 500

local function BuildClickCast(self, db, Add, AddSpace)
    Add(GUI:CreateLabel(self.child,
        L["Click-cast profiles are saved per class and switch with your talent loadout. They are separate from the profiles on the Manage page."]),
        nil, "both")
    AddSpace(GUI.Space.block, "both")

    local CC = DF.ClickCast
    if not (CC and CC.db and CC.profilesPanel) then
        Add(GUI:CreateLabel(self.child, L["Click casting is not available."]), nil, "both")
        return
    end

    local holder = CreateFrame("Frame", nil, self.child)
    holder:SetSize(400, CLICKCAST_PANEL_H)
    Add(holder, CLICKCAST_PANEL_H, "both")

    -- Into THIS build's holder, every time it shows: a rebuild retires the
    -- previous holder (and would take the panel to the trash with it), and Binds
    -- may have refreshed the panel while it was parked.
    local function Adopt()
        local panel = CC.profilesPanel
        if not panel then return end
        if panel:GetParent() ~= holder then
            panel:SetParent(holder)
            panel:SetFrameLevel(holder:GetFrameLevel() + 1)
            panel:ClearAllPoints()
            panel:SetAllPoints(holder)
        end
        panel:Show()
        if CC.RefreshProfilesPanel then CC:RefreshProfilesPanel() end
    end
    holder:SetScript("OnShow", Adopt)
    Adopt()
end

-- ============================================================
-- IMPORT / EXPORT
-- ONE paste box for every string the addon exports. DF.ImportRouter
-- (Features/ImportRouter.lua) says what the string is; each kind goes to the
-- flow that already owns it:
--   profile   -> the profile import below (categories, Party / Raid, Create New)
--   clickcast -> CC:ImportProfile, which keeps its binding picker
--   filter    -> DF.ImportFilterString, the Filter Designer's own flow
--   wizard    -> refused, clearly
-- Export picks WHAT first: a DandersFrames profile (full or partial, the old
-- UI), the active click-cast profile, or a filter.
-- ============================================================

-- Router error -> what the user reads.
local function ImportErrorText(parsed)
    local err = parsed and parsed.err
    if err == "empty" then return L["Paste a string first."] end
    if err == "wizard" then return L["Setup wizard strings are no longer supported."] end
    if err == "unknown" then return L["That doesn't look like a DandersFrames string."] end
    if err == "unavailable" then
        if parsed.kind == "clickcast" then return L["Click casting is not available."] end
        return L["Import failed. Please try again or check for errors."]
    end
    if parsed.kind == "filter" then
        if err == "newer" then return L["This filter was exported by a newer version of DandersFrames."] end
        if err == "tooLarge" then return L["That filter string is too large."] end
        return L["That filter string is corrupt or incomplete."]
    end
    if parsed.kind == "clickcast" then return L["Failed to decode import data"] end
    -- The profile validator's own reason ("Invalid encoding", "Legacy format -
    -- please re-export", ...), as the old Parse String showed it.
    return tostring(err)
end

local EXPORT_KINDS = { "profile", "clickcast", "filter" }

local function BuildImportExport(self, db, Add, AddSpace, AddSyncPoint)
    self.exportCheckboxes = {}
    self.importCheckboxes = {}
    self.exportFrameTypes = {party = true, raid = true}
    self.importFrameTypes = {party = true, raid = true}
    self.parsedImport = nil
    self.exportKind = self.exportKind or "profile"
    local AddToSection = Adder(self)

    -- Derived from the category registry (single source of truth) so this list
    -- can never drift from DF.ExportCategories when categories change.
    local categoryOrder = {}
    for cat in pairs(DF.ExportCategoryInfo) do tinsert(categoryOrder, cat) end
    tsort(categoryOrder, function(a, b)
        return (DF.ExportCategoryInfo[a].order or 99) < (DF.ExportCategoryInfo[b].order or 99)
    end)

    -- Page-scope note: a profile export or import is the whole profile, gated
    -- only by the Export for / Import for rows -- Profiles has no mode tab.
    local scopeBanner = GUI:CreateInfoBanner(self.child, {
        tone = "info", dismissKey = "importexport_scope",
        text = L["Profiles include both Party and Raid settings. Use the 'Export for' and 'Import for' checkboxes to choose which mode's settings are included."],
    })
    Add(scopeBanner, scopeBanner.layoutHeight or 44, "both")

    -- ========================================
    -- IMPORT: the one paste box (column 1) and what to do with it (column 2)
    -- ========================================
    local importGroup = GUI:CreateSettingsGroup(self.child, 280)
    importGroup:AddWidget(GUI:CreateHeader(self.child, L["Import String"]), 40)
    importGroup:AddWidget(GUI:CreateLabel(self.child,
        L["Paste any DandersFrames string: a profile, a click-cast profile or a filter."], 240), nil)

    local importArea = GUI:CreateTextArea(self.child, { width = 240, height = 80 })
    self.importEditBox = importArea.EditBox
    importGroup:AddWidget(importArea, 85)

    local status = CreateStatusLine(self.child, 240)
    local function SetStatus(text) status.Text:SetText(text or "") end
    SetStatus(DimText(L["Paste string above, then Parse"]))

    -- Reset the profile half of the column-2 options to "nothing parsed".
    local function ResetProfileOptions()
        if self.importNameEdit then self.importNameEdit:SetText(L["Imported Profile"]) end
        if self.createNewProfileCheck then self.createNewProfileCheck:Disable(); self.createNewProfileCheck:SetChecked(true) end
        for _, cb in pairs(self.importCheckboxes) do cb:SetChecked(false); cb:Disable() end
        if self.importPartyCheck then self.importPartyCheck:Disable(); self.importPartyCheck:SetChecked(false) end
        if self.importRaidCheck then self.importRaidCheck:Disable(); self.importRaidCheck:SetChecked(false) end
    end

    -- Parse: say what the string is, and for a profile fill in the options.
    importGroup:AddWidget(GUI:CreateButton(self.child, L["Parse String"], 240, 26, function()
        if not self.importEditBox then return end
        local parsed = DF.ImportRouter.Parse(self.importEditBox:GetText())
        self.parsedImport = parsed
        ResetProfileOptions()
        if not parsed.ok then
            local msg = ImportErrorText(parsed)
            SetStatus(ToneText("danger", msg))
            DF:Err(msg)
            self:RefreshStates()
            return
        end

        if parsed.kind == "clickcast" then
            SetStatus(format("%s %s", ToneText("success", L["OK"]),
                format(L["Click-cast profile: %s"], parsed.name or L["Imported Profile"])))
        elseif parsed.kind == "filter" then
            SetStatus(format("%s %s", ToneText("success", L["OK"]),
                format(L["Filter: %s"], parsed.name or "")))
        else
            local info = parsed.info or DF:GetImportInfo(parsed.data)
            parsed.info = info
            SetStatus(format("%s v%s %s%s", ToneText("success", L["OK"]),
                (tostring(info.version):gsub("^[vV]", "")),
                info.hasParty and L["[Party]"] or "",
                info.hasRaid and L["[Raid]"] or ""))
            if self.importNameEdit and info.profileName then
                self.importNameEdit:SetText(info.profileName)
            end
            if self.createNewProfileCheck then
                self.createNewProfileCheck:Enable()
                self.createNewProfileCheck:SetChecked(true)
            end
            local availableCats = {}
            for _, cat in ipairs(info.detectedCategories or {}) do availableCats[cat] = true end
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
        end
        -- The profile options show only for a profile string.
        self:RefreshStates()
    end), 30)
    importGroup:AddWidget(status, 34)
    AddToSection(importGroup, nil, 1)

    -- "What to Import": a DandersFrames profile's options. Shown only once a
    -- profile string has been parsed -- every other kind has its own flow.
    local importSettingsGroup = GUI:CreateSettingsGroup(self.child, 280)
    importSettingsGroup.hideOn = function()
        local p = self.parsedImport
        return not (p and p.ok and p.kind == "profile")
    end
    importSettingsGroup:AddWidget(GUI:CreateHeader(self.child, L["What to Import"]), 40)

    local impNameInput = GUI:CreateInput(self.child, L["Profile Name"], 240)
    impNameInput.EditBox:SetText(L["Imported Profile"])
    self.importNameEdit = impNameInput.EditBox
    importSettingsGroup:AddWidget(impNameInput, 50)

    local createNewRow = CreateFrame("Frame", nil, self.child)
    createNewRow:SetSize(240, 20)
    local createNewCheck = CreateSmallCheckbox(createNewRow, L["Create New Profile"], true)
    createNewCheck:SetPoint("LEFT", 0, 0)
    createNewCheck:Disable()
    self.createNewProfileCheck = createNewCheck
    importSettingsGroup:AddWidget(createNewRow, 24)

    importSettingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Import for"], 240), 22)
    local ftRowImp = CreateFrame("Frame", nil, self.child)
    ftRowImp:SetSize(240, 20)
    local partyImp = CreateSmallCheckbox(ftRowImp, L["Party"], false)
    partyImp:SetPoint("LEFT", 0, 0)
    partyImp:Disable()
    partyImp.checkbox:SetScript("OnClick", function(s) self.importFrameTypes.party = s:GetChecked() end)
    self.importPartyCheck = partyImp
    local raidImp = CreateSmallCheckbox(ftRowImp, L["Raid"], false)
    raidImp:SetPoint("LEFT", 80, 0)
    raidImp:Disable()
    raidImp.checkbox:SetScript("OnClick", function(s) self.importFrameTypes.raid = s:GetChecked() end)
    self.importRaidCheck = raidImp
    importSettingsGroup:AddWidget(ftRowImp, 24)

    importSettingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Settings to include"], 240), 22)
    for _, cat in ipairs(categoryOrder) do
        local info = DF.ExportCategoryInfo[cat]
        local catRow = CreateFrame("Frame", nil, self.child)
        catRow:SetSize(240, 18)
        local cb = CreateSmallCheckbox(catRow, L[info.name], false)
        cb:SetPoint("LEFT", 0, 0)
        cb:Disable()
        self.importCheckboxes[cat] = cb
        importSettingsGroup:AddWidget(catRow, 20)
    end
    AddToSection(importSettingsGroup, nil, 2)

    -- The profile import itself -- unchanged from the old page.
    local function ImportProfile(parsed)
        local selectedCats = {}
        for _, cat in ipairs(categoryOrder) do
            if self.importCheckboxes[cat]:GetChecked() then tinsert(selectedCats, cat) end
        end
        if #selectedCats == 0 then
            DF:Err("Select at least one category.")
            return
        end
        local selectedFrameTypes = {
            party = self.importPartyCheck:GetChecked(),
            raid = self.importRaidCheck:GetChecked(),
        }
        if not selectedFrameTypes.party and not selectedFrameTypes.raid then
            DF:Err("Select Party or Raid.")
            return
        end

        local createNew = self.createNewProfileCheck and self.createNewProfileCheck:GetChecked()
        local profileName = self.importNameEdit and self.importNameEdit:GetText()
        if profileName == "" then profileName = nil end

        local confirmText
        if createNew then
            confirmText = L["Create new profile '"] .. (profileName or L["Imported Profile"]) .. L["'?\n\nThis will copy your current settings, then apply the selected import categories on top."]
        else
            local currentProfile = DF:GetCurrentProfile() or "Default"
            confirmText = L["Import settings into current profile?\n\n"] .. "|c" .. GUI:ToneHex("danger") .. L["WARNING: This will permanently overwrite settings in your '"] .. currentProfile .. L["' profile."] .. "|r\n\n" .. L["Tip: Check 'Create New Profile' to import without affecting your current settings."]
        end

        -- Everything the accept needs is captured here rather than stapled onto
        -- the dialog afterwards, so there is no window in which the popup exists
        -- without its payload.
        local importData = parsed.data
        DF:ShowPopupAlert({
            title   = L["Import Profile"],
            message = confirmText,
            buttons = {
                {
                    label = L["Import"],
                    onClick = function()
                        if not importData then return end
                        -- ☠ PCALL the apply. It creates the profile and switches to it BEFORE
                        -- merging the payload, so a throw mid-apply would leave the user in a
                        -- half-imported profile with no message and no FullProfileRefresh.
                        local ok, applied = pcall(DF.ApplyImportedProfile, DF, importData,
                            selectedCats, selectedFrameTypes, profileName, createNew)
                        if not ok then
                            DF:Err(L["Import failed. Please try again or check for errors."])
                        end
                        -- A completed import returns true only after its FullProfileRefresh,
                        -- which already rebuilt this page. Any other outcome may have changed
                        -- data without one, so it keeps the rebuild.
                        if ok and applied == true and GUI.RefreshCurrentPageAfterFullRefresh then
                            GUI.RefreshCurrentPageAfterFullRefresh()
                        elseif GUI.RefreshCurrentPage then
                            GUI:RefreshCurrentPage()
                        end
                    end,
                },
                { label = L["Cancel"] },
            },
        })
    end

    -- A click-cast string: CC:ImportProfile owns the rest, binding picker and all.
    local function ImportClickCast(parsed)
        local CC = DF.ClickCast
        if not (CC and CC.ImportProfile) then
            DF:Err(L["Click casting is not available."])
            return
        end
        local okCall, success, result = pcall(CC.ImportProfile, CC, parsed.str)
        if not okCall then
            DF:Err(L["Import failed. Please try again or check for errors."])
        elseif success then
            -- true + a name: imported; true + anything else: the binding picker is up
            -- and finishes the import itself.
            if type(result) == "string" and result ~= "Showing import dialog" then
                DF:Say(format(L["Profile imported: %s"], result))
            end
            if CC.RefreshProfilesPanel then CC:RefreshProfilesPanel() end
        elseif result then
            DF:Err(format(L["Import failed: %s"], result))
        else
            DF:Err(L["Import failed. Please try again or check for errors."])
        end
    end

    local importActionsGroup = GUI:CreateSettingsGroup(self.child, 280)
    importActionsGroup:AddWidget(GUI:CreateHeader(self.child, L["Import"]), 40)
    importActionsGroup:AddWidget(GUI:CreateIconButton(self.child, "download", L["Import"], 240, 26, function()
        local parsed = self.parsedImport
        -- Edited since it was parsed: parse what is in the box now.
        local now = self.importEditBox and DF.ImportRouter.Trim(self.importEditBox:GetText()) or ""
        if not parsed or parsed.str ~= now then
            DF:Err(L["Parse a string first."])
            return
        end
        if not parsed.ok then
            DF:Err(ImportErrorText(parsed))
            return
        end
        if parsed.kind == "profile" then
            ImportProfile(parsed)
        elseif parsed.kind == "clickcast" then
            ImportClickCast(parsed)
        elseif parsed.kind == "filter" then
            if DF.ImportFilterString then
                DF.ImportFilterString(parsed.str)
            else
                DF:Err(L["Import failed. Please try again or check for errors."])
            end
        end
    end), 32)
    importActionsGroup:AddWidget(GUI:CreateIconButton(self.child, "close", L["Clear"], 240, 24, function()
        if self.importEditBox then self.importEditBox:SetText("") end
        SetStatus(DimText(L["Paste string above, then Parse"]))
        ResetProfileOptions()
        self.parsedImport = nil
        self:RefreshStates()
    end), 28)
    AddToSection(importActionsGroup, nil, 2)

    AddSyncPoint()
    AddSpace(GUI.Space.block, "both")

    -- ========================================
    -- EXPORT: what (column 1), then the string (column 2)
    -- ========================================
    local kindGroup = GUI:CreateSettingsGroup(self.child, 280)
    kindGroup:AddWidget(GUI:CreateHeader(self.child, L["What to Export"]), 40)
    local kindLabels = {
        profile   = L["Profile"],
        clickcast = L["Click-Cast Profile"],
        filter    = L["Filter"],
    }
    local kindOptions = { _order = { unpack(EXPORT_KINDS) } }
    for _, k in ipairs(EXPORT_KINDS) do kindOptions[k] = kindLabels[k] end
    kindGroup:AddWidget(GUI:CreateDropdown(self.child, L["Type"], kindOptions, nil, nil, nil,
        function() return self.exportKind end,
        function(v)
            self.exportKind = v
            if self.exportEditBox then self.exportEditBox:SetText("") end
            self:RefreshStates()
        end), 55)
    AddToSection(kindGroup, nil, 1)

    -- ---- a DandersFrames profile: the old export options, unchanged ----
    local exportSettingsGroup = GUI:CreateSettingsGroup(self.child, 280)
    exportSettingsGroup.hideOn = function() return self.exportKind ~= "profile" end

    local nameInput = GUI:CreateInput(self.child, L["Profile Name"], 240)
    -- The current profile's name. ☠ This read DF.db.keys.profile, which does not
    -- exist (an AceDB shape this addon never had), so it was always "My Profile".
    nameInput.EditBox:SetText(DF:GetCurrentProfile() or "Default")
    self.exportNameEdit = nameInput.EditBox
    exportSettingsGroup:AddWidget(nameInput, 50)

    -- frameTypes: true = All checks Party+Raid, false = None clears them,
    -- nil = Look/Layout leave the frame-type row alone.
    local presetRow = CreateFrame("Frame", nil, self.child)
    presetRow:SetSize(240, 24)
    local presets = {
        {name = "All", x = 0, frameTypes = true, cats = categoryOrder},
        {name = "Look", x = 60, cats = {"bars", "auras", "dispel", "missingBuffs", "defensives", "targetedSpells", "targetedList", "text", "textDesigner", "icons", "other"}},
        {name = "Layout", x = 120, cats = {"position", "layout"}},
        {name = "None", x = 180, frameTypes = false, cats = {}},
    }
    for _, p in ipairs(presets) do
        local btn = CreateSmallButton(presetRow, L[p.name], 56)
        btn:SetPoint("LEFT", p.x, 0)
        btn:SetScript("OnClick", function()
            local sel = {}
            for _, c in ipairs(p.cats) do sel[c] = true end
            for cat, cb in pairs(self.exportCheckboxes) do cb:SetChecked(sel[cat] or false) end
            -- All/None also drive the Party/Raid row -- keep the STATE table in
            -- sync (SetChecked does not fire the checkbox OnClick handlers).
            if p.frameTypes ~= nil and self.exportFrameTypeBoxes then
                for ft, box in pairs(self.exportFrameTypeBoxes) do
                    box:SetChecked(p.frameTypes)
                    self.exportFrameTypes[ft] = p.frameTypes
                end
                if self.UpdateExportCategoryState then self.UpdateExportCategoryState() end
            end
        end)
    end
    exportSettingsGroup:AddWidget(presetRow, 28)

    exportSettingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Export for"], 240), 22)
    local ftRow = CreateFrame("Frame", nil, self.child)
    ftRow:SetSize(240, 20)
    local partyExp = CreateSmallCheckbox(ftRow, L["Party"], true)
    partyExp:SetPoint("LEFT", 0, 0)
    partyExp.checkbox:SetScript("OnClick", function(s)
        self.exportFrameTypes.party = s:GetChecked()
        if self.UpdateExportCategoryState then self.UpdateExportCategoryState() end
    end)
    local raidExp = CreateSmallCheckbox(ftRow, L["Raid"], true)
    raidExp:SetPoint("LEFT", 80, 0)
    raidExp.checkbox:SetScript("OnClick", function(s)
        self.exportFrameTypes.raid = s:GetChecked()
        if self.UpdateExportCategoryState then self.UpdateExportCategoryState() end
    end)
    self.exportFrameTypeBoxes = {party = partyExp, raid = raidExp}
    exportSettingsGroup:AddWidget(ftRow, 24)

    exportSettingsGroup:AddWidget(GUI:CreateLabel(self.child, L["Settings to include"], 240), 22)
    for _, cat in ipairs(categoryOrder) do
        local info = DF.ExportCategoryInfo[cat]
        local catRow = CreateFrame("Frame", nil, self.child)
        catRow:SetSize(240, 18)
        local cb = CreateSmallCheckbox(catRow, L[info.name], true)
        cb:SetPoint("LEFT", 0, 0)
        self.exportCheckboxes[cat] = cb
        exportSettingsGroup:AddWidget(catRow, 20)
    end
    -- Grey the category list while no mode is selected (nothing would export).
    self.UpdateExportCategoryState = function()
        local enabled = self.exportFrameTypes.party or self.exportFrameTypes.raid
        for _, cb in pairs(self.exportCheckboxes) do
            if enabled then cb:Enable() else cb:Disable() end
        end
    end
    AddToSection(exportSettingsGroup, nil, 1)

    -- ---- the active click-cast profile ----
    local ccGroup = GUI:CreateSettingsGroup(self.child, 280)
    ccGroup.hideOn = function() return self.exportKind ~= "clickcast" end
    local ccLine = CreateStatusLine(self.child, 240)
    -- Read on show: the active click-cast profile follows the talent loadout.
    local function PaintCCLine()
        local CC = DF.ClickCast
        local ok, name = false, nil
        if CC and CC.db and CC.GetActiveProfileName then ok, name = pcall(CC.GetActiveProfileName, CC) end
        if ok and type(name) == "string" then
            ccLine.Text:SetText(format(L["Exports your active click-cast profile: %s"], name))
        else
            ccLine.Text:SetText(L["Click casting is not available."])
        end
    end
    ccLine:SetScript("OnShow", PaintCCLine)
    PaintCCLine()
    ccGroup:AddWidget(ccLine, 34)
    AddToSection(ccGroup, nil, 1)

    -- ---- a filter (preset or custom; R:ExportFilter takes either) ----
    local filterGroup = GUI:CreateSettingsGroup(self.child, 280)
    filterGroup.hideOn = function() return self.exportKind ~= "filter" end
    -- value -> { key, name }. Rebuilt on every open: filters come and go.
    local filterRefs = {}
    local function FilterOptions()
        local opts = { _order = {} }
        wipe(filterRefs)
        local R = DF.FilterRegistry
        for _, entry in ipairs((R and R.ListFilters and R:ListFilters()) or {}) do
            local value = entry.kind .. ":" .. tostring(entry.key)
            local name = entry.custom and entry.name or L[entry.name]
            filterRefs[value] = { key = entry.key, name = name }
            opts[value] = name
            tinsert(opts._order, value)
        end
        return opts
    end
    filterGroup:AddWidget(GUI:CreateDropdown(self.child, L["Filter"], FilterOptions(), nil, nil, nil,
        function() return self.exportFilter end,
        function(v) self.exportFilter = v end,
        { optionsFunc = FilterOptions }), 55)
    AddToSection(filterGroup, nil, 1)

    -- ---- the string ----
    local exportActionsGroup = GUI:CreateSettingsGroup(self.child, 280)
    exportActionsGroup:AddWidget(GUI:CreateHeader(self.child, L["Export"]), 40)

    local function ExportProfileString()
        local selectedCats = {}
        local allSelected = true
        for _, cat in ipairs(categoryOrder) do
            if self.exportCheckboxes[cat]:GetChecked() then
                tinsert(selectedCats, cat)
            else
                allSelected = false
            end
        end
        if allSelected then selectedCats = nil end
        local profileName = self.exportNameEdit:GetText()
        if profileName == "" then profileName = nil end
        return DF:ExportProfile(selectedCats, self.exportFrameTypes, profileName)
    end

    exportActionsGroup:AddWidget(GUI:CreateIconButton(self.child, "upload", L["Generate Export String"], 240, 26, function()
        local str
        if self.exportKind == "clickcast" then
            local CC = DF.ClickCast
            if not (CC and CC.ExportProfile) then
                DF:Err(L["Click casting is not available."])
                return
            end
            str = CC:ExportProfile()   -- says why in chat when it cannot
            if not str then return end
        elseif self.exportKind == "filter" then
            local R = DF.FilterRegistry
            local ref = self.exportFilter and filterRefs[self.exportFilter]
            if not (R and ref) then
                DF:Err(L["Pick a filter first."])
                return
            end
            str = R:ExportFilter(ref.key, ref.name)
            if not str then
                DF:Err(L["That filter can't be exported."])
                return
            end
        else
            str = ExportProfileString()
            if not str then
                DF:Err("Export failed - no string returned")
                return
            end
        end
        if self.exportEditBox then
            self.exportEditBox:SetText(str)
            self.exportEditBox:HighlightText()
            self.exportEditBox:SetFocus()
            DF:Say("Export generated.")
        end
    end), 32)

    local exportArea = GUI:CreateTextArea(self.child, { width = 240, height = 100 })
    self.exportEditBox = exportArea.EditBox
    exportActionsGroup:AddWidget(exportArea, 105)

    exportActionsGroup:AddWidget(GUI:CreateButton(self.child, L["Select All Text"], 240, 24, function()
        if self.exportEditBox then
            self.exportEditBox:HighlightText()
            self.exportEditBox:SetFocus()
        end
    end), 28)
    AddToSection(exportActionsGroup, nil, 2)

    -- See Also
    AddSpace(GUI.Space.block, "both")
    Add(GUI:CreateSeeAlso(self.child, {
        {pageId = "profiles_manage", label = L["Manage Profiles"]},
        {pageId = DF.ChangedSettings.PAGE_ID, label = L["Changed Settings"]},
    }), 30, "both")
end

-- ============================================================
-- CHANGED SETTINGS
-- ============================================================

-- Party / Raid / Global. Party and Raid ARE the frame mode under the Profiles
-- view (the report is built from the search index, which is per mode), so
-- picking one switches it -- GUI:SetUnderlyingFrameMode, the whole Party/Raid
-- switch. Global is a scope of this page alone.
local function CreateScopePicker(page)
    local CS = DF.ChangedSettings
    local options = {
        party = L["Party"], raid = L["Raid"], global = L["Global"],
        _order = { "party", "raid", "global" },
    }
    return GUI:CreateDropdown(page.child, L["Show"], options, nil, nil, nil,
        function()
            if CS.scope == "global" then return "global" end
            return GUI.SelectedMode
        end,
        function(v)
            -- ⚠ NEXT FRAME, ALL OF IT. This runs inside the dropdown's own pick,
            -- and both a mode switch (which refreshes the page on screen) and the
            -- rebuild a new scope causes retire this very dropdown.
            C_Timer.After(0, function()
                if v == "global" then
                    CS.scope = "global"
                else
                    CS.scope = nil
                    if v ~= GUI.SelectedMode and GUI.SetUnderlyingFrameMode then
                        GUI:SetUnderlyingFrameMode(v)
                    end
                end
                if GUI.CurrentPageName == CS.PAGE_ID and page:IsShown() and page.RefreshCached then
                    page:RefreshCached()
                end
            end)
        end)
end

-- Profiles > Changed Settings
--
-- A GENERATED page: every setting in the current mode whose stored value
-- differs from the shipped default, grouped by the page that owns it, one
-- click from the setting itself. The diff walk, the grouping and the value
-- formatting all live in Features/ChangedSettings.lua so they can be
-- asserted headlessly; everything here is the drawing. ONE page, with a
-- Party / Raid / Global picker at the top (CreateScopePicker).
local function BuildChangedSettings(self, Add, AddSpace)
    local CS = DF.ChangedSettings
    -- The picker's choice (Party / Raid / Global); nil is the frame mode
    -- under the Profiles view, which picking Party or Raid switches.
    local scope = CS.scope
    -- ⚠ FIRST, BEFORE ANY WIDGET IS ADDED. BuildReport may build the search
    -- registry, which re-runs every other page's builder and ends by calling
    -- RefreshStates on whatever page is on screen -- this one. With nothing
    -- added yet that pass runs over an empty children list and is a no-op;
    -- move this below the first Add() and it re-lays a half-built page.
    local report, reason = CS:BuildReport(GUI, scope)
    local isGlobal = (scope == "global")
    local modeLabel = isGlobal and L["Global"]
        or (GUI.SelectedMode == "raid") and L["Raid"] or L["Party"]

    -- Dim hex for the "-> default" half of a value cell. Built from the
    -- palette rather than typed, so the ledger follows a theme change like
    -- everything else; floor because %02x on a fractional number is an error
    -- in some Lua builds.
    local cd = GUI.Colors.textDim
    local dimHex = format("%02x%02x%02x",
        math.floor(cd.r * 255), math.floor(cd.g * 255), math.floor(cd.b * 255))

    -- ☠ AN ICON, NOT AN ARROW CHARACTER. This was "\226\134\146" (U+2192 →)
    -- and it rendered as an EMPTY BOX in game -- "2 ⃞ 1" in the report -- for
    -- the same reason the Cyrillic and CJK squares happened: the settings
    -- panel draws in the user's Settings Font, and the shipped default ("DF
    -- Roboto SemiBold") carries Latin and punctuation and nothing else. Our
    -- own art cannot be missing from the font, because it is not in a font.
    -- Tinted to the dim colour by GUI:InlineIcon: a |cff escape does not
    -- reach a texture, and a white arrow beside grey text reads as a
    -- highlight rather than as punctuation.
    --
    -- ⚠ THE COPY-AS-TEXT BLOCK KEEPS ITS ASCII ">". It is pasted into a
    -- support thread, where an inline texture escape is seven words of
    -- gibberish -- ChangedSettings.BuildText already builds that half from
    -- FormatValue's `ascii` path and is untouched by this.
    local arrow = GUI:InlineIcon("chevron_right", 10, cd)

    -- ===== THE KNOWN GAP, STATED =====
    -- Not hidden, and shown on the EMPTY page too -- that is the reading it
    -- most has to survive, because "Everything is at its defaults" with no
    -- caveat under it is the one screen a user could take as a guarantee.
    -- The registry only carries keys the shared factories BOUND; a control
    -- wired through a closure get/set (Border Alpha) and an ordered list
    -- have no key for it to carry.
    local function AddFootnote()
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateLabel(self.child,
            L["Not everything is listed: a few controls and ordered lists are not tracked here."]),
            nil, "both")
    end

    -- ===== HEADER BOX =====
    local headerGroup = GUI:CreateSettingsGroup(self.child, 280)
    headerGroup:AddWidget(GUI:CreateHeader(self.child, L["Changed Settings"]), 40)
    headerGroup:AddWidget(CreateScopePicker(self), 55)

    if not report then
        -- ⚠ SAY WHICH. "Nothing changed" and "could not be measured" look
        -- identical on screen and mean opposite things, so the page never
        -- falls back to the empty state here -- it names the reason.
        headerGroup:AddWidget(GUI:CreateLabel(self.child,
            (reason == "combat") and L["This list can't be built during combat."]
            or L["Building the list of settings..."]), nil)
        -- No footnote here: "not everything is listed" under a page that
        -- listed nothing at all is noise. It belongs on the EMPTY state,
        -- where it is the caveat on a real claim.
        Add(headerGroup, nil, "both")
        return
    end

    headerGroup:AddWidget(GUI:CreateLabel(self.child, isGlobal
        and L["Showing the settings on the Global tab: account-wide ones, and those shared by Party and Raid. Click a row to jump to the setting."]
        or format(L["Showing %s settings in the current profile. Click a row to jump to the setting."],
            modeLabel)), nil)

    if report.count == 0 then
        headerGroup:AddWidget(GUI:CreateLabel(self.child, L["Everything is at its defaults."]), nil)
        Add(headerGroup, nil, "both")
        AddFootnote()
        return
    end

    headerGroup:AddWidget(GUI:CreateLabel(self.child,
        format(L["%d settings differ from defaults"], report.count)), nil)

    headerGroup:AddWidget(GUI:CreateIconButton(self.child, "content_copy", L["Copy as Text"], 240, 26, function()
        -- The same read-only multi-line popup the profile export and the
        -- debug-log export use -- a singleton, so no frame is leaked per
        -- click. Rebuilt on the click rather than captured at page build:
        -- the user may have changed something since.
        local fresh = CS:BuildReport(GUI, scope)
        DF:ShowPopupInput({
            title       = L["Changed Settings"],
            message     = L["Press Ctrl+A to select all, then Ctrl+C to copy"],
            text        = CS.BuildText(fresh, { modeLabel = modeLabel, version = DF.VERSION }),
            multiline   = true,
            readOnly    = true,
            cancelLabel = L["Close"],
        })
    end), 32)

    Add(headerGroup, nil, "both")

    -- ===== ONE BOX PER SOURCE PAGE =====
    for _, group in ipairs(report.groups) do
        local box = GUI:CreateSettingsGroup(self.child, 280)
        box:AddWidget(GUI:CreateHeader(self.child, group.label), 40)

        for _, row in ipairs(group.rows) do
            -- A plain kit button with NO opts.text: StyleButton grows a
            -- labelled button to fit its string (FitToLabel), which on a
            -- full-width report row would push the box wider than the page.
            -- The two strings are ours, anchored to the row's own edges, so
            -- the row takes whatever width the group hands it.
            local rowBtn = CreateFrame("Button", nil, self.child, "BackdropTemplate")
            rowBtn:SetSize(260, 22)
            GUI:StyleButton(rowBtn, { height = 22, align = "left" })

            local value = rowBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            value:SetPoint("RIGHT", rowBtn, "RIGHT", -8, 0)
            -- ☠ AND A LEFT BOUND, which is what actually clips. A FontString
            -- anchored on ONE edge with word wrap off is unbounded on the
            -- other: it grows to fit its string, which for a stored texture
            -- path (the reported case) meant a cell running off the left of
            -- the row and out of the page. The right edge was never the
            -- problem -- it was pinned all along.
            --
            -- Anchored to the row's CENTRE rather than to a pixel column, so
            -- the split tracks whatever width the group hands the row: half
            -- for the setting's name, half for its value. Nothing moves for a
            -- row whose two strings already fit, because both are justified
            -- to their OUTER edges; a value that does not fit truncates
            -- instead of escaping.
            --
            -- ⚠ No cycle with `name` below, which anchors its right edge to
            -- this string's left: that edge is now fixed to rowBtn, so both
            -- resolve from the row and neither waits on the other.
            value:SetPoint("LEFT", rowBtn, "CENTER", 0, 0)
            value:SetJustifyH("RIGHT")
            value:SetWordWrap(false)
            value:SetText(format("%s %s|cff%s%s|r",
                CS.FormatValue(row.current), arrow, dimHex, CS.FormatValue(row.default)))
            -- The CURRENT half at full text weight, the "-> default" half
            -- dimmed by the escape above. The current value is what the user
            -- came to read; the default is context.
            value:SetTextColor(GUI.Colors.text.r, GUI.Colors.text.g, GUI.Colors.text.b)

            local name = rowBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            name:SetPoint("LEFT", rowBtn, "LEFT", 8, 0)
            name:SetPoint("RIGHT", value, "LEFT", -10, 0)
            name:SetJustifyH("LEFT")
            name:SetWordWrap(false)
            name:SetText(row.label)
            local ct = GUI.Colors.text
            name:SetTextColor(ct.r, ct.g, ct.b)

            -- The section is not on the row (it would double the width for a
            -- line that is already two columns), so it goes in the tooltip,
            -- where it answers "which of the three Offset X sliders is this".
            local where = group.label
            if row.section and row.section ~= "" then
                where = where .. "  >  " .. row.section
            end
            rowBtn:HookScript("OnEnter", function(s)
                GUI:ShowTooltip(s, { title = L["Show me"], lines = { where } })
            end)
            rowBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)

            -- ☠ THE SEARCH JUMP, not a hand-rolled one. NavigateToTab is the
            -- exact machinery a search result's breadcrumb uses: it selects
            -- the tab, scrolls to the section, flashes it, AND opens the
            -- popout row that owns the key when the control lives inside one
            -- (Border Alpha's box, the aura popouts). A local Tabs:Click()
            -- would land on the page with the control still behind a closed
            -- row.
            local tab, section, key = group.tab, row.section, row.key
            rowBtn:SetScript("OnClick", function()
                DF.Search:NavigateToTab(tab, section, key)
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            end)

            box:AddWidget(rowBtn, 24)
        end

        Add(box, nil, "both")
    end

    AddFootnote()
end

-- ============================================================
-- SETUP -- called from the page chain (GUI/Pages/Modules.lua)
-- ============================================================
function DF:SetupProfilesPages(_, CreateCategory, CreateSubTab, BuildPage)
    CreateCategory("profiles", L["Profiles"])

    local pageManage = CreateSubTab("profiles", "profiles_manage", L["Manage"])
    BuildPage(pageManage, BuildManage)

    local pageSpec = CreateSubTab("profiles", "profiles_spec", L["Spec & Character"])
    BuildPage(pageSpec, BuildSpec)

    -- Raid's, whatever mode sits under the view (AutoProfilesUI:BuildPage).
    local pageAutoProfiles = CreateSubTab("profiles", "profiles_auto", L["Auto Layouts"])
    BuildPage(pageAutoProfiles, function(self, db, Add, AddSpace)
        if DF.AutoProfilesUI and DF.AutoProfilesUI.BuildPage then
            DF.AutoProfilesUI:BuildPage(GUI, self, db, Add, AddSpace)
        else
            Add(GUI:CreateHeader(self.child, L["Auto Layouts"]), 40, "both")
            Add(GUI:CreateLabel(self.child, L["Auto Layouts module not loaded."], 400), 30, "both")
        end
    end)

    local pageClickCast = CreateSubTab("profiles", "profiles_clickcast", L["Click-Casting"])
    BuildPage(pageClickCast, BuildClickCast)

    local pageImportExport = CreateSubTab("profiles", "profiles_importexport", L["Import/Export"])
    BuildPage(pageImportExport, BuildImportExport)

    -- ☠ NOT INDEXED BY SEARCH, and this flag is the mechanism (read in
    -- Search:BuildFullRegistry). Building the registry re-runs every page's
    -- builder and this builder ASKS for the registry, so without the skip the
    -- two call each other forever; and even one level deep is wrong, because a
    -- nested Refresh on this page retires the widgets the outer Refresh already
    -- placed. See the header of Features/ChangedSettings.lua.
    local pageChangedSettings = CreateSubTab("profiles", DF.ChangedSettings.PAGE_ID, L["Changed Settings"])
    if pageChangedSettings then pageChangedSettings.skipSearchIndex = true end
    BuildPage(pageChangedSettings, function(self, db, Add, AddSpace)
        BuildChangedSettings(self, Add, AddSpace)
    end)
end
