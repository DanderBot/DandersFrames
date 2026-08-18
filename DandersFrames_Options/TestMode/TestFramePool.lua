-- ============================================================
-- TestFramePool.lua
-- Creates separate non-secure frames for test mode preview
-- These frames are completely independent of live header children
-- ============================================================

-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames

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
    
    -- Binding tooltip on hover, PLUS the hover-state flag live sets.
    --
    -- ☠ HOVER HIGHLIGHT COULD NOT RENDER IN THE PREVIEW. Live's InitializeHeaderChild
    -- HOOKS OnEnter/OnLeave to set self.dfIsHovered and re-run DF:UpdateHighlights;
    -- this handler REPLACED that with a tooltip-only script. Highlights.lua gates the
    -- Hover Highlight on frame.dfIsHovered, and test frames DO run the live
    -- DF:UpdateHighlights (through UpdateAllTestHighlights) -- so the entire render
    -- path already existed and only the flag was missing. Nothing secure is involved:
    -- it is a Lua field and a Lua call. (Audit, 2026-08-07.)
    frame:SetScript("OnEnter", function(self)
        self.dfIsHovered = true
        if DF.UpdateHighlights then DF:UpdateHighlights(self) end
        if DF.ShowBindingTooltip then DF:ShowBindingTooltip(self) end
    end)
    frame:SetScript("OnLeave", function(self)
        self.dfIsHovered = false
        if DF.UpdateHighlights then DF:UpdateHighlights(self) end
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

-- ☠ DELEGATES TO THE LIVE POSITIONER -- do not re-derive the anchor here.
--
-- This used to anchor the test container at the raw raidAnchorX/Y, which is a SECOND
-- accounting model. DF:UpdateRaidContainerPosition already positions DF.testRaidContainer
-- itself, at the same cx/cy as the live container and the mover, and that cx/cy carries
-- ComputeRaidMainGroupAnchorOffset. Entering test mode ran THIS function instead, so
-- Center Mode = Fixed was ignored on entry and the preview sat where Default would put
-- it. The tell was that changing any setting -- toggling the dropdown to Default and back
-- -- appeared to "fix" it: those handlers call the live path, which corrected it.
--
-- Anything that shifts the container must therefore be added in UpdateRaidContainerPosition
-- and nowhere else, or the preview forks from live again.
function DF:PositionTestRaidContainer()
    if not DF.testRaidContainer then return end

    if DF.raidContainer and DF.UpdateRaidContainerPosition then
        DF:UpdateRaidContainerPosition()
        return
    end

    -- Fallback for the case the live call above would no-op on: no live container yet.
    -- Takes the shift from the SAME helper rather than restating the formula.
    local db = DF:GetRaidDB()
    local raidScale = db.frameScale or 1.0
    local ax, ay = 0, 0
    if DF.ComputeRaidMainGroupAnchorOffset then
        ax, ay = DF:ComputeRaidMainGroupAnchorOffset()
    end
    DF.testRaidContainer:SetScale(raidScale)
    DF.testRaidContainer:ClearAllPoints()
    DF.testRaidContainer:SetPoint("CENTER", UIParent, "CENTER",
        ((db.raidAnchorX or 0) + ax) / raidScale, ((db.raidAnchorY or 0) + ay) / raidScale)
end

-- ============================================================
-- ITERATOR HELPERS FOR TEST FRAMES
-- ============================================================
-- These mirror the live frame iterators but for test frames
