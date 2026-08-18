local addonName, DF = ...

-- ============================================================
-- RAID/PARTY GEOMETRY CALCULATORS + SPEC CACHE
-- ============================================================
-- ☠ THE NAME OF THIS FILE IS HISTORICAL. There is no secure sorting here.
--
-- This was once a secure-handler system: a SecureHandlerBaseTemplate frame,
-- snippets executed in the restricted environment, attribute bridges, and
-- push/trigger entry points meant to re-sort frames during combat. None of it
-- ever ran in a shipped build -- its init path was unreachable -- and it has
-- been removed. The block above SPECIALIZATION CACHING SYSTEM records the
-- reachability argument in full.
--
-- What the file provides now, and the only reason it is still loaded:
--
--   1. GEOMETRY CALCULATORS -- plain Lua, no secure environment:
--        CalculateSlotPosition / GetSlotAnchors          (party slots)
--        CalculateRaidSlotPosition / GetRaidSlotAnchors  (flat raid slots)
--        CalculateRaidGroupPosition                      (grouped raid)
--        CalculateRaidGroupContainerSize                 (container extent)
--        MapGrowthAnchor                                 (START/CENTER/END)
--      plus the PositionFrameToSlot family that applies them and the
--      UpdateLayoutParams / UpdateRaidLayoutParams / UpdateRaidGroupLayoutParams
--      builders that feed them. Consumers are Frames/Init.lua and the Options
--      addon's test mode.
--
--      ⚠ CalculateRaidGroupPosition is ONE OF TWO implementations of the same
--      grouped-raid geometry. The other is the live secure header snippet in
--      Frames/Headers.lua. They are deliberately kept in agreement -- changing
--      one without the other silently desyncs test mode from live.
--
--   2. SPEC CACHE -- inspect-driven spec IDs mapped to detailed roles so the
--      melee/ranged DPS split works. Frames/Headers.lua and
--      Features/FlatRaidFrames.lua read SecureSort.specCache directly.
-- ============================================================

-- ============================================================
-- MODULE STATE
-- ============================================================

DF.SecureSort = DF.SecureSort or {}
local SecureSort = DF.SecureSort

-- ☠ SecureSort.debug and SecureSort:SetDebug went with the secure environment.
-- The flag existed only because the SECURE side kept its own `debugEnabled`
-- copy that a debug-console category could not reach into; with no handler
-- there is nothing left to keep in step. Lua-side tracing in this file goes
-- through DebugPrint, i.e. the console's SECURESORT category.

-- ⚠ Kept only because Core/API.lua still reads it. The other three state flags
-- (handlerReady, framesRegistered, raidFramesRegistered) went with the
-- registration functions -- nothing reads them any more. This one stays false
-- for the whole session, which is what it has always done.
SecureSort.initialized = false

-- ============================================================
-- SPECIALIZATION TO ROLE MAPPING
-- ============================================================
-- Maps spec IDs to detailed roles for melee/ranged DPS distinction
-- Roles: 1=Tank, 2=Melee DPS, 3=Healer, 4=Ranged DPS
-- This matches SortUnitFrames' approach

local SPEC_ROLE = {
    -- TANKS (role 1)
    [250] = 1, -- Death Knight Blood 
    [581] = 1, -- Demon Hunter Vengeance
    [73]  = 1, -- Warrior Protection
    [104] = 1, -- Druid Guardian
    [66]  = 1, -- Paladin Protection
    [268] = 1, -- Monk Brewmaster
    
    -- MELEE DPS (role 2)
    [259] = 2, -- Rogue Assassination
    [260] = 2, -- Rogue Outlaw
    [261] = 2, -- Rogue Subtlety
    [103] = 2, -- Druid Feral
    [269] = 2, -- Monk Windwalker
    [251] = 2, -- Death Knight Frost
    [252] = 2, -- Death Knight Unholy
    [577] = 2, -- Demon Hunter Havoc 
    [71]  = 2, -- Warrior Arms
    [72]  = 2, -- Warrior Fury
    [70]  = 2, -- Paladin Retribution
    [255] = 2, -- Hunter Survival
    [263] = 2, -- Shaman Enhancement
    
    -- HEALERS (role 3)
    [65]   = 3, -- Paladin Holy
    [105]  = 3, -- Druid Restoration
    [270]  = 3, -- Monk Mistweaver 
    [257]  = 3, -- Priest Holy
    [256]  = 3, -- Priest Discipline
    [264]  = 3, -- Shaman Restoration
    [1468] = 3, -- Evoker Preservation
    
    -- RANGED DPS (role 4)
    [102]  = 4, -- Druid Balance
    [253]  = 4, -- Hunter Beast Mastery
    [254]  = 4, -- Hunter Marksmanship
    [62]   = 4, -- Mage Arcane
    [63]   = 4, -- Mage Fire
    [64]   = 4, -- Mage Frost
    [258]  = 4, -- Priest Shadow
    [262]  = 4, -- Shaman Elemental
    [265]  = 4, -- Warlock Affliction
    [266]  = 4, -- Warlock Demonology
    [267]  = 4, -- Warlock Destruction
    [1467] = 4, -- Evoker Devastation
    [1473] = 4, -- Evoker Augmentation
}

-- Cache for spec data by player name (persists across sorts)
SecureSort.specCache = {}

-- Queue for players who need inspection
SecureSort.inspectQueue = {}
SecureSort.inspectInProgress = false

-- A unit's GUID can be a SECRET value in 12.0 (e.g. M+ encounters) and a secret
-- cannot be used as a table key — doing so throws "cannot be indexed with secret
-- keys". The inspect queue is keyed by GUID and matched back against the GUID
-- delivered by INSPECT_READY, so a unit-token fallback would never match; instead
-- we skip queuing/handling units whose GUID isn't accessible.
local issecretvalue = issecretvalue or function() return false end
local function canaccessvalue(v)
    return v ~= nil and not issecretvalue(v)
end

-- ============================================================
-- DEBUG UTILITIES
-- ============================================================

-- Routed to the debug console's SECURESORT category. Every DebugPrint call site
-- in this file feeds this one helper, so the console is the single place to
-- turn them on or off.
local DebugPrint = DF:MakeDebugPrinter("SECURESORT")

-- ============================================================
-- ☠ THE SECURE HANDLER IS GONE -- READ THIS BEFORE ADDING ONE BACK
-- ============================================================
-- CreateHandler and everything that fed it stood here: the secure-handler
-- snippets, the test UI and test buttons, SetSecurePath, RegisterSnippet,
-- PushSortSettings, PushPartyUnitNames, TriggerSecureSort, and the
-- SecureDebugCallback that secure code called back into.
--
-- None of it ever ran. The handler is built only by SecureSort:Initialize, and
-- Initialize has no reachable caller: both of its entries require DF.initialized
-- to be true in the one state (DF.headersCreated == false) where DF.initialized
-- can never have been set, because the sole writer of that flag --
-- DF:FinalizeHeaderInit in Frames/Headers.lua -- returns early unless
-- headersCreated is true. So self.handler stayed nil for the whole session and
-- every push/trigger in this module returned false at its first guard.
--
-- Frames are positioned by SecureGroupHeaderTemplate, driven from
-- Frames/Headers.lua. What survives in THIS file is only what other files
-- actually consume: the geometry calculators, the layout-param builders, and
-- the spec/inspect cache below.
--
-- ⚠ If a secure handler is ever wanted again, give it a reachable init path
-- FIRST. Re-adding the machinery without one just recreates 2,000 dead lines.

-- ============================================================
-- SPECIALIZATION CACHING SYSTEM
-- ============================================================
-- Cache player specs out of combat for melee/ranged DPS distinction
-- Uses inspection API to get spec IDs, maps to detailed roles

-- Get unit name in format suitable for caching (handles cross-realm)
local function GetCacheableName(unit)
    local name = GetUnitName(unit, true)  -- returns "Name-Realm" directly, avoids secret string taint
    return name
end

-- Get detailed role from spec ID (1=Tank, 2=Melee, 3=Healer, 4=Ranged)
function SecureSort:GetSpecRole(specID)
    return SPEC_ROLE[specID] or 0  -- 0 = unknown
end

-- Cache the spec for a unit (called when we get spec info)
function SecureSort:CacheUnitSpec(unit, specID)
    local name = GetCacheableName(unit)
    if not name then return end
    
    local role = self:GetSpecRole(specID)
    if role > 0 then
        self.specCache[name] = {
            specID = specID,
            role = role,  -- 1=Tank, 2=Melee, 3=Healer, 4=Ranged
        }
        -- Spec cached (debug removed - too spammy)
    end
end

-- Get cached spec role for a unit (returns 0 if not cached)
function SecureSort:GetCachedSpecRole(unit)
    local name = GetCacheableName(unit)
    if not name then return 0 end
    
    local cached = self.specCache[name]
    if cached then
        return cached.role
    end
    return 0
end

-- Queue a unit for inspection (to get their spec)
function SecureSort:QueueInspect(unit)
    if not UnitExists(unit) then return end
    if not UnitIsPlayer(unit) then return end
    if UnitIsUnit(unit, "player") then return end  -- Don't inspect self
    
    -- canaccessvalue also covers the nil case (a secret GUID can't be a table key)
    local guid = UnitGUID(unit)
    if not canaccessvalue(guid) then return end

    -- Don't queue if already cached
    local name = GetCacheableName(unit)
    if name and self.specCache[name] then return end

    -- Add to queue
    self.inspectQueue[guid] = unit
    
    -- Start inspection process if not already running
    if not self.inspectInProgress then
        self:ProcessInspectQueue()
    end
end

-- Process the inspection queue
function SecureSort:ProcessInspectQueue()
    if InCombatLockdown() then
        -- Wait for combat to end
        return
    end
    
    -- Get next unit from queue
    local guid, unit = next(self.inspectQueue)
    if not guid then
        self.inspectInProgress = false
        return
    end
    
    -- Verify unit still exists and matches GUID. The unit's LIVE GUID can have
    -- become secret since queuing (combat) — comparing a secret value throws,
    -- so an inaccessible live GUID counts as a mismatch (identity can't be
    -- verified; drop the entry and move on).
    local liveGuid = UnitGUID(unit)
    if not UnitExists(unit) or not canaccessvalue(liveGuid) or liveGuid ~= guid then
        self.inspectQueue[guid] = nil
        C_Timer.After(0.1, function() self:ProcessInspectQueue() end)
        return
    end
    
    -- Check if InspectFrame is open (don't interfere with player inspection)
    if InspectFrame and InspectFrame:IsShown() then
        C_Timer.After(2, function() self:ProcessInspectQueue() end)
        return
    end
    
    self.inspectInProgress = true
    
    -- Request inspection
    NotifyInspect(unit)
    
    -- Wait for result (handled by INSPECT_READY event)
end

-- Debounce party-sort re-runs driven by inspect results. Inspects arrive roughly
-- every 0.5s via ProcessInspectQueue; coalescing into a single sort avoids
-- Hide/Show flicker across all 4 party members' inspects.
function SecureSort:ScheduleInspectDrivenPartySort()
    if self.pendingInspectPartySortTimer then return end
    self.pendingInspectPartySortTimer = C_Timer.NewTimer(0.75, function()
        self.pendingInspectPartySortTimer = nil
        if InCombatLockdown() then
            self.pendingInspectPartySort = true
            return
        end
        if not IsInRaid() and DF.ApplyPartyGroupSorting then
            DF:ApplyPartyGroupSorting()
        end
    end)
end

-- Handle INSPECT_READY event
function SecureSort:OnInspectReady(guid)
    -- A secret GUID can't be a table key (and could never have been queued), so
    -- it can't be one of ours — skip before indexing the queue with it.
    if not canaccessvalue(guid) then return end
    -- Only process if this was an inspect WE initiated (guid is in our queue)
    local unit = self.inspectQueue[guid]
    if not unit then
        -- Not our inspect - don't interfere with user's manual inspection
        return
    end
    
    -- Process our queued inspect. Same live-GUID secrecy guard as
    -- ProcessInspectQueue: comparing a secret value throws.
    local liveGuid = UnitGUID(unit)
    if UnitExists(unit) and canaccessvalue(liveGuid) and liveGuid == guid then
        local specID = GetInspectSpecialization(unit)
        if specID and specID > 0 then
            self:CacheUnitSpec(unit, specID)
            
            -- Re-sort with the updated spec data if not in combat
            if not InCombatLockdown() then
                -- Notify FlatRaidFrames to re-sort with updated spec data
                -- Guard: only re-sort if flat mode is actually active (not grouped mode)
                if DF.FlatRaidFrames and DF.FlatRaidFrames.initialized then
                    local rdb = DF:GetRaidDB()
                    if rdb and not rdb.raidUseGroups then
                        DF.FlatRaidFrames:UpdateNameList()
                    else
                        DF:Debug("FLATRAID", "Skipping UpdateNameList from inspect: grouped mode active")
                    end
                end
                -- Re-apply party sorting so melee/ranged classification settles as inspects
                -- complete, instead of waiting for an unrelated roster/combat event.
                -- Debounced: inspects stream in ~0.5s apart, so coalesce into one sort.
                if not IsInRaid() and DF.ApplyPartyGroupSorting then
                    self:ScheduleInspectDrivenPartySort()
                end
            else
                -- Defer FlatRaidFrames re-sort until combat ends
                if DF.FlatRaidFrames and DF.FlatRaidFrames.initialized then
                    local rdb = DF:GetRaidDB()
                    if rdb and not rdb.raidUseGroups then
                        DF.FlatRaidFrames.pendingNameListUpdate = true
                    end
                end
                -- Defer party sort until combat ends
                if not IsInRaid() then
                    self.pendingInspectPartySort = true
                end
            end
        end
    end
    
    -- Remove from queue (only our inspects reach here)
    self.inspectQueue[guid] = nil
    
    -- Clear inspection (safe because this was our inspect)
    ClearInspectPlayer()
    
    -- Process next in queue after a delay
    C_Timer.After(0.5, function() self:ProcessInspectQueue() end)
end

-- Scan current group and queue inspections
function SecureSort:ScanGroupForSpecs()
    if InCombatLockdown() then return end
    
    -- Clear old queue
    wipe(self.inspectQueue)
    
    -- Cache player's own spec
    local playerSpecID = GetSpecializationInfo(GetSpecialization() or 0)
    if playerSpecID then
        self:CacheUnitSpec("player", playerSpecID)
    end
    
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) and not UnitIsUnit(unit, "player") then
                self:QueueInspect(unit)
            end
        end
    elseif IsInGroup() then
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                self:QueueInspect(unit)
            end
        end
    end
end

-- ============================================================
-- PHASE 2.5: SLOT-BASED POSITIONING SYSTEM
-- ============================================================
-- This system provides proper slot-based positioning that handles
-- all growth modes (START/CENTER/END) and both orientations
-- (horizontal/vertical). The same formula is used for both secure
-- and insecure (test mode) positioning.

-- ============================================================
-- SHARED POSITION CALCULATION (Insecure Lua)
-- ============================================================
-- This function calculates the offset for a given slot.
-- It's used by both the insecure PositionFrameToSlot() and
-- the secure snippet (which contains the same logic).

-- Calculate the offset for a slot position
-- @param slotIndex: 0-based slot index
-- @param frameCount: total number of visible frames (for CENTER calculation)
-- @param layoutParams: table with frameWidth, frameHeight, spacing, horizontal, growthAnchor
-- @return x, y offsets from container anchor
function SecureSort:CalculateSlotPosition(slotIndex, frameCount, layoutParams)
    local horizontal = layoutParams.horizontal
    local spacing = layoutParams.spacing or 2
    local frameWidth = layoutParams.frameWidth or 80
    local frameHeight = layoutParams.frameHeight or 40
    local growthAnchor = layoutParams.growthAnchor or "START"
    
    -- Calculate stride (distance between frame origins)
    local stride = horizontal and (frameWidth + spacing) or (frameHeight + spacing)
    
    -- Calculate offset based on growth anchor
    -- Note: For all anchors, slot 0 should be visually "first" (left for horizontal, top for vertical)
    -- The anchor determines alignment, NOT the direction of reading order
    local offset
    if growthAnchor == "START" then
        -- Frames aligned to start: slot 0 at offset 0, subsequent slots grow away
        offset = slotIndex * stride
    elseif growthAnchor == "END" then
        -- Frames aligned to end: slot n-1 at offset 0, slot 0 at far end
        -- Visual order is preserved (slot 0 still appears first visually)
        offset = -(frameCount - 1 - slotIndex) * stride
    else -- CENTER
        -- Frames grow from center: positions are centered around 0
        offset = (slotIndex - (frameCount - 1) / 2) * stride
    end
    
    -- Return x, y based on orientation
    if horizontal then
        return offset, 0
    else
        return 0, -offset  -- Negative Y for downward growth
    end
end

-- Get the anchor point based on layout params
-- @return anchor, relativeAnchor for SetPoint
function SecureSort:GetSlotAnchors(layoutParams)
    local horizontal = layoutParams.horizontal
    local growthAnchor = layoutParams.growthAnchor or "START"
    
    if horizontal then
        if growthAnchor == "START" then
            return "LEFT", "LEFT"
        elseif growthAnchor == "END" then
            return "RIGHT", "RIGHT"
        else -- CENTER
            return "CENTER", "CENTER"
        end
    else
        if growthAnchor == "START" then
            return "TOP", "TOP"
        elseif growthAnchor == "END" then
            return "BOTTOM", "BOTTOM"
        else -- CENTER
            return "CENTER", "CENTER"
        end
    end
end

-- ============================================================
-- RAID GRID POSITION CALCULATION (Flat Layout)
-- ============================================================
-- These functions calculate positions for raid frames in a 2D grid layout.
-- Used by both test mode (insecure) and secure code (same formula).

-- Calculate x, y position for a raid frame in a flat grid
-- @param slotIndex: 0-based slot index (0 to frameCount-1)
-- @param frameCount: total number of visible frames
-- @param layoutParams: raid layout configuration containing:
--   - frameWidth, frameHeight: frame dimensions
--   - hSpacing, vSpacing: horizontal and vertical spacing
--   - playersPerRow: number of players per row/column
--   - horizontal: true if primary direction is horizontal
--   - gridAnchor: "START", "CENTER", or "END"
--   - reverseFill: if true, reverse fill order within rows/columns
-- @return x, y offsets from the anchor point
function SecureSort:CalculateRaidSlotPosition(slotIndex, frameCount, layoutParams)
    local frameWidth = layoutParams.frameWidth or 80
    local frameHeight = layoutParams.frameHeight or 35
    local hSpacing = layoutParams.hSpacing or 2
    local vSpacing = layoutParams.vSpacing or 2
    local playersPerRow = layoutParams.playersPerRow or 5
    local horizontal = layoutParams.horizontal

    -- growthAnchor: where the grid is positioned in container (mapped from START/CENTER/END)
    local growthAnchor = layoutParams.growthAnchor or "TOPLEFT"

    -- frameAnchor/columnAnchor: control fill direction within the grid
    -- frameAnchor = "END" reverses the primary fill axis (e.g. right-to-left instead of left-to-right)
    -- columnAnchor = "END" reverses the secondary axis (e.g. bottom-to-top instead of top-to-bottom)
    local frameAnchor = layoutParams.frameAnchor or "START"
    local columnAnchor = layoutParams.columnAnchor or "START"

    -- Grid cell dimensions for the VISIBLE frames. Mirrors how the live secure
    -- header wraps: playersPerRow units fill the primary axis, then wrap onto a
    -- new line on the secondary axis.
    local numCols, numRows
    if horizontal then
        numCols = math.min(playersPerRow, frameCount)
        numRows = math.ceil(frameCount / playersPerRow)
    else
        numRows = math.min(playersPerRow, frameCount)
        numCols = math.ceil(frameCount / playersPerRow)
    end

    -- Which visual cell (column from the left, row from the top) this slot fills.
    -- Fill direction is set ONLY by frameAnchor/columnAnchor — matching the live
    -- secure header's point / columnAnchorPoint (FlatRaidFrames.ApplyLayoutSettings)
    -- — and is INDEPENDENT of the growth anchor, which only decides where the whole
    -- grid sits. The previous code folded the anchors into the growth-anchor branch
    -- and mirrored END layouts, which is why test inverted vs live for End alignment.
    local cellCol, cellRow
    if horizontal then
        local u = slotIndex % playersPerRow                 -- position along the row (primary, X)
        local line = math.floor(slotIndex / playersPerRow)  -- which row (secondary, Y)
        cellCol = (frameAnchor == "END") and ((numCols - 1) - u) or u
        cellRow = (columnAnchor == "END") and ((numRows - 1) - line) or line
    else
        local u = slotIndex % playersPerRow                 -- position along the column (primary, Y)
        local line = math.floor(slotIndex / playersPerRow)  -- which column (secondary, X)
        cellRow = (frameAnchor == "END") and ((numRows - 1) - u) or u
        cellCol = (columnAnchor == "END") and ((numCols - 1) - line) or line
    end

    local cellX = cellCol * (frameWidth + hSpacing)   -- from the grid's left edge
    local cellY = cellRow * (frameHeight + vSpacing)  -- from the grid's top edge
    local gridWidth = numCols * frameWidth + (numCols - 1) * hSpacing
    local gridHeight = numRows * frameHeight + (numRows - 1) * vSpacing

    -- Offset from the growth-anchor corner. The grid box is pinned by that corner to
    -- the same corner of the container (GetRaidSlotAnchors returns growthAnchor for
    -- both frame and container), exactly like the live inner container, so the grid
    -- hugs that corner regardless of container size.
    local x, y
    if growthAnchor == "CENTER" then
        x = cellX + (frameWidth / 2) - (gridWidth / 2)
        y = (gridHeight / 2) - cellY - (frameHeight / 2)
    elseif growthAnchor == "TOPRIGHT" then
        x = -(gridWidth - cellX - frameWidth)
        y = -cellY
    elseif growthAnchor == "BOTTOMLEFT" then
        x = cellX
        y = gridHeight - cellY - frameHeight
    elseif growthAnchor == "BOTTOMRIGHT" then
        x = -(gridWidth - cellX - frameWidth)
        y = gridHeight - cellY - frameHeight
    else
        -- TOPLEFT (and any legacy/default value)
        x = cellX
        y = -cellY
    end

    return x, y
end

-- Get anchor points for raid grid layout
-- @param layoutParams: layout configuration with growthAnchor
-- @return anchor, relativeAnchor for SetPoint
function SecureSort:GetRaidSlotAnchors(layoutParams)
    -- growthAnchor determines WHERE the grid is positioned in the container
    -- We use the same anchor for both frame and container
    local growthAnchor = layoutParams.growthAnchor or "TOPLEFT"
    return growthAnchor, growthAnchor
end

-- ============================================================
-- INSECURE POSITIONING (for Test Mode)
-- ============================================================
-- These functions position frames directly using regular SetPoint().
-- Used when NOT in combat and for test mode frames.

-- Position a single frame to a slot (insecure - for test mode)
-- @param frame: the frame to position
-- @param slotIndex: 0-based slot index
-- @param frameCount: total visible frame count
-- @param layoutParams: layout configuration
-- @param container: the container frame to anchor to
function SecureSort:PositionFrameToSlot(frame, slotIndex, frameCount, layoutParams, container)
    if not frame or not container then
        DebugPrint("ERROR: PositionFrameToSlot - frame or container is nil")
        return false
    end
    
    local x, y = self:CalculateSlotPosition(slotIndex, frameCount, layoutParams)
    local anchor, relativeAnchor = self:GetSlotAnchors(layoutParams)
    
    frame:ClearAllPoints()
    frame:SetPoint(anchor, container, relativeAnchor, x, y)
    -- Pixel-perfect: land the frame's edges on the physical grid. The CENTER growth
    -- anchor computes offsets via /2, which can fall on a half-pixel and make a 1px
    -- border straddle two physical rows; this nudges it back on-grid (bounded ≤0.5px).
    DF:SnapPointToPixelGrid(frame, (DF:GetFrameDB(frame) or {}).pixelPerfect)

    DF:Debug("SECURESORT", "Positioned frame to slot %s at (%s, %s)", slotIndex, x, y)
    return true
end

-- ============================================================
-- RAID INSECURE POSITIONING (for Test Mode)
-- ============================================================
-- Position raid frames using the grid calculation functions.
-- Used for test mode where we don't need secure code.

-- Position a single raid frame to a grid slot (insecure - for test mode)
-- @param frame: the frame to position
-- @param slotIndex: 0-based slot index
-- @param frameCount: total visible frame count
-- @param layoutParams: raid layout configuration
-- @param container: the container frame to anchor to
-- @return true if positioned, false if skipped (no change needed)
function SecureSort:PositionRaidFrameToSlot(frame, slotIndex, frameCount, layoutParams, container)
    if not frame or not container then
        return false
    end

    -- DOOR-SHUT backstop (flat): mirror the grouped positioner. The live flat raid
    -- frames are children of the FlatRaidFrames secure header; this Lua per-frame
    -- positioner is for TEST frames (DF.testRaidContainer) only. Refuse any call
    -- that targets the live container so test mode can never drive live frames.
    if container == DF.raidContainer then
        return false
    end

    local x, y = self:CalculateRaidSlotPosition(slotIndex, frameCount, layoutParams)
    local anchor, relativeAnchor = self:GetRaidSlotAnchors(layoutParams)
    
    -- Optimization: Check if frame is already at this position
    local currentAnchor, currentRelTo, currentRelAnchor, currentX, currentY = frame:GetPoint(1)
    if currentAnchor == anchor and currentRelAnchor == relativeAnchor 
       and currentX and currentY
       and math.abs(currentX - x) <= 0.5 and math.abs(currentY - y) <= 0.5 then
        -- Frame is already in position, skip
        return false
    end
    
    frame:ClearAllPoints()
    frame:SetPoint(anchor, container, relativeAnchor, x, y)
    -- Pixel-perfect: land the frame's edges on the physical grid. The CENTER grid
    -- anchor computes offsets via /2, which can fall on a half-pixel and make a 1px
    -- border straddle two physical rows; this nudges it back on-grid (bounded ≤0.5px).
    DF:SnapPointToPixelGrid(frame, (DF:GetFrameDB(frame) or {}).pixelPerfect)

    return true
end

-- ============================================================
-- LAYOUT PARAMETERS
-- ============================================================
-- Store current layout parameters for secure code access

SecureSort.layoutParams = {
    frameWidth = 80,
    frameHeight = 40,
    spacing = 2,
    horizontal = false,  -- Default vertical
    growthAnchor = "START",
}

-- Update layout parameters from DF settings
function SecureSort:UpdateLayoutParams(mode)
    mode = mode or "party"  -- Default to party
    local db = DF:GetDB(mode)
    if not db then
        DF:Debug("SECURESORT", "WARNING: No db for mode '%s', using defaults", mode)
        return
    end
    
    self.layoutParams = {
        frameWidth = db.frameWidth or 80,
        frameHeight = db.frameHeight or 40,
        spacing = db.frameSpacing or 2,
        horizontal = db.growDirection == "HORIZONTAL",
        growthAnchor = db.growthAnchor or "START",
    }
    
    -- Apply pixel-perfect adjustments if enabled
    if db.pixelPerfect and DF.PixelPerfect then
        self.layoutParams.frameWidth = DF:PixelPerfect(self.layoutParams.frameWidth)
        self.layoutParams.frameHeight = DF:PixelPerfect(self.layoutParams.frameHeight)
        self.layoutParams.spacing = DF:PixelPerfect(self.layoutParams.spacing)
    end
    
    -- ☠ Three pushes into the secure environment followed here
    -- (SetLayoutParamsSecure, UpdateLayoutParamsOnButtons, PushSortSettings).
    -- They are gone with the handler. This function's remaining job is to fill
    -- self.layoutParams, which the test mode reads directly.
end

-- Map simplified growth anchor (START/CENTER/END) to WoW anchor points
-- The mapping depends on orientation (horizontal = Rows, not horizontal = Columns)
-- Rows: START → TOPLEFT, CENTER → CENTER, END → BOTTOMLEFT
-- Columns: START → TOPLEFT, CENTER → CENTER, END → TOPRIGHT
function SecureSort:MapGrowthAnchor(growthAnchor, horizontal)
    if growthAnchor == "START" then
        return "TOPLEFT"
    elseif growthAnchor == "CENTER" then
        return "CENTER"
    elseif growthAnchor == "END" then
        -- End position depends on orientation
        if horizontal then
            -- Rows: End means bottom-left
            return "BOTTOMLEFT"
        else
            -- Columns: End means top-right
            return "TOPRIGHT"
        end
    else
        -- Legacy values or direct anchor points - pass through
        return growthAnchor
    end
end

-- Update raid layout parameters from DF settings
function SecureSort:UpdateRaidLayoutParams()
    local db = DF:GetRaidDB()
    if not db then
        DebugPrint("WARNING: No raid db, using defaults")
        return
    end
    
    local horizontal = db.growDirection == "HORIZONTAL"
    local frameAnchor = db.raidFlatFrameAnchor or "START"
    local columnAnchor = db.raidFlatColumnAnchor or "START"
    
    -- Calculate headerAnchorPoint to match FlatRaidFrames exactly
    local headerAnchorPoint
    if horizontal then
        -- Horizontal: frameAnchor controls left/right, columnAnchor controls top/bottom
        if frameAnchor == "END" then
            headerAnchorPoint = (columnAnchor == "END") and "BOTTOMRIGHT" or "TOPRIGHT"
        else
            headerAnchorPoint = (columnAnchor == "END") and "BOTTOMLEFT" or "TOPLEFT"
        end
    else
        -- Vertical: frameAnchor controls top/bottom, columnAnchor controls left/right
        if frameAnchor == "END" then
            headerAnchorPoint = (columnAnchor == "END") and "BOTTOMRIGHT" or "BOTTOMLEFT"
        else
            headerAnchorPoint = (columnAnchor == "END") and "TOPRIGHT" or "TOPLEFT"
        end
    end
    
    self.raidLayoutParams = {
        frameWidth = db.frameWidth or 80,
        frameHeight = db.frameHeight or 35,
        hSpacing = db.raidFlatHorizontalSpacing or 2,
        vSpacing = db.raidFlatVerticalSpacing or 2,
        playersPerRow = db.raidPlayersPerRow or 5,
        horizontal = horizontal,
        -- FlatRaidFrames-compatible settings
        frameAnchor = frameAnchor,
        columnAnchor = columnAnchor,
        -- Map simplified growthAnchor (START/CENTER/END) to WoW anchor points
        growthAnchor = self:MapGrowthAnchor(db.raidFlatGrowthAnchor or "START", horizontal),
        -- Computed anchor point for frame positioning (matches FlatRaidFrames GetHeaderAnchorPoint)
        headerAnchorPoint = headerAnchorPoint,
        -- ☠ SEPARATE VOCABULARY FROM growthAnchor ABOVE, AND BOTH ARE NEEDED. The flat
        -- snippet compares lc.gridAnchor against "START"/"CENTER"/"END", so it cannot be
        -- given a mapped WoW anchor point. This table REPLACES raidLayoutParams wholesale,
        -- so the static gridAnchor/reverseFill defaults further down were shadowed off and
        -- PushRaidLayoutConfig pushed a permanent "START"/false -- the flat snippet ignored
        -- Grid Alignment and Reverse Fill entirely. Same class of gap as groupRowGrowth in
        -- 0af5f379: the setting existed, the push dropped it.
        gridAnchor = db.raidFlatGrowthAnchor or "START",
        reverseFill = db.raidFlatReverseFillOrder and true or false,
    }
    
    -- Apply pixel-perfect adjustments if enabled
    if db.pixelPerfect and DF.PixelPerfect then
        self.raidLayoutParams.frameWidth = DF:PixelPerfect(self.raidLayoutParams.frameWidth)
        self.raidLayoutParams.frameHeight = DF:PixelPerfect(self.raidLayoutParams.frameHeight)
        self.raidLayoutParams.hSpacing = DF:PixelPerfect(self.raidLayoutParams.hSpacing)
        self.raidLayoutParams.vSpacing = DF:PixelPerfect(self.raidLayoutParams.vSpacing)
    end
    
    if DF:DebugActive("SECURESORT") then
        DebugPrint("Raid layout params updated: " .. 
            self.raidLayoutParams.frameWidth .. "x" .. self.raidLayoutParams.frameHeight .. 
            " hSpacing=" .. self.raidLayoutParams.hSpacing ..
            " vSpacing=" .. self.raidLayoutParams.vSpacing ..
            " playersPerRow=" .. self.raidLayoutParams.playersPerRow ..
            " horizontal=" .. tostring(self.raidLayoutParams.horizontal) ..
            " headerAnchorPoint=" .. self.raidLayoutParams.headerAnchorPoint)
    end
    
    -- Note: Secure environment is updated via PushRaidLayoutConfig() which is called
    -- separately when triggering secure raid sort
end

-- ============================================================
-- RAID GROUP LAYOUT PARAMETERS
-- ============================================================
-- Store current raid GROUP layout parameters for test mode and secure code access

SecureSort.raidGroupLayoutParams = {
    frameWidth = 80,
    frameHeight = 35,
    playerSpacing = 2,           -- Spacing between players within a group
    groupSpacing = 10,           -- Spacing between groups in same row/column
    rowColSpacing = 15,          -- Spacing between rows/columns of groups
    groupsPerRowCol = 2,         -- Number of groups per row (horizontal) or column (vertical)
    horizontal = true,           -- Direction players fill within group (HORIZONTAL = left-to-right)
    groupAnchor = "CENTER",      -- How groups are anchored (START/CENTER/END)
    playerAnchor = "START",      -- How players are anchored within group slot (START/CENTER/END)
}

-- Update raid GROUP layout parameters from DF settings
function SecureSort:UpdateRaidGroupLayoutParams()
    local db = DF:GetRaidDB()
    if not db then
        DebugPrint("WARNING: No raid db, using defaults for group layout")
        -- [LEAK-TEST] Early-return case: shared table NOT replaced, stale fields survive.
        if DF.debugLeakTest then
            DF:Say(string.format(
                "LEAK-TEST: UpdateRaidGroupLayoutParams EARLY RETURN (no db) -- table NOT replaced. Existing testMode=%s",
                tostring(self.raidGroupLayoutParams and self.raidGroupLayoutParams.testMode)
            ))
        end
        return
    end

    -- [LEAK-TEST] About to replace shared table. Capture existing testMode so we can prove
    -- whether fields survive the assignment at the next line.
    if DF.debugLeakTest then
        DF:Say(string.format(
            "LEAK-TEST: UpdateRaidGroupLayoutParams REPLACING table  old.testMode=%s",
            tostring(self.raidGroupLayoutParams and self.raidGroupLayoutParams.testMode)
        ))
    end

    self.raidGroupLayoutParams = {
        frameWidth = db.frameWidth or 80,
        frameHeight = db.frameHeight or 40,
        playerSpacing = db.frameSpacing or 2,
        groupSpacing = db.raidGroupSpacing or 10,
        rowColSpacing = db.raidRowColSpacing or 30,
        groupsPerRowCol = db.raidGroupsPerRow or 8,
        horizontal = db.growDirection == "HORIZONTAL",
        groupAnchor = db.raidGroupAnchor or "START",
        playerAnchor = db.raidPlayerAnchor or "START",
        groupRowGrowth = db.raidGroupRowGrowth or "START",
    }
    
    -- Apply pixel-perfect adjustments if enabled
    if db.pixelPerfect and DF.PixelPerfect then
        self.raidGroupLayoutParams.frameWidth = DF:PixelPerfect(self.raidGroupLayoutParams.frameWidth)
        self.raidGroupLayoutParams.frameHeight = DF:PixelPerfect(self.raidGroupLayoutParams.frameHeight)
        self.raidGroupLayoutParams.playerSpacing = DF:PixelPerfect(self.raidGroupLayoutParams.playerSpacing)
        self.raidGroupLayoutParams.groupSpacing = DF:PixelPerfect(self.raidGroupLayoutParams.groupSpacing)
        self.raidGroupLayoutParams.rowColSpacing = DF:PixelPerfect(self.raidGroupLayoutParams.rowColSpacing)
    end
    
    if DF:DebugActive("SECURESORT") then
        DebugPrint("Raid GROUP layout params updated: " .. 
            self.raidGroupLayoutParams.frameWidth .. "x" .. self.raidGroupLayoutParams.frameHeight .. 
            " playerSpacing=" .. self.raidGroupLayoutParams.playerSpacing ..
            " groupSpacing=" .. self.raidGroupLayoutParams.groupSpacing ..
            " rowColSpacing=" .. self.raidGroupLayoutParams.rowColSpacing ..
            " groupsPerRowCol=" .. self.raidGroupLayoutParams.groupsPerRowCol ..
            " horizontal=" .. tostring(self.raidGroupLayoutParams.horizontal))
    end
end

-- Calculate group-based position for a frame
-- @param groupNum: group number (1-8)
-- @param posInGroup: position within group (0-4)
-- @param playersInGroup: actual number of players in this group
-- @param activeGroupList: ordered list of active (non-empty) group numbers
-- @param layoutParams: group layout parameters
-- @return x, y offsets from container TOPLEFT
function SecureSort:CalculateRaidGroupPosition(groupNum, posInGroup, playersInGroup, activeGroupList, layoutParams)
    local lp = layoutParams
    local frameWidth = lp.frameWidth
    local frameHeight = lp.frameHeight
    local playerSpacing = lp.playerSpacing
    local groupSpacing = lp.groupSpacing
    local rowColSpacing = lp.rowColSpacing
    local groupsPerRowCol = lp.groupsPerRowCol
    local horizontal = lp.horizontal
    local groupAnchor = lp.groupAnchor
    local playerAnchor = lp.playerAnchor

    -- ============================================================
    -- Mirror the LIVE grouped positioner exactly so test == live:
    --   * the secure snippet (Headers.lua position snippet) anchors each group
    --     header (groupAnchor Start/Center/End, groupRowGrowth flip over the full
    --     8-group grid, and playerAnchor=END shifting the group's anchor corner to
    --     BOTTOMLEFT (horizontal) / TOPRIGHT (vertical) so partial groups bottom/
    --     right-align), and
    --   * the SecureGroupHeaderTemplate stacks players WITHIN a header — always
    --     top->down (horizontal) / left->right (vertical), regardless of playerAnchor.
    -- Computed with y DOWN-positive, returned as a TOPLEFT offset (x, -yDown).
    -- ============================================================
    local groupW, groupH
    if horizontal then
        groupW = frameWidth
        groupH = 5 * frameHeight + 4 * playerSpacing
    else
        groupW = 5 * frameWidth + 4 * playerSpacing
        groupH = frameHeight
    end

    -- This group's display slot (1-based) among active groups
    local slot = 0
    for idx, g in ipairs(activeGroupList) do
        if g == groupNum then slot = idx; break end
    end
    if slot == 0 then return 0, 0 end
    local numPop = #activeGroupList

    local fullGridRC = math.ceil(8 / groupsPerRowCol)
    local totalWidth, totalHeight
    if horizontal then
        totalWidth = groupsPerRowCol * groupW + (groupsPerRowCol - 1) * groupSpacing
        totalHeight = fullGridRC * groupH + (fullGridRC - 1) * rowColSpacing
    else
        totalWidth = fullGridRC * groupW + (fullGridRC - 1) * rowColSpacing
        totalHeight = groupsPerRowCol * groupH + (groupsPerRowCol - 1) * groupSpacing
    end

    -- Populated grid extent (drives CENTER alignment + the END-row offset), matching the snippet
    local popRem = numPop % groupsPerRowCol
    local popRows = (numPop > 0) and math.ceil(numPop / groupsPerRowCol) or 0
    local popCols
    if numPop > 0 and numPop < groupsPerRowCol then popCols = numPop
    elseif numPop > 0 then popCols = groupsPerRowCol
    else popCols = 0 end
    local populatedWidth, populatedHeight
    if horizontal then
        populatedWidth = (popCols > 0) and (popCols * groupW + (popCols - 1) * groupSpacing) or 0
        populatedHeight = (popRows > 0) and (popRows * groupH + (popRows - 1) * rowColSpacing) or 0
    else
        populatedWidth = (popRows > 0) and (popRows * groupW + (popRows - 1) * rowColSpacing) or 0
        populatedHeight = (popCols > 0) and (popCols * groupH + (popCols - 1) * groupSpacing) or 0
    end

    local slotIndex = slot - 1
    local rcIdx = math.floor(slotIndex / groupsPerRowCol)
    local posInRC = slotIndex % groupsPerRowCol
    local isPartialRow = (popRem > 0 and rcIdx == popRows - 1)
    local groupRowGrowth = lp.groupRowGrowth or "START"
    if groupRowGrowth == "END" then
        rcIdx = (fullGridRC - 1) - rcIdx
    end
    local gInRC = isPartialRow and popRem or groupsPerRowCol

    -- Group order is driven SOLELY by activeGroupList (Group Display Order /
    -- My Group First, via DF:GetEffectiveRaidGroupOrder). The legacy
    -- raidGroupOrder == "REVERSE" toggle is deprecated (no GUI; superseded by the
    -- display-order feature) and is intentionally NOT applied here -- the live
    -- header positioner (Headers.lua:UpdateRaidPositionAttributes) never honoured
    -- it, so honouring it here made test/legacy disagree with live. gInRC is still
    -- the row/column population used by the groupAnchor END/CENTER offsets below.

    local x, yDown
    if horizontal then
        local xOff = posInRC * (groupW + groupSpacing)
        local yOff = rcIdx * (groupH + rowColSpacing)
        if groupAnchor == "END" then
            local rcW = gInRC * groupW + (gInRC - 1) * groupSpacing
            xOff = (totalWidth - rcW) + posInRC * (groupW + groupSpacing)
        elseif groupAnchor == "CENTER" then
            local rcW = gInRC * groupW + (gInRC - 1) * groupSpacing
            xOff = (totalWidth - rcW) / 2 + posInRC * (groupW + groupSpacing)
            -- ☠ Mirrors the header snippet's CENTER correction. rcIdx was already flipped
            -- over fullGridRC, and adding that to a block that is already centred on the
            -- wrap axis compounds -- one populated row in a two-row grid landed half a
            -- group plus half the wrap spacing outside the container. Recover the
            -- populated-row index: (popRows-1) - ((fullGridRC-1) - rcIdx).
            local rcCentered = rcIdx
            if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
            yOff = (totalHeight - populatedHeight) / 2 + rcCentered * (groupH + rowColSpacing)
        end
        x = xOff
        local hdrTop
        if playerAnchor == "END" then
            -- group anchored BOTTOMLEFT: header bottom sits at (totalHeight - yOff)
            local actualGroupHeight = playersInGroup * frameHeight + (playersInGroup - 1) * playerSpacing
            hdrTop = (totalHeight - yOff) - actualGroupHeight
        else
            hdrTop = yOff
        end
        yDown = hdrTop + posInGroup * (frameHeight + playerSpacing)
    else
        local xOff = rcIdx * (groupW + rowColSpacing)
        local yOff = posInRC * (groupH + groupSpacing)
        if groupAnchor == "END" then
            local rcH = gInRC * groupH + (gInRC - 1) * groupSpacing
            yOff = (totalHeight - rcH) + posInRC * (groupH + groupSpacing)
        elseif groupAnchor == "CENTER" then
            local rcH = gInRC * groupH + (gInRC - 1) * groupSpacing
            yOff = (totalHeight - rcH) / 2 + posInRC * (groupH + groupSpacing)
            -- Same correction, wrap axis is X in vertical growth.
            local rcCentered = rcIdx
            if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
            xOff = (totalWidth - populatedWidth) / 2 + rcCentered * (groupW + rowColSpacing)
        end
        yDown = yOff
        local hdrLeft
        if playerAnchor == "END" then
            -- group anchored TOPRIGHT: header right sits at (totalWidth - xOff)
            local actualGroupWidth = playersInGroup * frameWidth + (playersInGroup - 1) * playerSpacing
            hdrLeft = (totalWidth - xOff) - actualGroupWidth
        else
            hdrLeft = xOff
        end
        x = hdrLeft + posInGroup * (frameWidth + playerSpacing)
    end

    local retY = -yDown

    -- ═══ RETIRED 2026-08-15: the lp.testMode CENTER compensation block (#867). ═══
    -- It folded the container's CENTER shift into TEST FRAME offsets because the test
    -- container was "intentionally left uncompensated" while live's container carried
    -- the shift. That split accounting is what made the unlock overlay unfaithful:
    -- the mover was sized/positioned from the container, and in test mode the frames
    -- drifted half a group-row out of the box it drew (Aphoex, 2026-08-15,
    -- groups-per-row < 8). The compensation now lives in exactly ONE place —
    -- DF:UpdateRaidContainerPosition applies ComputeRaidContainerCompensation (now
    -- test-aware) to the live container, the TEST container and the MOVER alike — so
    -- this calculator returns raw grid offsets in every mode and the preview differs
    -- from live in data only. ⚠ lp.testMode is now DEBUG-ONLY: the claim that used to sit
    -- here -- that PositionRaidFrameToGroupSlot still reads it for a playerAnchor=END
    -- BOTTOMLEFT mirror (#875) -- is false. Grep .testMode in this file: every remaining
    -- read is the LEAK-TEST print and the two params-swap log lines. The END mirror is
    -- driven by playerAnchor itself, not by the mode. Keep the field for the leak test;
    -- do not build anything on it.

    return x, retY
end

-- Calculate container size for group-based layout
-- @param activeGroupCount: number of active (non-empty) groups
-- @param layoutParams: group layout parameters
-- @return totalWidth, totalHeight
function SecureSort:CalculateRaidGroupContainerSize(activeGroupCount, layoutParams)
    local lp = layoutParams
    local frameWidth = lp.frameWidth
    local frameHeight = lp.frameHeight
    local playerSpacing = lp.playerSpacing
    local groupSpacing = lp.groupSpacing
    local rowColSpacing = lp.rowColSpacing
    local groupsPerRowCol = lp.groupsPerRowCol
    local horizontal = lp.horizontal
    
    -- Calculate max group dimensions
    local maxGroupWidth, maxGroupHeight
    if horizontal then
        maxGroupWidth = frameWidth
        maxGroupHeight = 5 * frameHeight + 4 * playerSpacing
    else
        maxGroupWidth = 5 * frameWidth + 4 * playerSpacing
        maxGroupHeight = frameHeight
    end
    
    -- Calculate grid dimensions for 8 groups (fixed, so dragging works)
    local totalGroups = 8
    local numRowsCols = math.ceil(totalGroups / groupsPerRowCol)
    local maxCols = horizontal and groupsPerRowCol or numRowsCols
    local maxRows = horizontal and numRowsCols or groupsPerRowCol
    
    local totalWidth, totalHeight
    if horizontal then
        totalWidth = maxCols * maxGroupWidth + (maxCols - 1) * groupSpacing
        totalHeight = maxRows * maxGroupHeight + (maxRows - 1) * rowColSpacing
    else
        totalWidth = maxCols * maxGroupWidth + (maxCols - 1) * rowColSpacing
        totalHeight = maxRows * maxGroupHeight + (maxRows - 1) * groupSpacing
    end
    
    return totalWidth, totalHeight
end

-- Position a raid frame using group-based layout
-- @param frame: the frame to position
-- @param groupNum: which group (1-8) this frame belongs to
-- @param posInGroup: position within the group (0-4)
-- @param playersInGroup: how many players are in this group
-- @param activeGroupList: ordered list of active group numbers
-- @param layoutParams: group layout parameters
-- @param container: the container frame
-- @return true if frame was moved, false if already in position
function SecureSort:PositionRaidFrameToGroupSlot(frame, groupNum, posInGroup, playersInGroup, activeGroupList, layoutParams, container)
    -- [LEAK-TEST] Instrumentation: per-call visibility into which frames use this function
    -- and whether the testMode flag leaks onto the shared table. Toggle:
    --   /run DandersFrames.debugLeakTest = true
    if DF.debugLeakTest then
        local frameName = (frame and frame.GetName and frame:GetName()) or "?"
        local containerName = (container and container.GetName and container:GetName()) or "?"
        local isTestFrame = frame and frame.dfIsTestFrame and true or false
        DF:Say(string.format(
            "LEAK-TEST: PositionRaidFrameToGroupSlot frame=%s container=%s dfIsTestFrame=%s lp.testMode=%s DF.raidTestMode=%s",
            tostring(frameName),
            tostring(containerName),
            tostring(isTestFrame),
            tostring(layoutParams and layoutParams.testMode),
            tostring(DF.raidTestMode)
        ))
    end

    if not frame or not container then
        return false
    end

    -- DOOR-SHUT backstop: this legacy Lua per-frame positioner must NEVER drive
    -- LIVE raid frames. In header mode the live frames are children of the secure
    -- group headers (positioned by the secure header path); only TEST frames
    -- (passed with DF.testRaidContainer) or genuinely headerless legacy frames may
    -- use this. The live container + active headers => a live header frame slipped
    -- through; refuse it so test mode can never corrupt live.
    if container == DF.raidContainer and DF.raidSeparatedHeaders then
        return false
    end

    local x, y = self:CalculateRaidGroupPosition(groupNum, posInGroup, playersInGroup, activeGroupList, layoutParams)

    -- Anchor TOPLEFT, identical to the in-combat secure snippet. (An older
    -- test-only BOTTOMLEFT conversion lived here, meant to "mirror live" for
    -- playerAnchor=END — but it resolved to an identical on-screen position, i.e.
    -- a no-op, and was premised on a Y-flip that never actually happened. Removed,
    -- so test and live use the exact same anchor and offset.)
    local currentAnchor, _, currentRelAnchor, currentX, currentY = frame:GetPoint(1)
    if currentAnchor == "TOPLEFT" and currentRelAnchor == "TOPLEFT"
       and currentX and currentY
       and math.abs(currentX - x) <= 0.5 and math.abs(currentY - y) <= 0.5 then
        return false
    end

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", container, "TOPLEFT", x, y)
    -- Pixel-perfect: land the frame's edges on the physical grid (no-op for the
    -- TOPLEFT stride math, but keeps grouped test frames consistent with party/flat
    -- and covers any CENTER growth-anchor offset that lands on a half-pixel).
    DF:SnapPointToPixelGrid(frame, (DF:GetFrameDB(frame) or {}).pixelPerfect)

    return true
end

-- ============================================================
-- EVENT HANDLING FOR RESORT ON GROUP CHANGES
-- ============================================================
-- Watch GROUP_ROSTER_UPDATE to resort when party composition changes

local roleUpdateFrame = CreateFrame("Frame")
roleUpdateFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
roleUpdateFrame:RegisterEvent("INSPECT_READY")
roleUpdateFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
roleUpdateFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
roleUpdateFrame:SetScript("OnEvent", function(self, event, arg1)
    -- Handle inspection results (always process - doesn't need SecureSort initialized)
    if event == "INSPECT_READY" then
        if arg1 then
            SecureSort:OnInspectReady(arg1)
        end
        return
    end
    
    -- Handle spec changes (always process - caches spec and triggers FlatRaidFrames re-sort)
    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Re-cache player spec
        local playerSpecID = GetSpecializationInfo(GetSpecialization() or 0)
        if playerSpecID then
            SecureSort:CacheUnitSpec("player", playerSpecID)
        end
        -- Re-sort with the updated spec data
        if not InCombatLockdown() then
            -- Notify FlatRaidFrames to re-sort with updated spec data
            -- Guard: only re-sort if flat mode is actually active (not grouped mode)
            if DF.FlatRaidFrames and DF.FlatRaidFrames.initialized then
                local rdb = DF:GetRaidDB()
                if rdb and not rdb.raidUseGroups then
                    DF.FlatRaidFrames:UpdateNameList()
                else
                    DF:Debug("FLATRAID", "Skipping UpdateNameList from spec change: grouped mode active")
                end
            end
        end
        return
    end

    -- Handle group roster changes - scan new members for specs
    if event == "GROUP_ROSTER_UPDATE" then
        if not InCombatLockdown() then
            -- Delay slightly to let roster data settle
            C_Timer.After(0.5, function()
                if not InCombatLockdown() then
                    SecureSort:ScanGroupForSpecs()
                end
            end)
        end
        return
    end
    
    -- Handle combat end - process any pending operations
    if event == "PLAYER_REGEN_ENABLED" then
        -- Process pending inspect-driven party sort (inspects that resolved during combat)
        if SecureSort.pendingInspectPartySort and not IsInRaid() then
            SecureSort.pendingInspectPartySort = false
            if DF.ApplyPartyGroupSorting then
                DF:ApplyPartyGroupSorting()
                DebugPrint("Applied pending inspect-driven party sort after combat")
            end
        end
        
        -- Resume inspection queue after combat
        SecureSort:ProcessInspectQueue()
    end
end)

-- ============================================================
-- SPEC SCAN ON ENTERING WORLD
-- ============================================================
-- ☠ An AUTO-INITIALIZATION block stood here: an initFrame on ADDON_LOADED /
-- PLAYER_LOGIN / PLAYER_ENTERING_WORLD, a 20-attempt 0.05s polling ticker, and
-- TryInitialize / TryRegisterFrames / TryFullInit.
--
-- It could never succeed. TryInitialize's body ended in a bare `return false`,
-- under a comment saying SecureSort is disabled and Headers.lua handles sorting
-- via nameList-based SecureGroupHeaderTemplate. So initAttempted stayed false,
-- TryFullInit never advanced past the first step, and the login ticker just ran
-- its twenty attempts and cancelled itself, every login, for every user.
--
-- The one live thing that block did is kept below: seeding the spec cache once
-- roster data has arrived. Frames/Headers.lua and Features/FlatRaidFrames.lua
-- read SecureSort.specCache for the melee/ranged DPS split, so this is
-- load-bearing -- it is why the file still exists at all.

local specScanFrame = CreateFrame("Frame")
specScanFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
specScanFrame:SetScript("OnEvent", function()
    -- Delayed so roster data has arrived after the loading screen.
    C_Timer.After(2, function()
        if not InCombatLockdown() and (IsInGroup() or IsInRaid()) then
            SecureSort:ScanGroupForSpecs()
        end
    end)
end)

DebugPrint("SecureSort.lua loaded (geometry calculators + spec cache)")
