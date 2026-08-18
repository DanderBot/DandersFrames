local addonName, DF = ...

-- Header tracing, routed to the debug console's HEADERS category. This was 68
-- inline `if DF.debugHeaders then print(...) end` guards behind a chat-only
-- toggle; funnelling them through one printer makes the console the single
-- place to turn header logging on or off, and puts the output in the copyable
-- log instead of the chat frame.
local headerDebug = DF:MakeDebugPrinter("HEADERS")

-- ============================================================
-- SECURE GROUP HEADER MANAGEMENT
-- Manages SecureGroupHeaderTemplate for party/raid frames
-- ============================================================

-- Make addon accessible globally for XML OnLoad
DandersFrames = DF

-- Forward declaration (defined later, needed by ProcessRosterUpdate)
local IteratePinnedFrames

-- ============================================================
-- FRAME-BASED THROTTLING
-- Delays roster updates to next frame, automatically coalescing
-- multiple GROUP_ROSTER_UPDATE events into a single update.
-- Much better than C_Timer.After because:
-- 1. Waits for all events in this "batch" to process
-- 2. Showing an already-shown frame is a no-op (automatic dedup)
-- ============================================================
local rosterThrottleFrame = CreateFrame("Frame")
rosterThrottleFrame:Hide()
DF._rosterThrottleFrame = rosterThrottleFrame
local gruEventCount = 0        -- total GRU events since last PEW
local gruBurstCount = 0        -- GRU events coalesced into current throttle batch
rosterThrottleFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    DF:Debug("ROSTER", "Throttle fired: processing %d coalesced GRU events (%d total since PEW)", gruBurstCount, gruEventCount)
    gruBurstCount = 0
    if not InCombatLockdown() then
        DF:ProcessRosterUpdate()
    else
        -- ARENA FIX: Check for arena first - arena is IsInRaid()=true but needs
        -- its own sorting path, not flat raid or grouped raid.
        -- Without this, arena falls through to pendingFlatLayoutRefresh (wrong flag).
        local contentType = DF.GetContentType and DF:GetContentType()
        if contentType == "arena" then
            DF.pendingSortingUpdate = true
        else
            -- For flat layouts, just queue a flat layout refresh
            -- For grouped layouts, queue full header settings apply
            local raidDb = DF:GetRaidDB()
            if IsInRaid() and not raidDb.raidUseGroups then
                DF.pendingFlatLayoutRefresh = true
            else
                DF.pendingHeaderSettingsApply = true
            end
        end
    end
end)

local function QueueRosterUpdate()
    gruBurstCount = gruBurstCount + 1
    gruEventCount = gruEventCount + 1
    DF:Debug("ROSTER", "QueueRosterUpdate: GRU #%d (burst #%d), members=%d", gruEventCount, gruBurstCount, GetNumGroupMembers())
    rosterThrottleFrame:Show()  -- Showing already-shown frame = no-op
end

-- ============================================================
-- ARENA SORT RETRY
-- A friendly arena member can EXIST before their name has resolved
-- (UnitName returns nil / UNKNOWNOBJECT while they're still loading in —
-- common in non-rated arenas where players trickle in during prep). A
-- nameList built in that window FILTERS the unresolved player out of the
-- secure header, and nothing ever fixes it: name resolution fires no
-- GROUP_ROSTER_UPDATE, and once the gates open combat blocks attribute
-- writes for the rest of the round. When a build comes back incomplete,
-- ApplyArenaHeaderSorting shows everyone in INDEX order instead and this
-- retry loop re-sorts once the names resolve (UNIT_NAME_UPDATE nudges it
-- too, but per the codebase's own experience that event is unreliable).
-- ============================================================
local arenaSortRetryPending = false
local arenaSortRetryCount = 0
local arenaNameListIncomplete = false

local function SetArenaNameListIncomplete(v)
    arenaNameListIncomplete = v
    if not v then
        arenaSortRetryCount = 0  -- complete build: re-arm the safety cap
    end
end

local function ScheduleArenaSortRetry()
    if arenaSortRetryPending then return end
    if arenaSortRetryCount >= 24 then return end  -- ~12s safety cap
    arenaSortRetryPending = true
    arenaSortRetryCount = arenaSortRetryCount + 1
    C_Timer.After(0.5, function()
        arenaSortRetryPending = false
        if not (DF.GetContentType and DF:GetContentType() == "arena") then return end
        if InCombatLockdown() then
            -- Replays via the existing combat-end queue.
            DF.pendingSortingUpdate = true
        elseif DF.IsFrameSortActive and DF:IsFrameSortActive() then
            -- FrameSort owns sorting: re-request its order. Calling
            -- ApplyArenaHeaderSorting here would just yield and clear the
            -- header to INDEX, never resolving the incomplete state.
            if DF.FrameSort and DF.FrameSort.RequestSort then
                DF.FrameSort:RequestSort()
            end
        elseif DF.ApplyArenaHeaderSorting then
            DF:ApplyArenaHeaderSorting()
        end
    end)
end

-- FrameSort integration (Features/FrameSort.lua) writes the arena header's
-- nameList through its own path; this exposes the incomplete-state machinery
-- so that path gets the same INDEX-fallback + retry + UNIT_NAME_UPDATE-nudge
-- coverage as the native ApplyArenaHeaderSorting path.
function DF:SetArenaSortIncomplete(incomplete)
    SetArenaNameListIncomplete(incomplete)
    if incomplete then
        ScheduleArenaSortRetry()
    end
end

-- Same pattern for role updates
local roleThrottleFrame = CreateFrame("Frame")
roleThrottleFrame:Hide()
roleThrottleFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    DF:ProcessRoleUpdate()
end)

local function QueueRoleUpdate()
    roleThrottleFrame:Show()
end

-- ============================================================
-- FOLLOWER DUNGEON ROSTER RECHECK
-- Follower NPCs register with the group system on a delay after
-- zoning in. If the party is incomplete, schedule a recheck so
-- all NPC frames appear without requiring a /reload. (#402)
-- ============================================================
local followerRecheckTimer = nil
local FOLLOWER_RECHECK_DELAY = 2  -- seconds
local FOLLOWER_RECHECK_MAX = 3    -- max retry attempts

-- ============================================================
-- GUID AND ROLE CACHING
-- Only trigger updates when data actually changes
-- ============================================================
local issecretvalue = issecretvalue or function() return false end
local unitGuidCache = {}   -- unit -> GUID mapping
local unitRoleCache = {}   -- unit -> role mapping  
local unitLeaderCache = nil -- tracks current leader unit (single value, not table)

-- ============================================================
-- UNIT-TO-FRAME LOOKUP TABLE
-- Maps unit strings ("raid17", "party2", etc.) directly to their frame.
-- Maintained by OnAttributeChanged — provides O(1) frame lookup for
-- unit-specific events (absorb, heal prediction, summon, rez, etc.)
-- instead of iterating all frames per event. See headerChildEventFrame.
--
-- DandersFrames never displays the same unit in two frames simultaneously,
-- so this is a simple 1:1 mapping (no set-based multi-frame tracking needed).
--
-- Pet frames are NOT indexed here — they come up through the pet header's own
-- child-init path rather than this one.
-- ============================================================
local unitFrameMap = {}    -- "raid17" => frame, "party2" => frame, etc.
DF.unitFrameMap = unitFrameMap  -- Expose for cross-file access (e.g., Auras.lua hook)

-- ============================================================
-- HEADER CHILD EVENT MANAGEMENT
-- Enable/disable event processing on all children of a header.
-- Events are registered GLOBALLY on headerChildEventFrame (centralized dispatch),
-- so this just sets a flag that the central handler checks.
-- Used to fully disable hidden frames (performance optimization).
-- ============================================================

-- Public function to enable/disable event processing on all children of a header
-- @param header SecureGroupHeaderTemplate
-- @param enabled boolean - true to process events, false to skip
function DF:SetHeaderChildrenEventsEnabled(header, enabled)
    if not header then return end
    
    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child then
            child.dfEventsEnabled = enabled
        end
    end
end

-- ============================================================
-- UNIT FRAME MAP REBUILD
-- Rebuilds unitFrameMap by scanning all visible header children.
-- Called after wipe(unitFrameMap) to ensure the centralized event
-- dispatcher can find frames for incoming UNIT_HEALTH etc. events.
-- Without this, if OnAttributeChanged("unit") doesn't fire (because
-- unit assignments haven't changed), the map stays empty and all
-- unit events are silently dropped — causing health desync.
-- ============================================================
function DF:CountUnitFrameMap()
    local count = 0
    for _ in pairs(unitFrameMap) do count = count + 1 end
    return count
end

function DF:RebuildUnitFrameMap()
    -- Targeted cleanup: remove stale entries where the frame is hidden
    -- or no longer assigned to that unit. This replaces the old destructive
    -- wipe(unitFrameMap) pattern — we keep valid entries so UNIT_HEALTH
    -- events are never silently dropped during transitions.
    for unit, frame in pairs(unitFrameMap) do
        if not frame:IsShown() or frame:GetAttribute("unit") ~= unit then
            unitFrameMap[unit] = nil
        end
    end

    -- Helper: process a single header child.
    -- Uses IsShown() instead of IsVisible() because IsVisible() requires
    -- ALL ancestors to be visible.  After a zone-transition wipe the parent
    -- container may not yet be shown when this runs, so IsVisible() would
    -- return false even though the child itself is valid and shown.
    -- Also syncs frame.unit from the secure "unit" attribute if they've
    -- drifted (can happen when OnAttributeChanged hasn't fired yet), and
    -- rebuilds unitGuidCache alongside unitFrameMap so the GUID-based skip
    -- optimisation in OnAttributeChanged works correctly after a wipe.
    local function ProcessChild(child)
        if not child or (child.isPinnedFrame and not child.isPinnedBossFrame) then return end
        
        -- Prefer the secure attribute as the source of truth; fall back to
        -- the Lua property that OnAttributeChanged keeps in sync.
        local unit = child:GetAttribute("unit")
        if unit and unit ~= "" then
            -- Sync frame.unit if it's stale or nil (OnAttributeChanged may
            -- not have fired yet after a Hide/Show cycle).
            if child.unit ~= unit then
                child.unit = unit
            end
        else
            unit = child.unit
        end
        
        if not unit then return end
        -- Accept the child if it is shown (lightweight check) OR if its
        -- parent header is shown — covers the brief window where children
        -- haven't fully resolved their visibility after a header Show().
        if not child:IsShown() then return end
        
        unitFrameMap[unit] = child
        
        -- Rebuild GUID cache entry so OnAttributeChanged's GUID-based skip
        -- optimisation works correctly.  Without this, oldGuid is nil after
        -- a wipe and every OnAttributeChanged falls through to the full
        -- C_Timer.After(0) refresh path, causing a one-frame health stale.
        local guid = UnitGUID(unit)
        if guid and not issecretvalue(guid) then
            unitGuidCache[unit] = guid
        end
    end
    
    -- Scan party header children
    if DF.partyHeader then
        for i = 1, 5 do
            ProcessChild(DF.partyHeader:GetAttribute("child" .. i))
        end
    end
    
    -- Scan arena header children
    if DF.arenaHeader then
        for i = 1, 5 do
            ProcessChild(DF.arenaHeader:GetAttribute("child" .. i))
        end
    end
    
    -- Scan raid separated headers (grouped mode)
    if DF.raidSeparatedHeaders then
        for group = 1, 8 do
            local header = DF.raidSeparatedHeaders[group]
            if header and header:IsShown() then
                for i = 1, 5 do
                    ProcessChild(header:GetAttribute("child" .. i))
                end
            end
        end
    end
    
    -- Scan flat raid header (combined mode)
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header and DF.FlatRaidFrames.header:IsShown() then
        for i = 1, 40 do
            ProcessChild(DF.FlatRaidFrames.header:GetAttribute("child" .. i))
        end
    end
end

-- ============================================================
-- ROSTER MEMBERSHIP CACHING
-- Detect when roster actually changes vs duplicate events
-- ============================================================
local rosterMembershipCache = {}  -- name -> subgroup mapping
local lastRosterCount = 0         -- track group size changes

-- Build a snapshot of current roster membership
local function GetRosterSnapshot()
    local snapshot = {}
    local count = 0
    
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name, _, subgroup = GetRaidRosterInfo(i)
            if name then
                snapshot[name] = subgroup
                count = count + 1
            end
        end
    elseif IsInGroup() then
        -- Party mode - just track presence
        local playerName = UnitName("player")
        if playerName then
            snapshot[playerName] = 1
            count = count + 1
        end
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name = UnitName(unit)
                if name then
                    snapshot[name] = 1
                    count = count + 1
                end
            end
        end
    end
    
    return snapshot, count
end

-- Check if roster membership has changed (returns true if changed)
local function HasRosterMembershipChanged()
    local newSnapshot, newCount = GetRosterSnapshot()
    
    -- Quick check: count changed
    if newCount ~= lastRosterCount then
        rosterMembershipCache = newSnapshot
        lastRosterCount = newCount
        if DF.RosterDebugCount then DF:RosterDebugCount("RosterMembership-CHANGED-count") end
        return true
    end
    
    -- Deep check: same count but different members or subgroups
    for name, subgroup in pairs(newSnapshot) do
        if rosterMembershipCache[name] ~= subgroup then
            rosterMembershipCache = newSnapshot
            lastRosterCount = newCount
            if DF.RosterDebugCount then DF:RosterDebugCount("RosterMembership-CHANGED-member") end
            return true
        end
    end
    
    -- Check for removed members
    for name in pairs(rosterMembershipCache) do
        if not newSnapshot[name] then
            rosterMembershipCache = newSnapshot
            lastRosterCount = newCount
            if DF.RosterDebugCount then DF:RosterDebugCount("RosterMembership-CHANGED-removed") end
            return true
        end
    end
    
    if DF.RosterDebugCount then DF:RosterDebugCount("RosterMembership-SAME") end
    return false
end


-- Clear GUID cache for a unit (when unit is removed)
local function ClearUnitCache(unit)
    if unit then
        unitGuidCache[unit] = nil
        unitRoleCache[unit] = nil
        
        -- Clear range cache for this unit to prevent stale OOR state on new player
        if DF.ClearRangeCacheForUnit then
            DF:ClearRangeCacheForUnit(unit)
        end
    end
end

-- ============================================================
-- HEADER ATTRIBUTE CACHING
-- Only call SetAttribute when value actually changes.
-- This is CRITICAL because SecureGroupHeaderTemplate fires
-- OnAttributeChanged for ALL children when ANY attribute changes.
-- ============================================================
local headerAttributeCache = {}  -- header -> { attr -> value }

-- Set attribute only if it changed (prevents massive OnAttributeChanged cascades)
local function SetHeaderAttribute(header, attr, value)
    if not header then return end
    
    local headerName = header:GetName() or tostring(header)
    if not headerAttributeCache[headerName] then
        headerAttributeCache[headerName] = {}
    end
    
    local cache = headerAttributeCache[headerName]
    
    -- Compare with cached value
    if cache[attr] == value then
        -- Value unchanged, skip SetAttribute entirely
        if DF and DF.RosterDebugCount then
            DF:RosterDebugCount("SetHeaderAttribute-SKIPPED")
        end
        return false
    end
    
    -- Value changed: SET FIRST, then record. Recording first meant a write that
    -- was blocked or otherwise failed still poisoned the cache into reporting
    -- success, and every later attempt to set the same value was then skipped.
    header:SetAttribute(attr, value)
    cache[attr] = value
    if DF and DF.RosterDebugCount then
        DF:RosterDebugCount("SetHeaderAttribute-CHANGED")
    end
    return true
end

-- Clear cache for a header (use when header is destroyed/recreated, OR when
-- anything writes the header's attributes WITHOUT going through
-- SetHeaderAttribute -- otherwise the cache still describes the old values and
-- the next matching write is skipped as redundant).
local function ClearHeaderAttributeCache(header)
    if header then
        local headerName = header:GetName() or tostring(header)
        headerAttributeCache[headerName] = nil
    end
end

-- Exposed because the bypassing writers live in another file: Features/FrameSort.lua
-- nils nameList/sortMethod directly when the user turns the external sorter off, and
-- DF:SetPartySorting writes them raw. Neither went through SetHeaderAttribute, so the
-- cache kept claiming the old values were live and the re-apply that should have
-- restored DF's own sorting was skipped -- party frames stayed in template order
-- until a roster change happened to alter the nameList string.
function DF:ClearHeaderAttributeCache(header)
    ClearHeaderAttributeCache(header)
end

-- ============================================================
-- NAMELIST PROCESSING
-- SecureGroupHeaderTemplate uses UnitName() internally which returns
-- names WITHOUT realm suffixes. GetRaidRosterInfo() returns names
-- WITH realm suffixes for cross-realm players. This mismatch causes
-- nameList sorting to fail silently.
-- ============================================================
local STRIP_REALMS_FROM_NAMELIST = false  -- Keep realms in nameList

-- Process a nameList string, optionally stripping realm names
-- @param nameList: Comma-separated list of names (e.g., "Player1-Realm,Player2,Player3-OtherRealm")
-- @param stripRealms: If true, strips realm suffixes from names (everything after the dash)
-- @return: Processed nameList string
local function ProcessNameList(nameList, stripRealms)
    if not nameList or nameList == "" then return nameList end
    if not stripRealms then return nameList end
    
    local names = {}
    for name in string.gmatch(nameList, "[^,]+") do
        -- Strip realm (everything after the dash)
        local cleanName = name:match("([^%-]+)") or name
        table.insert(names, cleanName)
    end
    
    return table.concat(names, ",")
end

-- ============================================================
-- DEBUG CALL COUNTER SYSTEM
-- Tracks function call counts during roster updates
-- Usage: /dfroster to start monitoring, join a raid, /dfroster to see results
-- ============================================================
DF.RosterDebug = {
    enabled = false,
    startTime = 0,
    counts = {},
    events = {},
}

function DF:RosterDebugCount(funcName)
    if not DF.RosterDebug.enabled then return end
    DF.RosterDebug.counts[funcName] = (DF.RosterDebug.counts[funcName] or 0) + 1
end

function DF:RosterDebugEvent(eventName)
    if not DF.RosterDebug.enabled then return end
    DF.RosterDebug.events[eventName] = (DF.RosterDebug.events[eventName] or 0) + 1
end

DF:RegisterDebugSlash("DFROSTER", "Roster / unit map dump", false, "/dfroster")
SlashCmdList["DFROSTER"] = function(msg)
    if not DF.RosterDebug.enabled then
        -- Start monitoring
        wipe(DF.RosterDebug.counts)
        wipe(DF.RosterDebug.events)
        DF.RosterDebug.startTime = GetTime()
        DF.RosterDebug.enabled = true
        -- Via CmdPath, not a hardcoded spelling: /dfroster is no longer a bind
        -- after the one-command rework, and the path stays right if roster ever
        -- moves between the everyday and debug listings.
        DF:Say("Started monitoring. Join/leave groups, then run "
            .. DF:CmdPath("roster") .. " again to see results.")
    else
        -- Stop and report
        DF.RosterDebug.enabled = false
        local elapsed = GetTime() - DF.RosterDebug.startTime
        local o = DF:Out("Roster", string.format("results after %.1fs", elapsed))

        local eventList = {}
        for event, count in pairs(DF.RosterDebug.events) do
            table.insert(eventList, {name = event, count = count})
        end
        table.sort(eventList, function(a, b) return a.count > b.count end)
        o:Section("Events", #eventList)
        for _, item in ipairs(eventList) do
            o:Field(item.name, item.count)
        end

        local funcList = {}
        for func, count in pairs(DF.RosterDebug.counts) do
            table.insert(funcList, {name = func, count = count})
        end
        table.sort(funcList, function(a, b) return a.count > b.count end)
        o:Section("Function calls", #funcList)
        for _, item in ipairs(funcList) do
            -- Status here is a CALL-RATE judgement, not a datatype: a handler firing
            -- 50+ times for one roster change is exactly what this probe hunts.
            o:Field(item.name, item.count,
                item.count > 50 and "bad" or (item.count > 10 and "warn" or "good"))
        end

        if #eventList == 0 and #funcList == 0 then
            o:Line("no activity recorded", "neutral")
        end
    end
end

-- Local caching
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local UnregisterStateDriver = UnregisterStateDriver

-- (Removed) DF.POSITION_HEADER_SNIPPET, a secure-snippet string never handed to any
-- restricted environment — one hit in the whole repo, its own definition. Its banner read
-- "This is the ONLY function that moves headers", which was actively misleading: nothing
-- ever executed it, and header positioning is done by the plain-Lua functions in this file.

-- ============================================================
-- HEADER CHILD INITIALIZATION
-- Called from XML OnLoad when header creates a child frame
-- ============================================================

function DF:InitializeHeaderChild(frame)
    if not frame then return end
    if frame.dfInitialized then return end
    
    -- Mark frame properties
    frame.dfIsDandersFrame = true
    frame.dfIsHeaderChild = true
    
    -- Determine if this is a raid, party, or arena frame based on parent
    local parent = frame:GetParent()
    local isRaid = false
    local isArena = false
    local isRaidCombined = false
    local isPinned = false
    if parent then
        local parentName = parent:GetName() or ""
        isArena = parentName:find("Arena") ~= nil
        isPinned = parentName:find("Pinned") ~= nil
        isRaid = parentName:find("Raid") ~= nil and not isArena and not isPinned
        -- Match ALL grouped raid header children: DandersRaidGroup1Header..8Header
        -- AND legacy RaidCombined (if any). Flat raid uses DandersFlatRaidHeader
        -- which does NOT match here — flat children need ApplyFrameLayout on OnShow.
        isRaidCombined = (parentName:find("RaidGroup") ~= nil) or (parentName:find("RaidCombined") ~= nil)
    end

    -- PINNED FRAMES: Use current group status to determine raid vs party
    -- Pinned frames can show either party or raid members, so they should
    -- use the appropriate settings based on whether we're in a raid
    if isPinned then
        isRaid = IsInRaid()
    end

    frame.isRaidFrame = isRaid
    frame.isArenaFrame = isArena  -- Arena uses party settings but raid units
    frame.isPinnedFrame = isPinned
    frame.dfIsRaidCombinedChild = isRaidCombined

    -- Register in external lookup table (immune to WoW's secure template clearing fields)
    if isRaid and DF.RegisterRaidFrame then
        DF:RegisterRaidFrame(frame)
    end

    DF:Debug("LAYOUT", "InitializeHeaderChild: parent=%s isRaid=%s isArena=%s isPinned=%s",
        frame:GetParent() and frame:GetParent():GetName() or "nil",
        tostring(isRaid), tostring(isArena), tostring(isPinned))
    
    -- Get appropriate DB and set frame size
    -- Arena frames use PARTY settings (same as party frames)
    local db = isRaid and DF:GetRaidDB() or DF:GetDB()
    local frameWidth = db.frameWidth or (isRaid and 80 or 120)
    local frameHeight = db.frameHeight or (isRaid and 40 or 50)
    -- Snapped: this creation-time size is what SecureGroupHeaderTemplate reads to size
    -- the header until the first ApplyFrameLayout pass re-sizes it (which also snaps).
    DF:SetPixelPerfectSize(frame, frameWidth, frameHeight, db)
    
    -- Create all visual elements
    DF:CreateFrameElements(frame)
    
    -- Register for clicks
    frame:RegisterForClicks("AnyUp")
    
    -- Set default click actions (target on left, menu on right)
    -- Click casting will override these when it initializes, but this ensures
    -- basic click-to-target always works regardless of CC state or timing.
    frame:SetAttribute("type1", "target")
    frame:SetAttribute("type2", "togglemenu")
    
    -- Register for ping system (makes frames pingable)
    DF:RegisterFrameForPing(frame)
    
    -- ========================================
    -- EVENT HANDLING (CENTRALIZED DISPATCH)
    -- All unit events are handled by the central headerChildEventFrame
    -- using unitFrameMap for O(1) frame lookup. No per-frame event
    -- registration needed - eliminates timing bugs on unit changes.
    -- ========================================
    frame.dfEventsEnabled = true  -- Flag checked by global handler
    
    -- Sync unit attribute to frame.unit property (for compatibility with existing code)
    -- The header assigns units via attributes, but a lot of code uses frame.unit directly
    -- Use GUID comparison to detect actual player changes
    frame:HookScript("OnAttributeChanged", function(self, name, value)
        if name == "unit" then
            DF:RosterDebugCount("OnAttributeChanged(unit)")
            
            -- Get the actual unit via SecureButton_GetModifiedUnit
            local actualUnit = value and SecureButton_GetModifiedUnit(self) or nil
            local oldUnit = self.unit
            
            -- Get GUIDs for comparison (guard against secret values from Midnight 12.0)
            local rawNewGuid = actualUnit and UnitGUID(actualUnit) or nil
            local newGuid = (rawNewGuid and not issecretvalue(rawNewGuid)) and rawNewGuid or nil
            local oldGuid = oldUnit and unitGuidCache[oldUnit] or nil

            -- LEVEL 0: Both nil — nothing to do
            -- Hide/Show cycles on SecureGroupHeaderTemplate fire OnAttributeChanged("unit", nil)
            -- on every pre-allocated child slot. For empty groups this generates dozens of
            -- nil->nil transitions per GRU that are pure noise.
            if not oldUnit and not actualUnit then
                return
            end

            -- LEVEL 1: Skip if unit string AND GUID are both the same
            -- (Must check GUID because same unit string can have different player after roster change)
            if oldUnit == actualUnit then
                if newGuid and newGuid == oldGuid then
                    -- Truly the same - unit string and player are identical
                    DF:RosterDebugCount("OnAttributeChanged(unit)-SKIPPED-same")
                    return
                end
                -- Same unit string but different GUID - player changed, need full refresh
                DF:RosterDebugCount("OnAttributeChanged(unit)-SAME-UNIT-NEW-GUID")
                -- Fall through to full refresh
            end

            -- LEVEL 2: Different unit strings but same GUID (player moved slots)
            -- e.g., raid3 -> raid5 but same person
            if actualUnit and oldUnit and newGuid and newGuid == oldGuid then
                -- Same player, just different unit string - update unit but skip full refresh
                DF:RosterDebugCount("OnAttributeChanged(unit)-SKIPPED-same-guid")
                -- Update unitFrameMap: remove old entry only if this frame owns it
                -- Skip for pinned frames - they share units with main frames
                -- and must not overwrite or remove main frame entries
                if not self.isPinnedFrame or self.isPinnedBossFrame then
                    if unitFrameMap[oldUnit] == self then
                        unitFrameMap[oldUnit] = nil
                    end
                    unitFrameMap[actualUnit] = self
                end
                self.unit = actualUnit
                ClearUnitCache(oldUnit)
                ClearUnitCache(actualUnit)  -- New slot may have stale aura/range data from old occupant
                unitGuidCache[actualUnit] = newGuid
                -- Reset phased cache for both old and new unit tokens
                if DF.ResetPhasedCache then
                    DF:ResetPhasedCache(oldUnit)
                    DF:ResetPhasedCache(actualUnit)
                end
                
                -- No event re-registration needed: global headerChildEventFrame
                -- uses unitFrameMap[unit] for dispatch, which we just updated above.

                -- This button now shows a different unit token, so any pet anchored to
                -- it is pointing at the wrong teammate. Same-GUID path still counts: the
                -- pet's unit is derived from the slot, not the player. Guarded because
                -- Pets.lua and this file have no guaranteed load order.
                if DF.InvalidatePetAnchors then DF:InvalidatePetAnchors() end

                return
            end

            DF:RosterDebugCount("OnAttributeChanged(unit)-PROCESSED")
            DF:Debug("ROSTER", "OnAttributeChanged: %s -> %s (isRaid=%s)",
                tostring(oldUnit), tostring(actualUnit), tostring(self.isRaidFrame))
            
            -- Clear old unit's cache
            if oldUnit then
                -- Remove from unitFrameMap (only if this frame owns the entry)
                -- Skip for pinned frames - they must not remove main frame entries
                if (not self.isPinnedFrame or self.isPinnedBossFrame) and unitFrameMap[oldUnit] == self then
                    unitFrameMap[oldUnit] = nil
                end
                -- Clear legacy DF.playerFrame if this frame was the player
                if oldUnit == "player" and DF.playerFrame == self then
                    DF.playerFrame = nil
                end
                ClearUnitCache(oldUnit)
                -- Clear phased cache for old unit (stale phase data)
                if DF.ResetPhasedCache then DF:ResetPhasedCache(oldUnit) end
                -- No per-frame event unregistration needed: global handler
                -- uses unitFrameMap which we just cleared for oldUnit.
            end
            
            self.unit = actualUnit
            -- The full reassign path. Same reasoning as the same-GUID path above: this
            -- button's unit moved, so its pet's anchor is stale.
            --
            -- ⚠ NOT conditional on oldUnit. It is tempting to narrow this to "only when
            -- something was there before", but oldUnit is nil precisely when a child
            -- receives its FIRST unit — a rebuild burst, which is exactly the case that
            -- most needs the pets re-anchored. The retail lane shipped a narrowing that
            -- treated a nil unit as "invalidate everything" and the field log caught it
            -- degrading straight back to a full sweep during arena entry.
            if DF.InvalidatePetAnchors then DF:InvalidatePetAnchors() end
            -- Clear background color tracking (unit changed, need fresh colors)
            -- Clear stale range state so this slot doesn't inherit the previous
            -- occupant's faded appearance. dfInRange is immediately repopulated
            -- by UpdateRange below for accurate OOR state before first render.
            self.dfInRange = nil
            -- Cache new unit's GUID
            if actualUnit then
                -- Clear stale aura/range data that may belong to old occupant of this slot
                ClearUnitCache(actualUnit)
                -- Eagerly populate range state before the first render. Without this,
                -- dfInRange is nil and GetInRange falls back to "assume in range", causing
                -- OOR members to briefly flash as in-range on group join or roster reshuffle.
                if DF.UpdateRange then
                    DF:UpdateRange(self)
                end
                -- Clear phased cache for new unit (force fresh evaluation)
                if DF.ResetPhasedCache then DF:ResetPhasedCache(actualUnit) end
                -- Skip unitFrameMap for pinned frames (except boss-type pinned frames)
                if not self.isPinnedFrame or self.isPinnedBossFrame then
                    unitFrameMap[actualUnit] = self
                end
                local cacheGuid = UnitGUID(actualUnit)
                if cacheGuid and not issecretvalue(cacheGuid) then
                    unitGuidCache[actualUnit] = cacheGuid
                end

                local num = actualUnit:match("%d+")
                if num then
                    self.index = tonumber(num)
                elseif actualUnit == "player" then
                    self.index = 0
                    -- Sync legacy DF.playerFrame for backward compatibility --
                    -- main-frame children ONLY.
                    --
                    -- DF.playerFrame is not a generic "whichever frame holds
                    -- unit=player"; ~50 consumers treat it as the party player
                    -- frame specifically. SecureSort uses it as party slot 0,
                    -- setting secure paths and swap frame refs on it, and
                    -- UpdateAllFrames drives its unit watch and its click-cast
                    -- registration from it. A pinned frame showing the player was
                    -- being adopted here, which hands all of that the wrong frame.
                    --
                    -- The sibling write fifty lines above already guards exactly
                    -- this ("Skip for pinned frames - they must not remove main
                    -- frame entries"); this one never got the same treatment.
                    if not self.isPinnedFrame then
                        DF.playerFrame = self
                    end
                end

                -- Click casting needs a unit to accept a frame, and this is the
                -- moment one arrives. A header child is created before the header
                -- assigns units, so registration at creation is REFUSED for lack
                -- of a unit -- and the ClickCastFrames metatable cannot retry,
                -- because its rawset already spent that frame's one __newindex.
                -- Without this the frame stays unregistered for the session: no
                -- hooks, no binds, bound keys falling through to the action bar,
                -- with only a /reload to clear it. Cheap and idempotent --
                -- EnsureRegistered returns immediately if already registered, and
                -- honours an explicit opt-out.
                if DF.ClickCast and DF.ClickCast.EnsureRegistered then
                    DF.ClickCast:EnsureRegistered(self)
                end
                
                -- No per-frame event registration needed: global headerChildEventFrame
                -- handles all unit events and dispatches via unitFrameMap[unit].
            end
            
            -- Trigger a comprehensive update for the frame
            if actualUnit then

                C_Timer.After(0, function()
                    if self:IsVisible() and self.unit then
                        -- Use full frame refresh for complete update
                        if DF.FullFrameRefresh then
                            DF:FullFrameRefresh(self)
                        else
                            -- Fallback if FullFrameRefresh not yet loaded
                            if DF.UpdateUnitFrame then DF:UpdateUnitFrame(self) end
                            if DF.UpdateAuras then DF:UpdateAuras(self) end
                            if DF.UpdateDefensiveBar then DF:UpdateDefensiveBar(self) end
                            if DF.UpdateRoleIcon then DF:UpdateRoleIcon(self) end
                        end
                    end
                end)
            end

            -- Fire OnFramesSorted for external API subscribers whenever a child's
            -- unit attribute is reassigned. Catches in-combat reshuffles (roster
            -- changes, ASSIGNEDROLE re-sorts) that ApplyPartyGroupSorting cannot
            -- cover due to combat lockdown. Coalesced per sortType per frame so
            -- Blizzard reshuffling N children only produces one callback.
            local sortType
            if self.isArenaFrame then
                sortType = "arena"
            elseif self.isRaidFrame then
                sortType = "raid"
            else
                sortType = "party"
            end
            DF._sortCallbackPending = DF._sortCallbackPending or {}
            if not DF._sortCallbackPending[sortType] then
                DF._sortCallbackPending[sortType] = true
                C_Timer.After(0, function()
                    DF._sortCallbackPending[sortType] = nil
                    if DF.FireAPICallback then
                        DF:FireAPICallback("OnFramesSorted", sortType)
                    end
                end)
            end
        end
    end)

    -- If unit is already set (might be set before OnLoad in some cases), sync it now
    local currentUnit = frame:GetAttribute("unit")
    if currentUnit then
        frame.unit = currentUnit
        -- Skip unitFrameMap for pinned frames - they share units with main frames
        -- (boss-type pinned frames are allowed: boss1-8 units are only in these frames)
        if not frame.isPinnedFrame or frame.isPinnedBossFrame then
            unitFrameMap[currentUnit] = frame
        end
        local num = currentUnit:match("%d+")
        if num then
            frame.index = tonumber(num)
        elseif currentUnit == "player" then
            frame.index = 0
        end
        
        -- No per-frame event registration needed: global headerChildEventFrame
        -- handles all unit events and dispatches via unitFrameMap[unit].
    end
    
    -- Mark as initialized
    frame.dfInitialized = true
    
    -- Register with click casting system (Clique, Clicked, etc.)
    DF:RegisterFrameWithClickCast(frame)

    -- ========================================
    -- HOVER HANDLING (OnEnter/OnLeave)
    -- Sets dfIsHovered flag and updates highlights
    -- ========================================
    frame:HookScript("OnEnter", function(self)
        local frameDb = DF:GetFrameDB(self)

        -- Set hover state and update highlights
        self.dfIsHovered = true
        if DF.UpdateHighlights then
            DF:UpdateHighlights(self)
        end

        -- Binding tooltip (independent of unit tooltip settings)
        if DF.ShowBindingTooltip then DF:ShowBindingTooltip(self) end

        -- Check if we're actually hovering a child element (aura) with SetPropagateMouseMotion
        local focus = GetMouseFocus and GetMouseFocus() or GetMouseFoci and GetMouseFoci()[1]
        if focus and focus ~= self and focus.unitFrame == self then
            return
        end

        -- Check if tooltips are enabled
        if not frameDb.tooltipFrameEnabled then return end

        -- Check if tooltips disabled in combat
        if frameDb.tooltipFrameDisableInCombat and InCombatLockdown() then return end

        -- Show tooltip
        if self.unit and UnitExists(self.unit) then
            local anchorType = frameDb.tooltipFrameAnchor or "CURSOR"
            if anchorType == "CURSOR" then
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            elseif anchorType == "FRAME" then
                local anchorPos = frameDb.tooltipFrameAnchorPos or "BOTTOMRIGHT"
                local offsetX = frameDb.tooltipFrameX or 0
                local offsetY = frameDb.tooltipFrameY or 0
                GameTooltip:SetOwner(self, "ANCHOR_NONE")
                GameTooltip:ClearAllPoints()
                GameTooltip:SetPoint(anchorPos, self, anchorPos, offsetX, offsetY)
            else
                GameTooltip_SetDefaultAnchor(GameTooltip, self)
            end
            GameTooltip:SetUnit(self.unit)
            -- GetUnit() returns a secret value due to secure frame taint from
            -- SecureGroupHeaderTemplate, so TooltipDataProcessor-based addons
            -- can't read the unit. Bypass via RaiderIO's public API, but only
            -- when the normal path fails to avoid duplicate tooltip lines.
            local _, ttUnit = GameTooltip:GetUnit()
            if (not ttUnit or issecretvalue(ttUnit)) and _G.RaiderIO and _G.RaiderIO.ShowProfile then
                _G.RaiderIO.ShowProfile(GameTooltip, self.unit)
            end
            -- Start refresh ticker so tooltip addons (RaiderIO) can respond
            -- to modifier key changes while hovering
            if DF.StartTooltipRefresh then DF:StartTooltipRefresh(self) end
        end
    end)

    frame:HookScript("OnLeave", function(self)
        -- Clear hover state and update highlights
        self.dfIsHovered = false
        if DF.UpdateHighlights then
            DF:UpdateHighlights(self)
        end

        -- Stop tooltip refresh ticker
        if DF.StopTooltipRefresh then DF:StopTooltipRefresh() end

        -- Only hide tooltip if we're truly leaving the frame
        local focus = GetMouseFocus and GetMouseFocus() or GetMouseFoci and GetMouseFoci()[1]
        if focus and focus.unitFrame == self then
            return
        end
        GameTooltip:Hide()
        if DFBindingTooltip and focus ~= self then DFBindingTooltip:Hide(); DFBindingTooltip.anchorFrame = nil end
    end)

    -- Apply layout (this configures all the visual elements properly)
    if DF.ApplyFrameLayout then
        DF:ApplyFrameLayout(frame)
    end
    
    -- ========================================
    -- ONSHOW HOOK - Update frame when it becomes visible
    -- This ensures all visual elements are properly updated
    -- ========================================
    frame:HookScript("OnShow", function(self)
        -- Register in unitFrameMap immediately so UNIT_HEALTH events
        -- can dispatch to this frame the instant it becomes visible.
        -- Without this, frames shown after RebuildUnitFrameMap() are
        -- invisible to event dispatch until the next rebuild.
        if self.unit and (not self.isPinnedFrame or self.isPinnedBossFrame) then
            unitFrameMap[self.unit] = self
        end

        -- Small delay to ensure unit is set
        C_Timer.After(0.05, function()
            if self and self.unit and self:IsVisible() then
                DF:Debug("LAYOUT", "OnShow refresh: %s (headerChild=%s isRaid=%s)",
                    self.unit or "?", tostring(self.dfIsHeaderChild), tostring(self.isRaidFrame))
                -- Apply layout in case settings changed while hidden
                -- SKIP for raid combined (grouped) children — SetSize triggers SecureGroupHeader_Update
                -- which repositions every sibling, causing visible frame jumping on roster changes.
                -- Raid combined children get sized explicitly by ApplyHeaderSettings.
                -- Party and flat raid children need this to stay correctly sized.
                if DF.ApplyFrameLayout and not self.dfIsRaidCombinedChild then
                    DF:ApplyFrameLayout(self)
                end
                -- Core frame update
                if DF.UpdateUnitFrame then
                    DF:UpdateUnitFrame(self)
                end
                -- Auras
                if DF.UpdateAuras then
                    DF:UpdateAuras(self)
                end
                -- Defensive row: separate handle, not reached by UpdateAuras (#1063)
                if DF.UpdateDefensiveBar then
                    DF:UpdateDefensiveBar(self)
                end
                -- Missing buff icon
                if DF.UpdateMissingBuffIcon then
                    DF:UpdateMissingBuffIcon(self)
                end
                -- Icons
                if DF.UpdateRoleIcon then DF:UpdateRoleIcon(self) end
                if DF.UpdateLeaderIcon then DF:UpdateLeaderIcon(self) end
                if DF.UpdateRaidTargetIcon then DF:UpdateRaidTargetIcon(self) end
                -- Dispel overlay
                if DF.UpdateDispelOverlay then
                    DF:UpdateDispelOverlay(self)
                end
                -- Highlights
                if DF.UpdateHighlights then
                    DF:UpdateHighlights(self)
                end
                -- Resource bar
                if DF.ApplyResourceBarLayout then
                    DF:ApplyResourceBarLayout(self)
                end
                if DF.UpdateResourceBar then
                    DF:UpdateResourceBar(self)
                end
            end
        end)
    end)
    
    -- Initial icon updates (role, leader, raid target, etc.)
    -- Delayed slightly to ensure unit attribute is set
    C_Timer.After(0.1, function()
        if frame and frame.unit and frame:IsVisible() then
            if DF.UpdateRoleIcon then DF:UpdateRoleIcon(frame) end
            if DF.UpdateLeaderIcon then DF:UpdateLeaderIcon(frame) end
            if DF.UpdateRaidTargetIcon then DF:UpdateRaidTargetIcon(frame) end
            if DF.UpdateReadyCheckIcon then DF:UpdateReadyCheckIcon(frame) end
        end
    end)
    
    -- Debug output
    if DF:DebugActive("HEADERS") then
        headerDebug("Initialized child frame:", frame:GetName(), "Size:", frameWidth, "x", frameHeight)
    end
end


-- ============================================================
-- CONTAINER CREATION
-- ============================================================

function DF:CreateContainers()
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    -- Party container (holds player header + party header)
    -- Parent to existing DF.container so mover works automatically
    if not DF.partyContainer then
        local parent = DF.container or UIParent
        if DF:DebugActive("HEADERS") then
            headerDebug("Creating partyContainer, parent:", parent:GetName() or "UIParent")
        end
        
        -- CRITICAL: Ensure parent container is shown!
        if DF.container then
            DF.container:Show()
        end
        
        DF.partyContainer = CreateFrame("Frame", "DandersPartyContainer", parent, "SecureFrameTemplate")
        
        -- If parented to existing container, fill it
        -- Otherwise position independently
        if DF.container then
            DF.partyContainer:SetAllPoints(DF.container)
        else
            local partyScale = db.frameScale or 1.0
            DF.partyContainer:SetScale(partyScale)
            DF.partyContainer:SetPoint("CENTER", UIParent, "CENTER", (db.anchorX or 0) / partyScale, (db.anchorY or 0) / partyScale)
        end
        DF.partyContainer:SetSize(500, 200)
        DF.partyContainer:Show()
    end
    
    -- Raid container (separate from party, has its own position)
    if not DF.raidContainer then
        local raidScale = raidDb.frameScale or 1.0
        DF.raidContainer = CreateFrame("Frame", "DandersRaidContainer", UIParent, "SecureFrameTemplate")
        DF.raidContainer:SetScale(raidScale)
        DF.raidContainer:SetPoint("CENTER", UIParent, "CENTER", (raidDb.raidAnchorX or 0) / raidScale, (raidDb.raidAnchorY or 0) / raidScale)
        DF.raidContainer:SetSize(600, 400)
        DF.raidContainer:SetMovable(true)
        DF.raidContainer:Hide()
        
        -- Create raid mover frame
        DF:CreateRaidMoverFrame()
    end
end

-- ============================================================
-- PLAYER HEADER (Separate - for solo mode + self first/last)
-- ============================================================

-- ============================================================
-- PARTY HEADER (Single header for player + party1-4)
-- ============================================================

function DF:CreatePartyHeader()
    if DF.partyHeader then return end
    
    local db = DF:GetDB()
    
    DF.partyHeader = CreateFrame("Frame", "DandersPartyHeader", DF.partyContainer, "SecureGroupHeaderTemplate")
    
    -- Show player AND party members - sorting controlled by nameList or groupBy
    DF.partyHeader:SetAttribute("showPlayer", not db.hidePlayerFrame)
    DF.partyHeader:SetAttribute("showParty", true)
    DF.partyHeader:SetAttribute("showRaid", false)
    DF.partyHeader:SetAttribute("showSolo", db.soloMode or false)
    
    -- Template
    DF.partyHeader:SetAttribute("template", "DandersUnitButtonTemplate")

    -- Layout attributes
    -- ☠ WAS db.growHorizontal, WHICH NOTHING EVER WRITES. Three reads, zero writes,
    -- absent from Config -- so it was always nil and all three sites took the VERTICAL
    -- branch whatever the user chose. The rest of the addon spells this
    -- `growDirection == "HORIZONTAL"` (:1526, :1711, :3079).
    --
    -- ⚠ SCOPE: this was NOT "party frames are always vertical". DF:ApplyHeaderSettings
    -- reads growDirection correctly and calls SetPartyOrientation, so on the normal path
    -- the wrong orientation these two CREATE sites set is corrected straight afterwards.
    -- The one that could stand was UpdatePartyHeaderLayout: both its callers live in
    -- DF:ProcessHeaderCombatQueue, so it runs LAST on leaving combat with nothing
    -- re-applying the correct value behind it. Symptom: a party layout change queued
    -- during combat flips you to vertical when combat ends.
    -- ★ LIVE-ONLY: the preview reads growDirection via SecureSort:UpdateLayoutParams, so
    -- the preview was right and live was wrong. (Test-vs-live audit, 2026-08-07.)
    local horizontal = (db.growDirection == "HORIZONTAL")
    local spacing = db.frameSpacing or 2
    DF.partyHeader:SetAttribute("point", horizontal and "LEFT" or "TOP")
    -- IMPORTANT: Don't use Lua ternary with 0! (0 is falsy)
    if horizontal then
        DF.partyHeader:SetAttribute("xOffset", spacing)
        DF.partyHeader:SetAttribute("yOffset", 0)
    else
        DF.partyHeader:SetAttribute("xOffset", 0)
        DF.partyHeader:SetAttribute("yOffset", -spacing)
    end
    DF.partyHeader:SetAttribute("maxColumns", 1)
    DF.partyHeader:SetAttribute("unitsPerColumn", 5)
    
    -- Store layout values for secure positioning code
    DF.partyHeader:SetAttribute("frameWidth", db.frameWidth or 120)
    DF.partyHeader:SetAttribute("frameHeight", db.frameHeight or 50)
    DF.partyHeader:SetAttribute("spacing", db.frameSpacing or 2)
    DF.partyHeader:SetAttribute("horizontal", horizontal)
    -- (The `growFromCenter` attribute write that used to sit here was removed. It read a
    -- db key nothing defines or writes, and the ONLY snippet that consumed it was the
    -- isPlayerHeader branch of SetupSecurePositioning -- a branch never installed, since
    -- the separate player header was folded into partyHeader. CENTER growth is live and
    -- correct via `selfCentering`, which DF:SetGrowFromCenter writes.)

    -- SetFrameRef for secure snippets (Phase 3) - only if available
    if DF.partyHeader.SetFrameRef then
        DF.partyHeader:SetFrameRef("container", DF.partyContainer)
    end
    
    -- Initial position - anchor to container
    if horizontal then
        DF.partyHeader:SetPoint("LEFT", DF.partyContainer, "LEFT", 0, 0)
    else
        DF.partyHeader:SetPoint("TOP", DF.partyContainer, "TOP", 0, 0)
    end
    
    -- ============================================================
    -- STARTINGINDEX TRICK - Force create all 5 frames upfront (player + party1-4)
    -- This MUST happen at ADDON_LOADED for combat reload support!
    -- ============================================================
    DF.partyHeader:SetAttribute("startingIndex", -4)  -- Creates 5 frames
    DF.partyHeader:Show()
    DF.partyHeader:SetAttribute("startingIndex", 1)   -- Reset to normal operation
    
    if DF:DebugActive("HEADERS") then
        headerDebug("Created party header (includes player)")
        -- List created children
        C_Timer.After(0.1, function()
            for i = 1, 10 do
                local child = DF.partyHeader:GetAttribute("child" .. i)
                if child then
                    if DF:DebugActive("HEADERS") then
                        headerDebug("  Child " .. i .. ":", child:GetName())
                    end
                end
            end
        end)
    end
end

-- ============================================================
-- ARENA HEADER (Single header for raid1-5 in arena)
-- Uses PARTY SETTINGS but RAID UNIT IDs
-- Arena returns IsInRaid()=true but should use party-style layout
-- ============================================================

function DF:CreateArenaHeader()
    if DF.arenaHeader then return end
    
    -- Use PARTY settings (arena uses party-style layout)
    local db = DF:GetDB()
    
    -- Create in partyContainer (same position as party frames)
    DF.arenaHeader = CreateFrame("Frame", "DandersArenaHeader", DF.partyContainer, "SecureGroupHeaderTemplate")
    
    -- KEY DIFFERENCE: Use raid units, not party units
    -- This fixes aura issues because arena players ARE raid1-5, not party1-4
    DF.arenaHeader:SetAttribute("showPlayer", true)
    DF.arenaHeader:SetAttribute("showParty", false)  -- NOT party units
    DF.arenaHeader:SetAttribute("showRaid", true)    -- USE raid units
    DF.arenaHeader:SetAttribute("showSolo", false)
    
    -- Template
    DF.arenaHeader:SetAttribute("template", "DandersUnitButtonTemplate")
    
    -- Layout attributes - SAME as party
    -- ☠ WAS db.growHorizontal, WHICH NOTHING EVER WRITES. Three reads, zero writes,
    -- absent from Config -- so it was always nil and all three sites took the VERTICAL
    -- branch whatever the user chose. The rest of the addon spells this
    -- `growDirection == "HORIZONTAL"` (:1526, :1711, :3079).
    --
    -- ⚠ SCOPE: this was NOT "party frames are always vertical". DF:ApplyHeaderSettings
    -- reads growDirection correctly and calls SetPartyOrientation, so on the normal path
    -- the wrong orientation these two CREATE sites set is corrected straight afterwards.
    -- The one that could stand was UpdatePartyHeaderLayout: both its callers live in
    -- DF:ProcessHeaderCombatQueue, so it runs LAST on leaving combat with nothing
    -- re-applying the correct value behind it. Symptom: a party layout change queued
    -- during combat flips you to vertical when combat ends.
    -- ★ LIVE-ONLY: the preview reads growDirection via SecureSort:UpdateLayoutParams, so
    -- the preview was right and live was wrong. (Test-vs-live audit, 2026-08-07.)
    local horizontal = (db.growDirection == "HORIZONTAL")
    local spacing = db.frameSpacing or 2
    DF.arenaHeader:SetAttribute("point", horizontal and "LEFT" or "TOP")
    if horizontal then
        DF.arenaHeader:SetAttribute("xOffset", spacing)
        DF.arenaHeader:SetAttribute("yOffset", 0)
    else
        DF.arenaHeader:SetAttribute("xOffset", 0)
        DF.arenaHeader:SetAttribute("yOffset", -spacing)
    end
    DF.arenaHeader:SetAttribute("maxColumns", 1)
    DF.arenaHeader:SetAttribute("unitsPerColumn", 5)  -- Max 5 for arena (2v2, 3v3, 5v5)
    
    -- Store layout values for secure positioning code
    DF.arenaHeader:SetAttribute("frameWidth", db.frameWidth or 120)
    DF.arenaHeader:SetAttribute("frameHeight", db.frameHeight or 50)
    DF.arenaHeader:SetAttribute("spacing", db.frameSpacing or 2)
    DF.arenaHeader:SetAttribute("horizontal", horizontal)

    -- SetFrameRef for secure snippets
    if DF.arenaHeader.SetFrameRef then
        DF.arenaHeader:SetFrameRef("container", DF.partyContainer)
    end
    
    -- Initial position - anchor to container (same as party)
    if horizontal then
        DF.arenaHeader:SetPoint("LEFT", DF.partyContainer, "LEFT", 0, 0)
    else
        DF.arenaHeader:SetPoint("TOP", DF.partyContainer, "TOP", 0, 0)
    end
    
    -- ============================================================
    -- STARTINGINDEX TRICK - Force create all 5 frames upfront
    -- This MUST happen at ADDON_LOADED for combat reload support!
    -- ============================================================
    DF.arenaHeader:SetAttribute("startingIndex", -4)  -- Creates 5 frames
    DF.arenaHeader:Show()
    DF.arenaHeader:SetAttribute("startingIndex", 1)   -- Reset to normal operation
    DF.arenaHeader:Hide()  -- Start hidden, only show when in arena
    
    if DF:DebugActive("HEADERS") then
        headerDebug("Created arena header (raid units 1-5)")
        C_Timer.After(0.1, function()
            for i = 1, 10 do
                local child = DF.arenaHeader:GetAttribute("child" .. i)
                if child then
                    if DF:DebugActive("HEADERS") then
                        headerDebug("  Arena Child " .. i .. ":", child:GetName())
                    end
                end
            end
        end)
    end
end

-- ============================================================
-- RAID HEADERS
-- Two modes: Combined (single header) or Separated (8 headers)
-- ============================================================

function DF:CreateRaidHeaders()
    local db = DF:GetRaidDB()
    
    -- CRITICAL: The raidContainer must be shown for frame creation to work!
    -- Headers inside a hidden parent won't create child frames
    local containerWasHidden = not DF.raidContainer:IsShown()
    if containerWasHidden then
        DF.raidContainer:Show()
    end
    
    -- Create both modes, only one will be active at a time
    DF:CreateRaidCombinedHeader()
    DF:CreateRaidSeparatedHeaders()
    -- NOTE: raidPlayerHeader is no longer needed - nameList handles player positioning.
    -- The commented-out DF:CreateRaidPlayerHeader() call that sat here is gone with
    -- it: that function no longer exists anywhere, so uncommenting the line would
    -- have thrown rather than restored the old behaviour.

    -- Create secure position handler for raid groups
    DF:CreateRaidPositionHandler()
    
    -- Hide after a short delay to allow frame creation to complete
    -- BUT only if not in combat (combat reload case)
    C_Timer.After(0.1, function()
        -- Skip if in combat - can't Hide() secure frames
        if InCombatLockdown() then
            DF.pendingRaidHide = true
            return
        end
        
        -- Hide container if not in raid
        if not IsInRaid() then
            if DF.raidContainer then
                DF.raidContainer:Hide()
            end
            if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
                DF.FlatRaidFrames.header:Hide()
            end
            for i = 1, 8 do
                if DF.raidSeparatedHeaders and DF.raidSeparatedHeaders[i] then
                    DF.raidSeparatedHeaders[i]:Hide()
                end
            end
        end
        
        -- Debug: count frames after delay
        if DF:DebugActive("HEADERS") then
            local flatCount = 0
            if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
                for i = 1, 40 do
                    if DF.FlatRaidFrames.header:GetAttribute("child" .. i) then
                        flatCount = flatCount + 1
                    end
                end
            end
            headerDebug("FlatRaidFrames header children after delay:", flatCount)
            
            -- Count separated
            if DF.raidSeparatedHeaders then
                for g = 1, 8 do
                    local header = DF.raidSeparatedHeaders[g]
                    if header then
                        local count = 0
                        for i = 1, 5 do
                            if header:GetAttribute("child" .. i) then
                                count = count + 1
                            end
                        end
                        if count > 0 then
                            DF:Debug("HEADERS", "  Group %s header children: %s", g, count)
                        end
                    end
                end
            end
        end
    end)
end

-- ============================================================
-- APPLY FLAT LAYOUT ATTRIBUTES
-- Sets up the combined header based on growDirection and flat layout settings
-- Uses SecureGroupHeaderTemplate attributes:
--   point, xOffset, yOffset - how units position relative to each other
--   unitsPerColumn - units before wrapping to next column/row
--   maxColumns - maximum columns/rows
--   columnAnchorPoint, columnSpacing - how columns/rows position
-- ============================================================
-- OPTION A SIMPLIFICATION: This is now the single source of truth for flat layout.
-- Sets all attributes AND positions the header within the container.
-- Let SecureGroupHeaderTemplate auto-size the header based on visible children.
-- ============================================================
function DF:ApplyFlatLayoutAttributes()
    -- Legacy function - now delegates to FlatRaidFrames
    if DF.FlatRaidFrames and DF.FlatRaidFrames.initialized then
        DF.FlatRaidFrames:ApplyLayoutSettings()
    end
end

function DF:CreateRaidCombinedHeader()
    -- Legacy flat raid system has been removed
    -- All flat layouts now use FlatRaidFrames module
    headerDebug("CreateRaidCombinedHeader: Legacy system removed, using FlatRaidFrames")
end

-- Call-stack hooks for tracking what moves/resizes the raid container and the
-- flat header. The routine FLATRAID trace covers our own writes; these hooks
-- catch writes from ANYWHERE — Blizzard's SecureGroupHeader_Update, or another
-- addon — which is the only way to find a third party fighting us for position.
--
-- hooksecurefunc cannot be undone, so this stays opt-in behind a slash command
-- rather than riding the console category toggle. Output goes to the console
-- under FLATRAID so it can be copied out with the rest of the trace.
function DF:InstallFlatLayoutDebugHooks()
    -- ☠ LATCH PER SURFACE, NOT ONCE FOR THE WHOLE FUNCTION.
    -- The two blocks below each depend on a frame that may not exist yet. A single
    -- flag set unconditionally at the end meant running this before the raid container
    -- or flat header was created marked the tool "armed" with ZERO hooks installed —
    -- and the early-out then fired forever, so every later attempt answered "already
    -- armed. Reload to remove them." while tracing nothing, and the caller's "nothing
    -- to hook" branch became unreachable.
    --
    -- One flag per surface fixes both halves: a surface that did not exist yet can be
    -- picked up by a later run, and a surface already hooked is never double-hooked
    -- (hooksecurefunc cannot be undone, so a repeat would print every write twice).
    DF._flatDbgHooked = DF._flatDbgHooked or {}
    local hooked = DF._flatDbgHooked

    local function traceWrite(label)
        return function(_, a, b)
            if not DF:DebugActive("FLATRAID") then return end
            DF:Debug("FLATRAID", "HOOK %s(%s%s) from\n%s", label, tostring(a),
                b ~= nil and (", " .. tostring(b)) or "", debugstack(2, 20, 0) or "unknown")
        end
    end

    local added = 0

    if DF.raidContainer and not hooked.container then
        hooksecurefunc(DF.raidContainer, "SetSize", traceWrite("raidContainer:SetSize"))
        hooksecurefunc(DF.raidContainer, "SetPoint", traceWrite("raidContainer:SetPoint"))
        hooksecurefunc(DF.raidContainer, "ClearAllPoints", traceWrite("raidContainer:ClearAllPoints"))
        hooked.container = true
        added = added + 1
    end

    if DF.FlatRaidFrames and DF.FlatRaidFrames.header and not hooked.header then
        local header = DF.FlatRaidFrames.header
        hooksecurefunc(header, "SetSize", traceWrite("header:SetSize"))
        hooksecurefunc(header, "SetPoint", traceWrite("header:SetPoint"))
        hooksecurefunc(header, "ClearAllPoints", traceWrite("header:ClearAllPoints"))
        hooksecurefunc(header, "SetWidth", traceWrite("header:SetWidth"))
        hooksecurefunc(header, "SetHeight", traceWrite("header:SetHeight"))
        hooked.header = true
        added = added + 1
    end

    -- Reflects reality rather than "this ran": true once ANY surface is traced.
    DF.flatLayoutDebugHooksInstalled = (hooked.container or hooked.header) and true or false
    return added
end

-- Arms the call-stack hooks above. One-way: they cannot be removed until reload.
DF:RegisterDebugSlash("DFFLATDEBUG", "Trace every write to the raid container/header (until reload)", true, "/dfflatdebug")
SlashCmdList["DFFLATDEBUG"] = function()
    -- Ask the installer first and report what it DID. The old order asked the flag
    -- first and returned early on "already armed", which meant a run that had hooked
    -- only one of the two surfaces could never pick up the other.
    local added = DF:InstallFlatLayoutDebugHooks()

    if added > 0 then
        DF:Say("Call-stack hooks armed", added .. " surface(s)", "GOOD")
        DF:Say("Enable the FLATRAID category in the debug console to see them.")
    elseif DF.flatLayoutDebugHooksInstalled then
        DF:Say("Call-stack hooks are already armed. Reload to remove them.")
    else
        DF:Say("No raid container or flat header exists yet — nothing to hook.")
    end
end

-- Comprehensive state dump function. No longer its own slash command: it was
-- /dfflatstate, half of the flat-raid picture, while /df debug flatraid info printed
-- the other half. Both now run from /df debug flatraid.
-- Second half of the flat-raid picture, emitted INTO the caller's block.
-- ☠ Takes the writer rather than opening its own — it used to call DF:Out three
-- times, which turned three SECTIONS of one dump into three separate top-level
-- blocks, each with its own rule and title. /df debug flatraid looked like it was
-- running four commands. Promoting a section to a block is the inverse of the
-- bug that left dumps with no header at all, and the same conversion caused both.
--
-- Deliberately does NOT re-print module state or the settings FlatRaidFrames:
-- DebugPrint already covers — merging the two commands exposed that both were
-- printing raidUseGroups, growDirection and raidPlayersPerRow. Only what the
-- other half does not have lives here.
function DF:DumpFlatLayoutState(o)
    if not o then return end
    local db = DF:GetRaidDB()

    o:Section("Layout")
    o:Field("innerContainer", DF.FlatRaidFrames and DF.FlatRaidFrames.innerContainer and "exists" or "none",
        (DF.FlatRaidFrames and DF.FlatRaidFrames.innerContainer) and "GOOD" or "NEUTRAL")
    o:Field("growth anchor", db.raidFlatGrowthAnchor or "TOPLEFT", "NEUTRAL")
    o:Field("frame anchor", db.raidFlatFrameAnchor or "START", "NEUTRAL")
    o:Field("column anchor", db.raidFlatColumnAnchor or "START", "NEUTRAL")
    o:Field("spacing", (db.raidFlatHorizontalSpacing or 0) .. " h, " .. (db.raidFlatVerticalSpacing or 0) .. " v", "NEUTRAL")
    o:Field("frame size", (db.frameWidth or "?") .. " x " .. (db.frameHeight or "?"), "NEUTRAL")

    if not DF.raidContainer then
        o:Section("Raid container")
        o:Line("none", "BAD")
        return
    end
    local w, h = DF.raidContainer:GetSize()
    local point, _, relativePoint, x, y = DF.raidContainer:GetPoint(1)
    o:Section("Raid container", DF.raidContainer:IsShown() and "shown" or "hidden")
    o:Field("size", string.format("%.0f x %.0f", w, h), "NEUTRAL")
    o:Field("anchor", string.format("%s -> %s at %.0f, %.0f",
        tostring(point), tostring(relativePoint), x or 0, y or 0), "NEUTRAL")
end


-- ============================================================
-- DEBUG OVERLAY: Magenta boxes showing EXPECTED positions
-- Compare against actual SecureGroupHeaderTemplate positioning
-- ============================================================

-- Create/show debug overlay with magenta boxes at calculated positions
DF:RegisterDebugSlash("DFFLATOVERLAY", "Flat raid debug overlay", true, "/dfflatoverlay")
SlashCmdList["DFFLATOVERLAY"] = function()
    DF:ToggleFlatDebugOverlay()
end

function DF:ToggleFlatDebugOverlay()
    if DF.flatDebugOverlay and DF.flatDebugOverlay:IsShown() then
        DF.flatDebugOverlay:Hide()
        DF:Say("Overlay HIDDEN")
        return
    end
    
    DF:CreateFlatDebugOverlay()
    DF.flatDebugOverlay:Show()
    DF:Say("Overlay SHOWN - Magenta = expected positions, Cyan = actual child positions")
end

function DF:CreateFlatDebugOverlay()
    if not DF.raidContainer then
        DF:Say("No raidContainer exists!")
        return
    end
    
    local db = DF:GetRaidDB()
    local frameWidth = db.frameWidth or 80
    local frameHeight = db.frameHeight or 40
    local hSpacing = db.raidFlatHorizontalSpacing or 2
    local vSpacing = db.raidFlatVerticalSpacing or 2
    local horizontal = (db.growDirection == "HORIZONTAL")
    local playersPerUnit = db.raidPlayersPerRow or 5
    local reverseFill = db.raidFlatReverseFillOrder or false
    local anchor = db.raidFlatFrameAnchor or "START"
    local maxColumns = math.ceil(40 / playersPerUnit)
    
    -- Create overlay container if needed
    if not DF.flatDebugOverlay then
        DF.flatDebugOverlay = CreateFrame("Frame", "DFDebugOverlay", UIParent)
        DF.flatDebugOverlay:SetFrameStrata("HIGH")
        DF.flatDebugOverlay.expectedBoxes = {}
        DF.flatDebugOverlay.actualBoxes = {}
    end
    
    local overlay = DF.flatDebugOverlay
    
    -- Position overlay exactly where raidContainer is
    overlay:ClearAllPoints()
    overlay:SetAllPoints(DF.raidContainer)
    
    -- Clear old boxes
    for _, box in ipairs(overlay.expectedBoxes) do
        box:Hide()
    end
    for _, box in ipairs(overlay.actualBoxes) do
        box:Hide()
    end
    
    -- Calculate container size (same as PositionRaidHeaders)
    local containerWidth, containerHeight
    if horizontal then
        containerWidth = playersPerUnit * frameWidth + (playersPerUnit - 1) * hSpacing
        containerHeight = maxColumns * frameHeight + (maxColumns - 1) * vSpacing
    else
        containerWidth = maxColumns * frameWidth + (maxColumns - 1) * hSpacing
        containerHeight = playersPerUnit * frameHeight + (playersPerUnit - 1) * vSpacing
    end
    
    overlay:SetSize(containerWidth, containerHeight)
    
    -- Draw container outline (yellow)
    if not overlay.border then
        overlay.border = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
        overlay.border:SetAllPoints()
        overlay.border:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 2,
        })
        overlay.border:SetBackdropBorderColor(1, 1, 0, 1) -- Yellow
    end
    overlay.border:Show()
    
    local o = DF:Out("Flat Overlay", "geometry")
    o:Field("Container size", containerWidth .. " x " .. containerHeight)
    o:Field("horizontal", tostring(horizontal))
    o:Field("playersPerUnit", playersPerUnit)
    o:Field("spacing", hSpacing .. " h, " .. vSpacing .. " v")
    o:Field("anchor", anchor)
    o:Field("reverseFill", tostring(reverseFill))
    
    -- Create EXPECTED position boxes (magenta) - our calculated positions
    -- This uses the math WE think SecureGroupHeaderTemplate should use
    for i = 1, 40 do
        local box = overlay.expectedBoxes[i]
        if not box then
            box = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
            box:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
            })
            box:SetBackdropColor(1, 0, 1, 0.3) -- Magenta, semi-transparent
            box:SetBackdropBorderColor(1, 0, 1, 1) -- Magenta border
            overlay.expectedBoxes[i] = box
            
            -- Add slot number text
            box.text = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            box.text:SetPoint("CENTER")
            box.text:SetTextColor(1, 1, 1, 1)
        end
        
        box:SetSize(frameWidth - 4, frameHeight - 4) -- Slightly smaller to see overlap
        box.text:SetText(i)
        
        -- Calculate position based on slot index
        local col, row
        if horizontal then
            -- HORIZONTAL: fill rows first (slot 1-5 in row 1, 6-10 in row 2, etc.)
            col = ((i - 1) % playersPerUnit)  -- 0-based column within row
            row = math.floor((i - 1) / playersPerUnit)  -- 0-based row
        else
            -- VERTICAL: fill columns first (slot 1-5 in col 1, 6-10 in col 2, etc.)
            row = ((i - 1) % playersPerUnit)  -- 0-based row within column
            col = math.floor((i - 1) / playersPerUnit)  -- 0-based column
        end
        
        -- Calculate x, y position from TOPLEFT of container
        local x, y
        
        if horizontal then
            -- X: columns go left-to-right (or right-to-left if reversed)
            if reverseFill then
                x = containerWidth - (col + 1) * frameWidth - col * hSpacing
            else
                x = col * (frameWidth + hSpacing)
            end
            
            -- Y: rows go top-to-bottom (START/CENTER) or bottom-to-top (END)
            if anchor == "END" then
                y = -(containerHeight - (row + 1) * frameHeight - row * vSpacing)
            else
                y = -(row * (frameHeight + vSpacing))
            end
        else
            -- VERTICAL mode
            -- X: columns go left-to-right (START/CENTER) or right-to-left (END)
            if anchor == "END" then
                x = containerWidth - (col + 1) * frameWidth - col * hSpacing
            else
                x = col * (frameWidth + hSpacing)
            end
            
            -- Y: rows go top-to-bottom (or bottom-to-top if reversed)
            if reverseFill then
                y = -(containerHeight - (row + 1) * frameHeight - row * vSpacing)
            else
                y = -(row * (frameHeight + vSpacing))
            end
        end
        
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", overlay, "TOPLEFT", x + 2, y - 2) -- +2/-2 for inset
        box:Show()
    end
    
    -- Create ACTUAL position boxes (cyan) - where SecureGroupHeaderTemplate put them
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        for i = 1, 40 do
            local child = DF.FlatRaidFrames.header:GetAttribute("child" .. i)
            if child then
                local box = overlay.actualBoxes[i]
                if not box then
                    box = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
                    box:SetBackdrop({
                        edgeFile = "Interface\\Buttons\\WHITE8x8",
                        edgeSize = 2,
                    })
                    box:SetBackdropBorderColor(0, 1, 1, 1) -- Cyan border
                    overlay.actualBoxes[i] = box
                    
                    -- Add child number text
                    box.text = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    box.text:SetPoint("BOTTOMRIGHT", -2, 2)
                    box.text:SetTextColor(0, 1, 1, 1)
                end
                
                -- Get child's actual position relative to container
                local childLeft = child:GetLeft()
                local childTop = child:GetTop()
                local containerLeft = DF.raidContainer:GetLeft()
                local containerTop = DF.raidContainer:GetTop()
                
                if childLeft and childTop and containerLeft and containerTop then
                    local relX = childLeft - containerLeft
                    local relY = childTop - containerTop
                    
                    box:SetSize(child:GetWidth(), child:GetHeight())
                    box:ClearAllPoints()
                    box:SetPoint("TOPLEFT", overlay, "TOPLEFT", relX, relY)
                    box.text:SetText("c" .. i)
                    box:Show()
                else
                    box:Hide()
                end
            end
        end
    end
    
    DF:Say("Overlay created with 40 expected (magenta) + actual (cyan) boxes")
end

function DF:CreateRaidSeparatedHeaders()
    if DF.raidSeparatedHeaders and DF.raidSeparatedHeaders[1] then return end
    
    local db = DF:GetRaidDB()
    local horizontal = (db.growDirection == "HORIZONTAL")  -- Groups as columns
    
    DF.raidSeparatedHeaders = {}
    
    -- Colors for each group (for debug visualization)
    local groupColors = {
        {1, 0, 0, 0.3},      -- Group 1: Red
        {0, 1, 0, 0.3},      -- Group 2: Green
        {0, 0, 1, 0.3},      -- Group 3: Blue
        {1, 1, 0, 0.3},      -- Group 4: Yellow
        {1, 0, 1, 0.3},      -- Group 5: Magenta
        {0, 1, 1, 0.3},      -- Group 6: Cyan
        {1, 0.5, 0, 0.3},    -- Group 7: Orange
        {0.5, 0, 1, 0.3},    -- Group 8: Purple
    }
    
    for group = 1, 8 do
        local header = CreateFrame("Frame", "DandersRaidGroup" .. group .. "Header", DF.raidContainer, "SecureGroupHeaderTemplate")
        
        -- Only show this specific group
        header:SetAttribute("showPlayer", true)
        header:SetAttribute("showParty", false)
        header:SetAttribute("showRaid", true)
        header:SetAttribute("showSolo", false)
        header:SetAttribute("groupFilter", tostring(group))  -- Only this group!
        
        -- Template
        header:SetAttribute("template", "DandersUnitButtonTemplate")
        
        -- Layout depends on growDirection
        -- Note: point=TOP/LEFT keeps player order consistent (first at top/left)
        -- The secure snippet handles where the GROUP is positioned (START/END)
        -- ☠ SNAPPED, per the rule in UpdateRaidHeaderLayoutAttributes. This is the
        -- INTRA-group player stride, and a group's own size is derived as
        -- 5 * frameHeight + 4 * spacing from the SNAPPED spacing. Feeding the raw value
        -- here put the players inside a group on a different stride from the box the
        -- group occupies -- the same producer split the five-value rule exists for, just
        -- one level down. pixelPerfect defaults to TRUE.
        local spacing = db.frameSpacing or 2
        if db.pixelPerfect and DF.PixelPerfect then spacing = DF:PixelPerfect(spacing) end
        if horizontal then
            -- HORIZONTAL: Groups as columns, players stacked vertically (top to bottom)
            header:SetAttribute("point", "TOP")
            header:SetAttribute("columnAnchorPoint", "LEFT")
            header:SetAttribute("xOffset", 0)
            header:SetAttribute("yOffset", -spacing)
        else
            -- VERTICAL: Groups as rows, players arranged horizontally (left to right)
            header:SetAttribute("point", "LEFT")
            header:SetAttribute("columnAnchorPoint", "TOP")
            header:SetAttribute("xOffset", spacing)
            header:SetAttribute("yOffset", 0)
        end
        header:SetAttribute("unitsPerColumn", 5)
        header:SetAttribute("maxColumns", 1)
        
        -- Store for secure positioning
        header:SetAttribute("groupIndex", group)
        header:SetAttribute("frameWidth", db.frameWidth or 80)
        header:SetAttribute("frameHeight", db.frameHeight or 40)
        header:SetAttribute("spacing", db.frameSpacing or 2)
        
        -- Debug background (toggle with /df debug raidbg)
        local debugBg = header:CreateTexture(nil, "BACKGROUND")
        debugBg:SetAllPoints()
        debugBg:SetColorTexture(unpack(groupColors[group]))
        debugBg:Hide()
        header.debugBackground = debugBg
        
        -- Group number label
        local label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOP", header, "TOP", 0, -2)
        label:SetText(group)
        label:Hide()
        header.debugLabel = label
        
        -- SetFrameRef for secure snippets (Phase 3) - only if available
        if header.SetFrameRef then
            header:SetFrameRef("container", DF.raidContainer)
        end
        
        -- Force create 5 frames per group using startingIndex trick
        header:SetAttribute("startingIndex", -4)
        header:Show()
        header:SetAttribute("startingIndex", 1)
        -- DON'T hide immediately - let frame creation complete
        
        DF.raidSeparatedHeaders[group] = header
    end
    
    headerDebug("Created 8 separated raid headers")
end

-- ============================================================
-- SECURE RAID GROUP POSITIONING
-- All positioning is done in secure code so it works in combat
-- Lua only sets attributes, secure code does all positioning
-- ============================================================

-- ☠ RETIRED. Returns (0, 0) UNCONDITIONALLY. See the block inside the function for why,
-- and read that before changing anything here.
--
-- This header used to describe the live mechanism: an inverse offset that shifted the
-- container to hold CENTER content still as popRows grew, against #867. Every word of
-- that is now false, including the list of cases it claimed to return (0,0) for -- there
-- are no cases, it always does. It is replaced rather than kept as history because a
-- reader who stops above the signature would take the retired story as current fact, and
-- the description it gave was itself the reasoning that got reversed twice in 24h.
--
-- Two facts worth having here so nobody re-derives them:
--   * CENTER has no drift to cancel. The container is always sized for all eight groups
--     and the block is centred with (total - populated) / 2, so it grows SYMMETRICALLY
--     about the container centre and the centroid is invariant under popRows. Verified
--     numerically across 512 configurations, both positioners, both axes.
--   * #867 was the compounding defect (a centred block also taking a row index flipped
--     over the FULL grid), fixed at source in 50a3e7c5 -- not centring drift.
function DF:ComputeRaidContainerCompensation()
    -- ☠ RETIRED, ALWAYS ZERO. It was zeroed in b0e84ae3, restored in b0e58e79 on the
    -- argument below, and re-zeroed the same day when the restore was tested in game.
    -- Read the whole block before touching it -- the restore looked well reasoned and
    -- was still wrong.
    --
    -- WHY THERE IS NOTHING TO COMPENSATE. CENTER grows the populated block SYMMETRICALLY
    -- ABOUT THE CONTAINER CENTRE, because the container is always sized for all eight
    -- groups and xStart is (totalWidth - populatedWidth) / 2. Two columns' worth of box,
    -- one populated column: content sits [0.5col, 1.5col], centred at 1col. Two
    -- populated columns: content sits [0, 2col], still centred at 1col. THE CENTROID IS
    -- ALREADY INVARIANT UNDER popRows. The body below instead pins the block's LEADING
    -- EDGE to the popRows==1 position, so it does not cancel a drift -- it INTRODUCES
    -- one, of (populatedDim - groupDim) / 2. Observed in game as the whole container and
    -- mover dragged half a group-column left, frames correctly placed inside it, at
    -- Wrap 7 / Center Right / 8 groups (Krathe, 2026-08-18).
    --
    -- WHAT #867 ACTUALLY WAS. Not centring drift: the compounding. Born 2026-03-10 in
    -- eb878888 with the wrap growth setting -- a block centred by yStart also took a row
    -- index already flipped over the FULL grid, two reference frames summed, error
    -- (fullGridRC - popRows) group rows. That changes as the roster changes, which is
    -- the reported "frames shoot off the top of the screen when a player joins a group".
    -- ☠ THE TELL IS IN #867's OWN CHANGELOG: recovery "required a Groups Grow From
    -- toggle" -- Grow From is groupRowGrowth, the exact setting that triggers the
    -- compounding. f3216d3c (2026-05-02, 4.3.7) compensated the CONTAINER instead of
    -- fixing the maths, i.e. a workaround one layer below the bug. The bug itself is
    -- fixed at source in 50a3e7c5, so this has nothing left to do.
    --
    -- ☠ IF #867-STYLE JUMPING EVER COMES BACK, IT IS THE POSITIONER, NOT THIS. Do not
    -- reinstate a container nudge to hide it. The body stays only as the record of what
    -- was tried; delete it outright in the next tidy-up.
    do return 0, 0 end

    local db = DF:GetRaidDB()
    if not db then return 0, 0 end
    if not db.raidUseGroups then return 0, 0 end
    if (db.raidGroupAnchor or "START") ~= "CENTER" then return 0, 0 end

    -- ★ ONE compensation, MODE-AWARE — this function is now the single source of the
    -- CENTER shift. The live container, the TEST container and the MOVER all take it
    -- in UpdateRaidContainerPosition; the test frame calculator carries NONE of it
    -- (its old lp.testMode comp block is retired — see CalculateRaidGroupPosition).
    -- The unlock overlay is only faithful if all three read the SAME number, which is
    -- why there is exactly one ("overlay is not faithful when groups-per-row < 8",
    -- Aphoex 2026-08-15: content sat half a group-row below the box because the
    -- container carried the shift and the mover never did).
    -- In test mode the populated count comes from the TEST roster (5 per group,
    -- mirroring LightweightPositionRaidTestFrames): the handler attributes describe
    -- the LIVE roster, which solo is ZERO populated groups — the comp would read 0
    -- while the preview simulates eight.
    local numPopulated = 0
    if DF.raidTestMode then
        local testCount = db.raidTestFrameCount or 10
        numPopulated = math.min(8, math.ceil(testCount / 5))
    else
        if not DF.raidPositionHandler then return 0, 0 end
        if not DF.raidSeparatedHeaders then return 0, 0 end
        -- Mirror the snippet: a group is "populated" when its child count > 0.
        -- Read counts from the same handler attributes the snippet reads, so the
        -- compensation always agrees with the snippet's view of the world.
        local handler = DF.raidPositionHandler
        for i = 1, 8 do
            local count = handler:GetAttribute("group" .. i .. "count") or 0
            if count > 0 then numPopulated = numPopulated + 1 end
        end
    end
    if numPopulated == 0 then return 0, 0 end

    -- Mirror the snippet's totalHeight / populatedHeight calculation.
    local groupsPerRow = db.raidGroupsPerRow or 8
    if groupsPerRow < 1 then groupsPerRow = 1 end
    if groupsPerRow > 8 then groupsPerRow = 8 end

    local growDirection = db.growDirection or "HORIZONTAL"
    local isHorizontal = (growDirection == "HORIZONTAL")
    local frameWidth = db.frameWidth or 80
    local frameHeight = db.frameHeight or 40
    local spacing = db.frameSpacing or 2
    local rowColSpacing = db.raidRowColSpacing or 30

    local groupHeight, groupWidth
    if isHorizontal then
        groupWidth = frameWidth
        groupHeight = 5 * frameHeight + 4 * spacing
    else
        groupWidth = 5 * frameWidth + 4 * spacing
        groupHeight = frameHeight
    end

    -- popRows = ceil(numPopulated / groupsPerRow)
    local popRem = numPopulated % groupsPerRow
    local popRows = (numPopulated - popRem) / groupsPerRow
    if popRem > 0 then popRows = popRows + 1 end

    -- popRows == 1 is the reference state — compensation is zero there. Skip the
    -- rest to avoid pointless arithmetic and to match existing behaviour exactly
    -- when the bug doesn't apply.
    if popRows <= 1 then return 0, 0 end

    -- The drift dimension depends on growDirection: HORIZONTAL = vertical drift,
    -- VERTICAL = horizontal drift. (Per the snippet's totalHeight/populatedHeight
    -- vs totalWidth/populatedWidth selection at lines 2492-2498.)
    local groupDim, populatedDim
    if isHorizontal then
        groupDim = groupHeight
        populatedDim = popRows * groupHeight + (popRows - 1) * rowColSpacing
    else
        groupDim = groupWidth
        populatedDim = popRows * groupWidth + (popRows - 1) * rowColSpacing
    end

    -- Compensation = (groupDim - populatedDim) / 2. This is yStart_now minus
    -- yStart_at_popRows1, so popRows=1 yields zero (existing behaviour preserved)
    -- and popRows>1 yields a negative offset that shifts the container in the
    -- direction opposite to the snippet's content drift. Net visual: visible
    -- content's TOP edge stays where popRows=1 layout placed it for every
    -- larger populated count.
    local compensation = (groupDim - populatedDim) / 2
    if isHorizontal then
        return 0, compensation
    else
        return compensation, 0
    end
end

-- "Anchor To: Main Group" — the CONSTANT anchor-reference offset.
--
-- ☠ THIS IS NOT THE COMPENSATION ABOVE, AND MUST NEVER GROW A ROSTER TERM. The retired
-- ComputeRaidContainerCompensation failed because it computed from popRows — a value
-- that changes as people join — and then three surfaces (container, mover, test) each
-- needed their own copy of the lie. This function reads SETTINGS ONLY. Same inputs,
-- same output, whether the raid has 1 group or 8.
--
-- What it does: with Groups Anchor = CENTER and Anchor To = Main Group, the positioner
-- places wrap units at FIXED slots (see anchorToMain in the snippet), so the first wrap
-- unit always occupies the same slot of the reserved grid. This returns the constant
-- shift that puts THAT unit's centreline on the saved anchor instead of the grid's
-- centre. Which end the main unit sits at depends on the wrap key AND the players
-- anchor (players = END mirrors the wrap axis in the snippet corners; the two flips
-- cancel, hence the equality test below).
--
-- Returns (dx, dy) added to the container anchor BEFORE the frameScale division, for
-- container, mover and test container alike — one number, three consumers, like every
-- other piece of this geometry. (0, 0) unless the mode is on and the grid actually
-- wraps.
function DF:ComputeRaidMainGroupAnchorOffset()
    local db = DF:GetRaidDB()
    if not db then return 0, 0 end
    if not db.raidUseGroups then return 0, 0 end
    if (db.raidGroupAnchor or "START") ~= "CENTER" then return 0, 0 end
    if (db.raidGroupCenterMode or "ALL") ~= "MAIN" then return 0, 0 end

    local groupsPerRow = db.raidGroupsPerRow or 8
    if groupsPerRow < 1 then groupsPerRow = 1 end
    if groupsPerRow > 8 then groupsPerRow = 8 end
    local rem8 = 8 % groupsPerRow
    local fullGridRC = (8 - rem8) / groupsPerRow
    if rem8 > 0 then fullGridRC = fullGridRC + 1 end
    -- One wrap unit = nothing hangs off = the grid centre IS the unit centre.
    if fullGridRC <= 1 then return 0, 0 end

    -- Snapped like the handler's snapInit seeds, so this offset lives on the same
    -- stride as the geometry it repositions.
    local frameWidth = db.frameWidth or 80
    local frameHeight = db.frameHeight or 40
    local spacing = db.frameSpacing or 2
    local rowColSpacing = db.raidRowColSpacing or 30
    if db.pixelPerfect and DF.PixelPerfect then
        frameWidth = DF:PixelPerfect(frameWidth)
        frameHeight = DF:PixelPerfect(frameHeight)
        spacing = DF:PixelPerfect(spacing)
        rowColSpacing = DF:PixelPerfect(rowColSpacing)
    end

    local isHorizontal = (db.growDirection or "HORIZONTAL") == "HORIZONTAL"
    local groupDim
    if isHorizontal then
        groupDim = 5 * frameHeight + 4 * spacing   -- wrap axis is Y
    else
        groupDim = 5 * frameWidth + 4 * spacing    -- wrap axis is X
    end
    local total = fullGridRC * groupDim + (fullGridRC - 1) * rowColSpacing
    local m = (total - groupDim) / 2

    -- Where does the main unit sit inside the grid? Players = END mirrors the wrap
    -- axis (TOPRIGHT/BOTTOMLEFT corners with negated offsets); wrap = END flips the
    -- slot index over the full grid. Both flips together cancel.
    local playersEnd = (db.raidPlayerAnchor or "START") == "END"
    local wrapEnd = (db.raidGroupRowGrowth or "START") == "END"
    local mainAtNear = (playersEnd == wrapEnd)   -- near = TOP (horizontal) / LEFT (vertical)

    if isHorizontal then
        -- Main at the top of the grid means its centre sits m ABOVE the grid centre,
        -- so the container moves DOWN (negative y) to land it on the anchor.
        return 0, mainAtNear and -m or m
    else
        -- Main at the left means its centre sits m LEFT of the grid centre, so the
        -- container moves RIGHT (positive x).
        return mainAtNear and m or -m, 0
    end
end

function DF:CreateRaidPositionHandler()
    if DF.raidPositionHandler then return end
    if not DF.raidContainer then return end
    if not DF.raidSeparatedHeaders then return end
    
    -- CRITICAL: SecureHandlerWrapScript requires combat-safe window
    if InCombatLockdown() then
        DF:Err("Cannot create raid position handler in combat")
        DF.pendingRaidPositionHandler = true
        return
    end
    
    local db = DF:GetRaidDB()
    
    -- Create the secure handler
    DF.raidPositionHandler = CreateFrame("Frame", "DandersRaidPositionHandler", UIParent, "SecureHandlerBaseTemplate")
    local handler = DF.raidPositionHandler
    
    -- Store frame refs
    SecureHandlerSetFrameRef(handler, "container", DF.raidContainer)
    for i = 1, 8 do
        if DF.raidSeparatedHeaders[i] then
            SecureHandlerSetFrameRef(handler, "group" .. i, DF.raidSeparatedHeaders[i])
        end
    end
    
    -- Initialize layout attributes (all lowercase)
    -- ☠ SNAPPED, SAME FIVE VALUES. This is the SIXTH producer of the same geometry and it
    -- was seeding RAW db numbers while UpdateRaidHeaderLayoutAttributes and
    -- UpdateRaidGroupLayoutParams both pushed snapped ones. The snippet fires on
    -- triggerposition, which the per-header child hook bumps independently, so between
    -- handler creation and the first attribute update the live layout ran on unsnapped
    -- geometry while SecureSort's side was snapped -- the exact producer split the rule at
    -- UpdateRaidHeaderLayoutAttributes exists to prevent. Transient and sub-pixel, but it
    -- is a real fork and it would bite whoever adds a sixth value.
    local function snapInit(value)
        if db.pixelPerfect and DF.PixelPerfect then
            return DF:PixelPerfect(value)
        end
        return value
    end
    handler:SetAttribute("framewidth", snapInit(db.frameWidth or 80))
    handler:SetAttribute("frameheight", snapInit(db.frameHeight or 40))
    handler:SetAttribute("spacing", snapInit(db.frameSpacing or 2))
    handler:SetAttribute("groupspacing", snapInit(db.raidGroupSpacing or 10))
    handler:SetAttribute("playergrowfrom", db.raidPlayerAnchor or "START")
    handler:SetAttribute("groupsgrowfrom", db.raidGroupAnchor or "START")
    handler:SetAttribute("growdirection", db.growDirection or "HORIZONTAL")
    handler:SetAttribute("groupsperrow", db.raidGroupsPerRow or 8)
    handler:SetAttribute("rowcolspacing", snapInit(db.raidRowColSpacing or 30))
    handler:SetAttribute("grouprowgrowth", db.raidGroupRowGrowth or "START")
    -- Anchor To: Main Group. 1 = pin the first wrap unit at a fixed, centred slot
    -- (constant placement); 0 = centre the whole populated block (default). Numeric,
    -- like centerless flags elsewhere -- string compares in snippets are a needless risk.
    handler:SetAttribute("anchortomain", ((db.raidGroupCenterMode or "ALL") == "MAIN") and 1 or 0)
    handler:SetAttribute("flatmodeactive", (not db.raidUseGroups) and 1 or 0)

    -- Initialize display order attributes.
    -- ☠ Through the shared producer, not raw db. This read raidGroupDisplayOrder directly,
    -- which ignored My Group First and skipped the per-entry validation, so the seed order
    -- disagreed with what UpdateRaidGroupOrderAttributes writes moments later.
    local displayOrder = DF:GetEffectiveRaidGroupOrder(db)
    for i = 1, 8 do
        handler:SetAttribute("displayorder" .. i, displayOrder[i] or i)
    end
    
    -- The main positioning snippet - supports both HORIZONTAL and VERTICAL layouts
    -- with row/column wrapping via groupsperrow
    -- NOTE: Cannot use 'function' keyword in secure snippets, must inline everything
    local positionSnippet = [[
        local handler = self
        local container = handler:GetFrameRef("container")
        if not container then return end

        -- Batch mode: skip repositioning until all group counts are synced
        local suppress = handler:GetAttribute("suppressreposition")
        if suppress and suppress == 1 then return end

        -- Flat mode: flat raid manages its own container sizing — grouped
        -- repositioning must not stomp on it
        local flatActive = handler:GetAttribute("flatmodeactive")
        if flatActive and flatActive == 1 then return end

        -- Get all group refs explicitly (no string concat in loop)
        local group1 = handler:GetFrameRef("group1")
        local group2 = handler:GetFrameRef("group2")
        local group3 = handler:GetFrameRef("group3")
        local group4 = handler:GetFrameRef("group4")
        local group5 = handler:GetFrameRef("group5")
        local group6 = handler:GetFrameRef("group6")
        local group7 = handler:GetFrameRef("group7")
        local group8 = handler:GetFrameRef("group8")
        
        -- Read layout attributes
        local frameWidth = handler:GetAttribute("framewidth") or 80
        local frameHeight = handler:GetAttribute("frameheight") or 40
        local spacing = handler:GetAttribute("spacing") or 2
        local groupSpacing = handler:GetAttribute("groupspacing") or 10
        local playerGrowFrom = handler:GetAttribute("playergrowfrom") or "START"
        local groupsGrowFrom = handler:GetAttribute("groupsgrowfrom") or "START"
        local growDirection = handler:GetAttribute("growdirection") or "HORIZONTAL"
        local groupsPerRow = handler:GetAttribute("groupsperrow") or 8
        local rowColSpacing = handler:GetAttribute("rowcolspacing") or 30
        local groupRowGrowth = handler:GetAttribute("grouprowgrowth") or "START"
        local anchorToMain = handler:GetAttribute("anchortomain") or 0

        if groupsPerRow < 1 then groupsPerRow = 1 end
        if groupsPerRow > 8 then groupsPerRow = 8 end
        
        local isHorizontal = (growDirection == "HORIZONTAL")
        
        -- Group dimensions depend on layout direction
        local groupWidth, groupHeight
        if isHorizontal then
            groupWidth = frameWidth
            groupHeight = 5 * frameHeight + 4 * spacing
        else
            groupWidth = 5 * frameWidth + 4 * spacing
            groupHeight = frameHeight
        end
        
        -- Full grid rows/cols: ceil(8 / groupsPerRow)
        local rem8 = 8 % groupsPerRow
        local fullGridRC = (8 - rem8) / groupsPerRow
        if rem8 > 0 then fullGridRC = fullGridRC + 1 end
        
        -- Container size based on full grid with row/column wrapping
        local totalWidth, totalHeight
        if isHorizontal then
            totalWidth = groupsPerRow * groupWidth + (groupsPerRow - 1) * groupSpacing
            totalHeight = fullGridRC * groupHeight + (fullGridRC - 1) * rowColSpacing
        else
            totalWidth = fullGridRC * groupWidth + (fullGridRC - 1) * rowColSpacing
            totalHeight = groupsPerRow * groupHeight + (groupsPerRow - 1) * groupSpacing
        end
        container:SetWidth(totalWidth)
        container:SetHeight(totalHeight)
        
        -- Read child counts from handler attributes
        local g1count = handler:GetAttribute("group1count") or 0
        local g2count = handler:GetAttribute("group2count") or 0
        local g3count = handler:GetAttribute("group3count") or 0
        local g4count = handler:GetAttribute("group4count") or 0
        local g5count = handler:GetAttribute("group5count") or 0
        local g6count = handler:GetAttribute("group6count") or 0
        local g7count = handler:GetAttribute("group7count") or 0
        local g8count = handler:GetAttribute("group8count") or 0
        
        -- Read custom display order (which group goes in each display position)
        local d1 = handler:GetAttribute("displayorder1") or 1
        local d2 = handler:GetAttribute("displayorder2") or 2
        local d3 = handler:GetAttribute("displayorder3") or 3
        local d4 = handler:GetAttribute("displayorder4") or 4
        local d5 = handler:GetAttribute("displayorder5") or 5
        local d6 = handler:GetAttribute("displayorder6") or 6
        local d7 = handler:GetAttribute("displayorder7") or 7
        local d8 = handler:GetAttribute("displayorder8") or 8
        
        -- Get count for each display position's group (inline lookups)
        local c1 = 0
        if d1 == 1 then c1 = g1count elseif d1 == 2 then c1 = g2count elseif d1 == 3 then c1 = g3count elseif d1 == 4 then c1 = g4count
        elseif d1 == 5 then c1 = g5count elseif d1 == 6 then c1 = g6count elseif d1 == 7 then c1 = g7count elseif d1 == 8 then c1 = g8count end
        
        local c2 = 0
        if d2 == 1 then c2 = g1count elseif d2 == 2 then c2 = g2count elseif d2 == 3 then c2 = g3count elseif d2 == 4 then c2 = g4count
        elseif d2 == 5 then c2 = g5count elseif d2 == 6 then c2 = g6count elseif d2 == 7 then c2 = g7count elseif d2 == 8 then c2 = g8count end
        
        local c3 = 0
        if d3 == 1 then c3 = g1count elseif d3 == 2 then c3 = g2count elseif d3 == 3 then c3 = g3count elseif d3 == 4 then c3 = g4count
        elseif d3 == 5 then c3 = g5count elseif d3 == 6 then c3 = g6count elseif d3 == 7 then c3 = g7count elseif d3 == 8 then c3 = g8count end
        
        local c4 = 0
        if d4 == 1 then c4 = g1count elseif d4 == 2 then c4 = g2count elseif d4 == 3 then c4 = g3count elseif d4 == 4 then c4 = g4count
        elseif d4 == 5 then c4 = g5count elseif d4 == 6 then c4 = g6count elseif d4 == 7 then c4 = g7count elseif d4 == 8 then c4 = g8count end
        
        local c5 = 0
        if d5 == 1 then c5 = g1count elseif d5 == 2 then c5 = g2count elseif d5 == 3 then c5 = g3count elseif d5 == 4 then c5 = g4count
        elseif d5 == 5 then c5 = g5count elseif d5 == 6 then c5 = g6count elseif d5 == 7 then c5 = g7count elseif d5 == 8 then c5 = g8count end
        
        local c6 = 0
        if d6 == 1 then c6 = g1count elseif d6 == 2 then c6 = g2count elseif d6 == 3 then c6 = g3count elseif d6 == 4 then c6 = g4count
        elseif d6 == 5 then c6 = g5count elseif d6 == 6 then c6 = g6count elseif d6 == 7 then c6 = g7count elseif d6 == 8 then c6 = g8count end
        
        local c7 = 0
        if d7 == 1 then c7 = g1count elseif d7 == 2 then c7 = g2count elseif d7 == 3 then c7 = g3count elseif d7 == 4 then c7 = g4count
        elseif d7 == 5 then c7 = g5count elseif d7 == 6 then c7 = g6count elseif d7 == 7 then c7 = g7count elseif d7 == 8 then c7 = g8count end
        
        local c8 = 0
        if d8 == 1 then c8 = g1count elseif d8 == 2 then c8 = g2count elseif d8 == 3 then c8 = g3count elseif d8 == 4 then c8 = g4count
        elseif d8 == 5 then c8 = g5count elseif d8 == 6 then c8 = g6count elseif d8 == 7 then c8 = g7count elseif d8 == 8 then c8 = g8count end
        
        -- Count populated groups in DISPLAY ORDER and assign slots
        -- popN = "what slot is group N in?" (0 if not populated)
        local numPopulated = 0
        local pop1, pop2, pop3, pop4, pop5, pop6, pop7, pop8 = 0, 0, 0, 0, 0, 0, 0, 0
        
        -- Check display position 1 (group d1)
        if c1 > 0 then
            numPopulated = numPopulated + 1
            if d1 == 1 then pop1 = numPopulated
            elseif d1 == 2 then pop2 = numPopulated
            elseif d1 == 3 then pop3 = numPopulated
            elseif d1 == 4 then pop4 = numPopulated
            elseif d1 == 5 then pop5 = numPopulated
            elseif d1 == 6 then pop6 = numPopulated
            elseif d1 == 7 then pop7 = numPopulated
            elseif d1 == 8 then pop8 = numPopulated
            end
        end
        
        -- Check display position 2 (group d2)
        if c2 > 0 then
            numPopulated = numPopulated + 1
            if d2 == 1 then pop1 = numPopulated
            elseif d2 == 2 then pop2 = numPopulated
            elseif d2 == 3 then pop3 = numPopulated
            elseif d2 == 4 then pop4 = numPopulated
            elseif d2 == 5 then pop5 = numPopulated
            elseif d2 == 6 then pop6 = numPopulated
            elseif d2 == 7 then pop7 = numPopulated
            elseif d2 == 8 then pop8 = numPopulated
            end
        end
        
        -- Check display position 3 (group d3)
        if c3 > 0 then
            numPopulated = numPopulated + 1
            if d3 == 1 then pop1 = numPopulated
            elseif d3 == 2 then pop2 = numPopulated
            elseif d3 == 3 then pop3 = numPopulated
            elseif d3 == 4 then pop4 = numPopulated
            elseif d3 == 5 then pop5 = numPopulated
            elseif d3 == 6 then pop6 = numPopulated
            elseif d3 == 7 then pop7 = numPopulated
            elseif d3 == 8 then pop8 = numPopulated
            end
        end
        
        -- Check display position 4 (group d4)
        if c4 > 0 then
            numPopulated = numPopulated + 1
            if d4 == 1 then pop1 = numPopulated
            elseif d4 == 2 then pop2 = numPopulated
            elseif d4 == 3 then pop3 = numPopulated
            elseif d4 == 4 then pop4 = numPopulated
            elseif d4 == 5 then pop5 = numPopulated
            elseif d4 == 6 then pop6 = numPopulated
            elseif d4 == 7 then pop7 = numPopulated
            elseif d4 == 8 then pop8 = numPopulated
            end
        end
        
        -- Check display position 5 (group d5)
        if c5 > 0 then
            numPopulated = numPopulated + 1
            if d5 == 1 then pop1 = numPopulated
            elseif d5 == 2 then pop2 = numPopulated
            elseif d5 == 3 then pop3 = numPopulated
            elseif d5 == 4 then pop4 = numPopulated
            elseif d5 == 5 then pop5 = numPopulated
            elseif d5 == 6 then pop6 = numPopulated
            elseif d5 == 7 then pop7 = numPopulated
            elseif d5 == 8 then pop8 = numPopulated
            end
        end
        
        -- Check display position 6 (group d6)
        if c6 > 0 then
            numPopulated = numPopulated + 1
            if d6 == 1 then pop1 = numPopulated
            elseif d6 == 2 then pop2 = numPopulated
            elseif d6 == 3 then pop3 = numPopulated
            elseif d6 == 4 then pop4 = numPopulated
            elseif d6 == 5 then pop5 = numPopulated
            elseif d6 == 6 then pop6 = numPopulated
            elseif d6 == 7 then pop7 = numPopulated
            elseif d6 == 8 then pop8 = numPopulated
            end
        end
        
        -- Check display position 7 (group d7)
        if c7 > 0 then
            numPopulated = numPopulated + 1
            if d7 == 1 then pop1 = numPopulated
            elseif d7 == 2 then pop2 = numPopulated
            elseif d7 == 3 then pop3 = numPopulated
            elseif d7 == 4 then pop4 = numPopulated
            elseif d7 == 5 then pop5 = numPopulated
            elseif d7 == 6 then pop6 = numPopulated
            elseif d7 == 7 then pop7 = numPopulated
            elseif d7 == 8 then pop8 = numPopulated
            end
        end
        
        -- Check display position 8 (group d8)
        if c8 > 0 then
            numPopulated = numPopulated + 1
            if d8 == 1 then pop1 = numPopulated
            elseif d8 == 2 then pop2 = numPopulated
            elseif d8 == 3 then pop3 = numPopulated
            elseif d8 == 4 then pop4 = numPopulated
            elseif d8 == 5 then pop5 = numPopulated
            elseif d8 == 6 then pop6 = numPopulated
            elseif d8 == 7 then pop7 = numPopulated
            elseif d8 == 8 then pop8 = numPopulated
            end
        end
        
        -- Populated grid dimensions for CENTER alignment
        -- popRows = ceil(numPopulated / groupsPerRow)
        local popRem = numPopulated % groupsPerRow
        local popRows = 0
        if numPopulated > 0 then
            popRows = (numPopulated - popRem) / groupsPerRow
            if popRem > 0 then popRows = popRows + 1 end
        end
        local popCols = groupsPerRow
        if numPopulated > 0 and numPopulated < groupsPerRow then popCols = numPopulated end
        if numPopulated == 0 then popCols = 0 end
        
        local populatedWidth, populatedHeight
        if isHorizontal then
            populatedWidth = popCols > 0 and (popCols * groupWidth + (popCols - 1) * groupSpacing) or 0
            populatedHeight = popRows > 0 and (popRows * groupHeight + (popRows - 1) * rowColSpacing) or 0
        else
            populatedWidth = popRows > 0 and (popRows * groupWidth + (popRows - 1) * rowColSpacing) or 0
            populatedHeight = popCols > 0 and (popCols * groupHeight + (popCols - 1) * groupSpacing) or 0
        end
        
        -- Position group 1
        if group1 then
            group1:ClearAllPoints()
            local slot = pop1
            if slot > 0 then
            local slotIndex = slot - 1
            local rcIdx = (slotIndex - slotIndex % groupsPerRow) / groupsPerRow
            local posInRC = slotIndex % groupsPerRow
            local isPartialRow = popRem > 0 and rcIdx == popRows - 1
            if groupRowGrowth == "END" then
                rcIdx = (fullGridRC - 1) - rcIdx
            end

            if isHorizontal then
                local xOff = posInRC * (groupWidth + groupSpacing)
                local yOff = rcIdx * (groupHeight + rowColSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) + posInRC * (groupWidth + groupSpacing)
                    if playerGrowFrom == "END" then
                        group1:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group1:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) / 2 + posInRC * (groupWidth + groupSpacing)
                    local yStart = (totalHeight - populatedHeight) / 2
                    -- ☠ CENTER CENTRES THE POPULATED BLOCK, SO THE ROW INDEX MUST BE
                    -- RELATIVE TO THAT BLOCK, NOT TO THE FULL GRID. rcIdx was already
                    -- flipped over fullGridRC above, and adding that on top of yStart
                    -- compounds: with one populated row in a two-row grid it pushed the
                    -- groups half a group plus half the wrap spacing BELOW the container.
                    -- Recover the populated-row index from the flipped one --
                    -- (popRows-1) - ((fullGridRC-1) - rcIdx) collapses to the line below.
                    -- START needs no correction: rcIdx is already the raw index there.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: FIXED slots, no populated centring. Every term
                    -- is a constant of the settings, so nothing moves with the roster; the
                    -- full-grid flip is correct here, exactly as in the START and END arms.
                    if anchorToMain == 1 then yStart = 0 rcCentered = rcIdx end
                    yOff = yStart + rcCentered * (groupHeight + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group1:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group1:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group1:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group1:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            else
                local xOff = rcIdx * (groupWidth + rowColSpacing)
                local yOff = posInRC * (groupHeight + groupSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) + posInRC * (groupHeight + groupSpacing)
                    if playerGrowFrom == "END" then
                        group1:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group1:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) / 2 + posInRC * (groupHeight + groupSpacing)
                    local xStart = (totalWidth - populatedWidth) / 2
                    -- Same correction as the horizontal arm above: the wrap axis is X in
                    -- VERTICAL growth, so a centred block gets the same compounding.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: fixed slots, as in the horizontal arm above.
                    if anchorToMain == 1 then xStart = 0 rcCentered = rcIdx end
                    xOff = xStart + rcCentered * (groupWidth + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group1:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group1:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group1:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group1:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            end
            end -- slot > 0
        end

        -- Position group 2
        if group2 then
            group2:ClearAllPoints()
            local slot = pop2
            if slot > 0 then
            local slotIndex = slot - 1
            local rcIdx = (slotIndex - slotIndex % groupsPerRow) / groupsPerRow
            local posInRC = slotIndex % groupsPerRow
            local isPartialRow = popRem > 0 and rcIdx == popRows - 1
            if groupRowGrowth == "END" then
                rcIdx = (fullGridRC - 1) - rcIdx
            end

            if isHorizontal then
                local xOff = posInRC * (groupWidth + groupSpacing)
                local yOff = rcIdx * (groupHeight + rowColSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) + posInRC * (groupWidth + groupSpacing)
                    if playerGrowFrom == "END" then
                        group2:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group2:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) / 2 + posInRC * (groupWidth + groupSpacing)
                    local yStart = (totalHeight - populatedHeight) / 2
                    -- ☠ CENTER CENTRES THE POPULATED BLOCK, SO THE ROW INDEX MUST BE
                    -- RELATIVE TO THAT BLOCK, NOT TO THE FULL GRID. rcIdx was already
                    -- flipped over fullGridRC above, and adding that on top of yStart
                    -- compounds: with one populated row in a two-row grid it pushed the
                    -- groups half a group plus half the wrap spacing BELOW the container.
                    -- Recover the populated-row index from the flipped one --
                    -- (popRows-1) - ((fullGridRC-1) - rcIdx) collapses to the line below.
                    -- START needs no correction: rcIdx is already the raw index there.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: FIXED slots, no populated centring. Every term
                    -- is a constant of the settings, so nothing moves with the roster; the
                    -- full-grid flip is correct here, exactly as in the START and END arms.
                    if anchorToMain == 1 then yStart = 0 rcCentered = rcIdx end
                    yOff = yStart + rcCentered * (groupHeight + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group2:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group2:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group2:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group2:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            else
                local xOff = rcIdx * (groupWidth + rowColSpacing)
                local yOff = posInRC * (groupHeight + groupSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) + posInRC * (groupHeight + groupSpacing)
                    if playerGrowFrom == "END" then
                        group2:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group2:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) / 2 + posInRC * (groupHeight + groupSpacing)
                    local xStart = (totalWidth - populatedWidth) / 2
                    -- Same correction as the horizontal arm above: the wrap axis is X in
                    -- VERTICAL growth, so a centred block gets the same compounding.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: fixed slots, as in the horizontal arm above.
                    if anchorToMain == 1 then xStart = 0 rcCentered = rcIdx end
                    xOff = xStart + rcCentered * (groupWidth + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group2:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group2:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group2:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group2:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            end
            end -- slot > 0
        end

        -- Position group 3
        if group3 then
            group3:ClearAllPoints()
            local slot = pop3
            if slot > 0 then
            local slotIndex = slot - 1
            local rcIdx = (slotIndex - slotIndex % groupsPerRow) / groupsPerRow
            local posInRC = slotIndex % groupsPerRow
            local isPartialRow = popRem > 0 and rcIdx == popRows - 1
            if groupRowGrowth == "END" then
                rcIdx = (fullGridRC - 1) - rcIdx
            end

            if isHorizontal then
                local xOff = posInRC * (groupWidth + groupSpacing)
                local yOff = rcIdx * (groupHeight + rowColSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) + posInRC * (groupWidth + groupSpacing)
                    if playerGrowFrom == "END" then
                        group3:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group3:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) / 2 + posInRC * (groupWidth + groupSpacing)
                    local yStart = (totalHeight - populatedHeight) / 2
                    -- ☠ CENTER CENTRES THE POPULATED BLOCK, SO THE ROW INDEX MUST BE
                    -- RELATIVE TO THAT BLOCK, NOT TO THE FULL GRID. rcIdx was already
                    -- flipped over fullGridRC above, and adding that on top of yStart
                    -- compounds: with one populated row in a two-row grid it pushed the
                    -- groups half a group plus half the wrap spacing BELOW the container.
                    -- Recover the populated-row index from the flipped one --
                    -- (popRows-1) - ((fullGridRC-1) - rcIdx) collapses to the line below.
                    -- START needs no correction: rcIdx is already the raw index there.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: FIXED slots, no populated centring. Every term
                    -- is a constant of the settings, so nothing moves with the roster; the
                    -- full-grid flip is correct here, exactly as in the START and END arms.
                    if anchorToMain == 1 then yStart = 0 rcCentered = rcIdx end
                    yOff = yStart + rcCentered * (groupHeight + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group3:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group3:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group3:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group3:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            else
                local xOff = rcIdx * (groupWidth + rowColSpacing)
                local yOff = posInRC * (groupHeight + groupSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) + posInRC * (groupHeight + groupSpacing)
                    if playerGrowFrom == "END" then
                        group3:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group3:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) / 2 + posInRC * (groupHeight + groupSpacing)
                    local xStart = (totalWidth - populatedWidth) / 2
                    -- Same correction as the horizontal arm above: the wrap axis is X in
                    -- VERTICAL growth, so a centred block gets the same compounding.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: fixed slots, as in the horizontal arm above.
                    if anchorToMain == 1 then xStart = 0 rcCentered = rcIdx end
                    xOff = xStart + rcCentered * (groupWidth + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group3:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group3:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group3:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group3:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            end
            end -- slot > 0
        end

        -- Position group 4
        if group4 then
            group4:ClearAllPoints()
            local slot = pop4
            if slot > 0 then
            local slotIndex = slot - 1
            local rcIdx = (slotIndex - slotIndex % groupsPerRow) / groupsPerRow
            local posInRC = slotIndex % groupsPerRow
            local isPartialRow = popRem > 0 and rcIdx == popRows - 1
            if groupRowGrowth == "END" then
                rcIdx = (fullGridRC - 1) - rcIdx
            end

            if isHorizontal then
                local xOff = posInRC * (groupWidth + groupSpacing)
                local yOff = rcIdx * (groupHeight + rowColSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) + posInRC * (groupWidth + groupSpacing)
                    if playerGrowFrom == "END" then
                        group4:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group4:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) / 2 + posInRC * (groupWidth + groupSpacing)
                    local yStart = (totalHeight - populatedHeight) / 2
                    -- ☠ CENTER CENTRES THE POPULATED BLOCK, SO THE ROW INDEX MUST BE
                    -- RELATIVE TO THAT BLOCK, NOT TO THE FULL GRID. rcIdx was already
                    -- flipped over fullGridRC above, and adding that on top of yStart
                    -- compounds: with one populated row in a two-row grid it pushed the
                    -- groups half a group plus half the wrap spacing BELOW the container.
                    -- Recover the populated-row index from the flipped one --
                    -- (popRows-1) - ((fullGridRC-1) - rcIdx) collapses to the line below.
                    -- START needs no correction: rcIdx is already the raw index there.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: FIXED slots, no populated centring. Every term
                    -- is a constant of the settings, so nothing moves with the roster; the
                    -- full-grid flip is correct here, exactly as in the START and END arms.
                    if anchorToMain == 1 then yStart = 0 rcCentered = rcIdx end
                    yOff = yStart + rcCentered * (groupHeight + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group4:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group4:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group4:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group4:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            else
                local xOff = rcIdx * (groupWidth + rowColSpacing)
                local yOff = posInRC * (groupHeight + groupSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) + posInRC * (groupHeight + groupSpacing)
                    if playerGrowFrom == "END" then
                        group4:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group4:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) / 2 + posInRC * (groupHeight + groupSpacing)
                    local xStart = (totalWidth - populatedWidth) / 2
                    -- Same correction as the horizontal arm above: the wrap axis is X in
                    -- VERTICAL growth, so a centred block gets the same compounding.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: fixed slots, as in the horizontal arm above.
                    if anchorToMain == 1 then xStart = 0 rcCentered = rcIdx end
                    xOff = xStart + rcCentered * (groupWidth + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group4:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group4:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group4:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group4:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            end
            end -- slot > 0
        end

        -- Position group 5
        if group5 then
            group5:ClearAllPoints()
            local slot = pop5
            if slot > 0 then
            local slotIndex = slot - 1
            local rcIdx = (slotIndex - slotIndex % groupsPerRow) / groupsPerRow
            local posInRC = slotIndex % groupsPerRow
            local isPartialRow = popRem > 0 and rcIdx == popRows - 1
            if groupRowGrowth == "END" then
                rcIdx = (fullGridRC - 1) - rcIdx
            end

            if isHorizontal then
                local xOff = posInRC * (groupWidth + groupSpacing)
                local yOff = rcIdx * (groupHeight + rowColSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) + posInRC * (groupWidth + groupSpacing)
                    if playerGrowFrom == "END" then
                        group5:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group5:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) / 2 + posInRC * (groupWidth + groupSpacing)
                    local yStart = (totalHeight - populatedHeight) / 2
                    -- ☠ CENTER CENTRES THE POPULATED BLOCK, SO THE ROW INDEX MUST BE
                    -- RELATIVE TO THAT BLOCK, NOT TO THE FULL GRID. rcIdx was already
                    -- flipped over fullGridRC above, and adding that on top of yStart
                    -- compounds: with one populated row in a two-row grid it pushed the
                    -- groups half a group plus half the wrap spacing BELOW the container.
                    -- Recover the populated-row index from the flipped one --
                    -- (popRows-1) - ((fullGridRC-1) - rcIdx) collapses to the line below.
                    -- START needs no correction: rcIdx is already the raw index there.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: FIXED slots, no populated centring. Every term
                    -- is a constant of the settings, so nothing moves with the roster; the
                    -- full-grid flip is correct here, exactly as in the START and END arms.
                    if anchorToMain == 1 then yStart = 0 rcCentered = rcIdx end
                    yOff = yStart + rcCentered * (groupHeight + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group5:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group5:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group5:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group5:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            else
                local xOff = rcIdx * (groupWidth + rowColSpacing)
                local yOff = posInRC * (groupHeight + groupSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) + posInRC * (groupHeight + groupSpacing)
                    if playerGrowFrom == "END" then
                        group5:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group5:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) / 2 + posInRC * (groupHeight + groupSpacing)
                    local xStart = (totalWidth - populatedWidth) / 2
                    -- Same correction as the horizontal arm above: the wrap axis is X in
                    -- VERTICAL growth, so a centred block gets the same compounding.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: fixed slots, as in the horizontal arm above.
                    if anchorToMain == 1 then xStart = 0 rcCentered = rcIdx end
                    xOff = xStart + rcCentered * (groupWidth + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group5:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group5:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group5:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group5:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            end
            end -- slot > 0
        end

        -- Position group 6
        if group6 then
            group6:ClearAllPoints()
            local slot = pop6
            if slot > 0 then
            local slotIndex = slot - 1
            local rcIdx = (slotIndex - slotIndex % groupsPerRow) / groupsPerRow
            local posInRC = slotIndex % groupsPerRow
            local isPartialRow = popRem > 0 and rcIdx == popRows - 1
            if groupRowGrowth == "END" then
                rcIdx = (fullGridRC - 1) - rcIdx
            end

            if isHorizontal then
                local xOff = posInRC * (groupWidth + groupSpacing)
                local yOff = rcIdx * (groupHeight + rowColSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) + posInRC * (groupWidth + groupSpacing)
                    if playerGrowFrom == "END" then
                        group6:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group6:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) / 2 + posInRC * (groupWidth + groupSpacing)
                    local yStart = (totalHeight - populatedHeight) / 2
                    -- ☠ CENTER CENTRES THE POPULATED BLOCK, SO THE ROW INDEX MUST BE
                    -- RELATIVE TO THAT BLOCK, NOT TO THE FULL GRID. rcIdx was already
                    -- flipped over fullGridRC above, and adding that on top of yStart
                    -- compounds: with one populated row in a two-row grid it pushed the
                    -- groups half a group plus half the wrap spacing BELOW the container.
                    -- Recover the populated-row index from the flipped one --
                    -- (popRows-1) - ((fullGridRC-1) - rcIdx) collapses to the line below.
                    -- START needs no correction: rcIdx is already the raw index there.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: FIXED slots, no populated centring. Every term
                    -- is a constant of the settings, so nothing moves with the roster; the
                    -- full-grid flip is correct here, exactly as in the START and END arms.
                    if anchorToMain == 1 then yStart = 0 rcCentered = rcIdx end
                    yOff = yStart + rcCentered * (groupHeight + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group6:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group6:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group6:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group6:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            else
                local xOff = rcIdx * (groupWidth + rowColSpacing)
                local yOff = posInRC * (groupHeight + groupSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) + posInRC * (groupHeight + groupSpacing)
                    if playerGrowFrom == "END" then
                        group6:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group6:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) / 2 + posInRC * (groupHeight + groupSpacing)
                    local xStart = (totalWidth - populatedWidth) / 2
                    -- Same correction as the horizontal arm above: the wrap axis is X in
                    -- VERTICAL growth, so a centred block gets the same compounding.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: fixed slots, as in the horizontal arm above.
                    if anchorToMain == 1 then xStart = 0 rcCentered = rcIdx end
                    xOff = xStart + rcCentered * (groupWidth + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group6:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group6:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group6:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group6:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            end
            end -- slot > 0
        end

        -- Position group 7
        if group7 then
            group7:ClearAllPoints()
            local slot = pop7
            if slot > 0 then
            local slotIndex = slot - 1
            local rcIdx = (slotIndex - slotIndex % groupsPerRow) / groupsPerRow
            local posInRC = slotIndex % groupsPerRow
            local isPartialRow = popRem > 0 and rcIdx == popRows - 1
            if groupRowGrowth == "END" then
                rcIdx = (fullGridRC - 1) - rcIdx
            end

            if isHorizontal then
                local xOff = posInRC * (groupWidth + groupSpacing)
                local yOff = rcIdx * (groupHeight + rowColSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) + posInRC * (groupWidth + groupSpacing)
                    if playerGrowFrom == "END" then
                        group7:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group7:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) / 2 + posInRC * (groupWidth + groupSpacing)
                    local yStart = (totalHeight - populatedHeight) / 2
                    -- ☠ CENTER CENTRES THE POPULATED BLOCK, SO THE ROW INDEX MUST BE
                    -- RELATIVE TO THAT BLOCK, NOT TO THE FULL GRID. rcIdx was already
                    -- flipped over fullGridRC above, and adding that on top of yStart
                    -- compounds: with one populated row in a two-row grid it pushed the
                    -- groups half a group plus half the wrap spacing BELOW the container.
                    -- Recover the populated-row index from the flipped one --
                    -- (popRows-1) - ((fullGridRC-1) - rcIdx) collapses to the line below.
                    -- START needs no correction: rcIdx is already the raw index there.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: FIXED slots, no populated centring. Every term
                    -- is a constant of the settings, so nothing moves with the roster; the
                    -- full-grid flip is correct here, exactly as in the START and END arms.
                    if anchorToMain == 1 then yStart = 0 rcCentered = rcIdx end
                    yOff = yStart + rcCentered * (groupHeight + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group7:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group7:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group7:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group7:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            else
                local xOff = rcIdx * (groupWidth + rowColSpacing)
                local yOff = posInRC * (groupHeight + groupSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) + posInRC * (groupHeight + groupSpacing)
                    if playerGrowFrom == "END" then
                        group7:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group7:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) / 2 + posInRC * (groupHeight + groupSpacing)
                    local xStart = (totalWidth - populatedWidth) / 2
                    -- Same correction as the horizontal arm above: the wrap axis is X in
                    -- VERTICAL growth, so a centred block gets the same compounding.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: fixed slots, as in the horizontal arm above.
                    if anchorToMain == 1 then xStart = 0 rcCentered = rcIdx end
                    xOff = xStart + rcCentered * (groupWidth + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group7:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group7:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group7:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group7:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            end
            end -- slot > 0
        end

        -- Position group 8
        if group8 then
            group8:ClearAllPoints()
            local slot = pop8
            if slot > 0 then
            local slotIndex = slot - 1
            local rcIdx = (slotIndex - slotIndex % groupsPerRow) / groupsPerRow
            local posInRC = slotIndex % groupsPerRow
            local isPartialRow = popRem > 0 and rcIdx == popRows - 1
            if groupRowGrowth == "END" then
                rcIdx = (fullGridRC - 1) - rcIdx
            end

            if isHorizontal then
                local xOff = posInRC * (groupWidth + groupSpacing)
                local yOff = rcIdx * (groupHeight + rowColSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) + posInRC * (groupWidth + groupSpacing)
                    if playerGrowFrom == "END" then
                        group8:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group8:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcW = gInRC * groupWidth + (gInRC - 1) * groupSpacing
                    xOff = (totalWidth - rcW) / 2 + posInRC * (groupWidth + groupSpacing)
                    local yStart = (totalHeight - populatedHeight) / 2
                    -- ☠ CENTER CENTRES THE POPULATED BLOCK, SO THE ROW INDEX MUST BE
                    -- RELATIVE TO THAT BLOCK, NOT TO THE FULL GRID. rcIdx was already
                    -- flipped over fullGridRC above, and adding that on top of yStart
                    -- compounds: with one populated row in a two-row grid it pushed the
                    -- groups half a group plus half the wrap spacing BELOW the container.
                    -- Recover the populated-row index from the flipped one --
                    -- (popRows-1) - ((fullGridRC-1) - rcIdx) collapses to the line below.
                    -- START needs no correction: rcIdx is already the raw index there.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: FIXED slots, no populated centring. Every term
                    -- is a constant of the settings, so nothing moves with the roster; the
                    -- full-grid flip is correct here, exactly as in the START and END arms.
                    if anchorToMain == 1 then yStart = 0 rcCentered = rcIdx end
                    yOff = yStart + rcCentered * (groupHeight + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group8:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group8:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group8:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff, yOff)
                    else
                        group8:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            else
                local xOff = rcIdx * (groupWidth + rowColSpacing)
                local yOff = posInRC * (groupHeight + groupSpacing)
                if slot > 0 and groupsGrowFrom == "END" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) + posInRC * (groupHeight + groupSpacing)
                    if playerGrowFrom == "END" then
                        group8:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group8:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                elseif slot > 0 and groupsGrowFrom == "CENTER" then
                    local gInRC = groupsPerRow
                    if isPartialRow then gInRC = popRem end
                    local rcH = gInRC * groupHeight + (gInRC - 1) * groupSpacing
                    yOff = (totalHeight - rcH) / 2 + posInRC * (groupHeight + groupSpacing)
                    local xStart = (totalWidth - populatedWidth) / 2
                    -- Same correction as the horizontal arm above: the wrap axis is X in
                    -- VERTICAL growth, so a centred block gets the same compounding.
                    local rcCentered = rcIdx
                    if groupRowGrowth == "END" then rcCentered = rcIdx + popRows - fullGridRC end
                    -- Anchor To Main Group: fixed slots, as in the horizontal arm above.
                    if anchorToMain == 1 then xStart = 0 rcCentered = rcIdx end
                    xOff = xStart + rcCentered * (groupWidth + rowColSpacing)
                    if playerGrowFrom == "END" then
                        group8:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group8:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                else
                    if playerGrowFrom == "END" then
                        group8:SetPoint("TOPRIGHT", container, "TOPRIGHT", -xOff, -yOff)
                    else
                        group8:SetPoint("TOPLEFT", container, "TOPLEFT", xOff, -yOff)
                    end
                end
            end
            end -- slot > 0
        end

        -- Debug info
        handler:SetAttribute("debugpopulated", numPopulated)
        handler:SetAttribute("debugdirection", growDirection)
        handler:SetAttribute("debugplayergrow", playerGrowFrom)
        handler:SetAttribute("debuggroupsgrow", groupsGrowFrom)
        handler:SetAttribute("debuggroupsperrow", groupsPerRow)
        handler:SetAttribute("debugpoprows", popRows)
    ]]
    
    -- Set up OnAttributeChanged
    SecureHandlerWrapScript(handler, "OnAttributeChanged", handler, [[
        if name == "triggerposition" then
            ]] .. positionSnippet .. [[
        end
    ]])
    
    -- Hook each group header to count its own children and report to position handler
    for i = 1, 8 do
        local groupHeader = DF.raidSeparatedHeaders[i]
        if groupHeader then
            SecureHandlerSetFrameRef(groupHeader, "positionHandler", handler)
            groupHeader:SetAttribute("groupIndex", i)
            
            -- When child attributes change, count OUR OWN children and report to position handler
            -- NOTE: SecureGroupHeaderTemplate stores children as "frameref-childN"
            SecureHandlerWrapScript(groupHeader, "OnAttributeChanged", groupHeader, [[
                if name and name:match("^child%d+$") then
                    local posHandler = self:GetFrameRef("positionHandler")
                    local groupIndex = self:GetAttribute("groupIndex")
                    if not posHandler or not groupIndex then return end

                    -- Count our own children using frameref-child prefix
                    local count = 0
                    local c1 = self:GetAttribute("frameref-child1")
                    local c2 = self:GetAttribute("frameref-child2")
                    local c3 = self:GetAttribute("frameref-child3")
                    local c4 = self:GetAttribute("frameref-child4")
                    local c5 = self:GetAttribute("frameref-child5")
                    if c1 and c1:IsShown() then count = count + 1 end
                    if c2 and c2:IsShown() then count = count + 1 end
                    if c3 and c3:IsShown() then count = count + 1 end
                    if c4 and c4:IsShown() then count = count + 1 end
                    if c5 and c5:IsShown() then count = count + 1 end

                    -- Report our count (always update, even when suppressed)
                    if groupIndex == 1 then posHandler:SetAttribute("group1count", count)
                    elseif groupIndex == 2 then posHandler:SetAttribute("group2count", count)
                    elseif groupIndex == 3 then posHandler:SetAttribute("group3count", count)
                    elseif groupIndex == 4 then posHandler:SetAttribute("group4count", count)
                    elseif groupIndex == 5 then posHandler:SetAttribute("group5count", count)
                    elseif groupIndex == 6 then posHandler:SetAttribute("group6count", count)
                    elseif groupIndex == 7 then posHandler:SetAttribute("group7count", count)
                    elseif groupIndex == 8 then posHandler:SetAttribute("group8count", count)
                    end

                    -- Trigger reposition (skip if batching — caller will trigger once at end)
                    local suppress = posHandler:GetAttribute("suppressreposition")
                    if not suppress or suppress ~= 1 then
                        local v = posHandler:GetAttribute("triggerposition") or 0
                        posHandler:SetAttribute("triggerposition", v + 1)
                    end
                end
            ]])
            
            -- Do an initial count right now (children might already exist)
            local count = 0
            for j = 1, 5 do
                local child = groupHeader:GetAttribute("child" .. j)
                if child and child:IsShown() then
                    count = count + 1
                end
            end
            handler:SetAttribute("group" .. i .. "count", count)
            
            DF:Debug("HEADERS", "Group %s initial count: %s", i, count)
        end
    end
    
    -- Trigger initial positioning synchronously for combat reload support
    -- Children already exist due to startingIndex trick in CreateRaidSeparatedHeaders
    -- CRITICAL: Must NOT defer with C_Timer.After - that runs after ADDON_LOADED's
    -- combat-safe window closes, causing TriggerRaidPosition to fail in combat
    
    -- Initialize player group tracking and custom display order
    -- Must happen BEFORE TriggerRaidPosition so order is correct on combat reload
    if db.raidPlayerGroupFirst then
        DF.cachedPlayerGroup = DF:GetPlayerRaidGroup()
    end
    -- Always update display order attributes (handles both custom order and player-group-first)
    DF:UpdateRaidGroupOrderAttributes()
    
    DF:TriggerRaidPosition()
    DF:HookRaidChildrenForRepositioning()
    
    headerDebug("Created secure raid position handler")
end

-- Hook raid group header children to trigger repositioning on show/hide
function DF:HookRaidChildrenForRepositioning()
    if InCombatLockdown() then return end
    if not DF.raidSeparatedHeaders then return end
    if not DF.raidPositionHandler then return end
    
    DF.hookedRaidChildren = DF.hookedRaidChildren or {}
    
    for groupIndex = 1, 8 do
        local groupHeader = DF.raidSeparatedHeaders[groupIndex]
        if groupHeader then
            for j = 1, 5 do
                local child = groupHeader:GetAttribute("child" .. j)
                if child and not DF.hookedRaidChildren[child] then
                    DF.hookedRaidChildren[child] = true
                    
                    -- Store ref to position handler AND parent group header
                    SecureHandlerSetFrameRef(child, "positionHandler", DF.raidPositionHandler)
                    SecureHandlerSetFrameRef(child, "parentGroup", groupHeader)
                    child:SetAttribute("parentGroupIndex", groupIndex)
                    
                    -- OnShow - count parent's children and trigger
                    SecureHandlerWrapScript(child, "OnShow", child, [[
                        local posHandler = self:GetFrameRef("positionHandler")
                        local parentGroup = self:GetFrameRef("parentGroup")
                        local groupIndex = self:GetAttribute("parentGroupIndex")
                        if not posHandler or not parentGroup or not groupIndex then return end

                        -- Count parent's children using frameref-child prefix
                        local count = 0
                        local c1 = parentGroup:GetAttribute("frameref-child1")
                        local c2 = parentGroup:GetAttribute("frameref-child2")
                        local c3 = parentGroup:GetAttribute("frameref-child3")
                        local c4 = parentGroup:GetAttribute("frameref-child4")
                        local c5 = parentGroup:GetAttribute("frameref-child5")
                        if c1 and c1:IsShown() then count = count + 1 end
                        if c2 and c2:IsShown() then count = count + 1 end
                        if c3 and c3:IsShown() then count = count + 1 end
                        if c4 and c4:IsShown() then count = count + 1 end
                        if c5 and c5:IsShown() then count = count + 1 end

                        -- Set count based on index (always update, even when suppressed)
                        if groupIndex == 1 then posHandler:SetAttribute("group1count", count)
                        elseif groupIndex == 2 then posHandler:SetAttribute("group2count", count)
                        elseif groupIndex == 3 then posHandler:SetAttribute("group3count", count)
                        elseif groupIndex == 4 then posHandler:SetAttribute("group4count", count)
                        elseif groupIndex == 5 then posHandler:SetAttribute("group5count", count)
                        elseif groupIndex == 6 then posHandler:SetAttribute("group6count", count)
                        elseif groupIndex == 7 then posHandler:SetAttribute("group7count", count)
                        elseif groupIndex == 8 then posHandler:SetAttribute("group8count", count)
                        end

                        -- Trigger reposition (skip if batching — caller will trigger once at end)
                        local suppress = posHandler:GetAttribute("suppressreposition")
                        if not suppress or suppress ~= 1 then
                            local v = posHandler:GetAttribute("triggerposition") or 0
                            posHandler:SetAttribute("triggerposition", v + 1)
                        end
                    ]])
                    
                    -- OnHide - count parent's children (excluding self) and trigger
                    SecureHandlerWrapScript(child, "OnHide", child, [[
                        local posHandler = self:GetFrameRef("positionHandler")
                        local parentGroup = self:GetFrameRef("parentGroup")
                        local groupIndex = self:GetAttribute("parentGroupIndex")
                        if not posHandler or not parentGroup or not groupIndex then return end

                        -- Count parent's children, excluding self since we're hiding
                        local count = 0
                        local c1 = parentGroup:GetAttribute("frameref-child1")
                        local c2 = parentGroup:GetAttribute("frameref-child2")
                        local c3 = parentGroup:GetAttribute("frameref-child3")
                        local c4 = parentGroup:GetAttribute("frameref-child4")
                        local c5 = parentGroup:GetAttribute("frameref-child5")
                        if c1 and c1:IsShown() and c1 ~= self then count = count + 1 end
                        if c2 and c2:IsShown() and c2 ~= self then count = count + 1 end
                        if c3 and c3:IsShown() and c3 ~= self then count = count + 1 end
                        if c4 and c4:IsShown() and c4 ~= self then count = count + 1 end
                        if c5 and c5:IsShown() and c5 ~= self then count = count + 1 end

                        -- Set count based on index (always update, even when suppressed)
                        if groupIndex == 1 then posHandler:SetAttribute("group1count", count)
                        elseif groupIndex == 2 then posHandler:SetAttribute("group2count", count)
                        elseif groupIndex == 3 then posHandler:SetAttribute("group3count", count)
                        elseif groupIndex == 4 then posHandler:SetAttribute("group4count", count)
                        elseif groupIndex == 5 then posHandler:SetAttribute("group5count", count)
                        elseif groupIndex == 6 then posHandler:SetAttribute("group6count", count)
                        elseif groupIndex == 7 then posHandler:SetAttribute("group7count", count)
                        elseif groupIndex == 8 then posHandler:SetAttribute("group8count", count)
                        end

                        -- Trigger reposition (skip if batching — caller will trigger once at end)
                        local suppress = posHandler:GetAttribute("suppressreposition")
                        if not suppress or suppress ~= 1 then
                            local v = posHandler:GetAttribute("triggerposition") or 0
                            posHandler:SetAttribute("triggerposition", v + 1)
                        end
                    ]])
                    
                    DF:Debug("HEADERS", "Hooked child %s of group %s", j, groupIndex)
                end
            end
        end
    end
end

-- Update raid header layout attributes based on growDirection
-- Call this when growDirection changes
-- Cache last-applied layout state so we only ClearAllPoints when something actually changed.
-- ClearAllPoints momentarily unanchors every child frame; if it runs on every GRU the
-- frames visually "jump" as SecureGroupHeaderTemplate re-anchors them.
local lastLayoutHorizontal = nil
local lastLayoutSpacing = nil

function DF:UpdateRaidHeaderLayoutAttributes()
    if InCombatLockdown() then return end
    if not DF.raidSeparatedHeaders then return end

    local db = DF:GetRaidDB()
    local horizontal = (db.growDirection == "HORIZONTAL")  -- Groups as columns
    -- ☠ SNAPPED before the cache compare, not after: the cache must key on the value
    -- actually pushed, or toggling pixelPerfect at an unchanged frameSpacing would be
    -- read as "nothing changed" and skip the update entirely.
    local spacing = db.frameSpacing or 2
    if db.pixelPerfect and DF.PixelPerfect then spacing = DF:PixelPerfect(spacing) end

    -- Skip entirely if nothing changed — avoids the destructive ClearAllPoints
    if horizontal == lastLayoutHorizontal and spacing == lastLayoutSpacing then
        DF:Debug("ROSTER", "UpdateRaidHeaderLayoutAttributes: no change, skipping")
        return
    end

    DF:Debug("ROSTER", "UpdateRaidHeaderLayoutAttributes: layout changed (horizontal=%s->%s, spacing=%s->%s)",
        tostring(lastLayoutHorizontal), tostring(horizontal),
        tostring(lastLayoutSpacing), tostring(spacing))
    lastLayoutHorizontal = horizontal
    lastLayoutSpacing = spacing

    for group = 1, 8 do
        local header = DF.raidSeparatedHeaders[group]
        if header then
            -- CRITICAL: Clear child points before changing layout
            -- This prevents the "staircase" effect when switching orientations
            for i = 1, 5 do
                local child = header:GetAttribute("child" .. i)
                if child then
                    child:ClearAllPoints()
                end
            end

            -- Note: point=TOP/LEFT keeps player order consistent (first at top/left)
            -- The secure snippet handles where the GROUP is positioned (START/END)
            if horizontal then
                -- HORIZONTAL: Groups as columns, players stacked vertically
                header:SetAttribute("point", "TOP")
                header:SetAttribute("columnAnchorPoint", "LEFT")
                header:SetAttribute("xOffset", 0)
                header:SetAttribute("yOffset", -spacing)
            else
                -- VERTICAL: Groups as rows, players arranged horizontally
                header:SetAttribute("point", "LEFT")
                header:SetAttribute("columnAnchorPoint", "TOP")
                header:SetAttribute("xOffset", spacing)
                header:SetAttribute("yOffset", 0)
            end
        end
    end

    DF:Debug("HEADERS", "Updated header layout attributes: horizontal=%s", tostring(horizontal))
end

-- Update raid position attributes - SECURE ONLY (no Lua fallback for debugging)
function DF:UpdateRaidPositionAttributes()
    if not DF.raidPositionHandler then
        -- Handler is only created when raid frames are enabled (see CreateRaidHeaders
        -- gated on db.raidEnabled). If raid is disabled, this is a no-op, not an error.
        DF:Debug("HEADERS", "UpdateRaidPositionAttributes: no raid position handler (raid frames disabled?)")
        return
    end
    
    local db = DF:GetRaidDB()
    local handler = DF.raidPositionHandler
    
    -- Update header child layout attributes (point, xOffset, yOffset)
    DF:UpdateRaidHeaderLayoutAttributes()
    
    -- ☠ SNAP THE SAME FIVE VALUES SecureSort SNAPS, or the two disagree.
    --
    -- Grouped raid geometry has TWO independent producers feeding ONE layout:
    --   * this function          -> handler ATTRIBUTES  -> positions the GROUP HEADERS
    --   * UpdateRaidGroupLayoutParams -> raidGroupLayoutConfig -> positions the FRAMES
    --     inside each group (and sizes the container, via Init.lua)
    -- SecureSort ran every value through DF:PixelPerfect; this side pushed the raw db
    -- numbers. So with pixelPerfect on, groups were spaced on unsnapped values while
    -- their contents were laid out on snapped ones, and the error accumulated across
    -- the row -- the ~4.5px-per-group drift in the audit.
    --
    -- ⚠ pixelPerfect DEFAULTS TO TRUE (Core/Config.lua), so this was not an
    -- opt-in-only fault: it was the shipped behaviour for every grouped raid layout.
    -- The snap is sub-pixel per value, which is exactly why it survived so long --
    -- visible as creeping misalignment across eight groups, not as an obvious jump.
    --
    -- These five mirror UpdateRaidGroupLayoutParams one-for-one (frameWidth,
    -- frameHeight, playerSpacing=spacing, groupSpacing, rowColSpacing). Add a value
    -- there, add it here.
    local function snap(value)
        if db.pixelPerfect and DF.PixelPerfect then
            return DF:PixelPerfect(value)
        end
        return value
    end

    -- Update attributes (can only change these out of combat)
    if not InCombatLockdown() then
        handler:SetAttribute("framewidth", snap(db.frameWidth or 80))
        handler:SetAttribute("frameheight", snap(db.frameHeight or 40))
        handler:SetAttribute("spacing", snap(db.frameSpacing or 2))
        handler:SetAttribute("groupspacing", snap(db.raidGroupSpacing or 10))
        handler:SetAttribute("playergrowfrom", db.raidPlayerAnchor or "START")
        handler:SetAttribute("groupsgrowfrom", db.raidGroupAnchor or "START")
        handler:SetAttribute("growdirection", db.growDirection or "HORIZONTAL")
        handler:SetAttribute("groupsperrow", db.raidGroupsPerRow or 8)
        handler:SetAttribute("rowcolspacing", snap(db.raidRowColSpacing or 30))
        handler:SetAttribute("grouprowgrowth", db.raidGroupRowGrowth or "START")
        handler:SetAttribute("anchortomain", ((db.raidGroupCenterMode or "ALL") == "MAIN") and 1 or 0)

        -- Update custom group display order
        DF:UpdateRaidGroupOrderAttributes()
    end
    
    -- Trigger repositioning
    DF:TriggerRaidPosition()
    
    headerDebug("UpdateRaidPositionAttributes triggered secure positioning")
end

-- Trigger secure repositioning
function DF:TriggerRaidPosition()
    -- Can't SetAttribute on secure frames during combat
    if InCombatLockdown() then
        DF:Debug("POSITION", "TriggerRaidPosition: deferred (combat)")
        DF.pendingRaidPositionTrigger = true
        return
    end

    -- Skip grouped-mode repositioning when flat raid mode is active.
    -- The grouped secure snippet resizes the shared raidContainer for the 8-group grid,
    -- which stomps on FlatRaidFrames' own container sizing and causes visual jumping.
    local raidDb = DF:GetRaidDB()
    if raidDb and not raidDb.raidUseGroups then
        DF:Debug("POSITION", "TriggerRaidPosition: skipped (flat mode active)")
        return
    end

    if DF.raidPositionHandler then
        local v = DF.raidPositionHandler:GetAttribute("triggerposition") or 0
        DF:Debug("POSITION", "TriggerRaidPosition: firing (counter=%d)", v + 1)
        DF.raidPositionHandler:SetAttribute("triggerposition", v + 1)
        
        if DF:DebugActive("HEADERS") then
            -- Read back debug info after a tiny delay
            C_Timer.After(0.01, function()
                local numPop = DF.raidPositionHandler:GetAttribute("debugpopulated") or "nil"
                local dir = DF.raidPositionHandler:GetAttribute("debugdirection") or "nil"
                local playerGrow = DF.raidPositionHandler:GetAttribute("debugplayergrow") or "nil"
                local groupsGrow = DF.raidPositionHandler:GetAttribute("debuggroupsgrow") or "nil"
                local gpr = DF.raidPositionHandler:GetAttribute("debuggroupsperrow") or "nil"
                local prows = DF.raidPositionHandler:GetAttribute("debugpoprows") or "nil"
                DF:Debug("HEADERS", "Secure: pop=%s dir=%s playerGrow=%s groupsGrow=%s gpr=%s popRows=%s", tostring(numPop), tostring(dir), tostring(playerGrow), tostring(groupsGrow), tostring(gpr), tostring(prows))
            end)
        end
    end
end

-- Track player's current raid group (for "Player's Group First" feature)
DF.cachedPlayerGroup = nil

function DF:UpdatePlayerGroupTracking()
    if InCombatLockdown() then
        DF.pendingPlayerGroupUpdate = true
        return
    end
    
    local oldGroup = DF.cachedPlayerGroup
    DF.cachedPlayerGroup = DF:GetPlayerRaidGroup()
    
    DF:Debug("HEADERS", "Player group tracking: %s -> %s", tostring(oldGroup), tostring(DF.cachedPlayerGroup))
    
    -- If group changed and we have the handler, update attributes
    if oldGroup ~= DF.cachedPlayerGroup and DF.raidPositionHandler then
        DF:UpdateRaidGroupOrderAttributes()
    end
end

-- Update group display order attributes on the secure handler
-- ☠ THE ORDER BUILDER LIVES IN Frames/Init.lua AS DF:GetEffectiveRaidGroupOrder, and
-- this function used to carry a second copy of it. Do not reintroduce one here: a
-- duplicate definition on DF silently wins or loses by file load order, and the two
-- copies had already drifted on validation strictness. Init.lua's is now the single
-- producer, shared with SecureSort:PushRaidGroupLayoutConfig (which ships it to the
-- secure grouped positioner) and DF:SortActiveGroupListByDisplayOrder.
function DF:UpdateRaidGroupOrderAttributes()
    if InCombatLockdown() then
        DF.pendingGroupOrderUpdate = true
        return
    end
    
    if not DF.raidPositionHandler then return end
    
    local handler = DF.raidPositionHandler
    local effectiveOrder = DF:GetEffectiveRaidGroupOrder()

    -- Set attributes for each display position (1-8)
    -- displayorder1 = which group number should be in position 1, etc.
    for displayPos = 1, 8 do
        local groupNum = effectiveOrder[displayPos]
        if not groupNum then
            DF:DebugWarn("ROSTER", "UpdateRaidGroupOrderAttributes: effectiveOrder[%d] is nil, falling back", displayPos)
            groupNum = displayPos
        end
        handler:SetAttribute("displayorder" .. displayPos, groupNum)
    end
    
    -- Also set the reverse lookup: for each group, what display position is it in?
    -- groupdisplaypos1 = what position is group 1 in, etc.
    for displayPos, groupNum in ipairs(effectiveOrder) do
        handler:SetAttribute("groupdisplaypos" .. groupNum, displayPos)
    end
    
    if DF:DebugActive("HEADERS") then
        local orderStr = table.concat(effectiveOrder, ",")
        DF:Debug("ROSTER", "UpdateRaidGroupOrderAttributes: group display order: %s", orderStr)
    end
end


-- ============================================================
-- RAID ROSTER CACHE
-- Caches GetRaidRosterInfo results to avoid calling it 320+ times per roster update
-- (8 groups x 40 members = 320 calls without caching)
-- ============================================================
local raidRosterCache = {}
local raidRosterCacheValid = false

local function CacheRaidRosterInfo()
    wipe(raidRosterCache)
    local numMembers = GetNumGroupMembers()
    local playerName = UnitName("player")
    
    for i = 1, numMembers do
        local name, rank, subgroup, level, classLoc, class, zone, online, isDead, role, isML, combatRole = GetRaidRosterInfo(i)
        if name then
            raidRosterCache[i] = {
                name = name,
                rank = rank,
                subgroup = subgroup,
                level = level,
                classLoc = classLoc,
                class = class,
                zone = zone,
                online = online,
                isDead = isDead,
                role = role,
                isML = isML,
                combatRole = combatRole,
                isPlayer = (name == playerName),
                raidIndex = i
            }
        end
    end
    raidRosterCacheValid = true
end

local function ClearRaidRosterCache()
    wipe(raidRosterCache)
    raidRosterCacheValid = false
end

-- Apply sorting within each raid group, handling player position in their group
function DF:ApplyRaidGroupSorting()
    if InCombatLockdown() then return end
    if not DF.raidSeparatedHeaders then return end

    -- Flat mode has its own sorting via FlatRaidFrames:UpdateSorting()
    local db = DF:GetRaidDB()
    if not db.raidUseGroups then return end

    DF:Debug("RAIDPOS", "ApplyRaidGroupSorting ENTRY: members=%d anchor=(%.1f,%.1f)",
        GetNumGroupMembers(), db.raidAnchorX or 0, db.raidAnchorY or 0)

    -- FrameSort integration: yield sorting to FrameSort when active
    if DF:IsFrameSortActive() then return end

    -- Suppress repositioning FIRST, before any attribute changes that could
    -- trigger SecureGroupHeader child re-anchoring → OnShow → position snippet.
    -- Without this, UpdateRaidHeaderLayoutAttributes (called by UpdateRaidPositionAttributes
    -- below) fires unsuppressed repositions via ClearAllPoints/SetAttribute on headers.
    DF:Debug("ROSTER", "ApplyRaidGroupSorting: suppressing reposition, configuring 8 groups")
    if DF.raidPositionHandler then
        DF.raidPositionHandler:SetAttribute("suppressreposition", 1)
    end

    -- Cache raid roster info once (avoids 320+ GetRaidRosterInfo calls)
    CacheRaidRosterInfo()
    
    local selfPosition = db.sortSelfPosition or "FIRST"
    local sortEnabled = db.sortEnabled
    local separateMeleeRanged = db.sortSeparateMeleeRanged
    local sortByClass = db.sortByClass
    local sortAlphabetical = db.sortAlphabetical
    
    -- Get player's current group
    local playerGroup = DF:GetPlayerRaidGroup()
    
    -- Detect if player changed groups
    local previousGroup = DF.lastPlayerRaidGroup
    local groupChanged = previousGroup and playerGroup and previousGroup ~= playerGroup
    DF.lastPlayerRaidGroup = playerGroup
    
    if groupChanged and DF:DebugActive("HEADERS") then
        headerDebug("Player changed groups:", previousGroup, "->", playerGroup)
    end
    
    -- Determine if we need nameList for advanced sorting
    -- Use nameList for ALL groups when:
    -- - Player position is FIRST/LAST (player's group only)
    -- - OR any advanced option is enabled (all groups need it)
    local needsAdvancedSorting = separateMeleeRanged or sortByClass or sortAlphabetical
    local playerNeedsNameList = (selfPosition ~= "SORTED")
    -- #78: hidden pinned members can only be dropped via the nameList path, so force
    -- it on every group when a "Hide from Main Frames" set is active (see
    -- ApplyPartyGroupSorting). With sorting otherwise off, BuildSortedNameList emits
    -- the kept members in index order (not role order), so hiding never silently
    -- turns sorting on.
    local hasHidden = DF.GetPinnedHiddenNames and DF:GetPinnedHiddenNames() ~= nil

    if DF:DebugActive("HEADERS") then
        headerDebug("ApplyRaidGroupSorting:")
        headerDebug("  playerGroup=", playerGroup, "selfPosition=", selfPosition)
        DF:Debug("HEADERS", "  sortEnabled= %s separateMeleeRanged= %s sortByClass= %s", tostring(sortEnabled), tostring(separateMeleeRanged), tostring(sortByClass))
        DF:Debug("HEADERS", "  needsAdvancedSorting= %s playerNeedsNameList= %s", tostring(needsAdvancedSorting), tostring(playerNeedsNameList))
    end
    
    -- Legacy: Hide raidPlayerHeader if it exists (no longer created, but may exist from old sessions)
    if DF.raidPlayerHeader then
        DF.raidPlayerHeader:Hide()
    end
    
    -- Get role order for native sorting (when not using nameList)
    local roleOrder = db.sortRoleOrder or {"TANK", "HEALER", "MELEE", "RANGED"}
    local groupingOrder = {}
    for _, role in ipairs(roleOrder) do
        if role == "MELEE" or role == "RANGED" then
            if not tContains(groupingOrder, "DAMAGER") then
                table.insert(groupingOrder, "DAMAGER")
            end
        else
            table.insert(groupingOrder, role)
        end
    end
    local roleOrderString = table.concat(groupingOrder, ",")
    
    -- Track last-applied sorting key per group so we only Hide/Show when something changed.
    -- Hide/Show forces SecureGroupHeaderTemplate to ClearAllPoints+SetPoint every child,
    -- which causes visible frame jumping even though positions ultimately resolve correctly.
    DF._lastGroupSortKey = DF._lastGroupSortKey or {}

    -- Snapshot per-group sort keys + a layout signature BEFORE configuring the
    -- groups, so we can detect afterwards whether anything that affects the
    -- grouped layout actually changed and skip a redundant (jittery) reposition.
    local prevSortKeys = {}
    for gi = 1, 8 do prevSortKeys[gi] = DF._lastGroupSortKey[gi] end
    local layoutSig = table.concat({
        db.frameWidth or 80, db.frameHeight or 40, db.frameSpacing or 2,
        db.raidRowColSpacing or 30, db.raidGroupsPerRow or 8,
        db.growDirection or "HORIZONTAL", db.raidGroupAnchor or "START",
        db.raidAnchorX or 0, db.raidAnchorY or 0, db.frameScale or 1,
    }, ":")

    -- Configure each group header (SORTING ONLY - positioning handled by secure handler)
    for i = 1, 8 do
        local header = DF.raidSeparatedHeaders[i]
        if header then
            -- Check visibility setting for this group
            local showGroup = db.raidGroupVisible and db.raidGroupVisible[i]
            if showGroup == nil then showGroup = true end

            if not showGroup then
                -- DEFENSE IN DEPTH: Don't just hide — strip all attributes so the
                -- header can never claim or display units even if something shows it.
                -- An empty nameList with NAMELIST sort means zero children matched.
                header:SetAttribute("showRaid", false)
                header:SetAttribute("showParty", false)
                header:SetAttribute("showPlayer", false)
                header:SetAttribute("nameList", "")
                header:SetAttribute("sortMethod", "NAMELIST")
                header:SetAttribute("groupFilter", nil)
                header:SetAttribute("groupBy", nil)
                header:SetAttribute("groupingOrder", nil)
                header:SetAttribute("roleFilter", nil)
                header:SetAttribute("strictFiltering", nil)

                if header:IsShown() then header:Hide() end
                if DF.raidPositionHandler then
                    DF.raidPositionHandler:SetAttribute("group" .. i .. "count", 0)
                end
                DF:SetHeaderChildrenEventsEnabled(header, false)

                -- Track sortKey so re-enabling triggers a full Hide/Show cycle
                DF._lastGroupSortKey[i] = "HIDDEN"

                DF:Debug("ROSTER", "  Group %d: hidden (user setting, attrs cleared)", i)
            else
                -- Visible group: set up sorting attributes normally
                header:SetAttribute("showPlayer", true)
                header:SetAttribute("showRaid", true)
                header:SetAttribute("showParty", false)

                -- NOTE: Positioning attributes (point, yOffset, sortDir, ClearAllPoints/SetPoint)
                -- are now handled by the secure position handler via UpdateRaidPositionAttributes

                -- Build the sorting key BEFORE applying attributes.
                -- This lets us detect whether anything actually changed and skip the
                -- destructive Hide/Show cycle when the sorting is identical.
                local sortKey

                -- CHECK sortEnabled FIRST (like party sorting does)
                -- This ensures ALL headers get sorting disabled, not just those that don't need nameList
                if not sortEnabled and not hasHidden then
                    sortKey = "INDEX:" .. i

                    -- Sorting disabled - clear ALL sorting attributes with nil
                    -- CRITICAL: Must use nil, not empty string, for SecureGroupHeaderTemplate
                    header:SetAttribute("nameList", nil)
                    header:SetAttribute("groupBy", nil)
                    header:SetAttribute("groupingOrder", nil)
                    header:SetAttribute("roleFilter", nil)
                    header:SetAttribute("strictFiltering", nil)
                    header:SetAttribute("groupFilter", tostring(i))  -- Keep groupFilter to show correct group
                    header:SetAttribute("sortMethod", "INDEX")

                    headerDebug("  Group", i, ": sorting DISABLED, using INDEX")
                else
                    -- Sorting enabled - determine if this group uses nameList
                    -- Use nameList when:
                    -- 1. Advanced sorting enabled (all groups)
                    -- 2. OR player's group with FIRST/LAST position
                    local isPlayerGroup = (i == playerGroup)
                    local useNameList = needsAdvancedSorting or (isPlayerGroup and playerNeedsNameList) or hasHidden

                    if useNameList then
                        -- Use nameList for custom sorting
                        -- For player's group: use selfPosition
                        -- For other groups: use "SORTED" (player position doesn't matter)
                        local groupSelfPosition = isPlayerGroup and selfPosition or "SORTED"
                        local nameList = DF:BuildRaidGroupNameList(i, groupSelfPosition)
                        sortKey = "NL:" .. (nameList or "")

                        -- Clear native sorting attributes - use direct SetAttribute to bypass cache
                        -- This ensures attributes are always set fresh when switching modes
                        header:SetAttribute("groupBy", nil)
                        header:SetAttribute("groupingOrder", nil)
                        header:SetAttribute("groupFilter", nil)  -- nameList acts as the filter
                        header:SetAttribute("roleFilter", nil)
                        header:SetAttribute("strictFiltering", nil)

                        -- Set nameList and sortMethod directly (bypass cache)
                        header:SetAttribute("nameList", nameList)
                        header:SetAttribute("sortMethod", "NAMELIST")

                        if DF:DebugActive("HEADERS") then
                            local tag = isPlayerGroup and "(player)" or ""
                            headerDebug("  Group", i, tag, ": nameList mode -", nameList)
                        end
                    else
                        sortKey = "ROLE:" .. i .. ":" .. roleOrderString

                        -- Use native sorting with groupFilter (simple role sorting only)
                        -- Use direct SetAttribute to bypass cache
                        header:SetAttribute("nameList", nil)
                        header:SetAttribute("groupFilter", tostring(i))
                        header:SetAttribute("groupingOrder", roleOrderString)
                        header:SetAttribute("groupBy", "ASSIGNEDROLE")
                        header:SetAttribute("sortMethod", "NAME")

                        headerDebug("  Group", i, ": native role sorting, groupFilter=", i)
                    end
                end

                -- Determine if we need the destructive Hide/Show cycle.
                -- SecureGroupHeaderTemplate re-evaluates children on Show(), calling
                -- ClearAllPoints+SetPoint on every child. This causes visible frame
                -- jumping. Only do it when sorting actually changed.
                local sortChanged = (sortKey ~= DF._lastGroupSortKey[i])
                DF._lastGroupSortKey[i] = sortKey

                if not sortChanged and header:IsShown() then
                    -- Sorting unchanged and header already shown — skip Hide/Show
                    DF:Debug("ROSTER", "  Group %d: sort unchanged, skipping Hide/Show", i)
                else
                    -- Sorting changed or header needs to be shown — do the full cycle
                    header:Hide()
                    header:Show()
                    DF:SetHeaderChildrenEventsEnabled(header, true)
                    local childCountAfter = 0
                    for ci = 1, 5 do
                        local ch = header:GetAttribute("child" .. ci)
                        if ch and ch:IsShown() then childCountAfter = childCountAfter + 1 end
                    end
                    DF:Debug("ROSTER", "  Group %d: Hide/Show (sortChanged=%s), children -> %d", i, tostring(sortChanged), childCountAfter)
                end
            end
        end
    end
    
    -- ── Skip redundant repositions ──────────────────────────────────────────
    -- Re-firing the secure snippet when nothing about the grouped layout changed
    -- makes the grid visibly snap/settle. That happened on unrelated GUI
    -- interaction (any refresh that re-runs the raid layout), producing a stream
    -- of identical no-op repositions. Bail out here — after restoring suppression
    -- so nothing gets stuck — unless sort order, populated counts, or the layout
    -- signature actually changed.
    do
        DF._lastGroupCount = DF._lastGroupCount or {}
        local counts, countChanged = {}, false
        for gi = 1, 8 do
            local header = DF.raidSeparatedHeaders[gi]
            local count = 0
            if header then
                for ci = 1, 5 do
                    local ch = header:GetAttribute("child" .. ci)
                    if ch and ch:IsShown() then count = count + 1 end
                end
            end
            counts[gi] = count
            if DF._lastGroupCount[gi] ~= count then countChanged = true end
        end

        local sortChangedAny = false
        for gi = 1, 8 do
            if DF._lastGroupSortKey[gi] ~= prevSortKeys[gi] then
                sortChangedAny = true
                break
            end
        end

        -- A POPULATED header can be shown yet UNANCHORED: the secure position
        -- snippet ClearAllPoints()s every group header and only re-anchors
        -- populated slots, so a raid-to-party collapse (all counts hit 0)
        -- strips the anchors while the caches above still describe the
        -- populated raid. Converting back with the same roster, nothing above
        -- reads as changed, and the early-out below would skip the only
        -- reposition that could re-anchor the headers — frames stay alive
        -- (shown, units assigned, alpha 1) but draw nothing until a /reload.
        -- GetLeft() is nil on a frame with no resolved rect. Gate on
        -- counts[gi] > 0: an EMPTY visible group is legitimately left
        -- unanchored by the same snippet, so testing it would fire on every
        -- pass in any raid that doesn't fill all enabled groups, permanently
        -- defeating the redundant-reposition early-out.
        local headerUnanchored = false
        for gi = 1, 8 do
            local gh = DF.raidSeparatedHeaders[gi]
            if gh and counts[gi] > 0 and gh:IsShown() and not gh:GetLeft() then
                headerUnanchored = true
                break
            end
        end

        local changed = sortChangedAny or countChanged or headerUnanchored
            or (DF._lastRaidLayoutSig ~= layoutSig)
            or (not DF._raidSortApplied)

        if not changed then
            if DF.raidPositionHandler then
                DF.raidPositionHandler:SetAttribute("suppressreposition", 0)
            end
            DF:Debug("ROSTER", "ApplyRaidGroupSorting: no positional change, skipping reposition")
            return
        end

        for gi = 1, 8 do DF._lastGroupCount[gi] = counts[gi] end
        DF._lastRaidLayoutSig = layoutSig
        DF._raidSortApplied = true
    end

    -- Update layout attributes and position handler settings WHILE suppress is still on.
    -- UpdateRaidHeaderLayoutAttributes clears child anchor points, which causes
    -- SecureGroupHeaderTemplate to re-anchor children (firing OnShow). If suppress
    -- were already off, each child OnShow would independently fire the position snippet,
    -- creating N redundant repositions. By keeping suppress on, those OnShow hooks
    -- are no-ops, and we fire ONE authoritative reposition after unsuppressing.
    --
    -- IMPORTANT: Force-clear the layout cache before updating attributes.
    -- An auto-profile switch may have applied new frame dimensions (frameWidth,
    -- frameHeight, groupSpacing, etc.) between the roster throttle firing and this
    -- sort running. Without the cache clear, UpdateRaidHeaderLayoutAttributes skips
    -- if horizontal/spacing appear unchanged, and the position snippet fires with
    -- stale handler attributes — causing groups to overlap.
    lastLayoutHorizontal = nil
    lastLayoutSpacing = nil
    DF:UpdateRaidPositionAttributes()

    -- NOW unsuppress and fire the single authoritative reposition
    DF:Debug("ROSTER", "ApplyRaidGroupSorting: unsuppressing, triggering authoritative reposition")
    if DF.raidPositionHandler then
        DF.raidPositionHandler:SetAttribute("suppressreposition", 0)
    end

    -- Authoritative Lua-side recount: secure OnShow/OnHide hooks may have
    -- set intermediate counts during the Hide/Show cycle above. Recount
    -- from Lua to guarantee the position snippet sees final child state.
    -- This is critical for CENTER alignment where all groups shift when
    -- numPopulated changes — stale counts produce wrong centering offsets.
    if DF.raidPositionHandler then
        for i = 1, 8 do
            local header = DF.raidSeparatedHeaders[i]
            if header then
                local count = 0
                for ci = 1, 5 do
                    local ch = header:GetAttribute("child" .. ci)
                    if ch and ch:IsShown() then count = count + 1 end
                end
                DF.raidPositionHandler:SetAttribute("group" .. i .. "count", count)
            end
        end
    end

    DF:TriggerRaidPosition()

    -- Safety net: SecureGroupHeaderTemplate may defer child Show/Hide past
    -- the synchronous reposition above. Re-trigger after a brief delay to
    -- catch any stale group counts. (#571)
    C_Timer.After(0.05, function()
        if not InCombatLockdown() then
            DF:TriggerRaidPosition()
        end
    end)

    -- Re-anchor container after positionSnippet resizes it — the CENTER anchor
    -- shifts when dimensions change, so reapply the saved position
    C_Timer.After(0.1, function()
        if not InCombatLockdown() and DF.UpdateRaidContainerPosition then
            DF:Debug("ROSTER", "ApplyRaidGroupSorting: re-anchoring raidContainer after resize")
            DF:UpdateRaidContainerPosition()
        end
    end)

    -- Log header positions after reposition for diagnosis
    if DF.raidSeparatedHeaders then
        for i = 1, 8 do
            local h = DF.raidSeparatedHeaders[i]
            if h and h:IsShown() then
                local point, relativeTo, relativePoint, x, y = h:GetPoint(1)
                local childCount = 0
                for ci = 1, 5 do
                    local ch = h:GetAttribute("child" .. ci)
                    if ch and ch:IsShown() then childCount = childCount + 1 end
                end
                DF:Debug("ROSTER", "  Final G%d: %d children, pos=(%s, %.0f, %.0f)",
                    i, childCount, point or "nil", x or 0, y or 0)
            end
        end
    end
    
    -- Clear the roster cache (no longer needed until next update)
    ClearRaidRosterCache()
    
    -- NOTE: Frame refresh is handled by OnAttributeChanged when units swap
    -- No need for explicit refresh here - it causes flicker due to double update

    headerDebug("Raid group sorting applied")

    -- OnFramesSorted callback is fired from child OnAttributeChanged.
end

-- ☠ (Removed) DF:RefreshRaidGroupFrames, DF:RefreshRaidFlatFrames and
-- DF:RefreshPartyFrames -- the three "refresh all X frames after sorting changes"
-- helpers. None had a caller in either addon.
--
-- ⚠ THEIR NAMES DESCRIBED A CONTRACT THAT NO LONGER EXISTS, which is why all three
-- rotted together: sorting does not call anything to refresh afterwards any more.
-- Each sat directly beneath a sort path ending in "OnFramesSorted callback is fired
-- from child OnAttributeChanged" -- the frames re-render from that attribute change,
-- so there is nothing left for a post-sort sweep to do.
--
-- Their only other mention was in Profiler's PROFILED_FUNCTIONS, which wraps
-- DF[name] rather than calling it; those entries are gone too. DF:FullFrameRefresh,
-- which they called, is live and has other callers.

-- Comprehensive frame refresh - updates ALL visual elements
-- Called when unit assignment changes due to sorting
function DF:FullFrameRefresh(frame)
    DF:RosterDebugCount("FullFrameRefresh")
    if not frame or not frame.unit then return end
    
    -- Clear color tracking to force re-evaluation of background colors
    -- (When units swap positions due to sorting, old colors would persist otherwise)
    frame.dfCurrentBgTexture = nil  -- Background texture tracking
    frame.dfAggroActive = nil       -- Aggro highlight state
    frame.dfAggroColor = nil        -- Aggro color override
    
    -- Core frame update - handles health, name, power, dead/offline state, AND colors
    -- NOTE: Do NOT call ApplyHealthColors separately - UpdateUnitFrame handles it via ElementAppearance
    if DF.UpdateUnitFrame then DF:UpdateUnitFrame(frame, "FullFrameRefresh") end

    -- A class-coloured border depends on this slot's unit, which is only known
    -- now (UpdateUnitFrame doesn't touch the border, and the heavier UpdateFrame
    -- that sets it doesn't run on roster/unit changes). Refresh the colour so
    -- every member's border tracks their class, not just the player's.
    if frame.border and frame.border.SetBorderColor and DF.GetFrameBorderColor then
        frame.border:SetBorderColor(DF:GetFrameBorderColor(frame, DF:GetFrameDB(frame)))
    end

    -- Auras (buffs/debuffs)
    if DF.UpdateAuras then DF:UpdateAuras(frame) end
    -- ☠ The defensive row is its OWN container handle (frame.defensiveFactory), driven
    -- only through UpdateDefensiveBar — UpdateAuras never touches it. This refresh runs
    -- on every header unit reassignment, so without the call the buff and debuff rows
    -- retargeted to the new occupant while the defensive row kept showing the previous
    -- one's defensives (#1063, "defensives get copied to Valeera").
    if DF.UpdateDefensiveBar then DF:UpdateDefensiveBar(frame) end

    -- Icons
    if DF.UpdateRoleIcon then DF:UpdateRoleIcon(frame, "FullFrameRefresh") end
    if DF.UpdateLeaderIcon then DF:UpdateLeaderIcon(frame) end
    if DF.UpdateRaidTargetIcon then DF:UpdateRaidTargetIcon(frame) end
    if DF.UpdateReadyCheckIcon then DF:UpdateReadyCheckIcon(frame) end
    if DF.UpdateCenterStatusIcon then DF:UpdateCenterStatusIcon(frame) end
    
    -- Buff indicators
    if DF.UpdateMissingBuffIcon then DF:UpdateMissingBuffIcon(frame) end
    
    -- Overlays
    -- pcall'd: the dispel overlay is the only element here that reaches into the
    -- native aura container's slot buttons, so it is the one most exposed to a
    -- forbidden-object / taint throw. Unguarded, such a throw aborts the REST of
    -- this function -- highlights, status icons, resource bar, absorbs and heal
    -- prediction all silently stop updating on that frame (bug #1011). One broken
    -- element must not take the other five down with it.
    if DF.UpdateDispelOverlay then pcall(DF.UpdateDispelOverlay, DF, frame) end

    -- Highlights (selection, aggro, etc.)
    if DF.UpdateHighlights then DF:UpdateHighlights(frame) end
    
    -- Status icons (phased, summon, resurrection, AFK, vehicle, raid role)
    if DF.UpdateAllStatusIcons then DF:UpdateAllStatusIcons(frame) end
    
    -- Bars
    -- NOTE: ApplyResourceBarLayout must be called first to show/hide the bar based on settings
    -- UpdateResourceBar only updates values for already-visible bars
    if DF.ApplyResourceBarLayout then DF:ApplyResourceBarLayout(frame) end
    if DF.UpdateResourceBar then DF:UpdateResourceBar(frame) end
    if DF.UpdateAbsorb then DF:UpdateAbsorb(frame) end
    if DF.UpdateHealAbsorb then DF:UpdateHealAbsorb(frame) end
    if DF.UpdateHealPrediction then DF:UpdateHealPrediction(frame) end
end

-- Refresh all LIVE frames (party, arena, and raid) - calls FullFrameRefresh on each
-- Use this when settings change that affect data-driven content (health text format, name truncation, etc.)
function DF:RefreshLiveFrames()
    -- Skip if in test mode (live frames aren't visible)
    if DF.testMode or DF.raidTestMode then
        return
    end
    
    -- Refresh party frames
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(function(frame)
            if frame and frame.unit then
                DF:FullFrameRefresh(frame)
            end
        end)
    end
    
    -- Refresh arena frames (use party settings)
    if DF.IterateArenaFrames then
        DF:IterateArenaFrames(function(frame)
            if frame and frame.unit then
                DF:FullFrameRefresh(frame)
            end
        end)
    end
    
    -- Refresh raid frames
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(frame)
            if frame and frame.unit then
                DF:FullFrameRefresh(frame)
            end
        end)
    end

    -- ☠ AND PINNED — a pinned frame IS a live frame. None of the three iterators above
    -- reaches one, so every caller of this function silently skipped them: the combat-ENTRY
    -- half of the HideInCombat gates (PLAYER_REGEN_DISABLED routes here through
    -- RefreshAllVisibleFrames) plus every settings callback that refreshes data-driven
    -- content. Boss sets included — they are unit frames for friendly, healable NPCs.
    if DF.IteratePinnedFrames then
        DF.IteratePinnedFrames(function(frame)
            if frame and frame.unit then
                DF:FullFrameRefresh(frame)
            end
        end)
    end
end

-- Refresh ALL visible frames (both test and live)
-- Use this for settings callbacks that need to update whichever frames are currently visible
function DF:RefreshAllVisibleFrames()
    if DF.testMode or DF.raidTestMode then
        -- In test mode, refresh test frames
        if DF.RefreshTestFrames then
            DF:RefreshTestFrames()
        end
    else
        -- Not in test mode, refresh live frames
        DF:RefreshLiveFrames()
    end
end

-- ============================================================
-- NAMELIST-BASED PLAYER POSITIONING (Alternative approach)
-- ============================================================
-- This approach uses nameList attribute on SecureGroupHeaderTemplate
-- to position the player FIRST or LAST within their group.
-- 
-- Benefits:
-- - No separate raidPlayerHeader needed
-- - All groups managed by their own headers
-- - Works reliably out of combat
-- 
-- Limitations:
-- - Cannot update nameList in combat (UnitName not available in secure code)
-- - If player moves groups in combat, their old group will be wrong until combat ends
-- ============================================================

-- Build a namelist for a raid group that puts player first or last, sorted by role priority
function DF:BuildRaidGroupNameList(groupIndex, selfPosition)
    -- Use cached roster if available (much faster than calling GetRaidRosterInfo 40 times per group)
    if raidRosterCacheValid then
        local members = {}
        local playerInGroup = false
        
        for _, info in pairs(raidRosterCache) do
            if info.subgroup == groupIndex then
                if info.isPlayer then
                    playerInGroup = true
                end
                table.insert(members, {
                    unit = info.isPlayer and "player" or ("raid" .. info.raidIndex),
                    name = info.name,
                    isPlayer = info.isPlayer
                })
            end
        end
        
        return DF:BuildSortedNameList(members, DF:GetRaidDB(), selfPosition, playerInGroup)
    end
    
    -- Fallback: no cache, use original method
    local members = {}
    local playerName = UnitName("player")
    local playerInGroup = false
    
    for i = 1, GetNumGroupMembers() do
        local name, _, subgroup, _, _, class, _, _, _, _, _, role = GetRaidRosterInfo(i)
        if subgroup == groupIndex and name then
            -- Compare just the name part (without realm) to detect player
            local namePart = name:match("([^%-]+)") or name
            local isPlayer = (namePart == playerName)
            if isPlayer then
                playerInGroup = true
            end
            table.insert(members, {
                unit = isPlayer and "player" or ("raid" .. i),
                -- Use playerName (no realm) for player, full name for others
                name = isPlayer and playerName or name,
                isPlayer = isPlayer
            })
        end
    end
    
    -- Use the unified sorting function
    return DF:BuildSortedNameList(members, DF:GetRaidDB(), selfPosition, playerInGroup)
end

-- Build a namelist for party that puts player first or last, sorted by role priority
function DF:BuildPartyNameList(selfPosition)
    -- Get members in party (player + party1-4)
    local members = {}
    local playerName = UnitName("player")
    
    -- Add player
    table.insert(members, {
        unit = "player",
        name = playerName,
        isPlayer = true
    })
    
    -- Add party members
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            local name, realm = UnitName(unit)
            local fullName = name
            if realm and realm ~= "" then
                fullName = name .. "-" .. realm
            end
            if name then
                table.insert(members, {
                    unit = unit,
                    name = fullName,
                    isPlayer = false
                })
            end
        end
    end
    
    -- Use the unified sorting function
    return DF:BuildSortedNameList(members, DF:GetDB(), selfPosition, true)
end

-- ============================================================
-- UNIFIED NAMELIST SORTING
-- ============================================================
-- Builds a sorted nameList from a list of members
-- @param members: Array of {unit, name, isPlayer} entries
-- @param db: Database to read settings from (party or raid db)
-- @param selfPosition: "FIRST", "LAST", or "SORTED"
-- @param includesPlayer: Whether the player is in this group
-- @return: Comma-separated nameList string
function DF:BuildSortedNameList(members, db, selfPosition, includesPlayer)
    -- #78: drop members that belong to a pinned set with "Hide from Main Frames" on,
    -- so a pinned unit doesn't also appear in the main party/raid frames. The player
    -- is hidden only when they themselves are pinned into a hiding set (flagged via
    -- __hidePlayer). Live lookup so the filter tracks roster/membership changes; nil
    -- (the common case) is a cheap no-op.
    local hidden = DF.GetPinnedHiddenNames and DF:GetPinnedHiddenNames()
    if hidden then
        local kept = {}
        for _, m in ipairs(members) do
            local hide
            if m.isPlayer then
                hide = hidden.__hidePlayer  -- only when the player is pinned into a hiding set
            else
                hide = hidden[m.name]
            end
            if not hide then
                kept[#kept + 1] = m
            end
        end
        members = kept
    end

    -- #78: when frame sorting is OFF, "Hide from Main Frames" still forces the
    -- nameList path (the only way to exclude a unit from a secure header). In that
    -- case we must NOT impose role/class ordering — the user turned sorting off and
    -- expects natural order. Emit the kept members in group-index order (player
    -- first, then by unit index), mirroring what the INDEX sortMethod would have
    -- shown, just with the hidden units removed. The order MUST be deterministic
    -- (not raw pairs() iteration, which is unstable and would reshuffle the secure
    -- header mid-encounter — see the bug-947 tiebreak note below), so we sort by a
    -- stable per-unit index.
    if not db.sortEnabled then
        local ordered = {}
        for _, m in ipairs(members) do ordered[#ordered + 1] = m end
        local function UnitIndex(m)
            if m.isPlayer then return 0 end
            return tonumber(string.match(m.unit or "", "%d+")) or 50
        end
        table.sort(ordered, function(a, b)
            local ia, ib = UnitIndex(a), UnitIndex(b)
            if ia ~= ib then return ia < ib end
            return (a.name or "") < (b.name or "")
        end)
        local idxNames = {}
        for _, m in ipairs(ordered) do idxNames[#idxNames + 1] = m.name end
        local idxResult = ProcessNameList(table.concat(idxNames, ","), STRIP_REALMS_FROM_NAMELIST)
        headerDebug("  Sorting OFF + hide active: preserving index order:", idxResult)
        return idxResult
    end

    local roleOrder = db.sortRoleOrder or {"TANK", "HEALER", "MELEE", "RANGED"}
    local separateMeleeRanged = db.sortSeparateMeleeRanged
    local sortByClass = db.sortByClass
    local sortAlphabetical = db.sortAlphabetical
    
    if DF:DebugActive("HEADERS") then
        headerDebug("=== BuildSortedNameList ===")
        headerDebug("  selfPosition:", selfPosition, "members:", #members)
        DF:Debug("HEADERS", "  separateMeleeRanged: %s", tostring(separateMeleeRanged))
        DF:Debug("HEADERS", "  sortByClass: %s", tostring(sortByClass))
        DF:Debug("HEADERS", "  sortAlphabetical: %s", tostring(sortAlphabetical))
        if DF:DebugActive("HEADERS") then
            headerDebug("  roleOrder:", table.concat(roleOrder, ", "))
        end
    end
    
    -- Build role priority map (lower = higher priority)
    local rolePriority = {}
    for i, role in ipairs(roleOrder) do
        if role == "MELEE" or role == "RANGED" then
            if separateMeleeRanged then
                rolePriority[role] = i
            else
                if not rolePriority["DAMAGER"] then
                    rolePriority["DAMAGER"] = i
                end
            end
        else
            rolePriority[role] = i
        end
    end
    -- Default priorities for any missing roles
    rolePriority["TANK"] = rolePriority["TANK"] or 1
    rolePriority["HEALER"] = rolePriority["HEALER"] or 2
    if separateMeleeRanged then
        rolePriority["MELEE"] = rolePriority["MELEE"] or 3
        rolePriority["RANGED"] = rolePriority["RANGED"] or 4
    else
        rolePriority["DAMAGER"] = rolePriority["DAMAGER"] or 3
    end
    rolePriority["NONE"] = 99
    
    -- Build class priority from database
    local classOrder = db.sortClassOrder or {
        "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER", 
        "MAGE", "MONK", "PALADIN", "PRIEST", "ROGUE", 
        "SHAMAN", "WARLOCK", "WARRIOR"
    }
    local classPriority = {}
    for i, className in ipairs(classOrder) do
        classPriority[className] = i
    end
    
    -- ★ ONE SHARED TABLE (Core/Config.lua). This used to be a local copy; see the
    -- header there for the three-way disagreement it caused.
    local meleeSpecs = DF.MELEE_SPECS
    
    local meleeClasses = DF.MELEE_CLASSES
    
    -- Get melee/ranged type for a unit.
    -- Priority: SecureSort.specCache (persistent across INSPECT_READY) → game's inspect cache → class fallback.
    -- Checking the persistent cache first avoids flipping a DPS's classification once we've learned
    -- their real spec — if we only relied on GetInspectSpecialization, a Hunter Survival / Feral Druid /
    -- WW Monk / Ret Pally / Enh Shaman would default to RANGED before inspect, then jump to MELEE later.
    local function GetMeleeRangedType(unit, role)
        if role ~= "DAMAGER" then return nil end

        local specID
        if UnitIsUnit(unit, "player") then
            specID = GetSpecializationInfo(GetSpecialization())
        else
            local cache = DF.SecureSort and DF.SecureSort.specCache
            if cache then
                local name = GetUnitName(unit, true)
                local cached = name and cache[name]
                if cached and cached.specID and cached.specID > 0 then
                    specID = cached.specID
                end
            end
            if not specID then
                specID = GetInspectSpecialization(unit)
            end
        end

        if specID and specID > 0 then
            return meleeSpecs[specID] and "MELEE" or "RANGED"
        end

        local _, class = UnitClass(unit)
        return meleeClasses[class] and "MELEE" or "RANGED"
    end
    
    -- Build sorted entries for each member
    local sortedMembers = {}
    local playerEntry = nil
    
    for _, member in ipairs(members) do
        local role = UnitGroupRolesAssigned(member.unit) or "NONE"
        local _, class = UnitClass(member.unit)
        local meleeRanged = separateMeleeRanged and GetMeleeRangedType(member.unit, role) or nil
        local sortRole = meleeRanged or role
        
        local entry = {
            name = member.name,
            isPlayer = member.isPlayer,
            role = role,
            sortRole = sortRole,
            class = class or "UNKNOWN",
            classPriority = classPriority[class] or 99,
            rolePriority = rolePriority[sortRole] or 99
        }
        
        if member.isPlayer then
            playerEntry = entry
        else
            table.insert(sortedMembers, entry)
        end
        
        if DF:DebugActive("HEADERS") then
            local tag = member.isPlayer and "Player" or member.unit
            if DF:DebugActive("HEADERS") then
                headerDebug("  " .. tag .. ":", member.name, 
                      "role=", role, "sortRole=", sortRole,
                      "class=", class, "classPri=", entry.classPriority, "rolePri=", entry.rolePriority)
            end
        end
    end
    
    -- Per-element key for name comparisons: a unit's name can be SECRET in
    -- combat (Midnight), and even ~= on a secret string throws. A secret (or
    -- missing) name falls back to the unit token — plain and unique. The
    -- substitution is a pure per-element function, so the comparator stays a
    -- consistent total order for table.sort.
    local function NameKey(m)
        local n = m.name
        if n == nil or issecretvalue(n) then return tostring(m.unit) end
        return n
    end

    -- Sort function: Role -> Class -> Alphabetical
    local function SortMembers(a, b)
        if a.rolePriority ~= b.rolePriority then
            return a.rolePriority < b.rolePriority
        end
        if sortByClass and a.classPriority ~= b.classPriority then
            return a.classPriority < b.classPriority
        end
        local nameA, nameB = NameKey(a), NameKey(b)
        if sortAlphabetical and nameA ~= nameB then
            if sortAlphabetical == "ZA" then
                return nameA > nameB
            else
                return nameA < nameB
            end
        end
        -- Deterministic final tiebreak. Without one, members with equal sort keys
        -- (same role, Alphabetical off) have no defined order, and Lua's table.sort
        -- is NOT stable — so a roster-driven re-sort mid-encounter reshuffles
        -- same-role players, making the group frames rearrange during M+ pulls.
        -- Break ties by name (invariant for the session, and realm-qualified in the
        -- nameList so cross-realm names don't collide) so every re-sort of the same
        -- roster produces an identical order and the secure header never reorders.
        if nameA ~= nameB then
            return nameA < nameB
        end
        return false
    end

    -- Sort non-player members
    table.sort(sortedMembers, SortMembers)
    
    -- Build final name list based on selfPosition
    local names = {}
    
    if selfPosition == "FIRST" and playerEntry then
        -- Player first, then sorted others
        table.insert(names, playerEntry.name)
        for _, entry in ipairs(sortedMembers) do
            table.insert(names, entry.name)
        end
        headerDebug("  Mode: FIRST - player at position 1")
        
    elseif selfPosition == "LAST" and playerEntry then
        -- Sorted others, then player
        for _, entry in ipairs(sortedMembers) do
            table.insert(names, entry.name)
        end
        table.insert(names, playerEntry.name)
        headerDebug("  Mode: LAST - player at last position")
        
    else
        -- SORTED: Include player in normal sorting
        if playerEntry then
            table.insert(sortedMembers, playerEntry)
            table.sort(sortedMembers, SortMembers)
        end
        for _, entry in ipairs(sortedMembers) do
            table.insert(names, entry.name)
        end
        headerDebug("  Mode: SORTED - player sorted with group")
    end
    
    local result = table.concat(names, ",")
    
    -- Strip realm names for cross-realm compatibility
    -- SecureGroupHeaderTemplate uses UnitName() internally which doesn't include realms
    result = ProcessNameList(result, STRIP_REALMS_FROM_NAMELIST)
    
    headerDebug("  Final nameList:", result)
    
    return result
end


-- Apply sorting to flat raid layout (uses FlatRaidFrames)
function DF:ApplyRaidFlatSorting()
    if InCombatLockdown() then return end

    -- Delegate to FlatRaidFrames
    if DF.FlatRaidFrames then
        DF.FlatRaidFrames:UpdateNameList()
    end
    -- OnFramesSorted callback is fired from child OnAttributeChanged.
end

-- (Removed) DF:RefreshRaidFlatFrames -- no callers; see the note on its group-frame
-- twin above. FlatRaidFrames:RefreshAllChildFrames, which it delegated to, is live.

-- Toggle raid group debug backgrounds
function DF:ToggleRaidDebugBackgrounds()
    if not DF.raidSeparatedHeaders then
        DF:Err("No raid headers exist")
        return
    end
    
    if InCombatLockdown() then
        DF:Err("Cannot toggle in combat")
        return
    end
    
    DF.raidDebugBgVisible = not DF.raidDebugBgVisible
    
    local db = DF:GetRaidDB()
    local frameWidth = db.frameWidth or 80
    local frameHeight = db.frameHeight or 40
    local spacing = db.frameSpacing or 2
    local groupHeight = 5 * frameHeight + 4 * spacing
    
    -- Show/hide raid container for debug
    if DF.raidContainer then
        if DF.raidDebugBgVisible then
            DF.raidContainer:Show()
        elseif not IsInRaid() then
            DF.raidContainer:Hide()
        end
    end
    
    for i = 1, 8 do
        local header = DF.raidSeparatedHeaders[i]
        if header then
            -- Set size so background is visible
            header:SetSize(frameWidth, groupHeight)
            
            -- Show header for debug even if not in raid
            if DF.raidDebugBgVisible then
                header:Show()
            elseif not IsInRaid() then
                header:Hide()
            end
            
            if header.debugBackground then
                if DF.raidDebugBgVisible then
                    header.debugBackground:Show()
                else
                    header.debugBackground:Hide()
                end
            end
            if header.debugLabel then
                if DF.raidDebugBgVisible then
                    header.debugLabel:Show()
                else
                    header.debugLabel:Hide()
                end
            end
        end
    end
    
    -- Re-position headers so they show correctly
    if DF.raidDebugBgVisible then
        DF:PositionRaidHeaders()
    end
    
    DF:Say("Raid debug backgrounds", DF.raidDebugBgVisible and "on" or "off",
        DF.raidDebugBgVisible and "GOOD" or "NEUTRAL")
end

-- ============================================================
-- HELPER FUNCTIONS FOR FRAME ACCESS
-- Use these instead of DF.partyFrames[i] directly
-- ============================================================

function DF:GetPlayerFrame()
    -- Player is now part of partyHeader (via nameList sorting)
    -- Find the child that has the "player" unit
    if DF.partyHeader then
        for i = 1, 5 do
            local child = DF.partyHeader:GetAttribute("child" .. i)
            if child then
                local unit = child:GetAttribute("unit")
                if unit == "player" then
                    return child
                end
            end
        end
    end
    return nil
end

function DF:GetPartyFrame(index)
    -- index 1-4 for party1-4
    -- Find the child that has the "partyN" unit
    if DF.partyHeader then
        local targetUnit = "party" .. index
        for i = 1, 5 do
            local child = DF.partyHeader:GetAttribute("child" .. i)
            if child then
                local unit = child:GetAttribute("unit")
                if unit == targetUnit then
                    return child
                end
            end
        end
    end
    return nil
end

function DF:GetRaidFrame(index)
    -- index 1-40 for raid1-40
    local db = DF:GetRaidDB()
    
    if db.raidUseGroups and DF.raidSeparatedHeaders then
        -- Separated mode: find which group header has this frame
        -- ☠ THE ARITHMETIC IS A GUESS, SO VERIFY IT. Separated headers are filtered by
        -- SUBGROUP and ordered by nameList, so raid index N sits in subgroup ceil(N/5) at
        -- slot ((N-1)%5)+1 only while the roster happens to be densely packed in index
        -- order -- which it stops being after any promotion or group move. Unverified,
        -- this returned a frame showing a DIFFERENT player, and both
        -- DandersFrames_GetRaidFrame (a public API) and the DF.raidFrames proxy hand that
        -- straight to callers.
        local wanted = "raid" .. index
        local group = math.ceil(index / 5)
        local indexInGroup = ((index - 1) % 5) + 1
        local header = DF.raidSeparatedHeaders[group]
        if header then
            local guess = header:GetAttribute("child" .. indexInGroup)
            if guess and guess.unit == wanted then return guess end
        end
        -- Fall back to a scan. Costs a walk of at most 8 headers x 5 children, only on the
        -- rosters where the fast path was wrong -- and correctness beats the guess.
        for g = 1, 8 do
            local h = DF.raidSeparatedHeaders[g]
            if h then
                for i = 1, 5 do
                    local child = h:GetAttribute("child" .. i)
                    if child and child.unit == wanted then return child end
                end
            end
        end
        return nil
    elseif DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        -- Flat mode: use FlatRaidFrames header
        return DF.FlatRaidFrames.header:GetAttribute("child" .. index)
    end
    
    return nil
end


function DF:IteratePartyFrames(callback)
    -- Player frame
    local playerFrame = DF:GetPlayerFrame()
    if playerFrame then
        if callback(playerFrame, 0, "player") then return true end
    end
    
    -- Party frames 1-4
    for i = 1, 4 do
        local frame = DF:GetPartyFrame(i)
        if frame then
            if callback(frame, i, "party" .. i) then return true end
        end
    end
end

-- Iterate arena frames (raid1-5 in arena header)
function DF:IterateArenaFrames(callback)
    if not DF.arenaHeader then return end
    
    for i = 1, 5 do
        local frame = DF.arenaHeader:GetAttribute("child" .. i)
        if frame then
            if callback(frame, i, "raid" .. i) then return true end
        end
    end
end

function DF:IterateRaidFrames(callback)
    local db = DF:GetRaidDB()
    
    if db.raidUseGroups and DF.raidSeparatedHeaders then
        -- Separated mode
        local index = 1
        for group = 1, 8 do
            local header = DF.raidSeparatedHeaders[group]
            if header then
                for i = 1, 5 do
                    local frame = header:GetAttribute("child" .. i)
                    if frame then
                        if callback(frame, index, "raid" .. index) then return true end
                        index = index + 1
                    end
                end
            end
        end
    elseif DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        -- Flat mode: use FlatRaidFrames header
        for i = 1, 40 do
            local frame = DF.FlatRaidFrames.header:GetAttribute("child" .. i)
            if frame then
                if callback(frame, i, "raid" .. i) then return true end
            end
        end
    end
end

function DF:IterateAllFrames(callback)
    if DF:IsInArena() then
        -- Arena: use arena header (raid units, party layout)
        -- Don't iterate party or raid headers - they're hidden in arena
        if DF:IterateArenaFrames(callback) then return true end
    else
        if DF:IteratePartyFrames(callback) then return true end
        if DF:IterateRaidFrames(callback) then return true end
    end
end

-- ============================================================
-- HEADER VISIBILITY MANAGEMENT
-- ============================================================

function DF:UpdateHeaderVisibility(skipRaidReposition)
    if InCombatLockdown() then
        -- Can't modify secure frames during combat - defer until PLAYER_REGEN_ENABLED
        -- State driver registration requires SetAttribute which is protected in combat
        DF.pendingVisibilityUpdate = true
        DF.pendingStateDrivers = not DF.testModeStateDriversActive and not DF.testMode and not DF.raidTestMode
        return
    end
    
    -- Don't show live frames while in test mode
    if DF.testMode or DF.raidTestMode then
        return
    end
    
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    -- Use unified content type detection
    local contentType = DF:GetContentType()
    local inArena = (contentType == "arena")
    local inRaid = IsInRaid() and not inArena  -- Raid but NOT arena
    local inParty = IsInGroup() and not IsInRaid()

    -- ☠ Guarded: debugstack() builds a stack string whether or not logging is
    -- on, and this runs on every roster and zone change. The FLATRAID traces
    -- elsewhere in this file already do it this way.
    if DF:DebugActive("VISIBILITY") then
        DF:Debug("VISIBILITY", "UpdateHeaderVisibility: content=%s inRaid=%s inParty=%s skipRaidRepos=%s caller=%s",
            tostring(contentType), tostring(inRaid), tostring(inParty), tostring(skipRaidReposition),
            debugstack(2, 1, 0) or "?")
    end

    -- (Removed) an IsInInstance() call whose BOTH return values were unused — the
    -- "ARENA DEBUG" trace it fed is long gone, so the call did nothing but cost an
    -- API round trip on every visibility evaluation.

    -- Solo mode check
    local showSolo = db.soloMode and not inParty and not inRaid and not inArena
    
    -- ARENA FIX: Clear stale state drivers that would fight arena visibility.
    -- [group:raid]=true in arena, so party-hide/raid-show drivers must be removed.
    -- CRITICAL: Always unregister regardless of testModeStateDriversActive flag.
    -- State drivers PERSIST through /reload, but the tracking flag resets to nil.
    -- UnregisterStateDriver is safe to call even if no driver is registered.
    if inArena then
        if DF.partyContainer then
            UnregisterStateDriver(DF.partyContainer, "visibility")
        end
        if DF.partyHeader then
            UnregisterStateDriver(DF.partyHeader, "visibility")
        end
        if DF.raidContainer then
            UnregisterStateDriver(DF.raidContainer, "visibility")
        end
        if DF.raidSeparatedHeaders then
            for i = 1, 8 do
                if DF.raidSeparatedHeaders[i] then
                    UnregisterStateDriver(DF.raidSeparatedHeaders[i], "visibility")
                end
            end
        end
        if DF.FlatRaidFrames then
            if DF.FlatRaidFrames.header then
                UnregisterStateDriver(DF.FlatRaidFrames.header, "visibility")
            end
            if DF.FlatRaidFrames.innerContainer then
                UnregisterStateDriver(DF.FlatRaidFrames.innerContainer, "visibility")
            end
        end
        DF.testModeStateDriversActive = false
    end
    
    -- ============================================================
    -- ARENA: Use arena header (raid units, party layout)
    -- ============================================================
    if DF.arenaHeader then
        if inArena then
            if not DF.arenaHeader:IsShown() then
                DF.arenaHeader:Show()
            end
        else
            DF.arenaHeader:Hide()
        end
    end
    
    -- ============================================================
    -- PARTY: Use party header (party units)
    -- Only when in party (not raid, not arena)
    -- ============================================================
    if DF.partyHeader then
        if (inParty or showSolo) and not inArena then
            -- Show header first, THEN set showSolo attribute.
            -- Setting showSolo on a hidden header triggers SecureGroupHeader_Update
            -- which configures children internally but can't show them. The subsequent
            -- Show() may not re-evaluate because it thinks children are already configured.
            -- By showing first (OnShow triggers initial update), then setting the attribute
            -- (OnAttributeChanged triggers a second update on the now-visible header),
            -- children are properly configured and displayed.
            if not DF.partyHeader:IsShown() then
                DF.partyHeader:Show()
            end
            DF.partyHeader:SetAttribute("showSolo", showSolo)
        else
            -- When hiding: set attribute first so template reconfigures with showSolo=false,
            -- preventing stale showSolo=true from resurrecting frames on later Hide/Show cycles.
            DF.partyHeader:SetAttribute("showSolo", showSolo)
            DF.partyHeader:Hide()
        end
    end
    
    -- ============================================================
    -- RAID: Use raid headers (only when in raid, NOT arena)
    -- ============================================================
    if inRaid then
        DF:UpdateRaidHeaderVisibility(skipRaidReposition)
    else
        -- Hide all raid headers (includes arena case)
        -- Also disable events on child frames (performance)
        if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
            DF.FlatRaidFrames.header:Hide()
            DF:SetHeaderChildrenEventsEnabled(DF.FlatRaidFrames.header, false)
        end
        if DF.raidSeparatedHeaders then
            for i = 1, 8 do
                if DF.raidSeparatedHeaders[i] then
                    DF.raidSeparatedHeaders[i]:Hide()
                    DF:SetHeaderChildrenEventsEnabled(DF.raidSeparatedHeaders[i], false)
                end
            end
        end
        if DF.raidContainer then
            DF.raidContainer:Hide()
        end
    end
    
    -- ============================================================
    -- CONTAINER VISIBILITY
    -- ============================================================
    if DF.partyContainer then
        if inArena then
            -- Arena uses partyContainer (same position as party frames)
            if DF.container then
                DF.container:Show()
            end
            DF.partyContainer:Show()
            -- Enable events on ARENA header (not party header - party frames are hidden in arena)
            if DF.arenaHeader then
                DF:SetHeaderChildrenEventsEnabled(DF.arenaHeader, true)
            end
            -- Disable party header events - party frames not used in arena
            DF:SetHeaderChildrenEventsEnabled(DF.partyHeader, false)
        elseif inParty or showSolo then
            if DF.container then
                DF.container:Show()
            end
            DF.partyContainer:Show()
            -- Re-enable events on party child frames
            DF:SetHeaderChildrenEventsEnabled(DF.partyHeader, true)
            -- Disable arena header events when not in arena
            if DF.arenaHeader then
                DF:SetHeaderChildrenEventsEnabled(DF.arenaHeader, false)
            end
        elseif inRaid then
            -- In actual raid (not arena) - hide party container
            -- Also disable events on child frames (performance)
            DF.partyContainer:Hide()
            DF:SetHeaderChildrenEventsEnabled(DF.partyHeader, false)
            if DF.arenaHeader then
                DF:SetHeaderChildrenEventsEnabled(DF.arenaHeader, false)
            end
        else
            DF.partyContainer:Hide()
            DF:SetHeaderChildrenEventsEnabled(DF.partyHeader, false)
            if DF.arenaHeader then
                DF:SetHeaderChildrenEventsEnabled(DF.arenaHeader, false)
            end
        end
    end

    -- Sync permanent mover visibility with the active frame set
    -- Without this, both party and raid movers stay visible after a party<->raid transition
    if DF.UpdatePermanentMoverVisibility then
        DF:UpdatePermanentMoverVisibility()
    end
end

function DF:UpdateRaidHeaderVisibility(skipReposition)
    if InCombatLockdown() then
        DF.pendingRaidHeaderVisibility = true
        return
    end

    -- Guard against infinite recursion: SetEnabled(false) calls back here
    if DF._updatingRaidHeaderVisibility then return end
    DF._updatingRaidHeaderVisibility = true

    DF:Debug("VISIBILITY", "UpdateRaidHeaderVisibility: skipReposition=%s", tostring(skipReposition))

    -- Don't show live frames while in test mode
    -- IMPORTANT: Clear the recursion guard before returning, otherwise all future
    -- calls to UpdateRaidHeaderVisibility are permanently blocked until ReloadUI.
    if DF.testMode or DF.raidTestMode then
        DF._updatingRaidHeaderVisibility = nil
        return
    end

    -- ⚠ AUDITED, NOT FIXED (2026-08-10). This function has no IsInRaid() gate, and the
    -- combat-deferred replay has none either: park a visibility update during combat,
    -- leave the raid before combat ends, and PLAYER_REGEN_ENABLED drains
    -- pendingRaidHeaderVisibility straight into here, showing the raid container and the
    -- flat raid header to someone no longer in a raid. The sibling branch beside that
    -- drain DOES test IsInRaid() before showing the container -- and then calls this
    -- unguarded function anyway.
    --
    -- ☠ An early `if not IsInRaid() then return end` here is NOT the fix, and was tried
    -- and reverted. This function is not show-only: further down it calls
    -- FlatRaidFrames:SetEnabled(false) and header:Hide() on the paths that tear raid
    -- headers back down. Bailing early would skip that teardown, so the frames stay up in
    -- the very case the guard was added for -- a different bug wearing the same clothes.
    --
    -- The real fix gates the SHOW paths while leaving the hide logic reachable, which
    -- needs a client to confirm against leaving a raid, a raid converting to a party, and
    -- the combat-deferred replay. See docs/12.1-final-audit-phase1.md (V40).
    local db = DF:GetRaidDB()

    -- Show container
    if DF.raidContainer then
        DF.raidContainer:Show()
    end
    
    -- Suppress repositioning during show/hide loop to prevent multiple
    -- partial repositions with stale group counts
    if DF.raidPositionHandler then
        DF.raidPositionHandler:SetAttribute("suppressreposition", 1)
    end

    if db.raidUseGroups then
        DF:Debug("VISIBILITY", "  Raid mode: GROUPED (separated headers)")
        -- Separated mode: show individual group headers

        -- CRITICAL: Hide FlatRaidFrames when switching to grouped mode
        if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
            DF.FlatRaidFrames:SetEnabled(false)
        end

        if DF.raidSeparatedHeaders then
            for i = 1, 8 do
                local header = DF.raidSeparatedHeaders[i]
                if header then
                    -- Show/hide based on group visibility settings
                    local showGroup = db.raidGroupVisible and db.raidGroupVisible[i]
                    if showGroup == nil then showGroup = true end  -- Default to show

                    if showGroup then
                        -- CRITICAL: Only call Show() if not already visible!
                        if not header:IsShown() then
                            header:Show()
                            DF:SetHeaderChildrenEventsEnabled(header, true)
                        end
                        -- Recalculate child count for this group
                        if DF.raidPositionHandler then
                            local count = 0
                            for j = 1, 5 do
                                local child = header:GetAttribute("child" .. j)
                                if child and child:IsShown() then
                                    count = count + 1
                                end
                            end
                            DF.raidPositionHandler:SetAttribute("group" .. i .. "count", count)
                        end
                    else
                        -- DEFENSE IN DEPTH: Neutralize header so it can never claim
                        -- or display units even if something unexpectedly shows it.
                        header:SetAttribute("showRaid", false)
                        header:SetAttribute("showParty", false)
                        header:SetAttribute("showPlayer", false)
                        header:SetAttribute("nameList", "")
                        header:SetAttribute("sortMethod", "NAMELIST")
                        header:SetAttribute("groupFilter", nil)

                        header:Hide()
                        DF:SetHeaderChildrenEventsEnabled(header, false)
                        -- Set count to 0 so positioning skips this group (no gap)
                        if DF.raidPositionHandler then
                            DF.raidPositionHandler:SetAttribute("group" .. i .. "count", 0)
                        end
                    end
                end
            end
        end
    else
        DF:Debug("VISIBILITY", "  Raid mode: FLAT (FlatRaidFrames)")
        -- Combined mode (flat layout): use FlatRaidFrames

        -- CRITICAL: Hide separated headers FIRST before enabling FlatRaidFrames.
        -- Also neutralize their secure attributes so stale groupFilter/nameList/showRaid
        -- values from the previous grouped layout can't bleed into the next switch.
        if DF.raidSeparatedHeaders then
            for i = 1, 8 do
                local header = DF.raidSeparatedHeaders[i]
                if header then
                    header:SetAttribute("showRaid", false)
                    header:SetAttribute("showParty", false)
                    header:SetAttribute("showPlayer", false)
                    header:SetAttribute("nameList", "")
                    header:SetAttribute("sortMethod", "NAMELIST")
                    header:SetAttribute("groupFilter", nil)
                    header:Hide()
                    DF:SetHeaderChildrenEventsEnabled(header, false)
                end
            end
        end

        -- Enable FlatRaidFrames (which will also hide separated headers as a safeguard)
        if DF.FlatRaidFrames then
            DF.FlatRaidFrames:SetEnabled(true)
        end
    end

    DF._updatingRaidHeaderVisibility = nil

    -- Reposition handling:
    -- When skipReposition=true (called from ProcessRosterUpdate before sorting),
    -- leave suppressreposition=1 so secure-side OnShow/OnAttributeChanged hooks
    -- can't fire stale repositions in the gap before ApplyRaidGroupSorting starts.
    -- The sorting function will unsuppress and fire the authoritative reposition.
    if not skipReposition then
        if DF.raidPositionHandler then
            DF.raidPositionHandler:SetAttribute("suppressreposition", 0)
        end
        DF:Debug("VISIBILITY", "  Triggering raid reposition (authoritative)")
        DF:TriggerRaidPosition()
    else
        DF:Debug("VISIBILITY", "  Leaving suppressreposition=1 (sorting will unsuppress)")
    end

    -- Log final header visibility state for diagnosis
    if DF.raidSeparatedHeaders then
        local vis = {}
        for i = 1, 8 do
            local h = DF.raidSeparatedHeaders[i]
            if h then
                local count = 0
                for ci = 1, 5 do
                    local ch = h:GetAttribute("child" .. ci)
                    if ch and ch:IsShown() then count = count + 1 end
                end
                vis[i] = h:IsShown() and count or -1  -- -1 = header hidden
            end
        end
        DF:Debug("VISIBILITY", "  Header states: G1=%d G2=%d G3=%d G4=%d G5=%d G6=%d G7=%d G8=%d (shown children, -1=hidden)",
            vis[1] or 0, vis[2] or 0, vis[3] or 0, vis[4] or 0, vis[5] or 0, vis[6] or 0, vis[7] or 0, vis[8] or 0)
    end
end

-- Position raid group headers relative to each other within the container
function DF:PositionRaidHeaders()
    if DF:DebugActive("FLATRAID") then
        DF:Debug("FLATRAID", "PositionRaidHeaders: called from\n%s", debugstack(2, 10, 0) or "unknown")
    end
    
    local db = DF:GetRaidDB()

    if not DF.raidContainer then return end

    -- Combined header mode (flat layout) - uses FlatRaidFrames
    if not db.raidUseGroups then
        if DF.FlatRaidFrames then
            DF.FlatRaidFrames:ApplyLayoutSettings()
        end
        return
    end

    -- Separated headers mode - delegate to secure handler
    -- This updates attributes and triggers secure repositioning
    -- Works both in and out of combat!
    DF:UpdateRaidPositionAttributes()
    
    headerDebug("PositionRaidHeaders: delegated to secure handler")
end

-- Update grouped raid frame sizes (separated headers only)
function DF:UpdateRaidGroupFrameSizes()
    if InCombatLockdown() then return end

    local db = DF:GetRaidDB()
    local frameWidth = db.frameWidth or 80
    local frameHeight = db.frameHeight or 40

    DF:Debug("HEADERS", "UpdateRaidGroupFrameSizes: width=%s height=%s", frameWidth, frameHeight)

    -- Update raidPlayerHeader frame (legacy, may not exist)
    if DF.raidPlayerHeader then
        local child = DF.raidPlayerHeader:GetAttribute("child1")
        if child then
            child:SetSize(frameWidth, frameHeight)
        end
    end

    -- Update separated headers child frame sizes
    -- ☠ SNAPPED, via SetPixelPerfectSize — not a raw SetSize. SecureGroupHeaderTemplate
    -- sizes the HEADER from child1:GetWidth()/GetHeight() (configureChildren, Blizzard's
    -- SecureGroupHeaders.lua), and the position handler's framewidth/frameheight are
    -- seeded snapped. A raw child here made the header's real extent disagree with the
    -- reserved 5-slot extent by the rounding delta whenever this ran after
    -- ApplyFrameLayout (which snaps). Same rule as the intra-group spacing at its
    -- SetAttribute site: one stride, snapped everywhere.
    if DF.raidSeparatedHeaders then
        for g = 1, 8 do
            local header = DF.raidSeparatedHeaders[g]
            if header then
                for i = 1, 5 do
                    local child = header:GetAttribute("child" .. i)
                    if child then
                        DF:SetPixelPerfectSize(child, frameWidth, frameHeight, db)
                    end
                end
            end
        end
    end

    -- Reposition headers with new sizes (triggers secure handler)
    DF:PositionRaidHeaders()
end

-- Update flat raid frame sizes (FlatRaidFrames header only)
function DF:UpdateRaidFlatFrameSizes()
    if InCombatLockdown() then return end

    local db = DF:GetRaidDB()
    local frameWidth = db.frameWidth or 80
    local frameHeight = db.frameHeight or 40

    DF:Debug("FLATRAID", "UpdateRaidFlatFrameSizes: %s x %s", tostring(frameWidth), tostring(frameHeight))

    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        for i = 1, 40 do
            local child = DF.FlatRaidFrames.header:GetAttribute("child" .. i)
            if child then
                -- Snapped for the same reason as the grouped children above: the header
                -- is sized from the child's live width, and the layout maths snap.
                DF:SetPixelPerfectSize(child, frameWidth, frameHeight, db)
            end
        end
    end

    -- Reposition flat layout with new sizes
    DF:PositionRaidHeaders()
end

-- Get which raid group the player is in (1-8, or nil if not in raid)
function DF:GetPlayerRaidGroup()
    if not IsInRaid() then 
        headerDebug("GetPlayerRaidGroup: Not in raid")
        return nil 
    end
    
    -- Get player's name for comparison
    local playerName = UnitName("player")
    local playerFullName = GetUnitName("player", true) -- includes realm
    
    headerDebug("GetPlayerRaidGroup: Looking for player:", playerName, "/", playerFullName)
    
    -- Scan all raid members and compare by name
    for i = 1, 40 do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if name then
            -- Compare names (GetRaidRosterInfo returns name with realm for cross-realm)
            if name == playerName or name == playerFullName or (playerFullName and name:find(playerName, 1, true)) then
                headerDebug("GetPlayerRaidGroup: Found player at index", i, "name=", name, "subgroup=", subgroup)
                return subgroup
            end
        end
    end
    
    -- Fallback: try UnitIsUnit comparison
    for i = 1, 40 do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if name and UnitIsUnit("raid" .. i, "player") then
            headerDebug("GetPlayerRaidGroup: Found via UnitIsUnit at raid", i, "subgroup=", subgroup)
            return subgroup
        end
    end
    
    headerDebug("GetPlayerRaidGroup: Could not find player's group")
    
    return nil
end

-- ============================================================
-- LAYOUT UPDATES
-- ============================================================

function DF:UpdatePartyHeaderLayout()
    if InCombatLockdown() then
        DF.pendingLayoutUpdate = true
        return
    end
    
    local db = DF:GetDB()
    
    -- ☠ WAS db.growHorizontal, WHICH NOTHING EVER WRITES. Three reads, zero writes,
    -- absent from Config -- so it was always nil and all three sites took the VERTICAL
    -- branch whatever the user chose. The rest of the addon spells this
    -- `growDirection == "HORIZONTAL"` (:1526, :1711, :3079).
    --
    -- ⚠ SCOPE: this was NOT "party frames are always vertical". DF:ApplyHeaderSettings
    -- reads growDirection correctly and calls SetPartyOrientation, so on the normal path
    -- the wrong orientation these two CREATE sites set is corrected straight afterwards.
    -- The one that could stand was UpdatePartyHeaderLayout: both its callers live in
    -- DF:ProcessHeaderCombatQueue, so it runs LAST on leaving combat with nothing
    -- re-applying the correct value behind it. Symptom: a party layout change queued
    -- during combat flips you to vertical when combat ends.
    -- ★ LIVE-ONLY: the preview reads growDirection via SecureSort:UpdateLayoutParams, so
    -- the preview was right and live was wrong. (Test-vs-live audit, 2026-08-07.)
    local horizontal = (db.growDirection == "HORIZONTAL")
    local spacing = db.frameSpacing or 2
    
    -- ============================================================
    -- UPDATE PARTY HEADER
    -- ============================================================
    if DF.partyHeader then
        -- Update solo mode attribute
        DF.partyHeader:SetAttribute("showSolo", db.soloMode or false)
        
        -- Update header layout attributes
        DF.partyHeader:SetAttribute("point", horizontal and "LEFT" or "TOP")
        -- IMPORTANT: Don't use Lua ternary with 0! (0 is falsy)
        if horizontal then
            DF.partyHeader:SetAttribute("xOffset", spacing)
            DF.partyHeader:SetAttribute("yOffset", 0)
        else
            DF.partyHeader:SetAttribute("xOffset", 0)
            DF.partyHeader:SetAttribute("yOffset", -spacing)
        end
        
        -- Update stored values for secure positioning
        DF.partyHeader:SetAttribute("frameWidth", db.frameWidth or 120)
        DF.partyHeader:SetAttribute("frameHeight", db.frameHeight or 50)
        DF.partyHeader:SetAttribute("spacing", spacing)
        DF.partyHeader:SetAttribute("horizontal", horizontal)

        -- Update header position
        DF.partyHeader:ClearAllPoints()
        if horizontal then
            DF.partyHeader:SetPoint("LEFT", DF.partyContainer, "LEFT", 0, 0)
        else
            DF.partyHeader:SetPoint("TOP", DF.partyContainer, "TOP", 0, 0)
        end
        
        -- Update frame sizes
        DF:IteratePartyFrames(function(frame)
            if frame then
                frame:SetSize(db.frameWidth or 120, db.frameHeight or 50)
            end
        end)
    end
    
    -- ============================================================
    -- UPDATE ARENA HEADER (same settings as party)
    -- ============================================================
    if DF.arenaHeader then
        -- Update header layout attributes (same as party)
        DF.arenaHeader:SetAttribute("point", horizontal and "LEFT" or "TOP")
        if horizontal then
            DF.arenaHeader:SetAttribute("xOffset", spacing)
            DF.arenaHeader:SetAttribute("yOffset", 0)
        else
            DF.arenaHeader:SetAttribute("xOffset", 0)
            DF.arenaHeader:SetAttribute("yOffset", -spacing)
        end
        
        -- Update stored values for secure positioning
        DF.arenaHeader:SetAttribute("frameWidth", db.frameWidth or 120)
        DF.arenaHeader:SetAttribute("frameHeight", db.frameHeight or 50)
        DF.arenaHeader:SetAttribute("spacing", spacing)
        DF.arenaHeader:SetAttribute("horizontal", horizontal)

        -- Update header position (same as party)
        DF.arenaHeader:ClearAllPoints()
        if horizontal then
            DF.arenaHeader:SetPoint("LEFT", DF.partyContainer, "LEFT", 0, 0)
        else
            DF.arenaHeader:SetPoint("TOP", DF.partyContainer, "TOP", 0, 0)
        end
        
        -- Update frame sizes
        DF:IterateArenaFrames(function(frame)
            if frame then
                frame:SetSize(db.frameWidth or 120, db.frameHeight or 50)
            end
        end)
    end
    
    -- Update visibility in case soloMode changed
    DF:UpdateHeaderVisibility()
end

function DF:UpdateRaidHeaderLayout()
    if InCombatLockdown() then
        DF.pendingLayoutUpdate = true
        return
    end
    
    local db = DF:GetRaidDB()
    
    -- Update combined header
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        -- Use the CORRECT setting names - raidPlayersPerRow, raidFlatHorizontalSpacing, etc.
        local playersPerUnit = db.raidPlayersPerRow or 5
        local hSpacing = db.raidFlatHorizontalSpacing or 2
        local vSpacing = db.raidFlatVerticalSpacing or 2
        local horizontal = (db.growDirection == "HORIZONTAL")
        local maxColumns = math.ceil(40 / playersPerUnit)
        
        -- Don't override layout attributes here - ApplyFlatLayoutAttributes handles that
        -- Just update frame dimensions
        DF.FlatRaidFrames.header:SetAttribute("frameWidth", db.frameWidth or 80)
        DF.FlatRaidFrames.header:SetAttribute("frameHeight", db.frameHeight or 40)
    end
    
    -- Update separated headers
    if DF.raidSeparatedHeaders then
        for i = 1, 8 do
            local header = DF.raidSeparatedHeaders[i]
            if header then
                header:SetAttribute("yOffset", -(db.frameSpacing or 2))
                header:SetAttribute("frameWidth", db.frameWidth or 80)
                header:SetAttribute("frameHeight", db.frameHeight or 40)
                header:SetAttribute("spacing", db.frameSpacing or 2)
            end
        end
    end
    
    -- Update frame sizes
    DF:IterateRaidFrames(function(frame)
        if frame then
            frame:SetSize(db.frameWidth or 80, db.frameHeight or 40)
        end
    end)
end

-- ============================================================
-- COMBAT QUEUE
-- ============================================================

DF.headerCombatQueue = {}

function DF:ProcessHeaderCombatQueue()
    if InCombatLockdown() then return end
    
    if DF.headerCombatQueue.visibility then
        DF:UpdateHeaderVisibility()
    end
    
    if DF.headerCombatQueue.partyLayout then
        DF:UpdatePartyHeaderLayout()
    end
    
    if DF.headerCombatQueue.raidLayout then
        DF:UpdateRaidHeaderLayout()
    end
    
    wipe(DF.headerCombatQueue)
end

-- Register for combat end
local headerCombatFrame = CreateFrame("Frame")
headerCombatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
headerCombatFrame:SetScript("OnEvent", function()
    -- Clear any active visibility state drivers (test mode or group transition)
    -- Safe to call even if Core.lua already cleared for test mode interruption
    if DF.testModeStateDriversActive then
        DF:ClearTestModeStateDrivers()
    end
    
    DF:ProcessHeaderCombatQueue()
    
    if DF.pendingVisibilityUpdate then
        DF.pendingVisibilityUpdate = nil
        DF.pendingRaidHeaderVisibility = nil  -- Subsumed by full visibility update
        DF.pendingRaidVisibilityUpdate = nil  -- Subsumed by full visibility update
        -- Register deferred state drivers if needed (was blocked during combat)
        if DF.pendingStateDrivers then
            DF.pendingStateDrivers = nil
            if DF.SetGroupTransitionStateDrivers then
                DF:SetGroupTransitionStateDrivers()
            end
        end
        DF:UpdateHeaderVisibility()
    end

    -- Process deferred raid header visibility (flat ↔ grouped switch)
    -- Only fires if pendingVisibilityUpdate didn't already handle it above
    if DF.pendingRaidHeaderVisibility then
        DF.pendingRaidHeaderVisibility = nil
        DF:UpdateRaidHeaderVisibility()
    end

    -- Process orphan pendingRaidVisibilityUpdate (set by UpdateLiveRaidFrames
    -- in Init.lua when called during combat — previously never consumed)
    if DF.pendingRaidVisibilityUpdate then
        DF.pendingRaidVisibilityUpdate = nil
        -- Replay what UpdateLiveRaidFrames does: show raidContainer + sync headers
        if IsInRaid() and DF.raidContainer then
            DF.raidContainer:Show()
        end
        DF:UpdateRaidHeaderVisibility()
    end

    local raidDb = DF:GetRaidDB()
    local isFlatRaid = IsInRaid() and not raidDb.raidUseGroups
    
    if DF.pendingLayoutUpdate then
        DF.pendingLayoutUpdate = nil
        DF:UpdatePartyHeaderLayout()
        
        -- For flat raid layouts, ONLY call ApplyFlatLayoutAttributes
        -- Don't call UpdateRaidLayout or ApplyHeaderSettings - they trigger too many things
        -- Delay by one frame to let other combat-end processing complete first
        if isFlatRaid then
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    DF:ApplyFlatLayoutAttributes()
                end
            end)
        else
            DF:UpdateRaidHeaderLayout()
        end
    end
    
    -- Process pending flat layout refresh (queued during combat roster changes)
    if DF.pendingFlatLayoutRefresh then
        DF.pendingFlatLayoutRefresh = false
        -- Clear FlatRaidFrames pending flags - SetEnabled(true) handles everything
        -- This prevents a duplicate UpdateNameList from FlatRaidFrames' own REGEN handler
        if DF.FlatRaidFrames then
            DF.FlatRaidFrames.pendingNameListUpdate = false
            DF.FlatRaidFrames.pendingLayoutUpdate = false
        end
        if isFlatRaid then
            -- UpdateHeaderVisibility → SetEnabled(true) handles layout + nameList rebuild
            DF:UpdateHeaderVisibility()
        else
            -- Mode changed during combat (was flat raid, now not) - update visibility
            DF:UpdateHeaderVisibility()
        end
    end
    
    -- FIX: Safety-net rebuild after all combat-queued layout/visibility changes.
    -- Ensures unitFrameMap is consistent before the next UNIT_HEALTH event.
    DF:RebuildUnitFrameMap()
end)

-- ============================================================
-- MAIN INITIALIZATION
-- Call this to set up the header-based frame system
-- ============================================================

-- ============================================================
-- SORTING (Phase 2)
-- Configure sort method and grouping for headers
-- ============================================================

-- Sort methods: "INDEX", "NAME", "NAMELIST"
-- Group by: nil (no grouping), "GROUP", "CLASS", "ROLE", "ASSIGNEDROLE"
--   ASSIGNEDROLE = dungeon finder / manually assigned roles (use this!)
--   ROLE = older system (deprecated)
-- Grouping order examples:
--   Role: "TANK,HEALER,DAMAGER" or "HEALER,TANK,DAMAGER"
--   Class: "WARRIOR,PALADIN,DEATHKNIGHT,..." 
--   Group: "1,2,3,4,5,6,7,8"

function DF:SetPartySorting(sortMethod, groupBy, groupingOrder)
    if InCombatLockdown() then
        DF:Err("Cannot change sorting in combat")
        return
    end
    
    -- Player header doesn't need sorting (only 1 frame)
    
    -- Party header
    if DF.partyHeader then
        -- IMPORTANT: Set groupingOrder BEFORE groupBy!
        -- When groupBy is set, the header immediately tries to use groupingOrder
        -- Use empty string "" to actually clear attributes (nil doesn't work!)
        DF.partyHeader:SetAttribute("groupingOrder", groupingOrder or "")
        DF.partyHeader:SetAttribute("groupBy", groupBy or "")
        if sortMethod then
            DF.partyHeader:SetAttribute("sortMethod", sortMethod)
        end
        -- Written raw (this function predates SetHeaderAttribute), so drop the
        -- cache -- otherwise it keeps describing the values this call just
        -- replaced and silently skips the next matching write.
        ClearHeaderAttributeCache(DF.partyHeader)

        -- Force relayout
        for i = 1, 5 do
            local child = DF.partyHeader:GetAttribute("child" .. i)
            if child then
                child:ClearAllPoints()
            end
        end
        DF.partyHeader:SetAttribute("unitsPerColumn", 5)
        
        headerDebug("Party sorting:", sortMethod or "nil", groupBy or "nil", groupingOrder or "nil")
    end
end

-- Apply party sorting based on selfPosition setting
-- Uses nameList for FIRST/LAST or any advanced sorting options
-- Uses native role sorting only for basic SORTED mode
function DF:ApplyPartyGroupSorting()
    if InCombatLockdown() then return end
    if not DF.partyHeader then return end

    -- Skip in arena: party header is hidden (arena uses arenaHeader with raid units).
    -- The Hide/Show re-evaluate trick below would re-show the party header,
    -- causing it to overlap with the arena header in the same container.
    if DF.GetContentType and DF:GetContentType() == "arena" then return end

    -- FrameSort integration: yield sorting to FrameSort when active
    if DF:IsFrameSortActive() then return end

    local db = DF:GetDB()
    local selfPosition = db.sortSelfPosition or "FIRST"
    local sortEnabled = db.sortEnabled
    local separateMeleeRanged = db.sortSeparateMeleeRanged
    local sortByClass = db.sortByClass
    local sortAlphabetical = db.sortAlphabetical
    
    -- Determine if we need nameList (any advanced option or FIRST/LAST)
    local needsNameList = (selfPosition ~= "SORTED") or separateMeleeRanged or sortByClass or sortAlphabetical

    -- #78: excluding pinned-and-hidden members can ONLY be done via the nameList
    -- (the native-role / INDEX modes below assign every unit and can't drop one),
    -- so force the nameList path whenever a "Hide from Main Frames" set is active.
    -- When sorting is off, BuildSortedNameList emits the kept members in index
    -- order (not role order), so hiding never silently turns sorting on.
    local hasHidden = DF.GetPinnedHiddenNames and DF:GetPinnedHiddenNames() ~= nil

    if DF:DebugActive("HEADERS") then
        headerDebug("ApplyPartyGroupSorting:")
        DF:Debug("HEADERS", "  selfPosition= %s sortEnabled= %s hasHidden= %s", selfPosition, tostring(sortEnabled), tostring(hasHidden))
        DF:Debug("HEADERS", "  needsNameList= %s", tostring(needsNameList))
    end

    if not needsNameList and sortEnabled and not hasHidden then
        -- Simple SORTED mode with no advanced options: Use native role sorting (works in combat)
        SetHeaderAttribute(DF.partyHeader, "nameList", nil)
        
        -- Get role order from settings
        local roleOrder = db.sortRoleOrder or {"TANK", "HEALER", "MELEE", "RANGED"}
        local groupingOrder = {}
        for _, role in ipairs(roleOrder) do
            if role == "MELEE" or role == "RANGED" then
                if not tContains(groupingOrder, "DAMAGER") then
                    table.insert(groupingOrder, "DAMAGER")
                end
            else
                table.insert(groupingOrder, role)
            end
        end
        local roleOrderString = table.concat(groupingOrder, ",")
        
        SetHeaderAttribute(DF.partyHeader, "groupingOrder", roleOrderString)
        SetHeaderAttribute(DF.partyHeader, "groupBy", "ASSIGNEDROLE")
        SetHeaderAttribute(DF.partyHeader, "sortMethod", "NAME")
        
        headerDebug("  Using native role sorting (combat-safe)")
    elseif not sortEnabled and not hasHidden then
        -- Sorting disabled entirely - clear ALL sorting attributes
        -- CRITICAL: Must clear all attributes to prevent stale nameList/groupBy from persisting
        SetHeaderAttribute(DF.partyHeader, "nameList", nil)
        SetHeaderAttribute(DF.partyHeader, "groupBy", nil)
        SetHeaderAttribute(DF.partyHeader, "groupingOrder", nil)
        SetHeaderAttribute(DF.partyHeader, "groupFilter", nil)
        SetHeaderAttribute(DF.partyHeader, "roleFilter", nil)
        SetHeaderAttribute(DF.partyHeader, "strictFiltering", nil)
        SetHeaderAttribute(DF.partyHeader, "sortMethod", "INDEX")
        
        -- Force header to re-evaluate by hiding and showing
        -- This is required for SecureGroupHeaderTemplate to rebuild frames
        DF.partyHeader:Hide()
        DF.partyHeader:Show()
        
        headerDebug("  Sorting disabled, using INDEX (cleared all attributes)")
    else
        -- Use nameList for FIRST/LAST or any advanced sorting options
        local nameList = DF:BuildPartyNameList(selfPosition)
        
        -- Clear all filtering/grouping attributes that could interfere with nameList
        SetHeaderAttribute(DF.partyHeader, "groupBy", nil)
        SetHeaderAttribute(DF.partyHeader, "groupingOrder", nil)
        SetHeaderAttribute(DF.partyHeader, "groupFilter", nil)
        SetHeaderAttribute(DF.partyHeader, "roleFilter", nil)
        SetHeaderAttribute(DF.partyHeader, "strictFiltering", nil)
        
        -- Set nameList and sortMethod (ONLY if changed!)
        SetHeaderAttribute(DF.partyHeader, "nameList", nameList)
        SetHeaderAttribute(DF.partyHeader, "sortMethod", "NAMELIST")
        
        -- Force header to re-evaluate by hiding and showing
        -- This is required for SecureGroupHeaderTemplate to re-sort children
        DF.partyHeader:Hide()
        DF.partyHeader:Show()
        
        headerDebug("  Using nameList mode:", nameList)
    end
    
    -- NOTE: Frame refresh is handled by OnAttributeChanged when units swap
    -- No need for explicit refresh here - it causes flicker due to double update

    -- OnFramesSorted callback is fired from the child OnAttributeChanged
    -- handler (see CreatePartyFrame), which catches real unit-attribute
    -- reassignments in both combat and non-combat paths.
end

-- ============================================================
-- ARENA HEADER SORTING
-- Arena uses party settings but operates on raid unit IDs (raid1-5)
-- ============================================================

-- Build a sorted nameList for arena frames
-- Same approach as BuildPartyNameList but iterates raid1-5 (arena uses raid units)
-- Names come from GetRaidRosterInfo, NOT UnitName: for raid-kind units,
-- SecureGroupHeaderTemplate matches nameList tokens against GetRaidRosterInfo
-- names (already realm-qualified for cross-realm), and the roster usually
-- knows a late-joiner's name BEFORE their player object loads (UnitName
-- returns UNKNOWNOBJECT while they're still loading in — typical for
-- non-rated arenas where players trickle into the prep room). Sourcing from
-- the roster therefore yields a complete, matchable list immediately in the
-- common late-join case, where UnitName would have forced the INDEX fallback.
-- Returns nameList, complete. `complete` is false when a member EXISTS but
-- the roster hasn't served their name yet. An unresolved member is OMITTED
-- rather than added as "Unknown": a literal "Unknown" entry never matches
-- their real name, so the header would hide them for the whole round.
function DF:BuildArenaNameList(selfPosition)
    local members = {}
    local complete = true

    for i = 1, 5 do
        local unit = "raid" .. i
        if UnitExists(unit) then
            -- In arena, raid roster index i corresponds to unit "raid"..i
            -- (same mapping SecureGroupHeaders.lua uses for RAID-kind units).
            local name = GetRaidRosterInfo(i)
            -- issecretvalue first: comparing/testing a secret value crashes.
            if issecretvalue(name) or not name or name == UNKNOWNOBJECT then
                complete = false
            else
                table.insert(members, {
                    unit = unit,
                    name = name,
                    isPlayer = UnitIsUnit(unit, "player")
                })
            end
        end
    end

    -- Use the unified sorting function (handles role, class, alphabetical,
    -- melee/ranged separation, realm stripping, and self-positioning)
    return DF:BuildSortedNameList(members, DF:GetDB(), selfPosition, true), complete
end

-- Apply sorting to arena header (uses party settings)
function DF:ApplyArenaHeaderSorting()
    if InCombatLockdown() then
        -- Don't drop the request (a round's combat lasts minutes — e.g. a
        -- post-reload apply mid-round): replay on the combat-end queue.
        DF.pendingSortingUpdate = true
        return
    end
    if not DF.arenaHeader then return end

    -- FrameSort integration: yield sorting entirely to FrameSort when active.
    -- Clear any stale nameList from the previous Solo Shuffle round so
    -- SecureGroupHeaderTemplate stops filtering by an old teammate's name and
    -- shows all current units in INDEX order immediately.
    -- Do NOT call RequestSort() here — that would fire synchronously in the same
    -- event frame as GROUP_ROSTER_UPDATE, before WoW has finished assigning units
    -- to raid slots. The stale data would produce the wrong nameList, which then
    -- persists for the whole round once combat starts.
    -- FrameSort's Blizzard provider already schedules a sort on every
    -- GROUP_ROSTER_UPDATE; it calls our Sort() via RequestSelfManagedProvidersSort()
    -- on the next OnUpdate frame, by which time the unit API is fully settled.
    if DF:IsFrameSortActive() then
        DF.arenaHeader:SetAttribute("nameList", nil)
        DF.arenaHeader:SetAttribute("sortMethod", "INDEX")
        DF.arenaHeader:SetAttribute("groupBy", nil)
        DF.arenaHeader:SetAttribute("groupingOrder", nil)
        DF.arenaHeader:SetAttribute("groupFilter", nil)
        DF.arenaHeader:SetAttribute("roleFilter", nil)
        DF.arenaHeader:SetAttribute("strictFiltering", nil)
        return
    end

    local db = DF:GetDB()
    local selfPosition = db.sortSelfPosition or "FIRST"
    local sortEnabled = db.sortEnabled
    local separateMeleeRanged = db.sortSeparateMeleeRanged
    local sortByClass = db.sortByClass
    local sortAlphabetical = db.sortAlphabetical
    
    -- Determine if we need nameList (any advanced option or FIRST/LAST)
    local needsNameList = (selfPosition ~= "SORTED") or separateMeleeRanged or sortByClass or sortAlphabetical
    
    if DF:DebugActive("HEADERS") then
        headerDebug("ApplyArenaHeaderSorting:")
        DF:Debug("HEADERS", "  selfPosition= %s sortEnabled= %s", selfPosition, tostring(sortEnabled))
        DF:Debug("HEADERS", "  needsNameList= %s", tostring(needsNameList))
    end
    
    if not needsNameList and sortEnabled then
        -- Simple SORTED mode with no advanced options: Use native role sorting
        DF.arenaHeader:SetAttribute("nameList", nil)
        
        -- Get role order from settings
        local roleOrder = db.sortRoleOrder or {"TANK", "HEALER", "MELEE", "RANGED"}
        local groupingOrder = {}
        for _, role in ipairs(roleOrder) do
            if role == "MELEE" or role == "RANGED" then
                if not tContains(groupingOrder, "DAMAGER") then
                    table.insert(groupingOrder, "DAMAGER")
                end
            else
                table.insert(groupingOrder, role)
            end
        end
        local roleOrderString = table.concat(groupingOrder, ",")
        
        DF.arenaHeader:SetAttribute("groupingOrder", roleOrderString)
        DF.arenaHeader:SetAttribute("groupBy", "ASSIGNEDROLE")
        DF.arenaHeader:SetAttribute("sortMethod", "NAME")
        SetArenaNameListIncomplete(false)  -- not a filtering mode

        headerDebug("  Arena using native role sorting")
    elseif not sortEnabled then
        -- Sorting disabled entirely - clear ALL sorting attributes
        -- CRITICAL: Must clear all attributes to prevent stale nameList/groupBy from persisting
        DF.arenaHeader:SetAttribute("nameList", nil)
        DF.arenaHeader:SetAttribute("groupBy", nil)
        DF.arenaHeader:SetAttribute("groupingOrder", nil)
        DF.arenaHeader:SetAttribute("groupFilter", nil)
        DF.arenaHeader:SetAttribute("roleFilter", nil)
        DF.arenaHeader:SetAttribute("strictFiltering", nil)
        DF.arenaHeader:SetAttribute("sortMethod", "INDEX")
        SetArenaNameListIncomplete(false)  -- not a filtering mode

        -- Force header to re-evaluate by hiding and showing
        DF.arenaHeader:Hide()
        DF.arenaHeader:Show()

        headerDebug("  Arena sorting disabled, using INDEX (cleared all attributes)")
    else
        -- Use nameList for FIRST/LAST or any advanced sorting options
        local nameList, complete = DF:BuildArenaNameList(selfPosition)

        -- Clear all filtering/grouping attributes
        DF.arenaHeader:SetAttribute("groupBy", nil)
        DF.arenaHeader:SetAttribute("groupingOrder", nil)
        DF.arenaHeader:SetAttribute("groupFilter", nil)
        DF.arenaHeader:SetAttribute("roleFilter", nil)
        DF.arenaHeader:SetAttribute("strictFiltering", nil)

        if not complete then
            -- Someone exists whose name hasn't resolved yet. A filtering
            -- nameList would HIDE them — and nothing would fix it for the
            -- whole round (name resolution fires no roster event, and combat
            -- blocks attribute writes once the gates open). Show EVERYONE in
            -- INDEX order for now and re-sort once the names resolve.
            DF.arenaHeader:SetAttribute("nameList", nil)
            DF.arenaHeader:SetAttribute("sortMethod", "INDEX")
            SetArenaNameListIncomplete(true)
            ScheduleArenaSortRetry()
            headerDebug("  Arena nameList INCOMPLETE (unresolved name) — using INDEX + retry")
        else
            -- Set nameList and sortMethod
            DF.arenaHeader:SetAttribute("nameList", nameList)
            DF.arenaHeader:SetAttribute("sortMethod", "NAMELIST")
            SetArenaNameListIncomplete(false)
            headerDebug("  Arena using nameList mode:", nameList)
        end

        -- Force header to re-evaluate
        DF.arenaHeader:Hide()
        DF.arenaHeader:Show()
    end

    -- OnFramesSorted callback is fired from child OnAttributeChanged.
end

-- (Removed) DF:RefreshPartyFrames -- no callers; see the note on the group-frame
-- twin above.

function DF:SetRaidSorting(sortMethod, groupBy, groupingOrder)
    if InCombatLockdown() then
        DF:Err("Cannot change sorting in combat")
        return
    end
    
    -- Combined header
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        -- IMPORTANT: Set groupingOrder BEFORE groupBy!
        -- Use empty string "" to actually clear attributes (nil doesn't work!)
        DF.FlatRaidFrames.header:SetAttribute("groupingOrder", groupingOrder or "")
        DF.FlatRaidFrames.header:SetAttribute("groupBy", groupBy or "")
        if sortMethod then
            DF.FlatRaidFrames.header:SetAttribute("sortMethod", sortMethod)
        end
        
        -- Force relayout
        for i = 1, 40 do
            local child = DF.FlatRaidFrames.header:GetAttribute("child" .. i)
            if child then
                child:ClearAllPoints()
            end
        end
        local upc = DF.FlatRaidFrames.header:GetAttribute("unitsPerColumn") or 5
        DF.FlatRaidFrames.header:SetAttribute("unitsPerColumn", upc)
    end
    
    -- Separated headers (each group)
    if DF.raidSeparatedHeaders then
        for i = 1, 8 do
            local header = DF.raidSeparatedHeaders[i]
            if header then
                -- Use empty string "" to actually clear attributes
                header:SetAttribute("groupingOrder", groupingOrder or "")
                header:SetAttribute("groupBy", groupBy or "")
                if sortMethod then
                    header:SetAttribute("sortMethod", sortMethod)
                end
                
                -- Force relayout
                for j = 1, 5 do
                    local child = header:GetAttribute("child" .. j)
                    if child then
                        child:ClearAllPoints()
                    end
                end
                header:SetAttribute("unitsPerColumn", 5)
            end
        end
    end
    
    headerDebug("Raid sorting:", sortMethod or "nil", groupBy or "nil", groupingOrder or "nil")
end

-- Convenience functions for common sort configurations
function DF:SetSortByRole()
    -- Use ASSIGNEDROLE (dungeon finder roles) not ROLE (older system)
    DF:SetPartySorting("NAME", "ASSIGNEDROLE", "TANK,HEALER,DAMAGER")
    DF:SetRaidSorting("NAME", "ASSIGNEDROLE", "TANK,HEALER,DAMAGER")
    DF:Say("Sorting by ROLE (Tank > Healer > DPS)")
end

function DF:SetSortByName()
    DF:SetPartySorting("NAME", nil, nil)
    DF:SetRaidSorting("NAME", nil, nil)
    DF:Say("Sorting by NAME")
end

function DF:SetSortByIndex()
    DF:SetPartySorting("INDEX", nil, nil)
    DF:SetRaidSorting("INDEX", nil, nil)
    DF:Say("Sorting by INDEX (group order)")
end

function DF:SetSortByGroup()
    -- Only applies to raid combined header
    DF:SetRaidSorting("INDEX", "GROUP", "1,2,3,4,5,6,7,8")
    DF:Say("Raid sorting by GROUP")
end

-- ============================================================
-- ORIENTATION (Phase 2)
-- Configure horizontal vs vertical growth
-- ============================================================

function DF:SetPartyOrientation(horizontal, growFrom, selfPosition)
    if InCombatLockdown() then
        DF:Err("Cannot change orientation in combat")
        return
    end
    
    local db = DF:GetDB()
    local spacing = db.frameSpacing or 2
    local frameWidth = db.frameWidth or 120
    local frameHeight = db.frameHeight or 50
    
    -- Use provided values or read from settings
    growFrom = growFrom or db.growthAnchor or "START"
    selfPosition = selfPosition or db.sortSelfPosition or "FIRST"
    
    -- Calculate container size for 5 frames (player + 4 party)
    local maxFrameCount = 5
    local maxWidth = maxFrameCount * (frameWidth + spacing) - spacing
    local maxHeight = maxFrameCount * (frameHeight + spacing) - spacing
    
    -- Update DF.container size (the mover)
    if DF.container then
        if horizontal then
            DF.container:SetSize(maxWidth, frameHeight)
        else
            DF.container:SetSize(frameWidth, maxHeight)
        end
    end
    
    -- Determine anchor points and offsets based on growFrom
    local headerPoint, containerPoint, childPoint, xOff, yOff
    
    if horizontal then
        if growFrom == "END" then
            headerPoint = "RIGHT"
            containerPoint = "RIGHT"
            childPoint = "RIGHT"
            xOff = -spacing
            yOff = 0
        else
            headerPoint = "LEFT"
            containerPoint = "LEFT"
            childPoint = "LEFT"
            xOff = spacing
            yOff = 0
        end
    else
        if growFrom == "END" then
            headerPoint = "BOTTOM"
            containerPoint = "BOTTOM"
            childPoint = "BOTTOM"
            xOff = 0
            yOff = spacing
        else
            headerPoint = "TOP"
            containerPoint = "TOP"
            childPoint = "TOP"
            xOff = 0
            yOff = -spacing
        end
    end
    
    headerDebug("SetPartyOrientation: horizontal=", horizontal, "growFrom=", growFrom, "selfPosition=", selfPosition)
    
    -- Configure partyHeader (single header for player + party)
    if DF.partyHeader then
        DF.partyHeader:SetAttribute("showPlayer", not db.hidePlayerFrame)
        DF.partyHeader:SetAttribute("point", childPoint)
        DF.partyHeader:SetAttribute("xOffset", xOff)
        DF.partyHeader:SetAttribute("yOffset", yOff)
        
        if growFrom == "END" then
            DF.partyHeader:SetAttribute("sortDir", "DESC")
        else
            DF.partyHeader:SetAttribute("sortDir", "ASC")
        end
        
        -- Anchor header to container
        DF.partyHeader:ClearAllPoints()
        if growFrom == "CENTER" then
            -- For CENTER, set fallback position - secure code will adjust
            if horizontal then
                DF.partyHeader:SetPoint("LEFT", DF.partyContainer, "LEFT", 0, 0)
            else
                DF.partyHeader:SetPoint("TOP", DF.partyContainer, "TOP", 0, 0)
            end
        else
            -- START or END - anchor to container edge
            DF.partyHeader:SetPoint(headerPoint, DF.partyContainer, containerPoint, 0, 0)
        end
        
        -- Clear child points and trigger relayout
        for i = 1, 5 do
            local child = DF.partyHeader:GetAttribute("child" .. i)
            if child then
                child:ClearAllPoints()
            end
        end
        DF.partyHeader:SetAttribute("unitsPerColumn", 5)
    end
    
    -- Configure arenaHeader (same layout as party, but uses raid units)
    if DF.arenaHeader then
        DF.arenaHeader:SetAttribute("showPlayer", true)
        DF.arenaHeader:SetAttribute("point", childPoint)
        DF.arenaHeader:SetAttribute("xOffset", xOff)
        DF.arenaHeader:SetAttribute("yOffset", yOff)
        
        if growFrom == "END" then
            DF.arenaHeader:SetAttribute("sortDir", "DESC")
        else
            DF.arenaHeader:SetAttribute("sortDir", "ASC")
        end
        
        -- Anchor header to container (same as party)
        DF.arenaHeader:ClearAllPoints()
        if growFrom == "CENTER" then
            if horizontal then
                DF.arenaHeader:SetPoint("LEFT", DF.partyContainer, "LEFT", 0, 0)
            else
                DF.arenaHeader:SetPoint("TOP", DF.partyContainer, "TOP", 0, 0)
            end
        else
            DF.arenaHeader:SetPoint(headerPoint, DF.partyContainer, containerPoint, 0, 0)
        end
        
        -- Clear child points and trigger relayout
        for i = 1, 5 do
            local child = DF.arenaHeader:GetAttribute("child" .. i)
            if child then
                child:ClearAllPoints()
            end
        end
        DF.arenaHeader:SetAttribute("unitsPerColumn", 5)
    end
    
    -- Apply sorting (nameList for FIRST/LAST, role sorting for SORTED)
    DF:ApplyPartyGroupSorting()
    
    -- Enable/disable secure center positioning
    if growFrom == "CENTER" then
        DF:SetGrowFromCenter(true, selfPosition)
    else
        DF:SetGrowFromCenter(false, selfPosition)
    end
    
    headerDebug("Party orientation:", horizontal and "HORIZONTAL" or "VERTICAL", "growFrom:", growFrom, "selfPosition:", selfPosition)
end

function DF:SetRaidOrientation(horizontal, growFrom)
    if InCombatLockdown() then
        DF:Err("Cannot change orientation in combat")
        return
    end
    
    if DF:DebugActive("FLATRAID") then
        DF:Debug("FLATRAID", "SetRaidOrientation: horizontal=%s growFrom=%s, called from\n%s",
            tostring(horizontal), tostring(growFrom), debugstack(2, 10, 0) or "unknown")
    end
    
    local db = DF:GetRaidDB()
    
    -- Default growFrom for combined header (if not provided)
    -- ☠ Reads raidFlatFrameAnchor, NOT raidFlatPlayerAnchor. The latter was a second
    -- key for the same concept that no control has ever written in this repo's history
    -- (only the defaults table seeded it, to "CENTER"), so every reader here was pinned
    -- to a constant while "Players Grow From" wrote raidFlatFrameAnchor and moved only
    -- the geometry. Setting End flipped the header's anchor corner but left sortDir ASC.
    growFrom = growFrom or db.raidFlatFrameAnchor or "START"
    
    -- Combined header (flat layout) - just set sortDir, PositionRaidHeaders handles the rest
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        local combinedSortDir = (growFrom == "END") and "DESC" or "ASC"
        DF.FlatRaidFrames.header:SetAttribute("sortDir", combinedSortDir)
        
        DF:Debug("FLATRAID", "SetRaidOrientation:   -> set sortDir=%s", combinedSortDir)
    end

    DF:Debug("FLATRAID", "SetRaidOrientation:   -> calling PositionRaidHeaders")

    -- PositionRaidHeaders handles both flat (via ApplyFlatLayoutAttributes) 
    -- and group-based (via UpdateRaidPositionAttributes) layouts
    DF:PositionRaidHeaders()

    headerDebug("Raid orientation:", horizontal and "HORIZONTAL" or "VERTICAL", "growFrom:", growFrom)
end

-- ============================================================
-- PHASE 3: SECURE POSITIONING
-- Grow-from-center and self-first/last positioning
-- Uses SecureHandlerWrapScript pattern from SecureSort.lua
-- ============================================================

-- Set up secure positioning on a header.
--
-- ☠ THE `isPlayerHeader` PARAMETER IS GONE, and with it the whole player-header snippet.
-- Both call sites passed `false`: the separate player header was folded into partyHeader
-- ("All modes now use partyHeader only"), so that branch had not been installed on any
-- frame in a very long time.
--
-- It is worth saying what it cost, because it is still sitting in the audit doc as V6.
-- That dead snippet was the ONLY consumer of the `growFromCenter` attribute, and it
-- opened `if not growFromCenter then return end` against a db key nothing defines or
-- writes. Reading it in isolation says, convincingly, that CENTER growth has never run
-- for anyone -- and CENTER is the shipped default, so that reads as a shipping bug.
-- It is not. The live snippet below gates on `selfCentering`, which DF:SetGrowFromCenter
-- writes correctly from `growthAnchor == "CENTER"`. Centering works and always did.
--
-- Deleted rather than kept "just in case" for exactly that reason: an unreachable branch
-- that reads a never-written key is not inert, it is a trap that costs the next reader
-- an afternoon and can talk them into "fixing" a working layout path.
function DF:SetupSecurePositioning(header)
    if not header then return end

    -- Store reference to container for secure code
    SecureHandlerSetFrameRef(header, "container", DF.partyContainer)

    -- Set max children attribute for counting
    header:SetAttribute("maxChildren", 5)

    -- The positioning snippet - runs when triggerposition changes. Handles centering.
    -- All modes use partyHeader only (no separate playerHeader), so there is exactly
    -- one snippet. childCount is set by the OnShow/OnHide hooks on the children.
    local positionSnippet = [[
            local header = self
            local selfCentering = header:GetAttribute("selfCentering")
            
            -- Only do positioning if selfCentering is enabled
            if not selfCentering then
                return
            end
            
            local container = self:GetFrameRef("container")
            if not container then return end
            
            local horizontal = header:GetAttribute("horizontal")
            local frameWidth = header:GetAttribute("frameWidth") or 120
            local frameHeight = header:GetAttribute("frameHeight") or 50
            local spacing = header:GetAttribute("spacing") or 2
            local extraFrameCount = header:GetAttribute("extraFrameCount") or 0
            
            -- Read the pre-computed child count (set by OnShow/OnHide hooks)
            local childCount = header:GetAttribute("childCount") or 0
            
            -- Total frames to consider for centering
            local totalFrameCount = childCount + extraFrameCount
            
            -- Store debug info
            header:SetAttribute("debugChildCount", childCount)
            header:SetAttribute("debugExtraCount", extraFrameCount)
            header:SetAttribute("debugTotalCount", totalFrameCount)
            
            -- Don't reposition if no frames
            if totalFrameCount < 1 then
                header:SetAttribute("debugSkipped", "no frames")
                return
            end
            
            header:ClearAllPoints()
            
            -- Calculate total size for all frames
            local totalSize
            if horizontal then
                totalSize = totalFrameCount * frameWidth + (totalFrameCount - 1) * spacing
            else
                totalSize = totalFrameCount * frameHeight + (totalFrameCount - 1) * spacing
            end
            
            header:SetAttribute("debugTotalSize", totalSize)
            header:SetAttribute("debugSkipped", "none")
            
            -- Position header so children are centered
            -- Children grow from header's anchor point (LEFT for horizontal, TOP for vertical)
            -- So we position that anchor point at -totalSize/2 from container center
            if horizontal then
                local offsetX = -totalSize / 2
                header:SetAttribute("debugOffsetX", offsetX)
                header:SetPoint("LEFT", container, "CENTER", offsetX, 0)
            else
                local offsetY = totalSize / 2
                header:SetAttribute("debugOffsetY", offsetY)
                header:SetPoint("TOP", container, "CENTER", 0, offsetY)
            end
    ]]

    -- Use SecureHandlerWrapScript to handle attribute changes
    -- Note: 'name' and 'value' are implicitly available in OnAttributeChanged
    SecureHandlerWrapScript(header, "OnAttributeChanged", header, [[
        if name == "triggerposition" then
            ]] .. positionSnippet .. [[
        end
    ]])
    
    if DF:DebugActive("HEADERS") then
        headerDebug("Set up secure positioning for:", header:GetName())
    end
end

-- Trigger secure repositioning (can be called anytime, works in combat)
function DF:TriggerSecurePosition(header)
    if not header then return end
    -- Toggle attribute to trigger OnAttributeChanged
    local current = header:GetAttribute("triggerposition") or 0
    header:SetAttribute("triggerposition", current + 1)
end

-- Apply grow-from-center setting (call out of combat to set up)
-- selfPosition: "FIRST", "LAST", or "SORTED"
function DF:SetGrowFromCenter(enabled, selfPosition)
    if InCombatLockdown() then
        DF:Err("Cannot change grow-from-center in combat")
        return
    end
    
    local db = DF:GetDB()
    local horizontal = (db.growDirection == "HORIZONTAL")
    local spacing = db.frameSpacing or 2
    local frameWidth = db.frameWidth or 120
    local frameHeight = db.frameHeight or 50
    selfPosition = selfPosition or "FIRST"
    
    -- Count party children (visible frames in partyHeader - now includes player)
    local partyChildCount = 0
    if DF.partyHeader then
        for i = 1, 5 do
            local child = DF.partyHeader:GetAttribute("child" .. i)
            if child and child:IsShown() then
                partyChildCount = partyChildCount + 1
            end
        end
    end
    
    -- Count arena children
    local arenaChildCount = 0
    if DF.arenaHeader then
        for i = 1, 5 do
            local child = DF.arenaHeader:GetAttribute("child" .. i)
            if child and child:IsShown() then
                arenaChildCount = arenaChildCount + 1
            end
        end
    end
    
    headerDebug("SetGrowFromCenter:", enabled and "ENABLED" or "DISABLED", "selfPosition:", selfPosition, "partyChildCount:", partyChildCount, "arenaChildCount:", arenaChildCount)
    
    -- With single partyHeader, all modes use the same centering logic
    -- partyHeader contains all frames (player + party) sorted by nameList
    if DF.partyHeader then
        DF.partyHeader:SetAttribute("selfCentering", enabled)
        DF.partyHeader:SetAttribute("extraFrameCount", 0)  -- No separate player header
        DF.partyHeader:SetAttribute("childCount", partyChildCount)
        DF.partyHeader:SetAttribute("horizontal", horizontal)
        DF.partyHeader:SetAttribute("frameWidth", frameWidth)
        DF.partyHeader:SetAttribute("frameHeight", frameHeight)
        DF.partyHeader:SetAttribute("spacing", spacing)
    end
    
    -- Arena header uses same centering logic as party
    if DF.arenaHeader then
        DF.arenaHeader:SetAttribute("selfCentering", enabled)
        DF.arenaHeader:SetAttribute("extraFrameCount", 0)
        DF.arenaHeader:SetAttribute("childCount", arenaChildCount)
        DF.arenaHeader:SetAttribute("horizontal", horizontal)
        DF.arenaHeader:SetAttribute("frameWidth", frameWidth)
        DF.arenaHeader:SetAttribute("frameHeight", frameHeight)
        DF.arenaHeader:SetAttribute("spacing", spacing)
    end
    
    -- Trigger repositioning
    if enabled then
        DF:TriggerSecurePosition(DF.partyHeader)
        DF:TriggerSecurePosition(DF.arenaHeader)
    end
    
    headerDebug("Secure position triggered for center mode")
end

-- Initialize secure positioning on all headers
function DF:InitSecurePositioning()
    if InCombatLockdown() then
        DF:Err("Cannot init secure positioning in combat")
        return
    end
    
    -- Set up party header for centering
    if DF.partyHeader then
        DF:SetupSecurePositioning(DF.partyHeader)
        
        -- When party header's child attributes change, count and trigger repositioning
        -- NOTE: SecureGroupHeaderTemplate stores children as "frameref-childN"
        SecureHandlerWrapScript(DF.partyHeader, "OnAttributeChanged", DF.partyHeader, [[
            if name and name:match("^child%d+$") then
                -- Count our own visible children using frameref-child prefix
                local count = 0
                local c1 = self:GetAttribute("frameref-child1")
                local c2 = self:GetAttribute("frameref-child2")
                local c3 = self:GetAttribute("frameref-child3")
                local c4 = self:GetAttribute("frameref-child4")
                local c5 = self:GetAttribute("frameref-child5")
                if c1 and c1:IsShown() then count = count + 1 end
                if c2 and c2:IsShown() then count = count + 1 end
                if c3 and c3:IsShown() then count = count + 1 end
                if c4 and c4:IsShown() then count = count + 1 end
                if c5 and c5:IsShown() then count = count + 1 end
                
                -- Set our own childCount
                self:SetAttribute("childCount", count)
                
                -- Trigger reposition
                local v = self:GetAttribute("triggerposition") or 0
                self:SetAttribute("triggerposition", v + 1)
            end
        ]])
    end
    
    -- Set up arena header for centering (same as party)
    if DF.arenaHeader then
        DF:SetupSecurePositioning(DF.arenaHeader)
        
        SecureHandlerWrapScript(DF.arenaHeader, "OnAttributeChanged", DF.arenaHeader, [[
            if name and name:match("^child%d+$") then
                local count = 0
                local c1 = self:GetAttribute("frameref-child1")
                local c2 = self:GetAttribute("frameref-child2")
                local c3 = self:GetAttribute("frameref-child3")
                local c4 = self:GetAttribute("frameref-child4")
                local c5 = self:GetAttribute("frameref-child5")
                if c1 and c1:IsShown() then count = count + 1 end
                if c2 and c2:IsShown() then count = count + 1 end
                if c3 and c3:IsShown() then count = count + 1 end
                if c4 and c4:IsShown() then count = count + 1 end
                if c5 and c5:IsShown() then count = count + 1 end
                
                self:SetAttribute("childCount", count)
                
                local v = self:GetAttribute("triggerposition") or 0
                self:SetAttribute("triggerposition", v + 1)
            end
        ]])
    end
    
    -- Hook party children's OnShow/OnHide to trigger counting
    DF:HookPartyChildrenForRepositioning()
    
    -- Hook arena children's OnShow/OnHide to trigger counting
    DF:HookArenaChildrenForRepositioning()
    
    -- ☠ Was DF:Say — an unconditional chat print on EVERY login, for every user, in
    -- English only. It also carried no information: it fires at the end of the function
    -- unconditionally, so it says "this ran", which is true every time. There is no
    -- failure path that prints the opposite. Routed to the debug console, which is a
    -- toggle, per the rule: no forced text without the user turning something on.
    DF:Debug("HEADERS", "Secure positioning initialized")
end

-- Hook party header children to trigger repositioning on show/hide
function DF:HookPartyChildrenForRepositioning()
    if InCombatLockdown() then return end
    if not DF.partyHeader then return end
    
    -- Track which children we've hooked to avoid double-hooking same child
    DF.hookedChildren = DF.hookedChildren or {}
    
    -- Hook each child's OnShow and OnHide
    for i = 1, 5 do
        local child = DF.partyHeader:GetAttribute("child" .. i)
        if child and not DF.hookedChildren[child] then
            DF.hookedChildren[child] = true
            
            SecureHandlerSetFrameRef(child, "partyHeader", DF.partyHeader)
            
            -- On show - count all children and trigger repositioning
            SecureHandlerWrapScript(child, "OnShow", child, [[
                local partyHeader = self:GetFrameRef("partyHeader")
                if partyHeader then
                    -- Count visible children using frameref-child prefix
                    local count = 0
                    local c1 = partyHeader:GetAttribute("frameref-child1")
                    local c2 = partyHeader:GetAttribute("frameref-child2")
                    local c3 = partyHeader:GetAttribute("frameref-child3")
                    local c4 = partyHeader:GetAttribute("frameref-child4")
                    local c5 = partyHeader:GetAttribute("frameref-child5")
                    if c1 and c1:IsShown() then count = count + 1 end
                    if c2 and c2:IsShown() then count = count + 1 end
                    if c3 and c3:IsShown() then count = count + 1 end
                    if c4 and c4:IsShown() then count = count + 1 end
                    if c5 and c5:IsShown() then count = count + 1 end
                    
                    -- Update partyHeader childCount
                    partyHeader:SetAttribute("childCount", count)
                    
                    -- Trigger repositioning
                    local v = partyHeader:GetAttribute("triggerposition") or 0
                    partyHeader:SetAttribute("triggerposition", v + 1)
                end
            ]])
            
            -- On hide - count children excluding self
            SecureHandlerWrapScript(child, "OnHide", child, [[
                local partyHeader = self:GetFrameRef("partyHeader")
                if partyHeader then
                    -- Count visible children, excluding self since we're hiding
                    local count = 0
                    local c1 = partyHeader:GetAttribute("frameref-child1")
                    local c2 = partyHeader:GetAttribute("frameref-child2")
                    local c3 = partyHeader:GetAttribute("frameref-child3")
                    local c4 = partyHeader:GetAttribute("frameref-child4")
                    local c5 = partyHeader:GetAttribute("frameref-child5")
                    if c1 and c1:IsShown() and c1 ~= self then count = count + 1 end
                    if c2 and c2:IsShown() and c2 ~= self then count = count + 1 end
                    if c3 and c3:IsShown() and c3 ~= self then count = count + 1 end
                    if c4 and c4:IsShown() and c4 ~= self then count = count + 1 end
                    if c5 and c5:IsShown() and c5 ~= self then count = count + 1 end
                    
                    -- Update partyHeader childCount
                    partyHeader:SetAttribute("childCount", count)
                    
                    -- Trigger repositioning
                    local v = partyHeader:GetAttribute("triggerposition") or 0
                    partyHeader:SetAttribute("triggerposition", v + 1)
                end
            ]])
            
            if DF:DebugActive("HEADERS") then
                headerDebug("Hooked child", i, "for repositioning:", child:GetName())
            end
        end
    end
    
    DF.partyChildrenHooked = true
    
    headerDebug("Party children hooked for repositioning")
end

-- Hook arena header children to trigger repositioning on show/hide
function DF:HookArenaChildrenForRepositioning()
    if InCombatLockdown() then return end
    if not DF.arenaHeader then return end
    
    -- Track which children we've hooked to avoid double-hooking same child
    DF.hookedArenaChildren = DF.hookedArenaChildren or {}
    
    -- Hook each child's OnShow and OnHide
    for i = 1, 5 do
        local child = DF.arenaHeader:GetAttribute("child" .. i)
        if child and not DF.hookedArenaChildren[child] then
            DF.hookedArenaChildren[child] = true
            
            SecureHandlerSetFrameRef(child, "arenaHeader", DF.arenaHeader)
            
            -- On show - count all children and trigger repositioning
            SecureHandlerWrapScript(child, "OnShow", child, [[
                local arenaHeader = self:GetFrameRef("arenaHeader")
                if arenaHeader then
                    local count = 0
                    local c1 = arenaHeader:GetAttribute("frameref-child1")
                    local c2 = arenaHeader:GetAttribute("frameref-child2")
                    local c3 = arenaHeader:GetAttribute("frameref-child3")
                    local c4 = arenaHeader:GetAttribute("frameref-child4")
                    local c5 = arenaHeader:GetAttribute("frameref-child5")
                    if c1 and c1:IsShown() then count = count + 1 end
                    if c2 and c2:IsShown() then count = count + 1 end
                    if c3 and c3:IsShown() then count = count + 1 end
                    if c4 and c4:IsShown() then count = count + 1 end
                    if c5 and c5:IsShown() then count = count + 1 end
                    
                    arenaHeader:SetAttribute("childCount", count)
                    
                    local v = arenaHeader:GetAttribute("triggerposition") or 0
                    arenaHeader:SetAttribute("triggerposition", v + 1)
                end
            ]])
            
            -- On hide - count children excluding self
            SecureHandlerWrapScript(child, "OnHide", child, [[
                local arenaHeader = self:GetFrameRef("arenaHeader")
                if arenaHeader then
                    local count = 0
                    local c1 = arenaHeader:GetAttribute("frameref-child1")
                    local c2 = arenaHeader:GetAttribute("frameref-child2")
                    local c3 = arenaHeader:GetAttribute("frameref-child3")
                    local c4 = arenaHeader:GetAttribute("frameref-child4")
                    local c5 = arenaHeader:GetAttribute("frameref-child5")
                    if c1 and c1:IsShown() and c1 ~= self then count = count + 1 end
                    if c2 and c2:IsShown() and c2 ~= self then count = count + 1 end
                    if c3 and c3:IsShown() and c3 ~= self then count = count + 1 end
                    if c4 and c4:IsShown() and c4 ~= self then count = count + 1 end
                    if c5 and c5:IsShown() and c5 ~= self then count = count + 1 end
                    
                    arenaHeader:SetAttribute("childCount", count)
                    
                    local v = arenaHeader:GetAttribute("triggerposition") or 0
                    arenaHeader:SetAttribute("triggerposition", v + 1)
                end
            ]])
            
            if DF:DebugActive("HEADERS") then
                headerDebug("Hooked arena child", i, "for repositioning:", child:GetName())
            end
        end
    end
    
    -- ☠ (Removed) DF.arenaChildrenHooked = true. Write-only: nothing read it, so it
    -- guarded no re-entry. Both Hook*ChildrenForRepositioning functions actually
    -- guard per child, via DF.hookedChildren / DF.hookedArenaChildren -- the flag
    -- only looked like the guard. (Its party twin, DF.partyChildrenHooked, is read
    -- once in a debug print and stays.)

    headerDebug("Arena children hooked for repositioning")
end

-- ☠ (Removed) DF:UpdateHeaderFrameCount, "backup for out of combat" for the
-- totalFrameCount attribute. No callers in either addon; its only other mention was
-- a PROFILED_FUNCTIONS string, which wraps rather than calls. Both of its lines
-- forwarded to DF:TriggerSecurePosition, which is live and called elsewhere -- so
-- the "backup" it advertised was never running, and whatever keeps totalFrameCount
-- correct out of combat, it is not this.

-- ============================================================
-- DEBUG
-- ============================================================

function DF:DumpHeaderInfo()
    local o = DF:Out("Headers", "state dump")

    o:Section("Group status")
    print("  IsInRaid:", IsInRaid() and "true" or "false")
    print("  IsInGroup:", IsInGroup() and "true" or "false")
    print("  GetNumGroupMembers:", GetNumGroupMembers())
    
    -- Show init state
    o:Section("Init state")
    print("  headersCreated:", DF.headersCreated and "true" or "false")
    print("  headersInitialized:", DF.headersInitialized and "true" or "false")
    print("  partyChildrenHooked:", DF.partyChildrenHooked and "true" or "false")
    print("  pendingHeaderSettingsApply:", DF.pendingHeaderSettingsApply and "true" or "false")
    
    -- Show containers
    o:Section("Containers")
    print("  partyContainer:", DF.partyContainer and (DF.partyContainer:IsShown() and "VISIBLE" or "hidden") or "nil")
    print("  raidContainer:", DF.raidContainer and (DF.raidContainer:IsShown() and "VISIBLE" or "hidden") or "nil")
    
    -- Show current settings
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    o:Section("Party settings")
    print("  growDirection:", db.growDirection or "nil")
    print("  growthAnchor:", db.growthAnchor or "nil")
    print("  sortSelfPosition:", db.sortSelfPosition or "nil")
    print("  sortEnabled:", db.sortEnabled and "true" or "false")
    o:Section("Raid settings")
    print("  raidUseGroups:", raidDb.raidUseGroups and "true" or "false")
    -- ⚠ DF.db, not raidDb. The Enable Raid Frames checkbox writes the profile ROOT key;
    -- the raid table carries an inert same-named key inherited from PartyDefaults, so
    -- reading it here reported the opposite of the truth to whoever was diagnosing the
    -- setting. Same root cause as the two live reads fixed in Frames/Init.lua.
    print("  raidEnabled:", (DF.db and DF.db.raidEnabled ~= false) and "true" or "false")
    print("  sortEnabled:", raidDb.sortEnabled and "true" or "false")
    print("  sortSelfPosition:", raidDb.sortSelfPosition or "nil")
    print("  sortSeparateMeleeRanged:", raidDb.sortSeparateMeleeRanged and "true" or "false")
    print("  sortByClass:", raidDb.sortByClass and "true" or "false")
    print("  sortAlphabetical:", tostring(raidDb.sortAlphabetical))
    
    if DF.partyHeader then
        print("Party Header:", DF.partyHeader:GetName())
        print("  showPlayer:", DF.partyHeader:GetAttribute("showPlayer") and "true" or "false")
        print("  showSolo:", DF.partyHeader:GetAttribute("showSolo") and "true" or "false")
        print("  sortMethod:", DF.partyHeader:GetAttribute("sortMethod") or "nil")
        print("  nameList:", DF.partyHeader:GetAttribute("nameList") or "nil")
        
        -- Dump secure positioning debug attributes for partyHeader
        print("  Positioning Debug:")
        print("    selfCentering:", DF.partyHeader:GetAttribute("selfCentering") and "true" or "false")
        print("    extraFrameCount:", DF.partyHeader:GetAttribute("extraFrameCount") or "nil")
        print("    childCount (attr):", DF.partyHeader:GetAttribute("childCount") or "nil")
        print("    debugChildCount:", DF.partyHeader:GetAttribute("debugChildCount") or "nil")
        print("    debugExtraCount:", DF.partyHeader:GetAttribute("debugExtraCount") or "nil")
        print("    debugTotalCount:", DF.partyHeader:GetAttribute("debugTotalCount") or "nil")
        print("    debugTotalSize:", DF.partyHeader:GetAttribute("debugTotalSize") or "nil")
        print("    debugOffsetX:", DF.partyHeader:GetAttribute("debugOffsetX") or "nil")
        print("    debugOffsetY:", DF.partyHeader:GetAttribute("debugOffsetY") or "nil")
        print("    debugSkipped:", DF.partyHeader:GetAttribute("debugSkipped") or "nil")
        print("    frameWidth:", DF.partyHeader:GetAttribute("frameWidth") or "nil")
        print("    frameHeight:", DF.partyHeader:GetAttribute("frameHeight") or "nil")
        print("    spacing:", DF.partyHeader:GetAttribute("spacing") or "nil")
        print("    horizontal:", DF.partyHeader:GetAttribute("horizontal") and "true" or "false")
        
        local visibleCount = 0
        for i = 1, 5 do
            local child = DF.partyHeader:GetAttribute("child" .. i)
            if child then
                local isShown = child:IsShown()
                if isShown then visibleCount = visibleCount + 1 end
                print("  Child " .. i .. ":", child:GetName(), "Unit:", child:GetAttribute("unit") or "none", "Shown:", isShown and "yes" or "no")
            end
        end
        print("  Visible children:", visibleCount)
    end
    
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        local count = 0
        local visCount = 0
        for i = 1, 40 do
            local child = DF.FlatRaidFrames.header:GetAttribute("child" .. i)
            if child then
                count = count + 1
                if child:IsShown() then visCount = visCount + 1 end
            end
        end
        print("Raid Combined Header:", DF.FlatRaidFrames.header:IsShown() and "VISIBLE" or "hidden", count .. " children (" .. visCount .. " visible)")
    else
        print("Raid Combined Header: nil")
    end
    
    if DF.raidSeparatedHeaders then
        for g = 1, 8 do
            local header = DF.raidSeparatedHeaders[g]
            if header then
                local count = 0
                local visCount = 0
                for i = 1, 5 do
                    local child = header:GetAttribute("child" .. i)
                    if child then
                        count = count + 1
                        if child:IsShown() then visCount = visCount + 1 end
                    end
                end
                if count > 0 or header:IsShown() then
                    print("Raid Group " .. g .. " Header:", header:IsShown() and "VISIBLE" or "hidden", count .. " children (" .. visCount .. " visible)")
                    print("    sortMethod:", header:GetAttribute("sortMethod") or "nil")
                    print("    groupFilter:", header:GetAttribute("groupFilter") or "nil")
                    local nl = header:GetAttribute("nameList")
                    print("    nameList:", nl and (string.len(nl) > 50 and string.sub(nl, 1, 50) .. "..." or nl) or "nil")
                end
            end
        end
    else
        print("  " .. DF.OUT.NEUTRAL .. "Raid separated headers: none|r")
    end

    o:Siblings("headers")
end

-- ============================================================
-- APPLY SETTINGS FROM DB
-- Reads settings and applies them to headers
-- ============================================================

function DF:ApplyHeaderSettings()
    if DF:DebugActive("FLATRAID") then
        DF:Debug("FLATRAID", "ApplyHeaderSettings: called from\n%s", debugstack(2, 10, 0) or "unknown")
    end
    
    if InCombatLockdown() then
        -- Queue for after combat
        DF.pendingHeaderSettingsApply = true
        return
    end
    
    -- Make sure headers are created
    if not DF.headersCreated then
        headerDebug("ApplyHeaderSettings skipped - headers not created yet")
        return
    end
    
    -- Double-check headers exist
    if not DF.partyHeader then
        headerDebug("ApplyHeaderSettings skipped - party header missing")
        return
    end
    
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    DF:Debug("FLATRAID", "ApplyHeaderSettings: raidUseGroups=%s growDirection=%s raidFlatFrameAnchor=%s",
        tostring(raidDb.raidUseGroups), tostring(raidDb.growDirection), tostring(raidDb.raidFlatFrameAnchor))
    
    -- Apply orientation from growDirection, growthAnchor, and selfPosition settings
    local horizontal = (db.growDirection == "HORIZONTAL")
    local growFrom = db.growthAnchor or "START"
    local selfPosition = db.sortSelfPosition or "FIRST"
    DF:SetPartyOrientation(horizontal, growFrom, selfPosition)
    
    -- Raid orientation — only configure the ACTIVE mode's headers.
    -- Touching inactive headers triggers SecureGroupHeader attribute churn
    -- (OnAttributeChanged, OnShow/OnHide hooks) that can stomp container sizing.
    local raidHorizontal = (raidDb.growDirection == "HORIZONTAL")

    if raidDb.raidUseGroups then
        -- Separated mode: use raidGroupAnchor for groups
        local raidGrowFrom = raidDb.raidGroupAnchor or "START"
        DF:SetRaidOrientation(false, raidGrowFrom)
    else
        -- Combined/flat mode: use raidFlatFrameAnchor (different setting to the grouped one)
        local raidGrowFrom = raidDb.raidFlatFrameAnchor or "START"
        DF:Debug("FLATRAID", "ApplyHeaderSettings:   FLAT MODE: SetRaidOrientation(%s, %s)",
            tostring(raidHorizontal), raidGrowFrom)
        DF:SetRaidOrientation(raidHorizontal, raidGrowFrom)
    end

    -- Re-hook any new children that may have been created
    DF:HookPartyChildrenForRepositioning()

    -- Note: OnShow/OnHide hooks will handle dynamic repositioning when children change

    -- Apply sorting from settings
    -- NOTE: Party sorting is handled by ApplyPartyGroupSorting (called from SetPartyOrientation)
    -- NOTE: Arena sorting is NOT applied here — it's handled by ProcessRosterUpdate (via GRU).
    --       PEW clears arena attrs to INDEX for safe initial display of all units.
    --       Calling ApplyArenaHeaderSorting here would override INDEX before roster is complete,
    --       causing groupBy/nameList to filter out players who haven't loaded yet.
    -- NOTE: Raid separated headers sorting is handled by ApplyRaidGroupSorting
    -- NOTE: Raid flat/combined header sorting is handled by ApplyRaidFlatSorting

    -- Arena: skip raid sorting entirely (arena orientation was already applied above)
    local contentType = DF.GetContentType and DF:GetContentType()
    if contentType == "arena" then
        return
    end

    -- Update raid frame sizes — only for the active mode's headers.
    -- Sizing inactive grouped headers triggers attribute churn on hidden children.
    if raidDb.raidUseGroups then
        DF:UpdateRaidGroupFrameSizes()
        DF:ApplyRaidGroupSorting()
    else
        DF:UpdateRaidFlatFrameSizes()
        DF:Debug("FLATRAID", "ApplyHeaderSettings:   -> calling ApplyRaidFlatSorting")
        DF:ApplyRaidFlatSorting()
        
        -- ☠ A "FINAL SIZE FORCING" block used to sit here. It has never run for anyone.
        -- Its gate was `raidFlatPlayerAnchor ~= "CENTER"` and that key is seeded "CENTER"
        -- by the defaults table and written by no control anywhere in this repo's
        -- history, so the condition was false on every profile, on every apply.
        --
        -- It is deleted rather than repointed at raidFlatFrameAnchor along with the
        -- readers above. That key only offers START/END, so repointing would have turned
        -- a block that has executed zero times into one that executes on every settings
        -- apply -- force-sizing the flat header and toggling showRaid off/on to provoke
        -- a re-layout. Untested code that moves live frames is not something to switch on
        -- as a side effect of fixing a different bug. If flat mode ever does need the
        -- size forcing, it should be added deliberately and confirmed in game.
    end
    
    -- Schedule private aura reanchor after ALL attribute changes settle.
    -- This catches the showRaid false/true toggle above which can cause a second
    -- round of unit reassignments after the sorting functions have already run.
end

-- ============================================================
-- AUTO-INITIALIZATION
-- Create frames at ADDON_LOADED (combat-safe)
-- Apply settings at PLAYER_LOGIN or after combat
-- ============================================================

-- Create frames early (ADDON_LOADED) for combat-safe reload
function DF:CreateHeaderFrames()
    if DF.headersCreated then return end
    
    -- Check if secure headers are enabled in settings
    local db = DF:GetDB()
    if db and db.useSecureHeaders == false then
        headerDebug("Secure headers disabled in settings")
        return
    end
    
    -- forceHeaderMode is already set at file scope

    -- Create containers and headers (this is the combat-safe part)
    DF:CreateContainers()

    if DF.db and DF.db.partyEnabled ~= false then
        DF:CreatePartyHeader()
        -- Arena header rides with party (raid units but party layout)
        DF:CreateArenaHeader()
    end

    if DF.db and DF.db.raidEnabled ~= false then
        DF:CreateRaidHeaders()
    end
    
    -- Initialize secure positioning hooks (must be done out of combat, but frames exist)
    if not InCombatLockdown() then
        DF:InitSecurePositioning()
    else
        DF.pendingSecurePositioningInit = true
    end
    
    DF.headersCreated = true
end

-- Apply settings and show frames (PLAYER_LOGIN or after combat)
function DF:FinalizeHeaderInit()
    if DF.headersInitialized then return end
    if not DF.headersCreated then return end
    
    if InCombatLockdown() then
        DF.pendingHeaderFinalize = true
        return
    end
    
    -- CRITICAL: Ensure DF.container is shown!
    -- Something may have hidden it between ADDON_LOADED and PLAYER_LOGIN
    if DF.container then
        DF.container:Show()
    end
    
    -- Initialize secure positioning if it was deferred
    if DF.pendingSecurePositioningInit then
        DF:InitSecurePositioning()
        DF.pendingSecurePositioningInit = false
    end
    
    -- Apply settings from DB
    DF:ApplyHeaderSettings()

    -- ============================================================
    -- CRITICAL: Set up header visibility during the ADDON_LOADED
    -- grace window (InCombatLockdown() is still false).
    -- Without this, combat reloads never call UpdateHeaderVisibility
    -- because PLAYER_ENTERING_WORLD fires AFTER combat lockdown
    -- kicks in, causing UpdateHeaderVisibility to bail and defer
    -- to PLAYER_REGEN_ENABLED — leaving raid groups missing until
    -- combat ends.
    -- ============================================================
    DF:UpdateHeaderVisibility()

    DF.headersInitialized = true
    
    -- ============================================================
    -- CRITICAL: Set DF.initialized for header mode
    -- This was previously only set in Init.lua for legacy mode,
    -- but header mode returns early from InitializeFrames().
    -- Without this, event handlers check "if not DF.initialized then return"
    -- and never process events!
    -- ============================================================
    DF.initialized = true

    -- Do an immediate missing buff check
    if not InCombatLockdown() and DF.UpdateAllMissingBuffIcons then
        DF:UpdateAllMissingBuffIcons()
    end
    
    -- Initialize targeted spells feature
    if DF.InitTargetedSpells then
        DF:InitTargetedSpells()
    end
    
    -- Re-register with click-cast addons
    if DF.RegisterClickCastFrames then
        DF:RegisterClickCastFrames()
    end
    
    -- ============================================================
    -- SYNCHRONOUS: Apply sorting and update labels immediately
    -- CRITICAL for combat reload - no delays allowed!
    -- ============================================================
    DF:ApplyPartyGroupSorting()
    local db = DF:GetRaidDB()
    if db.raidUseGroups then
        DF:ApplyRaidGroupSorting()
    else
        DF:ApplyRaidFlatSorting()
    end
    
    -- Update raid group labels
    if DF.UpdateRaidGroupLabels then
        DF:UpdateRaidGroupLabels()
    end
    
    -- ============================================================
    -- SYNCHRONOUS: Force full refresh on all visible frames
    -- This ensures auras, absorbs, etc. are updated on combat reload
    -- ============================================================
    DF:RefreshAllHeaderChildFrames()
end

-- ============================================================
-- FULL REFRESH FOR ALL HEADER CHILDREN
-- Called during initialization and combat reload to ensure
-- all frames have their auras, absorbs, health bars, etc. updated
-- ============================================================
function DF:RefreshAllHeaderChildFrames()
    local function RefreshFrame(frame)
        if not frame then return end
        if not frame.dfIsHeaderChild then return end
        if not frame.unit then return end
        if not frame:IsVisible() then return end
        
        -- Full frame refresh - health, power, name, etc.
        if DF.UpdateUnitFrame then
            DF:UpdateUnitFrame(frame)
        end
        
        -- Auras
        if DF.UpdateAuras then
            DF:UpdateAuras(frame)
        end
        
        -- Role icon
        if DF.UpdateRoleIcon then
            DF:UpdateRoleIcon(frame)
        end
        
        -- Absorb bars
        if DF.UpdateAbsorb then
            DF:UpdateAbsorb(frame)
        end
        if DF.UpdateHealAbsorb then
            DF:UpdateHealAbsorb(frame)
        end
        
        -- Raid target icon
        if DF.UpdateRaidTargetIcon then
            DF:UpdateRaidTargetIcon(frame)
        end
        
        -- Ready check
        if DF.UpdateReadyCheckIcon then
            DF:UpdateReadyCheckIcon(frame)
        end
        
        -- Leader/assist icons
        if DF.UpdateLeaderIcon then
            DF:UpdateLeaderIcon(frame)
        end
        
        -- Dispel overlay
        if DF.UpdateDispelOverlay then
            DF:UpdateDispelOverlay(frame)
        end
        
        -- Missing buff icon
        if DF.UpdateMissingBuffIcon then
            DF:UpdateMissingBuffIcon(frame)
        end
        
        -- External def icon
        if DF.UpdateExternalDefIcon then
            DF:UpdateExternalDefIcon(frame)
        end
        
        -- Highlights
        if DF.UpdateHighlights then
            DF:UpdateHighlights(frame)
        end
    end
    
    -- Refresh party frames
    if DF.partyHeader then
        for i = 1, 5 do
            local child = DF.partyHeader:GetAttribute("child" .. i)
            if child then
                RefreshFrame(child)
            end
        end
    end
    
    -- Refresh arena frames
    if DF.arenaHeader then
        for i = 1, 40 do
            local child = DF.arenaHeader:GetAttribute("child" .. i)
            if child then
                RefreshFrame(child)
            end
        end
    end
    
    -- Refresh raid combined header
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        for i = 1, 40 do
            local child = DF.FlatRaidFrames.header:GetAttribute("child" .. i)
            if child then
                RefreshFrame(child)
            end
        end
    end
    
    -- Refresh raid separated headers
    if DF.raidSeparatedHeaders then
        for g = 1, 8 do
            local header = DF.raidSeparatedHeaders[g]
            if header then
                for i = 1, 5 do
                    local child = header:GetAttribute("child" .. i)
                    if child then
                        RefreshFrame(child)
                    end
                end
            end
        end
    end
    
    -- Refresh FlatRaidFrames if active
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        for i = 1, 40 do
            local child = DF.FlatRaidFrames.header:GetAttribute("child" .. i)
            if child then
                RefreshFrame(child)
            end
        end
    end
    
    -- Refresh PinnedFrames if active.
    -- ☠ THROUGH THE SHARED WALKER, NOT A HAND-ROLLED HEADER LOOP — this walked
    -- PinnedFrames.headers only, so the whole per-frame refresh block (role, absorb, raid
    -- target, dispel, missing buff, highlights) never reached a pinned BOSS frame.
    -- (Audit 2026-08-17.)
    if DF.IteratePinnedFrames then
        DF.IteratePinnedFrames(RefreshFrame)
    end
end

-- Single event frame for all header events
local headerEventFrame = CreateFrame("Frame")
headerEventFrame:RegisterEvent("ADDON_LOADED")
headerEventFrame:RegisterEvent("PLAYER_LOGIN")
headerEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
headerEventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
headerEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
headerEventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
headerEventFrame:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")  -- BUG #3 FIX: backup arena detection

headerEventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    
    -- ADDON_LOADED: Create frames early for combat-safe reload
    -- CRITICAL: Must run synchronously - no C_Timer.After!
    -- The combat-safe window only exists during ADDON_LOADED handler execution
    if event == "ADDON_LOADED" and arg1 == "DandersFrames" then
        DF:CreateHeaderFrames()
        
        -- COMBAT RELOAD DETECTION: If player exists, this is a reload, not fresh login
        -- We must finalize immediately because combat lockdown will kick in shortly
        if UnitExists("player") then
            -- Synchronously finalize - do NOT use any delays
            DF:FinalizeHeaderInit()
        end
        return
    end
    
    -- PLAYER_LOGIN: Finalize initialization (fresh login only)
    if event == "PLAYER_LOGIN" then
        -- For fresh logins, we can use a small delay to let things settle
        -- But check if we already finalized during ADDON_LOADED (reload case)
        if not DF.headersInitialized then
            C_Timer.After(0.3, function()
                DF:FinalizeHeaderInit()
            end)
        end
        return
    end
    
    -- PLAYER_REGEN_ENABLED: Handle pending operations after combat
    if event == "PLAYER_REGEN_ENABLED" then
        -- Finalize init if pending
        if DF.pendingHeaderFinalize then
            DF.pendingHeaderFinalize = false
            DF:FinalizeHeaderInit()
        end
        
        -- Apply pending settings (but not for flat layouts - they use pendingFlatLayoutRefresh)
        if DF.pendingHeaderSettingsApply then
            DF.pendingHeaderSettingsApply = false
            local raidDb = DF:GetRaidDB()
            local contentType = DF.GetContentType and DF:GetContentType()
            -- ARENA FIX: Arena is IsInRaid()=true but should NOT be skipped here.
            -- The flat-raid guard (IsInRaid and not raidUseGroups) was catching arena too,
            -- preventing UpdateHeaderVisibility from ever running for arena on combat end.
            local isFlatRaid = IsInRaid() and not raidDb.raidUseGroups and contentType ~= "arena"
            if not isFlatRaid then
                -- Update visibility first (ensures event registration)
                DF:UpdateHeaderVisibility()
                DF:ApplyHeaderSettings()
            end
        end
        
        -- Init secure positioning if pending
        if DF.pendingSecurePositioningInit and DF.headersCreated then
            DF.pendingSecurePositioningInit = false
            DF:InitSecurePositioning()
        end
        
        -- Create raid position handler if pending (combat reload case)
        if DF.pendingRaidPositionHandler then
            DF.pendingRaidPositionHandler = false
            DF:CreateRaidPositionHandler()
        end
        
        -- Trigger raid position if pending (combat reload case)
        if DF.pendingRaidPositionTrigger then
            DF.pendingRaidPositionTrigger = false
            DF:TriggerRaidPosition()
        end
        
        -- Update player group tracking if pending
        if DF.pendingPlayerGroupUpdate then
            DF.pendingPlayerGroupUpdate = false
            DF:UpdatePlayerGroupTracking()
        end
        
        -- Update group display order if pending
        if DF.pendingGroupOrderUpdate then
            DF.pendingGroupOrderUpdate = false
            DF:UpdateRaidGroupOrderAttributes()
        end
        
        -- Hide raid frames if pending (combat reload case when not in raid)
        if DF.pendingRaidHide and not IsInRaid() then
            DF.pendingRaidHide = false
            if DF.raidContainer then
                DF.raidContainer:Hide()
            end
            if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
                DF.FlatRaidFrames.header:Hide()
            end
            for i = 1, 8 do
                if DF.raidSeparatedHeaders and DF.raidSeparatedHeaders[i] then
                    DF.raidSeparatedHeaders[i]:Hide()
                end
            end
        end
        
        -- Apply pending sorting update (roster changed during combat)
        if DF.pendingSortingUpdate then
            DF.pendingSortingUpdate = false
            headerDebug("Applying queued sorting update after combat")
            -- When FrameSort integration is active, FrameSort already fires its own
            -- combat-end sort synchronously on PLAYER_REGEN_ENABLED (via its
            -- RunWhenCombatEnds callback queue). Calling ProcessRosterUpdate here
            -- would run ApplyArenaHeaderSorting → clear nameList to INDEX, undoing
            -- FrameSort's work. The event handler order between DF and FrameSort is
            -- non-deterministic, so this caused intermittent wrong ordering between
            -- Solo Shuffle rounds. Let FrameSort own the sort entirely.
            if not DF:IsFrameSortActive() then
                DF:ProcessRosterUpdate()
            end
            -- BUG #4 FIX: Force refresh all frames after arena combat-end recovery.
            -- Health bars may show stale data because UNIT_HEALTH events were dropped
            -- while the arena header was hidden / events disabled.
            if DF.RefreshLiveFrames then
                DF:RefreshLiveFrames()
            end
        end
        
        -- FIX: Safety-net rebuild of unitFrameMap after ALL pending operations.
        -- During combat, the map may have become stale (e.g., PLAYER_ENTERING_WORLD
        -- fired during combat and set pending flags, or sorting was deferred).
        -- The operations above may not always trigger OnAttributeChanged for every
        -- child (e.g., when sorting attributes haven't changed), so the map could
        -- still have gaps.  A rebuild here guarantees health events are dispatched
        -- correctly from this point forward.
        DF:RebuildUnitFrameMap()
        
        return
    end
    
    -- BUG #3 FIX: ARENA_PREP_OPPONENT_SPECIALIZATIONS - Backup arena detection.
    -- This event fires reliably when the arena prep phase begins, even after reloads.
    -- If PEW ran before IsInInstance() returned "arena", the arena header is still hidden
    -- and raid frames are showing instead. This corrects that.
    if event == "ARENA_PREP_OPPONENT_SPECIALIZATIONS" then
        if not DF.headersInitialized then return end
        local contentType = DF:GetContentType()
        if contentType == "arena" and DF.arenaHeader and not DF.arenaHeader:IsShown() then
            if not InCombatLockdown() then
                DF:UpdateHeaderVisibility()
                -- Clear stale sorting attributes
                DF.arenaHeader:SetAttribute("nameList", nil)
                DF.arenaHeader:SetAttribute("groupBy", nil)
                DF.arenaHeader:SetAttribute("groupingOrder", nil)
                DF.arenaHeader:SetAttribute("groupFilter", nil)
                DF.arenaHeader:SetAttribute("roleFilter", nil)
                DF.arenaHeader:SetAttribute("strictFiltering", nil)
                DF.arenaHeader:SetAttribute("sortMethod", "INDEX")
                DF:RebuildUnitFrameMap()
                if DF.RefreshLiveFrames then
                    DF:RefreshLiveFrames()
                end
                QueueRosterUpdate()
                headerDebug("ARENA_PREP: corrected header visibility")
            else
                DF.pendingVisibilityUpdate = true
                DF.pendingSortingUpdate = true
            end
        end
        return
    end
    
    -- GROUP_ROSTER_UPDATE / PLAYER_ENTERING_WORLD: Re-apply settings
    -- MINIMAL HANDLER: SecureGroupHeaderTemplate handles most roster changes automatically
    -- We only need to:
    -- 1. Update container visibility (party vs raid)
    -- 2. Update nameLists IF custom sorting is enabled
    -- 3. Update position handler for group layout
    -- Frame updates (role icons, dispel, etc.) happen via OnAttributeChanged and UNIT_* events
    if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        DF:Debug("ROSTER", "EVENT: %s, members=%d, inRaid=%s, combat=%s",
            event, GetNumGroupMembers(), tostring(IsInRaid()), tostring(InCombatLockdown()))
        DF:RosterDebugEvent("Headers.lua:" .. event)
        
        -- Only if headers are fully initialized
        if not DF.headersInitialized then return end
        
        -- ARENA RELOAD FIX: On UI reload, enable the content type fallback so that
        -- GetContentType() can use the saved arena hint from before the reload.
        -- This must run BEFORE any call to GetContentType() in this handler.
        -- The flag auto-clears once WoW's APIs start returning valid data.
        if event == "PLAYER_ENTERING_WORLD" and arg2 then  -- arg2 = isReloadingUi
            DF.useContentTypeFallback = true
        end
        
        -- Auto-disable test mode on zone transitions (PLAYER_ENTERING_WORLD only)
        -- Without this, UpdateHeaderVisibility bails early and live frames never show
        -- Must run before the combat check since zone-in can briefly be in combat
        if event == "PLAYER_ENTERING_WORLD" and (DF.testMode or DF.raidTestMode) then
            if DF.testMode then
                DF.testMode = false
                -- ☠ DROP THE CLAIMS TOO. This zone teardown clears the flag INLINE rather
                -- than going through the ownership model (the comment below says so), so a
                -- surviving `user` / `unlock` claim outlives the frames it asked for.
                -- ReconcileTestMode then sees wanted=true / active=false and re-shows the
                -- preview on the next owner change -- e.g. clicking Lock. Shim.lua's header
                -- names this call site and the combat one in Core.lua as the two that must
                -- clear their claims explicitly.
                if DF.ClearTestModeOwners then DF:ClearTestModeOwners("party") end
                DF:StopTestAnimation()
                if DF.testPartyFrames then
                    for i = 0, 4 do
                        local frame = DF.testPartyFrames[i]
                        if frame then frame:Hide() end
                    end
                end
                if DF.testPartyContainer then DF.testPartyContainer:Hide() end
            end
            if DF.raidTestMode then
                DF.raidTestMode = false
                -- Raid twin of the party clear above -- see that comment.
                if DF.ClearTestModeOwners then DF:ClearTestModeOwners("raid") end
                DF:StopTestAnimation()
                if DF.testRaidContainer then DF.testRaidContainer:Hide() end
            end
            -- Both mode flags are down now, so hand the shared engine state back:
            -- the aura data provider and the pinned preview. This path clears the
            -- flags inline rather than going through HideTestFrames, and skipping
            -- the handback used to strand C_UnitAuras on the SAMPLE provider for
            -- the rest of the session (live frames then rendered fake auras).
            if DF.TeardownTestModeEngines then DF:TeardownTestModeEngines() end
            -- ...and the FRAME-side teardown. This path was the thinnest of the three:
            -- it called frame:Hide() and nothing else, so it left the Aura Designer
            -- indicators (parented to UIParent, they survive Hide), the absorb
            -- textures, and the pet / personal-targeted / Targeted List preview sets
            -- all on screen after zoning with the preview up.
            if DF.TeardownTestFrameVisuals then DF:TeardownTestFrameVisuals() end
            -- Clear state drivers if not in combat (can't unregister in combat)
            if not InCombatLockdown() and DF.testModeStateDriversActive then
                DF:ClearTestModeStateDrivers()
            end
            DF.testModeInterruptedByCombat = false
            -- Update GUI buttons if open
            if DF.GUI then
                if DF.GUI.UpdateTestButtonState then DF.GUI.UpdateTestButtonState() end
                if DF.GUI.UpdateLockButtonState then DF.GUI.UpdateLockButtonState() end
            end
            -- Close test panel if open
            if DF.TestPanel and DF.TestPanel:IsShown() then
                DF.TestPanel:Hide()
            end
        end
        
        -- In combat, nameList-based sorting can't update, but labels can
        if InCombatLockdown() then
            -- Check for arena FIRST - arena is IsInRaid()=true but needs sorting, not flat layout
            local contentType = DF:GetContentType()
            if contentType == "arena" then
                -- Arena needs a full sorting update after combat (nameList with new player names)
                DF.pendingSortingUpdate = true
            else
                -- Set the correct pending flag based on raid mode
                local raidDb = DF:GetRaidDB()
                if IsInRaid() and raidDb and not raidDb.raidUseGroups then
                    DF.pendingFlatLayoutRefresh = true
                else
                    DF.pendingHeaderSettingsApply = true
                end
            end
            -- Register group transition state drivers for instant party<->raid switching
            -- UpdateHeaderVisibility will handle the state driver registration
            if DF.UpdateHeaderVisibility then
                DF:UpdateHeaderVisibility()
            end
            -- Still update group labels during combat (they're not secure frames)
            if IsInRaid() and DF.UpdateRaidGroupLabels then
                C_Timer.After(0.1, function()
                    if DF.UpdateRaidGroupLabels then
                        DF:UpdateRaidGroupLabels()
                    end
                end)
            end
            return
        end
        
        -- Frame-based throttling
        -- Queue update to next frame - automatically coalesces multiple events
        if event == "GROUP_ROSTER_UPDATE" or event == "ZONE_CHANGED_NEW_AREA" then
            QueueRosterUpdate()  -- Will call ProcessRosterUpdate on next frame
            return
        end
        
        -- PLAYER_ENTERING_WORLD runs immediately
        gruEventCount = 0  -- Reset GRU counter for this zone-in
        local isInInstance, instanceType = IsInInstance()
        DF:Debug("ROSTER", "PEW: isInitialLogin=%s, isReload=%s, inRaid=%s, inGroup=%s, members=%d, inInstance=%s, instanceType=%s",
            tostring(arg1), tostring(arg2), tostring(IsInRaid()), tostring(IsInGroup()),
            GetNumGroupMembers(), tostring(isInInstance), tostring(instanceType or "nil"))

        -- ARENA DEBUG: Log instance detection state at PEW entry
        
        -- FIX: Clear ALL caches to force re-validation of all frames
        -- This fixes health desync when WoW shuffles unit slots without changing unit strings
        -- (e.g., raid1=PlayerA before zone, raid1=PlayerB after zone)
        
        -- Clear GUID cache (existing fix)
        wipe(unitGuidCache)
        
        -- Clear roster membership cache - prevents HasRosterMembershipChanged() from
        -- incorrectly returning false when entering LFR with similar roster composition
        wipe(rosterMembershipCache)
        lastRosterCount = 0

        -- Clear sorting key cache so the next ApplyRaidGroupSorting does a full
        -- Hide/Show cycle. Zone transitions may change the roster composition
        -- even though the nameList string looks the same.
        if DF._lastGroupSortKey then wipe(DF._lastGroupSortKey) end
        -- Clear layout cache so UpdateRaidHeaderLayoutAttributes runs fully
        lastLayoutHorizontal = nil
        lastLayoutSpacing = nil
        
        -- NOTE: Do NOT wipe(unitFrameMap) here. Keeping existing entries ensures
        -- UNIT_HEALTH events keep dispatching to frames while headers rebuild.
        -- The GUID cache wipe above forces OnAttributeChanged to always take the
        -- full-refresh path, preventing stale-player-same-unit-string issues.
        -- Stale entries are cleaned by RebuildUnitFrameMap() (targeted cleanup)
        -- and overwritten by OnAttributeChanged when units reassign.

        -- Reset self-healing cooldown so the first missed UNIT_HEALTH event
        -- after zone transition triggers an immediate map rebuild
        DF.lastMapRebuild = nil

        -- Clear phased icon cache - stale phase data from previous zone/group
        if DF.WipePhasedCache then DF:WipePhasedCache() end

        -- Reset follower dungeon recheck state so retries work on each zone-in.
        -- Without this, exhausted retries from a previous dungeon prevent
        -- rechecks from ever running again.
        DF.followerRecheckCount = 0
        if followerRecheckTimer then
            followerRecheckTimer:Cancel()
            followerRecheckTimer = nil
        end
        
        -- ARENA FIX: Update header visibility BEFORE applying settings.
        -- Without this, entering arena leaves the arena header hidden and party header
        -- visible because ApplyHeaderSettings doesn't call UpdateHeaderVisibility.
        -- The addon relied on GROUP_ROSTER_UPDATE (queued to next frame) to fix this,
        -- but that creates a race with combat start at arena gates.
        DF:Debug("ROSTER", "PEW: calling UpdateHeaderVisibility()")
        DF:UpdateHeaderVisibility()
        DF:Debug("ROSTER", "PEW: UpdateHeaderVisibility() complete, calling ApplyHeaderSettings()")

        -- ARENA FIX: Reset stale sorting attributes on arena header.
        -- ApplyHeaderSettings calls ApplyPartyGroupSorting (party only), never ApplyArenaHeaderSorting.
        -- So the arena header retains the stale nameList from the PREVIOUS arena match.
        -- If the new arena has different players, SecureGroupHeaderTemplate can't match
        -- any names against the old nameList → shows zero frames.
        -- GROUP_ROSTER_UPDATE would eventually fix this via ProcessRosterUpdate →
        -- ApplyArenaHeaderSorting, but by then arena gates may have opened (combat lockdown)
        -- and ApplyArenaHeaderSorting bails → no frames for the entire match.
        -- Fix: Clear stale sorting and use INDEX ordering so frames show immediately.
        -- ProcessRosterUpdate will apply proper sorting once the roster is available.
        local contentType = DF:GetContentType()
        if contentType == "arena" and DF.arenaHeader and not InCombatLockdown() then
            DF.arenaHeader:SetAttribute("nameList", nil)
            DF.arenaHeader:SetAttribute("groupBy", nil)
            DF.arenaHeader:SetAttribute("groupingOrder", nil)
            DF.arenaHeader:SetAttribute("groupFilter", nil)
            DF.arenaHeader:SetAttribute("roleFilter", nil)
            DF.arenaHeader:SetAttribute("strictFiltering", nil)
            DF.arenaHeader:SetAttribute("sortMethod", "INDEX")
        end
        
        DF:ApplyHeaderSettings()
        DF:Debug("ROSTER", "PEW: ApplyHeaderSettings() complete")

        -- FIX: Rebuild unitFrameMap immediately after ApplyHeaderSettings.
        -- If sorting attributes haven't changed, OnAttributeChanged("unit") won't fire
        -- on header children, leaving unitFrameMap empty after the wipe above.
        -- Without this, all UNIT_HEALTH events are silently dropped until something
        -- else triggers OnAttributeChanged (e.g., a roster change).
        DF:RebuildUnitFrameMap()
        DF:Debug("ROSTER", "PEW: initial RebuildUnitFrameMap done, mapSize=%d", DF.unitFrameMap and DF:CountUnitFrameMap() or -1)
        
        -- Explicitly refresh all visible frames after a small delay
        -- This catches cases where unit attributes don't change but the player behind
        -- the unit ID has changed (WoW can reassign players without firing OnAttributeChanged)
        C_Timer.After(0.1, function()
            -- FIX: Rebuild map again in case header children became visible
            -- after the initial rebuild (SecureGroupHeaderTemplate may defer child Show)
            DF:Debug("ROSTER", "PEW +0.1s: rebuilding unitFrameMap, members=%d, GRUs so far=%d", GetNumGroupMembers(), gruEventCount)
            DF:RebuildUnitFrameMap()
            DF:Debug("ROSTER", "PEW +0.1s: mapSize=%d", DF.unitFrameMap and DF:CountUnitFrameMap() or -1)
            if DF.RefreshLiveFrames then
                DF:RefreshLiveFrames()
            end

            -- FOLLOWER DUNGEON FIX: PEW doesn't go through ProcessRosterUpdate,
            -- so the follower recheck in ProcessRosterUpdate may never trigger if
            -- GROUP_ROSTER_UPDATE fires before PEW (or doesn't fire at all).
            -- Schedule an independent recheck here so the party fills in even
            -- without a subsequent GROUP_ROSTER_UPDATE.
            if not IsInRaid() and IsInGroup() and GetNumGroupMembers() < 5 and not InCombatLockdown() then
                DF:Debug("ROSTER", "PEW: incomplete party (%d members), scheduling follower recheck", GetNumGroupMembers())
                -- Queue a roster update after a delay to give NPCs time to register
                C_Timer.After(FOLLOWER_RECHECK_DELAY, function()
                    if not InCombatLockdown() and IsInGroup() and GetNumGroupMembers() < 5 then
                        DF:Debug("ROSTER", "PEW follower recheck — group has %d members", GetNumGroupMembers())
                        rosterMembershipCache = {}
                        lastRosterCount = 0
                        QueueRosterUpdate()
                    end
                end)
            end
        end)

        -- BG SAFETY NET: In large BGs (40 players), SecureGroupHeaderTemplate
        -- may take >0.1s to show all children. The OnShow hook registers each
        -- child in unitFrameMap as it appears, but a second full rebuild +
        -- refresh ensures every frame has correct health data.
        if IsInRaid() then
            C_Timer.After(1.0, function()
                if InCombatLockdown() then
                    DF:Debug("ROSTER", "PEW +1.0s: skipped (combat lockdown)")
                    return
                end
                DF:Debug("ROSTER", "PEW +1.0s: rebuilding unitFrameMap, members=%d, GRUs so far=%d", GetNumGroupMembers(), gruEventCount)
                DF:RebuildUnitFrameMap()
                DF:Debug("ROSTER", "PEW +1.0s: mapSize=%d", DF.unitFrameMap and DF:CountUnitFrameMap() or -1)
                if DF.RefreshLiveFrames then
                    DF:RefreshLiveFrames()
                end
            end)
        end

        -- BUG #3 FIX: Delayed arena detection retry.
        -- On reload in arena, IsInInstance() may not return "arena" immediately when
        -- PLAYER_ENTERING_WORLD fires. This causes UpdateHeaderVisibility to show raid
        -- frames instead of the arena header. Schedule re-checks so that once WoW's
        -- instance detection catches up, we correct the header visibility.
        -- The arenaHeader:IsShown() guard prevents redundant work if arena was already
        -- detected correctly on the first pass.
        local function ArenaDetectionRetry()
            if not DF.headersInitialized then return end
            local ct = DF:GetContentType()
            if ct == "arena" and DF.arenaHeader and not DF.arenaHeader:IsShown() then
                if not InCombatLockdown() then
                    DF:UpdateHeaderVisibility()
                    -- Clear stale sorting on arena header (same as PEW arena fix above)
                    DF.arenaHeader:SetAttribute("nameList", nil)
                    DF.arenaHeader:SetAttribute("groupBy", nil)
                    DF.arenaHeader:SetAttribute("groupingOrder", nil)
                    DF.arenaHeader:SetAttribute("groupFilter", nil)
                    DF.arenaHeader:SetAttribute("roleFilter", nil)
                    DF.arenaHeader:SetAttribute("strictFiltering", nil)
                    DF.arenaHeader:SetAttribute("sortMethod", "INDEX")
                    DF:RebuildUnitFrameMap()
                    if DF.RefreshLiveFrames then
                        DF:RefreshLiveFrames()
                    end
                    -- Queue a roster update so arena sorting gets applied properly
                    QueueRosterUpdate()
                    headerDebug("Arena detection retry: corrected header visibility")
                else
                    -- In combat - defer everything
                    DF.pendingVisibilityUpdate = true
                    DF.pendingSortingUpdate = true
                end
            end
        end
        C_Timer.After(0.5, ArenaDetectionRetry)
        C_Timer.After(1.5, ArenaDetectionRetry)
        
        return
    end
end)

-- Separated roster update processing for debounce
-- #78: re-apply main-frame header sorting directly so the "Hide from Main Frames"
-- filter takes effect live (toggling the option, or a hiding set's membership
-- changing). Targeted re-filter — calls the sort functions straight, rather than the
-- roster-event-shaped ProcessRosterUpdate. Combat-gated (secure nameList writes are
-- illegal in combat; it re-applies on the next out-of-combat sort otherwise).
function DF:RefreshMainFrameSorting()
    if InCombatLockdown() then
        -- Don't drop the request: re-apply on the next out-of-combat sorting
        -- pass (same flag the roster events use) so a mid-combat hide toggle /
        -- membership change still lands without needing a roster change.
        DF.pendingSortingUpdate = true
        return
    end
    -- Route like ProcessRosterUpdate: arena frames are driven by the arena
    -- header (never the party/raid sorters), and the raid sorters only apply
    -- when actually in a raid — re-filtering all 8 hidden raid group headers
    -- from a 5-man (or Show()ing them in arena) is wasted churn at best.
    local contentType = DF.GetContentType and DF:GetContentType()
    if contentType == "arena" then return end
    if DF.ApplyPartyGroupSorting then DF:ApplyPartyGroupSorting() end
    if not IsInRaid() then return end
    local rdb = DF.GetRaidDB and DF:GetRaidDB()
    if rdb and rdb.raidUseGroups then
        if DF.ApplyRaidGroupSorting then DF:ApplyRaidGroupSorting() end
    elseif DF.ApplyRaidFlatSorting then
        DF:ApplyRaidFlatSorting()
    end
end

function DF:ProcessRosterUpdate()
    DF:RosterDebugEvent("Headers.lua:ProcessRosterUpdate")
    local numGroup = GetNumGroupMembers()
    local inRaid = IsInRaid()
    DF:Debug("ROSTER", "ProcessRosterUpdate: %d members, inRaid=%s", numGroup, tostring(inRaid))

    -- RAIDPOS diagnostic: capture container position state at the start of every
    -- roster processing pass so we can correlate "frames jumped" reports with the
    -- exact db values + auto-profile state at that moment.
    if DF.raidContainer and DF.Debug then
        local rdb = DF:GetRaidDB()
        local activeAuto = (DF.AutoProfilesUI and DF.AutoProfilesUI.activeRuntimeProfile
            and DF.AutoProfilesUI.activeRuntimeProfile.name) or "none"
        DF:Debug("RAIDPOS", "ProcessRosterUpdate ENTRY: members=%d inRaid=%s anchor=(%.1f,%.1f) scale=%.3f autoProfile=%s",
            numGroup, tostring(inRaid),
            rdb and rdb.raidAnchorX or 0, rdb and rdb.raidAnchorY or 0,
            rdb and rdb.frameScale or 1.0, activeAuto)
    end

    -- Clear range cache so stale unit→range mappings are flushed
    -- (moved here from Range.lua's own GROUP_ROSTER_UPDATE handler)
    if DF.ClearRangeCache then
        DF:ClearRangeCache()
    end

    -- Refresh leader/assist icons on every visible header child + pinned frame.
    -- WoW has no dedicated event for assist promotion/demotion — only
    -- GROUP_ROSTER_UPDATE fires. PARTY_LEADER_CHANGED covers most leader
    -- changes but its dedup + old/new-only update path can miss cases.
    -- UpdateLeaderIcon is cheap and self-gates on combat.
    if DF.UpdateLeaderIcon then
        local function refreshLeader(frame)
            if frame.dfIsHeaderChild and frame.unit then
                DF:UpdateLeaderIcon(frame)
            end
        end
        DF:IteratePartyFrames(refreshLeader)
        DF:IterateRaidFrames(refreshLeader)
        if IteratePinnedFrames then
            IteratePinnedFrames(function(frame)
                if frame.unit then
                    DF:UpdateLeaderIcon(frame)
                end
            end)
        end
    end

    -- Refresh names on every visible frame. UNIT_NAME_UPDATE is unreliable
    -- for cross-realm name resolution and can be silently dropped if
    -- unitFrameMap is briefly stale during a roster reshuffle — without
    -- this safety net, names can stay blank/stale (commonly after wipes).
    if DF.UpdateName then
        local function refreshName(frame)
            if frame.unit then
                DF:UpdateName(frame)
                -- TD mirrors this legacy safety net: refresh identity text on
                -- every roster change so TD names don't go stale/duplicate when
                -- the secure header reshuffles frames (the per-frame path misses some).
                if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "name") end
            end
        end
        DF:IteratePartyFrames(refreshName)
        DF:IterateRaidFrames(refreshName)
        if IteratePinnedFrames then
            IteratePinnedFrames(refreshName)
        end
    end

    local raidDb = DF:GetRaidDB()
    
    -- Check for arena first - arena uses arena header, not raid frames
    local contentType = DF:GetContentType()
    local inArena = (contentType == "arena")
    
    -- ARENA: Special handling - uses party settings but raid unit IDs
    if inArena then
        DF:Debug("ROSTER", "  Path: ARENA")
        -- Update visibility (shows arena header, hides party/raid)
        DF:UpdateHeaderVisibility()
        
        -- Arena sorting can't run during combat - queue for after
        if InCombatLockdown() then
            DF.pendingSortingUpdate = true
            headerDebug("Arena sorting update queued (combat lockdown)")
            return
        end
        
        -- Always apply arena sorting - it handles sortEnabled=false internally
        -- This ensures stale nameList/groupBy attributes are cleared when sorting is disabled
        if DF.arenaHeader then
            DF:ApplyArenaHeaderSorting()
        end
        
        return
    end
    
    -- RAID (not arena): Use flat layout handling
    if IsInRaid() and not raidDb.raidUseGroups then
        DF:Debug("ROSTER", "  Path: FLAT RAID")
        -- If in combat, queue refresh for after combat
        if InCombatLockdown() then
            DF:Debug("ROSTER", "  Deferred: combat lockdown (pendingFlatLayoutRefresh)")
            DF.pendingFlatLayoutRefresh = true
            return
        end

        -- Visibility update — skip grouped-raid reposition (flat raids don't use it)
        DF:UpdateHeaderVisibility(true)

        -- TEST 2: HasRosterMembershipChanged check - OK
        if not HasRosterMembershipChanged() then
            DF:Debug("ROSTER", "  Flat raid: roster unchanged, skipping sorting")
            -- FIX: Even though roster hasn't changed, unitFrameMap may be empty
            -- (e.g., after PLAYER_ENTERING_WORLD wiped it and OnAttributeChanged
            -- didn't fire because unit assignments are the same). Rebuild it.
            DF:RebuildUnitFrameMap()
            return
        end
        
        -- Always call flat raid sorting - it handles sortEnabled=false internally
        -- This ensures stale nameList/groupBy attributes are cleared when sorting is disabled
        DF:Debug("ROSTER", "  Flat raid: roster changed, applying sorting")
        DF:ApplyRaidFlatSorting()
        
        -- TEST 4: UpdateRestedIndicator - OK (group labels not needed for flat layout)
        if DF.UpdateRestedIndicator then
            DF:UpdateRestedIndicator()
        end
        
        -- TEST 5: UpdateDefaultPlayerFrame - OK
        if DF.UpdateDefaultPlayerFrame then
            DF:UpdateDefaultPlayerFrame()
        end
        
        return
    end
    
    -- Update visibility (handles raid<->party container switching)
    -- This is always needed as it's cheap and handles party<->raid switching
    -- Skip raid reposition here — sorting below will trigger its own authoritative
    -- reposition with correct group counts. Firing here with stale counts causes
    -- visible frame jumping.
    DF:Debug("ROSTER", "  Path: PARTY/GROUPED RAID (skipRaidReposition=true)")
    DF:UpdateHeaderVisibility(true)
    
    -- Update player group tracking for "Player's Group First" feature (raid only, not arena)
    if IsInRaid() and not inArena and raidDb.raidPlayerGroupFirst then
        DF:UpdatePlayerGroupTracking()
    end
    
    -- Detect flat→grouped transition: grouped headers may have zero children
    -- after flat mode cleared their attributes. Force sorting to repopulate them.
    local groupedHeadersEmpty = false
    if IsInRaid() and raidDb and raidDb.raidUseGroups and DF.raidPositionHandler then
        local totalCount = 0
        for i = 1, 8 do
            totalCount = totalCount + (DF.raidPositionHandler:GetAttribute("group" .. i .. "count") or 0)
        end
        if totalCount == 0 and GetNumGroupMembers() > 0 then
            groupedHeadersEmpty = true
            DF:Debug("ROSTER", "  Grouped headers empty despite active raid — forcing sort")
        end
    end

    -- Check if roster membership actually changed
    -- This prevents redundant sorting when GROUP_ROSTER_UPDATE fires multiple times
    -- with the same roster data
    if not groupedHeadersEmpty and not HasRosterMembershipChanged() then
        DF:Debug("ROSTER", "  Roster unchanged — skipping sorting, rebuilding unitFrameMap")
        -- Roster is identical - skip sorting
        -- Visibility update already handled above
        -- FIX: Rebuild unitFrameMap in case it was wiped (e.g., by PLAYER_ENTERING_WORLD)
        -- but OnAttributeChanged didn't fire because unit assignments are unchanged.
        DF:RebuildUnitFrameMap()
        -- Clear suppressreposition that was set by UpdateHeaderVisibility(true) above.
        -- Without this, suppress leaks and blocks all future repositioning until
        -- the next roster change that passes HasRosterMembershipChanged().
        if DF.raidPositionHandler then
            DF.raidPositionHandler:SetAttribute("suppressreposition", 0)
        end
        -- Always re-trigger positioning for grouped raids to ensure groups are
        -- correctly placed even when membership hasn't changed (e.g., WoW re-sorted
        -- children internally). TriggerRaidPosition is cheap and has a flat-mode guard.
        if IsInRaid() and raidDb and raidDb.raidUseGroups then
            DF:TriggerRaidPosition()
            -- Safety net: deferred child visibility may cause stale counts (#571)
            C_Timer.After(0.05, function()
                if not InCombatLockdown() then
                    DF:TriggerRaidPosition()
                end
            end)
        end
        return
    end

    DF:Debug("ROSTER", "  Roster CHANGED — applying sorting")
    -- Roster actually changed - apply sorting
    -- NOTE: Sorting functions can't run during combat (they modify secure header attributes)
    -- Queue for after combat if in combat lockdown
    if InCombatLockdown() then
        DF.pendingSortingUpdate = true
        headerDebug("Sorting update queued (combat lockdown)")
        return
    end
    
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    -- Always call party sorting - it handles sortEnabled=false internally
    -- This ensures stale nameList/groupBy attributes are cleared when sorting is disabled
    if DF.partyHeader then
        DF:ApplyPartyGroupSorting()
    end
    
    -- Raid sorting (not for arena)
    if IsInRaid() and not inArena then
        -- Always call raid sorting - it handles sortEnabled=false internally
        if raidDb.raidUseGroups then
            DF:Debug("ROSTER", "  Applying grouped raid sorting")
            DF:ApplyRaidGroupSorting()
        else
            DF:Debug("ROSTER", "  Applying flat raid sorting")
            DF:ApplyRaidFlatSorting()
        end
        
        -- NOTE: TriggerRaidPosition is NOT called here because ApplyRaidGroupSorting()
        -- already triggers it via UpdateRaidPositionAttributes(). Calling it again caused
        -- a double-reposition that made frames visually jump on roster changes.

        -- Update group labels (quick operation, safe anytime)
        if DF.UpdateRaidGroupLabels then
            C_Timer.After(0.1, function()
                if DF.UpdateRaidGroupLabels then
                    DF:UpdateRaidGroupLabels()
                end
            end)
        end
    end
    
    -- Update rested indicator (hide when in group)
    if DF.UpdateRestedIndicator then
        DF:UpdateRestedIndicator()
    end
    
    -- Update default player frame visibility
    if DF.UpdateDefaultPlayerFrame then
        DF:UpdateDefaultPlayerFrame()
    end
    
    -- Update pet frames (they don't receive GROUP_ROSTER_UPDATE directly)
    -- Only update if pet frames are enabled to avoid unnecessary work
    if db.petEnabled and DF.UpdateAllPetFrames then
        DF:UpdateAllPetFrames()
    end
    if raidDb.petEnabled and DF.UpdateAllRaidPetFrames then
        DF:UpdateAllRaidPetFrames()
    end

    -- Refresh summon icons on all frames — clears stale "Summon Pending" icons
    -- when leaving a group or entering an instance (M+ start, zone change)
    if DF.UpdateSummonIcon and DF.IterateAllFrames then
        DF:IterateAllFrames(function(frame)
            if frame and frame.unit then
                DF:UpdateSummonIcon(frame)
            end
        end)
        -- Also refresh pinned frames (not covered by IterateAllFrames)
        IteratePinnedFrames(function(frame)
            if frame and frame.unit then
                DF:UpdateSummonIcon(frame)
            end
        end)
    end

    -- ============================================================
    -- FOLLOWER DUNGEON RECHECK (#402)
    -- Follower NPCs register with the group system on a delay after
    -- zoning in. If the party looks incomplete, schedule a delayed
    -- recheck to pick up stragglers. No NPC check required — the
    -- 3-retry cap keeps this lightweight for normal undersized groups,
    -- and removing the gate prevents the chicken-and-egg case where
    -- no NPCs have registered yet so the recheck never triggers.
    -- ============================================================
    if not IsInRaid() and IsInGroup() then
        local groupSize = GetNumGroupMembers()
        if groupSize < 5 then
            -- Cancel any existing recheck timer
            if followerRecheckTimer then
                followerRecheckTimer:Cancel()
                followerRecheckTimer = nil
            end
            -- Track retry count
            local retryCount = (DF.followerRecheckCount or 0) + 1
            DF.followerRecheckCount = retryCount
            if retryCount <= FOLLOWER_RECHECK_MAX then
                followerRecheckTimer = C_Timer.NewTimer(FOLLOWER_RECHECK_DELAY, function()
                    followerRecheckTimer = nil
                    if not InCombatLockdown() and IsInGroup() and GetNumGroupMembers() < 5 then
                        DF:Debug("ROSTER", "Follower dungeon recheck %d/%d — group has %d members", retryCount, FOLLOWER_RECHECK_MAX, GetNumGroupMembers())
                        -- Force roster cache to see the change
                        rosterMembershipCache = {}
                        lastRosterCount = 0
                        QueueRosterUpdate()
                    end
                end)
            end
        else
            -- Full party — clear retry state
            DF.followerRecheckCount = 0
            if followerRecheckTimer then
                followerRecheckTimer:Cancel()
                followerRecheckTimer = nil
            end
        end
    end

    headerDebug("Roster update processed")
end

-- Cached role update
-- Only updates frames where the role actually changed
function DF:ProcessRoleUpdate()
    DF:RosterDebugEvent("Headers.lua:ProcessRoleUpdate")
    
    if not DF.UpdateRoleIcon then return end
    
    local function updateFrameRole(frame)
        if not frame.dfIsHeaderChild or not frame.unit or not frame:IsVisible() then
            return
        end
        
        local unit = frame.unit
        -- Must match what UpdateRoleIcon will DISPLAY, not the raw assignment --
        -- see the note on DF:GetRoleIconRole. Keyed on the raw value, this cache
        -- never fires inside a delve (the raw role stays "NONE" start to finish)
        -- and the icon never gets a chance to draw the spec-derived role.
        local newRole = DF:GetRoleIconRole(unit)
        local oldRole = unitRoleCache[unit]
        
        -- Only update if role actually changed (dirty-check pattern)
        if newRole ~= oldRole then
            unitRoleCache[unit] = newRole
            DF:UpdateRoleIcon(frame, "headerChild-cached")
            DF:RosterDebugCount("UpdateRoleIcon:ROLE_CHANGED")
        else
            DF:RosterDebugCount("UpdateRoleIcon:ROLE_SAME-skipped")
        end
    end
    
    DF:IteratePartyFrames(updateFrameRole)
    DF:IterateRaidFrames(updateFrameRole)
end

-- ========================================
-- CENTRAL EVENT HANDLER FOR HEADER CHILDREN
-- ========================================
-- GLOBAL EVENT HANDLER
-- ALL unit events are handled here using unitFrameMap for O(1) frame lookup.
-- This eliminates per-frame RegisterUnitEvent calls and the timing bugs
-- they caused on unit changes (missed events, stale health values).
-- ========================================
local headerChildEventFrame = CreateFrame("Frame")
-- Core unit events (formerly per-frame RegisterUnitEvent)
headerChildEventFrame:RegisterEvent("UNIT_HEALTH")
headerChildEventFrame:RegisterEvent("UNIT_MAXHEALTH")
headerChildEventFrame:RegisterEvent("UNIT_NAME_UPDATE")
headerChildEventFrame:RegisterEvent("UNIT_LEVEL")
headerChildEventFrame:RegisterEvent("UNIT_POWER_UPDATE")
headerChildEventFrame:RegisterEvent("UNIT_MAXPOWER")
headerChildEventFrame:RegisterEvent("UNIT_DISPLAYPOWER")
headerChildEventFrame:RegisterEvent("UNIT_CONNECTION")
-- Absorb/heal prediction events
headerChildEventFrame:RegisterEvent("UNIT_ABSORB_AMOUNT_CHANGED")
headerChildEventFrame:RegisterEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED")
headerChildEventFrame:RegisterEvent("UNIT_HEAL_PREDICTION")
-- Status icon events
headerChildEventFrame:RegisterEvent("INCOMING_SUMMON_CHANGED")
headerChildEventFrame:RegisterEvent("INCOMING_RESURRECT_CHANGED")
headerChildEventFrame:RegisterEvent("UNIT_PHASE")
headerChildEventFrame:RegisterEvent("UNIT_FLAGS")
headerChildEventFrame:RegisterEvent("UNIT_OTHER_PARTY_CHANGED")
headerChildEventFrame:RegisterEvent("UNIT_ENTERED_VEHICLE")
headerChildEventFrame:RegisterEvent("UNIT_EXITED_VEHICLE")
headerChildEventFrame:RegisterEvent("PLAYER_FLAGS_CHANGED")
-- Global events (no unit arg)
headerChildEventFrame:RegisterEvent("RAID_TARGET_UPDATE")
headerChildEventFrame:RegisterEvent("PLAYER_ROLES_ASSIGNED")
headerChildEventFrame:RegisterEvent("READY_CHECK")
headerChildEventFrame:RegisterEvent("READY_CHECK_CONFIRM")
headerChildEventFrame:RegisterEvent("READY_CHECK_FINISHED")
headerChildEventFrame:RegisterEvent("PARTY_LEADER_CHANGED")

-- Helper to iterate pinned frame children (forward-declared near file top)
-- ☠ BOTH POOLS. This walked player-set header children ONLY, so every caller silently
-- excluded pinned BOSS frames — which are real DF unit frames for friendly, healable
-- NPCs, not a special case. The visible cost was raid-target markers: put a skull on a
-- boss and the pinned frame kept the old icon until something else forced a
-- FullFrameRefresh, because RAID_TARGET_UPDATE routes through here. Its own neighbour
-- FindPinnedFrameForUnit has always walked bossFrames, so this was the odd one out.
-- ⚠ The other callers (ready check, leader, AFK, summon, player flags, the roster
-- name/leader safety net) are no-ops on an NPC rather than wrong — UnitIsPartyLeader and
-- friends simply answer false — so widening costs them nothing.
-- ★ PinnedFrames:ForEachActiveFrame is the same walk inside the pinned module; this one
-- exists separately because it supports EARLY EXIT (a truthy callback stops the sweep)
-- and that one does not. KEEP THEIR COVERAGE IDENTICAL.
IteratePinnedFrames = function(callback)
    if not DF.PinnedFrames or not DF.PinnedFrames.initialized then
        return
    end
    if DF.PinnedFrames.headers then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local header = DF.PinnedFrames.headers[setIndex]
            if header and header:IsShown() then
                for i = 1, 40 do
                    local child = header:GetAttribute("child" .. i)
                    if child and child:IsVisible() then
                        if callback(child) then return end
                    end
                end
            end
        end
    end
    if DF.PinnedFrames.bossFrames then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local frames = DF.PinnedFrames.bossFrames[setIndex]
            if frames then
                for i = 1, 8 do
                    local f = frames[i]
                    if f and f:IsShown() and f.unit then
                        if callback(f) then return end
                    end
                end
            end
        end
    end
end

-- Public alias so other files (e.g. the AFK timer ticker in StatusIcons.lua)
-- can tick pinned-frame children, which IterateAllFrames does not cover.
-- Call with a dot (DF.IteratePinnedFrames(cb)) — the function takes (callback).
DF.IteratePinnedFrames = IteratePinnedFrames

-- Helper to find pinned frame for a specific unit (player-mode or boss-mode set)
--
-- ⚠ HOT. Called from the UNIT_HEALTH / UNIT_POWER / UNIT_NAME_UPDATE /
-- UNIT_CONNECTION / UNIT_AURA handlers below, i.e. per unit event. It early-
-- outs cheaply when pinned frames are off or hidden, so only pinned users pay
-- the scan -- but for them it is up to 2x40 secure attribute reads per event.
-- CHILD_ATTR keeps the string cost out of it; replacing the scan itself with a
-- maintained pinned-unit map is the real fix and is on the Perfy list, because
-- the invalidation (frames re-slot on roster change) needs in-game validation.
local CHILD_ATTR = DF.CHILD_ATTR
local function FindPinnedFrameForUnit(unit)
    if not DF.PinnedFrames or not DF.PinnedFrames.initialized then
        return nil
    end
    -- Player-mode pinned sets: iterate header children
    if DF.PinnedFrames.headers then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local header = DF.PinnedFrames.headers[setIndex]
            if header and header:IsShown() then
                for i = 1, 40 do
                    local child = header:GetAttribute(CHILD_ATTR[i])
                    if child and child:IsVisible() and child.unit == unit then
                        return child
                    end
                end
            end
        end
    end
    -- Boss-mode pinned sets: iterate standalone boss frames
    if DF.PinnedFrames.bossFrames then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local frames = DF.PinnedFrames.bossFrames[setIndex]
            if frames then
                for i = 1, 8 do
                    local f = frames[i]
                    if f and f:IsVisible() and f.unit == unit then
                        return f
                    end
                end
            end
        end
    end
    return nil
end

-- TextDesigner live-text refresh helper. No-op unless the TD module loaded
-- (alpha builds only — DF.UpdateTextDesigner is nil otherwise). Driven from
-- the central dispatcher rather than from each update function's tail, so the
-- refresh fires once per event regardless of which fast/slow internal path the
-- update function took (the big bar functions have fast-path early returns that
-- a tail hook would miss, leaving text stale in combat).
local function tdRefresh(frame, pinnedFrame, hint)
    if not DF.UpdateTextDesigner then return end
    if frame then DF:UpdateTextDesigner(frame, hint) end
    if pinnedFrame then DF:UpdateTextDesigner(pinnedFrame, hint) end
end

headerChildEventFrame:SetScript("OnEvent", function(self, event, arg1)
    -- Skip if headers not initialized
    if not DF.headersInitialized then return end
    
    -- ========================================
    -- UNIT-SPECIFIC EVENTS (high frequency, checked first)
    -- O(1) lookup via unitFrameMap, skip if frame disabled/hidden
    -- ========================================
    
    -- UNIT_HEALTH / UNIT_MAXHEALTH: Update health bar
    if event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        local unit = arg1
        if unit then
            local frame = unitFrameMap[unit]
            
            -- SELF-HEALING: If the map lookup fails for a raid/party unit,
            -- the map may be stale (e.g., after a zone transition where
            -- OnAttributeChanged didn't fire).  Rebuild and retry once.
            -- Throttled: only attempt one rebuild per second to avoid
            -- burning CPU on events for units we genuinely don't track.
            if not frame and (unit:match("^raid%d") or unit:match("^party%d") or unit == "player") then
                local now = GetTime()
                if not DF.lastMapRebuild or (now - DF.lastMapRebuild) > 1.0 then
                    DF.lastMapRebuild = now
                    DF:RebuildUnitFrameMap()
                    frame = unitFrameMap[unit]
                end
            end
            
            if frame and frame.dfEventsEnabled ~= false then
                if DF.UpdateHealthFast then
                    DF:UpdateHealthFast(frame)
                end
            end
            local pinnedFrame = FindPinnedFrameForUnit(unit)
            if pinnedFrame and pinnedFrame.dfEventsEnabled ~= false then
                if DF.UpdateHealthFast then
                    DF:UpdateHealthFast(pinnedFrame)
                end
            end
            tdRefresh(frame, pinnedFrame, "health")
        end
        return
    end
    
    -- NOTE: UNIT_AURA is no longer handled here — see externalDefSubscriber
    -- below, which subscribes to the roster unit event dispatcher. UpdateAuras
    -- and UpdateDispelOverlay are driven by hooksecurefunc on
    -- CompactUnitFrame_UpdateAuras (Auras.lua) to ensure fresh cache data.

    -- UNIT_POWER_UPDATE / UNIT_MAXPOWER / UNIT_DISPLAYPOWER: Update power bar
    if event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER" or event == "UNIT_DISPLAYPOWER" then
        local unit = arg1
        if unit then
            local frame = unitFrameMap[unit]
            if frame and frame.dfEventsEnabled ~= false then
                if DF.UpdatePower then
                    DF:UpdatePower(frame)
                end
            end
            local pinnedFrame = FindPinnedFrameForUnit(unit)
            if pinnedFrame and pinnedFrame.dfEventsEnabled ~= false then
                if DF.UpdatePower then
                    DF:UpdatePower(pinnedFrame)
                end
            end
            tdRefresh(frame, pinnedFrame, "power")
        end
        return
    end
    
    -- UNIT_NAME_UPDATE: Update name text
    if event == "UNIT_NAME_UPDATE" then
        local unit = arg1
        if unit then
            local frame = unitFrameMap[unit]

            -- SELF-HEALING: If the map lookup fails for a raid/party unit,
            -- the map may be stale (e.g., after a roster reshuffle where
            -- OnAttributeChanged's deferred callback hasn't run yet).
            -- Without this, UNIT_NAME_UPDATE is silently dropped and the
            -- name stays blank/stale — a common symptom after wipes when
            -- the secure header reshuffles units. Same throttled rebuild
            -- pattern as UNIT_HEALTH and UNIT_CONNECTION above.
            if not frame and (unit:match("^raid%d") or unit:match("^party%d") or unit == "player") then
                local now = GetTime()
                if not DF.lastMapRebuild or (now - DF.lastMapRebuild) > 1.0 then
                    DF.lastMapRebuild = now
                    DF:RebuildUnitFrameMap()
                    frame = unitFrameMap[unit]
                end
            end

            if frame and frame.dfEventsEnabled ~= false then
                if DF.UpdateName then
                    DF:UpdateName(frame)
                end
            end
            local pinnedFrame = FindPinnedFrameForUnit(unit)
            if pinnedFrame and pinnedFrame.dfEventsEnabled ~= false then
                if DF.UpdateName then
                    DF:UpdateName(pinnedFrame)
                end
            end
            tdRefresh(frame, pinnedFrame, "name")

            -- Arena: the resolving name may be the one that made the last
            -- arena nameList build incomplete (the member was shown unsorted
            -- via INDEX instead of being filtered out) — nudge the re-sort.
            -- Gated on the incomplete flag so a fully-sorted header doesn't
            -- churn on routine name updates.
            if arenaNameListIncomplete and unit:match("^raid%d")
                and DF.GetContentType and DF:GetContentType() == "arena" then
                -- A real name-resolution signal: re-arm the safety cap so a
                -- player who loads in slower than the retry window (~12s)
                -- still gets re-sorted instead of staying in INDEX order.
                arenaSortRetryCount = 0
                ScheduleArenaSortRetry()
            end
        end
        return
    end

    -- UNIT_LEVEL: refresh TextDesigner identity text (the "level" element).
    -- TD-only — the legacy frames don't show a live level, so there's no
    -- existing update function to call here. No-op without the TD module.
    if event == "UNIT_LEVEL" then
        local unit = arg1
        if unit and DF.UpdateTextDesigner then
            tdRefresh(unitFrameMap[unit], FindPinnedFrameForUnit(unit), "name")
        end
        return
    end
    
    -- UNIT_CONNECTION: Full frame update (handles offline state)
    if event == "UNIT_CONNECTION" then
        local unit = arg1
        if unit then
            local frame = unitFrameMap[unit]

            -- SELF-HEALING: Same pattern as UNIT_HEALTH - rebuild map on miss.
            -- A missed UNIT_CONNECTION event directly causes "shows offline when
            -- online" or vice versa.
            if not frame and (unit:match("^raid%d") or unit:match("^party%d") or unit == "player") then
                local now = GetTime()
                if not DF.lastMapRebuild or (now - DF.lastMapRebuild) > 1.0 then
                    DF.lastMapRebuild = now
                    DF:RebuildUnitFrameMap()
                    frame = unitFrameMap[unit]
                end
            end

            if frame and frame.dfEventsEnabled ~= false then
                if DF.UpdateUnitFrame then
                    DF:UpdateUnitFrame(frame)
                end
            end
            local pinnedFrame = FindPinnedFrameForUnit(unit)
            if pinnedFrame and pinnedFrame.dfEventsEnabled ~= false then
                if DF.UpdateUnitFrame then
                    DF:UpdateUnitFrame(pinnedFrame)
                end
            end

            -- TD: UpdateUnitFrame early-returns on the offline branch before the
            -- TD "all" hook, so refresh TD directly here. "all" because a
            -- connection change flips status text + health/power value hiding.
            tdRefresh(frame, pinnedFrame, "all")

            -- Delayed re-check: UnitIsConnected may not return the updated
            -- state immediately, and the map rebuild throttle (1s) can cause
            -- the reconnect event to miss. Schedule a follow-up that bypasses
            -- the throttle and verifies the visual state matches reality. (#275)
            C_Timer.After(0.5, function()
                if not UnitExists(unit) then return end
                local isConnected = UnitIsConnected(unit)
                local isDead = UnitIsDead(unit) or UnitIsGhost(unit)

                local recheckFrame = unitFrameMap[unit]
                -- Bypass throttle: rebuild map if frame still missing
                if not recheckFrame then
                    DF:RebuildUnitFrameMap()
                    recheckFrame = unitFrameMap[unit]
                end
                if recheckFrame and recheckFrame.dfEventsEnabled ~= false then
                    -- Stale state: frame's tracked connection state doesn't match reality.
                    -- Uses dfLastKnownConnected instead of dfDeadFadeApplied so it works
                    -- even when fadeDeadFrames is disabled. (#570)
                    local frameThinks = recheckFrame.dfLastKnownConnected
                    local stale = (frameThinks == nil) or (isConnected ~= frameThinks)
                    if stale and DF.UpdateUnitFrame then
                        DF:UpdateUnitFrame(recheckFrame)
                        if DF.UpdateTextDesigner then DF:UpdateTextDesigner(recheckFrame, "all") end
                    end
                end
                -- Also re-check pinned frame
                local recheckPinned = FindPinnedFrameForUnit(unit)
                if recheckPinned and recheckPinned.dfEventsEnabled ~= false then
                    local frameThinks = recheckPinned.dfLastKnownConnected
                    local stale = (frameThinks == nil) or (isConnected ~= frameThinks)
                    if stale and DF.UpdateUnitFrame then
                        DF:UpdateUnitFrame(recheckPinned)
                        if DF.UpdateTextDesigner then DF:UpdateTextDesigner(recheckPinned, "all") end
                    end
                end
            end)
        end
        return
    end
    
    -- ========================================
    -- EXISTING UNIT-SPECIFIC EVENTS (absorb, heal prediction, status icons)
    -- ========================================
    
    -- RAID_TARGET_UPDATE: Update raid target icons on all frames
    if event == "RAID_TARGET_UPDATE" then
        if DF.UpdateRaidTargetIcon then
            DF:IteratePartyFrames(function(frame)
                if frame.dfIsHeaderChild then
                    DF:UpdateRaidTargetIcon(frame)
                end
            end)
            DF:IterateRaidFrames(function(frame)
                if frame.dfIsHeaderChild then
                    DF:UpdateRaidTargetIcon(frame)
                end
            end)
            -- Also update pinned frames
            IteratePinnedFrames(function(frame)
                DF:UpdateRaidTargetIcon(frame)
            end)
        end
        return
    end
    
    -- PLAYER_ROLES_ASSIGNED: Update role icons on all frames
    -- Frame-based throttling with role caching
    if event == "PLAYER_ROLES_ASSIGNED" then
        DF:RosterDebugEvent("Headers.lua:PLAYER_ROLES_ASSIGNED")
        QueueRoleUpdate()  -- Will call ProcessRoleUpdate on next frame
        return
    end
    
    -- READY_CHECK events: Update ready check icons
    if event == "READY_CHECK" or event == "READY_CHECK_CONFIRM" then
        if DF.UpdateReadyCheckIcon then
            DF:IteratePartyFrames(function(frame)
                if frame.dfIsHeaderChild then
                    DF:UpdateReadyCheckIcon(frame)
                end
            end)
            DF:IterateRaidFrames(function(frame)
                if frame.dfIsHeaderChild then
                    DF:UpdateReadyCheckIcon(frame)
                end
            end)
            -- Also update pinned frames
            IteratePinnedFrames(function(frame)
                DF:UpdateReadyCheckIcon(frame)
            end)
        end
        return
    end
    
    if event == "READY_CHECK_FINISHED" then
        if DF.ScheduleReadyCheckHide then
            DF:IteratePartyFrames(function(frame)
                if frame.dfIsHeaderChild then
                    DF:ScheduleReadyCheckHide(frame)
                end
            end)
            DF:IterateRaidFrames(function(frame)
                if frame.dfIsHeaderChild then
                    DF:ScheduleReadyCheckHide(frame)
                end
            end)
            -- Also update pinned frames
            IteratePinnedFrames(function(frame)
                DF:ScheduleReadyCheckHide(frame)
            end)
        end
        return
    end
    
    -- PARTY_LEADER_CHANGED: Update leader icons
    -- Only update the old and new leader frames, not all frames
    if event == "PARTY_LEADER_CHANGED" then
        if DF.UpdateLeaderIcon then
            -- Find the new leader
            local newLeader = nil
            local function findLeader(frame)
                if frame.dfIsHeaderChild and frame.unit and UnitIsGroupLeader(frame.unit) then
                    newLeader = frame.unit
                    return true  -- Stop iterating
                end
            end
            DF:IteratePartyFrames(findLeader)
            if not newLeader then
                DF:IterateRaidFrames(findLeader)
            end
            
            -- Only update frames if leader actually changed
            local oldLeader = unitLeaderCache
            if newLeader ~= oldLeader then
                unitLeaderCache = newLeader
                
                -- Update only the old and new leader frames, or all if cache was empty
                local function updateIfLeader(frame)
                    if frame.dfIsHeaderChild and frame.unit then
                        if not oldLeader or frame.unit == oldLeader or frame.unit == newLeader then
                            DF:UpdateLeaderIcon(frame)
                        end
                    end
                end
                DF:IteratePartyFrames(updateIfLeader)
                DF:IterateRaidFrames(updateIfLeader)
                -- Also update pinned frames showing old/new leader
                IteratePinnedFrames(function(frame)
                    if not oldLeader or frame.unit == oldLeader or frame.unit == newLeader then
                        DF:UpdateLeaderIcon(frame)
                    end
                end)
            end
        end
        
        -- BUG #8 FIX: Trigger roster update to refresh positions and unit mappings.
        -- WoW doesn't always fire GROUP_ROSTER_UPDATE on leader changes, which can
        -- leave unitFrameMap stale (raid indices may shuffle on promotion).
        -- QueueRosterUpdate coalesces with any concurrent GRU into a single ProcessRosterUpdate.
        if not InCombatLockdown() then
            QueueRosterUpdate()
        else
            DF.pendingHeaderSettingsApply = true
        end
        return
    end
    
    -- UNIT_ABSORB_AMOUNT_CHANGED: Update absorb bar for specific unit
    if event == "UNIT_ABSORB_AMOUNT_CHANGED" then
        local unit = arg1
        if unit and DF.UpdateAbsorb then
            local frame = unitFrameMap[unit]
            if frame and frame.dfEventsEnabled ~= false then
                DF:UpdateAbsorb(frame)
            end
            -- Also update pinned frame showing this unit
            local pinnedFrame = FindPinnedFrameForUnit(unit)
            if pinnedFrame then
                DF:UpdateAbsorb(pinnedFrame)
            end
            tdRefresh(frame, pinnedFrame, "absorb")
        end
        return
    end
    
    -- UNIT_HEAL_ABSORB_AMOUNT_CHANGED: Update heal absorb bar for specific unit
    if event == "UNIT_HEAL_ABSORB_AMOUNT_CHANGED" then
        local unit = arg1
        if unit and DF.UpdateHealAbsorb then
            local frame = unitFrameMap[unit]
            if frame and frame.dfEventsEnabled ~= false then
                DF:UpdateHealAbsorb(frame)
            end
            local pinnedFrame = FindPinnedFrameForUnit(unit)
            if pinnedFrame then
                DF:UpdateHealAbsorb(pinnedFrame)
            end
            tdRefresh(frame, pinnedFrame, "absorb")
        end
        return
    end
    
    -- UNIT_HEAL_PREDICTION: Update heal prediction for specific unit
    if event == "UNIT_HEAL_PREDICTION" then
        local unit = arg1
        if unit and DF.UpdateHealPrediction then
            local frame = unitFrameMap[unit]
            if frame and frame.dfEventsEnabled ~= false then
                DF:UpdateHealPrediction(frame)
            end
            -- Also update pinned frame showing this unit
            local pinnedFrame = FindPinnedFrameForUnit(unit)
            if pinnedFrame then
                DF:UpdateHealPrediction(pinnedFrame)
            end
            tdRefresh(frame, pinnedFrame, "heal")
        end
        return
    end
    
    -- INCOMING_SUMMON_CHANGED: Update summon icon
    if event == "INCOMING_SUMMON_CHANGED" then
        local unit = arg1
        if unit then
            local frame = unitFrameMap[unit]
            if frame and frame.dfEventsEnabled ~= false then
                if DF.UpdateSummonIcon then DF:UpdateSummonIcon(frame) end
                if DF.UpdateCenterStatusIcon then DF:UpdateCenterStatusIcon(frame) end  -- Backward compat
            end
            local pinnedFrame = FindPinnedFrameForUnit(unit)
            if pinnedFrame then
                if DF.UpdateSummonIcon then DF:UpdateSummonIcon(pinnedFrame) end
                if DF.UpdateCenterStatusIcon then DF:UpdateCenterStatusIcon(pinnedFrame) end
            end
        end
        return
    end
    
    -- INCOMING_RESURRECT_CHANGED: Update resurrection icon
    if event == "INCOMING_RESURRECT_CHANGED" then
        local unit = arg1
        if unit then
            local frame = unitFrameMap[unit]
            if frame and frame.dfEventsEnabled ~= false then
                if DF.UpdateResurrectionIcon then DF:UpdateResurrectionIcon(frame) end
            end
            local pinnedFrame = FindPinnedFrameForUnit(unit)
            if pinnedFrame then
                if DF.UpdateResurrectionIcon then DF:UpdateResurrectionIcon(pinnedFrame) end
            end
        end
        return
    end
    
    -- UNIT_PHASE / UNIT_FLAGS / UNIT_OTHER_PARTY_CHANGED: Update phased icon (cache-aware)
    if event == "UNIT_PHASE" or event == "UNIT_FLAGS" or event == "UNIT_OTHER_PARTY_CHANGED" then
        local unit = arg1
        -- Combat flag can flip on UNIT_FLAGS — refresh this unit's combat icon
        if event == "UNIT_FLAGS" and unit and DF.UpdateCombatIcon then
            local cFrame = DF.unitFrameMap and DF.unitFrameMap[unit]
            if cFrame then DF:UpdateCombatIcon(cFrame) end
        end
        if unit and DF.UpdatePhasedCacheForUnit then
            -- Update cache and main frame (only refreshes icon if cache value changed)
            DF:UpdatePhasedCacheForUnit(unit)
            -- Pinned frames share the same unit — cache is already updated,
            -- just refresh their icon visuals
            local pinnedFrame = FindPinnedFrameForUnit(unit)
            if pinnedFrame and DF.UpdatePhasedIcon then
                DF:UpdatePhasedIcon(pinnedFrame)
            end
        end
        return
    end
    
    -- UNIT_ENTERED_VEHICLE / UNIT_EXITED_VEHICLE: Update vehicle icon + invalidate aura cache
    if event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" then
        local unit = arg1
        if unit then
            if DF.UpdateVehicleIcon then
                local frame = unitFrameMap[unit]
                if frame and frame.dfEventsEnabled ~= false then
                    DF:UpdateVehicleIcon(frame)
                    -- Re-process auras with fresh cache
                    if DF.UpdateAuras_Enhanced then DF:UpdateAuras_Enhanced(frame) end
                    if DF.UpdateDefensiveBar then DF:UpdateDefensiveBar(frame) end
                    -- Refresh name — UNIT_NAME_UPDATE isn't guaranteed to fire
                    -- before this handler, so the vehicle name can stick.
                    -- NOTE: If more frame elements get stuck after vehicle swaps
                    -- (role icon, power bar type, etc.), consider a broader refresh here.
                    if DF.UpdateName then DF:UpdateName(frame) end
                    if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "name") end
                end
                local pinnedFrame = FindPinnedFrameForUnit(unit)
                if pinnedFrame then
                    DF:UpdateVehicleIcon(pinnedFrame)
                    if DF.UpdateAuras_Enhanced then DF:UpdateAuras_Enhanced(pinnedFrame) end
                    if DF.UpdateDefensiveBar then DF:UpdateDefensiveBar(pinnedFrame) end
                    if DF.UpdateName then DF:UpdateName(pinnedFrame) end
                    if DF.UpdateTextDesigner then DF:UpdateTextDesigner(pinnedFrame, "name") end
                end
            end
        end
        return
    end
    
    -- PLAYER_FLAGS_CHANGED: Update AFK icon
    if event == "PLAYER_FLAGS_CHANGED" then
        local unit = arg1
        if unit and DF.UpdateAFKIcon then
            local frame = unitFrameMap[unit]
            if frame and frame.dfEventsEnabled ~= false then
                DF:UpdateAFKIcon(frame)
            end
            -- Update AFK on EVERY pinned frame, not just FindPinnedFrameForUnit's
            -- single match: that lookup can miss (pinned child's unit token may
            -- differ from the event's, or not match at this instant), leaving the
            -- icon to appear only on a later full refresh — the "doesn't show
            -- instantly" bug. Pinned frames are few; UpdateAFKIcon is a cheap
            -- GUID-cache read, and each frame reflects its own unit's state.
            IteratePinnedFrames(function(pf)
                DF:UpdateAFKIcon(pf)
            end)
        end
        return
    end
end)

-- ========================================
-- UNIT_AURA — routed through the roster unit event dispatcher
-- ========================================
-- The external defensive icon listens for UNIT_AURA on roster units only.
-- The dispatcher (RosterEvents.lua) uses RegisterUnitEvent at the C++ level
-- so this only fires for player/partyN/raidN — never nameplates, target,
-- focus, mouseover, or any other unit token. UpdateAuras and
-- UpdateDispelOverlay are still driven by hooksecurefunc on
-- CompactUnitFrame_UpdateAuras (Auras.lua) for cache freshness, so this
-- subscriber's only job is to drive UpdateExternalDefIcon.
local externalDefSubscriber = {}
function externalDefSubscriber:OnUnitAura(event, unit)
    if not DF.headersInitialized then return end
    if not unit then return end

    local frame = unitFrameMap[unit]
    if frame and frame.dfEventsEnabled ~= false then
        if DF.UpdateExternalDefIcon then
            DF:UpdateExternalDefIcon(frame)
        end
    end
    local pinnedFrame = FindPinnedFrameForUnit(unit)
    if pinnedFrame and pinnedFrame.dfEventsEnabled ~= false then
        if DF.UpdateExternalDefIcon then
            DF:UpdateExternalDefIcon(pinnedFrame)
        end
    end
    -- TD: feign-death status_text changes show up as auras (UnitIsFeignDeath),
    -- so refresh status text (under the "health" hint) on aura updates.
    tdRefresh(frame, pinnedFrame, "health")
end
DF:RegisterRosterUnitEvent(externalDefSubscriber, "UNIT_AURA", "OnUnitAura")

-- Slash command for debug.
-- ☠ SPLIT AUDIENCE, DELIBERATELY. The command stays NON-dev because the bare dump
-- is the single most paste-able thing in the addon: headersCreated / initialized /
-- partyChildrenHooked, container visible-or-hidden, and the sort settings are
-- exactly what we need from a user reporting "my frames aren't showing" or
-- "raid frames are in the wrong order". Gating it would mean we could not ask.
--
-- The MUTATING subcommands are dev-only, because they do not report anything —
-- they rewrite secure header state. A user poking them mid-diagnosis changes the
-- symptom we are trying to read, and then reports the new one. See MUTATORS below.
DF:RegisterDebugSlash("DFHEADERS", "Secure header state dump: [cmd] for a subcommand", false, "/dfheaders")

-- Subcommands that WRITE. Everything not listed here only reads.
local HEADER_MUTATORS = {
    init = true, refresh = true, apply = true, sort = true,
    horizontal = true, h = true, vertical = true, v = true,
    grow = true, center = true, self = true, selfpos = true,
}

SlashCmdList["DFHEADERS"] = function(msg)
    local args = {}
    for word in msg:gmatch("%S+") do
        table.insert(args, word:lower())
    end
    local cmd = args[1] or ""

    if HEADER_MUTATORS[cmd] and not DF:IsDevBuild() then
        local o = DF:Out("Headers", "'" .. cmd .. "' is a dev-build command")
        o:Line("It rewrites secure header state rather than reporting it, so it is not available on a release build.", "NEUTRAL")
        o:Line("The read-only views are:", "NEUTRAL")
        o:Item("(no argument) or info", "full state dump")
        o:Item("map", "unit-to-frame map")
        o:Hints("/df debug headers", "/df debug headers map")
        return
    end

    if cmd == "debug" then
        DF:Say("Header tracing moved to the debug console — enable the HEADERS category there.")

    elseif cmd == "init" then
        DF:CreateHeaderFrames()
        C_Timer.After(0.2, function()
            DF:FinalizeHeaderInit()
        end)
    
    elseif cmd == "refresh" or cmd == "apply" then
        DF:ApplyHeaderSettings()
        DF:Say("Settings applied from DB")
    
    -- Sorting commands
    elseif cmd == "sort" then
        local sortType = args[2]
        if sortType == "role" then
            DF:SetSortByRole()
        elseif sortType == "name" then
            DF:SetSortByName()
        elseif sortType == "index" then
            DF:SetSortByIndex()
        elseif sortType == "group" then
            DF:SetSortByGroup()
        else
            DF:Say("Sort options: role, name, index, group")
        end
    
    -- Orientation commands
    elseif cmd == "horizontal" or cmd == "h" then
        local db = DF:GetDB()
        local raidDb = DF:GetRaidDB()
        local growFrom = db.growthAnchor or "START"
        local selfPos = db.sortSelfPosition or "FIRST"
        -- Use correct anchor based on raid layout mode
        local raidGrowFrom = raidDb.raidUseGroups and (raidDb.raidGroupAnchor or "START") or (raidDb.raidFlatFrameAnchor or "START")
        DF:SetPartyOrientation(true, growFrom, selfPos)
        DF:SetRaidOrientation(true, raidGrowFrom)
    
    elseif cmd == "vertical" or cmd == "v" then
        local db = DF:GetDB()
        local raidDb = DF:GetRaidDB()
        local growFrom = db.growthAnchor or "START"
        local selfPos = db.sortSelfPosition or "FIRST"
        -- Use correct anchor based on raid layout mode
        local raidGrowFrom = raidDb.raidUseGroups and (raidDb.raidGroupAnchor or "START") or (raidDb.raidFlatFrameAnchor or "START")
        DF:SetPartyOrientation(false, growFrom, selfPos)
        DF:SetRaidOrientation(false, raidGrowFrom)
    
    -- Phase 3: Grow from anchor (start/center/end)
    elseif cmd == "grow" then
        local mode = args[2] and args[2]:upper() or "START"
        if mode == "START" or mode == "CENTER" or mode == "END" then
            local db = DF:GetDB()
            local horizontal = (db.growDirection == "HORIZONTAL")
            local selfPos = db.sortSelfPosition or "FIRST"
            DF:SetPartyOrientation(horizontal, mode, selfPos)
            -- Also apply to raid (for testing)
            local raidDb = DF:GetRaidDB()
            local raidHorizontal = (raidDb.growDirection == "HORIZONTAL")
            DF:SetRaidOrientation(raidHorizontal, mode)
            DF:Say("Grow from", mode, "NEUTRAL")
        else
            DF:Say("Grow options: start, center, end")
        end
    
    -- Legacy center command (shortcut for grow center)
    elseif cmd == "center" then
        local db = DF:GetDB()
        local horizontal = (db.growDirection == "HORIZONTAL")
        local selfPos = db.sortSelfPosition or "FIRST"
        if args[2] == "off" then
            DF:SetPartyOrientation(horizontal, "START", selfPos)
            DF:Say("Grow from: START")
        else
            DF:SetPartyOrientation(horizontal, "CENTER", selfPos)
            DF:Say("Grow from: CENTER")
        end
    
    -- Self position (first/last/sorted)
    elseif cmd == "self" or cmd == "selfpos" then
        local mode = args[2] and args[2]:upper() or "FIRST"
        if mode == "FIRST" or mode == "LAST" or mode == "SORTED" then
            local db = DF:GetDB()
            local horizontal = (db.growDirection == "HORIZONTAL")
            local growFrom = db.growthAnchor or "START"
            DF:SetPartyOrientation(horizontal, growFrom, mode)
            DF:Say("Self position", mode, "NEUTRAL")
        else
            DF:Say("Self options: first, last, sorted")
        end
    
    elseif cmd == "info" or cmd == "" then
        DF:DumpHeaderInfo()
    
    elseif cmd == "map" then
        -- Dump unitFrameMap for debugging the O(1) lookup table
        local count = 0
        DF:Say("unitFrameMap contents:")
        for unit, frame in pairs(unitFrameMap) do
            local name = frame.unit and UnitName(frame.unit) or "?"
            local visible = frame:IsShown() and "shown" or "hidden"
            print("  " .. unit .. " => " .. (frame:GetName() or tostring(frame)) .. " (" .. name .. ", " .. visible .. ")")
            count = count + 1
        end
        print("  Total entries: " .. count)
    
    else
        local o = DF:Out("Headers")
        o:Section("Read-only")
        o:Item("(no argument) or info", "full state dump")
        o:Item("map", "unit-to-frame map (the O(1) lookup table)")
        o:Item("debug", "where header tracing went")
        -- The writing half is only listed on a dev build, to match the gate at
        -- the top of this handler. Listing commands a release build refuses is
        -- the same drift that put everyday commands in /df debug.
        if DF:IsDevBuild() then
            o:Section("Rewrites secure state", "dev builds only")
            o:Item("init", "create and initialise headers")
            o:Item("refresh / apply", "re-apply settings from the DB")
            o:Item("sort role|name|index|group", "change the sort")
            o:Item("horizontal / vertical", "change growth axis")
            o:Item("grow start|center|end", "change growth origin")
            o:Item("self first|last|sorted", "change the player position")
        end
        o:Siblings("headers")
    end
end
