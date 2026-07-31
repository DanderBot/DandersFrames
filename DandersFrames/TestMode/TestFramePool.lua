-- ============================================================
-- TestFramePool.lua
-- Creates separate non-secure frames for test mode preview
-- These frames are completely independent of live header children
-- ============================================================

local _, DF = ...

-- Test frame storage
DF.testPartyFrames = {}  -- [0]=player, [1-4]=party
DF.testRaidFrames = {}   -- [1-40]=raid

-- Test containers
DF.testPartyContainer = nil
DF.testRaidContainer = nil

-- Flag to track initialization
DF.testFramePoolInitialized = false

-- ============================================================
-- CREATE TEST CONTAINERS
-- ============================================================
local function CreateTestContainers()
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    -- Party test container (non-secure)
    if not DF.testPartyContainer then
        local scale = db.frameScale or 1.0
        DF.testPartyContainer = CreateFrame("Frame", "DandersTestPartyContainer", UIParent)
        DF.testPartyContainer:SetScale(scale)
        DF.testPartyContainer:SetPoint("CENTER", UIParent, "CENTER", (db.anchorX or 0) / scale, (db.anchorY or 0) / scale)
        DF.testPartyContainer:SetSize(500, 200)
        DF.testPartyContainer:Hide()  -- Hidden by default
    end

    -- Raid test container (non-secure)
    if not DF.testRaidContainer then
        local raidScale = raidDb.frameScale or 1.0
        DF.testRaidContainer = CreateFrame("Frame", "DandersTestRaidContainer", UIParent)
        DF.testRaidContainer:SetScale(raidScale)
        DF.testRaidContainer:SetPoint("CENTER", UIParent, "CENTER", (raidDb.raidAnchorX or 0) / raidScale, (raidDb.raidAnchorY or 0) / raidScale)
        DF.testRaidContainer:SetSize(600, 400)
        DF.testRaidContainer:Hide()  -- Hidden by default
    end
end

-- ============================================================
-- CREATE SINGLE TEST FRAME
-- ============================================================
local function CreateTestFrame(index, isRaid)
    local db = isRaid and DF:GetRaidDB() or DF:GetDB()
    local parent = isRaid and DF.testRaidContainer or DF.testPartyContainer
    
    -- Generate frame name
    local frameName
    if isRaid then
        frameName = "DandersTestRaidFrame" .. index
    else
        frameName = "DandersTestPartyFrame" .. index
    end
    
    -- Create as regular Button (NOT SecureUnitButtonTemplate)
    -- This allows us to show/hide at any time without combat lockdown
    local frame = CreateFrame("Button", frameName, parent)
    frame:SetSize(db.frameWidth or 120, db.frameHeight or 50)
    
    -- Set up frame properties
    frame.index = index
    frame.isRaidFrame = isRaid
    frame.dfIsTestFrame = true  -- Mark as test frame
    frame.dfIsDandersFrame = true  -- For consistency with live frames
    
    -- Assign a fake unit for test purposes
    if isRaid then
        frame.unit = "raid" .. index
    else
        frame.unit = index == 0 and "player" or ("party" .. index)
    end
    
    -- Enable mouse for hover effects in test mode
    frame:EnableMouse(true)
    frame:RegisterForClicks("AnyUp")
    
    -- Use existing CreateFrameElements to create all visual elements
    -- This ensures test frames look identical to live frames
    if DF.CreateFrameElements then
        DF:CreateFrameElements(frame, isRaid)
    end
    
    -- CRITICAL: Apply frame style to set up fonts and other settings
    -- Without this, FontStrings won't have fonts set
    if DF.ApplyFrameStyle then
        DF:ApplyFrameStyle(frame)
    end
    
    -- Binding tooltip on hover
    frame:SetScript("OnEnter", function(self)
        if DF.ShowBindingTooltip then DF:ShowBindingTooltip(self) end
    end)
    frame:SetScript("OnLeave", function(self)
        if DFBindingTooltip then DFBindingTooltip:Hide(); DFBindingTooltip.anchorFrame = nil end
    end)

    -- Hide by default
    frame:Hide()

    return frame
end

-- ============================================================
-- CREATE TEST FRAME POOL
-- ============================================================
function DF:CreateTestFramePool()
    if DF.testFramePoolInitialized then return end
    
    -- Create containers first
    CreateTestContainers()
    
    -- Create party test frames (player + party1-4)
    for i = 0, 4 do
        DF.testPartyFrames[i] = CreateTestFrame(i, false)
    end
    
    -- Create raid test frames (1-40)
    for i = 1, 40 do
        DF.testRaidFrames[i] = CreateTestFrame(i, true)
    end
    
    DF.testFramePoolInitialized = true
    -- (Removed) a pool-created announcement gated on DF.debugMode. That flag went
    -- with the debug rework and is written nowhere, so the branch was unreachable.
    -- Not re-homed onto the console because TestMode has no trace category at all —
    -- see the coverage note in the commit; adding one is a change, not a cleanup.
end

-- ============================================================
-- POSITION TEST CONTAINERS
-- ============================================================
function DF:PositionTestPartyContainer()
    if not DF.testPartyContainer then return end

    local db = DF:GetDB()
    local scale = db.frameScale or 1.0
    DF.testPartyContainer:SetScale(scale)
    DF.testPartyContainer:ClearAllPoints()
    DF.testPartyContainer:SetPoint("CENTER", UIParent, "CENTER", (db.anchorX or 0) / scale, (db.anchorY or 0) / scale)
end

function DF:PositionTestRaidContainer()
    if not DF.testRaidContainer then return end

    local db = DF:GetRaidDB()
    local raidScale = db.frameScale or 1.0
    DF.testRaidContainer:SetScale(raidScale)
    DF.testRaidContainer:ClearAllPoints()
    DF.testRaidContainer:SetPoint("CENTER", UIParent, "CENTER", (db.raidAnchorX or 0) / raidScale, (db.raidAnchorY or 0) / raidScale)
end

-- ============================================================
-- ITERATOR HELPERS FOR TEST FRAMES
-- ============================================================
-- These mirror the live frame iterators but for test frames
