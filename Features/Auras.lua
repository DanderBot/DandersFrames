local addonName, DF = ...

-- ============================================================
-- AURA FILTERING SYSTEM
-- Hooks into Blizzard's raid frame aura filtering to capture results
-- ============================================================

-- Local caching of frequently used globals and WoW API for performance
local pairs, ipairs, type, pcall, wipe = pairs, ipairs, type, pcall, wipe
local tinsert, tremove = table.insert, table.remove
local C_UnitAuras = C_UnitAuras
local UnitIsUnit = UnitIsUnit
local GetTime = GetTime

-- Additional cached API for direct aura update (Tier 1 optimization)
local UnitExists = UnitExists
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsConnected = UnitIsConnected
local InCombatLockdown = InCombatLockdown
local issecretvalue = issecretvalue
local strsplit = strsplit
local C_CurveUtil = C_CurveUtil
local GetAuraDataByAuraInstanceID = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID

-- Safe texture setter that handles secret values
local function SafeSetTexture(icon, texture)
    if icon and icon.texture and texture then
        icon.texture:SetTexture(texture)
        return true
    end
    return false
end

-- Safe cooldown setter
local function SafeSetCooldown(cooldown, expirationTime, duration)
    if cooldown and cooldown.SetCooldownFromExpirationTime then
        cooldown:SetCooldownFromExpirationTime(expirationTime, duration)
    end
end

-- Table pool to reduce garbage collection
-- PERFORMANCE FIX 2025-01-20: Reuse aura entry tables instead of creating new ones
local tablePool = {}
local poolSize = 0

local function AcquireTable()
    if poolSize > 0 then
        local t = tablePool[poolSize]
        tablePool[poolSize] = nil
        poolSize = poolSize - 1
        return t
    end
    return {}
end

local function ReleaseTable(t)
    if t then
        wipe(t)
        poolSize = poolSize + 1
        tablePool[poolSize] = t
    end
end

-- Helper to release all entry tables in an array before wiping
-- This returns entries to the pool so they can be reused
local function ReleaseAndWipe(arr)
    for i = 1, #arr do
        ReleaseTable(arr[i])
        arr[i] = nil
    end
end

-- Reusable result arrays for aura collection (reduces garbage)
-- These get wiped and reused each call instead of creating new tables
local reusableBuffs = {}
local reusableDebuffs = {}

-- ============================================================
-- SHARED AURA TIMER SYSTEM
-- Replaces per-icon OnUpdate scripts with a single shared timer
-- ============================================================

local trackedIcons = {}  -- [icon] = true

-- Create timer using AnimationGroup (same pattern as Range.lua)
local auraTimerFrame = CreateFrame("Frame")
local auraTimerGroup = auraTimerFrame:CreateAnimationGroup()
local auraTimerAnim = auraTimerGroup:CreateAnimation()
auraTimerAnim:SetDuration(0.2)
auraTimerGroup:SetLooping("REPEAT")

-- Performance tracking
local timerCallCount = 0
local iconsProcessedCount = 0
local lastReportTime = 0
local peakTrackedIcons = 0
local iconsByFrameType = { party = 0, raid = 0, highlight = 0, unknown = 0 }

-- Timer callback
auraTimerGroup:SetScript("OnLoop", function()
    timerCallCount = timerCallCount + 1
    
    -- Only skip if PerfTest explicitly disables the aura timer
    if DF.PerfTest and DF.PerfTest.enableAuraTimer == false then 
        return 
    end
    
    -- Track peak icons
    local currentCount = 0
    for _ in pairs(trackedIcons) do currentCount = currentCount + 1 end
    if currentCount > peakTrackedIcons then peakTrackedIcons = currentCount end
    
    for icon, _ in pairs(trackedIcons) do
        -- Skip hidden icons (includes icons on hidden parent frames)
        if not icon:IsShown() then
            trackedIcons[icon] = nil
        elseif icon.auraData and icon.auraData.auraInstanceID then
            iconsProcessedCount = iconsProcessedCount + 1
            
            -- Track frame type
            local frameType = "unknown"
            if icon.unitFrame then
                if icon.unitFrame.isPinnedFrame then
                    frameType = "highlight"
                elseif icon.unitFrame.isRaidFrame then
                    frameType = "raid"
                else
                    frameType = "party"
                end
            end
            iconsByFrameType[frameType] = iconsByFrameType[frameType] + 1
            -- Check if features are enabled
            local needsDurationColor = icon.showDuration and icon.durationColorByTime
            local needsExpiring = icon.expiringEnabled
            
            if needsDurationColor or needsExpiring then
                local unit = icon.unitFrame and icon.unitFrame.unit
                local auraInstanceID = icon.auraData.auraInstanceID
                
                if unit and auraInstanceID then
                    -- Get hasExpiration
                    local hasExpiration = nil
                    if C_UnitAuras and C_UnitAuras.DoesAuraHaveExpirationTime then
                        hasExpiration = C_UnitAuras.DoesAuraHaveExpirationTime(unit, auraInstanceID)
                    end
                    
                    if hasExpiration ~= nil then
                        -- Find native cooldown text if needed (safety net — rendering function usually discovers first)
                        if not icon.nativeCooldownText and icon.cooldown then
                            local regions = {icon.cooldown:GetRegions()}
                            for _, region in pairs(regions) do
                                if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                                    icon.nativeCooldownText = region
                                    break
                                end
                            end
                        end

                        -- Native text visibility is controlled by the cooldown frame's own Show/Hide
                        -- (SetShownFromBoolean on cooldown hides both swipe and text for permanent buffs)
                        -- No manual Show/Hide on nativeCooldownText needed here

                        -- Throttle expensive APIs to 1 FPS
                        local now = GetTime()
                        local auraChanged = icon.lastColorAuraID ~= auraInstanceID
                        if auraChanged then
                            icon.lastColorUpdate = nil
                            icon.lastColorAuraID = auraInstanceID
                        end
                        
                        if not icon.lastColorUpdate or (now - icon.lastColorUpdate) >= 1.0 then
                            icon.lastColorUpdate = now
                            
                            -- Get duration object
                            local durationObj = nil
                            if C_UnitAuras and C_UnitAuras.GetAuraDuration then
                                durationObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
                            end
                            
                            local useNewAPI = durationObj and durationObj.EvaluateRemainingDuration
                            
                            -- Duration color
                            if needsDurationColor and icon.nativeCooldownText and useNewAPI then
                                if C_CurveUtil and C_CurveUtil.CreateColorCurve then
                                    if not DF.durationColorCurve then
                                        local curve = C_CurveUtil.CreateColorCurve()
                                        curve:SetType(Enum.LuaCurveType.Linear)
                                        curve:AddPoint(0, CreateColor(1, 0, 0, 1))
                                        curve:AddPoint(0.3, CreateColor(1, 0.5, 0, 1))
                                        curve:AddPoint(0.5, CreateColor(1, 1, 0, 1))
                                        curve:AddPoint(1, CreateColor(0, 1, 0, 1))
                                        DF.durationColorCurve = curve
                                    end
                                    
                                    local result = durationObj:EvaluateRemainingPercent(DF.durationColorCurve)
                                    if result then
                                        if result.GetRGB then
                                            local r, g, b = result:GetRGB()
                                            icon.nativeCooldownText:SetTextColor(r, g, b, 1)
                                        elseif result.r then
                                            icon.nativeCooldownText:SetTextColor(result.r, result.g, result.b, 1)
                                        end
                                    end
                                end
                            end
                            
                            -- Expiring indicators
                            if not icon.testAuraData and needsExpiring and useNewAPI then
                                local threshold = icon.expiringThreshold or 30
                                local thresholdDecimal = threshold / 100
                                
                                if C_CurveUtil and C_CurveUtil.CreateColorCurve then
                                    DF.expiringCurves = DF.expiringCurves or {}
                                    if not DF.expiringCurves[threshold] then
                                        local curve = C_CurveUtil.CreateColorCurve()
                                        curve:SetType(Enum.LuaCurveType.Step)
                                        curve:AddPoint(0, CreateColor(1, 1, 1, 1))
                                        curve:AddPoint(thresholdDecimal, CreateColor(0, 0, 0, 0))
                                        curve:AddPoint(1, CreateColor(0, 0, 0, 0))
                                        DF.expiringCurves[threshold] = curve
                                    end
                                    
                                    local expireResult = durationObj:EvaluateRemainingPercent(DF.expiringCurves[threshold])
                                    
                                    if expireResult then
                                        local expiringAlpha = 0
                                        if expireResult.GetAlpha then
                                            expiringAlpha = expireResult:GetAlpha()
                                        elseif expireResult.a ~= nil then
                                            expiringAlpha = expireResult.a
                                        end
                                        
                                        -- Tint
                                        if icon.expiringTint and icon.expiringTintEnabled then
                                            icon.expiringTint:Show()
                                            if icon.expiringTint.SetAlphaFromBoolean then
                                                icon.expiringTint:SetAlphaFromBoolean(hasExpiration, expiringAlpha, 0)
                                            else
                                                icon.expiringTint:SetAlpha(expiringAlpha)
                                            end
                                        elseif icon.expiringTint then
                                            icon.expiringTint:Hide()
                                        end
                                        
                                        -- Border
                                        if icon.expiringBorderAlphaContainer and icon.expiringBorderEnabled then
                                            icon.expiringBorderAlphaContainer:Show()
                                            
                                            if icon.expiringBorderColorByTime then
                                                if icon.expiringBorderAlphaContainer.SetAlphaFromBoolean then
                                                    icon.expiringBorderAlphaContainer:SetAlphaFromBoolean(hasExpiration, 1, 0)
                                                else
                                                    icon.expiringBorderAlphaContainer:SetAlpha(1)
                                                end
                                                
                                                if not DF.expiringBorderColorCurve then
                                                    local curve = C_CurveUtil.CreateColorCurve()
                                                    curve:SetType(Enum.LuaCurveType.Linear)
                                                    curve:AddPoint(0, CreateColor(1, 0, 0, 1))
                                                    curve:AddPoint(0.3, CreateColor(1, 0.5, 0, 1))
                                                    curve:AddPoint(0.5, CreateColor(1, 1, 0, 1))
                                                    curve:AddPoint(1, CreateColor(0, 1, 0, 1))
                                                    DF.expiringBorderColorCurve = curve
                                                end
                                                
                                                local colorResult = durationObj:EvaluateRemainingPercent(DF.expiringBorderColorCurve)
                                                if colorResult and icon.expiringBorderTop then
                                                    if colorResult.GetRGBA then
                                                        local r, g, b, a = colorResult:GetRGBA()
                                                        icon.expiringBorderTop:SetColorTexture(r, g, b, a)
                                                        icon.expiringBorderBottom:SetColorTexture(r, g, b, a)
                                                        icon.expiringBorderLeft:SetColorTexture(r, g, b, a)
                                                        icon.expiringBorderRight:SetColorTexture(r, g, b, a)
                                                    elseif colorResult.r then
                                                        icon.expiringBorderTop:SetColorTexture(colorResult.r, colorResult.g, colorResult.b, colorResult.a or 1)
                                                        icon.expiringBorderBottom:SetColorTexture(colorResult.r, colorResult.g, colorResult.b, colorResult.a or 1)
                                                        icon.expiringBorderLeft:SetColorTexture(colorResult.r, colorResult.g, colorResult.b, colorResult.a or 1)
                                                        icon.expiringBorderRight:SetColorTexture(colorResult.r, colorResult.g, colorResult.b, colorResult.a or 1)
                                                    end
                                                end
                                            else
                                                if icon.expiringBorderAlphaContainer.SetAlphaFromBoolean then
                                                    icon.expiringBorderAlphaContainer:SetAlphaFromBoolean(hasExpiration, expiringAlpha, 0)
                                                else
                                                    icon.expiringBorderAlphaContainer:SetAlpha(expiringAlpha)
                                                end
                                            end
                                            
                                            if icon.expiringBorderPulsate and icon.expiringBorderPulse and not icon.expiringBorderPulse:IsPlaying() then
                                                icon.expiringBorderPulse:Play()
                                            end
                                        elseif icon.expiringBorderAlphaContainer then
                                            icon.expiringBorderAlphaContainer:Hide()
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- Start timer
C_Timer.After(1, function()
    auraTimerGroup:Play()
    DF.AuraTimer = auraTimerGroup
    lastReportTime = GetTime()
end)

-- Stats function for /df auratimer
function DF:GetAuraTimerStats()
    local iconCount = 0
    for _ in pairs(trackedIcons) do iconCount = iconCount + 1 end
    
    local now = GetTime()
    local elapsed = now - lastReportTime
    if elapsed < 1 then elapsed = 1 end
    
    local callsPerSec = timerCallCount / elapsed
    local iconsPerSec = iconsProcessedCount / elapsed
    
    -- Average icons per timer call
    local avgIconsPerCall = timerCallCount > 0 and (iconsProcessedCount / timerCallCount) or 0
    
    -- Compare to old system: 
    -- Old: Each icon runs OnUpdate at ~60fps
    -- New: Our timer runs at 5fps
    -- So old system = avgIcons * 60, new = avgIcons * 5
    local oldSystemCallsPerSec = avgIconsPerCall * 60
    local newSystemCallsPerSec = avgIconsPerCall * 5
    local savings = oldSystemCallsPerSec > 0 and ((oldSystemCallsPerSec - newSystemCallsPerSec) / oldSystemCallsPerSec * 100) or 0
    
    return {
        timerCalls = timerCallCount,
        iconsProcessed = iconsProcessedCount,
        trackedIcons = iconCount,
        peakIcons = peakTrackedIcons,
        avgIconsPerCall = avgIconsPerCall,
        callsPerSec = callsPerSec,
        iconsPerSec = iconsPerSec,
        oldSystemCallsPerSec = oldSystemCallsPerSec,
        newSystemCallsPerSec = newSystemCallsPerSec,
        savingsPercent = savings,
        elapsed = elapsed,
        byFrameType = iconsByFrameType
    }
end

function DF:PrintAuraTimerStats()
    local stats = self:GetAuraTimerStats()
    print("|cFF00FFFF[DF AuraTimer Stats]|r")
    print(string.format("  Icons: %d current, %d peak, %.1f avg/call", stats.trackedIcons, stats.peakIcons, stats.avgIconsPerCall))
    print(string.format("  Timer calls: %d (%.1f/sec)", stats.timerCalls, stats.callsPerSec))
    print(string.format("  Icons processed: %d (%.1f/sec)", stats.iconsProcessed, stats.iconsPerSec))
    print(string.format("  |cFFAAAAFF  Party: %d, Raid: %d, Highlight: %d, Unknown: %d|r", 
        stats.byFrameType.party, stats.byFrameType.raid, stats.byFrameType.highlight, stats.byFrameType.unknown))
    print(string.format("  |cFFFFFF00Old system (60fps): %.0f calls/sec|r", stats.oldSystemCallsPerSec))
    print(string.format("  |cFF00FF00New system (5fps): %.0f calls/sec|r", stats.newSystemCallsPerSec))
    print(string.format("  |cFF00FF00Reduction: %.1f%%|r", stats.savingsPercent))
end

function DF:ResetAuraTimerStats()
    timerCallCount = 0
    iconsProcessedCount = 0
    peakTrackedIcons = 0
    iconsByFrameType = { party = 0, raid = 0, highlight = 0, unknown = 0 }
    lastReportTime = GetTime()
    print("|cFF00FFFF[DF AuraTimer]|r Stats reset")
end

-- Register icon
function DF:RegisterIconForAuraTimer(icon)
    if icon then
        trackedIcons[icon] = true
    end
end

-- Unregister icon
function DF:UnregisterIconFromAuraTimer(icon)
    if icon then
        trackedIcons[icon] = nil
    end
end

-- Cache of auras that Blizzard's raid frames decided to show
-- Key: unitToken (e.g., "party1"), Value: {
--   buffs = {auraInstanceID = true},          -- Set for fast lookups
--   debuffs = {auraInstanceID = true},        -- Set for fast lookups
--   buffOrder = {auraInstanceID, ...},        -- Ordered array matching Blizzard's display order
--   debuffOrder = {auraInstanceID, ...},      -- Ordered array matching Blizzard's display order
--   playerDispellable = {auraInstanceID = true},  -- Only debuffs the current player can dispel
--   defensives = {auraInstanceID = true}  -- Defensive auras from CenterDefensiveBuff
-- }
DF.BlizzardAuraCache = {}

-- Track if we've successfully hooked Blizzard's frames
DF.BlizzardHookActive = false

-- ============================================================
-- SCAN BLIZZARD FRAMES FOR APPROVED AURAS
-- ============================================================

-- ============================================================
-- TRIGGER AURA UPDATES FOR ALL DF FRAMES SHOWING A UNIT
-- Shared by both Blizzard hook and Direct UNIT_AURA handler
-- ============================================================

local function TriggerAuraUpdateForUnit(unit)
    -- Fast unit→frame lookup via exposed unitFrameMap
    local ourFrame = DF.unitFrameMap and DF.unitFrameMap[unit]

    -- Fallback: iterate if unitFrameMap not yet available (early init)
    if not ourFrame then
        -- Check arena first (IsInRaid()=true in arena)
        if DF.IsInArena and DF:IsInArena() then
            if DF.IterateArenaFrames then
                DF:IterateArenaFrames(function(f)
                    if f and f.unit == unit then
                        ourFrame = f
                        return true
                    end
                end)
            end
        else
            if DF.IteratePartyFrames then
                DF:IteratePartyFrames(function(f)
                    if f and f.unit == unit then
                        ourFrame = f
                        return true
                    end
                end)
            end
            if not ourFrame and DF.IterateRaidFrames then
                DF:IterateRaidFrames(function(f)
                    if f and f.unit == unit then
                        ourFrame = f
                        return true
                    end
                end)
            end
        end
    end

    if ourFrame and ourFrame:IsVisible() then
        if DF.UpdateAuras_Enhanced then
            DF:UpdateAuras_Enhanced(ourFrame)
        end
        if DF.UpdateDefensiveBar then
            DF:UpdateDefensiveBar(ourFrame)
        end
        if DF.UpdateMyBuffIndicator then
            DF:UpdateMyBuffIndicator(ourFrame)
        end
        if DF.UpdateMissingBuffIcon then
            DF:UpdateMissingBuffIcon(ourFrame)
        end
        if DF.UpdateDispelOverlay then
            DF:UpdateDispelOverlay(ourFrame)
        end
    end

    -- Also update pinned frames showing this unit
    -- (Pinned frames share units with main frames but are excluded from unitFrameMap)
    if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
        for setIndex = 1, 2 do
            local header = DF.PinnedFrames.headers[setIndex]
            if header and header:IsShown() then
                for i = 1, 40 do
                    local child = header:GetAttribute("child" .. i)
                    if child and child:IsVisible() and child.unit == unit then
                        if DF.UpdateAuras_Enhanced then
                            DF:UpdateAuras_Enhanced(child)
                        end
                        if DF.UpdateDefensiveBar then
                            DF:UpdateDefensiveBar(child)
                        end
                        if DF.UpdateMyBuffIndicator then
                            DF:UpdateMyBuffIndicator(child)
                        end
                        if DF.UpdateMissingBuffIcon then
                            DF:UpdateMissingBuffIcon(child)
                        end
                        if DF.UpdateDispelOverlay then
                            DF:UpdateDispelOverlay(child)
                        end
                    end
                end
            end
        end
    end
end

local function CaptureAurasFromBlizzardFrame(frame, triggerUpdate)
    -- PERF TEST: Skip if disabled
    if DF.PerfTest and not DF.PerfTest.enableBlizzardAuraCache then return end
    
    if not frame or not frame.unit then return end
    
    -- CRITICAL GUARD: Skip frames where unitExists is false
    -- This can happen during rapid roster changes (e.g., joining a BG) where the frame
    -- has a unit assigned but the unit doesn't actually exist yet. Processing such frames
    -- can cause Blizzard's CompactUnitFrame code to error on nil tables.
    if frame.unitExists == false then return end
    
    -- PERFORMANCE FIX 2025-01-20: Check for nameplate FIRST before calling GetName()
    -- Nameplates pass through CompactUnitFrame_UpdateAuras hooks but we don't need their data
    -- and calling GetName() on them can error. Check unit string first (safe operation).
    local unit = frame.unit
    if unit and type(unit) == "string" and unit:find("nameplate") then
        return
    end
    -- Also check displayedUnit which nameplates may use
    local displayedUnit = frame.displayedUnit
    if displayedUnit and type(displayedUnit) == "string" and displayedUnit:find("nameplate") then
        return
    end
    
    -- Now safe to try GetName since we've filtered out nameplates
    local frameName = nil
    if frame.GetName and type(frame.GetName) == "function" then
        frameName = frame:GetName()
    end
    
    -- Skip preview frames and settings frames by name
    if frameName then
        if frameName:find("Preview") or frameName:find("Settings") or frameName:find("NamePlate") then
            return
        end
    end

    -- Skip Blizzard cache population when Direct mode is active for this unit
    local modeFrame = DF.unitFrameMap and DF.unitFrameMap[unit]
    if modeFrame then
        local modeDb = modeFrame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
        if modeDb and modeDb.auraSourceMode == "DIRECT" then return end
    end

    -- Initialize cache for this unit
    if not DF.BlizzardAuraCache[unit] then
        DF.BlizzardAuraCache[unit] = { buffs = {}, debuffs = {}, buffOrder = {}, debuffOrder = {}, playerDispellable = {}, defensives = {} }
    end

    -- Clear previous cache for this unit (wipe instead of new table to reduce GC)
    local cache = DF.BlizzardAuraCache[unit]
    wipe(cache.buffs)
    wipe(cache.debuffs)
    wipe(cache.buffOrder)
    wipe(cache.debuffOrder)
    wipe(cache.playerDispellable)
    wipe(cache.defensives)
    
    -- Capture buff auraInstanceIDs from Blizzard's buff frames
    -- ipairs preserves Blizzard's sorted display order (buffOrder array)
    -- Set (buffs) kept for fast lookups elsewhere in the codebase
    if frame.buffFrames and type(frame.buffFrames) == "table" then
        for i, buffFrame in ipairs(frame.buffFrames) do
            if buffFrame and buffFrame.IsShown and buffFrame:IsShown() and buffFrame.auraInstanceID then
                cache.buffs[buffFrame.auraInstanceID] = true
                cache.buffOrder[#cache.buffOrder + 1] = buffFrame.auraInstanceID
            end
        end
    end

    -- Capture debuff auraInstanceIDs from Blizzard's debuff frames
    if frame.debuffFrames and type(frame.debuffFrames) == "table" then
        for i, debuffFrame in ipairs(frame.debuffFrames) do
            if debuffFrame and debuffFrame.IsShown and debuffFrame:IsShown() and debuffFrame.auraInstanceID then
                cache.debuffs[debuffFrame.auraInstanceID] = true
                cache.debuffOrder[#cache.debuffOrder + 1] = debuffFrame.auraInstanceID
            end
        end
    end
    
    -- Capture player-dispellable debuffs from dispelDebuffFrames
    -- These are debuffs that the CURRENT PLAYER can dispel (Blizzard handles the logic)
    if frame.dispelDebuffFrames and type(frame.dispelDebuffFrames) == "table" then
        for i, debuffFrame in ipairs(frame.dispelDebuffFrames) do
            if debuffFrame and debuffFrame.IsShown and debuffFrame:IsShown() and debuffFrame.auraInstanceID then
                -- Add to both debuffs (for general display) and playerDispellable (for filtering)
                -- Only append to debuffOrder if not already captured from debuffFrames
                if not cache.debuffs[debuffFrame.auraInstanceID] then
                    cache.debuffs[debuffFrame.auraInstanceID] = true
                    cache.debuffOrder[#cache.debuffOrder + 1] = debuffFrame.auraInstanceID
                end
                cache.playerDispellable[debuffFrame.auraInstanceID] = true
            end
        end
    end
    
    -- Capture defensive auras from CenterDefensiveBuff frame
    -- This is a single frame that shows the "big defensive" aura Blizzard chose to display
    if frame.CenterDefensiveBuff then
        local defFrame = frame.CenterDefensiveBuff
        if defFrame.IsShown and defFrame:IsShown() and defFrame.auraInstanceID then
            DF.BlizzardAuraCache[unit].defensives[defFrame.auraInstanceID] = true
        end
    end
    
    -- Cache is now populated. Trigger display update if requested.
    --
    -- ARCHITECTURE: This hooksecurefunc callback fires AFTER
    -- Blizzard's CompactUnitFrame_UpdateAuras handler, so the cache is always
    -- fresh. This hook is the SOLE trigger for aura display updates — DF's own
    -- UNIT_AURA event handler does NOT call UpdateAuras, avoiding both race
    -- conditions (stale cache reads) and redundant double-updates.
    if triggerUpdate then
        TriggerAuraUpdateForUnit(unit)
    end
end

-- Scan ALL Blizzard compact frames to build cache
local function ScanAllBlizzardFrames()
    -- Scan party frames
    for i = 1, 4 do
        local frame = _G["CompactPartyFrameMember" .. i]
        -- Only scan frames that exist and have a valid unit
        if frame and frame.unit and frame.unitExists ~= false then
            CaptureAurasFromBlizzardFrame(frame, true)
        end
    end
    
    -- Scan raid frames
    for i = 1, 40 do
        local frame = _G["CompactRaidFrame" .. i]
        if frame and frame.unit and frame.unitExists ~= false then
            CaptureAurasFromBlizzardFrame(frame, true)
        end
    end
    
    -- Scan raid group frames
    for group = 1, 8 do
        for member = 1, 5 do
            local frame = _G["CompactRaidGroup" .. group .. "Member" .. member]
            if frame and frame.unit and frame.unitExists ~= false then
                CaptureAurasFromBlizzardFrame(frame, true)
            end
        end
    end
end

-- Find Blizzard frame for a specific unit and capture its auras
local function ScanBlizzardFrameForUnit(unit)
    if not unit then return end
    
    -- Check all possible Blizzard frame locations for this unit
    
    -- Party frames
    for i = 1, 5 do
        local frame = _G["CompactPartyFrameMember" .. i]
        if frame and frame.unit == unit and frame.unitExists ~= false then
            CaptureAurasFromBlizzardFrame(frame, true)
            return
        end
    end
    
    -- Raid frames
    for i = 1, 40 do
        local frame = _G["CompactRaidFrame" .. i]
        if frame and frame.unit == unit and frame.unitExists ~= false then
            CaptureAurasFromBlizzardFrame(frame, true)
            return
        end
    end
    
    -- Raid group frames
    for group = 1, 8 do
        for member = 1, 5 do
            local frame = _G["CompactRaidGroup" .. group .. "Member" .. member]
            if frame and frame.unit == unit and frame.unitExists ~= false then
                CaptureAurasFromBlizzardFrame(frame, true)
                return
            end
        end
    end
end

-- ============================================================
-- DIRECT AURA API PROVIDER
-- Queries C_UnitAuras directly with user-configured filter strings
-- Writes results to DF.BlizzardAuraCache (same structure as Blizzard provider)
-- ============================================================

-- Cache AuraUtil filter constants (available in 11.1+)
local AuraFilters = AuraUtil and AuraUtil.AuraFilters or {}

-- Reusable tables for scan results (allocated once, wiped each scan)
local directBuffResults = {}
local directDebuffResults = {}

-- Cached filter strings (rebuilt only when settings change)
local cachedBuffFilter = nil
local cachedDebuffFilter = nil
local cachedDefensiveFilter = nil
local cachedDispelFilter = nil

-- Build filter string for buffs from Direct mode settings
local function BuildDirectBuffFilter(db)
    local parts = { "HELPFUL" }
    if db.directBuffFilterPlayer then parts[#parts + 1] = "PLAYER" end
    if db.directBuffFilterRaid then parts[#parts + 1] = "RAID" end
    if db.directBuffFilterRaidInCombat and AuraFilters.RaidInCombat then
        parts[#parts + 1] = AuraFilters.RaidInCombat
    end
    if db.directBuffFilterCancelable then parts[#parts + 1] = "CANCELABLE" end
    return table.concat(parts, " ")
end

-- Build filter string for debuffs from Direct mode settings
local function BuildDirectDebuffFilter(db)
    local parts = { "HARMFUL" }
    if db.directDebuffFilterRaid then parts[#parts + 1] = "RAID" end
    if db.directDebuffFilterCrowdControl and AuraFilters.CrowdControl then
        parts[#parts + 1] = AuraFilters.CrowdControl
    end
    return table.concat(parts, " ")
end

-- Build defensive filter (fixed: HELPFUL + BIG_DEFENSIVE)
local function BuildDirectDefensiveFilter()
    if cachedDefensiveFilter then return cachedDefensiveFilter end
    local parts = { "HELPFUL" }
    if AuraFilters.BigDefensive then
        parts[#parts + 1] = AuraFilters.BigDefensive
    end
    cachedDefensiveFilter = table.concat(parts, " ")
    return cachedDefensiveFilter
end

-- Build dispel filter (fixed: HARMFUL + RAID_PLAYER_DISPELLABLE)
local function BuildDirectDispelFilter()
    if cachedDispelFilter then return cachedDispelFilter end
    local parts = { "HARMFUL" }
    if AuraFilters.RaidPlayerDispellable then
        parts[#parts + 1] = AuraFilters.RaidPlayerDispellable
    end
    cachedDispelFilter = table.concat(parts, " ")
    return cachedDispelFilter
end

-- Sort comparators for Direct mode
local function SortByTimeRemaining(a, b)
    local ok, result = pcall(function()
        local aExp = a.expirationTime or 0
        local bExp = b.expirationTime or 0
        if aExp == 0 and bExp == 0 then return false end
        if aExp == 0 then return false end
        if bExp == 0 then return true end
        return aExp < bExp
    end)
    if ok then return result end
    return false
end

local function SortByName(a, b)
    local ok, result = pcall(function()
        return (a.name or "") < (b.name or "")
    end)
    if ok then return result end
    return false
end

-- Rebuild cached filter strings from current settings
function DF:RebuildDirectFilterStrings()
    local db = DF:GetDB()
    if db then
        cachedBuffFilter = BuildDirectBuffFilter(db)
        cachedDebuffFilter = BuildDirectDebuffFilter(db)
    end
    -- Defensive and dispel are fixed, but clear to rebuild on next use
    cachedDefensiveFilter = nil
    cachedDispelFilter = nil
end

-- Scan a single unit with Direct API and populate DF.BlizzardAuraCache
local function ScanUnitDirect(unit)
    if not unit or not UnitExists(unit) then return end

    -- Get settings for this unit's frame type
    local frame = DF.unitFrameMap and DF.unitFrameMap[unit]
    local db
    if frame then
        db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    else
        db = DF:GetDB()
    end

    if not db or db.auraSourceMode ~= "DIRECT" then return end

    -- Initialize cache for this unit
    if not DF.BlizzardAuraCache[unit] then
        DF.BlizzardAuraCache[unit] = { buffs = {}, debuffs = {}, buffOrder = {}, debuffOrder = {}, playerDispellable = {}, defensives = {} }
    end
    local cache = DF.BlizzardAuraCache[unit]
    wipe(cache.buffs)
    wipe(cache.debuffs)
    wipe(cache.buffOrder)
    wipe(cache.debuffOrder)
    wipe(cache.playerDispellable)
    wipe(cache.defensives)

    local GetAuraDataByIndex = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not GetAuraDataByIndex then return end

    -- === BUFFS ===
    local buffFilter = cachedBuffFilter or BuildDirectBuffFilter(db)
    wipe(directBuffResults)
    local slot = 1
    while slot <= 40 do
        local auraData = GetAuraDataByIndex(unit, slot, buffFilter)
        if not auraData then break end
        directBuffResults[#directBuffResults + 1] = auraData
        slot = slot + 1
    end

    -- Apply sort if requested
    local buffSort = db.directBuffSortOrder or "DEFAULT"
    if buffSort == "TIME" and #directBuffResults > 1 then
        table.sort(directBuffResults, SortByTimeRemaining)
    elseif buffSort == "NAME" and #directBuffResults > 1 then
        table.sort(directBuffResults, SortByName)
    end

    -- Populate cache (same structure as Blizzard provider)
    for _, auraData in ipairs(directBuffResults) do
        local id = auraData.auraInstanceID
        if id then
            cache.buffs[id] = true
            cache.buffOrder[#cache.buffOrder + 1] = id
        end
    end

    -- === DEBUFFS ===
    local debuffFilter = cachedDebuffFilter or BuildDirectDebuffFilter(db)
    wipe(directDebuffResults)
    slot = 1
    while slot <= 40 do
        local auraData = GetAuraDataByIndex(unit, slot, debuffFilter)
        if not auraData then break end
        directDebuffResults[#directDebuffResults + 1] = auraData
        slot = slot + 1
    end

    local debuffSort = db.directDebuffSortOrder or "DEFAULT"
    if debuffSort == "TIME" and #directDebuffResults > 1 then
        table.sort(directDebuffResults, SortByTimeRemaining)
    elseif debuffSort == "NAME" and #directDebuffResults > 1 then
        table.sort(directDebuffResults, SortByName)
    end

    for _, auraData in ipairs(directDebuffResults) do
        local id = auraData.auraInstanceID
        if id then
            cache.debuffs[id] = true
            cache.debuffOrder[#cache.debuffOrder + 1] = id
        end
    end

    -- === DEFENSIVES (BIG_DEFENSIVE filter, multiple results) ===
    local defFilter = BuildDirectDefensiveFilter()
    slot = 1
    while slot <= 40 do
        local auraData = GetAuraDataByIndex(unit, slot, defFilter)
        if not auraData then break end
        local id = auraData.auraInstanceID
        if id then
            cache.defensives[id] = true
        end
        slot = slot + 1
    end

    -- === PLAYER DISPELLABLE ===
    local dispelFilter = BuildDirectDispelFilter()
    slot = 1
    while slot <= 40 do
        local auraData = GetAuraDataByIndex(unit, slot, dispelFilter)
        if not auraData then break end
        local id = auraData.auraInstanceID
        if id then
            cache.playerDispellable[id] = true
            -- Also add to debuffs if not already present
            if not cache.debuffs[id] then
                cache.debuffs[id] = true
                cache.debuffOrder[#cache.debuffOrder + 1] = id
            end
        end
        slot = slot + 1
    end
end

-- ============================================================
-- DIRECT MODE EVENT HANDLING
-- ============================================================

local directModeFrame = CreateFrame("Frame")
local directModeActive = false

local function OnDirectModeUnitAura(self, event, unit, updateInfo)
    if not unit then return end
    -- Only process units we care about (party/raid members with DF frames)
    if not DF.unitFrameMap or not DF.unitFrameMap[unit] then return end

    ScanUnitDirect(unit)
    TriggerAuraUpdateForUnit(unit)
end

function DF:EnableDirectAuraMode()
    if directModeActive then return end
    directModeActive = true

    directModeFrame:SetScript("OnEvent", OnDirectModeUnitAura)

    -- Register UNIT_AURA for all active units
    if DF.unitFrameMap then
        for unit in pairs(DF.unitFrameMap) do
            directModeFrame:RegisterUnitEvent("UNIT_AURA", unit)
        end
    end

    -- Rebuild filter strings from current settings
    DF:RebuildDirectFilterStrings()

    -- Do an initial full scan
    DF:DirectScanAllUnits()
end

function DF:DisableDirectAuraMode()
    if not directModeActive then return end
    directModeActive = false

    directModeFrame:UnregisterAllEvents()
    directModeFrame:SetScript("OnEvent", nil)
end

-- Full scan of all units currently in the frame map
function DF:DirectScanAllUnits()
    if not DF.unitFrameMap then return end
    for unit in pairs(DF.unitFrameMap) do
        ScanUnitDirect(unit)
        TriggerAuraUpdateForUnit(unit)
    end
end

-- Re-register when roster changes (units may change)
function DF:DirectModeRosterUpdate()
    if not directModeActive then return end
    if not DF.unitFrameMap then return end

    directModeFrame:UnregisterAllEvents()
    for unit in pairs(DF.unitFrameMap) do
        directModeFrame:RegisterUnitEvent("UNIT_AURA", unit)
    end

    -- Full scan after roster change
    DF:DirectScanAllUnits()
end

-- Switch between Blizzard and Direct modes
function DF:SetAuraSourceMode(mode)
    -- Clear all caches so stale data doesn't persist
    wipe(DF.BlizzardAuraCache)

    if mode == "DIRECT" then
        DF:EnableDirectAuraMode()
    else
        DF:DisableDirectAuraMode()
        -- Re-prime Blizzard cache
        ScanAllBlizzardFrames()
    end

    -- Update Blizzard frame visibility (fully disable in Direct mode, restore in Blizzard mode)
    C_Timer.After(0.1, function()
        if DF.UpdateBlizzardFrameVisibility then
            DF:UpdateBlizzardFrameVisibility()
        end
    end)
end

-- ============================================================
-- HOOK BLIZZARD'S COMPACT RAID FRAMES
-- ============================================================

local function SetupBlizzardHooks()
    -- Hook the main aura update function - capture and trigger our update
    if CompactUnitFrame_UpdateAuras then
        hooksecurefunc("CompactUnitFrame_UpdateAuras", function(frame)
            -- Skip frames in invalid states
            if not frame or frame.unitExists == false then return end
            CaptureAurasFromBlizzardFrame(frame, true)
        end)
        DF.BlizzardHookActive = true
    end
    
    -- Also hook UpdateBuffs and UpdateDebuffs if they exist separately
    if CompactUnitFrame_UpdateBuffs then
        hooksecurefunc("CompactUnitFrame_UpdateBuffs", function(frame)
            if not frame or frame.unitExists == false then return end
            CaptureAurasFromBlizzardFrame(frame, true)
        end)
    end
    
    if CompactUnitFrame_UpdateDebuffs then
        hooksecurefunc("CompactUnitFrame_UpdateDebuffs", function(frame)
            if not frame or frame.unitExists == false then return end
            CaptureAurasFromBlizzardFrame(frame, true)
        end)
    end
end

-- ============================================================
-- EVENT FRAME FOR PROACTIVE UPDATES
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

-- Apply our saved Blizzard frame settings via CVars only (not optionTable)
-- Modifying optionTable causes protected value errors in combat
local function ApplyBlizzardFrameSettings()
    if not DF.db or not DF.db.party then return end
    
    local db = DF.db.party
    
    local dispelIndicator = db._blizzDispelIndicator
    local onlyDispellable = db._blizzOnlyDispellable
    
    -- Force dispel indicator to be at least 1 (never disabled)
    if dispelIndicator == nil or dispelIndicator == 0 then
        dispelIndicator = 1
        db._blizzDispelIndicator = 1
    end
    
    -- Set via CVar only - do NOT modify optionTable
    SetCVar("raidFramesDispelIndicatorType", dispelIndicator)
    
    if onlyDispellable ~= nil then
        SetCVar("raidFramesDisplayOnlyDispellableDebuffs", onlyDispellable and 1 or 0)
    end
end

-- Export for use elsewhere
DF.ApplyBlizzardFrameSettings = ApplyBlizzardFrameSettings

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "GROUP_ROSTER_UPDATE" then
        if DF.RosterDebugEvent then DF:RosterDebugEvent("Auras.lua(blizz):GROUP_ROSTER_UPDATE") end
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
        -- Mark hooks as initializing (kept for potential future use)
        DF.blizzardHooksFullyActive = false

        -- Full scan after delays to let Blizzard frames initialize
        C_Timer.After(0.1, ScanAllBlizzardFrames)
        C_Timer.After(0.5, ScanAllBlizzardFrames)
        C_Timer.After(1.5, function()
            ScanAllBlizzardFrames()
            DF.blizzardHooksFullyActive = true
        end)

        -- Also apply our saved Blizzard settings
        C_Timer.After(0.2, ApplyBlizzardFrameSettings)
        C_Timer.After(1.0, ApplyBlizzardFrameSettings)

        -- Direct mode: re-register unit events for new roster
        local db = DF.db and DF.db.party
        local raidDb = DF.db and DF.db.raid
        local isDirectMode = (db and db.auraSourceMode == "DIRECT") or (raidDb and raidDb.auraSourceMode == "DIRECT")
        if isDirectMode then
            C_Timer.After(0.2, function() DF:DirectModeRosterUpdate() end)
        end
    end
end)

-- ============================================================
-- CHECK IF AURA SHOULD BE SHOWN (Using Blizzard's decisions)
-- ============================================================

local function IsAuraApprovedByBlizzard(unit, auraInstanceID, auraType)
    local cache = DF.BlizzardAuraCache[unit]
    if not cache then return false end  -- No cache = don't show aura (no fallback)
    
    if auraType == "BUFF" then
        return cache.buffs[auraInstanceID] == true
    else
        return cache.debuffs[auraInstanceID] == true
    end
end

-- Check if a debuff is dispellable by the current player
-- This uses Blizzard's dispelDebuffFrames which only show debuffs the player can dispel
-- Returns: true = player can dispel, false = player cannot dispel, nil = no cache data
local function IsPlayerDispellable(unit, auraInstanceID)
    local cache = DF.BlizzardAuraCache[unit]
    if not cache then return nil end
    
    return cache.playerDispellable[auraInstanceID] == true
end

-- Export for use in other modules (e.g., Features/Dispel.lua)
DF.IsPlayerDispellable = IsPlayerDispellable

-- Check if the current player has any buff applied to a unit
-- Blizzard's buffFrames on raid frames already only shows buffs YOU cast
-- So we just check if there's anything in the buffs cache
-- Out of combat: filter out raid buffs (like Mark of the Wild) by checking icon texture
-- In combat: can't read aura data, so trust the cache as-is
-- In encounter (M+/boss): aura data is protected even out of combat
--   - In combat: skip filtering, trust cache (same as normal combat)
--   - Out of combat: return false to hide indicators (can't filter, showing raid buff indicators would be misleading)
-- Returns: true = player has a (non-raid) buff on unit, false = no relevant buffs from player
local function UnitHasMyBuff(unit)
    local cache = DF.BlizzardAuraCache and DF.BlizzardAuraCache[unit]
    if not cache then return false end
    
    -- Quick check - if no buffs at all, return false
    if not next(cache.buffs) then return false end
    
    -- Encounter check (M+ keystones, boss fights) - aura data is protected
    local inEncounter = IsEncounterInProgress and IsEncounterInProgress()
    if inEncounter then
        if InCombatLockdown() then
            -- In encounter + in combat: can't filter, trust cache as-is
            return true
        else
            -- In encounter + out of combat: disable to avoid raid buff false positives
            return false
        end
    end
    
    -- In combat (non-encounter), aura data is secret - just check if any buff exists
    if InCombatLockdown() then
        return true
    end
    
    -- Out of combat, not in encounter - safe to filter out raid buffs by icon texture
    local raidBuffIcons = DF.GetRaidBuffIcons and DF:GetRaidBuffIcons()
    
    for auraInstanceID in pairs(cache.buffs) do
        -- Safety: skip secret auraInstanceIDs (shouldn't happen but belt-and-suspenders)
        if issecretvalue(auraInstanceID) then
            return true
        end
        
        local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID)
        if auraData then
            local auraIconTexture = auraData.icon
            -- Check if it's a raid buff by icon texture
            local isRaidBuff = false
            if raidBuffIcons and auraIconTexture and not issecretvalue(auraIconTexture) then
                isRaidBuff = raidBuffIcons[auraIconTexture] == true
            end
            
            if not isRaidBuff then
                -- Found a non-raid buff (HoT, shield, etc.)
                return true
            end
        end
    end
    
    -- Only raid buffs found (or couldn't read data)
    return false
end

-- Export for use in other modules (e.g., Features/MyBuffIndicators.lua)
DF.UnitHasMyBuff = UnitHasMyBuff

-- ============================================================
-- AURA COLLECTION FUNCTIONS
-- ============================================================

-- Collect buffs using Blizzard's cached decisions
-- We ONLY check auraInstanceID against our cache - no reading aura properties
local function CollectBuffs_Blizzard(unit, maxAuras)
    ReleaseAndWipe(reusableBuffs)  -- Return entries to pool before reusing array
    local buffs = reusableBuffs
    local filter = "HELPFUL"
    local slot = 1
    local cache = DF.BlizzardAuraCache[unit]
    
    if not cache then return buffs end
    
    while #buffs < maxAuras and slot <= 40 do
        local auraData = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex(unit, slot, filter)
        if not auraData then break end
        
        -- Get auraInstanceID - this is safe, it's just an integer
        local auraInstanceID = auraData.auraInstanceID
        
        -- Check if Blizzard approved this aura
        if auraInstanceID and cache.buffs[auraInstanceID] then
            local entry = AcquireTable()
            entry.slot = slot
            entry.data = auraData
            buffs[#buffs + 1] = entry
        end
        
        slot = slot + 1
    end
    
    return buffs
end

-- Collect debuffs using Blizzard's cached decisions
local function CollectDebuffs_Blizzard(unit, maxAuras)
    ReleaseAndWipe(reusableDebuffs)  -- Return entries to pool before reusing array
    local debuffs = reusableDebuffs
    local filter = "HARMFUL"
    local slot = 1
    local cache = DF.BlizzardAuraCache[unit]
    
    if not cache then return debuffs end
    
    while #debuffs < maxAuras and slot <= 40 do
        local auraData = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex(unit, slot, filter)
        if not auraData then break end
        
        local auraInstanceID = auraData.auraInstanceID
        
        if auraInstanceID and cache.debuffs[auraInstanceID] then
            local entry = AcquireTable()
            entry.slot = slot
            entry.data = auraData
            debuffs[#debuffs + 1] = entry
        end
        
        slot = slot + 1
    end
    
    return debuffs
end

-- ============================================================
-- MAIN COLLECTION API
-- ============================================================

-- Collect buffs using Blizzard's cached decisions only
-- Returns empty array if Blizzard cache not available (NO FALLBACK)
function DF:CollectBuffs(unit, maxAuras)
    local cache = DF.BlizzardAuraCache[unit]
    if not cache then
        -- CRITICAL: Must wipe before returning to avoid stale data
        ReleaseAndWipe(reusableBuffs)
        return reusableBuffs
    end
    return CollectBuffs_Blizzard(unit, maxAuras)
end

-- Collect debuffs using Blizzard's cached decisions only
-- Returns empty array if Blizzard cache not available (NO FALLBACK)
function DF:CollectDebuffs(unit, maxAuras)
    local cache = DF.BlizzardAuraCache[unit]
    if not cache then
        -- CRITICAL: Must wipe before returning to avoid stale data
        ReleaseAndWipe(reusableDebuffs)
        return reusableDebuffs
    end
    return CollectDebuffs_Blizzard(unit, maxAuras)
end

-- ============================================================
-- ENHANCED AURA ICON UPDATE
-- ============================================================

function DF:UpdateAuraIcons_Enhanced(frame, icons, auraType, maxAuras)
    local unit = frame.unit
    -- Use raid DB for raid frames, party DB for party frames
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    
    local auras
    if auraType == "BUFF" then
        auras = DF:CollectBuffs(unit, maxAuras)
    else
        auras = DF:CollectDebuffs(unit, maxAuras)
    end
    
    -- Get raid buff icons for filtering (only for buffs, out of combat, not in encounter, when option enabled)
    local raidBuffIcons = nil
    local inEncounter = IsEncounterInProgress and IsEncounterInProgress()
    local shouldFilterRaidBuffs = auraType == "BUFF" and db.missingBuffHideFromBar and not InCombatLockdown() and not inEncounter
    if shouldFilterRaidBuffs then
        raidBuffIcons = DF:GetRaidBuffIcons()
    end

    -- Defensive/AD deduplication: skip buffs already shown in defensive bar or Aura Designer
    local dedupSet = nil
    local cache = DF.BlizzardAuraCache[unit]
    if auraType == "BUFF" and db.buffDeduplicateDefensives then
        if cache and cache.defensives and next(cache.defensives) then
            dedupSet = cache.defensives
        end
        local adIDs = frame.dfAD_activeInstanceIDs
        if adIDs and next(adIDs) then
            if dedupSet then
                if not frame.dfDedup then frame.dfDedup = {} end
                wipe(frame.dfDedup)
                for id in pairs(dedupSet) do frame.dfDedup[id] = true end
                for id in pairs(adIDs) do frame.dfDedup[id] = true end
                dedupSet = frame.dfDedup
            else
                dedupSet = adIDs
            end
        end
    end

    local displayedCount = 0
    for i, auraInfo in ipairs(auras) do
        if displayedCount >= maxAuras then break end

        -- Dedup: skip buffs already shown in defensive bar or Aura Designer
        local auraInstanceID = auraInfo.data and auraInfo.data.auraInstanceID
        if dedupSet and auraInstanceID and dedupSet[auraInstanceID] then
            -- skip this aura entirely
        else

        local icon = icons[displayedCount + 1]
        if not icon then break end

        local auraData = auraInfo.data
        local canDisplay = false
        local skipAura = false

        -- Set icon texture
        local auraIconTexture = auraData.icon
        if auraIconTexture then
            canDisplay = SafeSetTexture(icon, auraIconTexture)
        end

        -- Check if this is a raid buff we should skip
        -- Note: auraIconTexture may be a secret value - can't use secrets as table keys
        if canDisplay and shouldFilterRaidBuffs and raidBuffIcons and auraIconTexture then
            -- Only do lookup if not a secret value
            if not issecretvalue(auraIconTexture) and raidBuffIcons[auraIconTexture] then
                skipAura = true
            end
        end

        if canDisplay and not skipAura then
            displayedCount = displayedCount + 1
            
            -- PERFORMANCE FIX: Reuse auraData table instead of creating new one every update
            if not icon.auraData then
                icon.auraData = { index = 0, auraInstanceID = nil }
            end
            icon.auraData.index = auraInfo.slot
            icon.auraData.auraInstanceID = nil  -- Reset before setting
            
            local auraInstanceID = auraData.auraInstanceID
            icon.auraData.auraInstanceID = auraInstanceID

            -- Compute hasExpiration BEFORE SafeSetCooldown so we can pre-hide native text
            -- This prevents flickering when a timed aura's icon slot gets reassigned to a permanent aura
            icon.expirationTime = nil
            icon.auraDuration = nil
            icon.hasExpiration = false

            if auraInstanceID and C_UnitAuras and C_UnitAuras.DoesAuraHaveExpirationTime then
                icon.hasExpiration = C_UnitAuras.DoesAuraHaveExpirationTime(unit, auraInstanceID)
                icon.expirationTime = auraData.expirationTime
                icon.auraDuration = auraData.duration
            else
                if auraData.expirationTime and auraData.expirationTime > 0 then
                    icon.expirationTime = auraData.expirationTime
                    icon.hasExpiration = true
                end
                if auraData.duration and auraData.duration > 0 then
                    icon.auraDuration = auraData.duration
                end
            end

            -- Set cooldown
            SafeSetCooldown(icon.cooldown, auraData.expirationTime, auraData.duration)
            
            -- Set stack count using new API if available
            icon.count:SetText("")
            local stackMinimum = icon.stackMinimum or 2
            
            if auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
                -- Use new API - pass min and max display count
                -- API returns empty string if below min, "*" if above max, otherwise the count
                local stackText = C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID, stackMinimum, 99)
                if stackText then
                    -- SetText can handle the secret value directly
                    icon.count:SetText(stackText)
                end
            end
            
            -- Show/hide cooldown (swipe + native countdown text) based on whether aura expires
            -- Hiding the cooldown frame also hides the native countdown text (as its child)
            -- This is the primary mechanism for hiding duration text on permanent buffs
            if icon.cooldown then
                if icon.cooldown.SetShownFromBoolean then
                    icon.cooldown:SetShownFromBoolean(icon.hasExpiration, true, false)
                else
                    icon.cooldown:Show()
                end
            end

            -- Our custom duration FontString (separate from native text) — show/hide based on hasExpiration
            if icon.duration then
                if icon.showDuration then
                    if icon.duration.SetShownFromBoolean then
                        icon.duration:SetShownFromBoolean(icon.hasExpiration, true, false)
                    else
                        icon.duration:Show()
                    end
                else
                    icon.duration:Hide()
                end
            end

            -- Note: Expiring indicators are managed by the icon's OnUpdate script
            -- We don't hide/reset them here to avoid flickering when auras refresh
            
            -- Check if Masque is actually controlling borders (enabled in settings AND Masque group is active)
            local masqueGroup = auraType == "BUFF" and DF.MasqueGroup_Buffs or DF.MasqueGroup_Debuffs
            local masqueActive = masqueGroup and masqueGroup.IsDisabled and not masqueGroup:IsDisabled()
            local masqueBorderControl = db.masqueBorderControl and DF.Masque and masqueActive
            
            -- Check if unit is dead/offline - use neutral border color to prevent
            -- colored border showing through faded icon texture
            local unitDeadOrOffline = UnitIsDeadOrGhost(unit) or not UnitIsConnected(unit)
            
            -- Set border color (normal border, not expiring) - only if we control borders
            local borderEnabled = auraType == "DEBUFF" and db.debuffBorderEnabled ~= false or db.buffBorderEnabled ~= false
            if borderEnabled and not masqueBorderControl then
                if auraType == "DEBUFF" and not unitDeadOrOffline then
                    -- Use custom dispel type colors if enabled, via color curve API
                    -- Only for living units - dead units can't be dispelled so colored border is meaningless
                    if db.debuffBorderColorByType ~= false and auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor and C_CurveUtil and C_CurveUtil.CreateColorCurve then
                        -- Build or get cached debuff border color curve
                        DF.debuffBorderCurve = DF.debuffBorderCurve or nil
                        if not DF.debuffBorderCurve then
                            local curve = C_CurveUtil.CreateColorCurve()
                            curve:SetType(Enum.LuaCurveType.Step)
                            
                            -- Dispel type enum values from wago.tools/db2/SpellDispelType
                            -- None = 0, Magic = 1, Curse = 2, Disease = 3, Poison = 4, Enrage = 9, Bleed = 11
                            local noneColor = db.debuffBorderColorNone or {r = 0.8, g = 0.0, b = 0.0}
                            local magicColor = db.debuffBorderColorMagic or {r = 0.2, g = 0.6, b = 1.0}
                            local curseColor = db.debuffBorderColorCurse or {r = 0.6, g = 0.0, b = 1.0}
                            local diseaseColor = db.debuffBorderColorDisease or {r = 0.6, g = 0.4, b = 0.0}
                            local poisonColor = db.debuffBorderColorPoison or {r = 0.0, g = 0.6, b = 0.0}
                            local bleedColor = db.debuffBorderColorBleed or {r = 1.0, g = 0.0, b = 0.0}
                            
                            curve:AddPoint(0, CreateColor(noneColor.r, noneColor.g, noneColor.b, 0.8))   -- None
                            curve:AddPoint(1, CreateColor(magicColor.r, magicColor.g, magicColor.b, 0.8))   -- Magic
                            curve:AddPoint(2, CreateColor(curseColor.r, curseColor.g, curseColor.b, 0.8))   -- Curse
                            curve:AddPoint(3, CreateColor(diseaseColor.r, diseaseColor.g, diseaseColor.b, 0.8)) -- Disease
                            curve:AddPoint(4, CreateColor(poisonColor.r, poisonColor.g, poisonColor.b, 0.8))   -- Poison
                            curve:AddPoint(9, CreateColor(bleedColor.r, bleedColor.g, bleedColor.b, 0.8))   -- Enrage
                            curve:AddPoint(11, CreateColor(bleedColor.r, bleedColor.g, bleedColor.b, 0.8))  -- Bleed
                            
                            DF.debuffBorderCurve = curve
                        end
                        
                        -- Get color from API
                        local borderColor = C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, DF.debuffBorderCurve)
                        if borderColor then
                            local r, g, b, a = 0.8, 0, 0, 0.8
                            if borderColor.GetRGBA then
                                r, g, b, a = borderColor:GetRGBA()
                            elseif borderColor.r then
                                r, g, b, a = borderColor.r, borderColor.g, borderColor.b, borderColor.a or 0.8
                            end
                            icon.border:SetColorTexture(r, g, b, a)
                        else
                            -- Fallback to none color
                            local c = db.debuffBorderColorNone or {r = 0.8, g = 0, b = 0}
                            icon.border:SetColorTexture(c.r, c.g, c.b, 0.8)
                        end
                    else
                        -- Color by type disabled or API not available - use default red
                        icon.border:SetColorTexture(0.8, 0, 0, 0.8)
                    end
                else
                    icon.border:SetColorTexture(0, 0, 0, 0.8)  -- Black for buffs and dead/offline debuffs
                end
                icon.border:Show()
            elseif not masqueBorderControl then
                icon.border:Hide()
            end
            -- When masqueBorderControl is true, border visibility is handled by ApplyAuraLayout
            
            -- Find native cooldown text if not already cached (for duration text)
            if not icon.nativeCooldownText and icon.cooldown then
                local regions = {icon.cooldown:GetRegions()}
                for _, region in ipairs(regions) do
                    if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                        icon.nativeCooldownText = region

                        -- IMMEDIATELY apply font settings to prevent large default font flash
                        -- This fixes the "big numbers" issue on first buff application
                        local prefix = auraType == "BUFF" and "buff" or "debuff"
                        local durationScale = db[prefix .. "DurationScale"] or 1.0
                        local durationFont = db[prefix .. "DurationFont"] or "Fonts\\FRIZQT__.TTF"
                        local durationOutline = db[prefix .. "DurationOutline"] or "OUTLINE"
                        if durationOutline == "NONE" then durationOutline = "" end
                        local durationSize = 10 * durationScale
                        local durationX = db[prefix .. "DurationX"] or 0
                        local durationY = db[prefix .. "DurationY"] or 0
                        local durationAnchor = db[prefix .. "DurationAnchor"] or "CENTER"

                        if DF.SafeSetFont then
                            DF:SafeSetFont(region, durationFont, durationSize, durationOutline)
                        end

                        -- Keep native text as child of cooldown (NOT reparented)
                        -- When cooldown is hidden for permanent buffs, the text hides automatically as a child
                        -- Position it where the user configured (ClearAllPoints works across parents)
                        region:ClearAllPoints()
                        region:SetPoint(durationAnchor, icon, durationAnchor, durationX, durationY)

                        -- Tell Blizzard's cooldown to show/hide countdown numbers based on user setting
                        -- This prevents Blizzard's C code from overriding our visibility control
                        if icon.cooldown.SetHideCountdownNumbers then
                            icon.cooldown:SetHideCountdownNumbers(not icon.showDuration)
                        end

                        break
                    end
                end
            end
            
            icon:Show()
            
            -- Register for shared timer updates
            DF:RegisterIconForAuraTimer(icon)
        end
        end -- dedup else
    end

    -- Hide remaining icons
    for i = displayedCount + 1, #icons do
        local icon = icons[i]
        icon.auraData = nil
        icon.testAuraData = nil  -- Clear test mode flag too
        icon.expirationTime = nil
        icon.auraDuration = nil
        if icon.duration then icon.duration:Hide() end
        if icon.expiringTint then icon.expiringTint:Hide() end
        if icon.expiringBorderAlphaContainer then
            icon.expiringBorderAlphaContainer:Hide()
            if icon.expiringBorderPulse and icon.expiringBorderPulse:IsPlaying() then
                icon.expiringBorderPulse:Stop()
            end
        end
        icon:Hide()
    end
    
    -- Store displayed count for center growth repositioning
    local countKey = auraType == "BUFF" and "buffDisplayedCount" or "debuffDisplayedCount"
    frame[countKey] = displayedCount
    
    -- Reposition icons if using center growth (now that we know the count)
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    local prefix = auraType == "BUFF" and "buff" or "debuff"
    local growth = db[prefix .. "Growth"] or (auraType == "BUFF" and "LEFT_UP" or "RIGHT_UP")
    local primary = strsplit("_", growth)
    
    if primary == "CENTER" and displayedCount > 0 then
        DF:RepositionCenterGrowthIcons(frame, icons, auraType, displayedCount)
    end
end

-- ============================================================
-- DIRECT AURA UPDATE (Merged Tier 1+2+3 optimization)
--
-- Merges collection and display into a single pass:
--   - Iterates approved auraInstanceIDs from BlizzardAuraCache directly (Tier 2 flip)
--   - Calls GetAuraDataByAuraInstanceID per ID instead of scanning slots 1-40 (Tier 2)
--   - Applies data directly to icon frames with no intermediate tables (Tier 3)
--   - All API lookups cached as file-scope locals (Tier 1)
--
-- Typical cost: O(approved_auras) ≈ 3-4 API calls per aura type
-- Old cost:     O(total_unit_auras) ≈ 30+ API calls per aura type
-- ============================================================

function DF:UpdateAuraIconsDirect(frame, icons, auraType, maxAuras)
    local unit = frame.unit
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    
    -- Quick out: no cache = no approved auras = hide everything
    local cache = DF.BlizzardAuraCache[unit]
    local cacheSet = cache and (auraType == "BUFF" and cache.buffs or cache.debuffs)
    if not cacheSet then
        for i = 1, #icons do
            local icon = icons[i]
            icon.auraData = nil
            icon.testAuraData = nil
            icon.expirationTime = nil
            icon.auraDuration = nil
            if icon.duration then icon.duration:Hide() end
            if icon.expiringTint then icon.expiringTint:Hide() end
            if icon.expiringBorderAlphaContainer then
                icon.expiringBorderAlphaContainer:Hide()
                if icon.expiringBorderPulse and icon.expiringBorderPulse:IsPlaying() then
                    icon.expiringBorderPulse:Stop()
                end
            end
            icon:Hide()
        end
        local countKey = auraType == "BUFF" and "buffDisplayedCount" or "debuffDisplayedCount"
        frame[countKey] = 0
        return
    end
    
    -- Raid buff filtering (buffs only, out of combat, not in encounter, when option enabled)
    local raidBuffIcons = nil
    local inEncounter = IsEncounterInProgress and IsEncounterInProgress()
    local shouldFilterRaidBuffs = auraType == "BUFF" and db.missingBuffHideFromBar and not InCombatLockdown() and not inEncounter
    if shouldFilterRaidBuffs then
        raidBuffIcons = DF:GetRaidBuffIcons()
    end

    -- Defensive/AD deduplication: skip buffs already shown in defensive bar or Aura Designer
    local dedupSet = nil
    if auraType == "BUFF" and db.buffDeduplicateDefensives then
        -- Defensive bar auraInstanceIDs
        if cache and cache.defensives and next(cache.defensives) then
            dedupSet = cache.defensives
        end
        -- Aura Designer active auraInstanceIDs
        local adIDs = frame.dfAD_activeInstanceIDs
        if adIDs and next(adIDs) then
            if dedupSet then
                -- Merge: build a combined set (defensive + AD)
                if not frame.dfDedup then frame.dfDedup = {} end
                wipe(frame.dfDedup)
                for id in pairs(dedupSet) do frame.dfDedup[id] = true end
                for id in pairs(adIDs) do frame.dfDedup[id] = true end
                dedupSet = frame.dfDedup
            else
                dedupSet = adIDs
            end
        end
    end

    -- Pre-fetch: Masque state (once per call, not per icon)
    local masqueGroup = auraType == "BUFF" and DF.MasqueGroup_Buffs or DF.MasqueGroup_Debuffs
    local masqueActive = masqueGroup and masqueGroup.IsDisabled and not masqueGroup:IsDisabled()
    local masqueBorderControl = db.masqueBorderControl and DF.Masque and masqueActive

    -- Pre-fetch: border enabled (once per call)
    local borderEnabled = auraType == "DEBUFF" and db.debuffBorderEnabled ~= false or db.buffBorderEnabled ~= false

    -- Pre-fetch: dead/offline state (once per call, not per icon)
    local unitDeadOrOffline = UnitIsDeadOrGhost(unit) or not UnitIsConnected(unit)

    -- Pre-fetch: duration font settings for nativeCooldownText first-time setup
    local prefix = auraType == "BUFF" and "buff" or "debuff"
    local durationScale = db[prefix .. "DurationScale"] or 1.0
    local durationFont = db[prefix .. "DurationFont"] or "Fonts\\FRIZQT__.TTF"
    local durationOutline = db[prefix .. "DurationOutline"] or "OUTLINE"
    if durationOutline == "NONE" then durationOutline = "" end
    local durationSize = 10 * durationScale
    local durationX = db[prefix .. "DurationX"] or 0
    local durationY = db[prefix .. "DurationY"] or 0
    local durationAnchor = db[prefix .. "DurationAnchor"] or "CENTER"
    
    -- Iterate in Blizzard's display order (captured from buffFrames/debuffFrames)
    -- This matches how Blizzard sorts auras on their default CompactUnitFrames
    local displayedCount = 0
    local orderList = cache and (auraType == "BUFF" and cache.buffOrder or cache.debuffOrder)

    if orderList then
        for i = 1, #orderList do
            if displayedCount >= maxAuras then break end

            local auraInstanceID = orderList[i]

            -- Dedup: skip buffs already shown in defensive bar or Aura Designer
            if dedupSet and dedupSet[auraInstanceID] then
                -- skip this aura entirely
            else

            -- Fetch aura data by instance ID (secret-safe: we only use the ID for lookup)
            local auraData = GetAuraDataByAuraInstanceID and GetAuraDataByAuraInstanceID(unit, auraInstanceID)
            if auraData then
                -- Guard: ensure we have an icon slot available
                local nextIcon = icons[displayedCount + 1]
                if not nextIcon then break end

                -- Set texture (validates the aura is displayable)
                local auraIconTexture = auraData.icon
                local canDisplay = false
                if auraIconTexture then
                    canDisplay = SafeSetTexture(nextIcon, auraIconTexture)
                end

                -- Check raid buff filtering
                local skipAura = false
                if canDisplay and shouldFilterRaidBuffs and raidBuffIcons and auraIconTexture then
                    if not issecretvalue(auraIconTexture) and raidBuffIcons[auraIconTexture] then
                        skipAura = true
                    end
                end

                if canDisplay and not skipAura then
                    displayedCount = displayedCount + 1
                    local icon = icons[displayedCount]
                    -- Note: texture already set by SafeSetTexture above

                    -- Store aura tracking data (reuse existing table)
                    if not icon.auraData then
                        icon.auraData = { index = 0, auraInstanceID = nil }
                    end
                    icon.auraData.index = i
                    icon.auraData.auraInstanceID = auraInstanceID

                    -- Compute hasExpiration BEFORE SafeSetCooldown so we can pre-hide native text
                    -- This prevents flickering when a timed aura's icon slot gets reassigned to a permanent aura
                    icon.expirationTime = nil
                    icon.auraDuration = nil
                    icon.hasExpiration = false

                    if C_UnitAuras.DoesAuraHaveExpirationTime then
                        icon.hasExpiration = C_UnitAuras.DoesAuraHaveExpirationTime(unit, auraInstanceID)
                        icon.expirationTime = auraData.expirationTime
                        icon.auraDuration = auraData.duration
                    else
                        if auraData.expirationTime and auraData.expirationTime > 0 then
                            icon.expirationTime = auraData.expirationTime
                            icon.hasExpiration = true
                        end
                        if auraData.duration and auraData.duration > 0 then
                            icon.auraDuration = auraData.duration
                        end
                    end

                    -- Set cooldown
                    SafeSetCooldown(icon.cooldown, auraData.expirationTime, auraData.duration)

                    -- Stack count
                    icon.count:SetText("")
                    local stackMinimum = icon.stackMinimum or 2
                    if C_UnitAuras.GetAuraApplicationDisplayCount then
                        local stackText = C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID, stackMinimum, 99)
                        if stackText then
                            icon.count:SetText(stackText)
                        end
                    end

                    -- Show/hide cooldown (swipe + native countdown text) based on whether aura expires
                    -- Hiding the cooldown frame also hides the native countdown text (as its child)
                    if icon.cooldown then
                        if icon.cooldown.SetShownFromBoolean then
                            icon.cooldown:SetShownFromBoolean(icon.hasExpiration, true, false)
                        else
                            icon.cooldown:Show()
                        end
                    end

                    -- Our custom duration FontString — show/hide based on hasExpiration
                    if icon.duration then
                        if icon.showDuration then
                            if icon.duration.SetShownFromBoolean then
                                icon.duration:SetShownFromBoolean(icon.hasExpiration, true, false)
                            else
                                icon.duration:Show()
                            end
                        else
                            icon.duration:Hide()
                        end
                    end

                    -- Border color (normal, not expiring)
                    if borderEnabled and not masqueBorderControl then
                        if auraType == "DEBUFF" and not unitDeadOrOffline then
                            if db.debuffBorderColorByType ~= false and C_UnitAuras.GetAuraDispelTypeColor and C_CurveUtil and C_CurveUtil.CreateColorCurve then
                                if not DF.debuffBorderCurve then
                                    local curve = C_CurveUtil.CreateColorCurve()
                                    curve:SetType(Enum.LuaCurveType.Step)

                                    local noneColor = db.debuffBorderColorNone or {r = 0.8, g = 0.0, b = 0.0}
                                    local magicColor = db.debuffBorderColorMagic or {r = 0.2, g = 0.6, b = 1.0}
                                    local curseColor = db.debuffBorderColorCurse or {r = 0.6, g = 0.0, b = 1.0}
                                    local diseaseColor = db.debuffBorderColorDisease or {r = 0.6, g = 0.4, b = 0.0}
                                    local poisonColor = db.debuffBorderColorPoison or {r = 0.0, g = 0.6, b = 0.0}
                                    local bleedColor = db.debuffBorderColorBleed or {r = 1.0, g = 0.0, b = 0.0}

                                    curve:AddPoint(0, CreateColor(noneColor.r, noneColor.g, noneColor.b, 0.8))
                                    curve:AddPoint(1, CreateColor(magicColor.r, magicColor.g, magicColor.b, 0.8))
                                    curve:AddPoint(2, CreateColor(curseColor.r, curseColor.g, curseColor.b, 0.8))
                                    curve:AddPoint(3, CreateColor(diseaseColor.r, diseaseColor.g, diseaseColor.b, 0.8))
                                    curve:AddPoint(4, CreateColor(poisonColor.r, poisonColor.g, poisonColor.b, 0.8))
                                    curve:AddPoint(9, CreateColor(bleedColor.r, bleedColor.g, bleedColor.b, 0.8))
                                    curve:AddPoint(11, CreateColor(bleedColor.r, bleedColor.g, bleedColor.b, 0.8))

                                    DF.debuffBorderCurve = curve
                                end

                                local borderColor = C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, DF.debuffBorderCurve)
                                if borderColor then
                                    local r, g, b, a = 0.8, 0, 0, 0.8
                                    if borderColor.GetRGBA then
                                        r, g, b, a = borderColor:GetRGBA()
                                    elseif borderColor.r then
                                        r, g, b, a = borderColor.r, borderColor.g, borderColor.b, borderColor.a or 0.8
                                    end
                                    icon.border:SetColorTexture(r, g, b, a)
                                else
                                    local c = db.debuffBorderColorNone or {r = 0.8, g = 0, b = 0}
                                    icon.border:SetColorTexture(c.r, c.g, c.b, 0.8)
                                end
                            else
                                icon.border:SetColorTexture(0.8, 0, 0, 0.8)
                            end
                        else
                            icon.border:SetColorTexture(0, 0, 0, 0.8)
                        end
                        icon.border:Show()
                    elseif not masqueBorderControl then
                        icon.border:Hide()
                    end

                    -- Find native cooldown text (first time only, cached on icon)
                    if not icon.nativeCooldownText and icon.cooldown then
                        local regions = {icon.cooldown:GetRegions()}
                        for _, region in ipairs(regions) do
                            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                                icon.nativeCooldownText = region

                                -- Immediately apply font settings to prevent large default font flash
                                if DF.SafeSetFont then
                                    DF:SafeSetFont(region, durationFont, durationSize, durationOutline)
                                end

                                -- Keep native text as child of cooldown (NOT reparented)
                                -- When cooldown is hidden for permanent buffs, the text hides automatically
                                region:ClearAllPoints()
                                region:SetPoint(durationAnchor, icon, durationAnchor, durationX, durationY)

                                -- Tell Blizzard's cooldown to show/hide countdown numbers based on user setting
                                if icon.cooldown.SetHideCountdownNumbers then
                                    icon.cooldown:SetHideCountdownNumbers(not icon.showDuration)
                                end

                                break
                            end
                        end
                    end

                    icon:Show()

                    -- Register for shared timer updates
                    DF:RegisterIconForAuraTimer(icon)
                end
            end
            end -- dedup else
        end
    end

    -- Legacy: slot-ordered iteration (walks aura slots 1-40, which is application order, not Blizzard's display order)
    -- Kept for reference in case we want a slot-based option in the future
    --[[
    local auraFilter = auraType == "BUFF" and "HELPFUL" or "HARMFUL"
    local slot = 1
    while displayedCount < maxAuras and slot <= 40 do
        local auraData = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex(unit, slot, auraFilter)
        if not auraData then break end
        local auraInstanceID = auraData.auraInstanceID
        if auraInstanceID and cacheSet[auraInstanceID] then
            -- ... display logic ...
        end
        slot = slot + 1
    end
    --]]
    
    -- Hide remaining icons
    for i = displayedCount + 1, #icons do
        local icon = icons[i]
        icon.auraData = nil
        icon.testAuraData = nil
        icon.expirationTime = nil
        icon.auraDuration = nil
        if icon.duration then icon.duration:Hide() end
        if icon.expiringTint then icon.expiringTint:Hide() end
        if icon.expiringBorderAlphaContainer then
            icon.expiringBorderAlphaContainer:Hide()
            if icon.expiringBorderPulse and icon.expiringBorderPulse:IsPlaying() then
                icon.expiringBorderPulse:Stop()
            end
        end
        icon:Hide()
    end
    
    -- Store displayed count for center growth repositioning
    local countKey = auraType == "BUFF" and "buffDisplayedCount" or "debuffDisplayedCount"
    frame[countKey] = displayedCount
    
    -- Reposition icons if using center growth
    local growth = db[prefix .. "Growth"] or (auraType == "BUFF" and "LEFT_UP" or "RIGHT_UP")
    local primary = strsplit("_", growth)
    
    if primary == "CENTER" and displayedCount > 0 then
        DF:RepositionCenterGrowthIcons(frame, icons, auraType, displayedCount)
    end
end

-- ============================================================
-- CENTER GROWTH REPOSITIONING
-- ============================================================

-- Reposition icons for center growth after we know the actual visible count
-- This calculates total width/height and offsets icons so they're centered as a group
function DF:RepositionCenterGrowthIcons(frame, icons, auraType, visibleCount)
    if not frame or not icons or visibleCount <= 0 then return end
    
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    local prefix = auraType == "BUFF" and "buff" or "debuff"
    
    local size = db[prefix .. "Size"] or 18
    local scale = db[prefix .. "Scale"] or 1.0
    local anchor = db[prefix .. "Anchor"] or (auraType == "BUFF" and "BOTTOMRIGHT" or "BOTTOMLEFT")
    local growth = db[prefix .. "Growth"] or (auraType == "BUFF" and "LEFT_UP" or "RIGHT_UP")
    local wrap = db[prefix .. "Wrap"] or 3
    local offsetX = db[prefix .. "OffsetX"] or 0
    local offsetY = db[prefix .. "OffsetY"] or 0
    local paddingX = db[prefix .. "PaddingX"] or 2
    local paddingY = db[prefix .. "PaddingY"] or 2
    local borderThickness = db[prefix .. "BorderThickness"] or 1
    
    -- Apply pixel-perfect sizing
    if db.pixelPerfect then
        size, scale, borderThickness = DF:PixelPerfectSizeAndScaleForBorder(size, scale, borderThickness)
    end
    
    -- Parse growth direction
    local primary, secondary = strsplit("_", growth)
    secondary = secondary or "UP"
    
    local scaledSize = size * scale
    
    -- For CENTER_LEFT and CENTER_RIGHT, icons stack vertically (centered) and grow horizontally
    -- For CENTER_UP and CENTER_DOWN, icons stack horizontally (centered) and grow vertically
    local isHorizontalGrowth = (secondary == "LEFT" or secondary == "RIGHT")
    
    if isHorizontalGrowth then
        -- Vertical stacking (icons in a column), horizontal growth direction
        local secondaryX = 0
        if secondary == "LEFT" then
            secondaryX = -(scaledSize + paddingX)
        elseif secondary == "RIGHT" then
            secondaryX = scaledSize + paddingX
        end
        
        -- Reposition each visible icon with proper vertical centering
        for i = 1, visibleCount do
            local icon = icons[i]
            if icon then
                local idx = i - 1
                local col = math.floor(idx / wrap)  -- Which column (horizontal position)
                local row = idx % wrap              -- Which row within the column (vertical position)
                
                -- Count icons in this column (for centering calculation)
                local iconsInCol = math.min(wrap, visibleCount - (col * wrap))
                
                -- Calculate center offset for this column (vertical centering)
                local centerOffset = (iconsInCol - 1) * (scaledSize + paddingY) / 2
                
                -- Position relative to center
                local x = offsetX + (col * secondaryX)
                local y = offsetY - (row * (scaledSize + paddingY)) + centerOffset
                
                icon:ClearAllPoints()
                icon:SetPoint(anchor, frame, anchor, x, y)
            end
        end
    else
        -- Horizontal stacking (icons in a row), vertical growth direction (original behavior)
        local secondaryY = 0
        if secondary == "UP" then
            secondaryY = scaledSize + paddingY
        elseif secondary == "DOWN" then
            secondaryY = -(scaledSize + paddingY)
        end
        
        -- Reposition each visible icon with proper horizontal centering
        for i = 1, visibleCount do
            local icon = icons[i]
            if icon then
                local idx = i - 1
                local row = math.floor(idx / wrap)
                local col = idx % wrap
                
                -- Count icons in this row (for centering calculation)
                local iconsInRow = math.min(wrap, visibleCount - (row * wrap))
                
                -- Calculate center offset for this row
                local centerOffset = (iconsInRow - 1) * (scaledSize + paddingX) / 2
                
                -- Position relative to center
                local x = offsetX + (col * (scaledSize + paddingX)) - centerOffset
                local y = offsetY + (row * secondaryY)
                
                icon:ClearAllPoints()
                icon:SetPoint(anchor, frame, anchor, x, y)
            end
        end
    end
end

-- ============================================================
-- REPLACEMENT UPDATE FUNCTION
-- ============================================================

function DF:UpdateAuras_Enhanced(frame)
    if not frame or not frame.unit then return end

    -- PERF TEST: Skip if disabled
    if DF.PerfTest and not DF.PerfTest.enableAuras then return end

    -- Use raid DB for raid frames, party DB for party frames
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()

    -- Aura Designer runs when enabled; standard buffs can coexist if showBuffs is on.
    local adEnabled = DF:IsAuraDesignerEnabled(frame)
    if adEnabled then
        -- Run AD engine (indicators, frame effects, etc.)
        if DF.AuraDesigner and DF.AuraDesigner.Engine then
            DF.AuraDesigner.Engine:UpdateFrame(frame)
        end

        -- If standard buffs are NOT coexisting, hide their icons
        if not db.showBuffs and frame.buffIcons then
            for _, icon in ipairs(frame.buffIcons) do icon:Hide() end
        end
    end

    -- PERFORMANCE: Only re-apply layout when settings have changed (version mismatch).
    -- Layout (icon positioning, sizing, fonts, borders) is expensive and rarely changes.
    -- It gets invalidated by DF:InvalidateAuraLayout() when GUI/profile settings change.
    local layoutVersion = DF.auraLayoutVersion or 0
    if frame.dfAuraLayoutVersion ~= layoutVersion then
        if DF.ApplyAuraLayout then
            DF:ApplyAuraLayout(frame, "BUFF")
            DF:ApplyAuraLayout(frame, "DEBUFF")
        end
        -- Note: dfAuraLayoutVersion is set inside ApplyAuraLayout
    end

    -- Buff display (standard buff icons)
    -- Shown when: AD is off, OR AD is on with showBuffs enabled (coexistence)
    if not adEnabled or db.showBuffs then
        if db.showBuffs then
            DF:UpdateAuraIconsDirect(frame, frame.buffIcons, "BUFF", db.buffMax or 4)
        else
            if frame.buffIcons then
                for _, icon in ipairs(frame.buffIcons) do icon:Hide() end
            end
        end
    end

    -- Debuff display (always runs — AD doesn't manage debuffs)
    if db.showDebuffs then
        DF:UpdateAuraIconsDirect(frame, frame.debuffIcons, "DEBUFF", db.debuffMax or 4)
    else
        for _, icon in ipairs(frame.debuffIcons) do icon:Hide() end
    end
    
    -- Refresh tooltip if mouse is over an aura that may have changed
    -- This handles the case where auras shift and a new aura is now under cursor
    -- PERFORMANCE FIX: Try GetMouseFocus first (returns single frame, no allocation)
    -- Only fall back to GetMouseFoci (returns table) if GetMouseFocus unavailable
    local focus = GetMouseFocus and GetMouseFocus() or GetMouseFoci and GetMouseFoci()[1]
    if focus and focus.unitFrame == frame and focus.auraType then
        -- Mouse is over one of our aura icons
        if focus:IsShown() and focus.auraData then
            -- Aura is still visible - refresh tooltip with new data
            local onEnter = focus:GetScript("OnEnter")
            if onEnter then
                onEnter(focus)
            end
        else
            -- Aura icon is now hidden - hide tooltip
            GameTooltip:Hide()
        end
    end
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

local OriginalUpdateAuras = nil
local enhancedAurasInitialized = false

local function InitializeEnhancedAuras()
    if enhancedAurasInitialized then return end
    
    -- Setup hooks to capture Blizzard's filtering decisions
    SetupBlizzardHooks()
    
    -- Replace UpdateAuras with enhanced version
    if DF.UpdateAuras and not OriginalUpdateAuras then
        OriginalUpdateAuras = DF.UpdateAuras
        DF.UpdateAuras = DF.UpdateAuras_Enhanced
    elseif not DF.UpdateAuras then
        -- DF.UpdateAuras doesn't exist yet - define it directly
        DF.UpdateAuras = DF.UpdateAuras_Enhanced
    end
    
    enhancedAurasInitialized = true

    -- Do an initial scan
    ScanAllBlizzardFrames()

    -- Check if Direct mode should be active on load
    -- Delayed slightly to ensure unitFrameMap is populated
    C_Timer.After(0.5, function()
        local db = DF.db and DF.db.party
        local raidDb = DF.db and DF.db.raid
        if (db and db.auraSourceMode == "DIRECT") or (raidDb and raidDb.auraSourceMode == "DIRECT") then
            DF:EnableDirectAuraMode()
        end
    end)
end

-- ============================================================
-- CRITICAL: Initialize synchronously, not with delay!
-- During combat reload, delayed initialization would fire AFTER combat
-- lockdown re-establishes, causing UpdateAuras to use the old (non-cached)
-- version instead of the Blizzard-cache-based enhanced version.
-- ============================================================
InitializeEnhancedAuras()

-- ============================================================
-- SAFEGUARD: Ensure enhanced version is used even if Icons.lua
-- loads after Auras.lua (shouldn't happen, but be defensive)
-- ============================================================
local auraInitFrame = CreateFrame("Frame")
auraInitFrame:RegisterEvent("ADDON_LOADED")
auraInitFrame:SetScript("OnEvent", function(self, event, arg1)
    if arg1 == "DandersFrames" then
        -- Double-check that enhanced version is active
        if DF.UpdateAuras ~= DF.UpdateAuras_Enhanced then
            if DF.UpdateAuras then
                OriginalUpdateAuras = DF.UpdateAuras
            end
            DF.UpdateAuras = DF.UpdateAuras_Enhanced
        end
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

-- ============================================================
-- DEBUG FUNCTION
-- ============================================================

function DF:DebugAuraFiltering()
    print("|cff00ccffDandersFrames Aura Filter Debug:|r")
    print("")
    print("|cffffcc00Hook Status:|r")
    print("  Blizzard Hook Active:", DF.BlizzardHookActive and "Yes" or "No")
    print("  CompactUnitFrame_UpdateAuras exists:", CompactUnitFrame_UpdateAuras and "Yes" or "No")
    print("")
    
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    print("|cffffcc00Current Settings:|r")
    print("  Filter Mode: BLIZZARD (uses Blizzard's aura filtering)")
    print("  Hide Blizzard Party Frames:", db.hideBlizzardPartyFrames and "Yes" or "No")
    print("  Hide Blizzard Raid Frames:", raidDb.hideBlizzardRaidFrames and "Yes" or "No")
    print("")
    
    print("|cffffcc00Blizzard Aura Cache:|r")
    local cacheCount = 0
    for unit, cache in pairs(DF.BlizzardAuraCache) do
        local buffCount, debuffCount = 0, 0
        for _ in pairs(cache.buffs) do buffCount = buffCount + 1 end
        for _ in pairs(cache.debuffs) do debuffCount = debuffCount + 1 end
        print("  " .. unit .. ": " .. buffCount .. " buffs, " .. debuffCount .. " debuffs cached")
        cacheCount = cacheCount + 1
    end
    if cacheCount == 0 then
        print("  (empty - Blizzard frames may not have updated yet)")
        print("  Try: /dfauras scan")
    end
end

-- Force a scan of all Blizzard frames
function DF:ForceScanBlizzardFrames()
    ScanAllBlizzardFrames()
    print("|cff00ff00DandersFrames:|r Scanned Blizzard frames for auras")
    
    -- Also update our frames
    if DF.UpdateAllFrames then
        DF:UpdateAllFrames()
    end
end

-- ============================================================
-- HIDE/SHOW BLIZZARD RAID FRAMES
-- Blizzard mode: hide containers, strip events but keep UNIT_AURA
-- Direct mode: fully disable frames (unregister ALL events,
--   reparent party frames to hidden parent — Grid2 pattern)
-- ============================================================

-- Track if we've installed hooks (only do once)
local blizzardHooksInstalled = false

-- Track which frames have been stripped so we can restore them
local strippedFrames = {}

-- Track frames that have been reparented to the hidden frame
local reparentedFrames = {}

-- Hidden parent frame for fully disabling Blizzard frames (Grid2 pattern)
local blizzardHiddenParent = CreateFrame("Frame")
blizzardHiddenParent:Hide()

-- Track if Direct-mode full disable is active
DF.blizzardFramesFullyDisabled = false

-- Function to strip events from a Blizzard unit frame
-- fullDisable=true: unregister ALL events (Direct mode, no Blizzard aura data needed)
-- fullDisable=false: keep UNIT_AURA + combat events (Blizzard mode, need aura cache)
local function StripUnitFrameEvents(frame, fullDisable)
    if not frame then return end
    local unit = frame.unit
    if unit then
        pcall(function()
            frame:UnregisterAllEvents()
            if not fullDisable then
                -- Re-register UNIT_AURA so Blizzard's aura cache keeps updating
                frame:RegisterUnitEvent("UNIT_AURA", unit)
                -- Keep combat events for proper updates
                frame:RegisterEvent("PLAYER_REGEN_ENABLED")
                frame:RegisterEvent("PLAYER_REGEN_DISABLED")
            end
        end)
        strippedFrames[frame] = true
    end
end

-- Reparent a frame to the hidden parent (fully removes it from the visual tree)
local function ReparentToHidden(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    pcall(function()
        if frame.GetParent then
            reparentedFrames[frame] = frame:GetParent()
        end
        frame:SetParent(blizzardHiddenParent)
        frame:Hide()
    end)
end

-- Restore a reparented frame back to its original parent
local function RestoreParent(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    local originalParent = reparentedFrames[frame]
    if originalParent then
        pcall(function()
            frame:SetParent(originalParent)
        end)
        reparentedFrames[frame] = nil
    end
end

-- Function to restore all events on a frame (call Blizzard's setup function)
local function RestoreUnitFrameEvents(frame)
    if not frame then return end
    if not strippedFrames[frame] then return end

    -- Restore parent first if it was reparented
    RestoreParent(frame)

    pcall(function()
        -- Call Blizzard's function to restore all events
        if CompactUnitFrame_UpdateUnitEvents then
            CompactUnitFrame_UpdateUnitEvents(frame)
        end
    end)
    strippedFrames[frame] = nil
end

-- Install hooks once to intercept Blizzard's event registration
local function InstallBlizzardHooks()
    if blizzardHooksInstalled then return end
    
    -- Hook CompactUnitFrame_UpdateUnitEvents to strip events but keep UNIT_AURA
    if CompactUnitFrame_UpdateUnitEvents then
        hooksecurefunc("CompactUnitFrame_UpdateUnitEvents", function(frame)
            -- Only strip events if we're hiding Blizzard frames
            local raidDb = DF:GetRaidDB()
            local partyDb = DF:GetDB()
            local shouldStrip = false
            
            if frame.unit then
                if frame.unit:match("^raid") and raidDb.hideBlizzardRaidFrames then
                    shouldStrip = true
                elseif frame.unit:match("^party") and partyDb.hideBlizzardPartyFrames then
                    shouldStrip = true
                elseif frame.unit == "player" and partyDb.hideBlizzardPartyFrames then
                    shouldStrip = true
                end
            end
            
            if shouldStrip then
                -- In Direct mode, fully disable (no events at all)
                local isDirectMode = false
                if frame.unit then
                    if frame.unit:match("^raid") then
                        isDirectMode = raidDb.auraSourceMode == "DIRECT"
                    else
                        isDirectMode = partyDb.auraSourceMode == "DIRECT"
                    end
                end
                StripUnitFrameEvents(frame, isDirectMode)
            end
        end)
    end

    blizzardHooksInstalled = true
end

function DF:UpdateBlizzardFrameVisibility()
    local partyDb = DF:GetDB()
    local raidDb = DF:GetRaidDB()

    -- Separate settings for party and raid frames
    local hidePartyFrames = partyDb.hideBlizzardPartyFrames
    local hideRaidFrames = raidDb.hideBlizzardRaidFrames

    -- Check if Direct mode is active (allows full disable instead of just hiding)
    local partyDirectMode = partyDb.auraSourceMode == "DIRECT"
    local raidDirectMode = raidDb.auraSourceMode == "DIRECT"
    DF.blizzardFramesFullyDisabled = (hidePartyFrames and partyDirectMode) or (hideRaidFrames and raidDirectMode)
    
    -- Side menu visibility - check based on current mode
    local showSideMenu
    if IsInRaid() then
        showSideMenu = raidDb.showBlizzardSideMenu
    else
        showSideMenu = partyDb.showBlizzardSideMenu
    end
    
    -- Install hooks if we're hiding frames
    if hidePartyFrames or hideRaidFrames then
        InstallBlizzardHooks()
    end
    
    -- Function to safely apply visibility using SetAlpha only
    local function SafeHideFrame(frame, hide)
        if not frame then return end
        pcall(function()
            if hide then
                frame:SetAlpha(0)
            else
                frame:SetAlpha(1)
            end
        end)
    end
    
    -- Function to safely scale container frames
    local function SafeScaleContainer(frame, hide)
        if not frame then return end
        if InCombatLockdown() then return end
        pcall(function()
            if hide then
                frame:SetAlpha(0)
                frame:SetScale(0.001)
            else
                frame:SetAlpha(1)
                frame:SetScale(1)
            end
        end)
    end
    
    -- Function to safely apply just alpha
    local function SafeSetAlpha(frame, alpha)
        if frame and frame.SetAlpha then
            pcall(function() frame:SetAlpha(alpha) end)
        end
    end
    
    -- Function to hide selection highlights
    local function HideSelectionHighlights(frame)
        if not frame then return end
        pcall(function()
            if frame.selectionHighlight and frame.selectionHighlight.SetShown then
                frame.selectionHighlight:SetShown(false)
            end
            if frame.selectionIndicator and frame.selectionIndicator.SetShown then
                frame.selectionIndicator:SetShown(false)
            end
        end)
    end
    
    -- Hide/show the main container frames (raid-style)
    SafeScaleContainer(CompactRaidFrameContainer, hideRaidFrames)
    
    -- Handle CompactPartyFrame (raid-style party frames)
    if CompactPartyFrame then
        SafeSetAlpha(CompactPartyFrame, hidePartyFrames and 0 or 1)
        SafeSetAlpha(CompactPartyFrame.title, hidePartyFrames and 0 or 1)
        SafeSetAlpha(CompactPartyFrame.borderFrame, hidePartyFrames and 0 or 1)
        if hidePartyFrames then
            HideSelectionHighlights(CompactPartyFrame)
        end
    end
    
    -- Handle traditional portrait-style party frames
    if hidePartyFrames and partyDirectMode then
        -- Direct mode: fully disable (reparent to hidden frame)
        ReparentToHidden(PartyFrame)
    else
        RestoreParent(PartyFrame)
        SafeScaleContainer(PartyFrame, hidePartyFrames)
    end

    -- Handle individual traditional party member frames (PartyMemberFrame1-4)
    for i = 1, 4 do
        local frame = _G["PartyMemberFrame" .. i]
        if frame then
            if hidePartyFrames and partyDirectMode then
                ReparentToHidden(frame)
            else
                RestoreParent(frame)
                SafeHideFrame(frame, hidePartyFrames)
                local petFrame = _G["PartyMemberFrame" .. i .. "PetFrame"]
                SafeSetAlpha(petFrame, hidePartyFrames and 0 or 1)
                local buffFrame = _G["PartyMemberFrame" .. i .. "BuffFrame"]
                SafeSetAlpha(buffFrame, hidePartyFrames and 0 or 1)
                local debuffFrame = _G["PartyMemberFrame" .. i .. "DebuffFrame"]
                SafeSetAlpha(debuffFrame, hidePartyFrames and 0 or 1)
            end
        end
    end

    -- Handle individual compact party member frames
    for i = 1, 5 do
        local frame = _G["CompactPartyFrameMember" .. i]
        if frame then
            if hidePartyFrames then
                SafeHideFrame(frame, true)
                HideSelectionHighlights(frame)
                StripUnitFrameEvents(frame, partyDirectMode)
            else
                -- Restore events when showing
                RestoreUnitFrameEvents(frame)
            end
        end
    end
    
    -- Handle raid frames
    for i = 1, 40 do
        local frame = _G["CompactRaidFrame" .. i]
        if frame then
            SafeHideFrame(frame, hideRaidFrames)
            if hideRaidFrames then
                HideSelectionHighlights(frame)
                StripUnitFrameEvents(frame, raidDirectMode)
            else
                -- Restore events when showing
                RestoreUnitFrameEvents(frame)
            end
        end
    end

    for group = 1, 8 do
        for member = 1, 5 do
            local frame = _G["CompactRaidGroup" .. group .. "Member" .. member]
            if frame then
                SafeHideFrame(frame, hideRaidFrames)
                if hideRaidFrames then
                    HideSelectionHighlights(frame)
                    StripUnitFrameEvents(frame, raidDirectMode)
                else
                    -- Restore events when showing
                    RestoreUnitFrameEvents(frame)
                end
            end
        end
        -- Also hide group headers
        local groupFrame = _G["CompactRaidGroup" .. group]
        SafeHideFrame(groupFrame, hideRaidFrames)
    end
    
    -- Handle raid frame manager
    if CompactRaidFrameManager then
        local sideMenuVisible = showSideMenu or not hideRaidFrames
        
        SafeHideFrame(CompactRaidFrameManager.container, hideRaidFrames)
        SafeHideFrame(CompactRaidFrameManager.toggleButton, hideRaidFrames)
        
        -- Handle the display frame (side panel with settings/pings) separately
        SafeHideFrame(CompactRaidFrameManager.displayFrame, not sideMenuVisible)
        
        -- The main manager frame itself
        SafeHideFrame(CompactRaidFrameManager, not sideMenuVisible)
    end
    
    -- Handle the side menu elements for party frames
    local partySideMenuVisible = showSideMenu or not hidePartyFrames
    
    if CompactPartyFrame then
        -- Only adjust title if we want to show/hide the side menu differently
        if not partySideMenuVisible then
            SafeSetAlpha(CompactPartyFrame.title, 0)
        end
        SafeHideFrame(CompactPartyFrame.dropdown, not partySideMenuVisible)
        SafeHideFrame(CompactPartyFrame.menuButton, not partySideMenuVisible)
    end
    
    if PartyFrame then
        SafeHideFrame(PartyFrame.DropdownButton, not partySideMenuVisible)
        SafeSetAlpha(PartyFrame.PartyMemberFrameDropDown, partySideMenuVisible and 1 or 0)
    end
    
    if EditModeManagerFrame and EditModeManagerFrame.PartyFramesSidePanel then
        SafeHideFrame(EditModeManagerFrame.PartyFramesSidePanel, not sideMenuVisible)
    end
end

-- Apply visibility on load and when group changes
local blizzFrameEventHandler = CreateFrame("Frame")
blizzFrameEventHandler:RegisterEvent("PLAYER_ENTERING_WORLD")
blizzFrameEventHandler:RegisterEvent("GROUP_ROSTER_UPDATE")
blizzFrameEventHandler:RegisterEvent("PLAYER_REGEN_ENABLED")
blizzFrameEventHandler:RegisterEvent("PLAYER_TARGET_CHANGED")
blizzFrameEventHandler:RegisterEvent("RAID_ROSTER_UPDATE")
blizzFrameEventHandler:RegisterEvent("PARTY_MEMBER_ENABLE")
blizzFrameEventHandler:RegisterEvent("PARTY_MEMBER_DISABLE")

blizzFrameEventHandler:SetScript("OnEvent", function(self, event)
    if event == "GROUP_ROSTER_UPDATE" then
        if DF.RosterDebugEvent then DF:RosterDebugEvent("Auras.lua(visibility):GROUP_ROSTER_UPDATE") end
    end
    -- Delay slightly to let frames initialize/reposition
    C_Timer.After(0.2, function()
        if DF.UpdateBlizzardFrameVisibility then
            DF:UpdateBlizzardFrameVisibility()
        end
    end)
    
    -- Do another update shortly after in case frames are still moving
    C_Timer.After(0.5, function()
        if DF.UpdateBlizzardFrameVisibility then
            DF:UpdateBlizzardFrameVisibility()
        end
    end)
    
    -- For target changes, also do an immediate check to hide selection highlights
    if event == "PLAYER_TARGET_CHANGED" then
        local db = DF.GetDB and DF:GetDB()
        local raidDb = DF.GetRaidDB and DF:GetRaidDB()
        local hideParty = db and db.hideBlizzardPartyFrames
        local hideRaid = raidDb and raidDb.hideBlizzardRaidFrames
        
        if hideParty or hideRaid then
            -- Hide selection highlights on all Blizzard frames
            local function HideSelectionHighlight(frame)
                if frame then
                    if frame.selectionHighlight and frame.selectionHighlight.SetShown then
                        frame.selectionHighlight:SetShown(false)
                    end
                    if frame.selectionIndicator and frame.selectionIndicator.SetShown then
                        frame.selectionIndicator:SetShown(false)
                    end
                end
            end
            
            if hideParty then
                for i = 1, 5 do
                    HideSelectionHighlight(_G["CompactPartyFrameMember" .. i])
                end
            end
            if hideRaid then
                for i = 1, 40 do
                    HideSelectionHighlight(_G["CompactRaidFrame" .. i])
                end
                for group = 1, 8 do
                    for member = 1, 5 do
                        HideSelectionHighlight(_G["CompactRaidGroup" .. group .. "Member" .. member])
                    end
                end
            end
        end
    end
end)

-- Hook Blizzard's selection highlight function to hide it when our option is enabled
if CompactUnitFrame_UpdateSelectionHighlight then
    hooksecurefunc("CompactUnitFrame_UpdateSelectionHighlight", function(frame)
        local db = DF.GetDB and DF:GetDB()
        local raidDb = DF.GetRaidDB and DF:GetRaidDB()
        
        -- Only affect party/raid frames, not nameplates
        local unit = frame.unit or frame.displayedUnit
        if unit then
            local isParty = unit:match("^party") or unit == "player"
            local isRaid = unit:match("^raid")
            
            local shouldHide = false
            if isParty and db and db.hideBlizzardPartyFrames then
                shouldHide = true
            elseif isRaid and raidDb and raidDb.hideBlizzardRaidFrames then
                shouldHide = true
            end
            
            if shouldHide and frame.selectionHighlight and frame.selectionHighlight.SetShown then
                frame.selectionHighlight:SetShown(false)
            end
        end
    end)
end

-- Slash command
SLASH_DFAURAS1 = "/dfauras"
SlashCmdList["DFAURAS"] = function(msg)
    if msg == "scan" then
        DF:ForceScanBlizzardFrames()
    elseif msg == "hideparty" then
        local db = DF:GetDB()
        db.hideBlizzardPartyFrames = not db.hideBlizzardPartyFrames
        DF:UpdateBlizzardFrameVisibility()
        print("|cff00ff00DandersFrames:|r Blizzard party frames " .. (db.hideBlizzardPartyFrames and "hidden" or "visible"))
    elseif msg == "hideraid" then
        local raidDb = DF:GetRaidDB()
        raidDb.hideBlizzardRaidFrames = not raidDb.hideBlizzardRaidFrames
        DF:UpdateBlizzardFrameVisibility()
        print("|cff00ff00DandersFrames:|r Blizzard raid frames " .. (raidDb.hideBlizzardRaidFrames and "hidden" or "visible"))
    elseif msg == "hideblizz" or msg == "hide" then
        -- Toggle both for convenience
        local db = DF:GetDB()
        local raidDb = DF:GetRaidDB()
        local newState = not (db.hideBlizzardPartyFrames or raidDb.hideBlizzardRaidFrames)
        db.hideBlizzardPartyFrames = newState
        raidDb.hideBlizzardRaidFrames = newState
        DF:UpdateBlizzardFrameVisibility()
        print("|cff00ff00DandersFrames:|r Blizzard frames " .. (newState and "hidden" or "visible"))
    elseif msg == "sidemenu" then
        -- Debug: list potential side menu frames
        print("|cff00ff00DandersFrames:|r Searching for side menu frames...")
        local framesToCheck = {
            "CompactPartyFrame",
            "CompactPartyFrameTitle",
            "CompactPartyFrameBorderFrame", 
            "PartyFrame",
            "CompactRaidFrameManager",
            "CompactRaidFrameManagerDisplayFrame",
            "CompactRaidFrameManagerContainerResizeFrame",
        }
        for _, name in ipairs(framesToCheck) do
            local frame = _G[name]
            if frame then
                print("  Found: " .. name .. " (shown: " .. tostring(frame:IsShown()) .. ", alpha: " .. tostring(frame:GetAlpha()) .. ")")
                -- List children
                if frame.GetChildren then
                    for i, child in ipairs({frame:GetChildren()}) do
                        local childName = child:GetName() or ("unnamed_" .. i)
                        if child:IsShown() then
                            print("    Child: " .. childName .. " (alpha: " .. tostring(child:GetAlpha()) .. ")")
                        end
                    end
                end
            end
        end
        -- Also check for any visible frame with "party" in name at UIParent level
        print("  Checking UIParent children for party-related frames...")
        for i, child in ipairs({UIParent:GetChildren()}) do
            local name = child:GetName()
            if name and (name:lower():find("party") or name:lower():find("compact")) and child:IsShown() then
                print("    UIParent child: " .. name .. " (alpha: " .. tostring(child:GetAlpha()) .. ")")
            end
        end
    else
        DF:DebugAuraFiltering()
    end
end

-- ============================================================
-- LIVE DEBUFF DEBUG MODE
-- Prints Blizzard's internal debuff/dispel data in real-time
-- Usage: /dfauras debuglive
-- ============================================================

DF.debugLiveAuras = false

local function PrintBlizzardFrameData(frame, frameName)
    if not frame then return end
    
    local unit = frame.unit
    if not unit then return end
    
    print("|cff00ccff[" .. frameName .. "]|r Unit: " .. unit)
    
    -- Check debuffs container
    if frame.debuffs and frame.debuffs.Size then
        local count = frame.debuffs:Size()
        print("  |cffff8800debuffs container:|r Size = " .. count)
        if count > 0 and frame.debuffs.Iterate then
            pcall(function()
                for aura in frame.debuffs:Iterate() do
                    local dispelInfo = ""
                    if aura.dispelName then
                        dispelInfo = "|cff00ff00" .. aura.dispelName .. "|r"
                    else
                        dispelInfo = "|cffff0000NOT DISPELLABLE|r"
                    end
                    print("    - " .. (aura.name or "?") .. " | ID: " .. tostring(aura.auraInstanceID) .. " | dispelName: " .. dispelInfo .. " | dispelType: " .. tostring(aura.dispelType or "nil"))
                end
            end)
        end
    else
        print("  |cffff0000debuffs container: NOT FOUND|r")
    end
    
    -- Check buffs container (for comparison)
    if frame.buffs and frame.buffs.Size then
        local count = frame.buffs:Size()
        print("  |cff88ff88buffs container:|r Size = " .. count)
    end
    
    -- Check bigDefensives container
    if frame.bigDefensives and frame.bigDefensives.Size then
        local count = frame.bigDefensives:Size()
        print("  |cffff00ffbigDefensives container:|r Size = " .. count)
        if count > 0 and frame.bigDefensives.Iterate then
            pcall(function()
                for aura in frame.bigDefensives:Iterate() do
                    print("    - " .. (aura.name or "?") .. " | ID: " .. tostring(aura.auraInstanceID))
                end
            end)
        end
    end
    
    -- Check for private auras
    if frame.privateAuraSize and frame.privateAuraSize > 0 then
        print("  |cffff00ffPrivate Auras:|r " .. frame.privateAuraSize .. " (hidden from addons)")
    end
    if frame.PrivateAuraAnchors then
        local anchorCount = 0
        for _ in pairs(frame.PrivateAuraAnchors) do anchorCount = anchorCount + 1 end
        if anchorCount > 0 then
            print("  |cffff00ffPrivateAuraAnchors:|r " .. anchorCount .. " anchors")
        end
    end
    
    -- Check dispels container (by type)
    if frame.dispels then
        local hasAny = false
        for dispelType, container in pairs(frame.dispels) do
            if type(container) == "table" and container.Size and container:Size() > 0 then
                hasAny = true
                break
            end
        end
        if hasAny then
            print("  |cff00ff00dispels container:|r (YOUR class can dispel these)")
            for dispelType, container in pairs(frame.dispels) do
                if type(container) == "table" and container.Size then
                    local count = container:Size()
                    if count > 0 then
                        print("    |cff00ff00" .. dispelType .. ":|r " .. count .. " auras")
                        if container.Iterate then
                            pcall(function()
                                for aura in container:Iterate() do
                                    print("      - " .. (aura.name or "?") .. " | ID: " .. tostring(aura.auraInstanceID))
                                end
                            end)
                        end
                    end
                end
            end
        else
            print("  |cffffff00dispels container:|r (empty - no debuffs YOUR class can dispel)")
        end
    else
        print("  |cffff0000dispels container: NOT FOUND|r")
    end
    
    -- Check old-style debuffFrames (what we currently use)
    if frame.debuffFrames then
        local shownCount = 0
        local totalCount = #frame.debuffFrames
        local shownDetails = {}
        for i, df in ipairs(frame.debuffFrames) do
            if df:IsShown() and df.auraInstanceID then
                shownCount = shownCount + 1
                table.insert(shownDetails, tostring(df.auraInstanceID))
            end
        end
        print("  |cffffff00debuffFrames (UI):|r " .. shownCount .. "/" .. totalCount .. " shown with auraInstanceID")
        if shownCount > 0 then
            print("    IDs: " .. table.concat(shownDetails, ", "))
        end
    end
    
    -- Check dispelDebuffFrames
    if frame.dispelDebuffFrames then
        local shownCount = 0
        local totalCount = #frame.dispelDebuffFrames
        local shownDetails = {}
        for i, df in ipairs(frame.dispelDebuffFrames) do
            if df:IsShown() and df.auraInstanceID then
                shownCount = shownCount + 1
                table.insert(shownDetails, tostring(df.auraInstanceID))
            end
        end
        print("  |cffffff00dispelDebuffFrames (UI):|r " .. shownCount .. "/" .. totalCount .. " shown with auraInstanceID")
        if shownCount > 0 then
            print("    IDs: " .. table.concat(shownDetails, ", "))
        end
    end
    
    -- NEW: Check for any other aura-related containers we might have missed
    -- Look for anything with "boss", "debuff", "aura" in the name that's a table with Size method
    local checkedKeys = {debuffs=true, buffs=true, dispels=true, bigDefensives=true, debuffFrames=true, dispelDebuffFrames=true, buffFrames=true, PrivateAuraAnchors=true}
    local foundOther = false
    for key, value in pairs(frame) do
        if type(key) == "string" and type(value) == "table" and not checkedKeys[key] then
            local keyLower = key:lower()
            if keyLower:find("boss") or keyLower:find("aura") or keyLower:find("debuff") then
                if value.Size and type(value.Size) == "function" then
                    local count = 0
                    pcall(function() count = value:Size() end)
                    if count > 0 then
                        if not foundOther then
                            print("  |cffff00ff=== OTHER CONTAINERS ===|r")
                            foundOther = true
                        end
                        print("    |cffff00ff" .. key .. ":|r Size = " .. count)
                        if value.Iterate then
                            pcall(function()
                                for aura in value:Iterate() do
                                    print("      - " .. (aura.name or "?") .. " | ID: " .. tostring(aura.auraInstanceID or "?"))
                                end
                            end)
                        end
                    end
                end
            end
        end
    end
    
    -- Also check raw API for what debuffs the unit actually has
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local hasHarmful = false
        for i = 1, 10 do
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
            if aura then
                if not hasHarmful then
                    print("  |cffff5500=== RAW API HARMFUL AURAS ===|r")
                    hasHarmful = true
                end
                local dispelInfo = aura.dispelName and ("|cff00ff00" .. aura.dispelName .. "|r") or "|cffff0000none|r"
                local bossInfo = ""
                pcall(function()
                    if aura.isBossAura then bossInfo = " |cffff0000[BOSS]|r" end
                end)
                print("    [" .. i .. "] " .. (aura.name or "?") .. " | ID: " .. tostring(aura.auraInstanceID) .. " | dispel: " .. dispelInfo .. bossInfo)
            else
                break
            end
        end
        if not hasHarmful then
            print("  |cffffff00RAW API: No HARMFUL auras on " .. unit .. "|r")
        end
    end
    
    print("")
end

local function DebugAllBlizzardFrames()
    print("|cff00ff00=== BLIZZARD FRAME DEBUFF DEBUG ===|r")
    print("")
    
    -- Party frames
    for i = 1, 5 do
        local frame = _G["CompactPartyFrameMember" .. i]
        if frame and frame.unit then
            PrintBlizzardFrameData(frame, "CompactPartyFrameMember" .. i)
        end
    end
    
    -- Raid frames (just first 10 to avoid spam)
    for i = 1, 10 do
        local frame = _G["CompactRaidFrame" .. i]
        if frame and frame.unit then
            PrintBlizzardFrameData(frame, "CompactRaidFrame" .. i)
        end
    end
    
    print("|cff00ff00=== END DEBUG ===|r")
end

-- Hook for live monitoring
local debugHookInstalled = false
local function InstallDebugHook()
    if debugHookInstalled then return end
    
    if CompactUnitFrame_UpdateAuras then
        hooksecurefunc("CompactUnitFrame_UpdateAuras", function(frame)
            if not DF.debugLiveAuras then return end
            if not frame or not frame.unit then return end
            
            -- PERFORMANCE FIX 2025-01-20: Check for nameplate BEFORE calling GetName()
            -- Nameplates can error on GetName() - check unit string first
            local unit = frame.unit
            if unit and type(unit) == "string" and unit:find("nameplate") then
                return
            end
            local displayedUnit = frame.displayedUnit
            if displayedUnit and type(displayedUnit) == "string" and displayedUnit:find("nameplate") then
                return
            end
            
            -- Now safe to call GetName
            local name = frame:GetName()
            if not name then return end
            if name:find("NamePlate") then return end
            
            PrintBlizzardFrameData(frame, name)
        end)
        debugHookInstalled = true
        print("|cff00ff00DandersFrames:|r Debug hook installed")
    end
end

-- Slash command handler for debug
SLASH_DFAURASDEBUG1 = "/dfaurasdebug"
SlashCmdList["DFAURASDEBUG"] = function(msg)
    msg = msg:lower():trim()
    
    if msg == "live" or msg == "on" then
        DF.debugLiveAuras = true
        InstallDebugHook()
        print("|cff00ff00DandersFrames:|r Live aura debug ENABLED - debuff data will print when auras change")
    elseif msg == "off" then
        DF.debugLiveAuras = false
        print("|cff00ff00DandersFrames:|r Live aura debug DISABLED")
    elseif msg == "now" or msg == "snap" or msg == "snapshot" then
        DebugAllBlizzardFrames()
    else
        print("|cff00ccffDandersFrames Aura Debug Commands:|r")
        print("  /dfaurasdebug live - Enable live monitoring (prints on every aura update)")
        print("  /dfaurasdebug off - Disable live monitoring")
        print("  /dfaurasdebug now - Print current snapshot of all Blizzard frame data")
    end
end

-- ============================================================
-- DEFENSIVE / BUFF DEDUPLICATION DEBUG
-- Dumps auraInstanceIDs from both caches to check for overlap
-- Usage: /dfdefdup
-- ============================================================

SLASH_DFDEFDUP1 = "/dfdefdup"
SlashCmdList["DFDEFDUP"] = function()
    local issecret = issecretvalue or function() return false end
    local header = "|cff00ff00DandersFrames|r |cff00ccff[Defensive/Buff Dedup Debug]|r"
    print(header)

    local anyUnit = false
    for unit, cache in pairs(DF.BlizzardAuraCache) do
        if cache and (next(cache.defensives) or next(cache.buffs)) then
            anyUnit = true
            local unitName = UnitName(unit) or unit
            print("|cffffcc00--- " .. unit .. " (" .. unitName .. ") ---|r")

            -- Defensive IDs
            local defCount = 0
            local defIDs = {}
            for id in pairs(cache.defensives) do
                defCount = defCount + 1
                local isSecret = issecret(id)
                defIDs[defCount] = { id = id, secret = isSecret }
            end

            if defCount > 0 then
                print("  |cff00ff00Defensives (" .. defCount .. "):|r")
                for i, entry in ipairs(defIDs) do
                    if entry.secret then
                        print("    [" .. i .. "] SECRET (cannot read)")
                    else
                        -- Try to get aura data for extra info
                        local info = ""
                        local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, entry.id)
                        if ok and data then
                            local iconStr = data.icon
                            if iconStr and not issecret(iconStr) then
                                info = " icon=" .. tostring(iconStr)
                            end
                            local nameStr = data.name
                            if nameStr and not issecret(nameStr) then
                                info = info .. " name=" .. tostring(nameStr)
                            end
                            local spellStr = data.spellId
                            if spellStr and not issecret(spellStr) then
                                info = info .. " spellId=" .. tostring(spellStr)
                            end
                        end
                        print("    [" .. i .. "] ID=" .. tostring(entry.id) .. info)
                    end
                end
            else
                print("  |cff888888Defensives: (none)|r")
            end

            -- Buff IDs
            local buffCount = #(cache.buffOrder or {})
            if buffCount > 0 then
                print("  |cff3399ffBuffs (" .. buffCount .. "):|r")
                for i, id in ipairs(cache.buffOrder) do
                    local isSecret = issecret(id)
                    if isSecret then
                        print("    [" .. i .. "] SECRET (cannot read)")
                    else
                        local info = ""
                        local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, id)
                        if ok and data then
                            local iconStr = data.icon
                            if iconStr and not issecret(iconStr) then
                                info = " icon=" .. tostring(iconStr)
                            end
                            local nameStr = data.name
                            if nameStr and not issecret(nameStr) then
                                info = info .. " name=" .. tostring(nameStr)
                            end
                            local spellStr = data.spellId
                            if spellStr and not issecret(spellStr) then
                                info = info .. " spellId=" .. tostring(spellStr)
                            end
                        end
                        print("    [" .. i .. "] ID=" .. tostring(id) .. info)
                    end
                end
            else
                print("  |cff888888Buffs: (none)|r")
            end

            -- Check for overlaps
            local overlapCount = 0
            local overlaps = {}
            for id in pairs(cache.defensives) do
                if not issecret(id) and cache.buffs[id] then
                    overlapCount = overlapCount + 1
                    overlaps[overlapCount] = id
                end
            end

            if overlapCount > 0 then
                print("  |cffff3333DUPLICATES FOUND (" .. overlapCount .. "):|r")
                for i, id in ipairs(overlaps) do
                    local info = ""
                    local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, id)
                    if ok and data then
                        local nameStr = data.name
                        if nameStr and not issecret(nameStr) then
                            info = " name=" .. tostring(nameStr)
                        end
                    end
                    print("    |cffff3333" .. tostring(id) .. info .. "|r")
                end
            else
                print("  |cff00ff00No duplicates between defensive and buff caches|r")
            end
        end
    end

    if not anyUnit then
        print("  |cffff8800No cached aura data found. Are you in a group?|r")
    end
end
