local addonName, DF = ...

-- ============================================================
-- FRAME SORTING SYSTEM
-- Sorts party/raid frames by role and name
-- ============================================================

-- Local caching of frequently used globals for performance
local ipairs, wipe = ipairs, wipe
local sort = table.sort
local tinsert = table.insert
local UnitExists = UnitExists
local UnitGUID = UnitGUID
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UnitClass = UnitClass
local issecretvalue = issecretvalue or function() return false end

-- A unit's GUID can be a SECRET value in 12.0 (e.g. M+ encounters) and a secret
-- cannot be used as a table key — doing so throws "cannot be indexed with secret
-- keys". Fall back to the unit token (always a plain string) when the GUID isn't
-- accessible so cache lookups never crash.
local issecretvalue = issecretvalue or function() return false end
local function canaccessvalue(v)
    return v ~= nil and not issecretvalue(v)
end

-- NOTE: Previously used reusable tables here, but that caused bugs when
-- SortFrameList was called while iterating over a previous result.
-- Now we return fresh tables each time. The garbage is minimal.

DF.Sort = {}
local Sort = DF.Sort

-- Spec to role mapping (melee vs ranged DPS)
-- This maps DPS spec IDs to whether they're melee
-- Tank/healer specs are excluded - they're filtered by role before this check
-- ★ ONE SHARED TABLE (Core/Config.lua). This was a local copy; the header there
-- records the three-way disagreement between this file, Headers.lua and
-- FlatRaidFrames.lua that it caused.
local MELEE_SPECS = DF.MELEE_SPECS

-- Cache for unit info (cleared on group changes)
Sort.UnitCache = {}

-- ============================================================
-- ROLE DETECTION
-- ============================================================

-- Get the role for a unit (TANK, HEALER, MELEE, RANGED, or DAMAGER)
-- ⚠ PREVIEW-ONLY COMPARATOR PATH. Live party/raid ordering is decided by the
-- SECURE SNIPPET's roleFilter (Features/SecureSort.lua), not by this file: every
-- caller of SortFrameList passes isTestMode = true. So this Lua comparator exists
-- to make the preview show the order the snippet WOULD produce, and the two have to
-- be kept in step by hand -- there is no way to run a secure snippet against the
-- non-secure test frames. Treat any change to the snippet's ordering as a change
-- here as well. (Audit, 2026-08-07.)
--
-- `db` is the mode's DB. ☠ It used to be resolved here as DF:GetDB(), which is
-- ALWAYS the party table -- so Separate Melee/Ranged set on the Raid page was
-- ignored when sorting raid frames, and the party setting silently drove them.
function Sort:GetUnitRole(unit, db)
    if not unit or not UnitExists(unit) then return "DAMAGER" end
    
    -- Check cache first. The GUID can be a secret value that can't be used as
    -- a table key — in that case SKIP the cache entirely (recompute fresh).
    -- Don't fall back to the unit token as a key: token-keyed entries go stale
    -- the moment the roster shifts (raid5 becomes a different player and would
    -- briefly show the previous player's role until the next cache clear).
    local guid = UnitGUID(unit)
    local cacheKey = canaccessvalue(guid) and guid or nil
    if cacheKey and self.UnitCache[cacheKey] then
        return self.UnitCache[cacheKey].role
    end
    
    -- Get assigned role
    local role = UnitGroupRolesAssigned(unit)
    
    -- For DPS, determine if melee or ranged
    if role == "DAMAGER" or role == "NONE" then
        db = db or DF:GetDB()
        if db.sortSeparateMeleeRanged then
            local specID = nil
            
            -- For player, we can get spec directly
            if UnitIsUnit(unit, "player") then
                specID = GetSpecializationInfo(GetSpecialization() or 1)
            else
                -- For other players, try to get from inspection cache or guess from class
                -- Note: In a full implementation, you'd use NotifyInspect/INSPECT_READY
                -- For now, we'll use class-based guessing
                -- ☠ A FOURTH HAND-WRITTEN MELEE TABLE lived here, missed by 20174c23.
                -- It happened to agree with DF.MELEE_CLASSES, but agreement by copy is
                -- what produced the earlier three-way disagreement in the first place.
                local _, class = UnitClass(unit)
                if class then
                    role = DF.MELEE_CLASSES[class] and "MELEE" or "RANGED"
                else
                    role = "DAMAGER"
                end
            end
            
            -- Check spec if we have it
            if specID then
                if MELEE_SPECS[specID] then
                    role = "MELEE"
                else
                    role = "RANGED"
                end
            end
        else
            role = "DAMAGER"
        end
    end
    
    -- Cache the result
    if cacheKey then
        self.UnitCache[cacheKey] = self.UnitCache[cacheKey] or {}
        self.UnitCache[cacheKey].role = role
    end
    
    return role
end

-- Get sort priority for a role based on db settings
function Sort:GetRolePriority(role, db)
    local roleOrder = db.sortRoleOrder or { "TANK", "HEALER", "MELEE", "RANGED" }
    
    for i, r in ipairs(roleOrder) do
        if r == role then
            return i
        end
        -- Handle DAMAGER matching MELEE or RANGED when not separating
        if role == "DAMAGER" and (r == "MELEE" or r == "RANGED") then
            return i
        end
    end
    
    return 100 -- Unknown role goes last
end

-- ============================================================
-- SORTING LOGIC
-- ============================================================

-- Get sort priority for a class based on db settings
function Sort:GetClassPriority(class, db)
    if not class then return 100 end
    
    local classOrder = db.sortClassOrder
    if not classOrder then return 100 end
    
    for i, c in ipairs(classOrder) do
        if c == class then
            return i
        end
    end
    
    return 100 -- Unknown class goes last
end

-- Compare function for sorting frames
function Sort:CompareUnits(unitA, unitB, db)
    local roleA = self:GetUnitRole(unitA, db)
    local roleB = self:GetUnitRole(unitB, db)
    
    local prioA = self:GetRolePriority(roleA, db)
    local prioB = self:GetRolePriority(roleB, db)
    
    -- First sort by role priority
    if prioA ~= prioB then
        return prioA < prioB
    end
    
    -- Then sort by class if enabled
    if db.sortByClass then
        local _, classA = UnitClass(unitA)
        local _, classB = UnitClass(unitB)
        
        local classPrioA = self:GetClassPriority(classA, db)
        local classPrioB = self:GetClassPriority(classB, db)
        
        if classPrioA ~= classPrioB then
            return classPrioA < classPrioB
        end
    end
    
    -- Name key for the alphabetical sort + tiebreak below. A unit's name can
    -- be SECRET in combat (Midnight), and even ~= on a secret string throws —
    -- a secret (or missing) name falls back to the unit token, which is plain
    -- and unique. Pure per-unit substitution, so the comparator stays a
    -- consistent total order for table.sort.
    local nameA = UnitName(unitA)
    local nameB = UnitName(unitB)
    if nameA == nil or issecretvalue(nameA) then nameA = unitA end
    if nameB == nil or issecretvalue(nameB) then nameB = unitB end

    -- Then sort alphabetically if enabled
    -- Supports "AZ", "ZA", or legacy true (treated as "AZ")
    local alpha = db.sortAlphabetical
    if alpha and alpha ~= false then
        if alpha == "ZA" then
            return nameA > nameB
        else
            return nameA < nameB
        end
    end

    -- Deterministic final tiebreak: equal-key units need a stable order, or the
    -- unstable Lua table.sort reshuffles them on each re-sort (group-frame shuffle
    -- during M+ pulls). Mirrors Headers.lua SortMembers.
    if nameA ~= nameB then return nameA < nameB end
    return false
end

-- Compare function for test mode using test data
function Sort:CompareTestData(dataA, dataB, db)
    -- Get roles from test data
    local roleA = dataA.role or "DAMAGER"
    local roleB = dataB.role or "DAMAGER"
    
    -- Map test roles to sort roles, respecting melee/ranged separation
    local function MapTestRole(data)
        local role = data.role or "DAMAGER"
        if role == "TANK" or role == "HEALER" then return role end
        
        -- When separating melee/ranged, use spec ID for accurate classification
        if db.sortSeparateMeleeRanged then
            -- Check spec ID first (most accurate)
            local specID = data.specID
            if specID and specID > 0 then
                return MELEE_SPECS[specID] and "MELEE" or "RANGED"
            end
            
            -- Class fallback -- the SAME table live uses now. The comment here used
            -- to claim it matched live; it did not (live omitted PALADIN).
            local class = data.class
            if class then
                return DF.MELEE_CLASSES[class] and "MELEE" or "RANGED"
            end
        end
        
        return "DAMAGER"
    end
    
    roleA = MapTestRole(dataA)
    roleB = MapTestRole(dataB)
    
    local prioA = self:GetRolePriority(roleA, db)
    local prioB = self:GetRolePriority(roleB, db)
    
    -- First sort by role priority
    if prioA ~= prioB then
        return prioA < prioB
    end
    
    -- Then sort by class if enabled
    if db.sortByClass then
        local classA = dataA.class
        local classB = dataB.class
        
        local classPrioA = self:GetClassPriority(classA, db)
        local classPrioB = self:GetClassPriority(classB, db)
        
        if classPrioA ~= classPrioB then
            return classPrioA < classPrioB
        end
    end
    
    -- Then sort alphabetically if enabled
    -- Supports "AZ", "ZA", or legacy true (treated as "AZ")
    local alpha = db.sortAlphabetical
    if alpha and alpha ~= false then
        local nameA = dataA.name or ""
        local nameB = dataB.name or ""
        if alpha == "ZA" then
            return nameA > nameB
        else
            return nameA < nameB
        end
    end

    -- Deterministic final tiebreak (see CompareUnits) so test-mode sorting is
    -- stable across re-sorts too.
    local tieA = dataA.name or ""
    local tieB = dataB.name or ""
    if tieA ~= tieB then return tieA < tieB end
    return false
end

-- Sort a list of frame data entries
-- Each entry should have: {frame = frame, unit = unit, isPlayer = bool, testData = optional}
-- In test mode, entries should have testData with .name, .class, .role
function Sort:SortFrameList(frameList, db, isTestMode)
    if not db.sortEnabled then return frameList end
    
    local playerEntry = nil
    local otherEntries = {}  -- Fresh table each call
    
    -- Separate player from others
    for _, entry in ipairs(frameList) do
        if entry.isPlayer then
            playerEntry = entry
        else
            tinsert(otherEntries, entry)
        end
    end
    
    -- Sort non-player entries
    if isTestMode then
        -- Use test data for sorting
        sort(otherEntries, function(a, b)
            local dataA = a.testData or {}
            local dataB = b.testData or {}
            return self:CompareTestData(dataA, dataB, db)
        end)
    else
        -- Use real unit data
        sort(otherEntries, function(a, b)
            return self:CompareUnits(a.unit, b.unit, db)
        end)
    end
    
    -- Build final list based on self position setting
    local sortedList = {}  -- Fresh table each call
    local selfPos = db.sortSelfPosition or "SORTED"
    
    -- Check if selfPos is a numeric position (1-5)
    local numericPos = tonumber(selfPos)
    
    if numericPos and playerEntry then
        -- Insert player at specific position
        local inserted = false
        for i, entry in ipairs(otherEntries) do
            -- Insert player before this position if we've reached the target
            if i == numericPos and not inserted then
                tinsert(sortedList, playerEntry)
                inserted = true
            end
            tinsert(sortedList, entry)
        end
        -- If we haven't inserted yet (position is beyond list length), add at end
        if not inserted then
            tinsert(sortedList, playerEntry)
        end
    elseif selfPos == "FIRST" and playerEntry then
        tinsert(sortedList, playerEntry)
        for _, entry in ipairs(otherEntries) do
            tinsert(sortedList, entry)
        end
    elseif selfPos == "LAST" and playerEntry then
        for _, entry in ipairs(otherEntries) do
            tinsert(sortedList, entry)
        end
        tinsert(sortedList, playerEntry)
    else
        -- SORTED (or legacy NORMAL) - sort player with everyone else
        if playerEntry then
            local inserted = false
            
            for i, entry in ipairs(otherEntries) do
                local playerFirst
                if isTestMode then
                    local playerData = playerEntry.testData or {}
                    local entryData = entry.testData or {}
                    playerFirst = self:CompareTestData(playerData, entryData, db)
                else
                    playerFirst = self:CompareUnits("player", entry.unit, db)
                end
                
                if playerFirst and not inserted then
                    tinsert(sortedList, playerEntry)
                    inserted = true
                end
                tinsert(sortedList, entry)
            end
            
            if not inserted then
                tinsert(sortedList, playerEntry)
            end
        else
            -- Can't reuse here, need to return the other entries directly
            return otherEntries
        end
    end
    
    return sortedList
end

-- ============================================================
-- CACHE MANAGEMENT
-- ============================================================

function Sort:ClearCache()
    wipe(self.UnitCache)
end

function Sort:TriggerResort()
    self:ClearCache()

    -- ☠ A SecureSort push/trigger block used to sit here, gated on
    -- `DF.SecureSort.initialized and .framesRegistered`. Neither flag is ever set:
    -- SecureSort:Initialize() has no reachable caller (see Features/SecureSort.lua),
    -- so the whole block was dead and its comment -- "SecureSort is now the only
    -- system that positions party frames" -- had it exactly backwards. Party frames
    -- are positioned by SecureGroupHeaderTemplate via Frames/Headers.lua.
    --
    -- Clearing the unit cache is the real work this function does, and it is live.
end

-- ============================================================
-- EVENT HANDLING
-- ============================================================
-- (Event-based sorting removed - Headers.lua unified handler manages all sorting)
-- ============================================================

-- ============================================================
-- SLASH COMMAND
-- ============================================================

DF:RegisterDebugSlash("DFSORT", "Frame sorting diagnostics", false, "/dfsort")
SlashCmdList["DFSORT"] = function(msg)
    if msg == "refresh" or msg == "resort" then
        Sort:TriggerResort()
        DF:Say("Re-sorted frames.")
    elseif msg == "clear" then
        Sort:ClearCache()
        DF:Say("Cleared sort cache.")
    -- Bare form prints the dump, matching its two siblings: /df debug secure with no
    -- argument prints status, /df debug flatraid with no argument prints info. "debug"
    -- meant three different things across the three sort/layout commands — a dump
    -- here, a real TOGGLE in secure, a console signpost in flatraid — so the bare
    -- form is now the consistent way in. "debug" stays as an alias.
    elseif msg == "debug" or msg == "" then
        -- ☠ THE BODY GOES THROUGH THE WRITER, NOT print().
        -- This block opened a DF:Out header and then printed its body with bare
        -- print(). That reads as a style inconsistency and is not one: the writers
        -- route through DebugConsole:Log, which is where secret values are
        -- sanitised. The unit rows below call UnitName() on group members — on 12.1
        -- that can return a secret value, and handing one to a raw print is exactly
        -- what the sanitiser exists to prevent. It also meant these lines never
        -- reached the console log, so they were missing from the very export someone
        -- would attach to a sorting bug report.
        local o = DF:Out("Sort")
        local db = DF:GetDB()
        o:Field("sortEnabled", tostring(db.sortEnabled))
        o:Field("sortSelfPosition", tostring(db.sortSelfPosition))
        o:Field("sortByClass", tostring(db.sortByClass))
        o:Field("sortAlphabetical", tostring(db.sortAlphabetical))
        o:Field("sortSeparateMeleeRanged", tostring(db.sortSeparateMeleeRanged))
        o:Field("sortRoleOrder", table.concat(db.sortRoleOrder or {}, ", "))
        if db.sortByClass then
            o:Field("sortClassOrder", table.concat(db.sortClassOrder or {}, ", "))
        end

        -- Detected roles and classes for party members.
        o:Section("Unit Info")
        local function unitRow(unit)
            local _, unitClass = UnitClass(unit)
            o:Field(unit, string.format("%s - %s - %s",
                tostring(Sort:GetUnitRole(unit)), tostring(unitClass), tostring(UnitName(unit))))
        end
        unitRow("player")
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                unitRow(unit)
            end
        end
        o:Siblings("sort")
    else
        local o = DF:Out("Sort")
        o:Section("Commands")
        o:Item("(no argument)", "sort config, roles and classes")
        o:Item("refresh", "re-sort frames")
        o:Item("clear", "clear the role cache")
    end
end
