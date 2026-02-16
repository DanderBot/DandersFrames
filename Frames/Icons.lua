local addonName, DF = ...

-- ============================================================
-- FRAMES ICONS MODULE
-- Contains missing buff icons and aura update functions
-- ============================================================

-- Local caching of frequently used globals and WoW API for performance
local pairs, ipairs, type, wipe = pairs, ipairs, type, wipe
local tinsert = table.insert
local UnitBuff, UnitDebuff = UnitBuff, UnitDebuff
local GetTime = GetTime
local C_Spell = C_Spell
local UnitClass = UnitClass
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsConnected = UnitIsConnected
local UnitExists = UnitExists
local InCombatLockdown = InCombatLockdown

-- ============================================================
-- MISSING BUFF CACHING (cached lookup optimization)
-- ============================================================

-- Cache player class once at load
local _, cachedPlayerClass = UnitClass("player")

-- Cache spell icons (spellID -> texture)
local spellIconCache = {}

-- Cache missing buff state per frame (frame -> spellID or nil)
local missingBuffCache = {}

-- Default border color for missing buff icon (avoids table allocation)
local DEFAULT_MISSING_BUFF_BORDER_COLOR = {r = 1, g = 0, b = 0, a = 1}

-- Helper to get cached spell icon
local function GetCachedSpellIcon(spellID)
    if not spellID then return nil end
    
    local cached = spellIconCache[spellID]
    if cached then return cached end
    
    -- Fetch and cache
    local icon
    if C_Spell and C_Spell.GetSpellTexture then
        icon = C_Spell.GetSpellTexture(spellID)
    elseif GetSpellTexture then
        icon = GetSpellTexture(spellID)
    end
    
    if icon then
        spellIconCache[spellID] = icon
    end
    return icon
end

-- ============================================================
-- PERFORMANCE FIX: Default colors for UpdateDefensiveBar fallbacks
-- Avoids creating tables on every call when db values are nil
-- ============================================================
local DEFAULT_DEFENSIVE_BORDER_COLOR = {r = 0, g = 0.8, b = 0, a = 1}
local DEFAULT_DEFENSIVE_DURATION_COLOR = {r = 1, g = 1, b = 1}

-- ============================================================
-- PERFORMANCE FIX: Module-level state for UpdateDefensiveBar pcalls
-- Avoids creating closures on every call
-- ============================================================
local DefensiveBarState = {
    unit = nil,
    auraInstanceID = nil,
    auraData = nil,
    frame = nil,
    textureSet = false,
}

-- Module-level function for GetAuraDataByAuraInstanceID pcall
local function GetDefensiveAuraData()
    local state = DefensiveBarState
    state.auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(state.unit, state.auraInstanceID)
end

-- Module-level function for SetTexture pcall
local function SetDefensiveTexture()
    local state = DefensiveBarState
    state.frame.defensiveIcon.texture:SetTexture(state.auraData.icon)
    state.textureSet = true
end

-- Module-level function for SetCooldownFromExpirationTime pcall
local function SetDefensiveCooldown()
    local state = DefensiveBarState
    local cooldown = state.frame.defensiveIcon.cooldown
    local auraData = state.auraData
    if cooldown.SetCooldownFromExpirationTime and auraData.expirationTime and auraData.duration then
        cooldown:SetCooldownFromExpirationTime(auraData.expirationTime, auraData.duration)
    end
end

-- Get raid buff icons for fallback filtering (when spellId is secret)
-- This is cached after first call
function DF:GetRaidBuffIcons()
    if DF.RaidBuffIconCache then
        return DF.RaidBuffIconCache
    end
    
    local icons = {}
    for _, buffInfo in ipairs(DF.RaidBuffs) do
        local spellIdOrTable = buffInfo[1]
        -- Handle both single spell ID and table of spell IDs
        local spellIds = type(spellIdOrTable) == "table" and spellIdOrTable or {spellIdOrTable}
        for _, spellId in ipairs(spellIds) do
            local icon = nil
            if C_Spell and C_Spell.GetSpellTexture then
                icon = C_Spell.GetSpellTexture(spellId)
            elseif GetSpellTexture then
                icon = GetSpellTexture(spellId)
            end
            if icon then
                icons[icon] = true
            end
        end
    end
    
    DF.RaidBuffIconCache = icons
    return icons
end

-- Get raid buff names for filtering (when both spellId and icon are secret)
function DF:GetRaidBuffNames()
    if DF.RaidBuffNameCache then
        return DF.RaidBuffNameCache
    end
    
    local names = {}
    for _, buffInfo in ipairs(DF.RaidBuffs) do
        local name = buffInfo[3]  -- Name is index 3 in our table
        if name then
            names[name] = true
        end
    end
    
    DF.RaidBuffNameCache = names
    return names
end

-- ============================================================
-- PERFORMANCE FIX: Module-level state for UnitHasBuff
-- Avoids creating closures every call which caused memory leaks
-- OLD CODE preserved in comments below for rollback if needed
-- ============================================================

-- Shared state table for UnitHasBuff helper functions
local UnitHasBuffState = {
    spellIDs = nil,      -- Current spell IDs to check
    found = false,       -- Result from ForEachAura
    matched = false,     -- Result from GetAuraDataByIndex
    currentAuraData = nil, -- Current aura being checked
}

-- Reusable single-element table for single spell IDs (avoids {spellIDOrTable} allocation)
local singleSpellIDTable = {}

-- Module-level function for checking aura spell ID
-- Note: In WoW, comparing secret values doesn't error - it just returns false
local function CheckAuraSpellId_ForEach()
    local state = UnitHasBuffState
    local auraData = state.currentAuraData
    -- Check for secret value to avoid "attempt to compare secret value" errors
    if auraData and auraData.spellId and not issecretvalue(auraData.spellId) then
        local spellIDs = state.spellIDs
        local auraSpellId = auraData.spellId
        for i = 1, #spellIDs do
            if auraSpellId == spellIDs[i] then
                state.found = true
                return
            end
        end
    end
end

-- Module-level callback for AuraUtil.ForEachAura
local function ForEachAuraCallback(auraData)
    local state = UnitHasBuffState
    state.currentAuraData = auraData
    CheckAuraSpellId_ForEach()
    if state.found then return true end  -- Stop iteration
end

-- Module-level function for GetAuraDataByIndex loop
local function CheckAuraSpellId_ByIndex()
    local state = UnitHasBuffState
    local auraData = state.currentAuraData
    -- Check for secret value to avoid "attempt to compare secret value" errors
    if auraData and auraData.spellId and not issecretvalue(auraData.spellId) then
        local spellIDs = state.spellIDs
        local auraSpellId = auraData.spellId
        for i = 1, #spellIDs do
            if auraSpellId == spellIDs[i] then
                state.matched = true
                return
            end
        end
    end
end

-- Helper function to check if a unit has a specific buff
function DF:UnitHasBuff(unit, spellIDOrTable, spellName)
    if not unit or not UnitExists(unit) then return false end
    
    local db = DF:GetDB()
    local debug = db and db.missingBuffIconDebug
    
    -- PERFORMANCE FIX: Reuse single-element table instead of creating {spellIDOrTable} every call
    -- OLD: local spellIDs = type(spellIDOrTable) == "table" and spellIDOrTable or {spellIDOrTable}
    local spellIDs
    if type(spellIDOrTable) == "table" then
        spellIDs = spellIDOrTable
    else
        wipe(singleSpellIDTable)
        singleSpellIDTable[1] = spellIDOrTable
        spellIDs = singleSpellIDTable
    end
    
    -- Store in shared state for module-level helper functions
    UnitHasBuffState.spellIDs = spellIDs
    UnitHasBuffState.found = false
    UnitHasBuffState.matched = false
    
    if debug then
        local idStr = type(spellIDOrTable) == "table" and table.concat(spellIDOrTable, ", ") or tostring(spellIDOrTable)
        print("|cff00ff00DF:|r Checking " .. unit .. " for " .. (spellName or "unknown") .. " (IDs: " .. idStr .. ")")
    end
    
    -- Method 1: Try name-based lookup first (most reliable for party members)
    -- Spell names are typically not protected like spell IDs can be
    -- Wrap in pcall because FindAuraByName may call APIs that don't exist in Edit Mode
    if spellName and AuraUtil and AuraUtil.FindAuraByName then
        local success, auraData = pcall(AuraUtil.FindAuraByName, spellName, unit, "HELPFUL")
        if success and auraData then
            if debug then print("|cff00ff00DF:|r   -> Found via FindAuraByName") end
            return true
        end
    end
    
    -- Method 2: Use AuraUtil.ForEachAura with spell ID (works well for player)
    -- PERFORMANCE FIX: Use module-level callback instead of inline closure
    -- OLD CODE:
    --[[
    if AuraUtil and AuraUtil.ForEachAura then
        local found = false
        AuraUtil.ForEachAura(unit, "HELPFUL", nil, function(auraData)
            -- Wrap in pcall since spellId might be secret
            pcall(function()
                if auraData and auraData.spellId then
                    for _, spellID in ipairs(spellIDs) do
                        if auraData.spellId == spellID then
                            found = true
                            break
                        end
                    end
                end
            end)
            if found then return true end  -- Stop iteration
        end, true)  -- usePackedAura = true
        if found then 
            if debug then print("|cff00ff00DF:|r   -> Found via ForEachAura") end
            return true 
        end
    end
    --]]
    if AuraUtil and AuraUtil.ForEachAura then
        UnitHasBuffState.found = false
        -- PERF: Direct call - comparison inside callback is safe (doesn't error on secret values)
        AuraUtil.ForEachAura(unit, "HELPFUL", nil, ForEachAuraCallback, true)
        if UnitHasBuffState.found then 
            if debug then print("|cff00ff00DF:|r   -> Found via ForEachAura") end
            return true 
        end
    end
    
    -- Method 3: Direct iteration with C_UnitAuras.GetAuraDataByIndex
    -- PERFORMANCE FIX: Use module-level function instead of inline closure
    -- OLD CODE:
    --[[
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local success, auraData = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
            if not success or not auraData then break end
            -- Wrap comparison in pcall since spellId might be secret
            local matched = false
            pcall(function()
                if auraData.spellId then
                    for _, spellID in ipairs(spellIDs) do
                        if auraData.spellId == spellID then
                            matched = true
                            break
                        end
                    end
                end
            end)
            if matched then
                if debug then print("|cff00ff00DF:|r   -> Found via GetAuraDataByIndex at slot " .. i) end
                return true
            end
        end
    end
    --]]
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            -- PERF: Direct call without pcall - API returns nil on no aura, doesn't error
            local auraData = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
            if not auraData then break end
            -- PERF: Direct comparison without per-aura pcall
            UnitHasBuffState.currentAuraData = auraData
            UnitHasBuffState.matched = false
            CheckAuraSpellId_ByIndex()
            if UnitHasBuffState.matched then
                if debug then print("|cff00ff00DF:|r   -> Found via GetAuraDataByIndex at slot " .. i) end
                return true
            end
        end
    end
    
    if debug then print("|cff00ff00DF:|r   -> NOT FOUND") end
    return false
end

-- Per-frame throttle tracking for missing buff updates (kept for UpdateAllMissingBuffIcons)
local missingBuffThrottle = {}

function DF:UpdateMissingBuffIcon(frame)
    if not frame or not frame.unit or not frame.missingBuffFrame then return end
    
    -- PERF TEST: Skip if disabled
    if DF.PerfTest and not DF.PerfTest.enableMissingBuff then
        frame.missingBuffFrame:Hide()
        return
    end
    
    -- Use raid DB for raid frames, party DB for party frames
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    
    -- Check if feature is disabled
    if not db.missingBuffIconEnabled then
        frame.missingBuffFrame:Hide()
        return
    end
    
    -- ========================================
    -- PRIORITY HIDE CHECKS
    -- These conditions ALWAYS hide the icon, regardless of buff state
    -- ========================================
    
    -- Hide during combat - aura data may be protected/secret
    if InCombatLockdown() then
        frame.missingBuffFrame:Hide()
        return
    end
    
    -- Hide during encounter (boss fights) - same protection as combat
    if IsEncounterInProgress and IsEncounterInProgress() then
        frame.missingBuffFrame:Hide()
        return
    end
    
    -- Hide in M+ keys - aura data is fully protected/secret during keystones
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive() then
        frame.missingBuffFrame:Hide()
        return
    end
    
    -- Hide in PvP (arenas and battlegrounds) - same aura protection as M+
    local contentType = DF:GetContentType()
    if contentType == "arena" or contentType == "battleground" then
        frame.missingBuffFrame:Hide()
        return
    end
    
    local unit = frame.unit
    
    -- Hide for dead or offline units
    if UnitIsDeadOrGhost(unit) or not UnitIsConnected(unit) then
        frame.missingBuffFrame:Hide()
        missingBuffCache[frame] = nil
        return
    end
    
    -- Hide for units that don't exist
    if not UnitExists(unit) then
        frame.missingBuffFrame:Hide()
        missingBuffCache[frame] = nil
        return
    end
    
    -- Check for missing buffs
    local missingSpellID = nil
    local missingIcon = nil
    
    -- Use cached player class (computed once at load)
    local playerBuffKey = db.missingBuffClassDetection and DF.ClassToRaidBuff[cachedPlayerClass]
    
    -- PERF: Use numeric for loop instead of ipairs (avoids iterator allocation)
    local raidBuffs = DF.RaidBuffs
    for i = 1, #raidBuffs do
        local buffInfo = raidBuffs[i]
        local spellIDOrTable, configKey, name, buffClass = buffInfo[1], buffInfo[2], buffInfo[3], buffInfo[4]
        
        -- Determine if we should check this buff
        local shouldCheck = false
        if db.missingBuffClassDetection then
            -- Class detection mode: only check YOUR class's raid buff
            shouldCheck = (configKey == playerBuffKey)
        else
            -- Manual mode: check if this buff type is enabled in settings
            shouldCheck = db[configKey]
        end
        
        if shouldCheck then
            -- Use our helper function to check for the buff (supports single ID or table of IDs)
            local hasBuff = DF:UnitHasBuff(unit, spellIDOrTable, name)
            
            if not hasBuff then
                -- Get the first spell ID for getting the icon
                missingSpellID = type(spellIDOrTable) == "table" and spellIDOrTable[1] or spellIDOrTable
                -- Use cached icon lookup
                missingIcon = GetCachedSpellIcon(missingSpellID)
                break  -- Show first missing buff
            end
        end
    end
    
    -- CACHING: Check if the missing buff state changed
    local cachedMissing = missingBuffCache[frame]
    if cachedMissing == missingSpellID then
        -- No change - skip all visual updates
        return
    end
    
    -- Update cache
    missingBuffCache[frame] = missingSpellID
    
    if missingSpellID and missingIcon then
        -- Show the missing buff icon
        frame.missingBuffIcon:SetTexture(missingIcon)
        
        -- Apply border if enabled
        local showBorder = db.missingBuffIconShowBorder ~= false
        if showBorder then
            -- PERF: Use module-level default instead of inline table
            local bc = db.missingBuffIconBorderColor or DEFAULT_MISSING_BUFF_BORDER_COLOR
            local borderSize = db.missingBuffIconBorderSize or 2
            
            -- Apply pixel perfect to border size 
            if db.pixelPerfect then
                borderSize = DF:PixelPerfect(borderSize)
            end
            
            -- Set color on all border edges
            if frame.missingBuffBorderLeft then
                frame.missingBuffBorderLeft:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
                frame.missingBuffBorderLeft:SetWidth(borderSize)
                frame.missingBuffBorderLeft:Show()
            end
            if frame.missingBuffBorderRight then
                frame.missingBuffBorderRight:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
                frame.missingBuffBorderRight:SetWidth(borderSize)
                frame.missingBuffBorderRight:Show()
            end
            if frame.missingBuffBorderTop then
                frame.missingBuffBorderTop:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
                frame.missingBuffBorderTop:SetHeight(borderSize)
                frame.missingBuffBorderTop:ClearAllPoints()
                frame.missingBuffBorderTop:SetPoint("TOPLEFT", borderSize, 0)
                frame.missingBuffBorderTop:SetPoint("TOPRIGHT", -borderSize, 0)
                frame.missingBuffBorderTop:Show()
            end
            if frame.missingBuffBorderBottom then
                frame.missingBuffBorderBottom:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
                frame.missingBuffBorderBottom:SetHeight(borderSize)
                frame.missingBuffBorderBottom:ClearAllPoints()
                frame.missingBuffBorderBottom:SetPoint("BOTTOMLEFT", borderSize, 0)
                frame.missingBuffBorderBottom:SetPoint("BOTTOMRIGHT", -borderSize, 0)
                frame.missingBuffBorderBottom:Show()
            end
            
            -- Adjust icon position for border
            frame.missingBuffIcon:ClearAllPoints()
            frame.missingBuffIcon:SetPoint("TOPLEFT", borderSize, -borderSize)
            frame.missingBuffIcon:SetPoint("BOTTOMRIGHT", -borderSize, borderSize)
        else
            -- Hide all border edges
            if frame.missingBuffBorderLeft then frame.missingBuffBorderLeft:Hide() end
            if frame.missingBuffBorderRight then frame.missingBuffBorderRight:Hide() end
            if frame.missingBuffBorderTop then frame.missingBuffBorderTop:Hide() end
            if frame.missingBuffBorderBottom then frame.missingBuffBorderBottom:Hide() end
            frame.missingBuffIcon:ClearAllPoints()
            frame.missingBuffIcon:SetPoint("TOPLEFT", 0, 0)
            frame.missingBuffIcon:SetPoint("BOTTOMRIGHT", 0, 0)
        end
        
        -- Apply positioning
        local scale = db.missingBuffIconScale or 1.5
        local anchor = db.missingBuffIconAnchor or "CENTER"
        local x = db.missingBuffIconX or 0
        local y = db.missingBuffIconY or 0
        
        frame.missingBuffFrame:SetScale(scale)
        frame.missingBuffFrame:ClearAllPoints()
        frame.missingBuffFrame:SetPoint(anchor, frame, anchor, x, y)
        
        -- Apply frame level (controls layering within strata)
        local frameLevel = db.missingBuffIconFrameLevel or 0
        if frameLevel == 0 then
            -- "Auto" - use default relative to content overlay
            frame.missingBuffFrame:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 10)
        else
            frame.missingBuffFrame:SetFrameLevel(frame:GetFrameLevel() + frameLevel)
        end
        
        frame.missingBuffFrame:Show()
        
        -- Apply OOR alpha immediately after showing (the range timer won't
        -- re-trigger if the unit's range state hasn't changed)
        if DF.UpdateMissingBuffAppearance then
            DF:UpdateMissingBuffAppearance(frame)
        end
    else
        frame.missingBuffFrame:Hide()
    end
end

-- Update missing buff icons for all frames (called on a timer, out of combat only)
function DF:UpdateAllMissingBuffIcons()
    -- Clear caches so display-setting changes (border toggle, color, etc.) re-render
    wipe(missingBuffCache)
    wipe(missingBuffThrottle)
    
    -- Check if in test mode - use test update functions instead
    if DF.testMode or DF.raidTestMode then
        if DF.UpdateAllTestMissingBuff then
            DF:UpdateAllTestMissingBuff()
        end
        return
    end
    
    -- Disable in M+ keys - aura data is fully protected/secret during keystones
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive() then
        return
    end
    
    -- Disable in PvP (arenas and battlegrounds) - same aura protection as M+
    local contentType = DF:GetContentType()
    if contentType == "arena" or contentType == "battleground" then
        return
    end
    
    -- Safety check - only run out of combat
    if InCombatLockdown() then return end
    
    -- Throttle updates to avoid spam (0.1 second minimum between updates)
    local now = GetTime()
    if DF.lastMissingBuffUpdate and (now - DF.lastMissingBuffUpdate) < 0.1 then
        return
    end
    DF.lastMissingBuffUpdate = now
    
    local function updateFrame(frame)
        if frame and frame:IsShown() then
            DF:UpdateMissingBuffIcon(frame)
        end
    end
    
    -- Party frames via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(updateFrame)
    end
    
    -- Raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(updateFrame)
    end
end

-- Hide all missing buff icons (called when entering combat)
function DF:HideAllMissingBuffIcons()
    -- Clear caches
    wipe(missingBuffCache)
    wipe(missingBuffThrottle)
    
    local function hideFrame(frame)
        if frame and frame.missingBuffFrame then
            frame.missingBuffFrame:Hide()
        end
    end
    
    -- Party frames via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(hideFrame)
    end
    
    -- Raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(hideFrame)
    end
end

-- ========================================
-- DEFENSIVE ICON
-- ========================================

-- Update defensive icon for a single frame
-- Uses Blizzard's CenterDefensiveBuff cache - they decide which defensive to show
function DF:UpdateDefensiveBar(frame)
    if not frame or not frame.unit or not frame.defensiveIcon then return end
    
    -- PERF TEST: Skip if disabled
    if DF.PerfTest and not DF.PerfTest.enableDefensive then
        frame.defensiveIcon:Hide()
        return
    end
    
    -- Use raid DB for raid frames, party DB for party frames
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    local unit = frame.unit
    
    -- Check if feature is enabled
    if not db.defensiveIconEnabled then
        frame.defensiveIcon:Hide()
        return
    end
    
    -- Check if unit exists
    if not UnitExists(unit) then
        frame.defensiveIcon:Hide()
        return
    end
    
    -- Check Blizzard's cached defensive from CenterDefensiveBuff
    local cache = DF.BlizzardAuraCache and DF.BlizzardAuraCache[unit]
    local auraInstanceID = nil
    
    if cache and cache.defensives then
        -- Get the first (and only) defensive from cache
        for id in pairs(cache.defensives) do
            auraInstanceID = id
            break
        end
    end
    
    if not auraInstanceID then
        frame.defensiveIcon:Hide()
        return
    end
    
    -- PERFORMANCE FIX: Use module-level state and functions instead of closures
    -- OLD CODE:
    --[[
    local auraData = nil
    pcall(function()
        auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID)
    end)
    --]]
    DefensiveBarState.unit = unit
    DefensiveBarState.auraInstanceID = auraInstanceID
    DefensiveBarState.auraData = nil
    DefensiveBarState.frame = frame
    DefensiveBarState.textureSet = false
    
    pcall(GetDefensiveAuraData)
    local auraData = DefensiveBarState.auraData
    
    if not auraData then
        frame.defensiveIcon:Hide()
        return
    end
    
    -- Settings
    -- PERFORMANCE FIX: Use module-level default colors instead of inline tables
    local iconSize = db.defensiveIconSize or 24
    local borderSize = db.defensiveIconBorderSize or 2
    local borderColor = db.defensiveIconBorderColor or DEFAULT_DEFENSIVE_BORDER_COLOR
    local anchor = db.defensiveIconAnchor or "CENTER"
    local x = db.defensiveIconX or 0
    local y = db.defensiveIconY or 0
    local scale = db.defensiveIconScale or 1.0
    local showDuration = db.defensiveIconShowDuration ~= false
    
    -- Apply pixel perfect to border size 
    if db.pixelPerfect then
        borderSize = DF:PixelPerfect(borderSize)
    end
    
    -- Duration text settings
    local durationScale = db.defensiveIconDurationScale or 1.0
    local durationFont = db.defensiveIconDurationFont or "Fonts\\FRIZQT__.TTF"
    local durationOutline = db.defensiveIconDurationOutline or "OUTLINE"
    if durationOutline == "NONE" then durationOutline = "" end
    local durationX = db.defensiveIconDurationX or 0
    local durationY = db.defensiveIconDurationY or 0
    local durationColor = db.defensiveIconDurationColor or DEFAULT_DEFENSIVE_DURATION_COLOR
    
    -- PERFORMANCE FIX: Use module-level function instead of closure
    -- OLD CODE:
    --[[
    local textureSet = false
    pcall(function()
        frame.defensiveIcon.texture:SetTexture(auraData.icon)
        textureSet = true
    end)
    --]]
    DefensiveBarState.auraData = auraData  -- Store for SetDefensiveTexture
    pcall(SetDefensiveTexture)
    
    if not DefensiveBarState.textureSet then
        frame.defensiveIcon:Hide()
        return
    end
    
    -- PERFORMANCE FIX: Reuse existing auraData table instead of creating new one
    -- OLD CODE: frame.defensiveIcon.auraData = { auraInstanceID = auraInstanceID }
    if not frame.defensiveIcon.auraData then
        frame.defensiveIcon.auraData = { auraInstanceID = nil }
    end
    frame.defensiveIcon.auraData.auraInstanceID = auraInstanceID
    
    -- PERFORMANCE FIX: Use module-level function instead of closure
    -- OLD CODE:
    --[[
    pcall(function()
        if frame.defensiveIcon.cooldown.SetCooldownFromExpirationTime and auraData.expirationTime and auraData.duration then
            frame.defensiveIcon.cooldown:SetCooldownFromExpirationTime(auraData.expirationTime, auraData.duration)
        end
    end)
    --]]
    pcall(SetDefensiveCooldown)
    
    -- Check expiration using secret-safe API
    -- Result may be a secret boolean - pass directly to SetShownFromBoolean without any boolean test
    local hasExpiration = nil
    if auraInstanceID and C_UnitAuras.DoesAuraHaveExpirationTime then
        hasExpiration = C_UnitAuras.DoesAuraHaveExpirationTime(unit, auraInstanceID)
    end
    
    -- Show/hide cooldown using secret-safe API (handles nil/secret values)
    if frame.defensiveIcon.cooldown.SetShownFromBoolean then
        frame.defensiveIcon.cooldown:SetShownFromBoolean(hasExpiration, true, false)
    else
        frame.defensiveIcon.cooldown:Show()
    end
    
    -- Swipe toggle (hideSwipe = true means no swipe)
    local showSwipe = not db.defensiveIconHideSwipe
    frame.defensiveIcon.cooldown:SetDrawSwipe(showSwipe)
    
    -- Duration text
    frame.defensiveIcon.cooldown:SetHideCountdownNumbers(not showDuration)
    
    -- Find and style the native cooldown text
    if not frame.defensiveIcon.nativeCooldownText then
        local regions = {frame.defensiveIcon.cooldown:GetRegions()}
        for _, region in ipairs(regions) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                frame.defensiveIcon.nativeCooldownText = region
                break
            end
        end
    end
    
    -- Apply duration text styling
    if frame.defensiveIcon.nativeCooldownText then
        local durationSize = 10 * durationScale
        DF:SafeSetFont(frame.defensiveIcon.nativeCooldownText, durationFont, durationSize, durationOutline)
        frame.defensiveIcon.nativeCooldownText:ClearAllPoints()
        frame.defensiveIcon.nativeCooldownText:SetPoint("CENTER", frame.defensiveIcon, "CENTER", durationX, durationY)
        frame.defensiveIcon.nativeCooldownText:SetTextColor(durationColor.r, durationColor.g, durationColor.b, 1)
    end
    
    -- Stack count using secret-safe API (no pcall needed)
    frame.defensiveIcon.count:SetText("")
    if auraInstanceID and C_UnitAuras.GetAuraApplicationDisplayCount then
        local stackText = C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID, 2, 99)
        if stackText then
            frame.defensiveIcon.count:SetText(stackText)
        end
    end
    
    -- Apply border if enabled
    local showBorder = db.defensiveIconShowBorder ~= false
    if showBorder then
        -- Set color on all border edges
        if frame.defensiveIcon.borderLeft then
            frame.defensiveIcon.borderLeft:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.defensiveIcon.borderLeft:SetWidth(borderSize)
            frame.defensiveIcon.borderLeft:Show()
        end
        if frame.defensiveIcon.borderRight then
            frame.defensiveIcon.borderRight:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.defensiveIcon.borderRight:SetWidth(borderSize)
            frame.defensiveIcon.borderRight:Show()
        end
        if frame.defensiveIcon.borderTop then
            frame.defensiveIcon.borderTop:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.defensiveIcon.borderTop:SetHeight(borderSize)
            frame.defensiveIcon.borderTop:ClearAllPoints()
            frame.defensiveIcon.borderTop:SetPoint("TOPLEFT", borderSize, 0)
            frame.defensiveIcon.borderTop:SetPoint("TOPRIGHT", -borderSize, 0)
            frame.defensiveIcon.borderTop:Show()
        end
        if frame.defensiveIcon.borderBottom then
            frame.defensiveIcon.borderBottom:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a)
            frame.defensiveIcon.borderBottom:SetHeight(borderSize)
            frame.defensiveIcon.borderBottom:ClearAllPoints()
            frame.defensiveIcon.borderBottom:SetPoint("BOTTOMLEFT", borderSize, 0)
            frame.defensiveIcon.borderBottom:SetPoint("BOTTOMRIGHT", -borderSize, 0)
            frame.defensiveIcon.borderBottom:Show()
        end
        
        frame.defensiveIcon.texture:ClearAllPoints()
        frame.defensiveIcon.texture:SetPoint("TOPLEFT", borderSize, -borderSize)
        frame.defensiveIcon.texture:SetPoint("BOTTOMRIGHT", -borderSize, borderSize)
    else
        -- Hide all border edges
        if frame.defensiveIcon.borderLeft then frame.defensiveIcon.borderLeft:Hide() end
        if frame.defensiveIcon.borderRight then frame.defensiveIcon.borderRight:Hide() end
        if frame.defensiveIcon.borderTop then frame.defensiveIcon.borderTop:Hide() end
        if frame.defensiveIcon.borderBottom then frame.defensiveIcon.borderBottom:Hide() end
        frame.defensiveIcon.texture:ClearAllPoints()
        frame.defensiveIcon.texture:SetPoint("TOPLEFT", 0, 0)
        frame.defensiveIcon.texture:SetPoint("BOTTOMRIGHT", 0, 0)
    end
    
    -- Size, scale, and position
    local adjustedIconSize = iconSize
    if db.pixelPerfect then
        adjustedIconSize = DF:PixelPerfect(iconSize)
    end
    frame.defensiveIcon:SetSize(adjustedIconSize, adjustedIconSize)
    frame.defensiveIcon:SetScale(scale)
    frame.defensiveIcon:ClearAllPoints()
    frame.defensiveIcon:SetPoint(anchor, frame, anchor, x, y)
    
    -- Frame level
    local frameLevel = db.defensiveIconFrameLevel or 0
    if frameLevel == 0 then
        frame.defensiveIcon:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 15)
    else
        frame.defensiveIcon:SetFrameLevel(frame:GetFrameLevel() + frameLevel)
    end
    
    -- Use SetMouseClickEnabled(false) to allow tooltips while passing clicks through
    if frame.defensiveIcon.SetMouseClickEnabled then
        frame.defensiveIcon:SetMouseClickEnabled(false)
    end
    
    frame.defensiveIcon:Show()
    
    -- Apply range-based fading to the newly shown icon
    if DF.UpdateDefensiveIconAppearance then
        DF:UpdateDefensiveIconAppearance(frame)
    end
end

-- Update defensive icons for all frames
function DF:UpdateAllDefensiveBars()
    -- Check if in test mode - use test update functions instead
    if DF.testMode or DF.raidTestMode then
        if DF.UpdateAllTestDefensiveBar then
            DF:UpdateAllTestDefensiveBar()
        end
        return
    end
    
    local function updateFrame(frame)
        if frame and frame:IsShown() then
            DF:UpdateDefensiveBar(frame)
        end
    end
    
    -- Party frames via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(updateFrame)
    end
    
    -- Raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(updateFrame)
    end
end

-- Hide all defensive icons
function DF:HideAllDefensiveBars()
    local function hideFrame(frame)
        if frame and frame.defensiveIcon then
            frame.defensiveIcon:Hide()
        end
    end
    
    -- Party frames via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(hideFrame)
    end
    
    -- Raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(hideFrame)
    end
end

-- Legacy function for backwards compatibility
function DF:UpdateExternalDefIcon(frame)
    -- Redirect to new defensive bar
    DF:UpdateDefensiveBar(frame)
end

-- Legacy function for backwards compatibility
function DF:UpdateAllExternalDefIcons()
    DF:UpdateAllDefensiveBars()
end

-- Legacy function for backwards compatibility
function DF:HideAllExternalDefIcons()
    DF:HideAllDefensiveBars()
end

function DF:UpdateAuras(frame)
    if DF.RosterDebugCount then DF:RosterDebugCount("UpdateAuras") end
    if not frame or not frame.unit then return end
    
    -- PERF TEST: Skip if disabled
    if DF.PerfTest and not DF.PerfTest.enableAuras then return end
    
    -- Use raid DB for raid frames, party DB for party frames
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    
    if db.showBuffs then
        DF:UpdateAuraIcons(frame, frame.buffIcons, "HELPFUL", db.buffMax or 4)
    else
        for _, icon in ipairs(frame.buffIcons) do icon:Hide() end
    end
    
    if db.showDebuffs then
        DF:UpdateAuraIcons(frame, frame.debuffIcons, "HARMFUL", db.debuffMax or 4)
    else
        for _, icon in ipairs(frame.debuffIcons) do icon:Hide() end
    end
end

-- Update auras on all frames (used when entering/leaving combat)
function DF:UpdateAllAuras()
    local function updateFrame(frame)
        if frame and frame:IsShown() then
            DF:UpdateAuras(frame)
        end
    end
    
    -- Party frames via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(updateFrame)
    end
    
    -- Raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(updateFrame)
    end
    
    -- Pinned frames
    if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
        for setIndex = 1, 2 do
            local header = DF.PinnedFrames.headers[setIndex]
            if header then
                for i = 1, 40 do
                    local child = header:GetAttribute("child" .. i)
                    if child then
                        updateFrame(child)
                    end
                end
            end
        end
    end
end

-- Update click-through state on all aura icons (used when combat state changes)
function DF:UpdateAuraClickThrough()
    -- Use SetMouseClickEnabled(false) to allow tooltips while passing clicks through
    -- This is Cell's approach for click-casting compatibility with tooltips
    -- If DisableMouse is enabled, use EnableMouse(false) for complete click-through (no tooltips)
    
    local function updateFrameClickThrough(frame)
        if not frame then return end
        local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
        
        -- Update buff icons
        if frame.buffIcons then
            local disableMouse = db.buffDisableMouse
            for _, icon in ipairs(frame.buffIcons) do
                if icon then
                    if disableMouse then
                        -- Complete click-through - no mouse interaction at all
                        icon:EnableMouse(false)
                    else
                        -- Allow tooltips but pass clicks/motion through to parent for bindings
                        icon:EnableMouse(true)
                        if icon.SetPropagateMouseMotion then
                            icon:SetPropagateMouseMotion(true)
                        end
                        if icon.SetPropagateMouseClicks then
                            icon:SetPropagateMouseClicks(true)
                        end
                        if icon.SetMouseClickEnabled then
                            icon:SetMouseClickEnabled(false)
                        end
                    end
                end
            end
        end
        
        -- Update debuff icons
        if frame.debuffIcons then
            local disableMouse = db.debuffDisableMouse
            for _, icon in ipairs(frame.debuffIcons) do
                if icon then
                    if disableMouse then
                        -- Complete click-through - no mouse interaction at all
                        icon:EnableMouse(false)
                    else
                        -- Allow tooltips but pass clicks/motion through to parent for bindings
                        icon:EnableMouse(true)
                        if icon.SetPropagateMouseMotion then
                            icon:SetPropagateMouseMotion(true)
                        end
                        if icon.SetPropagateMouseClicks then
                            icon:SetPropagateMouseClicks(true)
                        end
                        if icon.SetMouseClickEnabled then
                            icon:SetMouseClickEnabled(false)
                        end
                    end
                end
            end
        end
        
        -- Update defensive icon
        if frame.defensiveIcon then
            local disableMouse = db.defensiveIconDisableMouse
            if disableMouse then
                -- Complete click-through - no mouse interaction at all
                frame.defensiveIcon:EnableMouse(false)
            else
                -- Allow tooltips but pass clicks/motion through to parent for bindings
                frame.defensiveIcon:EnableMouse(true)
                if frame.defensiveIcon.SetPropagateMouseMotion then
                    frame.defensiveIcon:SetPropagateMouseMotion(true)
                end
                if frame.defensiveIcon.SetPropagateMouseClicks then
                    frame.defensiveIcon:SetPropagateMouseClicks(true)
                end
                if frame.defensiveIcon.SetMouseClickEnabled then
                    frame.defensiveIcon:SetMouseClickEnabled(false)
                end
            end
        end
        
        -- Update targeted spell icons
        if frame.targetedSpellIcons then
            local disableMouse = db.targetedSpellDisableMouse
            for _, icon in ipairs(frame.targetedSpellIcons) do
                if icon and icon.iconFrame then
                    if disableMouse then
                        -- Complete click-through - no mouse interaction at all
                        icon:EnableMouse(false)
                        icon.iconFrame:EnableMouse(false)
                    else
                        -- Allow tooltips but pass clicks/motion through to parent for bindings
                        icon:EnableMouse(true)
                        icon.iconFrame:EnableMouse(true)
                        if icon.SetPropagateMouseMotion then
                            icon:SetPropagateMouseMotion(true)
                        end
                        if icon.SetPropagateMouseClicks then
                            icon:SetPropagateMouseClicks(true)
                        end
                        if icon.iconFrame.SetPropagateMouseMotion then
                            icon.iconFrame:SetPropagateMouseMotion(true)
                        end
                        if icon.iconFrame.SetPropagateMouseClicks then
                            icon.iconFrame:SetPropagateMouseClicks(true)
                        end
                        if icon.SetMouseClickEnabled then
                            icon:SetMouseClickEnabled(false)
                        end
                        if icon.iconFrame.SetMouseClickEnabled then
                            icon.iconFrame:SetMouseClickEnabled(false)
                        end
                    end
                end
            end
        end
    end
    
    -- Party frames via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(updateFrameClickThrough)
    end
    
    -- Raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(updateFrameClickThrough)
    end
end

function DF:UpdateAuraIcons(frame, icons, filter, maxAuras)
    -- Don't read aura data during combat - it may be protected
    -- Event-driven updates will handle it when safe
    if InCombatLockdown() then
        return
    end
    
    local unit = frame.unit
    -- Use raid DB for raid frames, party DB for party frames
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    local index = 1
    local auraSlot = 1
    
    -- Get raid buff icons for filtering (only out of combat, not in encounter, when option enabled)
    -- We use icons because spellId is protected, but icon texture is accessible
    -- DF.raidBuffFilteringReady is set at PLAYER_LOGIN to avoid secret value errors during ADDON_LOADED
    local raidBuffIcons = nil
    local inEncounter = IsEncounterInProgress and IsEncounterInProgress()
    local shouldFilterRaidBuffs = filter == "HELPFUL" and db.missingBuffHideFromBar and DF.raidBuffFilteringReady and not InCombatLockdown() and not inEncounter
    if shouldFilterRaidBuffs then
        raidBuffIcons = DF:GetRaidBuffIcons()
    end
    
    -- Determine aura filter based on checkbox settings
    local auraFilter
    if filter == "HELPFUL" then
        -- Build filter string from checkbox settings
        auraFilter = "HELPFUL"
        if db.buffFilterPlayer then
            auraFilter = auraFilter .. "|PLAYER"
        end
        if db.buffFilterRaid then
            auraFilter = auraFilter .. "|RAID"
        end
        if db.buffFilterCancelable then
            auraFilter = auraFilter .. "|CANCELABLE"
        end
    elseif filter == "HARMFUL" then
        if db.debuffShowAll then
            auraFilter = "HARMFUL"
        else
            auraFilter = "HARMFUL|RAID"
        end
    else
        auraFilter = filter
    end
    
    while index <= maxAuras and auraSlot <= 40 do
        local auraData = nil
        
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            auraData = C_UnitAuras.GetAuraDataByIndex(unit, auraSlot, auraFilter)
        end
        
        if not auraData then
            break
        end
        
        -- Check if we should skip this aura (raid buff filtering via icon match)
        local skipAura = false
        if shouldFilterRaidBuffs and raidBuffIcons then
            -- Try to get icon - this is accessible even when other fields are protected
            local auraIconTexture = nil
            pcall(function()
                auraIconTexture = auraData.icon
            end)
            -- Check for secret value before using as table index
            if auraIconTexture and not issecretvalue(auraIconTexture) and raidBuffIcons[auraIconTexture] then
                skipAura = true
            end
        end
        
        if skipAura then
            -- Skip this aura, move to next slot but don't increment display index
            auraSlot = auraSlot + 1
        else
            local auraIcon = icons[index]
            local canDisplay = false
            
            -- Try to set texture - if it succeeds, we can display
            local ok = pcall(function()
                auraIcon.texture:SetTexture(auraData.icon)
            end)
            if ok then
                canDisplay = true
            end
            
            -- Only proceed if we could access the icon
            if canDisplay then
                -- Store aura data for tooltip (only store safe values, not secrets)
                auraIcon.auraData = {
                    index = auraSlot,
                    auraInstanceID = nil,  -- Will try to get this
                }
                
                -- Try to get auraInstanceID for tooltip
                local auraInstanceID = nil
                pcall(function()
                    auraInstanceID = auraData.auraInstanceID
                    auraIcon.auraData.auraInstanceID = auraInstanceID
                end)
                
                -- Set cooldown - don't compare values, just try to call
                pcall(function()
                    auraIcon.cooldown:SetCooldownFromExpirationTime(auraData.expirationTime, auraData.duration)
                end)
                
                -- Show/hide cooldown based on whether aura expires
                if auraInstanceID and C_UnitAuras and C_UnitAuras.DoesAuraHaveExpirationTime then
                    local hasExpiration = C_UnitAuras.DoesAuraHaveExpirationTime(unit, auraInstanceID)
                    if auraIcon.cooldown.SetShownFromBoolean then
                        auraIcon.cooldown:SetShownFromBoolean(hasExpiration, true, false)
                    end
                end
                
                -- Set stack count using new API if available
                auraIcon.count:SetText("")  -- Default to empty
                if auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
                    local success, stackText = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, unit, auraInstanceID, 2, 99)
                    if success and stackText then
                        auraIcon.count:SetText(stackText)
                    end
                else
                    -- Fallback: try comparison (may fail with secrets)
                    pcall(function()
                        local count = auraData.applications
                        if count > 1 then
                            auraIcon.count:SetText(count)
                        end
                    end)
                end
                
                -- Border color for debuffs - set default first, then try to get type
                if filter == "HARMFUL" then
                    auraIcon.border:SetColorTexture(0.8, 0, 0, 0.8)  -- Default red
                    pcall(function()
                        local color = DebuffTypeColor[auraData.dispelName]
                        if color then
                            auraIcon.border:SetColorTexture(color.r, color.g, color.b, 0.8)
                        end
                    end)
                else
                    auraIcon.border:SetColorTexture(0, 0, 0, 0.8)
                end
                
                auraIcon:Show()
                index = index + 1
            end
            
            auraSlot = auraSlot + 1
        end
    end
    
    for i = index, #icons do
        icons[i].auraData = nil
        icons[i]:Hide()
    end
end

