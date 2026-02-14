local addonName, DF = ...

-- ============================================================
-- PINNED FRAMES - Separate frame sets for selected players
-- Uses SecureGroupHeaderTemplate with nameList for explicit control
-- ============================================================

local PinnedFrames = {}
DF.PinnedFrames = PinnedFrames

-- Storage for headers and containers
PinnedFrames.containers = {}  -- [setIndex] = container frame
PinnedFrames.headers = {}     -- [setIndex] = SecureGroupHeaderTemplate
PinnedFrames.labels = {}      -- [setIndex] = label fontstring
PinnedFrames.initialized = false
PinnedFrames.currentMode = nil  -- Track what mode we initialized for

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

-- Get pinned frames config for actual current mode
local function GetPinnedDB()
    local db = IsInRaid() and DF:GetRaidDB() or DF:GetDB()
    return db and db.pinnedFrames
end

-- Get the current actual mode (not cached)
local function GetActualMode()
    return IsInRaid() and "raid" or "party"
end

-- Get a specific set's config
local function GetSetDB(setIndex)
    local hlDB = GetPinnedDB()
    return hlDB and hlDB.sets and hlDB.sets[setIndex]
end

-- Build nameList from player array
-- Uses full names (including realm for cross-realm players) to match WoW's nameList format
local function BuildNameList(players)
    if not players or #players == 0 then
        return ""
    end
    
    -- Just join the names with commas - don't strip realms
    return table.concat(players, ",")
end

-- Get current group roster as a lookup table
-- Returns both the roster lookup AND the actual names from GetRaidRosterInfo
local function GetGroupRoster()
    local roster = {}          -- shortName -> rosterName (for lookup)
    local rosterNames = {}     -- list of actual roster names (for nameList)
    local numMembers = GetNumGroupMembers()
    
    if numMembers == 0 then
        local name = UnitName("player")
        roster[name] = name
        table.insert(rosterNames, name)
        return roster, rosterNames
    end
    
    local isRaid = IsInRaid()
    
    if isRaid then
        -- Use GetRaidRosterInfo which returns exact name format for nameList
        for i = 1, numMembers do
            local name = GetRaidRosterInfo(i)
            if name then
                -- Store both the full name and short name for lookup
                roster[name] = name
                local shortName = name:match("([^%-]+)") or name
                if shortName ~= name then
                    roster[shortName] = name  -- Map short name to full roster name
                end
                table.insert(rosterNames, name)
            end
        end
    else
        -- Party mode
        local playerName = UnitName("player")
        roster[playerName] = playerName
        table.insert(rosterNames, playerName)
        
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name, realm = UnitName(unit)
                if name then
                    local fullName = name
                    if realm and realm ~= "" then
                        fullName = name .. "-" .. realm
                    end
                    roster[fullName] = fullName
                    roster[name] = fullName  -- Map short name too
                    table.insert(rosterNames, fullName)
                end
            end
        end
    end
    
    return roster, rosterNames
end

-- Check if player is in current group, returns the roster name if found
local function IsPlayerInGroup(fullName, roster)
    roster = roster or GetGroupRoster()
    
    -- First check if full name (with realm) is in roster
    if roster[fullName] then
        return roster[fullName]  -- Return the actual roster name
    end
    
    -- For same-realm players, also check short name
    local shortName = fullName:match("([^%-]+)") or fullName
    if roster[shortName] then
        return roster[shortName]  -- Return the actual roster name
    end
    
    return nil
end

-- ============================================================
-- AUTO-POPULATION
-- ============================================================

-- Auto-populate a single pinned set based on its settings
function PinnedFrames:AutoPopulateSet(set, roster)
    if not set then return false end
    
    local changed = false
    roster = roster or GetGroupRoster()
    
    -- Build lookup of current players in set
    local existingPlayers = {}
    for _, p in ipairs(set.players) do
        local name = p:match("([^%-]+)") or p
        existingPlayers[name] = true
    end
    
    -- Get group roster with role info
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then
        -- Solo mode
        if set.autoAddDPS then
            local name = UnitName("player")
            local realm = GetRealmName()
            local fullName = name .. "-" .. realm
            if not existingPlayers[name] then
                table.insert(set.players, fullName)
                changed = true
            end
        end
        return changed
    end
    
    local isRaid = IsInRaid()
    for i = 1, numMembers do
        local unit = isRaid and ("raid" .. i) or (i == 1 and "player" or "party" .. (i - 1))
        local name, realm = UnitName(unit)
        
        if name and not existingPlayers[name] then
            realm = realm or GetRealmName()
            local fullName = name .. "-" .. realm
            local role = UnitGroupRolesAssigned(unit)
            if role == "NONE" then role = "DAMAGER" end
            
            local shouldAdd = false
            if set.autoAddTanks and role == "TANK" then
                shouldAdd = true
            elseif set.autoAddHealers and role == "HEALER" then
                shouldAdd = true
            elseif set.autoAddDPS and role == "DAMAGER" then
                shouldAdd = true
            end
            
            if shouldAdd then
                table.insert(set.players, fullName)
                existingPlayers[name] = true
                changed = true
            end
        end
    end
    
    return changed
end

-- Clean up offline players from a set
function PinnedFrames:CleanOfflinePlayers(set, roster)
    if not set or set.keepOfflinePlayers then return false end
    
    roster = roster or GetGroupRoster()
    local changed = false
    
    for i = #set.players, 1, -1 do
        local fullName = set.players[i]
        if not IsPlayerInGroup(fullName, roster) then
            table.remove(set.players, i)
            changed = true
        end
    end
    
    return changed
end

-- Process all pinned sets for current mode
function PinnedFrames:ProcessAllSets()
    local hlDB = GetPinnedDB()
    if not hlDB or not hlDB.sets then return false end
    
    local roster = GetGroupRoster()
    local changed = false
    
    for i = 1, 2 do
        local set = hlDB.sets[i]
        if set then
            if self:AutoPopulateSet(set, roster) then
                changed = true
            end
            if self:CleanOfflinePlayers(set, roster) then
                changed = true
            end
        end
    end
    
    if changed then
        self:UpdateAllHeaders()
    end
    
    return changed
end

-- ============================================================
-- ANCHOR CALCULATION
-- ============================================================

-- Get the anchor point for the container based on growth settings
-- This determines which corner the header anchors to
local function GetContainerAnchorPoint(set)
    local horizontal = set.growDirection == "HORIZONTAL"
    local frameAnchor = set.frameAnchor or "START"
    local columnAnchor = set.columnAnchor or "START"
    
    if horizontal then
        -- Horizontal: frameAnchor controls left/right, columnAnchor controls top/bottom
        if frameAnchor == "END" then
            return (columnAnchor == "END") and "BOTTOMRIGHT" or "TOPRIGHT"
        else
            return (columnAnchor == "END") and "BOTTOMLEFT" or "TOPLEFT"
        end
    else
        -- Vertical: frameAnchor controls top/bottom, columnAnchor controls left/right
        if frameAnchor == "END" then
            return (columnAnchor == "END") and "BOTTOMRIGHT" or "BOTTOMLEFT"
        else
            return (columnAnchor == "END") and "TOPRIGHT" or "TOPLEFT"
        end
    end
end

-- ============================================================
-- FRAME CREATION
-- ============================================================

-- Create container and header for a pinned set
function PinnedFrames:CreateSetFrames(setIndex)
    if self.containers[setIndex] then return end
    
    -- CRITICAL: Cannot create frames during combat
    if InCombatLockdown() then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r CreateSetFrames: In combat, cannot create frames!")
        end
        return
    end
    
    local set = GetSetDB(setIndex)
    if not set then return end
    
    local modeSuffix = IsInRaid() and "Raid" or "Party"
    
    -- Create container (movable anchor frame)
    local container = CreateFrame("Frame", "DandersPinned" .. setIndex .. modeSuffix .. "Container", UIParent)
    container:SetSize(200, 100)  -- Will be resized based on content
    container:SetFrameStrata("MEDIUM")
    container:SetClampedToScreen(true)
    
    -- Position from saved settings
    local pos = set.position or { point = "CENTER", x = 0, y = 200 * (setIndex == 1 and 1 or -1) }
    container:ClearAllPoints()
    container:SetPoint(pos.point or "CENTER", UIParent, pos.point or "CENTER", pos.x or 0, pos.y or 0)
    
    -- Make draggable when unlocked
    container:SetMovable(true)
    container:EnableMouse(false)  -- Don't capture mouse on container - mover handles dragging
    
    -- Visual background when unlocked (for visibility)
    container.bg = container:CreateTexture(nil, "BACKGROUND")
    container.bg:SetAllPoints()
    container.bg:SetColorTexture(0.1, 0.1, 0.3, 0.3)
    container.bg:SetShown(not set.locked)
    
    -- Border when unlocked
    container.border = CreateFrame("Frame", nil, container, "BackdropTemplate")
    container.border:SetAllPoints()
    container.border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    container.border:SetBackdropBorderColor(0.4, 0.4, 0.8, 0.8)
    container.border:SetShown(not set.locked)
    
    -- Mover frame (parented to UIParent for scale independence)
    local mover = CreateFrame("Frame", "DandersPinned" .. setIndex .. "Mover", UIParent)
    mover:SetSize(80, 16)
    mover:SetFrameStrata("HIGH")
    mover:SetPoint("BOTTOM", container, "TOP", 0, 2)
    
    -- Mover background
    mover.bg = mover:CreateTexture(nil, "BACKGROUND")
    mover.bg:SetAllPoints()
    mover.bg:SetColorTexture(0.2, 0.2, 0.4, 0.9)
    
    -- Mover border (1px)
    mover.border = mover:CreateTexture(nil, "BORDER")
    mover.border:SetAllPoints()
    mover.border:SetColorTexture(0.5, 0.5, 0.9, 1.0)
    local moverInner = mover:CreateTexture(nil, "ARTWORK")
    moverInner:SetPoint("TOPLEFT", 1, -1)
    moverInner:SetPoint("BOTTOMRIGHT", -1, 1)
    moverInner:SetColorTexture(0.2, 0.2, 0.4, 0.9)
    
    -- Mover text
    mover.text = mover:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mover.text:SetPoint("CENTER")
    mover.text:SetText("Drag to Move")
    mover.text:SetTextColor(0.8, 0.8, 1.0)
    
    -- Mover is the drag handle
    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")
    
    -- Track starting mouse and container position
    local startMouseX, startMouseY, startPosX, startPosY
    
    mover:SetScript("OnDragStart", function(self)
        if set.locked then return end
        
        -- Get starting mouse position in screen coordinates
        local uiScale = UIParent:GetEffectiveScale()
        startMouseX, startMouseY = GetCursorPosition()
        startMouseX = startMouseX / uiScale
        startMouseY = startMouseY / uiScale
        
        -- Get current container position
        local pos = set.position or { x = 0, y = 0 }
        startPosX = pos.x or 0
        startPosY = pos.y or 0
        
        self:SetScript("OnUpdate", function()
            local mx, my = GetCursorPosition()
            mx = mx / uiScale
            my = my / uiScale
            
            -- Calculate delta from start
            local deltaX = mx - startMouseX
            local deltaY = my - startMouseY
            
            -- Apply delta to starting position
            local newX = startPosX + deltaX
            local newY = startPosY + deltaY
            
            -- Move container
            container:ClearAllPoints()
            container:SetPoint("CENTER", UIParent, "CENTER", newX, newY)
        end)
    end)
    
    mover:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        
        -- Get final position from mouse delta
        local uiScale = UIParent:GetEffectiveScale()
        local mx, my = GetCursorPosition()
        mx = mx / uiScale
        my = my / uiScale
        
        local deltaX = mx - startMouseX
        local deltaY = my - startMouseY
        
        local finalX = startPosX + deltaX
        local finalY = startPosY + deltaY
        
        -- Save position
        set.position = { point = "CENTER", x = finalX, y = finalY }
        
        -- Ensure container is at final position
        container:ClearAllPoints()
        container:SetPoint("CENTER", UIParent, "CENTER", finalX, finalY)
    end)
    
    -- Mover shows when unlocked AND enabled
    mover:SetShown(set.enabled and not set.locked)
    container.mover = mover
    
    -- Label (parented to UIParent for scale independence)
    local label = UIParent:CreateFontString("DandersPinned" .. setIndex .. "Label", "OVERLAY", "GameFontNormal")
    label:SetPoint("BOTTOM", container, "TOP", 0, 2)
    local labelText = set.name
    if not labelText or labelText == "" then
        labelText = "Pinned " .. setIndex
    end
    label:SetText(labelText)
    label:SetTextColor(0.8, 0.8, 1.0)
    -- Only show label if set is enabled AND showLabel is true
    label:SetShown(set.enabled and set.showLabel)
    
    self.containers[setIndex] = container
    self.labels[setIndex] = label
    
    -- Create SecureGroupHeaderTemplate
    local header = CreateFrame("Frame", "DandersPinned" .. setIndex .. modeSuffix .. "Header", container, "SecureGroupHeaderTemplate")
    
    -- Show all unit types - nameList controls which are visible
    header:SetAttribute("showPlayer", true)
    header:SetAttribute("showParty", true)
    header:SetAttribute("showRaid", true)
    header:SetAttribute("showSolo", true)
    
    -- Use same template as main frames
    header:SetAttribute("template", "DandersUnitButtonTemplate")
    
    -- Initial layout
    self:ApplyLayoutSettings(setIndex)
    
    -- Anchor header to container
    header:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    
    self.headers[setIndex] = header
    
    -- STARTINGINDEX TRICK - Force create frames upfront
    -- Must happen BEFORE setting nameList/sortMethod
    -- Use groupFilter temporarily to force frame creation
    header:SetAttribute("groupFilter", "1,2,3,4,5,6,7,8")  -- All groups
    header:SetAttribute("startingIndex", -39)  -- Creates up to 40 frames
    header:Show()
    header:SetAttribute("startingIndex", 1)    -- Reset to normal operation
    
    -- Now switch to nameList mode
    header:SetAttribute("sortMethod", "NAMELIST")
    header:SetAttribute("groupFilter", nil)  -- Clear groupFilter, nameList takes over
    
    -- Initial nameList (may be empty, that's ok now - frames are created)
    self:UpdateHeaderNameList(setIndex)
    
    if DF.debugPinnedFrames then
        -- Debug: count created children
        local count = 0
        for i = 1, 40 do
            if header:GetAttribute("child" .. i) then count = count + 1 end
        end
        print("|cFF00FFFF[DF Pinned]|r Set", setIndex, "created", count, "child frames")
    end
    
    -- Show/hide based on enabled state
    if set.enabled then
        container:Show()
        header:Show()
        -- Label and mover visibility based on their settings
        if label then
            label:SetShown(set.showLabel)
        end
        if container.mover then
            container.mover:SetShown(not set.locked)
        end
    else
        container:Hide()
        header:Hide()
        -- Hide label and mover when disabled
        if label then
            label:Hide()
        end
        if container.mover then
            container.mover:Hide()
        end
        -- Unregister events from child frames (synchronous - no delays for combat safety)
        if DF.SetHeaderChildrenEventsEnabled then
            DF:SetHeaderChildrenEventsEnabled(header, false)
        end
    end
end

-- ============================================================
-- HEADER UPDATES
-- ============================================================

-- Update the nameList for a header
function PinnedFrames:UpdateHeaderNameList(setIndex)
    local header = self.headers[setIndex]
    local set = GetSetDB(setIndex)
    
    if not header or not set then return end
    
    -- Get roster (maps stored names to actual GetRaidRosterInfo names)
    local roster = GetGroupRoster()
    local validRosterNames = {}
    
    -- For each player in set, find their actual roster name
    for _, storedName in ipairs(set.players) do
        local rosterName = IsPlayerInGroup(storedName, roster)
        if rosterName then
            -- Use the actual roster name (what GetRaidRosterInfo returns)
            table.insert(validRosterNames, rosterName)
        end
    end
    
    local nameList = BuildNameList(validRosterNames)
    
    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r Set", setIndex, "updating nameList")
        print("|cFF00FFFF[DF Pinned]|r   Players in set:", #set.players)
        print("|cFF00FFFF[DF Pinned]|r   Valid (in group):", #validRosterNames)
        print("|cFF00FFFF[DF Pinned]|r   nameList:", nameList ~= "" and nameList or "(empty)")
        for i, p in ipairs(set.players) do
            local rosterName = IsPlayerInGroup(p, roster)
            print("|cFF00FFFF[DF Pinned]|r     [" .. i .. "]", p, rosterName and ("-> " .. rosterName) or "(NOT in group)")
        end
    end
    
    -- Only update if not in combat
    if InCombatLockdown() then
        self.pendingNameListUpdate = self.pendingNameListUpdate or {}
        self.pendingNameListUpdate[setIndex] = true
        return
    end
    
    -- Clear ALL filtering/grouping attributes - nameList acts as the filter
    -- (Same approach as flat raid mode in Headers.lua)
    header:SetAttribute("groupBy", nil)
    header:SetAttribute("groupingOrder", nil)
    header:SetAttribute("groupFilter", nil)  -- MUST clear this for nameList to work!
    header:SetAttribute("roleFilter", nil)
    header:SetAttribute("strictFiltering", nil)
    
    -- Set nameList and sortMethod
    header:SetAttribute("nameList", nameList)
    header:SetAttribute("sortMethod", "NAMELIST")
    
    -- Force header to re-layout by toggling visibility
    if set.enabled then
        header:Hide()
        header:Show()
    end
    
    -- Resize container after layout change
    self:ResizeContainer(setIndex)
    
    -- Force visual refresh on all visible children after nameList change
    -- OnAttributeChanged handles unit reassignment, but a small delay ensures
    -- the header has finished re-laying out children before we refresh visuals
    C_Timer.After(0.1, function()
        if header and set.enabled then
            PinnedFrames:RefreshChildFrames(setIndex)
        end
    end)
end

-- Apply layout settings to a header
function PinnedFrames:ApplyLayoutSettings(setIndex)
    local header = self.headers[setIndex]
    local set = GetSetDB(setIndex)
    
    if not header or not set then return end
    if InCombatLockdown() then return end
    
    local db = IsInRaid() and DF:GetRaidDB() or DF:GetDB()
    if not db then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r ApplyLayoutSettings: db is nil!")
        end
        return
    end
    
    local frameWidth = db.frameWidth or 120
    local frameHeight = db.frameHeight or 50
    
    -- CRITICAL: Resize all child frames to match current raid/party settings
    -- This ensures frames use the correct size when switching between raid and party
    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child then
            child:SetSize(frameWidth, frameHeight)
            -- Also update the isRaidFrame flag for proper DB selection in other functions
            child.isRaidFrame = IsInRaid()
        end
    end
    
    local horizontal = set.growDirection == "HORIZONTAL"
    local hSpacing = set.horizontalSpacing or 2
    local vSpacing = set.verticalSpacing or 2
    local unitsPerRow = set.unitsPerRow or 5
    local columnAnchor = set.columnAnchor or "START"
    local frameAnchor = set.frameAnchor or "START"
    
    -- Frame anchor point determines where first frame is placed and growth direction
    -- HORIZONTAL: START=LEFT (grow right), END=RIGHT (grow left)
    -- VERTICAL: START=TOP (grow down), END=BOTTOM (grow up)
    local point, xOff, yOff
    if horizontal then
        if frameAnchor == "END" then
            point = "RIGHT"
            xOff = -hSpacing  -- Negative to grow left
        else
            point = "LEFT"
            xOff = hSpacing   -- Positive to grow right
        end
        yOff = 0
    else
        if frameAnchor == "END" then
            point = "BOTTOM"
            yOff = vSpacing   -- Positive to grow up
        else
            point = "TOP"
            yOff = -vSpacing  -- Negative to grow down
        end
        xOff = 0
    end
    
    header:SetAttribute("point", point)
    header:SetAttribute("xOffset", xOff)
    header:SetAttribute("yOffset", yOff)
    
    -- Column anchor point determines where new columns/rows appear
    -- HORIZONTAL: columns are vertical, START=TOP (down), END=BOTTOM (up)
    -- VERTICAL: columns are horizontal, START=LEFT (right), END=RIGHT (left)
    local colAnchorPoint, colSpacing
    if horizontal then
        colSpacing = vSpacing
        colAnchorPoint = (columnAnchor == "END") and "BOTTOM" or "TOP"
    else
        colSpacing = hSpacing
        colAnchorPoint = (columnAnchor == "END") and "RIGHT" or "LEFT"
    end
    header:SetAttribute("columnSpacing", colSpacing)
    header:SetAttribute("columnAnchorPoint", colAnchorPoint)
    
    header:SetAttribute("maxColumns", math.ceil(40 / unitsPerRow))
    header:SetAttribute("unitsPerColumn", unitsPerRow)
    
    -- Store frame dimensions for the template
    header:SetAttribute("frameWidth", frameWidth)
    header:SetAttribute("frameHeight", frameHeight)
    
    -- Get the anchor point based on growth settings
    local containerAnchorPoint = GetContainerAnchorPoint(set)
    
    -- Apply scale FIRST (before any position work)
    local container = self.containers[setIndex]
    if container then
        container:SetScale(set.scale or 1.0)
    end
    
    -- Anchor the header to the correct corner of container
    if container then
        header:ClearAllPoints()
        header:SetPoint(containerAnchorPoint, container, containerAnchorPoint, 0, 0)
        
        -- Restore saved position (always use CENTER anchor for container)
        local pos = set.position
        if pos then
            container:ClearAllPoints()
            container:SetPoint("CENTER", UIParent, "CENTER", pos.x or 0, pos.y or 0)
        end
    end
    
    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r ApplyLayoutSettings set", setIndex)
        print("|cFF00FFFF[DF Pinned]|r   horizontal:", horizontal)
        print("|cFF00FFFF[DF Pinned]|r   frameAnchor:", frameAnchor, "columnAnchor:", columnAnchor)
        print("|cFF00FFFF[DF Pinned]|r   containerAnchor:", containerAnchorPoint)
        print("|cFF00FFFF[DF Pinned]|r   frameSize:", frameWidth, "x", frameHeight)
        print("|cFF00FFFF[DF Pinned]|r   spacing:", hSpacing, vSpacing)
    end
    
    -- ============================================================
    -- CRITICAL: 4-step refresh to force repositioning
    -- Without this, changing layout settings won't reposition frames
    -- ============================================================
    if set.enabled and header:IsShown() then
        local currentNameList = header:GetAttribute("nameList")
        
        -- Step 1: Clear nameList to remove unit assignments
        header:SetAttribute("nameList", "")
        
        -- Step 2: Clear all child positions
        for i = 1, 40 do
            local child = header:GetAttribute("child" .. i)
            if child then
                child:ClearAllPoints()
            end
        end
        
        -- Step 3: Force header to process by hiding and showing
        header:Hide()
        header:Show()
        
        -- Step 4: Restore nameList - this reassigns units with new layout
        if currentNameList and currentNameList ~= "" then
            header:SetAttribute("nameList", currentNameList)
        end
    end
    
    -- Resize container after layout change
    self:ResizeContainer(setIndex)
end

-- Resize container to fit content
function PinnedFrames:ResizeContainer(setIndex)
    -- Can't resize secure frames during combat
    if InCombatLockdown() then return end
    
    local container = self.containers[setIndex]
    local header = self.headers[setIndex]
    local set = GetSetDB(setIndex)
    
    if not container or not header or not set then return end
    
    local db = IsInRaid() and DF:GetRaidDB() or DF:GetDB()
    local frameWidth = db.frameWidth or 120
    local frameHeight = db.frameHeight or 50
    
    -- Count visible children
    local visibleCount = 0
    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child and child:IsShown() then
            visibleCount = visibleCount + 1
        end
    end
    
    if visibleCount == 0 then
        container:SetSize(frameWidth, frameHeight)
        return
    end
    
    local horizontal = set.growDirection == "HORIZONTAL"
    local spacing = horizontal and (set.horizontalSpacing or 2) or (set.verticalSpacing or 2)
    local unitsPerRow = set.unitsPerRow or 5
    
    local rows = math.ceil(visibleCount / unitsPerRow)
    local cols = math.min(visibleCount, unitsPerRow)
    
    local width, height
    if horizontal then
        width = cols * frameWidth + (cols - 1) * spacing
        height = rows * frameHeight + (rows - 1) * (set.verticalSpacing or 2)
    else
        width = rows * frameWidth + (rows - 1) * (set.horizontalSpacing or 2)
        height = cols * frameHeight + (cols - 1) * spacing
    end
    
    container:SetSize(math.max(width, 50), math.max(height, 30))
end

-- Update all headers
function PinnedFrames:UpdateAllHeaders()
    for i = 1, 2 do
        self:UpdateHeaderNameList(i)
    end
end

-- ============================================================
-- ENABLE/DISABLE/LOCK
-- ============================================================

-- Iterate through header children and manage their events
local function SetChildFrameEvents(header, enabled)
    if DF.SetHeaderChildrenEventsEnabled then
        DF:SetHeaderChildrenEventsEnabled(header, enabled)
    end
end

-- Toggle enabled state for a set
-- Refresh all child frames for a set (called after enabling for combat reload support)
-- Uses FullFrameRefresh which uses Blizzard aura cache ONLY - no fallback
function PinnedFrames:RefreshChildFrames(setIndex)
    local header = self.headers[setIndex]
    if not header then return end
    
    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child and child.unit and child:IsVisible() then
            -- Full frame refresh (uses Blizzard aura cache only, no fallback)
            if DF.FullFrameRefresh then
                DF:FullFrameRefresh(child)
            end
        end
    end
    
    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r Set", setIndex, "refreshed all child frames")
    end
end

function PinnedFrames:SetEnabled(setIndex, enabled)
    local set = GetSetDB(setIndex)
    if not set then return end
    
    set.enabled = enabled
    
    local container = self.containers[setIndex]
    local header = self.headers[setIndex]
    
    if not container or not header then
        if enabled then
            self:CreateSetFrames(setIndex)
        end
        return
    end
    
    if InCombatLockdown() then
        self.pendingVisibilityUpdate = self.pendingVisibilityUpdate or {}
        self.pendingVisibilityUpdate[setIndex] = enabled
        return
    end
    
    -- Enable/disable events on child frames
    SetChildFrameEvents(header, enabled)
    
    -- Get label reference
    local label = self.labels[setIndex]
    
    if enabled then
        container:Show()
        header:Show()
        
        -- Update nameList first
        self:UpdateHeaderNameList(setIndex)
        
        -- Apply full layout refresh (4-step clear points method)
        -- This ensures frames are positioned correctly on enable
        self:ApplyLayoutSettings(setIndex)
        
        -- Update and show label if setting says so
        self:UpdateLabel(setIndex)
        if label then
            label:SetShown(set.showLabel)
        end
        
        -- Show mover if unlocked
        if container.mover and not set.locked then
            container.mover:SetShown(true)
        end
        
        -- CRITICAL: Force full refresh on all child frames
        -- This ensures auras, absorbs, etc. are updated on combat reload
        self:RefreshChildFrames(setIndex)
    else
        container:Hide()
        header:Hide()
        
        -- Hide label when disabled (must happen AFTER container hide)
        if label then
            label:Hide()
        end
        
        -- Hide mover when disabled
        if container.mover then
            container.mover:Hide()
        end
    end
end

-- Toggle locked state for a set
function PinnedFrames:SetLocked(setIndex, locked)
    local set = GetSetDB(setIndex)
    local container = self.containers[setIndex]
    
    if not set or not container then return end
    
    -- Unlocking requires frame manipulation that can taint in combat
    if not locked and InCombatLockdown() then
        self.pendingUnlock = self.pendingUnlock or {}
        self.pendingUnlock[setIndex] = true
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r Set", setIndex, "unlock queued until after combat")
        end
        return
    end
    
    set.locked = locked
    
    -- Container background/border visibility
    container.bg:SetShown(not locked)
    container.border:SetShown(not locked)
    
    -- Mover shows when unlocked (independent of label)
    if container.mover then
        container.mover:SetShown(not locked and set.enabled)
    end
end

-- Auto-lock all unlocked sets (called on combat start)
function PinnedFrames:LockAllForCombat()
    if not self.initialized then return end
    
    local hlDB = GetPinnedDB()
    if not hlDB or not hlDB.sets then return end
    
    for i = 1, 2 do
        local set = hlDB.sets[i]
        local container = self.containers[i]
        if set and container and not set.locked then
            -- Remember which sets were unlocked so we can restore after combat
            self.unlockedBeforeCombat = self.unlockedBeforeCombat or {}
            self.unlockedBeforeCombat[i] = true
            
            -- Lock visually (hide mover/bg/border) but don't save to DB
            container.bg:Hide()
            container.border:Hide()
            if container.mover then
                container.mover:Hide()
            end
            
            if DF.debugPinnedFrames then
                print("|cFF00FFFF[DF Pinned]|r Set", i, "auto-locked for combat")
            end
        end
    end
end

-- Restore unlock state after combat
function PinnedFrames:RestoreUnlockedAfterCombat()
    -- Restore sets that were unlocked before combat
    if self.unlockedBeforeCombat then
        for setIndex in pairs(self.unlockedBeforeCombat) do
            local set = GetSetDB(setIndex)
            local container = self.containers[setIndex]
            if set and container and not set.locked then
                container.bg:SetShown(true)
                container.border:SetShown(true)
                if container.mover then
                    container.mover:SetShown(set.enabled)
                end
            end
        end
        self.unlockedBeforeCombat = nil
    end
    
    -- Process any unlock requests that came in during combat
    if self.pendingUnlock then
        for setIndex in pairs(self.pendingUnlock) do
            self:SetLocked(setIndex, false)
        end
        self.pendingUnlock = nil
    end
end

-- Toggle label visibility
function PinnedFrames:SetShowLabel(setIndex, show)
    local set = GetSetDB(setIndex)
    local label = self.labels[setIndex]
    
    if not set or not label then return end
    
    set.showLabel = show
    label:SetShown(show)
end

-- Update label text
function PinnedFrames:UpdateLabel(setIndex)
    local set = GetSetDB(setIndex)
    local label = self.labels[setIndex]
    
    if not set or not label then return end
    
    local labelText = set.name
    if not labelText or labelText == "" then
        labelText = "Pinned " .. setIndex
    end
    label:SetText(labelText)
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

function PinnedFrames:Initialize()
    if self.initialized then return end
    
    -- CRITICAL: Cannot create frames during combat
    if InCombatLockdown() then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r Initialize: In combat, deferring...")
        end
        self.pendingInitialize = true
        return
    end
    
    -- Check if DB is ready - if not during ADDON_LOADED, defer to pending
    if not DF.db then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r Initialize: DF.db not ready, setting pendingInitialize")
        end
        self.pendingInitialize = true
        return
    end
    
    -- Track what mode we're initializing for
    self.currentMode = GetActualMode()
    
    -- Check if pinnedFrames config exists
    local hlDB = GetPinnedDB()
    if not hlDB then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r Initialize: No pinnedFrames config found!")
        end
        return
    end
    
    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r Initializing pinned frames...")
        print("|cFF00FFFF[DF Pinned]|r   Mode:", self.currentMode)
    end
    
    -- Create frames for both sets
    for i = 1, 2 do
        self:CreateSetFrames(i)
    end
    
    self.initialized = true
    
    -- Apply layout settings immediately (no delays for combat safety)
    -- Note: ApplyLayoutSettings is also called in CreateSetFrames, but we do it
    -- again here to ensure all settings are applied after headers are fully set up
    for i = 1, 2 do
        local header = self.headers[i]
        local set = GetSetDB(i)
        if header and set and set.enabled then
            self:ApplyLayoutSettings(i)
        end
    end
    
    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r Initialized pinned frames")
    end
end

-- Reinitialize for mode change (party <-> raid)
function PinnedFrames:Reinitialize()
    -- Cannot reinitialize during combat
    if InCombatLockdown() then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r Reinitialize: In combat, deferring...")
        end
        self.pendingReinitialize = true
        return
    end
    
    -- Clean up old frames
    for i = 1, 2 do
        if self.containers[i] then
            -- Also hide mover
            if self.containers[i].mover then
                self.containers[i].mover:Hide()
            end
            self.containers[i]:Hide()
            self.containers[i] = nil
        end
        if self.headers[i] then
            self.headers[i]:Hide()
            self.headers[i] = nil
        end
        if self.labels[i] then
            self.labels[i]:Hide()
        end
        self.labels[i] = nil
    end
    
    self.initialized = false
    self:Initialize()
end

-- Refresh all child frames (calls FullFrameRefresh on each)
function PinnedFrames:RefreshAllChildFrames()
    for setIndex = 1, 2 do
        local header = self.headers[setIndex]
        if header then
            for i = 1, 40 do
                local child = header:GetAttribute("child" .. i)
                if child and child:IsShown() and child.unit then
                    if DF.FullFrameRefresh then
                        DF:FullFrameRefresh(child)
                    end
                end
            end
        end
    end
end

-- ============================================================
-- EVENT HANDLING
-- All initialization must happen synchronously during ADDON_LOADED
-- No C_Timer.After delays - they can fire during combat lockdown
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("ROLE_CHANGED_INFORM")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

eventFrame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" then
        if arg1 == "DandersFrames" then
            -- Initialize immediately during ADDON_LOADED
            -- During /reload, this fires BEFORE combat lockdown is re-established
            -- so we can safely create frames here without deferring
            if DF.db then
                PinnedFrames:Initialize()
                
                -- Populate the nameList - always update headers on load
                if PinnedFrames.initialized then
                    PinnedFrames:ProcessAllSets()
                    PinnedFrames:UpdateAllHeaders()  -- Force update even if no changes
                    
                    -- Force visual refresh on all child frames immediately
                    PinnedFrames:RefreshAllChildFrames()
                end
            end
        end
        return
    end
    
    if not DF.db then return end
    
    if event == "PLAYER_REGEN_DISABLED" then
        -- Auto-lock all unlocked pinned sets on combat start
        if PinnedFrames.initialized then
            PinnedFrames:LockAllForCombat()
        end
        return
    end
    
    if event == "PLAYER_REGEN_ENABLED" then
        -- Restore unlock state for sets that were unlocked before combat
        if PinnedFrames.initialized then
            PinnedFrames:RestoreUnlockedAfterCombat()
        end
        
        -- Process pending reinitialization after combat
        if PinnedFrames.pendingReinitialize then
            PinnedFrames.pendingReinitialize = nil
            PinnedFrames:Reinitialize()
            PinnedFrames:ProcessAllSets()
            return  -- Reinitialize handles everything
        end
        
        -- Process pending initialization after combat
        if PinnedFrames.pendingInitialize then
            PinnedFrames.pendingInitialize = nil
            PinnedFrames:Initialize()
            PinnedFrames:ProcessAllSets()
        end
        
        -- Process pending updates after combat
        if PinnedFrames.pendingNameListUpdate then
            for setIndex, _ in pairs(PinnedFrames.pendingNameListUpdate) do
                PinnedFrames:UpdateHeaderNameList(setIndex)
            end
            PinnedFrames.pendingNameListUpdate = nil
        end
        
        if PinnedFrames.pendingVisibilityUpdate then
            for setIndex, enabled in pairs(PinnedFrames.pendingVisibilityUpdate) do
                PinnedFrames:SetEnabled(setIndex, enabled)
            end
            PinnedFrames.pendingVisibilityUpdate = nil
        end
        return
    end
    
    -- GROUP_ROSTER_UPDATE or ROLE_CHANGED_INFORM
    if PinnedFrames.initialized then
        -- Check if mode changed (party <-> raid)
        local actualMode = GetActualMode()
        if PinnedFrames.currentMode and actualMode ~= PinnedFrames.currentMode then
            if DF.debugPinnedFrames then
                print("|cFF00FFFF[DF Pinned]|r Mode changed from", PinnedFrames.currentMode, "to", actualMode, "- reinitializing")
            end
            PinnedFrames:Reinitialize()
            return
        end
        
        PinnedFrames:ProcessAllSets()
    end
end)

-- ============================================================
-- DEBUG
-- ============================================================

function PinnedFrames:DebugPrint()
    print("|cFF00FFFF[DF Pinned]|r === Debug Info ===")
    print("  Initialized:", tostring(self.initialized))
    print("  Current mode:", self.currentMode or "unknown")
    print("  Actual mode:", GetActualMode())
    print("  DF.db exists:", tostring(DF.db ~= nil))
    
    local hlDB = GetPinnedDB()
    print("  pinnedFrames DB exists:", tostring(hlDB ~= nil))
    
    -- Show current group roster
    local roster = GetGroupRoster()
    local rosterCount = 0
    for _ in pairs(roster) do rosterCount = rosterCount + 1 end
    print("  Group roster count:", rosterCount)
    for name, _ in pairs(roster) do
        print("    -", name)
    end
    
    for i = 1, 2 do
        local set = GetSetDB(i)
        print(" ")
        print("  === Set " .. i .. " ===")
        if set then
            print("    Enabled:", tostring(set.enabled))
            print("    Locked:", tostring(set.locked))
            print("    ShowLabel:", tostring(set.showLabel))
            print("    Name:", set.name or "(nil)")
            print("    Players in set:", #set.players)
            for j, p in ipairs(set.players) do
                local inGroup = IsPlayerInGroup(p, roster)
                print("      [" .. j .. "]", p, inGroup and "(IN GROUP)" or "(not in group)")
            end
            
            local container = self.containers[i]
            local header = self.headers[i]
            local label = self.labels[i]
            
            print("    Container exists:", tostring(container ~= nil))
            if container then
                print("      Shown:", tostring(container:IsShown()))
                print("      Size:", container:GetWidth(), "x", container:GetHeight())
            end
            
            print("    Header exists:", tostring(header ~= nil))
            if header then
                print("      Shown:", tostring(header:IsShown()))
                local nameListAttr = header:GetAttribute("nameList") or "(nil)"
                print("      nameList attr:", nameListAttr)
                print("      sortMethod:", header:GetAttribute("sortMethod") or "(nil)")
                print("      template:", header:GetAttribute("template") or "(nil)")
                
                -- Count children
                local childCount = 0
                local shownChildren = 0
                for j = 1, 40 do
                    local child = header:GetAttribute("child" .. j)
                    if child then
                        childCount = childCount + 1
                        if child:IsShown() then
                            shownChildren = shownChildren + 1
                        end
                    end
                end
                print("      Children (total):", childCount)
                print("      Children (shown):", shownChildren)
                
                -- List first few children
                for j = 1, math.min(5, childCount) do
                    local child = header:GetAttribute("child" .. j)
                    if child then
                        local unit = child:GetAttribute("unit") or "none"
                        print("        child" .. j .. ":", child:GetName() or "unnamed", "unit=" .. unit, child:IsShown() and "SHOWN" or "hidden")
                    end
                end
            end
            
            print("    Label exists:", tostring(label ~= nil))
            if label then
                print("      Shown:", tostring(label:IsShown()))
                print("      Text:", label:GetText() or "(nil)")
            end
        else
            print("    (set config is nil)")
        end
    end
end

-- Test function - adds player to set 1 and enables it
function PinnedFrames:Test()
    local set = GetSetDB(1)
    if not set then
        print("|cFF00FFFF[DF Pinned]|r Test: No set 1 config found!")
        return
    end
    
    local playerName = UnitName("player")
    local playerRealm = GetRealmName()
    local fullName = playerName .. "-" .. playerRealm
    
    -- Add player if not already in list
    local found = false
    for _, p in ipairs(set.players) do
        if p == fullName then
            found = true
            break
        end
    end
    
    if not found then
        table.insert(set.players, fullName)
        print("|cFF00FFFF[DF Pinned]|r Test: Added", fullName, "to set 1")
    else
        print("|cFF00FFFF[DF Pinned]|r Test:", fullName, "already in set 1")
    end
    
    -- Enable set 1
    set.enabled = true
    self:SetEnabled(1, true)
    
    -- Update nameList
    self:UpdateHeaderNameList(1)
    
    print("|cFF00FFFF[DF Pinned]|r Test: Set 1 enabled with player")
    print("|cFF00FFFF[DF Pinned]|r Run /dfpinned info to see details")
end

-- Slash command for debug
SLASH_DFPINNED1 = "/dfpinned"
SlashCmdList["DFPINNED"] = function(msg)
    if msg == "debug" then
        DF.debugPinnedFrames = not DF.debugPinnedFrames
        print("|cFF00FFFF[DF Pinned]|r Debug:", DF.debugPinnedFrames and "ON" or "OFF")
    elseif msg == "info" then
        PinnedFrames:DebugPrint()
    elseif msg == "reinit" then
        PinnedFrames:Reinitialize()
        print("|cFF00FFFF[DF Pinned]|r Reinitialized")
    elseif msg == "test" then
        PinnedFrames:Test()
    else
        print("|cFF00FFFF[DF Pinned]|r Commands:")
        print("  debug - Toggle debug output")
        print("  info - Show detailed debug info")  
        print("  test - Add player to set 1 and enable")
        print("  reinit - Reinitialize frames")
    end
end
