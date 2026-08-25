-- ============================================================
-- AUTO PROFILES - the settings page
-- ============================================================
-- Split from the engine, which is resident at DandersFrames/Core/AutoProfiles
-- because profile switching has to work whether or not this page has ever
-- been opened. Everything here is presentation: the page, the two dialogs and
-- the editing banner.
--
-- These re-declarations are aliases of objects the engine created; they add no
-- state. The engine also defines no-op versions of the four methods below that
-- it calls itself -- RefreshEditingUI, RefreshTabOverrideStars, ShowSidebarHint
-- and HideSidebarHint -- and this file overwrites them with the real ones.
local DF = DandersFrames
local L = DF.L
local format = string.format
local AutoProfilesUI = DF.AutoProfilesUI
local P = AutoProfilesUI._priv
local CONTENT_TYPES = P.CONTENT_TYPES
local CountDisplayedOverrides = P.CountDisplayedOverrides
local DeepCopyValue = P.DeepCopyValue
local GetOverrideTabId = P.GetOverrideTabId
local GroupOverridesByTab = P.GroupOverridesByTab
local KeyLabel = P.KeyLabel
local WalkOverrideDiff = P.WalkOverrideDiff

-- ============================================================
-- UI BUILDING
-- ============================================================

-- Build the Auto Profiles page content
function AutoProfilesUI:BuildPage(GUI, pageFrame, db, Add, AddSpace)
    local self = AutoProfilesUI
    self:InitDefaults()
    
    local autoDb = DF.db.raidAutoProfiles
    
    -- Only show for Raid mode
    if GUI.SelectedMode ~= "raid" then
        -- The disabled overlay survives page rebuilds (see the bottom of this
        -- function), so a raid -> party switch has to put it away explicitly or
        -- it hangs over the Raid-only message anchored to a discarded section.
        if pageFrame.autoDisabledOverlay then pageFrame.autoDisabledOverlay:Hide() end
        Add(GUI:CreateHeader(pageFrame.child, L["Raid Auto Layouts"]), 40, "both")
        Add(GUI:CreateLabel(pageFrame.child,
            L["Auto Layouts is a Raid-only feature. Switch to Raid mode to configure automatic layout switching based on content type and group size."],
            500, {r = 0.6, g = 0.6, b = 0.6}), 60, "both")
        return
    end

    -- =============================================
    -- Enable Checkbox
    -- =============================================
    local enableCheck = GUI:CreateCheckbox(pageFrame.child, L["Enable Raid Auto-Switching Layouts"],
        nil, nil,  -- dbTable, dbKey (not used)
        function() pageFrame:Refresh() end,  -- callback
        function() return autoDb.enabled end,  -- customGet
        function(val)                           -- customSet
            autoDb.enabled = val
            if not val then
                AutoProfilesUI:RemoveRuntimeProfile()
            else
                AutoProfilesUI:EvaluateAndApply()
            end
        end
    )
    Add(enableCheck, 30, "both")

    AddSpace(5, "both")

    -- When "Enable Raid Auto-Switching Layouts" is OFF the page stays VISIBLE,
    -- but the layout MANAGEMENT sections are covered by the shared disabled
    -- overlay (built at the bottom of this function) — the same treatment the
    -- Aura and Text Designers get. The toggle's callback runs pageFrame:Refresh()
    -- (a full rebuild), so reading autoDb.enabled at build time is
    -- self-refreshing — no disableOn/RefreshStates wiring needed for these raw
    -- frames (they have no SetEnabled, so the page gate loop skips them anyway).
    --
    -- ⚠ This REVERSES an earlier "configure-while-off" decision, which left add /
    -- edit / delete / rename / copy fully live on the theory that people build
    -- layouts before switching auto-switching on. In practice that read as though
    -- the feature were already running: you could build a whole set of layouts
    -- that would never fire, with nothing on the page saying so. Krathe called it
    -- 2026-07-27. Turning it back on is the one line at the bottom.
    local autoOff = not autoDb.enabled

    -- =============================================
    -- Current Status Box
    -- =============================================
    local statusContainer = CreateFrame("Frame", nil, pageFrame.child)
    statusContainer:SetSize(500, 55)
    DF.GUI:CreateElementBackdrop(statusContainer, {
        bgColor = { 0.1, 0.1, 0.1, 0.8 },
        borderColor = { 0.25, 0.25, 0.25, 1 },
    })
    
    local statusTitle = statusContainer:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    statusTitle:SetPoint("TOPLEFT", 10, -8)
    statusTitle:SetText(L["CURRENT STATUS"])
    statusTitle:SetTextColor(0.5, 0.5, 0.5)
    
    local statusLine1 = statusContainer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    statusLine1:SetPoint("TOPLEFT", 10, -24)
    
    local statusLine2 = statusContainer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    statusLine2:SetPoint("TOPLEFT", 10, -38)
    
    -- Update status display
    if not autoDb.enabled then
        statusLine1:SetText("|cff666666" .. L["Auto-switching disabled"] .. "|r")
        statusLine2:SetText("")
    elseif not IsInRaid() then
        statusLine1:SetText("|cff999999" .. L["Not in a raid group"] .. "|r")
        statusLine2:SetText("")
    else
        -- Live detection
        local contentType = DF:GetContentType()
        local raidSize = GetNumGroupMembers()

        -- Map content type to display name
        local contentNames = {
            mythic = L["Mythic"],
            instanced = L["Instanced / PvP"],
            battleground = L["Instanced / PvP"],
            openWorld = L["Open World"],
            arena = L["Arena"],
        }
        local contentDisplay = contentNames[contentType] or L["Unknown"]

        -- Get instance name if available
        local instanceName = select(1, GetInstanceInfo())
        local difficultyName = select(4, GetInstanceInfo())
        local contentDetail = ""
        if instanceName and instanceName ~= "" and contentType ~= "openWorld" then
            contentDetail = " |cff666666— " .. instanceName
            if difficultyName and difficultyName ~= "" then
                contentDetail = contentDetail .. " (" .. difficultyName .. ")"
            end
            contentDetail = contentDetail .. "|r"
        end

        statusLine1:SetText("|cff66ff66" .. L["Content:"] .. "|r |cffffffff" .. contentDisplay .. "|r" .. contentDetail .. "  |cff666666(" .. format(L["%d players"], raidSize) .. ")|r")

        -- Show active profile
        local profile, profileKey = self:GetActiveProfile()
        if profile then
            local rangeText = ""
            if profileKey == "mythic" then
                rangeText = L["20 (Fixed)"]
            elseif profile.min and profile.max then
                rangeText = profile.min .. "-" .. profile.max
            end
            local overrideCount = CountDisplayedOverrides(profile.overrides)
            statusLine2:SetText("|cff66ff66" .. L["Layout:"] .. "|r |cffffffff\"" .. (profile.name or L["Unnamed"]) .. "\"|r |cff666666— " .. rangeText .. " · " .. format(overrideCount ~= 1 and L["%d overrides"] or L["%d override"], overrideCount) .. "|r")
        else
            statusLine2:SetText("|cff66ff66" .. L["Layout:"] .. "|r |cff999999" .. L["None active (using global settings)"] .. "|r")
        end
    end
    
    -- Grey the runtime status indicator in place when auto-switching is off; it
    -- reports the auto-switch behaviour (which is inert when disabled). Stays
    -- visible, just dimmed.
    statusContainer:SetAlpha(autoOff and 0.4 or 1)

    Add(statusContainer, 60, "both")

    AddSpace(5, "both")
    
    -- =============================================
    -- How It Works Section (collapsible, persisted)
    -- =============================================
    local infoHeaderHeight = 28
    local infoBodyHeight = 206
    local infoCollapsed = autoDb.howItWorksCollapsed
    
    local infoContainer = CreateFrame("Frame", nil, pageFrame.child, "BackdropTemplate")
    infoContainer:SetSize(500, infoHeaderHeight + (infoCollapsed and 0 or infoBodyHeight))
    DF.GUI:CreateElementBackdrop(infoContainer, {
        bgColor     = { 0.15, 0.1, 0.05, 0.5 },
        borderColor = { 0.4, 0.25, 0.1, 0.5 },
    })
    
    -- Clickable header
    local infoHeader = CreateFrame("Button", nil, infoContainer)
    infoHeader:SetPoint("TOPLEFT", 0, 0)
    infoHeader:SetPoint("TOPRIGHT", 0, 0)
    infoHeader:SetHeight(infoHeaderHeight)
    
    local infoArrow = infoHeader:CreateTexture(nil, "OVERLAY")
    infoArrow:SetPoint("LEFT", 10, 0)
    infoArrow:SetSize(12, 12)
    infoArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. (infoCollapsed and "chevron_right" or "expand_more"))
    infoArrow:SetVertexColor(0.6, 0.6, 0.6)
    
    local howTitle = infoHeader:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    howTitle:SetPoint("LEFT", 28, 0)
    howTitle:SetText(L["How it works"])
    howTitle:SetTextColor(1, 1, 1)
    
    infoHeader:SetScript("OnEnter", function() infoArrow:SetVertexColor(1, 0.8, 0.2) end)
    infoHeader:SetScript("OnLeave", function() infoArrow:SetVertexColor(0.6, 0.6, 0.6) end)
    
    -- Body
    local infoBody = CreateFrame("Frame", nil, infoContainer)
    infoBody:SetPoint("TOPLEFT", 0, -infoHeaderHeight)
    infoBody:SetPoint("TOPRIGHT", 0, -infoHeaderHeight)
    infoBody:SetHeight(infoBodyHeight)
    if infoCollapsed then infoBody:Hide() end
    
    -- Toggle
    infoHeader:SetScript("OnClick", function()
        autoDb.howItWorksCollapsed = not autoDb.howItWorksCollapsed
        if autoDb.howItWorksCollapsed then
            infoArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
            infoBody:Hide()
        else
            infoArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            infoBody:Show()
        end
        -- Refresh page to recalculate layout
        if pageFrame.Refresh then pageFrame:Refresh() end
    end)
    
    local yOff = -4
    
    -- Step 1
    local step1 = infoBody:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    step1:SetPoint("TOPLEFT", 10, yOff)
    step1:SetPoint("RIGHT", infoBody, "RIGHT", -10, 0)
    step1:SetJustifyH("LEFT")
    step1:SetText("|cffff8020" .. "1.|r " .. format(L["Create layouts below for different player ranges within each content type. Layouts only store settings that %sdiffer%s from your global settings — everything else is inherited automatically."], "|cffffffff", "|r"))
    step1:SetTextColor(0.65, 0.65, 0.65)
    yOff = yOff - 30
    
    -- Step 2
    local step2 = infoBody:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    step2:SetPoint("TOPLEFT", 10, yOff)
    step2:SetPoint("RIGHT", infoBody, "RIGHT", -10, 0)
    step2:SetJustifyH("LEFT")
    step2:SetText("|cffff8020" .. "2.|r " .. format(L["Click %sEdit Settings%s on a profile to customise it. This takes you to the settings tabs with an editing banner at the top. While editing, any setting you change is stored as an override for that profile only."], "|cffffffff", "|r"))
    step2:SetTextColor(0.65, 0.65, 0.65)
    yOff = yOff - 30
    
    -- Step 3 - visual indicators
    local step3 = infoBody:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    step3:SetPoint("TOPLEFT", 10, yOff)
    step3:SetPoint("RIGHT", infoBody, "RIGHT", -10, 0)
    step3:SetJustifyH("LEFT")
    step3:SetText("|cffff8020" .. "3.|r " .. L["While editing, each setting shows its override status:"])
    step3:SetTextColor(0.65, 0.65, 0.65)
    yOff = yOff - 16
    
    -- Visual example row 1: Matching global (green check)
    local exRow1 = CreateFrame("Frame", nil, infoBody)
    exRow1:SetPoint("TOPLEFT", 24, yOff)
    exRow1:SetSize(460, 16)
    
    local ex1Check = exRow1:CreateTexture(nil, "OVERLAY")
    ex1Check:SetPoint("LEFT", 0, 0)
    ex1Check:SetSize(10, 10)
    ex1Check:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
    ex1Check:SetVertexColor(0.3, 0.7, 0.3)
    
    local ex1Text = exRow1:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    ex1Text:SetPoint("LEFT", ex1Check, "RIGHT", 4, 0)
    ex1Text:SetText(format(L["%sGlobal: 80%s %s— Setting matches global, no override stored%s"], "|cff4db84d", "|r", "|cff666666", "|r"))
    yOff = yOff - 18
    
    -- Visual example row 2: Overridden (dot + reset)
    local exRow2 = CreateFrame("Frame", nil, infoBody)
    exRow2:SetPoint("TOPLEFT", 24, yOff)
    exRow2:SetSize(460, 16)
    
    local ex2Star = exRow2:CreateTexture(nil, "OVERLAY")
    ex2Star:SetPoint("LEFT", 0, 0)
    ex2Star:SetSize(12, 12)
    ex2Star:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\dot")
    ex2Star:SetVertexColor(1, 0.8, 0.2)
    
    local ex2ResetBg = exRow2:CreateTexture(nil, "ARTWORK")
    ex2ResetBg:SetPoint("LEFT", ex2Star, "RIGHT", 4, 0)
    ex2ResetBg:SetSize(14, 14)
    ex2ResetBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    
    local ex2Reset = exRow2:CreateTexture(nil, "OVERLAY")
    ex2Reset:SetPoint("CENTER", ex2ResetBg, "CENTER", 0, 0)
    ex2Reset:SetSize(10, 10)
    ex2Reset:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh")
    ex2Reset:SetVertexColor(0.9, 0.45, 0.45)  -- danger red, matches the live reset button
    
    local ex2Text = exRow2:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    ex2Text:SetPoint("LEFT", ex2ResetBg, "RIGHT", 6, 0)
    ex2Text:SetText(format(L["%sModified%s %s— Setting differs from global. Click%s %sreset%s %sto revert.%s"], "|cffe6cc80", "|r", "|cff666666", "|r", "|cffffffff", "|r", "|cff666666", "|r"))
    yOff = yOff - 22
    
    -- Step 4
    local step4 = infoBody:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    step4:SetPoint("TOPLEFT", 10, yOff)
    step4:SetPoint("RIGHT", infoBody, "RIGHT", -10, 0)
    step4:SetJustifyH("LEFT")
    step4:SetText("|cffff8020" .. "4.|r " .. format(L["Click %sExit Editing%s when done. Your overrides are saved to the profile. If you change a setting back to match global, the override is automatically removed."], "|cffffffff", "|r"))
    step4:SetTextColor(0.65, 0.65, 0.65)
    yOff = yOff - 30
    
    -- Step 5
    local step5 = infoBody:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    step5:SetPoint("TOPLEFT", 10, yOff)
    step5:SetPoint("RIGHT", infoBody, "RIGHT", -10, 0)
    step5:SetJustifyH("LEFT")
    step5:SetText("|cffff8020" .. "5.|r " .. L["When you enter matching content, the layout's overrides are applied on top of your global settings. If no layout matches, global settings are used as-is."])
    step5:SetTextColor(0.65, 0.65, 0.65)
    
    Add(infoContainer, infoHeaderHeight + (infoCollapsed and 0 or infoBodyHeight), "both")
    
    AddSpace(GUI.Space.section, "both")
    
    -- =============================================
    -- Content Type Sections (dynamic height via layoutHeight)
    -- =============================================
    local firstSection
    for _, ct in ipairs(CONTENT_TYPES) do
        local section = self:CreateContentTypeSection(GUI, pageFrame, ct)
        firstSection = firstSection or section
        -- Add section with its current height
        Add(section, section.totalHeight, "both")
        AddSpace(8, "both")
    end

    -- =============================================
    -- Disabled overlay (see the note by `autoOff` above)
    -- =============================================
    -- Covers the layout sections ONLY. Everything above it — the enable
    -- checkbox, the Current Status box, the "How it works" documentation — stays
    -- readable, because the person looking at this scrim is exactly the one who
    -- still needs to read it. That is the one deliberate difference from the
    -- Designers, which have no explaining content to preserve.
    --
    -- Kept on pageFrame and re-anchored rather than rebuilt: it is NOT in
    -- self.children (the flow must not reserve height for it), so a page rebuild
    -- would otherwise leave the old one behind and stack a new one on top.
    -- firstSection is a fresh frame every build, hence the re-anchor.
    if firstSection then
        if not pageFrame.autoDisabledOverlay then
            pageFrame.autoDisabledOverlay = GUI:CreateDisabledOverlay(pageFrame.child, {
                label = L["Auto Layouts is disabled"],
            })
            -- Re-anchored to the TOP rather than the helper's centre: this scrim
            -- can span three expanded sections, and a centred message on a tall
            -- one lands below the fold — the user would see a dead grey slab and
            -- have to scroll to find out why. The Designers don't need this;
            -- their overlay is a fixed viewport-sized panel.
            pageFrame.autoDisabledOverlay.Label:ClearAllPoints()
            pageFrame.autoDisabledOverlay.Label:SetPoint("TOP", 0, -40)
        end
        local overlay = pageFrame.autoDisabledOverlay
        overlay:ClearAllPoints()
        overlay:SetPoint("TOPLEFT", firstSection, "TOPLEFT", 0, 0)
        overlay:SetPoint("BOTTOMRIGHT", pageFrame.child, "BOTTOMRIGHT", 0, 0)
        overlay:SetShown(autoOff)
    elseif pageFrame.autoDisabledOverlay then
        pageFrame.autoDisabledOverlay:Hide()
    end
end

-- Create a content type section (collapsible)
function AutoProfilesUI:CreateContentTypeSection(GUI, pageFrame, contentType)
    local self = AutoProfilesUI
    local autoDb = DF.db.raidAutoProfiles
    
    local profiles = self:GetProfiles(contentType.key)
    local numProfiles = #profiles
    
    -- Calculate heights
    local headerHeight = 32
    local rowHeight = 32
    local addButtonHeight = 32  -- Always include add button height
    local bodyPadding = 10
    local bodyHeight = (numProfiles * rowHeight) + addButtonHeight + bodyPadding
    
    -- If no layouts and is mythic, need extra space for "no layout set" text
    if contentType.key == "mythic" and numProfiles == 0 then
        bodyHeight = 60  -- Empty text + add button + padding
    elseif contentType.isFixed and numProfiles > 0 then
        -- Mythic with profile - no add button needed
        bodyHeight = (numProfiles * rowHeight) + bodyPadding
    end
    
    local section = CreateFrame("Frame", nil, pageFrame.child, "BackdropTemplate")
    section:SetSize(500, headerHeight)
    DF.GUI:CreateElementBackdrop(section, {
        bgColor     = { 0.12, 0.12, 0.12, 1 },
        borderColor = { 0.25, 0.25, 0.25, 1 },
    })
    section.expanded = true
    section.contentKey = contentType.key
    section.totalHeight = headerHeight + (section.expanded and bodyHeight or 0)
    
    -- Header button
    local header = CreateFrame("Button", nil, section)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(headerHeight)
    
    -- Arrow
    section.arrow = header:CreateTexture(nil, "OVERLAY")
    section.arrow:SetPoint("LEFT", 10, 0)
    section.arrow:SetSize(12, 12)
    section.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    section.arrow:SetVertexColor(0.6, 0.6, 0.6)
    
    -- Title
    local titleText = header:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    titleText:SetPoint("LEFT", 28, 0)
    titleText:SetText(contentType.title)
    titleText:SetTextColor(1, 0.5, 0.2)  -- Raid orange
    
    -- Description
    local descText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    descText:SetPoint("RIGHT", -10, 0)
    descText:SetText(contentType.description)
    descText:SetTextColor(0.5, 0.5, 0.5)
    
    -- Body container
    section.body = CreateFrame("Frame", nil, section)
    section.body:SetPoint("TOPLEFT", 0, -headerHeight)
    section.body:SetPoint("TOPRIGHT", 0, -headerHeight)
    section.body:SetHeight(bodyHeight)
    
    -- Toggle
    header:SetScript("OnClick", function()
        section.expanded = not section.expanded
        if section.expanded then
            section.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            section.body:Show()
            section.totalHeight = headerHeight + bodyHeight
        else
            section.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
            section.body:Hide()
            section.totalHeight = headerHeight
        end
        -- Update layoutHeight for the page layout system
        section.layoutHeight = section.totalHeight
        section:SetHeight(section.totalHeight)
        -- Call the page's RefreshStates to reposition all elements
        if pageFrame.RefreshStates then pageFrame:RefreshStates() end
    end)
    
    -- Hover effect
    header:SetScript("OnEnter", function()
        section:SetBackdropColor(0.16, 0.16, 0.16, 1)
    end)
    header:SetScript("OnLeave", function()
        section:SetBackdropColor(0.12, 0.12, 0.12, 1)
    end)
    
    -- Render profile rows
    local y = -5
    for i, profile in ipairs(profiles) do
        local row = self:CreateProfileRow(GUI, pageFrame, section.body, contentType, profile, i)
        row:SetPoint("TOPLEFT", 10, y)
        row:SetPoint("TOPRIGHT", -10, y)
        y = y - rowHeight
    end
    
    -- Empty state for mythic
    if contentType.key == "mythic" and numProfiles == 0 then
        local emptyText = section.body:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        emptyText:SetPoint("TOP", 0, -10)
        emptyText:SetText("|cff666666" .. L["No layout set. Using global settings."] .. "|r")
        
        -- Add button for mythic (centered, full width)
        local addBtn = self:CreateAddButton(GUI, pageFrame, section.body, contentType)
        addBtn:SetPoint("TOPLEFT", 10, -32)
        addBtn:SetPoint("TOPRIGHT", -10, -32)
    elseif not contentType.isFixed then
        -- Add Layout button (full width)
        local addBtn = self:CreateAddButton(GUI, pageFrame, section.body, contentType)
        addBtn:SetPoint("TOPLEFT", 10, y - 5)
        addBtn:SetPoint("TOPRIGHT", -10, y - 5)
    end
    
    section:SetHeight(section.totalHeight)
    return section
end

-- Create a profile row
function AutoProfilesUI:CreateProfileRow(GUI, pageFrame, parent, contentType, profile, index)
    local self = AutoProfilesUI
    
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(28)
    DF.GUI:CreateElementBackdrop(row, {
        outline = false,
        bgColor     = { 0.08, 0.08, 0.08, 1 },
    })
    
    -- Profile name — CLICKABLE, opening the same dialog the range badge does (which now
    -- carries the name field as well). The affordance mirrors the range badge beside it
    -- rather than adding a fifth button to an already crowded row.
    -- ⚠ Fixed layouts (mythic) have no dialog: the badge below only wires its click for
    -- non-fixed types, so the name follows the same rule or it would open nothing.
    local nameText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    nameText:SetPoint("LEFT", 10, 0)
    nameText:SetText(profile.name or L["Unnamed"])
    nameText:SetWidth(100)
    nameText:SetJustifyH("LEFT")

    -- ⚠ ONE tooltip for the name AND the range badge, because they open the SAME
    -- dialog. They used to describe themselves separately ("Click to edit range"),
    -- which promised less than the click delivers now that the dialog carries both
    -- fields -- and two descriptions of one destination drift apart. House shape:
    -- title plus a describing line, not a bare title.
    local function ShowRowEditTip(owner)
        GUI:ShowTooltip(owner, {
            title = L["Click to edit"],
            lines = { L["Change this layout's name, or the player range that activates it."] },
        })
    end

    if not contentType.isFixed then
        local nameBtn = CreateFrame("Button", nil, row)
        nameBtn:SetPoint("LEFT", nameText, "LEFT", -2, 0)
        nameBtn:SetSize(104, 22)
        nameBtn:SetScript("OnEnter", function(self)
            nameText:SetTextColor(1, 0.8, 0.2)
            ShowRowEditTip(self)
        end)
        nameBtn:SetScript("OnLeave", function()
            nameText:SetTextColor(1, 1, 1)
            GUI:HideTooltip()
        end)
        nameBtn:SetScript("OnClick", function()
            AutoProfilesUI:ShowProfileDialog(contentType, profile, index, pageFrame)
        end)
    end
    
    -- Range badge
    local rangeBadge = CreateFrame("Button", nil, row, "BackdropTemplate")
    rangeBadge:SetSize(65, 18)
    rangeBadge:SetPoint("LEFT", 115, 0)
    DF.GUI:CreateElementBackdrop(rangeBadge, {
        bgColor     = { 0.18, 0.18, 0.18, 1 },
        borderColor = { 0.3, 0.3, 0.3, 1 },
    })
    
    local rangeText = rangeBadge:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    rangeText:SetPoint("CENTER")
    
    if contentType.isFixed then
        rangeText:SetText(L["20 (Fixed)"])
        rangeText:SetTextColor(0.5, 0.5, 0.5)
    else
        rangeText:SetText((profile.min or 1) .. " - " .. (profile.max or 40))
        rangeText:SetTextColor(0.7, 0.7, 0.7)
        
        -- Make clickable for editing range
        rangeBadge:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(1, 0.5, 0.2, 1)
            rangeText:SetTextColor(1, 1, 1)
            ShowRowEditTip(self)
        end)
        rangeBadge:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            rangeText:SetTextColor(0.7, 0.7, 0.7)
            GUI:HideTooltip()
        end)
        rangeBadge:SetScript("OnClick", function()
            -- Show edit range dialog
            AutoProfilesUI:ShowProfileDialog(contentType, profile, index, pageFrame)
        end)
    end
    
    -- Override count: everything displayed (mapped groups + "Other"), deduped — same
    -- helper the editing status line and /df debug overrides use, so all three agree.
    local overrideCount = CountDisplayedOverrides(profile.overrides)
    
    local overrideText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    overrideText:SetPoint("LEFT", 190, 0)
    if overrideCount > 0 then
        overrideText:SetText("|cffffaa00*|r " .. format(overrideCount > 1 and L["%d overrides"] or L["%d override"], overrideCount))
        overrideText:SetTextColor(1, 0.67, 0)
    else
        overrideText:SetText("")
    end
    overrideText:SetWidth(80)
    overrideText:SetJustifyH("LEFT")

    -- Hoverable overlay on override count to show tooltip with details
    if overrideCount > 0 then
        local overrideBtn = CreateFrame("Button", nil, row)
        overrideBtn:SetPoint("LEFT", overrideText, "LEFT", -4, 0)
        overrideBtn:SetSize(88, 22)

        overrideBtn:SetScript("OnEnter", function(self)
            overrideText:SetTextColor(1, 0.8, 0.2)
            local lines = { " " }
            local groups, unknownKeys = GroupOverridesByTab(profile.overrides)
            local tabOrder = {}
            for tabId in pairs(groups) do tinsert(tabOrder, tabId) end
            table.sort(tabOrder)

            -- Global (un-overridden) raid values, to diff table overrides against so
            -- we show ONLY what the layout changed — not the whole stored config.
            -- While editing, live previews are written into DF._realRaidDB, so the
            -- TRUE global lives in globalSnapshot (diffing against _realRaidDB then
            -- would hide every change).
            local realRaid = (AutoProfilesUI:IsEditing() and AutoProfilesUI.globalSnapshot) or DF._realRaidDB or (DF.db and DF.db.raid)
            -- Hard cap on tooltip body lines so a large layout can't overflow the
            -- screen. Every emitted line (group headers, scalars, walk leaves, Other)
            -- counts; once the cap is hit we stop and flag truncation. The footer
            -- pointing at /df debug overrides (the complete dump) always shows.
            local MAX_LINES = 40
            local shown, truncated = 0, false
            local function canEmit()
                if shown >= MAX_LINES then truncated = true return false end
                shown = shown + 1
                return true
            end
            local budget = { n = nil }  -- the line cap governs length, not this
            -- Breadcrumb headers (val == nil) print as a grey line; leaves print
            -- the value INLINE next to the key (not a right-floating column) so a
            -- wide breadcrumb header doesn't push every value to the screen edge.
            local function emitTT(indent, label, val)
                if not canEmit() then return end
                if val == nil then
                    lines[#lines + 1] = { text = indent .. label, color = { 0.6, 0.6, 0.6 } }
                else
                    lines[#lines + 1] = {
                        text  = indent .. label .. "  |cffffffff" .. val .. "|r",
                        color = { 0.8, 0.8, 0.8 },
                    }
                end
            end
            -- Render one override key: scalars shown directly; a table-valued override
            -- is diffed against its global so only the changed leaves appear.
            local function renderKey(key, lr, lg, lb)
                local value = profile.overrides[key]
                if type(value) == "table" and not (value.r and value.g and value.b) then
                    if not canEmit() then return end
                    lines[#lines + 1] = { text = "  " .. KeyLabel(key) .. ":", color = { lr, lg, lb } }
                    WalkOverrideDiff(value, realRaid and realRaid[key], "", "    ", 1, 8, budget, emitTT)
                else
                    if not canEmit() then return end
                    local displayVal
                    if type(value) == "boolean" then
                        displayVal = value and "true" or "false"
                    elseif type(value) == "table" then
                        displayVal = string.format("(%.1f, %.1f, %.1f)", value.r, value.g, value.b)
                    else
                        displayVal = tostring(value)
                    end
                    lines[#lines + 1] = { left = "  " .. KeyLabel(key), right = displayVal, color = { lr, lg, lb } }
                end
            end

            for _, tabId in ipairs(tabOrder) do
                if not canEmit() then break end
                local group = groups[tabId]
                lines[#lines + 1] = {
                    text  = group.tabLabel .. " (" .. #group.keys .. ")",
                    color = { 1, 0.67, 0 },
                }
                table.sort(group.keys)
                for _, key in ipairs(group.keys) do
                    renderKey(key, 0.8, 0.8, 0.8)
                    if truncated then break end
                end
                if truncated then break end
            end

            if #unknownKeys > 0 and not truncated and canEmit() then
                lines[#lines + 1] = { text = format(L["Other (%d)"], #unknownKeys), color = { 0.5, 0.5, 0.5 } }
                table.sort(unknownKeys)
                for _, key in ipairs(unknownKeys) do
                    renderKey(key, 0.5, 0.5, 0.5)
                    if truncated then break end
                end
            end

            lines[#lines + 1] = " "
            if truncated then
                lines[#lines + 1] = { text = L["Too many to show here."], color = { 1, 0.6, 0.2 } }
            end
            -- /df debug overrides reports on the active layout (or one being edited), not
            -- whichever row is hovered — so note that inactive layouts need Edit first.
            lines[#lines + 1] = {
                text  = L["Use /df debug overrides for the full list — active layout, or Edit one to inspect it."],
                color = { 0.4, 0.4, 0.4 },
            }

            GUI:ShowTooltip(self, {
                title = L["Override Details"],
                tone  = "caution",   -- gold, matching the override text this hangs off
                lines = lines,
            })
        end)

        overrideBtn:SetScript("OnLeave", function()
            overrideText:SetTextColor(1, 0.67, 0)
            GUI:HideTooltip()
        end)
    end

    -- Copy To button — normal styling with a white label. It's a raid-only
    -- feature and the page is already saturated with raid orange, so this
    -- secondary action doesn't need its own orange text.
    local copyBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    copyBtn:SetPoint("RIGHT", -120, 0)
    GUI:StyleButton(copyBtn, { width = 55, height = 20, text = L["Copy To"] })

    copyBtn:SetScript("OnClick", function()
        AutoProfilesUI:ShowCopyDialog(contentType, profile, index, pageFrame)
    end)

    -- Unlock button — ACTIVE layout only. Mirrors the main toolbar Lock/Unlock
    -- toggle (icon + text) but scoped to this layout: clicking it edits THIS
    -- (active) layout with the raid frames unlocked, so dragging saves the position
    -- into the layout instead of the base. The main toolbar Unlock is disabled
    -- while a layout is active (steering position edits here), same convention as
    -- Edit Settings being active-layout-only.
    if AutoProfilesUI.activeRuntimeProfile == profile then
        local unlockBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        unlockBtn:SetSize(80, 20)
        unlockBtn:SetPoint("RIGHT", copyBtn, "LEFT", -6, 0)
        -- Toggle on the shared styler (orange identity); SetActive while unlocked.
        GUI:StyleButton(unlockBtn, { accent = { r = 1, g = 0.5, b = 0.2 } })

        local unlockIcon = unlockBtn:CreateTexture(nil, "OVERLAY")
        unlockIcon:SetSize(12, 12)
        unlockBtn.Icon = unlockIcon

        local unlockText = unlockBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        unlockText:SetPoint("CENTER", unlockBtn, "CENTER", 8, 0)
        unlockIcon:SetPoint("RIGHT", unlockText, "LEFT", -4, 0)
        unlockText:SetTextColor(0.9, 0.9, 0.9)
        unlockBtn.Text = unlockText

        local function RefreshUnlockBtn()
            local locked = DF:GetRaidDB().raidLocked
            unlockText:SetText(locked and L["Unlock"] or L["Lock"])
            unlockIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. (locked and "lock" or "lock_open"))
            unlockIcon:SetVertexColor(0.9, 0.9, 0.9)
            unlockBtn:SetActive(not locked)  -- accent fill/border while unlocked (editing)
        end
        RefreshUnlockBtn()

        unlockBtn:HookScript("OnEnter", function(self)
            GUI:ShowTooltip(self, {
                title = L["Unlock to Move"],
                tone = "warning",
                lines = {
                    L["Unlock this layout's frames to drag them. Changes save to this layout."],
                },
            })
        end)
        unlockBtn:HookScript("OnLeave", function()
            GUI:HideTooltip()
        end)
        unlockBtn:SetScript("OnClick", function()
            local locked = DF:GetRaidDB().raidLocked
            if locked then
                if InCombatLockdown() then
                    DF:Err("Cannot unlock during combat.")
                    return
                end
                -- Edit THIS layout (already the active one) so drag-writes land on
                -- it, then unlock for world dragging. Skip re-entering if Edit
                -- Settings already opened this layout (don't steal that session).
                local alreadyEditingThis = AutoProfilesUI:IsEditing()
                    and AutoProfilesUI.editingProfile == profile
                if not alreadyEditingThis then
                    -- Refused (shouldn't happen for the active layout) → don't fall
                    -- through to unlocking the BASE, which is the bug we're fixing.
                    if AutoProfilesUI:EnterEditing(contentType.key, index) == false then return end
                    DF.raidLayoutEditUnlock = true
                end
                if DF.UnlockRaidFrames then DF:UnlockRaidFrames() end
            else
                if DF.LockRaidFrames then DF:LockRaidFrames() end
            end
            RefreshUnlockBtn()
        end)
    end

    -- Edit Settings button — AutoProfiles orange identity; greys out via
    -- SetDisabled when this layout can't be edited (blockEdit below).
    local editBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    editBtn:SetSize(75, 20)
    editBtn:SetPoint("RIGHT", -40, 0)
    GUI:StyleButton(editBtn, {
        text = L["Edit Settings"],
        accent = { r = 1, g = 0.5, b = 0.2 },
    })
    editBtn:SetScript("OnClick", function(self)
        if self.dfDisabled then return end
        AutoProfilesUI:EnterEditing(contentType.key, index)
    end)

    -- Grey out the edit button when editing this layout would disturb the live
    -- raid frames. Entering edit writes the layout's settings into the live raid
    -- db for preview, so the real raid frames only stay correct when the layout
    -- being edited is the one actually driving them. Block when:
    --   * a DIFFERENT layout is running — only the active layout is editable; OR
    --   * you're in a raid group with NO layout running — any layout you edit
    --     wouldn't match what's on screen and would shove the live frames to its
    --     geometry, so nothing is editable here (leave the raid to edit others).
    -- Outside a raid group there are no real raid frames to disturb, so editing
    -- any layout is fine.
    local blockEdit = (self.activeRuntimeProfile ~= profile)
        and (self.activeRuntimeProfile ~= nil or IsInRaid())
    if blockEdit then
        local tipLine
        if self.activeRuntimeProfile then
            tipLine = L["Only the active layout can be edited\nwhile auto layouts are running."]
        else
            tipLine = L["While in a raid group you can only edit the active layout. Leave the raid group to edit other layouts."]
        end
        editBtn:SetDisabled(true)
        editBtn:HookScript("OnEnter", function(btn)
            GUI:ShowTooltip(btn, {
                title = L["Cannot Edit"],
                tone = "danger",
                lines = { tipLine },
            })
        end)
        editBtn:HookScript("OnLeave", function()
            GUI:HideTooltip()
        end)
    end

    -- Delete button (destructive — red hover wash via the shared styler)
    local deleteBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    deleteBtn:SetSize(22, 20)
    deleteBtn:SetPoint("RIGHT", -10, 0)
    GUI:StyleButton(deleteBtn, {
        accent = { r = 0.8, g = 0.2, b = 0.2 },
        icon = {
            texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\delete",
            size = 12,
            color = { r = 0.6, g = 0.6, b = 0.6 },
        },
    })

    deleteBtn:HookScript("OnEnter", function(self)
        self.Icon:SetVertexColor(1, 0.3, 0.3)
        GUI:ShowTooltip(self, { title = L["Delete Layout"] })
    end)
    deleteBtn:HookScript("OnLeave", function(self)
        self.Icon:SetVertexColor(0.6, 0.6, 0.6)
        GUI:HideTooltip()
    end)
    deleteBtn:SetScript("OnClick", function()
        DF:ShowPopupAlert({
            title   = L["Delete Layout"],
            message = format(L["Delete layout \"%s\"?"], profile.name),
            buttons = {
                {
                    label = L["Delete"],
                    onClick = function()
                        AutoProfilesUI:DeleteProfile(contentType.key, index)
                        if pageFrame.Refresh then pageFrame:Refresh() end
                    end,
                },
                { label = L["Cancel"] },
            },
        })
    end)
    
    return row
end

-- Create Add Layout button
function AutoProfilesUI:CreateAddButton(GUI, pageFrame, parent, contentType)
    local self = AutoProfilesUI
    
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetHeight(24)

    GUI:StyleButton(btn, { height = 24, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 14 }, text = L["Add Layout"] })

    btn:SetScript("OnClick", function()
        if contentType.key == "mythic" then
            -- Just create the mythic profile directly
            AutoProfilesUI:CreateProfile("mythic", "Mythic Setup")
            if pageFrame.Refresh then pageFrame:Refresh() end
        else
            -- Show add layout dialog
            AutoProfilesUI:ShowProfileDialog(contentType, nil, nil, pageFrame)
        end
    end)
    
    return btn
end

-- ============================================================
-- PROFILE DIALOG (Add/Edit)
-- Anchored to main GUI frame center, no overlay
-- ============================================================

local profileDialog = nil

function AutoProfilesUI:CreateProfileDialog()
    if profileDialog then return profileDialog end
    
    -- Dialog frame - parented to UIParent like click casting does
    local dialog = CreateFrame("Frame", "DandersAutoProfileDialog", UIParent, "BackdropTemplate")
    -- ⚠ Anchoring to DF.GUIFrame (next line) positions it with the GUI but does NOT
    -- scale it -- a point is not a parent. Register for the scale as well.
    if DF.GUI and DF.GUI.RegisterScaledSurface then DF.GUI:RegisterScaledSurface(dialog) end
    dialog:SetSize(360, 240)
    dialog:SetPoint("CENTER", DF.GUIFrame or UIParent, "CENTER", 0, 0)
    DF.GUI:CreatePanelBackdrop(dialog, { bgAlpha = 0.98, borderColor = { 0, 0, 0, 1 } })
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetFrameLevel(100)
    dialog:EnableMouse(true)
    dialog:SetMovable(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
    dialog:Hide()

    -- Title
    local title = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetTextColor(0.9, 0.9, 0.9)
    dialog.title = title

    -- Close button
    local closeBtn = DF.GUI:CreateCloseButton(dialog, { onClick = function() dialog:Hide() end })
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    
    -- =============================================
    -- Profile Name Section
    -- =============================================
    local nameLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    nameLabel:SetPoint("TOPLEFT", 12, -40)
    nameLabel:SetText(L["Layout Name"])
    nameLabel:SetTextColor(0.6, 0.6, 0.6)
    dialog.nameLabel = nameLabel

    local nameInput = CreateFrame("EditBox", nil, dialog, "BackdropTemplate")
    nameInput:SetSize(336, 26)
    nameInput:SetPoint("TOPLEFT", 12, -56)
    DF.GUI:StyleEditBox(nameInput, {})
    nameInput:SetAutoFocus(false)
    nameInput:SetMaxLetters(30)
    nameInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    nameInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nameInput:SetScript("OnTextChanged", function(self)
        AutoProfilesUI:ValidateDialog()
    end)
    dialog.nameInput = nameInput
    
    -- =============================================
    -- Range Section with Dual-Handle Slider
    -- =============================================
    local rangeLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    rangeLabel:SetPoint("TOPLEFT", 12, -92)
    rangeLabel:SetText(L["Player Range"])
    rangeLabel:SetTextColor(0.6, 0.6, 0.6)
    dialog.rangeLabel = rangeLabel

    -- Range display
    local rangeDisplay = dialog:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    rangeDisplay:SetPoint("TOPRIGHT", -12, -92)
    rangeDisplay:SetTextColor(1, 0.5, 0.2)
    dialog.rangeDisplay = rangeDisplay
    
    -- Dual-handle range slider (shared helper). Preserves the orange accent and
    -- the original 1..40 scale labels; drag/track-click/dragging-state are all
    -- handled internally by the helper.
    local slider = DF.GUI:CreateRangeSlider(dialog, {
        width = 336,
        accent = { r = 1, g = 0.5, b = 0.2 },
        minRange = 1, maxRange = 40,
        lo = dialog.currentMin or 1, hi = dialog.currentMax or 40,
        scaleLabels = {1, 10, 20, 30, 40}, scaleMin = 1, scaleMax = 40,
        display = rangeDisplay,
        formatOne   = function(v) return format(L["%d players"], v) end,
        formatRange = function(lo, hi) return format(L["%d - %d players"], lo, hi) end,
        onChange = function(lo, hi)
            dialog.currentMin, dialog.currentMax = lo, hi
            AutoProfilesUI:ValidateDialog()
        end,
    })
    slider:SetPoint("TOPLEFT", 12, -112)
    dialog.sliderTrack = slider

    dialog.UpdateSliderVisuals = function()
        local ct = dialog.contentType
        if not ct then return end
        slider:SetRange(ct.minRange, ct.maxRange)
        slider:SetValues(dialog.currentMin or ct.minRange, dialog.currentMax or ct.maxRange)
        AutoProfilesUI:ValidateDialog()
    end
    
    -- =============================================
    -- Validation Message
    -- =============================================
    local validationIcon = dialog:CreateTexture(nil, "OVERLAY")
    validationIcon:SetSize(14, 14)
    validationIcon:SetPoint("TOPLEFT", 12, -152)
    dialog.validationIcon = validationIcon
    
    local validationMsg = dialog:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    validationMsg:SetPoint("LEFT", validationIcon, "RIGHT", 6, 0)
    validationMsg:SetWidth(310)
    validationMsg:SetJustifyH("LEFT")
    dialog.validationMsg = validationMsg
    
    -- =============================================
    -- Buttons
    -- =============================================
    local cancelBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    cancelBtn:SetPoint("BOTTOMLEFT", 12, 12)
    DF.GUI:StyleButton(cancelBtn, { width = 80, height = 26, text = L["Cancel"] })
    cancelBtn:SetScript("OnClick", function()
        dialog:Hide()
    end)

    local createBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    createBtn:SetPoint("BOTTOMRIGHT", -12, 12)
    -- Primary CTA in the AutoProfiles orange identity; ValidateDialog drives its
    -- greyed (disabled) state via SetDisabled below.
    DF.GUI:StyleButton(createBtn, {
        width = 100, height = 26, text = L["Create Layout"],
        primary = true, accent = { r = 1, g = 0.5, b = 0.2 },
    })
    dialog.createBtnText = createBtn.Text

    createBtn:SetScript("OnClick", function(self)
        if self.dfDisabled then return end
        AutoProfilesUI:SubmitDialog()
    end)
    dialog.createBtn = createBtn

    profileDialog = dialog
    return dialog
end

function AutoProfilesUI:ShowProfileDialog(contentType, profile, profileIndex, pageFrame)
    local dialog = self:CreateProfileDialog()
    
    -- Re-anchor to GUI frame if it exists now
    if DF.GUIFrame then
        dialog:ClearAllPoints()
        dialog:SetPoint("CENTER", DF.GUIFrame, "CENTER", 0, 0)
    end
    
    -- Store context
    dialog.contentType = contentType
    dialog.profile = profile
    dialog.profileIndex = profileIndex
    dialog.pageFrame = pageFrame
    dialog.isEditMode = (profile ~= nil)
    
    -- Set title
    if dialog.isEditMode then
        -- ★ EDIT MODE SHOWS THE NAME TOO, so this is where a layout gets renamed.
        -- The field was hidden here and the dialog was titled "Edit Layout Range",
        -- which left no way to rename a layout at all once it existed -- the name was
        -- fixed at creation for the life of the layout. Same geometry as create mode
        -- now, so the two states differ only in their title and button text.
        -- ⚠ The duplicate-name check downstream already excluded the edited layout's
        -- own index (written for this and previously unreachable), so re-saving with
        -- the name untouched is not a conflict.
        dialog.title:SetText(L["Edit Layout"])
        dialog.createBtnText:SetText(L["Save Changes"])
        dialog.nameLabel:Show()
        dialog.nameInput:Show()
        dialog.rangeLabel:ClearAllPoints()
        dialog.rangeLabel:SetPoint("TOPLEFT", 12, -92)
        dialog.sliderTrack:ClearAllPoints()
        dialog.sliderTrack:SetPoint("TOPLEFT", 12, -112)
        dialog.validationIcon:ClearAllPoints()
        dialog.validationIcon:SetPoint("TOPLEFT", 12, -152)
        dialog:SetHeight(220)
    else
        dialog.title:SetText(L["Add Layout"])
        dialog.createBtnText:SetText(L["Create Layout"])
        dialog.nameLabel:Show()
        dialog.nameInput:Show()
        -- Reset positions to default
        dialog.rangeLabel:ClearAllPoints()
        dialog.rangeLabel:SetPoint("TOPLEFT", 12, -92)
        dialog.sliderTrack:ClearAllPoints()
        dialog.sliderTrack:SetPoint("TOPLEFT", 12, -112)
        dialog.validationIcon:ClearAllPoints()
        dialog.validationIcon:SetPoint("TOPLEFT", 12, -152)
        dialog:SetHeight(220)
    end
    
    -- Set initial values
    if dialog.isEditMode then
        dialog.nameInput:SetText(profile.name or "")
        dialog.currentMin = profile.min or contentType.minRange
        dialog.currentMax = profile.max or contentType.maxRange
    else
        dialog.nameInput:SetText("")
        local existingProfiles = self:GetProfiles(contentType.key)
        dialog.currentMin, dialog.currentMax = self:SuggestRange(contentType, existingProfiles)
    end
    
    -- Update visuals and show
    dialog.UpdateSliderVisuals()
    self:ValidateDialog()
    dialog:Show()
    
    -- Focus the name in BOTH modes: renaming is now the usual reason to open this in
    -- edit mode (the row's name is the click target), and the range is driven by the
    -- slider rather than the keyboard, so nothing competes for focus.
    dialog.nameInput:SetFocus()
end

function AutoProfilesUI:SuggestRange(contentType, existingProfiles)
    if #existingProfiles == 0 then
        return 1, 20
    end
    
    local sorted = {}
    for _, p in ipairs(existingProfiles) do
        table.insert(sorted, {min = p.min, max = p.max})
    end
    table.sort(sorted, function(a, b) return a.min < b.min end)
    
    if sorted[1].min > contentType.minRange then
        return contentType.minRange, sorted[1].min - 1
    end
    
    for i = 1, #sorted - 1 do
        if sorted[i].max + 1 < sorted[i + 1].min then
            return sorted[i].max + 1, sorted[i + 1].min - 1
        end
    end
    
    if sorted[#sorted].max < contentType.maxRange then
        return sorted[#sorted].max + 1, contentType.maxRange
    end
    
    return contentType.minRange, contentType.maxRange
end

function AutoProfilesUI:ValidateDialog()
    local dialog = profileDialog
    if not dialog or not dialog:IsShown() then return false end
    
    local contentType = dialog.contentType
    local isValid = true
    local errorMsg = nil
    
    local name = strtrim(dialog.nameInput:GetText() or "")
    local minVal = dialog.currentMin or 1
    local maxVal = dialog.currentMax or 40
    
    -- Validate the name. ⚠ Runs in EDIT mode too now that the field is shown there --
    -- it was create-only while renaming was impossible, and leaving it that way would
    -- have let a rename clear the name or collide with another layout, with the failure
    -- surfacing only after Save.
    -- ☠ The duplicate scan must SKIP THE LAYOUT BEING EDITED, or a layout would always
    -- conflict with itself and Save would be dead the moment the dialog opened.
    if name == "" then
        isValid = false
        errorMsg = L["Enter a profile name"]
    else
        local profiles = self:GetProfiles(contentType.key)
        for i, p in ipairs(profiles) do
            if not (dialog.isEditMode and i == dialog.profileIndex)
                and p.name and p.name:lower() == name:lower() then
                isValid = false
                errorMsg = L["A profile with this name already exists"]
                break
            end
        end
    end

    -- Validate range
    if isValid then
        local excludeIndex = dialog.isEditMode and dialog.profileIndex or nil
        local overlap = self:CheckRangeOverlap(contentType.key, minVal, maxVal, excludeIndex)
        if overlap then
            isValid = false
            errorMsg = format(L["Overlaps with \"%s\" (%d-%d)"], overlap.name, overlap.min, overlap.max)
        end
    end

    -- Update validation display
    if isValid then
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
        dialog.validationIcon:SetVertexColor(0.3, 0.85, 0.3)
        dialog.validationMsg:SetText(L["Valid range"])
        dialog.validationMsg:SetTextColor(0.3, 0.85, 0.3)
    elseif errorMsg then
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
        dialog.validationIcon:SetVertexColor(0.85, 0.3, 0.3)
        dialog.validationMsg:SetText(errorMsg)
        dialog.validationMsg:SetTextColor(0.85, 0.3, 0.3)
    else
        dialog.validationIcon:SetTexture(nil)
        dialog.validationMsg:SetText("")
    end
    
    -- Greyed (disabled) while the input is invalid; SetDisabled handles the
    -- dimmed backdrop + faded label.
    dialog.createBtn:SetDisabled(not isValid)

    return isValid
end

function AutoProfilesUI:SubmitDialog()
    local dialog = profileDialog
    if not dialog then return end
    
    local name = strtrim(dialog.nameInput:GetText() or "")
    local minVal = dialog.currentMin
    local maxVal = dialog.currentMax
    local contentType = dialog.contentType
    
    local success, err
    if dialog.isEditMode then
        -- ⚠ RENAME FIRST, RANGE SECOND, AND BAIL IF THE RENAME FAILS. UpdateProfileRange
        -- re-sorts the list by range, which invalidates profileIndex -- renaming after it
        -- could land on a different layout. Failing closed also keeps the dialog honest:
        -- a rejected name (duplicate/empty) leaves BOTH values untouched rather than
        -- silently applying half the edit.
        success, err = self:RenameProfile(contentType.key, dialog.profileIndex, name)
        if success then
            success, err = self:UpdateProfileRange(contentType.key, dialog.profileIndex, minVal, maxVal)
        end
    else
        success, err = self:CreateProfile(contentType.key, name, minVal, maxVal)
    end
    
    if success then
        dialog:Hide()
        if dialog.pageFrame and dialog.pageFrame.Refresh then
            dialog.pageFrame:Refresh()
        end
        -- Re-evaluate which profile should be active after range change
        self:EvaluateAndApply()
    else
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
        dialog.validationIcon:SetVertexColor(0.85, 0.3, 0.3)
        dialog.validationMsg:SetText(err or L["Unknown error"])
        dialog.validationMsg:SetTextColor(0.85, 0.3, 0.3)
    end
end

-- ============================================================
-- COPY TO DIALOG
-- ============================================================

local copyDialog = nil

function AutoProfilesUI:CreateCopyDialog()
    if copyDialog then return copyDialog end

    local dialog = CreateFrame("Frame", "DandersAutoProfileCopyDialog", UIParent, "BackdropTemplate")
    if DF.GUI and DF.GUI.RegisterScaledSurface then DF.GUI:RegisterScaledSurface(dialog) end
    dialog:SetSize(360, 280)
    dialog:SetPoint("CENTER", DF.GUIFrame or UIParent, "CENTER", 0, 0)
    DF.GUI:CreatePanelBackdrop(dialog, { bgAlpha = 0.98, borderColor = { 0, 0, 0, 1 } })
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetFrameLevel(100)
    dialog:EnableMouse(true)
    dialog:SetMovable(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
    dialog:Hide()

    -- Title
    local title = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText(L["Copy Layout"])
    title:SetTextColor(0.9, 0.9, 0.9)
    dialog.title = title

    -- Close button
    local closeBtn = DF.GUI:CreateCloseButton(dialog, { onClick = function() dialog:Hide() end })
    closeBtn:SetPoint("TOPRIGHT", -6, -6)

    -- =============================================
    -- Layout Name Section
    -- =============================================
    local nameLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    nameLabel:SetPoint("TOPLEFT", 12, -40)
    nameLabel:SetText(L["Layout Name"])
    nameLabel:SetTextColor(0.6, 0.6, 0.6)

    local nameInput = CreateFrame("EditBox", nil, dialog, "BackdropTemplate")
    nameInput:SetSize(336, 26)
    nameInput:SetPoint("TOPLEFT", 12, -56)
    DF.GUI:StyleEditBox(nameInput, {})
    nameInput:SetAutoFocus(false)
    nameInput:SetMaxLetters(30)
    nameInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    nameInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nameInput:SetScript("OnTextChanged", function()
        AutoProfilesUI:ValidateCopyDialog()
    end)
    dialog.nameInput = nameInput

    -- =============================================
    -- Destination Selector (radio-style buttons)
    -- =============================================
    local destLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    destLabel:SetPoint("TOPLEFT", 12, -92)
    destLabel:SetText(L["Copy To"])
    destLabel:SetTextColor(0.6, 0.6, 0.6)

    local destButtons = {}
    local buttonWidth = 106
    local buttonSpacing = 6
    local startX = 12

    for i, ct in ipairs(CONTENT_TYPES) do
        local btn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
        -- Shared styler (rest + accent-wash hover; SetActive drives selection).
        -- OMIT text: keep the custom label so its colour can track selection.
        DF.GUI:StyleButton(btn, { width = buttonWidth, height = 24 })
        btn:SetPoint("TOPLEFT", startX + (i - 1) * (buttonWidth + buttonSpacing), -108)

        local btnText = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        btnText:SetPoint("CENTER")
        btnText:SetText(ct.title)
        btnText:SetTextColor(0.6, 0.6, 0.6)

        btn.contentType = ct
        btn.label = btnText

        btn:SetScript("OnClick", function(self)
            dialog.selectedDest = self.contentType.key
            AutoProfilesUI:UpdateCopyDestButtons()
            AutoProfilesUI:UpdateCopyRangeVisibility()
            AutoProfilesUI:ValidateCopyDialog()
        end)

        -- Mythic-overwrite warning tooltip: hooked so it rides alongside the
        -- styler's own hover scripts instead of clobbering them.
        btn:HookScript("OnEnter", function(self)
            if self.contentType.key == "mythic" then
                local mythicProfile = DF.db.raidAutoProfiles.mythic.profile
                if mythicProfile then
                    DF.GUI:ShowTooltip(self, {
                        title = L["Will replace existing Mythic layout"],
                        tone = "warning",
                        lines = {
                            format(L["\"%s\" will be overwritten."], mythicProfile.name),
                        },
                    })
                end
            end
        end)

        btn:HookScript("OnLeave", function(self)
            DF.GUI:HideTooltip()
        end)

        destButtons[i] = btn
    end
    dialog.destButtons = destButtons

    -- =============================================
    -- Range Section (dual-handle slider, same as profile dialog)
    -- =============================================
    local rangeLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    rangeLabel:SetPoint("TOPLEFT", 12, -144)
    rangeLabel:SetText(L["Player Range"])
    rangeLabel:SetTextColor(0.6, 0.6, 0.6)
    dialog.rangeLabel = rangeLabel

    local rangeDisplay = dialog:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    rangeDisplay:SetPoint("TOPRIGHT", -12, -144)
    rangeDisplay:SetTextColor(1, 0.5, 0.2)
    dialog.rangeDisplay = rangeDisplay

    -- Dual-handle range slider (shared helper). Copy dialog uses fixed 1..40
    -- bounds (no contentType). Preserves the orange accent + scale labels.
    local slider = DF.GUI:CreateRangeSlider(dialog, {
        width = 336,
        accent = { r = 1, g = 0.5, b = 0.2 },
        minRange = 1, maxRange = 40,
        lo = dialog.currentMin or 1, hi = dialog.currentMax or 40,
        scaleLabels = {1, 10, 20, 30, 40}, scaleMin = 1, scaleMax = 40,
        display = rangeDisplay,
        formatOne   = function(v) return format(L["%d players"], v) end,
        formatRange = function(lo, hi) return format(L["%d - %d players"], lo, hi) end,
        onChange = function(lo, hi)
            dialog.currentMin, dialog.currentMax = lo, hi
            AutoProfilesUI:ValidateCopyDialog()
        end,
    })
    slider:SetPoint("TOPLEFT", 12, -164)
    dialog.sliderTrack = slider

    dialog.UpdateSliderVisuals = function()
        slider:SetRange(1, 40)
        slider:SetValues(dialog.currentMin or 1, dialog.currentMax or 40)
        AutoProfilesUI:ValidateCopyDialog()
    end

    -- Mythic fixed label (shown when mythic is selected destination)
    local mythicFixedLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    mythicFixedLabel:SetPoint("TOPLEFT", 12, -155)
    mythicFixedLabel:SetText(L["Fixed at 20 players (Mythic)"])
    mythicFixedLabel:SetTextColor(0.5, 0.5, 0.5)
    mythicFixedLabel:Hide()
    dialog.mythicFixedLabel = mythicFixedLabel

    -- =============================================
    -- Validation Message
    -- =============================================
    local validationIcon = dialog:CreateTexture(nil, "OVERLAY")
    validationIcon:SetSize(14, 14)
    validationIcon:SetPoint("TOPLEFT", 12, -200)
    dialog.validationIcon = validationIcon

    local validationMsg = dialog:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    validationMsg:SetPoint("LEFT", validationIcon, "RIGHT", 6, 0)
    validationMsg:SetWidth(310)
    validationMsg:SetJustifyH("LEFT")
    dialog.validationMsg = validationMsg

    -- =============================================
    -- Buttons
    -- =============================================
    local cancelBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    cancelBtn:SetPoint("BOTTOMLEFT", 12, 12)
    DF.GUI:StyleButton(cancelBtn, { width = 80, height = 26, text = L["Cancel"] })
    cancelBtn:SetScript("OnClick", function()
        dialog:Hide()
    end)

    local createBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    createBtn:SetPoint("BOTTOMRIGHT", -12, 12)
    -- Primary CTA in the AutoProfiles orange identity; ValidateCopyDialog drives
    -- its greyed (disabled) state via SetDisabled below.
    DF.GUI:StyleButton(createBtn, {
        width = 100, height = 26, text = L["Copy Layout"],
        primary = true, accent = { r = 1, g = 0.5, b = 0.2 },
    })
    dialog.createBtnText = createBtn.Text

    createBtn:SetScript("OnClick", function(self)
        if self.dfDisabled then return end
        AutoProfilesUI:SubmitCopyDialog()
    end)
    dialog.createBtn = createBtn

    copyDialog = dialog
    return dialog
end

function AutoProfilesUI:UpdateCopyDestButtons()
    local dialog = copyDialog
    if not dialog then return end

    for _, btn in ipairs(dialog.destButtons) do
        local isSelected = btn.contentType.key == dialog.selectedDest
        -- Backdrop selection state via the shared styler.
        btn:SetActive(isSelected)
        -- Custom label colour still tracks selection (styler leaves it alone).
        if isSelected then
            local a = (DF.GUI.GetThemeColor and DF.GUI.GetThemeColor()) or { r = 1, g = 0.5, b = 0.2 }
            btn.label:SetTextColor(a.r, a.g, a.b)
        else
            btn.label:SetTextColor(0.6, 0.6, 0.6)
        end
    end
end

function AutoProfilesUI:UpdateCopyRangeVisibility()
    local dialog = copyDialog
    if not dialog then return end

    local isMythic = dialog.selectedDest == "mythic"

    if isMythic then
        dialog.rangeLabel:Hide()
        dialog.rangeDisplay:Hide()
        dialog.sliderTrack:Hide()
        dialog.mythicFixedLabel:Show()
        -- Adjust validation and dialog height
        dialog.validationIcon:ClearAllPoints()
        dialog.validationIcon:SetPoint("TOPLEFT", 12, -175)
        dialog:SetHeight(250)
    else
        dialog.rangeLabel:Show()
        dialog.rangeDisplay:Show()
        dialog.sliderTrack:Show()
        dialog.mythicFixedLabel:Hide()
        dialog.validationIcon:ClearAllPoints()
        dialog.validationIcon:SetPoint("TOPLEFT", 12, -200)
        dialog:SetHeight(280)
    end
end

function AutoProfilesUI:ShowCopyDialog(contentType, profile, index, pageFrame)
    local dialog = self:CreateCopyDialog()

    -- Re-anchor to GUI frame if it exists now
    if DF.GUIFrame then
        dialog:ClearAllPoints()
        dialog:SetPoint("CENTER", DF.GUIFrame, "CENTER", 0, 0)
    end

    -- Store context
    dialog.sourceContentType = contentType.key
    dialog.sourceProfile = profile
    dialog.pageFrame = pageFrame

    -- Pre-fill name
    dialog.nameInput:SetText(format(L["%s (Copy)"], profile.name or L["Unnamed"]))

    -- Default destination to the same content type (same-section copy is common)
    dialog.selectedDest = contentType.key

    -- Set initial range from source profile
    if contentType.isFixed then
        dialog.currentMin = 1
        dialog.currentMax = 40
    else
        dialog.currentMin = profile.min or 1
        dialog.currentMax = profile.max or 40
    end

    -- Update UI
    self:UpdateCopyDestButtons()
    self:UpdateCopyRangeVisibility()
    dialog.UpdateSliderVisuals()
    self:ValidateCopyDialog()
    dialog:Show()
    dialog.nameInput:SetFocus()
end

function AutoProfilesUI:ValidateCopyDialog()
    local dialog = copyDialog
    if not dialog or not dialog:IsShown() then return false end

    local isValid = true
    local errorMsg = nil
    local name = strtrim(dialog.nameInput:GetText() or "")
    local destKey = dialog.selectedDest

    if not destKey then
        isValid = false
        errorMsg = L["Select a destination"]
    elseif name == "" then
        isValid = false
        errorMsg = L["Enter a layout name"]
    else
        -- Check name conflict in destination
        local profiles = self:GetProfiles(destKey)
        for _, p in ipairs(profiles) do
            if p.name:lower() == name:lower() then
                if destKey == "mythic" then
                    -- Mythic replaces, so name conflict is a warning not a block
                    break
                end
                isValid = false
                errorMsg = format(L["A layout with this name already exists in %s"], destKey)
                break
            end
        end

        -- Check range overlap (only for non-mythic destinations)
        if isValid and destKey ~= "mythic" then
            local minVal = dialog.currentMin or 1
            local maxVal = dialog.currentMax or 40
            local overlap = self:CheckRangeOverlap(destKey, minVal, maxVal)
            if overlap then
                isValid = false
                errorMsg = format(L["Overlaps with \"%s\" (%d-%d)"], overlap.name, overlap.min, overlap.max)
            end
        end
    end

    -- Update validation display
    if isValid then
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
        dialog.validationIcon:SetVertexColor(0.3, 0.85, 0.3)
        if destKey == "mythic" and DF.db.raidAutoProfiles.mythic.profile then
            dialog.validationMsg:SetText(L["Will replace existing Mythic layout"])
            dialog.validationMsg:SetTextColor(1, 0.67, 0)
        else
            dialog.validationMsg:SetText(L["Ready to copy"])
            dialog.validationMsg:SetTextColor(0.3, 0.85, 0.3)
        end
    elseif errorMsg then
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
        dialog.validationIcon:SetVertexColor(0.85, 0.3, 0.3)
        dialog.validationMsg:SetText(errorMsg)
        dialog.validationMsg:SetTextColor(0.85, 0.3, 0.3)
    else
        dialog.validationIcon:SetTexture(nil)
        dialog.validationMsg:SetText("")
    end

    -- Greyed (disabled) while the input is invalid; SetDisabled handles the
    -- dimmed backdrop + faded label.
    dialog.createBtn:SetDisabled(not isValid)

    return isValid
end

function AutoProfilesUI:SubmitCopyDialog()
    local dialog = copyDialog
    if not dialog then return end

    local name = strtrim(dialog.nameInput:GetText() or "")
    local destKey = dialog.selectedDest
    local sourceProfile = dialog.sourceProfile

    -- Deep-copy the overrides from the source
    local copiedOverrides = {}
    if sourceProfile.overrides then
        for k, v in pairs(sourceProfile.overrides) do
            copiedOverrides[k] = DeepCopyValue(v)
        end
    end

    if destKey == "mythic" then
        -- Mythic: single profile, just replace
        self:InitDefaults()
        DF.db.raidAutoProfiles.mythic.profile = {
            name = name,
            overrides = copiedOverrides,
        }
    else
        -- Instanced / Open World: use CreateProfile then inject overrides
        local minVal = dialog.currentMin or 1
        local maxVal = dialog.currentMax or 40
        local success, err = self:CreateProfile(destKey, name, minVal, maxVal)
        if not success then
            dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
            dialog.validationIcon:SetVertexColor(0.85, 0.3, 0.3)
            dialog.validationMsg:SetText(err or L["Unknown error"])
            dialog.validationMsg:SetTextColor(0.85, 0.3, 0.3)
            return
        end

        -- Find the newly created profile and inject overrides
        local profiles = DF.db.raidAutoProfiles[destKey].profiles
        for _, p in ipairs(profiles) do
            if p.name == name then
                p.overrides = copiedOverrides
                break
            end
        end
    end

    dialog:Hide()
    if dialog.pageFrame and dialog.pageFrame.Refresh then
        dialog.pageFrame:Refresh()
    end
    self:EvaluateAndApply()
end

-- ============================================================
-- EDITING BANNER
-- ============================================================

local editingBanner = nil

function AutoProfilesUI:CreateEditingBanner(parent)
    if editingBanner then return editingBanner end
    
    local banner = CreateFrame("Frame", "DandersAutoProfilesEditingBanner", parent, "BackdropTemplate")
    banner:SetHeight(50)
    DF.GUI:CreateElementBackdrop(banner, {
        bgColor     = { 0.15, 0.08, 0.03, 1 },
        borderColor = { 1, 0.5, 0.2, 1 },
    })
    banner:SetFrameLevel(parent:GetFrameLevel() + 50)  -- Ensure banner is above page content
    banner:Hide()
    
    -- Edit icon
    local icon = banner:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("LEFT", 12, 0)
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\edit_square")
    icon:SetVertexColor(1, 0.5, 0.2)
    
    -- "Editing:" label
    local editLabel = banner:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    editLabel:SetPoint("LEFT", icon, "RIGHT", 8, 6)
    editLabel:SetText(L["Editing:"])
    editLabel:SetTextColor(0.7, 0.7, 0.7)
    
    -- Profile name and content type
    local profileText = banner:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    profileText:SetPoint("LEFT", editLabel, "RIGHT", 6, 0)
    profileText:SetTextColor(1, 0.5, 0.2)
    banner.profileText = profileText
    
    -- Range info line
    local infoText = banner:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    infoText:SetPoint("LEFT", icon, "RIGHT", 8, -10)
    infoText:SetTextColor(0.5, 0.5, 0.5)
    banner.infoText = infoText
    
    -- Exit Editing button
    local exitBtn = CreateFrame("Button", nil, banner, "BackdropTemplate")
    exitBtn:SetPoint("RIGHT", -12, 0)
    -- Fixed orange accent (raid-only feature identity) so the hover wash doesn't
    -- track the party theme like an unscoped StyleButton would.
    DF.GUI:StyleButton(exitBtn, { width = 90, height = 26, text = L["Exit Editing"], accent = { r = 1, g = 0.5, b = 0.2 } })
    exitBtn:SetScript("OnClick", function()
        AutoProfilesUI:ExitEditing()
    end)

    -- (The per-layout "Reset to Global" Aura Designer button was retired when the
    -- preset dropdown gained an "Inherit (Global)" entry that does the same job.)

    editingBanner = banner
    return banner
end

function AutoProfilesUI:UpdateEditingBanner()
    if not editingBanner then return end

    local info = self:GetEditingInfo()
    if info then
        -- Use "»" (Latin-1) not "→" (U+2192): the bundled font lacks the arrow
        -- glyph and renders it as a "?" / missing-glyph box.
        editingBanner.profileText:SetText(info.contentName .. " » \"" .. info.name .. "\"")

        -- Show contextual info text based on the current page. Aura/Text Designer
        -- are chosen via the preset dropdown on their pages (with an "Inherit
        -- (Global)" entry), so point there; other pages keep the generic message.
        local GUI = DF.GUI
        local pageName = GUI and GUI.CurrentPageName
        if pageName == "auras_auradesigner" then
            editingBanner.infoText:SetText(info.rangeText .. " · |cffffcc66" .. L["Pick an Aura Designer template below for this layout. 'Inherit (Global)' follows your global one."] .. "|r")
        elseif pageName == "text_designer" then
            editingBanner.infoText:SetText(info.rangeText .. " · |cffffcc66" .. L["Pick a Text Designer template below for this layout. 'Inherit (Global)' follows your global one."] .. "|r")
        else
            editingBanner.infoText:SetText(info.rangeText .. " · " .. L["Only changed settings will be saved"])
        end

        editingBanner:Show()
    else
        editingBanner:Hide()
    end
end

function AutoProfilesUI:RefreshEditingUI()
    local GUI = DF.GUI
    if not GUI then return end
    
    -- Update the editing banner
    self:UpdateEditingBanner()
    
    -- Disable profile-related tabs when editing
    local tabsToDisable = {"profiles_auto", "profiles_manage", "profiles_importexport"}
    for _, tabName in ipairs(tabsToDisable) do
        local tab = GUI.Tabs and GUI.Tabs[tabName]
        if tab then
            if self:IsEditing() then
                -- Mark tab as disabled (GUI.lua will also respect this)
                tab.disabled = true
                tab:EnableMouse(false)
                tab.Text:SetTextColor(0.2, 0.2, 0.2)  -- Very dark grey
                tab.Text:SetAlpha(0.8)  -- Also reduce alpha
                if tab.accent then tab.accent:Hide() end
                tab.isActive = false
                tab:SetBackdropColor(0, 0, 0, 0)
            else
                -- Re-enable the tab
                tab.disabled = false
                tab:EnableMouse(true)
                tab.Text:SetTextColor(0.9, 0.9, 0.9)
                tab.Text:SetAlpha(1)  -- Restore alpha
            end
        end
    end
    
    -- Disable Party button and Binds button when editing (must stay in Raid mode)
    local buttonsToDisable = {GUI.PartyButton, GUI.ClicksButton}
    for _, btn in ipairs(buttonsToDisable) do
        if btn then
            if self:IsEditing() then
                btn.disabled = true
                btn:EnableMouse(false)
                btn.Text:SetTextColor(0.2, 0.2, 0.2)
                btn.Text:SetAlpha(0.8)
                btn:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
                btn:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.5)
            else
                btn.disabled = false
                btn:EnableMouse(true)
                btn.Text:SetAlpha(1)
                -- Colors will be restored by UpdateThemeColors below
            end
        end
    end
    
    -- Restore proper button colors when not editing
    if not self:IsEditing() and GUI.UpdateThemeColors then
        GUI.UpdateThemeColors()
    end
    
    -- Update page offset for current page
    self:UpdatePageOffset()
    
    -- Refresh all override indicators
    if GUI.RefreshAllOverrideIndicators then
        GUI.RefreshAllOverrideIndicators()
    end
end

function AutoProfilesUI:UpdatePageOffset()
    local GUI = DF.GUI
    if not GUI or not GUI.CurrentPageName then return end
    
    -- The layout code in GUI.lua now checks IsEditing() and adds offset
    -- We just need to trigger a refresh of the current page
    local page = GUI.Pages[GUI.CurrentPageName]
    if page and page.RefreshStates then
        page:RefreshStates()
    end
end

-- ============================================================
-- INTEGRATE BANNER INTO GUI
-- ============================================================

function AutoProfilesUI:SetupEditingBanner()
    local GUI = DF.GUI
    if not GUI or not GUI.contentFrame then return end

    -- Create the banner parented to the main content frame
    local banner = self:CreateEditingBanner(GUI.contentFrame)
    banner:SetPoint("TOPLEFT", GUI.contentFrame, "TOPLEFT", 0, 0)
    banner:SetPoint("TOPRIGHT", GUI.contentFrame, "TOPRIGHT", 0, 0)

    -- =============================================
    -- SIDEBAR ONBOARDING HINT
    -- Subtle orange border + text on the sidebar when editing starts.
    -- Dismissed on the first user tab click.
    -- =============================================
    local sidebarHint = CreateFrame("Frame", nil, GUI.tabFrame, "BackdropTemplate")
    sidebarHint:SetAllPoints(GUI.tabFrame)
    DF.GUI:CreateElementBackdrop(sidebarHint, {
        fill = false,
        borderColor = { 1, 0.5, 0.2, 0.8 },
    })
    sidebarHint:SetFrameLevel(GUI.tabFrame:GetFrameLevel() + 10)
    sidebarHint:EnableMouse(false)  -- Don't block clicks on tabs underneath
    sidebarHint:Hide()

    -- Hint label at the top of the sidebar with a background
    local hintBg = CreateFrame("Frame", nil, sidebarHint, "BackdropTemplate")
    hintBg:SetPoint("TOPLEFT", sidebarHint, "TOPLEFT", 1, -1)
    hintBg:SetPoint("TOPRIGHT", sidebarHint, "TOPRIGHT", -1, -1)
    hintBg:SetHeight(32)
    DF.GUI:CreateElementBackdrop(hintBg, {
        outline = false,
        bgColor     = { 0.12, 0.06, 0.02, 0.95 },
    })
    hintBg:EnableMouse(false)

    local hintText = hintBg:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    hintText:SetPoint("CENTER", hintBg, "CENTER", 0, 0)
    hintText:SetWidth(140)
    hintText:SetJustifyH("CENTER")
    hintText:SetText("|cffff8020" .. L["Select any tab"] .. "|r " .. L["to customise\nthis profile's settings"])
    hintText:SetTextColor(0.75, 0.75, 0.75)

    -- Subtle pulse animation on the border
    local pulseAlpha = 0.4
    local pulseDir = 1
    sidebarHint:SetScript("OnUpdate", function(self, elapsed)
        pulseAlpha = pulseAlpha + elapsed * pulseDir * 0.6
        if pulseAlpha >= 0.8 then
            pulseAlpha = 0.8
            pulseDir = -1
        elseif pulseAlpha <= 0.3 then
            pulseAlpha = 0.3
            pulseDir = 1
        end
        self:SetBackdropBorderColor(1, 0.5, 0.2, pulseAlpha)
    end)

    self.sidebarHint = sidebarHint
    self.sidebarHintDismissed = false

    -- =============================================
    -- OVERRIDE MARKERS ON NAV TABS / CATEGORIES
    -- A small dot (shared GUI:CreateOverrideMarker — same size, colour and
    -- hover tooltip as every other override marker) on tabs/categories that
    -- carry an override. Clicks fall through to the tab (the marker propagates).
    -- =============================================
    for tabName, tab in pairs(GUI.Tabs) do
        if not tab.overrideStar then
            local m = GUI:CreateOverrideMarker(tab, 8)
            m:SetPoint("LEFT", 12, 0)
            m.tooltipText = L["Override active"]
            m.tooltipSubText = L["This page has an overridden setting."]
            tab.overrideStar = m
        end
    end

    -- Markers on category headers (visible when a category is collapsed).
    for catName, cat in pairs(GUI.Categories) do
        if not cat.overrideStar then
            local m = GUI:CreateOverrideMarker(cat, 8)
            m:SetPoint("RIGHT", -6, 0)
            m.tooltipText = L["Override active"]
            m.tooltipSubText = L["A page in this category has an overridden setting."]
            cat.overrideStar = m
        end
    end

    -- Hook tab button clicks to dismiss sidebar hint and update banner
    -- Tab OnClick calls the local SelectTab (not GUI.SelectTab), so we must
    -- hook each button directly to detect user tab clicks
    for _, btn in pairs(GUI.Tabs) do
        btn:HookScript("OnClick", function()
            if AutoProfilesUI:IsEditing() then
                if not AutoProfilesUI.sidebarHintDismissed
                   and not AutoProfilesUI.suppressHintDismiss then
                    AutoProfilesUI:HideSidebarHint()
                end
                -- Update banner for page-specific elements (e.g. Aura Designer reset button)
                AutoProfilesUI:UpdateEditingBanner()
            end
        end)
    end

    -- Hook into page display to adjust offset when banner is shown
    local originalSelectTab = GUI.SelectTab
    GUI.SelectTab = function(name)
        originalSelectTab(name)

        -- After selecting tab, update banner and page offset
        AutoProfilesUI:UpdateEditingBanner()
        AutoProfilesUI:UpdatePageOffset()

        -- Re-apply disabled tab styling (SelectTab/UpdateThemeColors may have reset colors)
        if AutoProfilesUI:IsEditing() then
            local tabsToDisable = {"profiles_auto", "profiles_manage", "profiles_importexport"}
            for _, tabName in ipairs(tabsToDisable) do
                local tab = GUI.Tabs and GUI.Tabs[tabName]
                if tab then
                    tab.disabled = true
                    tab:EnableMouse(false)
                    tab.Text:SetTextColor(0.2, 0.2, 0.2)  -- Very dark grey
                    tab.Text:SetAlpha(0.8)  -- Also reduce alpha
                    if tab.accent then tab.accent:Hide() end
                    tab.isActive = false
                    tab:SetBackdropColor(0, 0, 0, 0)
                end
            end
        end
    end

    -- Also hook RefreshCurrentPage
    local originalRefresh = GUI.RefreshCurrentPage
    GUI.RefreshCurrentPage = function()
        originalRefresh()
        AutoProfilesUI:UpdateEditingBanner()
        AutoProfilesUI:UpdatePageOffset()
    end
end

function AutoProfilesUI:ShowSidebarHint()
    if self.sidebarHint then
        self.sidebarHintDismissed = false
        self.sidebarHint:Show()
    end
end

function AutoProfilesUI:HideSidebarHint()
    if self.sidebarHint then
        self.sidebarHintDismissed = true
        self.sidebarHint:Hide()
    end
end

-- Refresh orange star indicators on sidebar tabs/categories
-- Shows stars on tabs that contain overridden settings
function AutoProfilesUI:RefreshTabOverrideStars()
    local GUI = DF.GUI
    if not GUI or not GUI.Tabs then return end

    -- Determine which profile's overrides to display
    local profile
    if self:IsEditing() then
        profile = self.editingProfile
    elseif self.activeRuntimeProfile and GUI.SelectedMode == "raid" then
        profile = self.activeRuntimeProfile
    end

    -- Build set of tabIds with overrides
    local tabsWithOverrides = {}
    if profile and profile.overrides then
        for key in pairs(profile.overrides) do
            local tabId = GetOverrideTabId(key)
            if tabId then
                tabsWithOverrides[tabId] = true
            end
        end
    end

    -- Update tab stars
    for tabName, tab in pairs(GUI.Tabs) do
        if tab.overrideStar then
            if tabsWithOverrides[tabName] then
                tab.overrideStar:Show()
            else
                tab.overrideStar:Hide()
            end
        end
    end

    -- Update category stars (show if ANY child tab has overrides)
    if GUI.Categories then
        for catName, cat in pairs(GUI.Categories) do
            if cat.overrideStar then
                local hasOverride = false
                if cat.children then
                    for _, childBtn in ipairs(cat.children) do
                        if childBtn.tabName and tabsWithOverrides[childBtn.tabName] then
                            hasOverride = true
                            break
                        end
                    end
                end
                if hasOverride then
                    cat.overrideStar:Show()
                else
                    cat.overrideStar:Hide()
                end
            end
        end
    end
end

