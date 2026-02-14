local addonName, DF = ...

-- ============================================================
-- AUTO PROFILES UI - Raid-only automatic profile switching
-- ============================================================

local AutoProfilesUI = {}
DF.AutoProfilesUI = AutoProfilesUI

-- Local references
local C_RAID = {r = 1.0, g = 0.5, b = 0.2, a = 1}
local C_WARNING = {r = 1.0, g = 0.67, b = 0.0, a = 1}

-- Content type definitions
local CONTENT_TYPES = {
    {
        key = "instanced",
        title = "Instanced / PvP",
        description = "Raids, dungeons, battlegrounds (1-40)",
        minRange = 1,
        maxRange = 40,
        isFixed = false,
    },
    {
        key = "mythic", 
        title = "Mythic",
        description = "Fixed 20 players",
        minRange = 20,
        maxRange = 20,
        isFixed = true,
    },
    {
        key = "openWorld",
        title = "Open World",
        description = "World bosses, outdoor raids (1-40)",
        minRange = 1,
        maxRange = 40,
        isFixed = false,
    },
}

-- ============================================================
-- LOCAL HELPERS for db.raid access and snapshot lookups
-- Defined here so all functions in this file can reference them
-- ============================================================

-- Parse table-based keys (e.g., "raidGroupVisible_1" -> "raidGroupVisible", 1)
local function ParseTableKey(key)
    local tableName, index = key:match("^(.+)_(%d+)$")
    if tableName and index then
        return tableName, tonumber(index)
    end
    return nil, nil
end

-- Get a value from db.raid, handling table-based keys
local function GetRaidValue(key)
    local tableName, index = ParseTableKey(key)
    if tableName and index then
        local tbl = DF.db.raid[tableName]
        if type(tbl) == "table" then
            return tbl[index]
        end
        return nil
    else
        return DF.db.raid[key]
    end
end

-- Set a value in db.raid, handling table-based keys
local function SetRaidValue(key, value)
    local tableName, index = ParseTableKey(key)
    if tableName and index then
        local tbl = DF.db.raid[tableName]
        if type(tbl) == "table" then
            tbl[index] = value
        end
    else
        DF.db.raid[key] = value
    end
end

-- Get a value from the global snapshot, handling table-based keys
local function GetSnapshotValue(snapshot, key)
    if not snapshot then return nil, false end
    
    -- Direct key match
    if snapshot[key] ~= nil then
        return snapshot[key], true
    end
    
    -- Table-based key (e.g., "raidGroupVisible_1" -> snapshot["raidGroupVisible"][1])
    local tableName, index = ParseTableKey(key)
    if tableName and index and type(snapshot[tableName]) == "table" then
        return snapshot[tableName][index], true
    end
    
    return nil, false
end

-- Initialize database defaults
function AutoProfilesUI:InitDefaults()
    if not DF.db.raidAutoProfiles then
        DF.db.raidAutoProfiles = {
            enabled = false,
            instanced = { profiles = {} },
            mythic = { profile = nil },
            openWorld = { profiles = {} }
        }
    end
end

-- Get profiles for a content type
function AutoProfilesUI:GetProfiles(contentKey)
    self:InitDefaults()
    if contentKey == "mythic" then
        local profile = DF.db.raidAutoProfiles.mythic.profile
        return profile and {profile} or {}
    else
        return DF.db.raidAutoProfiles[contentKey].profiles or {}
    end
end

-- Check for range overlap within a content type
function AutoProfilesUI:CheckRangeOverlap(contentKey, min, max, excludeIndex)
    local profiles = self:GetProfiles(contentKey)
    for i, p in ipairs(profiles) do
        if i ~= excludeIndex then
            if min <= p.max and max >= p.min then
                return p  -- Returns the overlapping profile
            end
        end
    end
    return nil
end

-- Create a profile
function AutoProfilesUI:CreateProfile(contentKey, name, min, max)
    self:InitDefaults()
    
    if contentKey == "mythic" then
        DF.db.raidAutoProfiles.mythic.profile = {
            name = name or "Mythic Setup",
            overrides = {}
        }
        return true
    end
    
    -- Check for name conflict
    local profiles = DF.db.raidAutoProfiles[contentKey].profiles
    for _, p in ipairs(profiles) do
        if p.name:lower() == name:lower() then
            return false, "Name already exists"
        end
    end
    
    -- Check for range overlap
    local overlap = self:CheckRangeOverlap(contentKey, min, max)
    if overlap then
        return false, "Overlaps with " .. overlap.name
    end
    
    -- Create the profile
    table.insert(profiles, {
        name = name,
        min = min,
        max = max,
        overrides = {}
    })
    
    -- Sort by min range
    table.sort(profiles, function(a, b) return a.min < b.min end)
    
    return true
end

-- Delete a profile
function AutoProfilesUI:DeleteProfile(contentKey, index)
    self:InitDefaults()
    
    if contentKey == "mythic" then
        DF.db.raidAutoProfiles.mythic.profile = nil
        return true
    end
    
    local profiles = DF.db.raidAutoProfiles[contentKey].profiles
    if profiles[index] then
        table.remove(profiles, index)
        return true
    end
    return false
end

-- Update profile range
function AutoProfilesUI:UpdateProfileRange(contentKey, index, newMin, newMax)
    self:InitDefaults()
    
    if contentKey == "mythic" then
        return false, "Mythic has fixed range"
    end
    
    local profiles = DF.db.raidAutoProfiles[contentKey].profiles
    if not profiles[index] then
        return false, "Profile not found"
    end
    
    -- Check for overlap (excluding current profile)
    local overlap = self:CheckRangeOverlap(contentKey, newMin, newMax, index)
    if overlap then
        return false, "Overlaps with " .. overlap.name
    end
    
    profiles[index].min = newMin
    profiles[index].max = newMax
    
    -- Re-sort
    table.sort(profiles, function(a, b) return a.min < b.min end)
    
    return true
end

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
        Add(GUI:CreateHeader(pageFrame.child, "Raid Auto Profiles"), 40, "both")
        Add(GUI:CreateLabel(pageFrame.child, 
            "Auto Profiles is a Raid-only feature. Switch to Raid mode to configure automatic profile switching based on content type and group size.",
            500, {r = 0.6, g = 0.6, b = 0.6}), 60, "both")
        return
    end
    
    -- =============================================
    -- Enable Checkbox
    -- =============================================
    local enableCheck = GUI:CreateCheckbox(pageFrame.child, "Enable Raid Auto-Switching Profiles", 
        nil, nil,  -- dbTable, dbKey (not used)
        function() pageFrame:Refresh() end,  -- callback
        function() return autoDb.enabled end,  -- customGet
        function(val) autoDb.enabled = val end  -- customSet
    )
    Add(enableCheck, 30, "both")
    
    AddSpace(5, "both")
    
    -- =============================================
    -- Current Status Box
    -- =============================================
    local statusContainer = CreateFrame("Frame", nil, pageFrame.child, "BackdropTemplate")
    statusContainer:SetSize(500, 55)
    statusContainer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    statusContainer:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    statusContainer:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    
    local statusTitle = statusContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusTitle:SetPoint("TOPLEFT", 10, -8)
    statusTitle:SetText("CURRENT STATUS")
    statusTitle:SetTextColor(0.5, 0.5, 0.5)
    
    local statusLine1 = statusContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusLine1:SetPoint("TOPLEFT", 10, -24)
    
    local statusLine2 = statusContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusLine2:SetPoint("TOPLEFT", 10, -38)
    
    -- Update status display
    if not autoDb.enabled then
        statusLine1:SetText("|cff666666Auto-switching disabled|r")
        statusLine2:SetText("")
    elseif not IsInRaid() then
        statusLine1:SetText("|cff999999Not in a raid group|r")
        statusLine2:SetText("")
    else
        -- TODO: Get actual active profile from detection system
        statusLine1:SetText("|cff66ff66Content:|r |cffffffffInstanced / PvP|r |cff666666— Not detected|r")
        statusLine2:SetText("|cff66ff66Profile:|r |cff999999None active (using global settings)|r")
    end
    
    Add(statusContainer, 60, "both")
    
    AddSpace(5, "both")
    
    -- =============================================
    -- Info Box
    -- =============================================
    local infoContainer = CreateFrame("Frame", nil, pageFrame.child, "BackdropTemplate")
    infoContainer:SetSize(500, 45)
    infoContainer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    infoContainer:SetBackdropColor(0.15, 0.1, 0.05, 0.5)
    infoContainer:SetBackdropBorderColor(0.4, 0.25, 0.1, 0.5)
    
    local infoText = infoContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    infoText:SetPoint("TOPLEFT", 10, -8)
    infoText:SetPoint("BOTTOMRIGHT", -10, 8)
    infoText:SetJustifyH("LEFT")
    infoText:SetJustifyV("TOP")
    infoText:SetText("|cffffffffHow it works:|r Create profiles for different player ranges within each content type. Profiles only store settings that differ from global. If no range matches, global settings are used.")
    infoText:SetTextColor(0.7, 0.7, 0.7)
    
    Add(infoContainer, 50, "both")
    
    AddSpace(10, "both")
    
    -- =============================================
    -- Content Type Sections (dynamic height via layoutHeight)
    -- =============================================
    for _, ct in ipairs(CONTENT_TYPES) do
        local section = self:CreateContentTypeSection(GUI, pageFrame, ct)
        -- Add section with its current height
        Add(section, section.totalHeight, "both")
        AddSpace(8, "both")
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
    
    -- If no profiles and is mythic, need extra space for "no profile set" text
    if contentType.key == "mythic" and numProfiles == 0 then
        bodyHeight = 60  -- Empty text + add button + padding
    elseif contentType.isFixed and numProfiles > 0 then
        -- Mythic with profile - no add button needed
        bodyHeight = (numProfiles * rowHeight) + bodyPadding
    end
    
    local section = CreateFrame("Frame", nil, pageFrame.child, "BackdropTemplate")
    section:SetSize(500, headerHeight)
    section:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    section:SetBackdropColor(0.12, 0.12, 0.12, 1)
    section:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
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
    local titleText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("LEFT", 28, 0)
    titleText:SetText(contentType.title)
    titleText:SetTextColor(1, 0.5, 0.2)  -- Raid orange
    
    -- Description
    local descText = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
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
        local emptyText = section.body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        emptyText:SetPoint("TOP", 0, -10)
        emptyText:SetText("|cff666666No profile set. Using global settings.|r")
        
        -- Add button for mythic (centered, full width)
        local addBtn = self:CreateAddButton(GUI, pageFrame, section.body, contentType)
        addBtn:SetPoint("TOPLEFT", 10, -32)
        addBtn:SetPoint("TOPRIGHT", -10, -32)
    elseif not contentType.isFixed then
        -- Add Profile button (full width)
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
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.08, 0.08, 0.08, 1)
    
    -- Profile name
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", 10, 0)
    nameText:SetText(profile.name or "Unnamed")
    nameText:SetWidth(100)
    nameText:SetJustifyH("LEFT")
    
    -- Range badge
    local rangeBadge = CreateFrame("Button", nil, row, "BackdropTemplate")
    rangeBadge:SetSize(65, 18)
    rangeBadge:SetPoint("LEFT", 115, 0)
    rangeBadge:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    rangeBadge:SetBackdropColor(0.18, 0.18, 0.18, 1)
    rangeBadge:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    
    local rangeText = rangeBadge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rangeText:SetPoint("CENTER")
    
    if contentType.isFixed then
        rangeText:SetText("20 (fixed)")
        rangeText:SetTextColor(0.5, 0.5, 0.5)
    else
        rangeText:SetText((profile.min or 1) .. " - " .. (profile.max or 40))
        rangeText:SetTextColor(0.7, 0.7, 0.7)
        
        -- Make clickable for editing range
        rangeBadge:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(1, 0.5, 0.2, 1)
            rangeText:SetTextColor(1, 1, 1)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Click to edit range")
            GameTooltip:Show()
        end)
        rangeBadge:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            rangeText:SetTextColor(0.7, 0.7, 0.7)
            GameTooltip:Hide()
        end)
        rangeBadge:SetScript("OnClick", function()
            -- Show edit range dialog
            AutoProfilesUI:ShowProfileDialog(contentType, profile, index, pageFrame)
        end)
    end
    
    -- Override count
    local overrideCount = 0
    if profile.overrides then
        for _ in pairs(profile.overrides) do
            overrideCount = overrideCount + 1
        end
    end
    
    local overrideText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    overrideText:SetPoint("LEFT", 190, 0)
    if overrideCount > 0 then
        overrideText:SetText("|cffffaa00*|r " .. overrideCount .. " override" .. (overrideCount > 1 and "s" or ""))
        overrideText:SetTextColor(1, 0.67, 0)
    else
        overrideText:SetText("")
    end
    overrideText:SetWidth(80)
    overrideText:SetJustifyH("LEFT")
    
    -- Edit Settings button
    local editBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    editBtn:SetSize(75, 20)
    editBtn:SetPoint("RIGHT", -40, 0)
    editBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    editBtn:SetBackdropColor(0.15, 0.15, 0.15, 1)
    editBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    
    local editText = editBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    editText:SetPoint("CENTER")
    editText:SetText("Edit Settings")
    editText:SetTextColor(1, 0.5, 0.2)
    
    editBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.25, 0.15, 0.1, 1)
        self:SetBackdropBorderColor(1, 0.5, 0.2, 1)
    end)
    editBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.15, 0.15, 0.15, 1)
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end)
    editBtn:SetScript("OnClick", function()
        AutoProfilesUI:EnterEditing(contentType.key, index)
    end)
    
    -- Delete button
    local deleteBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    deleteBtn:SetSize(22, 20)
    deleteBtn:SetPoint("RIGHT", -10, 0)
    deleteBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    deleteBtn:SetBackdropColor(0.15, 0.15, 0.15, 1)
    deleteBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    
    local deleteIcon = deleteBtn:CreateTexture(nil, "OVERLAY")
    deleteIcon:SetPoint("CENTER")
    deleteIcon:SetSize(12, 12)
    deleteIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\delete")
    deleteIcon:SetVertexColor(0.6, 0.6, 0.6)
    
    deleteBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.3, 0.1, 0.1, 1)
        self:SetBackdropBorderColor(0.8, 0.2, 0.2, 1)
        deleteIcon:SetVertexColor(1, 0.3, 0.3)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Delete Profile")
        GameTooltip:Show()
    end)
    deleteBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.15, 0.15, 0.15, 1)
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        deleteIcon:SetVertexColor(0.6, 0.6, 0.6)
        GameTooltip:Hide()
    end)
    deleteBtn:SetScript("OnClick", function()
        -- Confirm deletion
        StaticPopupDialogs["DANDERSFRAMES_DELETE_AUTOPROFILE"] = {
            text = "Delete profile \"" .. profile.name .. "\"?",
            button1 = "Delete",
            button2 = "Cancel",
            OnAccept = function()
                AutoProfilesUI:DeleteProfile(contentType.key, index)
                if pageFrame.Refresh then pageFrame:Refresh() end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
        }
        StaticPopup_Show("DANDERSFRAMES_DELETE_AUTOPROFILE")
    end)
    
    return row
end

-- Create Add Profile button
function AutoProfilesUI:CreateAddButton(GUI, pageFrame, parent, contentType)
    local self = AutoProfilesUI
    
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetHeight(24)
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(0.08, 0.08, 0.08, 0)
    btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
    
    -- Centered text
    local btnText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btnText:SetPoint("CENTER", 0, 0)
    btnText:SetText("+ Add Profile")
    btnText:SetTextColor(0.5, 0.5, 0.5)
    
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(1, 0.5, 0.2, 1)
        btnText:SetTextColor(1, 0.5, 0.2)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
        btnText:SetTextColor(0.5, 0.5, 0.5)
    end)
    btn:SetScript("OnClick", function()
        if contentType.key == "mythic" then
            -- Just create the mythic profile directly
            AutoProfilesUI:CreateProfile("mythic", "Mythic Setup")
            if pageFrame.Refresh then pageFrame:Refresh() end
        else
            -- Show add profile dialog
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
    dialog:SetSize(360, 240)
    dialog:SetPoint("CENTER", DF.GUIFrame or UIParent, "CENTER", 0, 0)
    dialog:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    dialog:SetBackdropColor(0.06, 0.06, 0.06, 0.98)
    dialog:SetBackdropBorderColor(0, 0, 0, 1)
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetFrameLevel(100)
    dialog:EnableMouse(true)
    dialog:SetMovable(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
    dialog:Hide()
    
    -- Title
    local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetTextColor(0.9, 0.9, 0.9)
    dialog.title = title
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    closeBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    closeBtn:SetBackdropColor(0.1, 0.1, 0.1, 1)
    closeBtn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    local closeIcon = closeBtn:CreateTexture(nil, "OVERLAY")
    closeIcon:SetSize(12, 12)
    closeIcon:SetPoint("CENTER")
    closeIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
    closeIcon:SetVertexColor(0.5, 0.5, 0.5)
    closeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.8, 0.2, 0.2, 1)
        closeIcon:SetVertexColor(1, 0.3, 0.3)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
        closeIcon:SetVertexColor(0.5, 0.5, 0.5)
    end)
    closeBtn:SetScript("OnClick", function()
        dialog:Hide()
    end)
    
    -- =============================================
    -- Profile Name Section
    -- =============================================
    local nameLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", 12, -40)
    nameLabel:SetText("Profile Name")
    nameLabel:SetTextColor(0.6, 0.6, 0.6)
    dialog.nameLabel = nameLabel
    
    local nameInput = CreateFrame("EditBox", nil, dialog, "BackdropTemplate")
    nameInput:SetSize(336, 26)
    nameInput:SetPoint("TOPLEFT", 12, -56)
    nameInput:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    nameInput:SetBackdropColor(0.03, 0.03, 0.03, 1)
    nameInput:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    nameInput:SetFontObject("GameFontHighlight")
    nameInput:SetTextInsets(8, 8, 0, 0)
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
    local rangeLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rangeLabel:SetPoint("TOPLEFT", 12, -92)
    rangeLabel:SetText("Player Range")
    rangeLabel:SetTextColor(0.6, 0.6, 0.6)
    dialog.rangeLabel = rangeLabel
    
    -- Range display
    local rangeDisplay = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    rangeDisplay:SetPoint("TOPRIGHT", -12, -92)
    rangeDisplay:SetTextColor(1, 0.5, 0.2)
    dialog.rangeDisplay = rangeDisplay
    
    -- Slider track (thinner)
    local sliderWidth = 336
    local sliderTrack = CreateFrame("Frame", nil, dialog, "BackdropTemplate")
    sliderTrack:SetSize(sliderWidth, 12)
    sliderTrack:SetPoint("TOPLEFT", 12, -112)
    sliderTrack:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    sliderTrack:SetBackdropColor(0.03, 0.03, 0.03, 1)
    sliderTrack:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    dialog.sliderTrack = sliderTrack
    
    -- Range fill (between handles)
    local rangeFill = sliderTrack:CreateTexture(nil, "ARTWORK")
    rangeFill:SetTexture("Interface\\Buttons\\WHITE8x8")
    rangeFill:SetVertexColor(1, 0.5, 0.2, 0.5)
    rangeFill:SetHeight(10)
    rangeFill:SetPoint("TOP", 0, -1)
    dialog.rangeFill = rangeFill
    
    -- Helper to calculate position from value
    local function ValueToPos(value, minRange, maxRange)
        local pct = (value - minRange) / (maxRange - minRange)
        return pct * (sliderWidth - 4) + 2
    end
    
    -- Helper to calculate value from position
    local function PosToValue(pos, minRange, maxRange)
        local pct = (pos - 2) / (sliderWidth - 4)
        return math.floor(pct * (maxRange - minRange) + minRange + 0.5)
    end
    
    -- Handle dragging state
    local dragging = nil
    
    -- Min handle (thinner, more elegant)
    local minHandle = CreateFrame("Button", nil, sliderTrack)
    minHandle:SetSize(8, 16)
    minHandle:SetPoint("CENTER", sliderTrack, "LEFT", 2, 0)
    minHandle:EnableMouse(true)
    local minHandleTex = minHandle:CreateTexture(nil, "OVERLAY")
    minHandleTex:SetAllPoints()
    minHandleTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    minHandleTex:SetVertexColor(1, 0.5, 0.2, 1)
    dialog.minHandle = minHandle
    
    -- Max handle
    local maxHandle = CreateFrame("Button", nil, sliderTrack)
    maxHandle:SetSize(8, 16)
    maxHandle:SetPoint("CENTER", sliderTrack, "LEFT", sliderWidth - 2, 0)
    maxHandle:EnableMouse(true)
    local maxHandleTex = maxHandle:CreateTexture(nil, "OVERLAY")
    maxHandleTex:SetAllPoints()
    maxHandleTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    maxHandleTex:SetVertexColor(1, 0.5, 0.2, 1)
    dialog.maxHandle = maxHandle
    
    local function UpdateSliderVisuals()
        local contentType = dialog.contentType
        if not contentType then return end
        
        local minVal = dialog.currentMin or contentType.minRange
        local maxVal = dialog.currentMax or contentType.maxRange
        local minRange = contentType.minRange
        local maxRange = contentType.maxRange
        
        local minPos = ValueToPos(minVal, minRange, maxRange)
        local maxPos = ValueToPos(maxVal, minRange, maxRange)
        
        minHandle:ClearAllPoints()
        minHandle:SetPoint("CENTER", sliderTrack, "LEFT", minPos, 0)
        maxHandle:ClearAllPoints()
        maxHandle:SetPoint("CENTER", sliderTrack, "LEFT", maxPos, 0)
        
        -- Update fill
        rangeFill:ClearAllPoints()
        rangeFill:SetPoint("LEFT", sliderTrack, "LEFT", minPos, 0)
        rangeFill:SetWidth(math.max(maxPos - minPos, 2))
        
        -- Update display
        if minVal == maxVal then
            rangeDisplay:SetText(minVal .. " players")
        else
            rangeDisplay:SetText(minVal .. " - " .. maxVal .. " players")
        end
        
        AutoProfilesUI:ValidateDialog()
    end
    dialog.UpdateSliderVisuals = UpdateSliderVisuals
    
    -- Use OnMouseDown/OnMouseUp for more responsive dragging
    minHandle:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            dragging = "min"
        end
    end)
    
    maxHandle:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            dragging = "max"
        end
    end)
    
    minHandle:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and dragging == "min" then
            dragging = nil
        end
    end)
    
    maxHandle:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and dragging == "max" then
            dragging = nil
        end
    end)
    
    -- Global mouse up to catch releases outside handles
    dialog:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            dragging = nil
        end
    end)
    
    -- OnUpdate on the dialog itself for smoother tracking
    dialog:SetScript("OnUpdate", function(self)
        if not dragging then return end
        
        local contentType = dialog.contentType
        if not contentType then return end
        
        local x = select(1, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local trackLeft = sliderTrack:GetLeft()
        if not trackLeft then return end
        
        local pos = x - trackLeft
        pos = math.max(2, math.min(pos, sliderWidth - 2))
        
        local value = PosToValue(pos, contentType.minRange, contentType.maxRange)
        value = math.max(contentType.minRange, math.min(value, contentType.maxRange))
        
        if dragging == "min" then
            if value <= dialog.currentMax then
                dialog.currentMin = value
            end
        elseif dragging == "max" then
            if value >= dialog.currentMin then
                dialog.currentMax = value
            end
        end
        
        UpdateSliderVisuals()
    end)
    
    -- Click on track to move nearest handle
    sliderTrack:EnableMouse(true)
    sliderTrack:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        
        local contentType = dialog.contentType
        if not contentType then return end
        
        local x = select(1, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local trackLeft = sliderTrack:GetLeft()
        local pos = x - trackLeft
        local value = PosToValue(pos, contentType.minRange, contentType.maxRange)
        
        -- Move closest handle
        local minDist = math.abs(value - dialog.currentMin)
        local maxDist = math.abs(value - dialog.currentMax)
        
        if minDist <= maxDist then
            if value <= dialog.currentMax then
                dialog.currentMin = value
            end
        else
            if value >= dialog.currentMin then
                dialog.currentMax = value
            end
        end
        
        UpdateSliderVisuals()
    end)
    
    -- Scale labels
    local scaleLabels = {1, 10, 20, 30, 40}
    for _, num in ipairs(scaleLabels) do
        local label = sliderTrack:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetText(num)
        label:SetTextColor(0.35, 0.35, 0.35)
        local xPos = ValueToPos(num, 1, 40)
        label:SetPoint("TOP", sliderTrack, "BOTTOM", xPos - sliderWidth/2, -2)
    end
    
    -- =============================================
    -- Validation Message
    -- =============================================
    local validationIcon = dialog:CreateTexture(nil, "OVERLAY")
    validationIcon:SetSize(14, 14)
    validationIcon:SetPoint("TOPLEFT", 12, -152)
    dialog.validationIcon = validationIcon
    
    local validationMsg = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    validationMsg:SetPoint("LEFT", validationIcon, "RIGHT", 6, 0)
    validationMsg:SetWidth(310)
    validationMsg:SetJustifyH("LEFT")
    dialog.validationMsg = validationMsg
    
    -- =============================================
    -- Buttons
    -- =============================================
    local cancelBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    cancelBtn:SetSize(80, 26)
    cancelBtn:SetPoint("BOTTOMLEFT", 12, 12)
    cancelBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    cancelBtn:SetBackdropColor(0.1, 0.1, 0.1, 1)
    cancelBtn:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    
    local cancelText = cancelBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cancelText:SetPoint("CENTER")
    cancelText:SetText("Cancel")
    cancelText:SetTextColor(0.6, 0.6, 0.6)
    
    cancelBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        cancelText:SetTextColor(0.9, 0.9, 0.9)
    end)
    cancelBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
        cancelText:SetTextColor(0.6, 0.6, 0.6)
    end)
    cancelBtn:SetScript("OnClick", function()
        dialog:Hide()
    end)
    
    local createBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    createBtn:SetSize(100, 26)
    createBtn:SetPoint("BOTTOMRIGHT", -12, 12)
    createBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    createBtn:SetBackdropColor(0.15, 0.08, 0.03, 1)
    createBtn:SetBackdropBorderColor(1, 0.5, 0.2, 1)
    
    local createText = createBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    createText:SetPoint("CENTER")
    createText:SetText("Create Profile")
    createText:SetTextColor(1, 0.5, 0.2)
    dialog.createBtnText = createText
    
    createBtn:SetScript("OnEnter", function(self)
        if self.enabled then
            self:SetBackdropColor(0.22, 0.12, 0.05, 1)
        end
    end)
    createBtn:SetScript("OnLeave", function(self)
        if self.enabled then
            self:SetBackdropColor(0.15, 0.08, 0.03, 1)
        end
    end)
    createBtn:SetScript("OnClick", function(self)
        if self.enabled then
            AutoProfilesUI:SubmitDialog()
        end
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
        dialog.title:SetText("Edit Profile Range")
        dialog.createBtnText:SetText("Save Changes")
        dialog.nameLabel:Hide()
        dialog.nameInput:Hide()
        -- Shift elements up (52px offset from hidden name section)
        dialog.rangeLabel:ClearAllPoints()
        dialog.rangeLabel:SetPoint("TOPLEFT", 12, -40)
        dialog.sliderTrack:ClearAllPoints()
        dialog.sliderTrack:SetPoint("TOPLEFT", 12, -60)
        dialog.validationIcon:ClearAllPoints()
        dialog.validationIcon:SetPoint("TOPLEFT", 12, -100)
        dialog:SetHeight(175)
    else
        dialog.title:SetText("Add Profile")
        dialog.createBtnText:SetText("Create Profile")
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
    
    if not dialog.isEditMode then
        dialog.nameInput:SetFocus()
    end
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
    
    -- Validate name (only for new profiles)
    if not dialog.isEditMode then
        if name == "" then
            isValid = false
            errorMsg = "Enter a profile name"
        else
            local profiles = self:GetProfiles(contentType.key)
            for _, p in ipairs(profiles) do
                if p.name:lower() == name:lower() then
                    isValid = false
                    errorMsg = "A profile with this name already exists"
                    break
                end
            end
        end
    end
    
    -- Validate range
    if isValid then
        local excludeIndex = dialog.isEditMode and dialog.profileIndex or nil
        local overlap = self:CheckRangeOverlap(contentType.key, minVal, maxVal, excludeIndex)
        if overlap then
            isValid = false
            errorMsg = "Overlaps with \"" .. overlap.name .. "\" (" .. overlap.min .. "-" .. overlap.max .. ")"
        end
    end
    
    -- Update validation display
    if isValid then
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
        dialog.validationIcon:SetVertexColor(0.3, 0.85, 0.3)
        dialog.validationMsg:SetText("Valid range")
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
    
    -- Update button state
    local btn = dialog.createBtn
    btn.enabled = isValid
    if isValid then
        btn:SetBackdropColor(0.15, 0.08, 0.03, 1)
        btn:SetBackdropBorderColor(1, 0.5, 0.2, 1)
        dialog.createBtnText:SetTextColor(1, 0.5, 0.2)
    else
        btn:SetBackdropColor(0.06, 0.06, 0.06, 1)
        btn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
        dialog.createBtnText:SetTextColor(0.3, 0.3, 0.3)
    end
    
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
        success, err = self:UpdateProfileRange(contentType.key, dialog.profileIndex, minVal, maxVal)
    else
        success, err = self:CreateProfile(contentType.key, name, minVal, maxVal)
    end
    
    if success then
        dialog:Hide()
        if dialog.pageFrame and dialog.pageFrame.Refresh then
            dialog.pageFrame:Refresh()
        end
    else
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
        dialog.validationIcon:SetVertexColor(0.85, 0.3, 0.3)
        dialog.validationMsg:SetText(err or "Unknown error")
        dialog.validationMsg:SetTextColor(0.85, 0.3, 0.3)
    end
end

-- ============================================================
-- EDIT MODE STATE & FUNCTIONS
-- ============================================================

-- Runtime state (not persisted)
AutoProfilesUI.editingProfile = nil
AutoProfilesUI.editingContentType = nil
AutoProfilesUI.editingProfileIndex = nil
AutoProfilesUI.globalSnapshot = nil  -- Snapshot of true global values during editing

function AutoProfilesUI:IsEditing()
    return self.editingProfile ~= nil
end

function AutoProfilesUI:EnterEditing(contentType, profileIndex)
    local autoDb = DF.db.raidAutoProfiles
    
    if contentType == "mythic" then
        self.editingProfile = autoDb.mythic.profile
        self.editingProfileIndex = nil
    else
        local profiles = autoDb[contentType] and autoDb[contentType].profiles
        if profiles and profiles[profileIndex] then
            self.editingProfile = profiles[profileIndex]
            self.editingProfileIndex = profileIndex
        else
            return false, "Profile not found"
        end
    end
    
    self.editingContentType = contentType
    
    -- Snapshot ALL true global values before anything gets modified
    -- This lets controls freely write to db.raid for live preview while
    -- SetProfileSetting/GetGlobalValue always know the original globals
    self.globalSnapshot = {}
    for key, value in pairs(DF.db.raid) do
        if type(value) == "table" then
            local copy = {}
            for k, v in pairs(value) do copy[k] = v end
            self.globalSnapshot[key] = copy
        else
            self.globalSnapshot[key] = value
        end
    end
    
    -- Apply existing overrides to db.raid for live preview
    if self.editingProfile.overrides then
        for key, value in pairs(self.editingProfile.overrides) do
            if type(value) == "table" then
                local copy = {}
                for k, v in pairs(value) do copy[k] = v end
                SetRaidValue(key, copy)
            else
                SetRaidValue(key, value)
            end
        end
    end
    
    -- Refresh the GUI to show editing banner and disable Auto Profiles tab
    self:RefreshEditingUI()
    
    -- Switch to a settings tab (e.g., Layout/Frame)
    local GUI = DF.GUI
    if GUI and GUI.SelectTab then
        GUI.SelectTab("general_frame")
    end
    
    return true
end

function AutoProfilesUI:ExitEditing(skipUIUpdates)
    -- Diff safety net: before restoring globals, scan db.raid vs snapshot
    -- to catch any overrides that weren't explicitly tracked by controls
    if self.editingProfile and self.globalSnapshot then
        if not self.editingProfile.overrides then
            self.editingProfile.overrides = {}
        end
        local overrides = self.editingProfile.overrides
        
        for key, snapshotVal in pairs(self.globalSnapshot) do
            local currentVal = DF.db.raid[key]
            local matches = true
            
            if type(snapshotVal) == "table" and type(currentVal) == "table" then
                -- Deep compare (handles arrays and color tables)
                if #snapshotVal > 0 or #currentVal > 0 then
                    -- Array comparison (ordered)
                    if #snapshotVal ~= #currentVal then
                        matches = false
                    else
                        for i = 1, #snapshotVal do
                            if snapshotVal[i] ~= currentVal[i] then
                                matches = false
                                break
                            end
                        end
                    end
                else
                    -- Hash table comparison (colors etc)
                    for k, v in pairs(snapshotVal) do
                        if currentVal[k] ~= v then matches = false; break end
                    end
                    if matches then
                        for k, v in pairs(currentVal) do
                            if snapshotVal[k] ~= v then matches = false; break end
                        end
                    end
                end
            else
                matches = (snapshotVal == currentVal)
            end
            
            if not matches and overrides[key] == nil then
                -- Value changed but no override recorded — auto-store it
                if type(currentVal) == "table" then
                    local copy = {}
                    for k, v in pairs(currentVal) do copy[k] = v end
                    overrides[key] = copy
                else
                    overrides[key] = currentVal
                end
            elseif matches and overrides[key] ~= nil then
                -- Value matches global but override exists — clean it up
                overrides[key] = nil
            end
        end
    end
    
    -- Restore all modified db.raid values back to their true globals
    if self.globalSnapshot then
        for key, originalValue in pairs(self.globalSnapshot) do
            if type(originalValue) == "table" then
                local copy = {}
                for k, v in pairs(originalValue) do copy[k] = v end
                SetRaidValue(key, copy)
            else
                SetRaidValue(key, originalValue)
            end
        end
    end
    
    self.editingProfile = nil
    self.editingContentType = nil
    self.editingProfileIndex = nil
    self.globalSnapshot = nil
    
    -- Skip UI updates when GUI is closing (UI will reset on next open anyway)
    if skipUIUpdates then return end
    
    -- Refresh frames to show global settings again
    if DF.UpdateAll then DF:UpdateAll() end
    
    -- Refresh UI to hide banner and re-enable Auto Profiles tab
    self:RefreshEditingUI()
    
    -- Switch back to Auto Profiles tab
    local GUI = DF.GUI
    if GUI and GUI.SelectTab then
        GUI.SelectTab("profiles_auto")
    end
end

function AutoProfilesUI:GetEditingInfo()
    if not self:IsEditing() then return nil end
    
    local profile = self.editingProfile
    local contentType = self.editingContentType
    
    -- Get content type display name
    local contentName = "Unknown"
    for _, ct in ipairs(CONTENT_TYPES) do
        if ct.key == contentType then
            contentName = ct.title
            break
        end
    end
    
    -- Get range display
    local rangeText
    if contentType == "mythic" then
        rangeText = "20 players (fixed)"
    else
        rangeText = profile.min .. "-" .. profile.max .. " players"
    end
    
    -- Count overrides
    local overrideCount = 0
    if profile.overrides then
        for _ in pairs(profile.overrides) do
            overrideCount = overrideCount + 1
        end
    end
    
    return {
        name = profile.name or "Unnamed",
        contentType = contentType,
        contentName = contentName,
        rangeText = rangeText,
        overrideCount = overrideCount,
    }
end

-- ============================================================
-- EDITING BANNER
-- ============================================================

local editingBanner = nil

function AutoProfilesUI:CreateEditingBanner(parent)
    if editingBanner then return editingBanner end
    
    local banner = CreateFrame("Frame", "DandersAutoProfilesEditingBanner", parent, "BackdropTemplate")
    banner:SetHeight(50)
    banner:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    banner:SetBackdropColor(0.15, 0.08, 0.03, 1)
    banner:SetBackdropBorderColor(1, 0.5, 0.2, 1)
    banner:SetFrameLevel(parent:GetFrameLevel() + 50)  -- Ensure banner is above page content
    banner:Hide()
    
    -- Settings icon
    local icon = banner:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("LEFT", 12, 0)
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\settings")
    icon:SetVertexColor(1, 0.5, 0.2)
    
    -- "Editing:" label
    local editLabel = banner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    editLabel:SetPoint("LEFT", icon, "RIGHT", 8, 6)
    editLabel:SetText("Editing:")
    editLabel:SetTextColor(0.7, 0.7, 0.7)
    
    -- Profile name and content type
    local profileText = banner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    profileText:SetPoint("LEFT", editLabel, "RIGHT", 6, 0)
    profileText:SetTextColor(1, 0.5, 0.2)
    banner.profileText = profileText
    
    -- Range info line
    local infoText = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    infoText:SetPoint("LEFT", icon, "RIGHT", 8, -10)
    infoText:SetTextColor(0.5, 0.5, 0.5)
    banner.infoText = infoText
    
    -- Exit Editing button
    local exitBtn = CreateFrame("Button", nil, banner, "BackdropTemplate")
    exitBtn:SetSize(90, 26)
    exitBtn:SetPoint("RIGHT", -12, 0)
    exitBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    exitBtn:SetBackdropColor(0.1, 0.1, 0.1, 1)
    exitBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    
    local exitText = exitBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    exitText:SetPoint("CENTER")
    exitText:SetText("Exit Editing")
    exitText:SetTextColor(0.8, 0.8, 0.8)
    
    exitBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(1, 0.5, 0.2, 1)
        exitText:SetTextColor(1, 0.5, 0.2)
    end)
    exitBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        exitText:SetTextColor(0.8, 0.8, 0.8)
    end)
    exitBtn:SetScript("OnClick", function()
        AutoProfilesUI:ExitEditing()
    end)
    
    editingBanner = banner
    return banner
end

function AutoProfilesUI:UpdateEditingBanner()
    if not editingBanner then return end
    
    local info = self:GetEditingInfo()
    if info then
        editingBanner.profileText:SetText(info.contentName .. " → \"" .. info.name .. "\"")
        editingBanner.infoText:SetText(info.rangeText .. " · Only changed settings will be saved")
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

-- ============================================================
-- OVERRIDE SYSTEM FUNCTIONS
-- ============================================================

-- Get a raid setting value, checking profile overrides first
-- Returns: value, isOverridden
function AutoProfilesUI:GetRaidSetting(key)
    local globalValue = DF.db.raid[key]
    
    -- If editing a profile, check that profile's overrides
    if self.editingProfile then
        local overrides = self.editingProfile.overrides
        if overrides and overrides[key] ~= nil then
            return overrides[key], true  -- value, isOverridden
        end
        return globalValue, false
    end
    
    -- If auto-profiles enabled and not editing, check active profile
    if DF.db.raidAutoProfiles and DF.db.raidAutoProfiles.enabled then
        local activeProfile = self:GetActiveProfile()
        if activeProfile and activeProfile.overrides and activeProfile.overrides[key] ~= nil then
            return activeProfile.overrides[key], true
        end
    end
    
    return globalValue, false
end

function AutoProfilesUI:SetProfileSetting(key, value)
    if not self.editingProfile then return false end
    
    -- Ensure overrides table exists
    if not self.editingProfile.overrides then
        self.editingProfile.overrides = {}
    end
    
    -- Get the true global from snapshot (db.raid has been modified by the control already)
    local globalValue, found = GetSnapshotValue(self.globalSnapshot, key)
    if not found then
        -- Key not in snapshot (shouldn't happen, but fall back to live db)
        globalValue = GetRaidValue(key)
    end
    
    -- Compare values (handle tables like colors)
    local valuesMatch = false
    if type(value) == "table" and type(globalValue) == "table" then
        -- Deep compare for color tables
        valuesMatch = true
        for k, v in pairs(globalValue) do
            if value[k] ~= v then
                valuesMatch = false
                break
            end
        end
        if valuesMatch then
            for k, v in pairs(value) do
                if globalValue[k] ~= v then
                    valuesMatch = false
                    break
                end
            end
        end
    else
        valuesMatch = (value == globalValue)
    end
    
    if valuesMatch then
        -- Same as global, remove override
        self.editingProfile.overrides[key] = nil
    else
        -- Different from global, store override
        -- Deep copy tables to avoid reference issues
        if type(value) == "table" then
            local copy = {}
            for k, v in pairs(value) do
                copy[k] = v
            end
            self.editingProfile.overrides[key] = copy
        else
            self.editingProfile.overrides[key] = value
        end
    end
    
    return true
end

-- Reset a setting to global (remove override)
function AutoProfilesUI:ResetProfileSetting(key)
    if not self.editingProfile then return false end
    
    if self.editingProfile.overrides then
        self.editingProfile.overrides[key] = nil
    end
    
    -- Restore the actual db value to the true global (from snapshot)
    local globalValue, found = GetSnapshotValue(self.globalSnapshot, key)
    if not found then
        globalValue = GetRaidValue(key)
    end
    
    -- Deep copy tables
    if type(globalValue) == "table" then
        local copy = {}
        for k, v in pairs(globalValue) do copy[k] = v end
        SetRaidValue(key, copy)
    else
        SetRaidValue(key, globalValue)
    end
    
    return true
end

-- Get the global value for a setting (for display purposes)
function AutoProfilesUI:GetGlobalValue(key)
    -- When editing, return the true global from snapshot (db.raid may have overridden values)
    local snapshotVal, found = GetSnapshotValue(self.globalSnapshot, key)
    if found then
        return snapshotVal
    end
    return GetRaidValue(key)
end

-- Check if a setting is currently overridden
function AutoProfilesUI:IsSettingOverridden(key)
    if not self.editingProfile or not self.editingProfile.overrides then
        return false
    end
    return self.editingProfile.overrides[key] ~= nil
end

-- Get active profile based on current content/raid size (for runtime, not editing)
function AutoProfilesUI:GetActiveProfile()
    local autoDb = DF.db.raidAutoProfiles
    if not autoDb or not autoDb.enabled then return nil end
    
    -- For now, return nil - full detection will be implemented in Phase 11
    -- This is just a stub for the override system
    return nil
end
