local addonName, DF = ...

-- ============================================================
-- BOSS DEBUFFS (PRIVATE AURAS) SUPPORT
-- Private Auras are boss debuffs that addons cannot see data for.
-- We can only provide "anchor" frames where Blizzard will render them.
-- ============================================================

-- Check if API exists
if not C_UnitAuras or not C_UnitAuras.AddPrivateAuraAnchor then
    return
end

-- Local references
local pairs, ipairs, pcall = pairs, ipairs, pcall
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local UnitExists = UnitExists

-- ============================================================
-- FILE SCOPE: Create overlay pool and register for click casting
-- These frames are created once at file load time.
-- They are registered with ClickCastFrames immediately.
-- SetupPrivateAuraAnchors will use frames from this pool.
-- ============================================================

-- ============================================================
-- CLICK-CASTING OVERLAY SYSTEM - DISABLED
-- ============================================================
-- What: Overlay buttons positioned over private aura (boss debuff) icons
-- Why we had it: Private auras are rendered by Blizzard directly, and addon
--                frames couldn't receive mouse clicks on them. We created
--                invisible SecureUnitButton overlays that sat on top of the
--                private aura icons to intercept clicks for click-casting.
-- Why it's disabled: Blizzard fixed this issue - private aura icons now
--                    properly propagate mouse events to the parent frame,
--                    so click-casting works natively without our overlays.
-- Date disabled: 2026-02-01
-- ============================================================


-- Store anchor IDs for cleanup
local frameAnchors = {}

-- Pending updates queue (for changes made during combat)
local pendingUpdates = {}

-- Track if we need to set up anchors after combat (from combat reload)
local needsPostCombatSetup = false

-- Helper to queue or execute updates
local function QueueOrExecute(updateType, func)
    if InCombatLockdown() then
        pendingUpdates[updateType] = func
        print("|cffff9900DandersFrames:|r Boss debuff changes queued until combat ends.")
    else
        func()
    end
end

-- Process pending updates after combat
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function()
    -- Handle pending updates
    if next(pendingUpdates) then
        for updateType, func in pairs(pendingUpdates) do
            func()
        end
        pendingUpdates = {}
    end
    
    -- Handle post-combat setup (from combat reload)
    if needsPostCombatSetup then
        needsPostCombatSetup = false
        print("|cff00ff00DandersFrames:|r Combat ended - setting up boss debuff anchors")
        DF:UpdateAllPrivateAuraAnchors()
    end
end)

-- ============================================================
-- FILE-SCOPE CONTAINER POOL
-- ============================================================
local containerPool = {}
local POOL_SIZE = 120  -- Enough for 60 frames * 2 icons each

for i = 1, POOL_SIZE do
    local container = CreateFrame("Frame", "DFBossDebuffContainer" .. i, UIParent)
    container:SetSize(30, 30)
    container:Hide()
    container:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    -- Propagate mouse events so boss debuff tooltips reach the unit frame
    if container.SetPropagateMouseMotion then container:SetPropagateMouseMotion(true) end
    if container.SetPropagateMouseClicks then container:SetPropagateMouseClicks(true) end

    -- Debug background
    container.debugBg = container:CreateTexture(nil, "BACKGROUND")
    container.debugBg:SetAllPoints()
    container.debugBg:SetColorTexture(1, 0, 0, 0.4)
    container.debugBg:Hide()

    container.poolIndex = i
    container.inUse = false
    containerPool[i] = container
end

-- Get a container from the pool
local function GetContainer()
    for i, container in ipairs(containerPool) do
        if not container.inUse then
            container.inUse = true
            return container
        end
    end
    return nil
end

-- Return a container to the pool
local function ReleaseContainer(container)
    if not container then return end
    if container.isBeingReleased then return end  -- Prevent recursion
    if InCombatLockdown() then return end  -- Protected operations
    container.isBeingReleased = true
    
    -- Note: Overlays are now per-frame (not per-container), released in ClearPrivateAuraAnchors
    
    container.inUse = false
    container:Hide()
    container:ClearAllPoints()
    container:SetParent(UIParent)
    container.unitFrame = nil
    container.auraIndex = nil
    container.isBeingReleased = nil
end

-- ============================================================
-- POSITIONING HELPERS
-- ============================================================

local function GetGrowthAnchors(growth)
    if growth == "RIGHT" then
        return "LEFT", "RIGHT", 1, 0
    elseif growth == "LEFT" then
        return "RIGHT", "LEFT", -1, 0
    elseif growth == "DOWN" then
        return "TOP", "BOTTOM", 0, -1
    elseif growth == "UP" then
        return "BOTTOM", "TOP", 0, 1
    end
    -- Default to RIGHT
    return "LEFT", "RIGHT", 1, 0
end

-- ============================================================
-- MAIN SETUP FUNCTION
-- ============================================================

function DF:SetupPrivateAuraAnchors(frame)
    if not frame or not frame.unit then return end
    
    -- PERF TEST: Skip if disabled
    if DF.PerfTest and not DF.PerfTest.enablePrivateAuras then return end
    
    -- Can't do protected operations during combat
    if InCombatLockdown() then
        return
    end
    
    local unit = frame.unit
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    
    -- Clear existing anchors first
    DF:ClearPrivateAuraAnchors(frame)
    
    if not db.bossDebuffsEnabled then
        return
    end
    
    -- Get settings
    local maxIcons = db.bossDebuffsMax or 2
    local spacing = db.bossDebuffsSpacing or 2
    local growth = db.bossDebuffsGrowth or "RIGHT"
    local anchor = db.bossDebuffsAnchor or "LEFT"
    local offsetX = db.bossDebuffsOffsetX or 0
    local offsetY = db.bossDebuffsOffsetY or 0
    local frameLevel = db.bossDebuffsFrameLevel or 50
    local showCountdown = db.bossDebuffsShowCountdown ~= false
    local showNumbers = db.bossDebuffsShowNumbers ~= false
    local iconWidth = db.bossDebuffsIconWidth or 30
    local iconHeight = db.bossDebuffsIconHeight or 30
    local borderScale = db.bossDebuffsBorderScale or 1.0
    local textScale = db.bossDebuffsTextScale or 1.0
    local textOffsetX = db.bossDebuffsTextOffsetX or 0
    local textOffsetY = db.bossDebuffsTextOffsetY or 0
    
    -- Get growth anchoring
    local pointOnCurrent, pointOnPrev, xMult, yMult = GetGrowthAnchors(growth)
    
    -- Initialize storage
    if not frame.bossDebuffContainers then
        frame.bossDebuffContainers = {}
    end
    if not frame.bossDebuffScaleFrames then
        frame.bossDebuffScaleFrames = {}
    end
    if not frame.bossDebuffIconParents then
        frame.bossDebuffIconParents = {}
    end
    frameAnchors[frame] = {}
    
    -- Base frame level
    local baseLevel = frame:GetFrameLevel()
    
    -- Track if any anchors succeeded (for overlay setup)
    local anyAnchorSucceeded = false
    
    -- Create containers and register with Blizzard API
    for i = 1, maxIcons do
        local container = GetContainer()
        if not container then break end
        
        -- Store reference
        frame.bossDebuffContainers[i] = container
        container.unitFrame = frame
        container.auraIndex = i
        
        -- Parent to contentOverlay or frame
        container:SetParent(frame.contentOverlay or frame)
        container:ClearAllPoints()
        container:SetFrameLevel(baseLevel + frameLevel)
        container:SetSize(iconWidth, iconHeight)
        
        if i == 1 then
            container:SetPoint(pointOnCurrent, frame, anchor, offsetX, offsetY)
        else
            local prevContainer = frame.bossDebuffContainers[i - 1]
            local spacingX = spacing * xMult
            local spacingY = spacing * yMult
            container:SetPoint(pointOnCurrent, prevContainer, pointOnPrev, spacingX, spacingY)
        end
        
        container:Show()
        
        -- Debug background
        if DF.bossDebuffDebug and container.debugBg then
            local colors = {
                {1, 0, 0, 0.4},
                {0, 1, 0, 0.4},
                {0, 0, 1, 0.4},
                {1, 1, 0, 0.4},
            }
            local c = colors[i] or colors[1]
            container.debugBg:SetColorTexture(c[1], c[2], c[3], c[4])
            container.debugBg:Show()
        else
            container.debugBg:Hide()
        end
        
        -- Always disable numbers on main anchor (we show them scaled via second anchor)
        local mainShowNumbers = false
        
        -- Create/reuse a tiny icon parent frame (hides Blizzard's default stack text)
        local iconParent = frame.bossDebuffIconParents[i]
        if not iconParent then
            iconParent = CreateFrame("Frame", nil, frame.contentOverlay or frame)
            frame.bossDebuffIconParents[i] = iconParent
        end
        iconParent:SetParent(frame.contentOverlay or frame)
        iconParent:SetSize(0.001, 0.001)
        iconParent:SetFrameLevel(baseLevel + frameLevel)
        iconParent:ClearAllPoints()
        iconParent:SetPoint("CENTER", container, "CENTER", 0, 0)
        -- Propagate mouse events to parent so boss debuff tooltips work
        -- (this is our frame, not the protected private aura icon)
        if iconParent.SetPropagateMouseMotion then iconParent:SetPropagateMouseMotion(true) end
        if iconParent.SetPropagateMouseClicks then iconParent:SetPropagateMouseClicks(true) end
        iconParent:Show()
        
        -- Register main anchor with Blizzard's system
        local success, anchorID = pcall(function()
            return C_UnitAuras.AddPrivateAuraAnchor({
                unitToken = unit,
                auraIndex = i,
                parent = iconParent,
                showCountdownFrame = showCountdown,
                showCountdownNumbers = mainShowNumbers,
                iconInfo = {
                    iconWidth = iconWidth,
                    iconHeight = iconHeight,
                    borderScale = borderScale,
                    iconAnchor = {
                        point = "CENTER",
                        relativeTo = container,
                        relativePoint = "CENTER",
                        offsetX = 0,
                        offsetY = 0,
                    },
                },
            })
        end)
        
        -- Debug output
        if DF.bossDebuffDebug then
            print("      [" .. i .. "] AddPrivateAuraAnchor unit=" .. unit .. " success=" .. tostring(success) .. " anchorID=" .. tostring(anchorID))
        end
        
        if success and anchorID then
            table.insert(frameAnchors[frame], anchorID)
            anyAnchorSucceeded = true
            
            -- Register second anchor for scaled duration numbers
            if showNumbers then
                -- Create/reuse a tiny scale parent frame
                local scaleFrame = frame.bossDebuffScaleFrames[i]
                if not scaleFrame then
                    scaleFrame = CreateFrame("Frame", nil, frame.contentOverlay or frame)
                    frame.bossDebuffScaleFrames[i] = scaleFrame
                end
                scaleFrame:SetSize(0.001, 0.001)
                scaleFrame:SetScale(textScale)
                scaleFrame:SetFrameStrata("DIALOG")
                scaleFrame:ClearAllPoints()
                scaleFrame:SetPoint("CENTER", container, "CENTER", 0, 0)
                if scaleFrame.SetPropagateMouseMotion then scaleFrame:SetPropagateMouseMotion(true) end
                if scaleFrame.SetPropagateMouseClicks then scaleFrame:SetPropagateMouseClicks(true) end
                scaleFrame:Show()
                
                -- Offsets go in the iconAnchor (what Blizzard uses to position content).
                -- Divide by textScale to compensate for the scaled parent frame.
                local anchorOffX = textOffsetX / textScale
                local anchorOffY = textOffsetY / textScale
                
                local scaleSuccess, scaleAnchorID = pcall(function()
                    return C_UnitAuras.AddPrivateAuraAnchor({
                        unitToken = unit,
                        auraIndex = i,
                        parent = scaleFrame,
                        showCountdownFrame = true,
                        showCountdownNumbers = true,
                        iconInfo = {
                            iconWidth = 0.001,
                            iconHeight = 0.001,
                            borderScale = -100,
                            iconAnchor = {
                                point = "CENTER",
                                relativeTo = container,
                                relativePoint = "CENTER",
                                offsetX = anchorOffX,
                                offsetY = anchorOffY,
                            },
                        },
                    })
                end)
                
                if scaleSuccess and scaleAnchorID then
                    table.insert(frameAnchors[frame], scaleAnchorID)
                    if DF.bossDebuffDebug then
                        print("      [" .. i .. "] Scale anchor added, scale=" .. textScale .. " anchorID=" .. tostring(scaleAnchorID))
                    end
                end
            end
        else
            -- API call failed - release container
            ReleaseContainer(container)
            frame.bossDebuffContainers[i] = nil
        end
    end
    
    -- Track which unit we're now monitoring (idempotency guard for ReanchorPrivateAuras)
    frame.bossDebuffAnchoredUnit = unit
    
end

function DF:ClearPrivateAuraAnchors(frame)
    if not frame then return end
    if frame.isBeingCleared then return end  -- Prevent recursion
    if InCombatLockdown() then return end  -- Can't do protected operations
    frame.isBeingCleared = true
    
    -- Remove Blizzard anchors
    local anchors = frameAnchors[frame]
    if anchors then
        for i, anchorID in ipairs(anchors) do
            pcall(function()
                C_UnitAuras.RemovePrivateAuraAnchor(anchorID)
            end)
        end
        frameAnchors[frame] = nil
    end
    
    
    -- Return containers to pool
    if frame.bossDebuffContainers then
        local containers = frame.bossDebuffContainers
        frame.bossDebuffContainers = {}  -- Clear reference first
        for i, container in ipairs(containers) do
            ReleaseContainer(container)
        end
    end
    
    -- Hide scale frames (reused on next setup)
    if frame.bossDebuffScaleFrames then
        for i, scaleFrame in ipairs(frame.bossDebuffScaleFrames) do
            scaleFrame:Hide()
            scaleFrame:ClearAllPoints()
        end
    end
    
    -- Hide icon parent frames (reused on next setup)
    if frame.bossDebuffIconParents then
        for i, iconParent in ipairs(frame.bossDebuffIconParents) do
            iconParent:Hide()
            iconParent:ClearAllPoints()
        end
    end
    
    -- Clear tracked unit so next ReanchorPrivateAuras will re-register
    frame.bossDebuffAnchoredUnit = nil
    
    frame.isBeingCleared = nil
end

-- ============================================================
-- LIGHTWEIGHT REANCHOR (unit token changed, containers stay)
-- ============================================================
-- When sorting moves a player to a different frame position, the
-- container is still visually attached to the correct frame, but
-- the Blizzard anchor is monitoring the OLD unit token.
-- This function removes old anchors and re-adds with the new unit
-- token, reusing existing containers (no layout/parenting changes).
--
-- SAFE TO CALL IN COMBAT: C_UnitAuras.AddPrivateAuraAnchor and
-- RemovePrivateAuraAnchor are NOT protected functions.
-- ============================================================

function DF:ReanchorPrivateAuras(frame)
    if not frame or not frame.unit then return end
    
    -- Nothing to reanchor if no containers exist
    if not frame.bossDebuffContainers or #frame.bossDebuffContainers == 0 then return end
    
    -- PERF TEST: Skip if disabled
    if DF.PerfTest and not DF.PerfTest.enablePrivateAuras then return end
    
    local newUnit = frame.unit
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    if not db or not db.bossDebuffsEnabled then return end
    
    -- Idempotency guard: skip if anchors already monitoring this unit (Grid2-style).
    -- Prevents redundant Remove+Add cycles during Hide/Show sorting churn.
    if frame.bossDebuffAnchoredUnit == newUnit then return end
    
    -- Step 1: Remove all old Blizzard anchors (API only, keep containers)
    local oldAnchors = frameAnchors[frame]
    if oldAnchors then
        for i, anchorID in ipairs(oldAnchors) do
            pcall(function()
                C_UnitAuras.RemovePrivateAuraAnchor(anchorID)
            end)
        end
    end
    frameAnchors[frame] = {}
    
    -- Step 2: Re-read settings for anchor params
    local showCountdown = db.bossDebuffsShowCountdown ~= false
    local showNumbers = db.bossDebuffsShowNumbers ~= false
    local iconWidth = db.bossDebuffsIconWidth or 30
    local iconHeight = db.bossDebuffsIconHeight or 30
    local borderScale = db.bossDebuffsBorderScale or 1.0
    local textScale = db.bossDebuffsTextScale or 1.0
    local textOffsetX = db.bossDebuffsTextOffsetX or 0
    local textOffsetY = db.bossDebuffsTextOffsetY or 0
    local mainShowNumbers = false
    
    -- Step 3: Re-register each container with new unit token
    for i, container in ipairs(frame.bossDebuffContainers) do
        -- Use the tiny icon parent (hides Blizzard's default stack text)
        local iconParent = frame.bossDebuffIconParents and frame.bossDebuffIconParents[i]
        local anchorParent = iconParent or container
        
        local success, anchorID = pcall(function()
            return C_UnitAuras.AddPrivateAuraAnchor({
                unitToken = newUnit,
                auraIndex = i,
                parent = anchorParent,
                showCountdownFrame = showCountdown,
                showCountdownNumbers = mainShowNumbers,
                iconInfo = {
                    iconWidth = iconWidth,
                    iconHeight = iconHeight,
                    borderScale = borderScale,
                    iconAnchor = {
                        point = "CENTER",
                        relativeTo = container,
                        relativePoint = "CENTER",
                        offsetX = 0,
                        offsetY = 0,
                    },
                },
            })
        end)
        
        if success and anchorID then
            table.insert(frameAnchors[frame], anchorID)
            
            -- Re-register scaled duration numbers anchor if enabled
            if showNumbers and frame.bossDebuffScaleFrames and frame.bossDebuffScaleFrames[i] then
                local scaleFrame = frame.bossDebuffScaleFrames[i]
                local anchorOffX = textOffsetX / textScale
                local anchorOffY = textOffsetY / textScale
                
                local scaleSuccess, scaleAnchorID = pcall(function()
                    return C_UnitAuras.AddPrivateAuraAnchor({
                        unitToken = newUnit,
                        auraIndex = i,
                        parent = scaleFrame,
                        showCountdownFrame = true,
                        showCountdownNumbers = true,
                        iconInfo = {
                            iconWidth = 0.001,
                            iconHeight = 0.001,
                            borderScale = -100,
                            iconAnchor = {
                                point = "CENTER",
                                relativeTo = container,
                                relativePoint = "CENTER",
                                offsetX = anchorOffX,
                                offsetY = anchorOffY,
                            },
                        },
                    })
                end)
                
                if scaleSuccess and scaleAnchorID then
                    table.insert(frameAnchors[frame], scaleAnchorID)
                end
            end
        end
    end
    
    -- Track which unit we're now monitoring (idempotency guard)
    frame.bossDebuffAnchoredUnit = newUnit
    
    if DF.bossDebuffDebug then
        print("|cff00ff00DF BossDebuff:|r Reanchored " .. #frame.bossDebuffContainers .. " containers to " .. newUnit .. " (" .. #frameAnchors[frame] .. " anchors)")
    end
end

-- ============================================================
-- DEBOUNCED REANCHOR ALL FRAMES (combat-safe)
-- ============================================================
-- Called after sorting completes to ensure all private aura anchors
-- are monitoring the correct unit token. Uses C_Timer.After(0) so
-- it runs on the NEXT frame, after all SecureGroupHeaderTemplate
-- attribute changes have settled. Multiple calls in the same frame
-- coalesce into a single reanchor pass via the pendingReanchor flag.
--
-- Fully combat-safe: ReanchorPrivateAuras only calls
-- C_UnitAuras.Add/RemovePrivateAuraAnchor (not protected).
-- ============================================================

local pendingReanchor = false

function DF:SchedulePrivateAuraReanchor()
    if pendingReanchor then return end
    pendingReanchor = true
    C_Timer.After(0, function()
        pendingReanchor = false
        if DF.IterateAllFrames then
            DF:IterateAllFrames(function(frame)
                if frame and frame.unit then
                    DF:ReanchorPrivateAuras(frame)
                end
            end)
        end
        -- Also cover pinned frames
        if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
            for setIndex = 1, 2 do
                local header = DF.PinnedFrames.headers[setIndex]
                if header then
                    for i = 1, 40 do
                        local child = header:GetAttribute("child" .. i)
                        if child and child.unit then
                            DF:ReanchorPrivateAuras(child)
                        end
                    end
                end
            end
        end
    end)
end

-- ============================================================
-- LIGHTWEIGHT UPDATE FUNCTIONS (no anchor recreation)
-- ============================================================

-- Update position/layout without recreating anchors
local function UpdateFramePositions(frame)
    if not frame or not frame.bossDebuffContainers or #frame.bossDebuffContainers == 0 then return end
    
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    local spacing = db.bossDebuffsSpacing or 2
    local growth = db.bossDebuffsGrowth or "RIGHT"
    local anchor = db.bossDebuffsAnchor or "LEFT"
    local offsetX = db.bossDebuffsOffsetX or 0
    local offsetY = db.bossDebuffsOffsetY or 0
    
    local pointOnCurrent, pointOnPrev, xMult, yMult = GetGrowthAnchors(growth)
    
    for i, container in ipairs(frame.bossDebuffContainers) do
        container:ClearAllPoints()
        if i == 1 then
            container:SetPoint(pointOnCurrent, frame, anchor, offsetX, offsetY)
        else
            local prevContainer = frame.bossDebuffContainers[i - 1]
            local spacingX = spacing * xMult
            local spacingY = spacing * yMult
            container:SetPoint(pointOnCurrent, prevContainer, pointOnPrev, spacingX, spacingY)
        end
    end
end

function DF:UpdateAllPrivateAuraPositions()
    QueueOrExecute("positions", function()
        local function update(frame)
            if frame and frame.bossDebuffContainers then
                UpdateFramePositions(frame)
            end
        end
        
        DF:IterateAllFrames(update)
    end)
end

-- Update scale without recreating anchors
-- Update frame level without recreating anchors
function DF:UpdateAllPrivateAuraFrameLevel()
    QueueOrExecute("frameLevel", function()
        local function update(frame)
            if not frame or not frame.bossDebuffContainers then return end
            local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
            local frameLevel = db.bossDebuffsFrameLevel or 50
            local baseLevel = frame:GetFrameLevel()
            for _, container in ipairs(frame.bossDebuffContainers) do
                container:SetFrameLevel(baseLevel + frameLevel)
            end
        end
        
        DF:IterateAllFrames(update)
    end)
end


-- Update visibility of all containers (for enable/disable toggle)
function DF:UpdateAllPrivateAuraVisibility()
    QueueOrExecute("visibility", function()
        local function update(frame)
            if not frame or not frame.bossDebuffContainers then return end
            local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
            local enabled = db.bossDebuffsEnabled
            for _, container in ipairs(frame.bossDebuffContainers) do
                if enabled then
                    container:Show()
                else
                    container:Hide()
                end
            end
        end
        
        DF:IterateAllFrames(update)
    end)
end

-- ============================================================
-- UPDATE ALL FRAMES
-- ============================================================

function DF:UpdateAllPrivateAuraAnchors()
    -- Can't do protected operations during combat
    if InCombatLockdown() then
        needsPostCombatSetup = true
        return
    end
    
    -- Only setup frames that don't already have anchors
    local function setupIfNeeded(frame)
        if frame and frame.unit then
            local anchors = frameAnchors[frame]
            -- Setup if no anchors table or it's empty
            if not anchors or #anchors == 0 then
                DF:SetupPrivateAuraAnchors(frame)
            end
        end
    end
    
    -- Party frames (player + party1-4) via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(setupIfNeeded)
    end
    
    -- Raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(setupIfNeeded)
    end
    
    -- Pinned frames
    if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
        for setIndex = 1, 2 do
            local header = DF.PinnedFrames.headers[setIndex]
            if header then
                for i = 1, 40 do
                    local child = header:GetAttribute("child" .. i)
                    if child then
                        setupIfNeeded(child)
                    end
                end
            end
        end
    end
end

-- ============================================================
-- REFRESH ALL FRAMES (Clear and recreate to reset children)
-- ============================================================

-- Debounce timer for refresh
local refreshTimer = nil

-- Preview function - updates only active frames immediately, then all frames after delay
-- This gives live feedback while dragging sliders without lag
function DF:PreviewPrivateAuraAnchors()
    -- Skip if in combat
    if InCombatLockdown() then
        -- Just queue a full refresh for after combat
        QueueOrExecute("refresh", function()
            DF:RefreshAllPrivateAuraAnchors()
        end)
        return
    end
    
    -- Immediately update first visible frame for preview
    local updatedFirst = false
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(function(frame)
            if not updatedFirst and frame and frame.unit and frame:IsVisible() then
                DF:ClearPrivateAuraAnchors(frame)
                DF:SetupPrivateAuraAnchors(frame)
                updatedFirst = true
            end
        end)
    end
    
    -- Schedule debounced full refresh for all other frames
    if refreshTimer then
        refreshTimer:Cancel()
    end
    refreshTimer = C_Timer.NewTimer(0.3, function()
        refreshTimer = nil
        -- Update remaining frames (skip ones we already updated)
        DF:RefreshRemainingPrivateAuraAnchors()
    end)
end

-- Refresh remaining frames (called after preview delay)
function DF:RefreshRemainingPrivateAuraAnchors()
    if InCombatLockdown() then
        QueueOrExecute("refreshRemaining", function()
            DF:RefreshRemainingPrivateAuraAnchors()
        end)
        return
    end
    
    -- Party frames (skip first visible one, already updated in preview)
    local skippedFirst = false
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(function(frame)
            if frame and frame.unit then
                if not skippedFirst and frame:IsVisible() then
                    skippedFirst = true  -- Skip the one we updated in preview
                else
                    DF:ClearPrivateAuraAnchors(frame)
                    DF:SetupPrivateAuraAnchors(frame)
                end
            end
        end)
    end
    
    -- Raid frames
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(frame)
            if frame and frame.unit then
                DF:ClearPrivateAuraAnchors(frame)
                DF:SetupPrivateAuraAnchors(frame)
            end
        end)
    end
end

-- Debounced refresh - waits for slider to stop moving
function DF:RefreshAllPrivateAuraAnchorsDebounced()
    if refreshTimer then
        refreshTimer:Cancel()
    end
    refreshTimer = C_Timer.NewTimer(0.3, function()
        refreshTimer = nil
        if InCombatLockdown() then
            needsPostCombatSetup = true
            return
        end
        DF:RefreshAllPrivateAuraAnchors()
    end)
end

function DF:RefreshAllPrivateAuraAnchors()
    QueueOrExecute("refresh", function()
        -- Party frames via iterator
        if DF.IteratePartyFrames then
            DF:IteratePartyFrames(function(frame)
                if frame and frame.unit then
                    DF:ClearPrivateAuraAnchors(frame)
                    DF:SetupPrivateAuraAnchors(frame)
                end
            end)
        end
        
        -- Raid frames via iterator
        if DF.IterateRaidFrames then
            DF:IterateRaidFrames(function(frame)
                if frame and frame.unit then
                    DF:ClearPrivateAuraAnchors(frame)
                    DF:SetupPrivateAuraAnchors(frame)
                end
            end)
        end
        
        -- Pinned frames
        if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
            for setIndex = 1, 2 do
                local header = DF.PinnedFrames.headers[setIndex]
                if header then
                    for i = 1, 40 do
                        local child = header:GetAttribute("child" .. i)
                        if child and child.unit then
                            DF:ClearPrivateAuraAnchors(child)
                            DF:SetupPrivateAuraAnchors(child)
                        end
                    end
                end
            end
        end
    end)
end

-- ============================================================
-- EVENT HANDLING
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "DandersFrames" then
        
        -- Set up anchors immediately if not in combat
        if not InCombatLockdown() then
            DF:UpdateAllPrivateAuraAnchors()
        else
            needsPostCombatSetup = true
        end
        
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Just update anchors if not in combat (frames may have changed)
        if not InCombatLockdown() then
            DF:UpdateAllPrivateAuraAnchors()
        else
            needsPostCombatSetup = true
        end
        
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Roster changed - new frames may need containers, or units may have shifted.
        -- Out of combat: set up containers for any frames that don't have them yet.
        -- In combat: schedule a reanchor for existing containers (combat-safe).
        if not InCombatLockdown() then
            -- Delay slightly to let header children get their unit assignments first
            C_Timer.After(0.1, function()
                if not InCombatLockdown() then
                    DF:UpdateAllPrivateAuraAnchors()
                end
            end)
        else
            -- Combat-safe: reanchor existing containers to potentially new unit tokens
            DF:SchedulePrivateAuraReanchor()
        end
    end
end)

-- ============================================================
-- DEBUG COMMANDS
-- ============================================================

SLASH_DFBOSSDEBUFFS1 = "/dfboss"
SlashCmdList["DFBOSSDEBUFFS"] = function(msg)
    msg = msg:lower():trim()
    
    if msg == "refresh" or msg == "update" then
        DF:RefreshAllPrivateAuraAnchors()
        print("|cff00ff00DandersFrames:|r Boss debuff anchors refreshed (cleared and recreated)")
        
    elseif msg == "debug" then
        DF.bossDebuffDebug = not DF.bossDebuffDebug
        local show = DF.bossDebuffDebug
        
        local function toggleDebug(frame)
            if frame and frame.bossDebuffContainers then
                local colors = {
                    {1, 0, 0, 0.4},
                    {0, 1, 0, 0.4},
                    {0, 0, 1, 0.4},
                    {1, 1, 0, 0.4},
                }
                for i, container in ipairs(frame.bossDebuffContainers) do
                    if container.debugBg then
                        if show then
                            local c = colors[i] or colors[1]
                            container.debugBg:SetColorTexture(c[1], c[2], c[3], c[4])
                            container.debugBg:Show()
                        else
                            container.debugBg:Hide()
                        end
                    end
                end
            end
        end
        
        -- Toggle on all frames
        DF:IterateAllFrames(toggleDebug)
        
        print("|cff00ff00DandersFrames:|r Debug mode " .. (show and "ON" or "OFF"))
    
        
    elseif msg == "status" then
        local count = 0
        for _, container in ipairs(containerPool) do
            if container.inUse then count = count + 1 end
        end
        print("|cff00ff00DandersFrames:|r Containers in use: " .. count .. "/" .. POOL_SIZE)
        
        -- Count anchors
        local anchorCount = 0
        for frame, anchors in pairs(frameAnchors) do
            anchorCount = anchorCount + #anchors
        end
        print("|cff00ff00DandersFrames:|r Total anchors registered: " .. anchorCount)
        
        -- Show db settings
        local db = DF:GetDB()
        print("|cff00ff00DandersFrames:|r Settings:")
        print("  bossDebuffsEnabled: " .. tostring(db.bossDebuffsEnabled))
        print("  bossDebuffsClickCastingEnabled: " .. tostring(db.bossDebuffsClickCastingEnabled))
        print("  bossDebuffsShowDebugOverlay: " .. tostring(db.bossDebuffsShowDebugOverlay))
        print("  bossDebuffsMax: " .. tostring(db.bossDebuffsMax))
        
    elseif msg == "frames" then
        -- Debug: show what frames we can find
        print("|cff00ff00DandersFrames:|r Frame Debug:")
        
        -- Count party frames
        local partyCount = 0
        if DF.IteratePartyFrames then
            DF:IteratePartyFrames(function(frame)
                partyCount = partyCount + 1
                print("  Party[" .. partyCount .. "] " .. tostring(frame:GetName()) .. " unit=" .. tostring(frame.unit))
            end)
        end
        print("  Party frames total: " .. partyCount)
        
        -- Count raid frames
        local raidCount = 0
        if DF.IterateRaidFrames then
            DF:IterateRaidFrames(function(frame)
                raidCount = raidCount + 1
            end)
        end
        print("  Raid frames total: " .. raidCount)
        
    elseif msg == "force" then
        -- Force setup on all frames regardless of settings
        print("|cff00ff00DandersFrames:|r Force setting up anchors...")
        DF.bossDebuffDebug = true
        
        local function forceSetup(frame, name)
            if frame and frame.unit then
                print("  Setting up: " .. name .. " unit=" .. frame.unit)
                
                -- Clear existing first
                DF:ClearPrivateAuraAnchors(frame)
                
                -- Force setup bypassing enabled check
                local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
                print("    DB bossDebuffsEnabled: " .. tostring(db.bossDebuffsEnabled))
                
                -- Temporarily force enable
                local wasEnabled = db.bossDebuffsEnabled
                db.bossDebuffsEnabled = true
                
                DF:SetupPrivateAuraAnchors(frame)
                
                -- Restore setting
                db.bossDebuffsEnabled = wasEnabled
                
                if frame.bossDebuffContainers then
                    print("    Containers created: " .. #frame.bossDebuffContainers)
                    for i, c in ipairs(frame.bossDebuffContainers) do
                        print("      [" .. i .. "] shown=" .. tostring(c:IsShown()) .. " parent=" .. tostring(c:GetParent() and c:GetParent():GetName()))
                        if c.debugBg then c.debugBg:Show() end
                    end
                else
                    print("    No containers created!")
                end
            end
        end
        
        -- Force setup on all frames via iterators
        local idx = 0
        DF:IteratePartyFrames(function(frame)
            idx = idx + 1
            forceSetup(frame, "partyFrame["..idx.."]")
        end)
        
        idx = 0
        DF:IterateRaidFrames(function(frame)
            idx = idx + 1
            forceSetup(frame, "raidFrame["..idx.."]")
        end)
        print("|cff00ff00DandersFrames:|r Done!")
        
    else
        print("|cff00ff00DandersFrames Boss Debuffs:|r")
        print("  /dfboss refresh - Refresh anchors")
        print("  /dfboss debug - Toggle debug backgrounds (red/green)")
        -- print("  /dfboss overlay - Toggle overlay debug (cyan)")  -- DISABLED: Overlay no longer needed
        print("  /dfboss status - Show pool status")
        print("  /dfboss frames - Show all frame references")
        print("  /dfboss force - Force setup on all frames with debug")
    end
end
