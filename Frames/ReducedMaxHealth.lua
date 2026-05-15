local addonName, DF = ...

-- ==========================================================
-- REDUCED MAX HEALTH BAR
-- Visualises the fraction of a unit's max health that has been
-- temporarily reduced (M+ affixes, boss debuffs, etc.) using
-- GetUnitTotalModifiedMaxHealthPercent and the
-- UNIT_MAX_HEALTH_MODIFIERS_CHANGED event.
-- ==========================================================

local pairs, ipairs = pairs, ipairs
local CreateFrame = CreateFrame
local UnitExists, UnitIsDead, UnitIsGhost, UnitIsConnected =
      UnitExists, UnitIsDead, UnitIsGhost, UnitIsConnected
local GetUnitTotalModifiedMaxHealthPercent = GetUnitTotalModifiedMaxHealthPercent
local issecretvalue = issecretvalue or function() return false end

local DEFAULT_BAR_COLOR = { r = 0.2, g = 0.2, b = 0.2, a = 0.85 }

function DF:CreateReducedMaxHealthBar(frame, db)
    if not frame or not frame.healthBar or frame.dfReducedMaxHealthBar then return end

    local padding = (db and db.framePadding) or 0

    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetPoint("TOPLEFT", padding, -padding)
    bar:SetPoint("BOTTOMRIGHT", -padding, padding)
    bar:SetReverseFill(true)
    bar:SetFrameLevel(frame.healthBar:GetFrameLevel() + 6)
    bar:Hide()

    frame.dfReducedMaxHealthBar = bar
end

function DF:RestoreHealthBarFromReducedMax(frame)
    if not frame or not frame.dfReducedMaxHealthClipping then return end
    if not frame.healthBar then
        frame.dfReducedMaxHealthClipping = nil
        return
    end
    local db = DF:GetFrameDB(frame)
    local padding = (db and db.framePadding) or 0
    frame.healthBar:ClearAllPoints()
    frame.healthBar:SetPoint("TOPLEFT", padding, -padding)
    frame.healthBar:SetPoint("BOTTOMRIGHT", -padding, padding)
    frame.dfReducedMaxHealthClipping = nil
end

function DF:UpdateReducedMaxHealth(frame)
    if not frame or not frame.dfReducedMaxHealthBar then return end
    local bar = frame.dfReducedMaxHealthBar
    local db = DF:GetFrameDB(frame)

    if not db or not db.reducedMaxHealthEnabled then
        bar:Hide()
        DF:RestoreHealthBarFromReducedMax(frame)
        return
    end

    local unit = frame.unit
    if not frame.dfIsTestFrame then
        if not unit or not UnitExists(unit) or UnitIsDead(unit)
                or UnitIsGhost(unit) or not UnitIsConnected(unit) then
            bar:Hide()
            DF:RestoreHealthBarFromReducedMax(frame)
            return
        end
    end

    local pct
    if frame.dfIsTestFrame then
        pct = frame.dfTestReducedMaxPct or 0
    elseif GetUnitTotalModifiedMaxHealthPercent then
        pct = GetUnitTotalModifiedMaxHealthPercent(unit)
    end

    if not pct or issecretvalue(pct) or pct <= 0 then
        bar:Hide()
        DF:RestoreHealthBarFromReducedMax(frame)
        return
    end

    local texturePath = db.reducedMaxHealthTexture
    if DF.ResolveMediaTexture then
        texturePath = DF:ResolveMediaTexture(texturePath) or texturePath
    end
    if texturePath then
        bar:SetStatusBarTexture(texturePath)
    end

    local c = db.reducedMaxHealthColor or DEFAULT_BAR_COLOR
    bar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)

    local tex = bar:GetStatusBarTexture()
    if tex then
        tex:SetBlendMode(db.reducedMaxHealthBlendMode or "BLEND")
    end

    bar:SetMinMaxValues(0, 1)
    bar:SetValue(pct)
    bar:Show()

    if db.reducedMaxHealthClipHealthBar and frame.healthBar and tex then
        local padding = db.framePadding or 0
        frame.healthBar:ClearAllPoints()
        frame.healthBar:SetPoint("TOPLEFT", padding, -padding)
        frame.healthBar:SetPoint("BOTTOMLEFT", padding, padding)
        frame.healthBar:SetPoint("TOPRIGHT", tex, "TOPLEFT")
        frame.healthBar:SetPoint("BOTTOMRIGHT", tex, "BOTTOMLEFT")
        frame.dfReducedMaxHealthClipping = true
    else
        DF:RestoreHealthBarFromReducedMax(frame)
    end

    if DF.Debug then
        DF:Debug("ReducedMaxHealth", "Updated", unit or "(test)", "pct=", pct)
    end
end

function DF:UpdateAllReducedMaxHealth()
    local function updateFrame(frame)
        if frame and frame:IsShown() then
            DF:UpdateReducedMaxHealth(frame)
        end
    end

    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(updateFrame)
    end
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(updateFrame)
    end
    if DF.IterateAllFrames and not (DF.IteratePartyFrames or DF.IterateRaidFrames) then
        DF:IterateAllFrames(updateFrame)
    end
end

function DF:UpdateAllVisibleReducedMaxHealth(unit)
    local function updateFrame(frame)
        if frame and frame:IsShown() and (not unit or frame.unit == unit) then
            DF:UpdateReducedMaxHealth(frame)
        end
    end

    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(updateFrame)
    end
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(updateFrame)
    end
    if DF.IterateAllFrames and not (DF.IteratePartyFrames or DF.IterateRaidFrames) then
        DF:IterateAllFrames(updateFrame)
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        self:RegisterEvent("UNIT_MAX_HEALTH_MODIFIERS_CHANGED")
    elseif event == "UNIT_MAX_HEALTH_MODIFIERS_CHANGED" then
        local unit = ...
        if DF.UpdateAllVisibleReducedMaxHealth then
            DF:UpdateAllVisibleReducedMaxHealth(unit)
        end
    end
end)
