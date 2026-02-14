local addonName, DF = ...

-- ============================================================
-- HEALTH THRESHOLD FADE SYSTEM
-- Fades frames/elements when a unit's health is above a configurable
-- threshold (e.g. 100% or 80%). Uses the same pattern as Range.lua.
-- ============================================================

-- Upvalue all frequently used globals for performance
local UnitExists = UnitExists
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsConnected = UnitIsConnected

-- ============================================================
-- CHECK IF UNIT IS ABOVE HEALTH THRESHOLD
-- Returns true if unit health percent is >= configured threshold.
-- We use frame.dfComputedAboveThreshold set by Core.lua's SetHealthBarValue
-- via a StatusBar OnValueChanged callback (receives resolved values).
-- ============================================================

local function IsAboveHealthThresholdFromFrame(frame)
    if not frame or not frame.unit then
        return false
    end

    local unit = frame.unit

    if not UnitExists(unit) then
        return false
    end

    if UnitIsDeadOrGhost(unit) or not UnitIsConnected(unit) then
        return false
    end

    return frame.dfComputedAboveThreshold == true
end

-- ============================================================
-- UPDATE HEALTH FADE STATE FOR A FRAME
-- ============================================================

function DF:UpdateHealthFade(frame)
    if not frame or not frame.unit then return end

    if frame.isPetFrame then
        DF:UpdatePetHealthFade(frame)
        return
    end

    if DF.PerfTest and not DF.PerfTest.enableHealthFade then return end
    if DF.testMode or DF.raidTestMode then return end

    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    if not db or not db.healthFadeEnabled then
        if frame.dfIsHealthFaded then
            frame.dfIsHealthFaded = false
            if DF.UpdateAllElementAppearances then
                DF:UpdateAllElementAppearances(frame)
            end
        end
        return
    end

    local isAboveThreshold = IsAboveHealthThresholdFromFrame(frame)

    if isAboveThreshold and db.hfCancelOnDispel then
        if frame.dfDispelOverlay and frame.dfDispelOverlay:IsShown() then
            isAboveThreshold = false
        end
    end

    if frame.dfIsHealthFaded ~= isAboveThreshold then
        frame.dfIsHealthFaded = isAboveThreshold

        if DF.UpdateAllElementAppearances then
            DF:UpdateAllElementAppearances(frame)
        end
    end
end

-- ============================================================
-- UPDATE HEALTH FADE FOR PET FRAMES
-- ============================================================

function DF:UpdatePetHealthFade(frame)
    if not frame or not frame.unit then return end

    if not UnitExists(frame.unit) then return end

    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    if not db or not db.healthFadeEnabled then
        frame.dfIsHealthFaded = false
        return
    end

    local isAboveThreshold = IsAboveHealthThresholdFromFrame(frame)

    if frame.dfIsHealthFaded ~= isAboveThreshold then
        frame.dfIsHealthFaded = isAboveThreshold

        local healthFadeAlpha = db.healthFadeAlpha or 0.5

        if frame.SetAlpha then
            frame:SetAlpha(isAboveThreshold and healthFadeAlpha or 1.0)
        end
        if frame.healthBar then
            frame.healthBar:SetAlpha(isAboveThreshold and healthFadeAlpha or 1.0)
        end
    end
end

-- ============================================================
-- HELPER: Check if a frame should be faded (above health threshold)
-- Used by ElementAppearance.lua
-- ============================================================

function DF:IsHealthFaded(frame)
    if not frame then return false end

    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    if not db or not db.healthFadeEnabled then
        return false
    end

    return frame.dfIsHealthFaded == true
end

-- ============================================================
-- HELPER: Get health fade alpha for an element
-- Used by ElementAppearance.lua
-- ============================================================

function DF:GetHealthFadeAlpha(frame, elementKey)
    if not frame then return 1.0 end

    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    if not db then return 1.0 end

    local alphaMap = {
        healthBar = "hfHealthBarAlpha",
        background = "hfBackgroundAlpha",
        nameText = "hfNameTextAlpha",
        healthText = "hfHealthTextAlpha",
        auras = "hfAurasAlpha",
        icons = "hfIconsAlpha",
        dispelOverlay = "hfDispelOverlayAlpha",
        powerBar = "hfPowerBarAlpha",
        missingBuff = "hfMissingBuffAlpha",
        defensiveIcon = "hfDefensiveIconAlpha",
        targetedSpell = "hfTargetedSpellAlpha",
        myBuffIndicator = "hfMyBuffIndicatorAlpha",
        frame = "healthFadeAlpha",
    }

    local dbKey = alphaMap[elementKey] or "healthFadeAlpha"
    return db[dbKey] or 0.5
end
