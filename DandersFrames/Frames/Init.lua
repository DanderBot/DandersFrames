local addonName, DF = ...

-- Header tracing -> debug console HEADERS category (see Frames/Headers.lua).
local headerDebug = DF:MakeDebugPrinter("HEADERS")

-- ============================================================
-- FRAMES INIT MODULE
-- Contains frame initialization and raid frame setup
-- ============================================================

-- Local caching of frequently used globals for performance
local pairs, ipairs, type, wipe = pairs, ipairs, type, wipe
local ceil, max = math.ceil, math.max
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local IsInRaid = IsInRaid
local GetRaidRosterInfo = GetRaidRosterInfo
local UnitExists = UnitExists
local L = DF.L

-- PERFORMANCE FIX: Reusable tables for layout calculations (avoid GC during roster updates)
local reusableGroupPlayerCounts = {}
local reusableActiveGroups = {}
local reusableActiveGroupList = {}
local reusableFrameToGroup = {}
-- Optional: nil means the raid unlock/lock paths below behave exactly as they always have.
local Mover = LibStub and LibStub("DandersMover-1.0", true)

local reusableGroupCurrentPos = {}

-- ============================================================
-- RAID RECT SIGNAL
-- Intentionally empty: the legacy raid mover this used to resize is gone, but
-- MoverBridge hooksecurefuncs this name as its "raid rect changed" trigger
-- (relayout, flat-grid resize, test-container sync all still call it). Keep the
-- name and the call sites; the hook is the body now.
-- ============================================================

function DF:SyncRaidMoverToContainer()
end

-- ============================================================
-- INITIALIZATION & LAYOUT
-- ============================================================

function DF:InitializeFrames()
    if DF.container then return end
    
    -- ============================================================
    -- NOTE: This function is now called at ADDON_LOADED where
    -- InCombatLockdown() is ALWAYS false, even during a combat reload.
    -- This is critical for combat reload support - frames MUST be
    -- created during this window.
    -- ============================================================
    
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    -- Reset lock states on reload (frames should always start locked)
    db.locked = true
    raidDb.raidLocked = true
    DF.testMode = false
    DF.raidTestMode = false
    
    -- ============================================================
    -- HEADER MODE (always enabled)
    -- Legacy frame creation has been removed
    -- All frames are now managed by SecureGroupHeaderTemplate in Headers.lua
    -- ============================================================
    headerDebug("Header mode - creating container and mover only")
    
    -- Create container (needed for headers and movers)
    DF.container = CreateFrame("Frame", "DandersFramesContainer", UIParent)
    local partyScale = db.frameScale or 1.0
    DF.container:SetScale(partyScale)
    DF.container:SetPoint("CENTER", UIParent, "CENTER", (db.anchorX or 0) / partyScale, (db.anchorY or 0) / partyScale)
    DF.container:SetSize(500, 200)

    -- Create permanent mover handle for party (skip if party mode disabled)
    if DF.db and DF.db.partyEnabled ~= false then
        DF:CreatePermanentMover(DF.container, "party")
    end

    -- Initialize raid container (needed by Headers.lua)
    DF:InitializeRaidFrames()
end

-- ============================================================
-- RAID FRAMES INITIALIZATION
-- ============================================================

function DF:InitializeRaidFrames()
    if DF.raidContainer then return end
    
    -- ============================================================
    -- NOTE: This function is called at ADDON_LOADED where
    -- InCombatLockdown() is ALWAYS false, even during a combat reload.
    -- We create the container here; raid frames are created by
    -- SecureGroupHeaderTemplate in Headers.lua
    -- ============================================================
    
    local db = DF:GetRaidDB()
    
    -- Create raid container
    -- NOTE: Using SecureFrameTemplate so secure code can SetPoint relative to this frame
    DF.raidContainer = CreateFrame("Frame", "DandersRaidFramesContainer", UIParent, "SecureFrameTemplate")
    local raidScale = db.frameScale or 1.0
    DF.raidContainer:SetScale(raidScale)
    DF.raidContainer:SetPoint("CENTER", UIParent, "CENTER", (db.raidAnchorX or 0) / raidScale, (db.raidAnchorY or 0) / raidScale)
    DF.raidContainer:SetSize(400, 300)
    DF.raidContainer:SetMovable(true)
    DF.raidContainer:Hide()  -- Hidden by default, shown when in raid
    
    -- Raid frames are children of SecureGroupHeaderTemplate headers
    -- Access via DF:GetRaidFrame(index) or DF:IterateRaidFrames(callback)
    
    -- Create permanent mover handle for raid (skip if raid mode disabled)
    if DF.db and DF.db.raidEnabled ~= false then
        DF:CreatePermanentMover(DF.raidContainer, "raid")
    end
end


function DF:UpdateRaidLayout()
    local db = DF:GetRaidDB()
    
    if not DF.raidContainer then return end
    
    -- Protect against calling during combat (secure frame operations would fail)
    if InCombatLockdown() then
        -- For flat layouts, use the specific flat layout refresh flag
        -- which is handled properly in Headers.lua's combat handler
        if not db.raidUseGroups then
            DF.pendingFlatLayoutRefresh = true
        else
            DF.needsUpdate = true
        end
        return
    end
    
    -- Check if using flat grid layout instead of group-based
    if not db.raidUseGroups then
        return DF:UpdateRaidFlatLayout()
    end
    
    -- Use group-based layout
    return DF:UpdateRaidGroupedLayout()
end

-- Effective raid group display order: db.raidGroupDisplayOrder, with the
-- player's group moved first when "My Group First" is on. Mirrors the builder in
-- Headers.lua's UpdateRaidGroupOrderAttributes (which orders the group headers
-- via secure attributes) so the unit-frame positioner agrees with the headers.
function DF:GetEffectiveRaidGroupOrder(db)
    db = db or DF:GetRaidDB()
    -- ☠ VALIDATE EVERY ENTRY, not just the count. Headers.lua carried a second copy of
    -- this builder that did the full check; the two were merged here, and the length-only
    -- test was the weaker of the pair. A table of the right length holding a duplicate,
    -- a nil, an out-of-range number or a non-number produces a rank map with holes, and
    -- every consumer then silently falls back to raw group number for the affected group.
    local displayOrder = db and db.raidGroupDisplayOrder
    local isValid = type(displayOrder) == "table"
    if isValid then
        local seen = {}
        for i = 1, 8 do
            local v = displayOrder[i]
            if type(v) ~= "number" or v < 1 or v > 8 or seen[v] then
                isValid = false
                break
            end
            seen[v] = true
        end
    end
    if not isValid then
        if DF.DebugWarn then
            DF:DebugWarn("ROSTER", "GetEffectiveRaidGroupOrder: raidGroupDisplayOrder is invalid or missing, using default order")
        end
        displayOrder = {1, 2, 3, 4, 5, 6, 7, 8}
    end
    local effectiveOrder = {}
    if db and db.raidPlayerGroupFirst and DF.cachedPlayerGroup then
        effectiveOrder[1] = DF.cachedPlayerGroup
        for _, g in ipairs(displayOrder) do
            if g ~= DF.cachedPlayerGroup then effectiveOrder[#effectiveOrder + 1] = g end
        end
    else
        for _, g in ipairs(displayOrder) do effectiveOrder[#effectiveOrder + 1] = g end
    end
    return effectiveOrder
end

-- Sort a list of active group numbers in place by effective display order, so
-- the group-slot positioner (which derives a group's slot from its index within
-- this list) honours Group Display Order / My Group First. Falls back to raw
-- group number for any group not present in the effective order.
function DF:SortActiveGroupListByDisplayOrder(activeGroupList, db)
    local effectiveOrder = DF:GetEffectiveRaidGroupOrder(db)
    local rank = {}
    for pos, g in ipairs(effectiveOrder) do rank[g] = pos end
    table.sort(activeGroupList, function(a, b)
        return (rank[a] or a) < (rank[b] or b)
    end)
end

-- Group-based raid layout positioning
function DF:UpdateRaidGroupedLayout()
    local db = DF:GetRaidDB()
    if not DF.raidContainer then return end
    
    -- CRITICAL: Hide FlatRaidFrames when using grouped layout
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        DF.FlatRaidFrames:SetEnabled(false)
    end
    
    -- Check if we have raid headers or legacy frames
    local hasHeaders = DF.raidSeparatedHeaders or (DF.FlatRaidFrames and DF.FlatRaidFrames.header)
    local hasLegacy = DF.raidFrames and DF.raidFrames[1]
    
    if not hasHeaders and not hasLegacy then return end
    
    -- Use SecureSort's group positioning functions
    local SecureSort = DF.SecureSort
    if not SecureSort then
        return DF:UpdateRaidFlatLayout()
    end
    
    -- NEW HEADER MODE: Headers handle their own positioning via secure templates
    -- We only need to:
    -- 1. Position the group headers relative to each other
    -- 2. Update the raid container size
    -- 3. Update group labels
    if hasHeaders and not hasLegacy then
        -- Update visibility and positioning via headers
        DF:UpdateRaidHeaderVisibility()
        DF:PositionRaidHeaders()
        DF:UpdateRaidGroupLabels()
        return
    end
    
    -- ☠ A ~60-line "LEGACY MODE" block sat here, gated on
    -- `SecureSort.raidFramesRegistered`. That flag is never set -- it is written only
    -- by SecureSort:RegisterRaidFrames, which runs only after SecureSort:Initialize,
    -- which has no reachable caller. The block counted active groups, sized the
    -- container and handed positioning to a secure sort that was never armed.
    --
    -- Everything it did is done by the live path below and by PositionRaidHeaders.
    -- Note the container sizing and group ordering it performed are NOT lost: the
    -- surviving path calls the same CalculateRaidGroupContainerSize and
    -- SortActiveGroupListByDisplayOrder a few lines down.

    -- DOOR-SHUT (live frames are never Lua-driven): in header mode the live unit
    -- frames are children of the secure group headers and are positioned ONLY by
    -- the secure header path. DF.raidFrames is a PROXY that resolves to those live
    -- children (Frames/Core.lua), so the legacy Lua per-frame fallback below would
    -- SetPoint them onto the container and fight the secure layout -- that is how
    -- entering test mode or a GUI change could shove the LIVE frames around (e.g.
    -- the group-order inversion). Route header mode to the secure path here; the Lua
    -- fallback now only runs for genuinely headerless legacy frames (none in current
    -- builds). TEST frames are positioned separately in TestMode.lua
    -- (DF.testRaidFrames / DF.testRaidContainer) and never reach this live path.
    if hasHeaders then
        DF:UpdateRaidHeaderVisibility()
        DF:PositionRaidHeaders()
        DF:UpdateRaidGroupLabels()
        return
    end

    -- Sorting disabled OR test mode - use Lua-based positioning logic
    -- (Test mode has no real raid roster, so secure code can't query group membership)
    -- Update group layout params from current settings
    SecureSort:UpdateRaidGroupLayoutParams()
    local lp = SecureSort.raidGroupLayoutParams

    -- [LEAK-TEST] Instrumentation: does the live Lua path run, and what's lp.testMode?
    -- Toggle: /run DandersFrames.debugLeakTest = true (or false to silence)
    if DF.debugLeakTest then
        DF:Say(string.format(
            "LEAK-TEST: UpdateRaidGroupedLayout -> Lua fallback  raidTestMode=%s  lp.testMode=%s  db.sortEnabled=%s",
            tostring(DF.raidTestMode),
            tostring(lp and lp.testMode),
            tostring(db and db.sortEnabled)
        ))
    end
    
    -- Count visible frames and build group membership data
    -- PERFORMANCE FIX: Reuse tables instead of creating new ones
    wipe(reusableGroupPlayerCounts)
    wipe(reusableActiveGroups)
    wipe(reusableActiveGroupList)
    wipe(reusableFrameToGroup)
    local groupPlayerCounts = reusableGroupPlayerCounts  -- groupNum -> count of players
    local activeGroups = reusableActiveGroups       -- groupNum -> true if has players
    local activeGroupList = reusableActiveGroupList    -- ordered list of active group numbers
    local frameToGroup = reusableFrameToGroup       -- frameIndex -> { groupNum, posInGroup }
    local visibleCount = 0
    
    -- In test mode, frames are sequentially assigned: 1-5 = group 1, 6-10 = group 2, etc.
    -- In live mode, we need to get the actual group from the unit
    local isTestMode = DF.raidTestMode
    
    for i = 1, 40 do
        local frame = DF.raidFrames[i]
        if frame and frame:IsShown() then
            visibleCount = visibleCount + 1
            
            local groupNum
            local posInGroup
            
            if isTestMode then
                -- Test mode: sequential assignment
                groupNum = math.ceil(visibleCount / 5)
                posInGroup = (visibleCount - 1) % 5
            else
                -- Live mode: get actual group from unit
                local unit = frame:GetAttribute("unit") or frame.unit
                if unit and UnitExists(unit) then
                    local name, rank, subgroup = GetRaidRosterInfo(UnitInRaid(unit) or 0)
                    groupNum = subgroup or 1
                    
                    -- Count position within this group
                    posInGroup = (groupPlayerCounts[groupNum] or 0)
                else
                    -- Fallback for units without roster info
                    groupNum = math.ceil(i / 5)
                    posInGroup = (i - 1) % 5
                end
            end
            
            groupPlayerCounts[groupNum] = (groupPlayerCounts[groupNum] or 0) + 1
            -- PERFORMANCE FIX: Reuse sub-table if it exists
            if not frameToGroup[i] then
                frameToGroup[i] = { groupNum = 0, posInGroup = 0 }
            end
            frameToGroup[i].groupNum = groupNum
            frameToGroup[i].posInGroup = posInGroup
            
            if not activeGroups[groupNum] then
                activeGroups[groupNum] = true
                table.insert(activeGroupList, groupNum)
            end
        end
    end
    
    -- Order activeGroupList by effective display order (Group Display Order /
    -- My Group First). PositionRaidFrameToGroupSlot derives each group's slot
    -- from its index within this list, so a raw group-number sort here pinned
    -- the frames to default order while the headers/labels already moved — the
    -- Group Display Order / My Group First desync.
    DF:SortActiveGroupListByDisplayOrder(activeGroupList, db)

    -- Recalculate posInGroup now that we know actual counts
    -- PERFORMANCE FIX: Reuse table
    wipe(reusableGroupCurrentPos)
    local groupCurrentPos = reusableGroupCurrentPos
    for i = 1, 40 do
        local frame = DF.raidFrames[i]
        if frame and frame:IsShown() and frameToGroup[i] then
            local groupNum = frameToGroup[i].groupNum
            groupCurrentPos[groupNum] = groupCurrentPos[groupNum] or 0
            frameToGroup[i].posInGroup = groupCurrentPos[groupNum]
            groupCurrentPos[groupNum] = groupCurrentPos[groupNum] + 1
        end
    end
    
    -- Calculate and set container size
    local totalWidth, totalHeight = SecureSort:CalculateRaidGroupContainerSize(#activeGroupList, lp)
    DF.raidContainer:SetSize(totalWidth, totalHeight)
    DF:SyncRaidMoverToContainer()

    -- Position each visible frame
    for i = 1, 40 do
        local frame = DF.raidFrames[i]
        if frame and frame:IsShown() and frameToGroup[i] then
            local groupInfo = frameToGroup[i]
            local groupNum = groupInfo.groupNum
            local posInGroup = groupInfo.posInGroup
            local playersInGroup = groupPlayerCounts[groupNum]
            
            -- Set frame size
            frame:SetSize(lp.frameWidth, lp.frameHeight)
            
            -- Position using shared function
            SecureSort:PositionRaidFrameToGroupSlot(
                frame, 
                groupNum, 
                posInGroup, 
                playersInGroup, 
                activeGroupList, 
                lp, 
                DF.raidContainer
            )
        end
    end
    
    -- Update group labels
    DF:UpdateRaidGroupLabels()
end

-- ============================================================
-- FLAT GRID RAID LAYOUT
-- All players in one unified grid, no group structure
-- ============================================================

function DF:UpdateRaidFlatLayout()
    local db = DF:GetRaidDB()
    
    if not DF.raidContainer then return end
    
    -- Protect against calling during combat (secure frame operations would fail)
    if InCombatLockdown() then
        -- Use the specific flat layout refresh flag
        -- which is handled properly in Headers.lua's combat handler
        DF.pendingFlatLayoutRefresh = true
        return
    end
    
    -- CRITICAL: Hide separated headers when in flat mode
    -- This ensures we don't have two sets of frames visible
    if DF.raidSeparatedHeaders then
        for i = 1, 8 do
            if DF.raidSeparatedHeaders[i] then
                DF.raidSeparatedHeaders[i]:Hide()
                if DF.SetHeaderChildrenEventsEnabled then
                    DF:SetHeaderChildrenEventsEnabled(DF.raidSeparatedHeaders[i], false)
                end
            end
        end
    end
    
    -- Use FlatRaidFrames for flat layouts
    if DF.FlatRaidFrames then
        if not DF.FlatRaidFrames.initialized then
            DF.FlatRaidFrames:Initialize()
        end
        DF.FlatRaidFrames:SetEnabled(true)
        DF.FlatRaidFrames:ApplyLayoutSettings()
        return
    end
end

-- ============================================================
-- RAID GROUP LABELS
-- ============================================================

-- Container for group labels
DF.raidGroupLabels = {}

-- Format the group label text
local function FormatGroupLabelText(groupNum, format)
    if format == "GROUP_NUM" then
        return "Group " .. groupNum
    elseif format == "SHORT" then
        return "G" .. groupNum
    elseif format == "NUM_ONLY" then
        return tostring(groupNum)
    elseif format == "ROMAN" then
        local romans = {"I", "II", "III", "IV", "V", "VI", "VII", "VIII"}
        return romans[groupNum] or tostring(groupNum)
    else
        return "Group " .. groupNum
    end
end

-- Create or get a group label
-- Container parameter allows creating labels for either live (raidContainer) or test (testRaidContainer) mode
local function GetOrCreateGroupLabel(groupNum, container)
    -- Use provided container or default to raidContainer
    local parentContainer = container or DF.raidContainer
    if not parentContainer then return nil end
    
    -- Check if label already exists
    if DF.raidGroupLabels[groupNum] then
        local label = DF.raidGroupLabels[groupNum]
        -- Re-parent if needed (switching between live/test mode)
        if label:GetParent() ~= parentContainer then
            label:SetParent(parentContainer)
        end
        return label
    end

    local label = parentContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetDrawLayer("OVERLAY", 7)

    DF.raidGroupLabels[groupNum] = label
    return label
end

-- Update all raid group labels
-- This can be called during combat - FontStrings are not protected
-- Labels are now anchored directly to group headers (live) or first frame of each group (test)
function DF:UpdateRaidGroupLabels(activeGroupsTable, db, horizontal)
    if not db then db = DF:GetRaidDB() end
    
    local isTestMode = DF.raidTestMode
    
    -- Determine parent container based on mode
    local container = isTestMode and DF.testRaidContainer or DF.raidContainer
    if not container then return end
    
    -- Group labels only make sense in group-based layout mode
    local useGroups = db.raidUseGroups
    local enabled = db.groupLabelEnabled and useGroups
    
    -- Build active groups data
    local activeGroups = {}      -- groupNum -> true if active
    local groupFirstFrame = {}   -- groupNum -> first frame of that group (for test mode anchoring)
    
    if isTestMode then
        if DF.testGroupFirstFrame then
            -- Use sorted first-frame mapping (populated by LightweightPositionRaidTestFrames)
            for groupNum, frame in pairs(DF.testGroupFirstFrame) do
                activeGroups[groupNum] = true
                groupFirstFrame[groupNum] = frame
            end
        else
            -- Fallback: unsorted index-based (before first positioning pass)
            local testFrameCount = db.raidTestFrameCount or 10
            for i = 1, testFrameCount do
                local frame = DF.testRaidFrames and DF.testRaidFrames[i]
                if frame then
                    local groupNum = math.ceil(i / 5)
                    if not activeGroups[groupNum] then
                        activeGroups[groupNum] = true
                        groupFirstFrame[groupNum] = frame
                    end
                end
            end
        end
    else
        -- Live mode: check which separated headers have visible children
        if DF.raidSeparatedHeaders then
            for g = 1, 8 do
                local header = DF.raidSeparatedHeaders[g]
                if header and header:IsShown() then
                    -- Check if header has any visible children
                    local child1 = header:GetAttribute("child1")
                    if child1 and child1:IsShown() then
                        activeGroups[g] = true
                    end
                end
            end
        end
    end
    
    -- Get layout direction
    local isHorizontal = (db.growDirection == "HORIZONTAL")
    local labelPosition = db.groupLabelPosition or "START"
    local offsetX = db.groupLabelOffsetX or 0
    local offsetY = db.groupLabelOffsetY or 0
    
    for g = 1, 8 do
        local label = DF.raidGroupLabels[g]
        
        if not enabled or not activeGroups[g] then
            -- Hide label if disabled or group not active
            if label then
                label:Hide()
            end
        else
            -- Create label if needed (pass container for proper parenting in test mode)
            if not label then
                label = GetOrCreateGroupLabel(g, container)
            end

            if label then
                -- Ensure label is parented to the correct container
                if label:GetParent() ~= container then
                    label:SetParent(container)
                end

                -- Apply font settings (composite outline encoding handles shadow via SafeSetFont)
                local font = db.groupLabelFont or "Fonts\\FRIZQT__.TTF"
                local fontSize = db.groupLabelFontSize or 12
                local outline = db.groupLabelOutline or "OUTLINE"
                if outline == "NONE" then outline = "" end

                DF:SafeSetFont(label, font, fontSize, outline)

                -- Apply color
                local color = db.groupLabelColor or {r = 1, g = 1, b = 1, a = 1}
                label:SetTextColor(color.r, color.g, color.b, color.a or 1)

                -- Set text
                local format = db.groupLabelFormat or "GROUP_NUM"
                local text = FormatGroupLabelText(g, format)
                label:SetText(text)
                
                -- Determine anchor frame and points based on mode and layout
                local anchorFrame
                if isTestMode then
                    -- The group's EXTENT (first..last), not its first frame -- live
                    -- anchors to the separated header, which spans the group, so END
                    -- and CENTER only agree if the preview anchors to a span too.
                    -- Falls back to the first frame for the one pass before
                    -- UpdateTestGroupExtents has run. (Audit, 2026-08-07.)
                    anchorFrame = (DF.testGroupExtent and DF.testGroupExtent[g])
                        or groupFirstFrame[g]
                else
                    anchorFrame = DF.raidSeparatedHeaders and DF.raidSeparatedHeaders[g]
                end
                
                if anchorFrame then
                    -- Calculate anchor points based on label position and layout direction
                    local labelAnchor, frameAnchor, anchorOffsetX, anchorOffsetY
                    
                    if labelPosition == "START" then
                        if isHorizontal then
                            -- Columns mode: START = above the group
                            labelAnchor = "BOTTOM"
                            frameAnchor = "TOP"
                            anchorOffsetX = offsetX
                            anchorOffsetY = offsetY
                        else
                            -- Rows mode: START = left of the group
                            labelAnchor = "RIGHT"
                            frameAnchor = "LEFT"
                            anchorOffsetX = offsetX
                            anchorOffsetY = offsetY
                        end
                    elseif labelPosition == "END" then
                        if isHorizontal then
                            -- Columns mode: END = below the group
                            labelAnchor = "TOP"
                            frameAnchor = "BOTTOM"
                            anchorOffsetX = offsetX
                            anchorOffsetY = offsetY
                        else
                            -- Rows mode: END = right of the group
                            labelAnchor = "LEFT"
                            frameAnchor = "RIGHT"
                            anchorOffsetX = offsetX
                            anchorOffsetY = offsetY
                        end
                    else -- CENTER
                        labelAnchor = "CENTER"
                        frameAnchor = "CENTER"
                        anchorOffsetX = offsetX
                        anchorOffsetY = offsetY
                    end
                    
                    -- Position label relative to anchor frame
                    label:ClearAllPoints()
                    label:SetPoint(labelAnchor, anchorFrame, frameAnchor, anchorOffsetX, anchorOffsetY)

                    label:Show()
                else
                    -- No anchor frame available, hide label
                    label:Hide()
                end
            end
        end
    end
end

function DF:UnlockRaidFrames()
    if InCombatLockdown() then
        DF:Err("Cannot unlock raid frames during combat.")
        return
    end

    -- No DandersMover, no editing surface: see DF:UnlockFrames.
    if not Mover then
        DF:Say(L["DandersMover is disabled. Re-enable it in the AddOns list, or turn on Enable Permanent Mover under Frame options for a basic drag handle."])
        return
    end

    -- Unlocking shows raid test frames, which live in the load-on-demand
    -- companion. Deliberate user action (/df raidunlock, mover button), so load it.
    if DF.EnsureOptionsLoaded and not DF:EnsureOptionsLoaded() then
        return
    end

    -- See DF:UnlockFrames: the raid scope's keys only, forced relevant (solo editing).
    -- The container's own toggle does not gate the session -- only an empty list does.
    local filter = DF.MoverBridge and DF.MoverBridge:SessionFilter("raid") or "DandersFrames"
    if type(filter) == "table" and #filter.keys == 0 then
        DF:Say(string.format(L["All %s movers are turned off under DandersFrames in /mover config."], L["Raid Frames"]))
        return
    end
    if DF.MoverBridge then DF.MoverBridge:RequestScope("raid") end
    Mover:Unlock(filter)
end

function DF:LockRaidFrames()
    -- End the DandersMover session instead; its Locked callback restores raidLocked and
    -- releases the test claim for both scopes.
    if Mover and Mover:IsUnlocked() then
        Mover:Lock()
        return
    end

    if not DF.raidContainer then return end

    -- ☠ COMBAT GUARD, mirroring UnlockRaidFrames. The SetMovable calls in
    -- UpdatePermanentMoverVisibility below are PROTECTED actions on the secure raid
    -- container. Unlock has always refused in combat; Lock had no guard at all, so
    -- unlocking out of combat and then locking after a pull raised a blocked action.
    if InCombatLockdown() then
        DF:Err("Cannot lock raid frames during combat.")
        return
    end

    local db = DF:GetRaidDB()
    db.raidLocked = true

    -- Restore permanent mover visibility (keeps container movable if enabled)
    DF:UpdatePermanentMoverVisibility()

    -- If this lock ends a layout-edit unlock session (started from a layout's own
    -- Unlock button), exit editing so the dragged position is captured into that
    -- layout (ExitEditing's diff-scan + the live SetProfileSetting on drag) and the
    -- layout re-applies. Fires for ANY lock path.
    if DF.raidLayoutEditUnlock then
        DF.raidLayoutEditUnlock = nil
        if DF.AutoProfilesUI and DF.AutoProfilesUI.IsEditing and DF.AutoProfilesUI:IsEditing() then
            DF.AutoProfilesUI:ExitEditing()
        end
    end

    -- Update button text if it exists
    if DF.raidLockButton and DF.raidLockButton.Text then
        DF.raidLockButton.Text:SetText("Unlock Raid Frames")
    end
    if DF.displayLockButton and DF.displayLockButton.Text then
        DF.displayLockButton.Text:SetText("Unlock Frames")
    end

    -- Sync GUI toolbar buttons
    if DF.GUI then
        if DF.GUI.UpdateLockButtonState then DF.GUI.UpdateLockButtonState() end
        if DF.GUI.UpdateTestButtonState then DF.GUI.UpdateTestButtonState() end
    end

    DF:Say("Raid frames locked.")
end

-- ============================================================
-- CLICK-CAST REGISTRATION HELPERS
-- Centralised registration for Clique / Clicked / other click-cast addons.
--
-- There are two phases:
--   1. EARLY (frame creation at ADDON_LOADED) — just mark the frame as
--      needing click-cast registration. We do NOT write to ClickCastFrames
--      yet because Clique's __newindex metatable may not be installed.
--      Writing to a plain table means __newindex never fires for that key,
--      even after Clique later replaces the table with a metatable.
--
--   2. LATE (PLAYER_ENTERING_WORLD+0.5s via RegisterClickCastFrames /
--      RegisterRaidClickCastFrames) — now Clique's metatable is in place,
--      so we write ClickCastFrames[frame] = true and Clique picks it up.
--      The dfClickCastRegistered flag prevents writing more than once.
-- ============================================================

-- Register a frame for click-casting (Clique, Clicked, etc.)
--
-- Before PLAYER_ENTERING_WORLD, just marks the frame — we don't write to
-- ClickCastFrames yet because Clique's __newindex metatable may not be
-- installed. Writing to a plain table means __newindex never fires for
-- that key, even after Clique later replaces the table with a metatable.
--
-- After PLAYER_ENTERING_WORLD (clickCastReady = true), writes directly
-- to ClickCastFrames so Clique's metatable picks up the registration.
-- The dfClickCastRegistered flag prevents writing more than once.
function DF:RegisterFrameWithClickCast(frame)
    if not frame then return end
    if frame.dfClickCastRegistered then return end

    if DF.clickCastReady and ClickCastFrames then
        ClickCastFrames[frame] = true
        -- Do not rely on the table write alone. __newindex fires only for keys the
        -- table does not already hold, so a frame that has been through here before
        -- (or was rawset while ineligible) gets no metamethod at all and would be
        -- silently skipped -- while the flag below claims success. Go direct.
        if DF.ClickCast and DF.ClickCast.EnsureRegistered then
            DF.ClickCast:EnsureRegistered(frame)
        end
        frame.dfClickCastRegistered = true
    else
        -- Mark for deferred registration
        frame.dfNeedsClickCast = true
    end
end

function DF:UnregisterFrameWithClickCast(frame)
    if not frame then return end
    if ClickCastFrames then
        ClickCastFrames[frame] = false
    end
    frame.dfClickCastRegistered = nil
    frame.dfNeedsClickCast = nil
end

-- Commit all deferred registrations. Called once at PLAYER_ENTERING_WORLD
-- after Clique's metatable is in place.
--
-- Iterates ALL header children directly (not via unit-based lookups like
-- IteratePartyFrames/IterateRaidFrames) because at commit time some frames
-- may not have units assigned yet (e.g., party frames when solo-queuing
-- for a dungeon — the header pre-creates children but units aren't set
-- until group members actually appear).
function DF:CommitAllClickCastRegistrations()
    DF.clickCastReady = true

    local function commitFrame(frame)
        if frame and frame.dfNeedsClickCast and not frame.dfClickCastRegistered then
            if ClickCastFrames then
                ClickCastFrames[frame] = true
            end
            frame.dfClickCastRegistered = true
            frame.dfNeedsClickCast = nil
        end
    end

    -- Party header children (player + party1-4)
    if DF.partyHeader then
        for i = 1, 5 do
            commitFrame(DF.partyHeader:GetAttribute("child" .. i))
        end
    end

    -- Arena header children
    if DF.arenaHeader then
        for i = 1, 5 do
            commitFrame(DF.arenaHeader:GetAttribute("child" .. i))
        end
    end

    -- Raid separated headers (8 groups x 5)
    if DF.raidSeparatedHeaders then
        for g = 1, 8 do
            local header = DF.raidSeparatedHeaders[g]
            if header then
                for i = 1, 5 do
                    commitFrame(header:GetAttribute("child" .. i))
                end
            end
        end
    end

    -- Flat raid header (up to 40)
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        for i = 1, 40 do
            commitFrame(DF.FlatRaidFrames.header:GetAttribute("child" .. i))
        end
    end

    -- Combined raid header
    if DF.raidCombinedHeader then
        for i = 1, 40 do
            commitFrame(DF.raidCombinedHeader:GetAttribute("child" .. i))
        end
    end

    -- Pet frames
    if DF.petFrames then
        for _, frame in pairs(DF.petFrames) do
            commitFrame(frame)
        end
    end

    -- Pinned frames headers
    if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local header = DF.PinnedFrames.headers[setIndex]
            if header then
                for i = 1, 40 do
                    commitFrame(header:GetAttribute("child" .. i))
                end
            end
        end
    end

    -- Pinned boss frames
    if DF.PinnedFrames and DF.PinnedFrames.bossFrames then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local frames = DF.PinnedFrames.bossFrames[setIndex]
            if frames then
                for i = 1, 8 do
                    commitFrame(frames[i])
                end
            end
        end
    end
end

-- Legacy functions — now just call CommitAllClickCastRegistrations
function DF:RegisterRaidClickCastFrames()
    DF:CommitAllClickCastRegistrations()
end

function DF:RegisterClickCastFrames()
    DF:CommitAllClickCastRegistrations()
end

-- ============================================================
-- UPDATE LIVE RAID FRAMES (when actually in a raid)
-- ============================================================
function DF:UpdateLiveRaidFrames()
    if DF:DebugActive("FLATRAID") then
        DF:Debug("FLATRAID", "UpdateLiveRaidFrames: called from\n%s", debugstack(2, 10, 0) or "unknown")
    end
    
    -- Don't show live frames while in test mode
    if DF.testMode or DF.raidTestMode then
        return
    end
    
    -- Use header system if available (new mode)
    if DF.headersCreated then
        -- ARENA GUARD: Arena uses partyContainer + arenaHeader, NOT raidContainer.
        -- IsInRaid()=true in arena, so without this guard we'd show raid frames
        -- and hide partyContainer (destroying the arena header).
        if DF.IsInArena and DF:IsInArena() then
            return
        end
        
        -- Header system handles raid frames via SecureGroupHeaderTemplate
        -- Just need to show the raid container and headers
        if InCombatLockdown() then
            DF.pendingRaidVisibilityUpdate = true
            return
        end
        
        local db = DF:GetRaidDB()

        -- Check if raid frames are enabled
        -- ☠ PROFILE ROOT, NOT THE RAID TABLE, and `~= false`, not `not`.
        --
        -- The Enable Raid Frames checkbox binds to DF.db (Options/GUI/Pages/Options.lua),
        -- so the flag lives at the PROFILE ROOT. This read used DF:GetRaidDB(), whose
        -- raidEnabled is a separate key inherited from PartyDefaults (Core/Config.lua)
        -- that nothing ever writes -- so the test was permanently true and unticking the
        -- box did nothing here. Headers.lua's CreateHeaderFrames reads the right key, so
        -- headers were correctly skipped while this path still showed the raid container
        -- and hid the party one.
        --
        -- `~= false` because absence must mean ENABLED: a profile predating the key has
        -- no value, and `not nil` would read that as "off" -- the fail-dangerous shape.
        if DF.db and DF.db.raidEnabled == false then
            if DF.raidContainer then
                DF.raidContainer:Hide()
            end
            return
        end
        
        -- Show raid container
        if DF.raidContainer then
            DF.raidContainer:Show()
            -- NOTE: Don't ClearAllPoints/SetPoint here on every call!
            -- Container position is set when entering raid or when settings change.
            -- Repositioning on roster updates causes visual shifting.
        end
        
        -- Update header visibility (show/hide based on group mode)
        DF:UpdateRaidHeaderVisibility()
        
        -- NOTE: We intentionally do NOT call PositionRaidHeaders() here!
        -- PositionRaidHeaders clears child anchor points and triggers a full
        -- re-layout, causing visual shifting when roster changes.
        -- The SecureGroupHeaderTemplate handles child positioning automatically.
        -- Container/header positioning should only happen when SETTINGS change.
        
        -- Hide party container when in raid (party headers are hidden by UpdateHeaderVisibility)
        if DF.container then
            DF.container:Hide()
        end
        if DF.partyContainer then
            DF.partyContainer:Hide()
        end

        -- Update pet frames (must be called in header mode too, not just legacy mode)
        if DF.UpdateAllPetFrames then
            DF:UpdateAllPetFrames()
        end

        return
    end

    -- LEGACY MODE: Old code for non-header system (fallback)
    if not DF.raidContainer then return end
    if not DF.initialized then return end
    
    -- Safety check: Arenas use arena header, not raid frames
    local contentType = DF:GetContentType()
    local inArena = (contentType == "arena")
    if inArena then
        DF.raidContainer:Hide()
        DF:UpdateAllFrames()
        return
    end
    
    -- Protect against calling during combat
    if InCombatLockdown() then
        DF.needsUpdate = true
        return
    end
    
    local db = DF:GetRaidDB()

    -- Check if raid frames are enabled
    -- ☠ Same fix as the sibling above: the flag is at the PROFILE ROOT (the checkbox
    -- binds to DF.db), not in the raid table, and absence must mean ENABLED.
    if DF.db and DF.db.raidEnabled == false then
        DF.raidContainer:Hide()
        return
    end
    
    -- Show raid container
    DF.raidContainer:Show()
    
    -- Update raid container position
    local raidScale = db.frameScale or 1.0
    DF.raidContainer:SetScale(raidScale)
    DF.raidContainer:ClearAllPoints()
    DF.raidContainer:SetPoint("CENTER", UIParent, "CENTER", (db.raidAnchorX or 0) / raidScale, (db.raidAnchorY or 0) / raidScale)
    
    -- Legacy: Update layout only if legacy frames exist
    if DF.raidFrames and DF.raidFrames[1] then
        -- Update the layout (this positions frames)
        if db.raidUseGroups then
            DF:UpdateRaidLayout()
        else
            DF:UpdateRaidFlatLayout()
        end
        
        -- Register unit watches and fully update frames for existing raid members
        for i = 1, 40 do
            local frame = DF.raidFrames[i]
            if frame then
                frame.unit = "raid" .. i
                
                -- Use RegisterUnitWatch to automatically show/hide based on unit existence
                DF:SafeRegisterUnitWatch(frame)
                
                -- Apply style
                DF:ApplyFrameStyle(frame)
                
                -- Full update if unit exists
                if UnitExists(frame.unit) then
                    DF:UpdateUnitFrame(frame)
                    if DF.UpdateAuras then DF:UpdateAuras(frame) end
                    if DF.UpdateRoleIcon then DF:UpdateRoleIcon(frame) end
                    if DF.UpdateLeaderIcon then DF:UpdateLeaderIcon(frame) end
                    if DF.UpdateRaidTargetIcon then DF:UpdateRaidTargetIcon(frame) end
                    if DF.UpdateReadyCheckIcon then DF:UpdateReadyCheckIcon(frame) end
                    if DF.UpdatePingIcon then DF:UpdatePingIcon(frame) end
                    if DF.UpdateCenterStatusIcon then DF:UpdateCenterStatusIcon(frame) end
                    if DF.UpdateMissingBuffIcon and not InCombatLockdown() then DF:UpdateMissingBuffIcon(frame) end
                    if DF.UpdateExternalDefIcon then DF:UpdateExternalDefIcon(frame) end
                end
                
                DF:RegisterFrameWithClickCast(frame)
            end
        end
    end

    -- Hide party frames when in raid (legacy mode)
    if DF.container then
        DF.container:Hide()
    end
    if DF.playerFrame then
        UnregisterUnitWatch(DF.playerFrame)
        DF.playerFrame:Hide()
    end
    for i = 1, 4 do
        local frame = DF.partyFrames[i]
        if frame then
            UnregisterUnitWatch(frame)
            frame:Hide()
        end
    end
    
    -- Update raid pet frames
    if DF.UpdateAllRaidPetFrames then
        DF:UpdateAllRaidPetFrames()
    end
end

function DF:UpdateAllFrames()
    if DF:DebugActive("FLATRAID") then
        DF:Debug("FLATRAID", "UpdateAllFrames: called from\n%s", debugstack(2, 10, 0) or "unknown")
    end

    -- 12.1 factory rows: GUI callbacks that end in a full update (checkboxes,
    -- dropdowns) must also re-drive the standing aura containers, or the change
    -- applies one aura event late. Bump the layout version so the (debounced)
    -- drive re-applies; placed before the early-return branches so every path is
    -- covered. Gated on factory ownership so pre-12.1 / legacy paths pay nothing.
    -- ⚠ Asks "is the container era live at all", NOT "is a specific row active".
    -- This used to call the two RENDER gates (UseFactoryForBuffs /
    -- UseFactoryForDefensive), which then grew a perf-test term — so switching
    -- Auras and Defensive off in the perf panel silently stopped the version
    -- bump that the dispel overlay, missing-buff strip and Aura Designer also
    -- ride, and their settings changes started applying one aura event late.
    -- IsSupported is the question this gate actually means.
    if DF.InvalidateAuraLayout
        and DF.AuraContainer and DF.AuraContainer.IsSupported and DF.AuraContainer.IsSupported() then
        DF:InvalidateAuraLayout()
    end
    
    -- Header mode: party frames are managed by SecureGroupHeaderTemplate
    -- This function is called when NOT in a raid, to show party frames
    if DF.headersCreated then
        if InCombatLockdown() then
            DF.needsUpdate = true
            return
        end
        
        -- If in test mode, update test frames instead of live frames
        if DF.testMode or DF.raidTestMode then
            -- Still apply settings to live frames (they're hidden but need to stay in sync)
            if DF.IterateAllFrames then
                DF:IterateAllFrames(function(frame)
                    if frame and DF.ApplyFrameLayout then
                        DF:ApplyFrameLayout(frame)
                    end
                end)
            end
            
            -- Update test frames with new layout settings
            if DF.RefreshTestFramesWithLayout then
                DF:RefreshTestFramesWithLayout()
            end
            return
        end
        
        -- Show party container
        if DF.partyContainer then
            DF.partyContainer:Show()
        end
        
        -- Update header visibility (this shows/hides based on group status)
        if DF.UpdateHeaderVisibility then
            DF:UpdateHeaderVisibility()
        end
        
        -- Apply settings to all header children (party, raid, or arena)
        -- NOTE: This only applies LAYOUT settings (size, texture, etc.)
        -- Unit data updates (health, role icons, etc.) are handled by:
        -- - OnAttributeChanged -> FullFrameRefresh (unit changes)
        -- - headerChildEventFrame (PLAYER_ROLES_ASSIGNED, RAID_TARGET_UPDATE, etc.)
        -- - UNIT_* events (health, auras, power)
        -- IterateAllFrames routes to arena frames when in arena,
        -- party+raid frames otherwise — so layout changes always hit the correct frames.
        if DF.IterateAllFrames then
            DF:IterateAllFrames(function(frame)
                if frame and frame.dfIsHeaderChild then
                    if DF.ApplyFrameLayout then
                        DF:ApplyFrameLayout(frame)
                    end
                end
            end)
        end
        
        -- NOTE: We intentionally do NOT call ApplyHeaderSettings() here!
        -- ApplyHeaderSettings() repositions headers and containers, which causes
        -- visual shifting when roster changes. It should ONLY be called when
        -- settings actually change (from Options UI, profile switches, etc.),
        -- not during roster updates.
        -- The SecureGroupHeaderTemplate handles child positioning automatically.

        -- Update pet frames (must be called in header mode too, not just legacy mode)
        if DF.UpdateAllPetFrames then
            DF:UpdateAllPetFrames()
        end

        return
    end
    
    -- LEGACY MODE: Original UpdateAllFrames code
    if not DF.container then return end
    if not DF.initialized then return end
    
    -- Protect against calling during combat (secure frame operations would fail)
    if InCombatLockdown() then
        DF.needsUpdate = true
        return
    end
    
    -- If in a raid (and not in test mode), redirect to raid frames
    -- Use unified content type detection - arena uses arena header, not raid frames
    local contentType = DF:GetContentType()
    local inArena = (contentType == "arena")
    if IsInRaid() and not inArena and not DF.testMode and not DF.raidTestMode then
        DF:UpdateLiveRaidFrames()
        return
    end
    
    local db = DF:GetDB()
    
    -- Check group status
    local inGroup = IsInGroup()
    local numPartyMembers = GetNumSubgroupMembers()
    
    -- Was a DF:Out block printing to CHAT behind DF.debugEnabled. These are
    -- visibility inputs, so they belong in the console under VISIBILITY.
    DF:Debug("VISIBILITY", "UpdateAllFrames: inGroup=%s party=%d testMode=%s soloMode=%s",
        tostring(inGroup), numPartyMembers or 0, tostring(DF.testMode), tostring(db.soloMode))
    
    -- Determine what to show:
    -- Test Mode: show everything (player + 4 party frames)
    -- In Group: show player + party members
    -- Solo Mode (not in group): show player only
    -- No Solo Mode (not in group): show nothing
    -- hidePlayerFrame: completely hide player frame (except in test mode)
    -- raidTestMode: hide party frames entirely (raid test mode uses separate raid frames)
    
    -- When in raid test mode, hide party/player frames entirely
    local showPlayerFrame = (DF.testMode and not DF.raidTestMode) or ((inGroup or (db.soloMode == true)) and not db.hidePlayerFrame and not DF.raidTestMode)
    local showPartyFrames = (DF.testMode and not DF.raidTestMode) or (inGroup and not DF.raidTestMode)
    
    DF:Debug("VISIBILITY", "UpdateAllFrames: showPlayer=%s showParty=%s hidePlayer=%s raidTest=%s",
        tostring(showPlayerFrame), tostring(showPartyFrames),
        tostring(db.hidePlayerFrame), tostring(DF.raidTestMode))
    
    -- Update container position (always use CENTER for consistency with position panel)
    local partyScale = db.frameScale or 1.0
    DF.container:SetScale(partyScale)
    DF.container:ClearAllPoints()
    DF.container:SetPoint("CENTER", UIParent, "CENTER", (db.anchorX or 0) / partyScale, (db.anchorY or 0) / partyScale)
    DF.container:Show()  -- Ensure container is visible
    
    -- Calculate layout
    local spacing = db.frameSpacing or 4
    local horizontal = db.growDirection == "HORIZONTAL"
    
    -- Apply pixel-perfect adjustments for positioning calculations
    local ppFrameWidth = db.pixelPerfect and DF:PixelPerfect(db.frameWidth or 120) or (db.frameWidth or 120)
    local ppFrameHeight = db.pixelPerfect and DF:PixelPerfect(db.frameHeight or 50) or (db.frameHeight or 50)
    local ppSpacing = db.pixelPerfect and DF:PixelPerfect(spacing) or spacing
    
    -- Get growth anchor (START/CENTER/END)
    local growthAnchor = db.growthAnchor or "START"
    
    -- First pass: count how many frames will be shown
    local testFrameCount = db.testFrameCount or 5
    local visibleFrames = {}
    
    -- Check player frame
    -- In test mode, use testFrameCount; otherwise use normal logic
    local showPlayerInTest = DF.testMode and testFrameCount >= 1
    if showPlayerFrame or showPlayerInTest then
        local entry = {frame = DF.playerFrame, index = 0, isPlayer = true, unit = "player"}
        -- Add test data for sorting in test mode
        if DF.testMode then
            entry.testData = DF:GetTestUnitData(0, false)  -- false = not raid
        end
        table.insert(visibleFrames, entry)
    end
    
    -- Check party frames
    for i = 1, 4 do
        local frame = DF.partyFrames[i]
        if frame then
            -- In test mode, ONLY use testFrameCount (ignore actual party size)
            -- Outside test mode, use actual party membership
            local showThisFrame
            if DF.testMode then
                showThisFrame = (i + 1) <= testFrameCount
            else
                showThisFrame = inGroup and i <= numPartyMembers
            end
            
            if showPartyFrames and showThisFrame then
                local entry = {frame = frame, index = i, isPlayer = false, unit = "party" .. i}
                -- Add test data for sorting in test mode
                if DF.testMode then
                    entry.testData = DF:GetTestUnitData(i, false)  -- false = not raid
                end
                table.insert(visibleFrames, entry)
            end
        end
    end
    
    -- No sort pass here: SecureSort owns party sorting/positioning, and this list
    -- only drives visibility setup, which does not depend on order.
    local frameCount = #visibleFrames
    
    -- Calculate sizes (use pixel-perfect values)
    local maxFrameCount = 5  -- Maximum party size
    local actualWidth = frameCount > 0 and (frameCount * (ppFrameWidth + ppSpacing) - ppSpacing) or 0
    local actualHeight = frameCount > 0 and (frameCount * (ppFrameHeight + ppSpacing) - ppSpacing) or 0
    local maxWidth = maxFrameCount * (ppFrameWidth + ppSpacing) - ppSpacing
    local maxHeight = maxFrameCount * (ppFrameHeight + ppSpacing) - ppSpacing
    
    -- Set outer container to max size (for consistent dragging area)
    if horizontal then
        DF.container:SetSize(maxWidth, ppFrameHeight)
    else
        DF.container:SetSize(ppFrameWidth, maxHeight)
    end
    
    -- Create party group container if needed (holds actual frames, sized to visible frames)
    -- NOTE: Using SecureFrameTemplate so secure code can SetPoint relative to this frame
    if not DF.partyGroupContainer then
        DF.partyGroupContainer = CreateFrame("Frame", "DandersPartyGroupContainer", DF.container, "SecureFrameTemplate")
    end
    
    -- Size party group container to actual visible frames
    if frameCount > 0 then
        if horizontal then
            DF.partyGroupContainer:SetSize(actualWidth, ppFrameHeight)
        else
            DF.partyGroupContainer:SetSize(ppFrameWidth, actualHeight)
        end
        DF.partyGroupContainer:Show()
    else
        -- NOTE: Even with 0 visible frames, we keep the container visible (but 1x1 size)
        -- when NOT in test mode. This allows party frames to appear during combat
        -- when someone joins. RegisterUnitWatch will show the frames inside.
        DF.partyGroupContainer:SetSize(1, 1)
        if DF.testMode then
            DF.partyGroupContainer:Hide()
        else
            DF.partyGroupContainer:Show()  -- Keep visible for combat party joins
        end
    end
    
    -- Anchor party group container based on growthAnchor
    DF.partyGroupContainer:ClearAllPoints()
    if horizontal then
        -- Horizontal layout - anchor controls left/center/right
        if growthAnchor == "START" then
            DF.partyGroupContainer:SetPoint("LEFT", DF.container, "LEFT", 0, 0)
        elseif growthAnchor == "CENTER" then
            DF.partyGroupContainer:SetPoint("CENTER", DF.container, "CENTER", 0, 0)
        else -- END
            DF.partyGroupContainer:SetPoint("RIGHT", DF.container, "RIGHT", 0, 0)
        end
    else
        -- Vertical layout - anchor controls top/center/bottom
        if growthAnchor == "START" then
            DF.partyGroupContainer:SetPoint("TOP", DF.container, "TOP", 0, 0)
        elseif growthAnchor == "CENTER" then
            DF.partyGroupContainer:SetPoint("CENTER", DF.container, "CENTER", 0, 0)
        else -- END
            DF.partyGroupContainer:SetPoint("BOTTOM", DF.container, "BOTTOM", 0, 0)
        end
    end
    
    -- SecureSort handles positioning - we just need to set up visibility and content
    for idx, frameData in ipairs(visibleFrames) do
        local frame = frameData.frame
        
        -- Reparent to party group container (SecureSort positions relative to this)
        frame:SetParent(DF.partyGroupContainer)
        
        -- Handle visibility and updates
        if frameData.isPlayer then
            if not DF.testMode then
                DF:SafeRegisterUnitWatch(frame)
            else
                UnregisterUnitWatch(frame)
            end
            frame:Show()
            -- Register with click-cast addons when shown
            DF:RegisterFrameWithClickCast(frame)
            DF:ApplyFrameStyle(frame)
            if DF.testMode then
                DF:UpdateTestFrame(frame, 0)
            else
                DF:UpdateFrame(frame)
            end
        else
            if DF.testMode then
                UnregisterUnitWatch(frame)
                frame:Show()
                -- Register with click-cast addons when shown
                DF:RegisterFrameWithClickCast(frame)
                DF:ApplyFrameStyle(frame)  -- Apply style BEFORE UpdateTestFrame so dead fade isn't lost
                DF:UpdateTestFrame(frame, frameData.index)
            else
                DF:SafeRegisterUnitWatch(frame)
                -- Register with click-cast addons
                DF:RegisterFrameWithClickCast(frame)
                DF:ApplyFrameStyle(frame)
                DF:UpdateFrame(frame)
            end
        end
    end
    
    -- IMPORTANT: When NOT in test mode, ensure ALL party frames are parented to
    -- partyGroupContainer and have styles applied. This is necessary for frames
    -- that aren't currently visible (e.g., when solo) but may appear during combat
    -- when party members join. RegisterUnitWatch will handle showing them.
    if not DF.testMode then
        -- Player frame
        if DF.playerFrame then
            DF.playerFrame:SetParent(DF.partyGroupContainer)
            DF:ApplyFrameStyle(DF.playerFrame)
        end
        -- All party frames (even if currently invisible)
        for i = 1, 4 do
            local frame = DF.partyFrames[i]
            if frame then
                frame:SetParent(DF.partyGroupContainer)
                DF:ApplyFrameStyle(frame)
            end
        end
    end
    
    -- Hide frames that aren't visible
    -- NOTE: We only unregister from unit watch in test mode.
    -- Outside test mode, we ALWAYS keep RegisterUnitWatch active so frames
    -- can appear/disappear securely during combat when party members join/leave.
    
    -- IMPORTANT: Register party frames with RegisterUnitWatch when not in test mode.
    -- This ensures frames can appear during combat when party members join.
    -- RegisterUnitWatch will automatically show/hide based on UnitExists().
    if not DF.testMode then
        -- Register player frame only if it should be shown (solo mode enabled or in group)
        if DF.playerFrame then
            if showPlayerFrame then
                DF:SafeRegisterUnitWatch(DF.playerFrame)
            else
                DF:SafeUnregisterUnitWatch(DF.playerFrame)
                DF:UnregisterFrameWithClickCast(DF.playerFrame)
            end
        end
        -- Always register ALL party frames (1-4), even if currently solo
        -- Party frames use "party1"-"party4" units which only exist when in a group
        for i = 1, 4 do
            local frame = DF.partyFrames[i]
            if frame then
                DF:SafeRegisterUnitWatch(frame)
            end
        end
    end
    
    -- Handle test mode player frame visibility.
    --
    -- DF.playerFrame is legitimately nil at times -- the OnAttributeChanged
    -- handler clears it when the frame holding unit=player gives it up, and with
    -- "hide self from party frames" the header may never assign a main-frame
    -- child that unit at all. The two lines below dereference it unguarded, so
    -- this could throw. The sibling block above already tests it first.
    if DF.testMode and not (testFrameCount >= 1) and DF.playerFrame then
        UnregisterUnitWatch(DF.playerFrame)
        DF.playerFrame:Hide()
        DF:UnregisterFrameWithClickCast(DF.playerFrame)
    end

    for i = 1, 4 do
        local frame = DF.partyFrames[i]
        if frame then
            -- In test mode, ONLY use testFrameCount (ignore actual party size)
            local showThisFrame
            if DF.testMode then
                showThisFrame = (i + 1) <= testFrameCount
            else
                showThisFrame = inGroup and i <= numPartyMembers
            end
            
            if not (showPartyFrames and showThisFrame) then
                if DF.testMode then
                    -- Test mode: we control visibility manually
                    UnregisterUnitWatch(frame)
                    frame:Hide()
                end
                -- Outside test mode: do NOT unregister - let RegisterUnitWatch handle
                -- visibility so frames can appear during combat when party members join
                -- Unregister from click-cast addons when hidden
                DF:UnregisterFrameWithClickCast(frame)
            end
        end
    end
    
    -- Update role icons (not called from UpdateFrame to prevent flickering)
    if DF.UpdateAllRoleIcons and not DF.testMode then
        DF:UpdateAllRoleIcons()
    end
    
    -- Also update raid frames if in raid test mode
    if DF.raidTestMode then
        DF:UpdateRaidTestFrames()
    end
    
    -- Update pet frames
    if DF.UpdateAllPetFrames then
        DF:UpdateAllPetFrames()
    end
    
    -- ☠ The SecureSort init/positioning block that closed this function is gone, and
    -- it is worth recording WHY it could never run, because the reasoning is not local.
    --
    -- It began `if not DF.SecureSort.initialized and DF.initialized then Initialize()`.
    -- Reaching it at all requires falling past `if DF.headersCreated then ... return end`
    -- above, i.e. headersCreated == false. But `DF.initialized = true` is written in
    -- exactly one place -- DF:FinalizeHeaderInit in Frames/Headers.lua -- and that
    -- function's second line is `if not DF.headersCreated then return end`.
    --
    -- So the two conditions are mutually exclusive: the only state that reaches this
    -- code is the one state in which DF.initialized can never have been set. Everything
    -- downstream of Initialize() -- RegisterPartyFrames, the test-mode frameList build,
    -- PositionFrameToSlot, TriggerSecureSort -- was unreachable with it.
end

