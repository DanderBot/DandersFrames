local addonName, DF = ...

-- Applies the custom layout (scale, anchor, growth, wrap) to aura icons
function DF:ApplyAuraLayout(frame)
    -- Use strict validation to block nameplates
    if not DF:IsValidFrame(frame) then return end

    local unit = frame.unit or frame.displayedUnit
    if not frame.buffFrames and not frame.debuffFrames then return end

    local db = DF:GetDB(frame)
    
    -- FIX: Ensure the main frame is always clickable in normal mode.
    -- CRITICAL FIX: Check InCombatLockdown() to prevent ADDON_ACTION_BLOCKED errors
    if not DF.demoMode then
        if not InCombatLockdown() then
            frame:EnableMouse(true)
        end
    end
    
    -- Calculate Anchor points relative to growth direction
    local function GetRelativePoints(direction)
        if direction == "LEFT" then
            return "RIGHT", "LEFT", -2, 0
        elseif direction == "RIGHT" then
            return "LEFT", "RIGHT", 2, 0
        elseif direction == "UP" then
            return "BOTTOM", "TOP", 0, 2
        elseif direction == "DOWN" then
            return "TOP", "BOTTOM", 0, -2
        else
            -- Fallback
            return "LEFT", "RIGHT", 2, 0
        end
    end

    -- Parse "PRIMARY_SECONDARY" growth strings (e.g., "LEFT_DOWN")
    -- Added stackFont argument and countdown arguments
    local function ApplyLayout(auraFrames, scale, alpha, anchor, growthString, limit, offX, offY, maxCount, clickThrough, stackScale, stackAnchor, stackX, stackY, stackOutline, stackFont, showCountdown, countdownScale, countdownFont, countdownOutline, countdownX, countdownY, hideSwipe)
        if not auraFrames then return end
        
        -- Split growth direction string
        local primary, secondary = strsplit("_", growthString or "LEFT_DOWN")
        primary = primary or "LEFT"
        secondary = secondary or "DOWN"
        
        -- 1. Determine Primary Growth (Connection between neighbor icons)
        local pPoint, pRelPoint, pX, pY = GetRelativePoints(primary)
        
        -- 2. Determine Secondary Wrap (Connection between new row/col and start of previous)
        local sX, sY = 0, 0
        
        -- FIX: Removed "* scale" multiplier. 
        -- SetPoint offsets automatically scale with the frame's scale, so multiplying here resulted in double-scaling.
        local wrapSize = 20
        
        if secondary == "DOWN" then
            sY = -wrapSize
        elseif secondary == "UP" then
            sY = wrapSize
        elseif secondary == "LEFT" then
            sX = -wrapSize
        elseif secondary == "RIGHT" then
            sX = wrapSize
        end

        -- Apply layout to each aura
        for i, aura in ipairs(auraFrames) do
            if i > (maxCount or 99) then
                aura:Hide()
            elseif aura:IsShown() then
                
                -- STRATA FIX: Ensure Aura is above Absorb Glow (which is usually Health + 10)
                -- We set it to Health + 25 to guarantee visibility over glows and overlays
                if frame.healthBar then
                    local baseLevel = frame.healthBar:GetFrameLevel()
                    aura:SetFrameLevel(baseLevel + 25)
                end

                aura:SetScale(scale)
                aura:SetAlpha(alpha or 1.0)
                
                -- FORCE CLICK-THROUGH IN DEMO MODE
                if DF.demoMode and unit == "dandersdemo" then
                    aura:EnableMouse(false)
                else
                    aura:EnableMouse(not clickThrough)
                end
                
                -- COUNTDOWN TEXT on Cooldown Frame
                if aura.cooldown then
                    -- Always hide Blizzard's countdown - we'll use our own
                    aura.cooldown:SetHideCountdownNumbers(true)
                    
                    -- Hide/Show the swipe animation
                    aura.cooldown:SetDrawSwipe(not hideSwipe)
                    
                    if showCountdown then
                        -- Create our custom countdown text overlay
                        if not aura.dfCountdownOverlay then
                            aura.dfCountdownOverlay = CreateFrame("Frame", nil, aura)
                            aura.dfCountdownOverlay:SetAllPoints(aura)
                            aura.dfCountdownOverlay:SetFrameLevel(aura:GetFrameLevel() + 12)
                            
                            aura.dfCountdownText = aura.dfCountdownOverlay:CreateFontString(nil, "OVERLAY")
                        end
                        
                        -- Configure the font
                        local cdFont = countdownFont or "Fonts\\FRIZQT__.TTF"
                        local cdSize = 12 * (countdownScale or 1.0)
                        local cdOutline = countdownOutline or "OUTLINE"
                        aura.dfCountdownText:SetFont(cdFont, cdSize, cdOutline)
                        aura.dfCountdownText:SetTextColor(1, 1, 0.8, 1)
                        aura.dfCountdownText:SetShadowOffset(1, -1)
                        aura.dfCountdownText:SetShadowColor(0, 0, 0, 1)
                        
                        -- Position with offsets
                        aura.dfCountdownText:ClearAllPoints()
                        aura.dfCountdownText:SetPoint("CENTER", aura, "CENTER", countdownX or 0, countdownY or 0)
                        
                        -- Store reference to cooldown for OnUpdate
                        aura.dfCountdownOverlay.cooldown = aura.cooldown
                        
                        -- Hook SetCooldown to capture start/duration before they become secret
                        if not aura.cooldown.dfHooked then
                            hooksecurefunc(aura.cooldown, "SetCooldown", function(self, start, duration)
                                self.dfStart = start
                                self.dfDuration = duration
                            end)
                            aura.cooldown.dfHooked = true
                        end
                        
                        -- Set up OnUpdate to read cooldown times from our stored values
                        if not aura.dfCountdownOverlay.hasOnUpdate then
                            aura.dfCountdownOverlay:SetScript("OnUpdate", function(self, elapsed)
                                self.elapsed = (self.elapsed or 0) + elapsed
                                if self.elapsed < 0.1 then return end
                                self.elapsed = 0
                                
                                local cd = self.cooldown
                                local text = self:GetParent().dfCountdownText
                                
                                -- Use our stored values instead of API calls
                                if cd and cd:IsShown() and cd.dfStart and cd.dfDuration and cd.dfDuration > 0 then
                                    local remaining = (cd.dfStart + cd.dfDuration) - GetTime()
                                    
                                    if remaining > 0.5 then
                                        if remaining >= 3600 then
                                            text:SetText(math.floor(remaining / 3600) .. "h")
                                        elseif remaining >= 60 then
                                            text:SetText(math.floor(remaining / 60) .. "m")
                                        elseif remaining >= 10 then
                                            text:SetText(math.floor(remaining))
                                        elseif remaining >= 3 then
                                            text:SetFormattedText("%.0f", remaining)
                                        else
                                            text:SetFormattedText("%.1f", remaining)
                                        end
                                        text:Show()
                                    else
                                        text:Hide()
                                    end
                                else
                                    text:Hide()
                                end
                            end)
                            aura.dfCountdownOverlay.hasOnUpdate = true
                        end
                        
                        aura.dfCountdownOverlay:Show()
                    else
                        -- Hide our countdown
                        if aura.dfCountdownOverlay then
                            aura.dfCountdownOverlay:Hide()
                        end
                    end
                end
                
                -- NEW: Stack Text Customization
                if aura.count then
                    -- FIX: Ensure Stack Text is above Cooldown Swipe (Clip Fix)
                    -- We create a dedicated overlay frame that that sits significantly higher than the aura frame
                    if not aura.dfTextOverlay then
                        aura.dfTextOverlay = CreateFrame("Frame", nil, aura)
                        aura.dfTextOverlay:SetAllPoints(aura)
                    end
                    -- Update frame level to be higher than the cooldown (which typically inherits parent level)
                    -- Since we bumped aura to +25, this will be relative to that (+35 total), ensuring visibility
                    aura.dfTextOverlay:SetFrameLevel(aura:GetFrameLevel() + 10)
                    
                    -- Reparent the FontString to this overlay
                    if aura.count:GetParent() ~= aura.dfTextOverlay then
                        aura.count:SetParent(aura.dfTextOverlay)
                    end

                    local baseSize = 11 -- Approximate base size for NumberFontNormalSmall
                    local font = stackFont or "Fonts\\FRIZQT__.TTF" -- Default to Friz if not set
                    
                    -- Apply Font size and Outline
                    aura.count:SetFont(font, baseSize * (stackScale or 1.0), stackOutline or "OUTLINE")
                    
                    aura.count:ClearAllPoints()
                    aura.count:SetPoint(stackAnchor or "BOTTOMRIGHT", aura, stackAnchor or "BOTTOMRIGHT", stackX or 0, stackY or 0)
                end
                
                aura:ClearAllPoints()
                
                if i == 1 then
                    -- First Icon anchors directly to the frame
                    aura:SetPoint(anchor, frame, anchor, offX, offY)
                else
                    -- Check for Wrap condition
                    local isNewRow = ((i - 1) % limit) == 0
                    
                    if isNewRow then
                        -- Anchor to the start of the previous row (i - limit)
                        local prevRowStart = auraFrames[i - limit]
                        if prevRowStart and prevRowStart:IsShown() then
                            -- Use "TOPLEFT" for consistent wrap alignment relative to the previous row start
                            aura:SetPoint("TOPLEFT", prevRowStart, "TOPLEFT", sX, sY)
                        else
                            -- Fallback
                            aura:SetPoint(anchor, frame, anchor, offX, offY)
                        end
                    else
                        -- Normal Growth (anchors to immediate previous icon)
                        local prev = auraFrames[i-1]
                        if prev and prev:IsShown() then
                            aura:SetPoint(pPoint, prev, pRelPoint, pX, pY)
                        -- else (Fallback, same as above for safety)
                        else
                            aura:SetPoint(anchor, frame, anchor, offX, offY)
                        end
                    end
                end
            end
        end
    end

    -- Apply to Buffs
    ApplyLayout(
        frame.buffFrames, 
        db.raidBuffScale, 
        db.raidBuffAlpha,
        db.raidBuffAnchor, 
        db.raidBuffGrowth, 
        db.raidBuffWrap, 
        db.raidBuffOffsetX, 
        db.raidBuffOffsetY,
        db.raidBuffMax, 
        db.raidBuffClickThrough,
        db.raidBuffStackScale,
        db.raidBuffStackAnchor,
        db.raidBuffStackX,
        db.raidBuffStackY,
        db.raidBuffStackOutline,
        db.raidBuffStackFont,
        db.raidBuffShowCountdown,
        db.raidBuffCountdownScale,
        db.raidBuffCountdownFont,
        db.raidBuffCountdownOutline,
        db.raidBuffCountdownX,
        db.raidBuffCountdownY,
        db.raidBuffHideSwipe
    )

    -- Apply to Debuffs
    ApplyLayout(
        frame.debuffFrames, 
        db.raidDebuffScale, 
        db.raidDebuffAlpha,
        db.raidDebuffAnchor, 
        db.raidDebuffGrowth, 
        db.raidDebuffWrap, 
        db.raidDebuffOffsetX, 
        db.raidDebuffOffsetY,
        db.raidDebuffMax, 
        db.raidDebuffClickThrough,
        db.raidDebuffStackScale,
        db.raidDebuffStackAnchor,
        db.raidDebuffStackX,
        db.raidDebuffStackY,
        db.raidDebuffStackOutline,
        db.raidDebuffStackFont,
        db.raidDebuffShowCountdown,
        db.raidDebuffCountdownScale,
        db.raidDebuffCountdownFont,
        db.raidDebuffCountdownOutline,
        db.raidDebuffCountdownX,
        db.raidDebuffCountdownY,
        db.raidDebuffHideSwipe
    )
end

-- =========================================================================
-- DEMO DISPEL ICON (Custom Preview Icon)
-- This is ONLY for preview/demo purposes and is completely separate from
-- Blizzard's combat dispel icons.
-- =========================================================================

-- Creates and manages a custom DEMO icon that only shows when:
-- 1. 'Show Dispel Overlay Frame Demo' (showDispelOverlay) is ENABLED
-- 2. 'Show Dispel Icon' (showDispelIcon) is ENABLED
-- This icon has NO connection to Blizzard's actual combat dispel icons.
function DF:UpdateDemoDispelIcon(frame)
    if not DF:IsValidFrame(frame) then return end
    local db = DF:GetDB(frame)
    local fName = frame:GetName() or "Anon"

    -- 1. SETUP CUSTOM DEMO DISPEL ICON FRAME (dfDemoDispelIcon)
    if not frame.dfDemoDispelIcon then
        local f = CreateFrame("Frame", nil, frame)
        f:SetSize(16, 16)
        f:SetFrameStrata("HIGH")
        f:SetFrameLevel(999) -- Extremely high level to ensure visibility
        f:EnableMouse(false)
        f:Hide() -- Start hidden
        
        -- Create the icon texture using the atlas
        local icon = f:CreateTexture(nil, "OVERLAY")
        icon:SetAllPoints(true)
        -- Use the Blizzard atlas for the magic dispel icon
        icon:SetAtlas("RaidFrame-Icon-DebuffMagic")
        f.icon = icon
        
        -- Create a border texture for aesthetics
        local border = f:CreateTexture(nil, "BORDER")
        border:SetTexture("Interface\\Buttons\\UI-Panel-Button-Border")
        border:SetAllPoints(true)
        border:Hide() -- Start hidden
        f.border = border
        
        frame.dfDemoDispelIcon = f
        
        if DF.debugEnabled and fName == "CompactPartyFrameMember1" then
            print("|cff00ff00DF DEBUG:|r Created new demo dispel icon frame (dfDemoDispelIcon).")
        end
    end
    
    local demoIcon = frame.dfDemoDispelIcon
    
    -- 2. DETERMINE VISIBILITY
    -- The demo icon ONLY shows when BOTH conditions are met:
    -- - showDispelOverlay is enabled (the "Show Dispel Overlay Frame Demo" checkbox)
    -- - showDispelIcon is enabled
    local shouldShowDemoIcon = db.showDispelOverlay and db.showDispelIcon
    
    if shouldShowDemoIcon then
        -- Set size based on debuff scale
        local size = 16 * (db.raidDebuffScale or 1.0)
        
        demoIcon:SetSize(size, size)
        demoIcon:ClearAllPoints()
        demoIcon:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
        
        -- Ensure frame level is high enough
        if frame.healthBar then
            demoIcon:SetFrameLevel(frame.healthBar:GetFrameLevel() + 50)
        end
        
        demoIcon:Show()
        demoIcon.icon:Show()
        demoIcon.border:SetShown(db.showDispelBorder or false)
    else
        -- Hide the demo icon
        demoIcon:Hide()
        demoIcon.icon:Hide()
        demoIcon.border:Hide()
    end
    
    -- Clean up any legacy frames from previous implementations
    if frame.dfDebugFrame then frame.dfDebugFrame:Hide() end
    if frame.dfDemoIcon then frame.dfDemoIcon:Hide() end
    if frame.dfCustomDispelIcon then frame.dfCustomDispelIcon:Hide() end
end


-- =========================================================================
-- UPDATE BLIZZARD DISPEL ICONS (Combat Icons)
-- These are the REAL dispel icons that show during combat.
-- They are ONLY controlled by 'Show Dispel Icon' (showDispelIcon).
-- 'Show Dispel Overlay Frame Demo' has NO effect on these.
-- =========================================================================

-- Dedicated hidden frame for stealing cooldowns
if not DF.HiddenFrame then DF.HiddenFrame = CreateFrame("Frame") DF.HiddenFrame:Hide() end

function DF:UpdateDispelIcons(frame)
    if not DF:IsValidFrame(frame) then return end
    local db = DF:GetDB(frame)
    local frameName = frame:GetName()

    -- Iterate all Blizzard dispel frames (indices 0-5)
    -- These are the REAL combat dispel icons
    for i = 0, 5 do
        local dispelFrame = nil
        
        -- Get the frame object
        if frame.dispelDebuffFrames and frame.dispelDebuffFrames[i] then
            dispelFrame = frame.dispelDebuffFrames[i]
        elseif frame["DispelDebuff"..i] then
            dispelFrame = frame["DispelDebuff"..i]
        elseif frameName then
            dispelFrame = _G[frameName.."DispelDebuff"..i]
        end
        
        if dispelFrame then
            local iconTex = dispelFrame.icon or (frameName and _G[frameName.."DispelDebuff"..i.."Icon"])
            
            -- Disable mouse interaction to prevent tooltip conflicts
            dispelFrame:EnableMouse(false)
            dispelFrame:SetScript("OnEnter", nil)
            dispelFrame:SetScript("OnLeave", nil)
            
            if db.showDispelIcon then
                -- showDispelIcon is ENABLED: Let Blizzard fully control visibility
                -- We only adjust the draw layer, nothing else
                -- Blizzard's CompactUnitFrame_UpdateDispelDebuffs handles show/hide
                if iconTex then
                    if db.dispelLevelIcon and db.dispelLevelIcon > 0 then
                        iconTex:SetDrawLayer("OVERLAY", db.dispelLevelIcon)
                    else
                        iconTex:SetDrawLayer("OVERLAY", 1)
                    end
                end
                -- DO NOT call Show() or Hide() - let Blizzard handle it
            else
                -- showDispelIcon is DISABLED: Force hide all Blizzard dispel icons
                if iconTex then
                    iconTex:Hide()
                    iconTex:SetTexture(nil)
                    iconTex:SetAtlas(nil)
                end
                dispelFrame:Hide()
            end
        end
    end
    
    -- Update the DEMO dispel icon (separate from Blizzard icons)
    DF:UpdateDemoDispelIcon(frame)

    -- Handle the "DispelOverlay" Frame (Colored Border/Gradient visual effect)
    -- This is the visual overlay effect, not the icon
    if frame.DispelOverlay then
        local ov = frame.DispelOverlay
        
        -- Force Strata to match Frame to ensure FrameLevels compare correctly
        if ov.SetFrameStrata then 
            ov:SetFrameStrata(frame:GetFrameStrata()) 
        end
        
        -- CRITICAL FIX: Always set DispelOverlay level high enough for sandwich mode
        -- Check if either absorb bar or heal absorb bar is using sandwich mode
        local absorbStrata = db.absorbBarStrata or "MEDIUM"
        local healAbsorbStrata = db.healAbsorbBarStrata or "MEDIUM"
        local usingSandwich = (absorbStrata == "SANDWICH" or absorbStrata == "SANDWICH_LOW" or
                               healAbsorbStrata == "SANDWICH" or healAbsorbStrata == "SANDWICH_LOW")
        
        if frame.healthBar then
            local healthLevel = frame.healthBar:GetFrameLevel()
            local overlayLevel
            
            if usingSandwich then
                -- For sandwich mode: Set overlay level HIGH (above absorb bars at +3/+6)
                overlayLevel = healthLevel + 15
            else
                -- Normal mode: Use configured level or default to +5
                local boost = db.dispelLevelOverlay or 5
                if boost == 0 then boost = 5 end  -- Ensure non-zero
                overlayLevel = healthLevel + boost
            end
            
            ov:SetFrameLevel(overlayLevel)
            
            if DF.debugEnabled then
                print("DF Auras: Set DispelOverlay to level " .. overlayLevel .. " (sandwich=" .. tostring(usingSandwich) .. ", absorbStrata=" .. absorbStrata .. ")")
            end
        end
        
        -- Show/hide the overlay based on the demo toggle
        ov:SetShown(db.showDispelOverlay)
        
        if ov.Background then
            ov.Background:SetShown(db.showDispelBackground)
            if db.dispelLevelBackground then ov.Background:SetDrawLayer("OVERLAY", db.dispelLevelBackground) end
        end
        
        if ov.Border then
            ov.Border:SetShown(db.showDispelBorder)
            if db.dispelLevelBorder then ov.Border:SetDrawLayer("OVERLAY", db.dispelLevelBorder) end
        end
        
        if ov.Gradient then
            ov.Gradient:SetShown(db.showDispelGradient)
            if db.dispelLevelGradient then ov.Gradient:SetDrawLayer("OVERLAY", db.dispelLevelGradient) end
        end
    end
end

-- Legacy function name for backwards compatibility with hooks
function DF:UpdateMidnightIcon(frame)
    DF:UpdateDemoDispelIcon(frame)
end

-- SHOW FAKE DEMO AURAS
function DF:UpdateDemoAuras(frame)
    -- Ensure Frames Exist
    if not frame.debuffFrames then frame.debuffFrames = {} end
    if not frame.buffFrames then frame.buffFrames = {} end
    
    -- 1. FAKE DEBUFFS (Standard Grid Layout)
    local fakeDebuffs = {
        { icon = "Interface\\Icons\\Spell_Shadow_ShadowWordPain", type = "Magic", color = DebuffTypeColor["Magic"] },
        { icon = "Interface\\Icons\\Spell_Nature_Regeneration", type = "Poison", color = DebuffTypeColor["Poison"] },
        { icon = "Interface\\Icons\\Spell_Holy_WordFortitude", type = "Curse", color = DebuffTypeColor["Curse"] },
    }

    for i, debuffInfo in ipairs(fakeDebuffs) do
        local f = frame.debuffFrames[i]
        if not f then
            f = CreateFrame("Button", nil, frame, "CompactAuraTemplate")
            frame.debuffFrames[i] = f
        end
        
        if f then
            f:Show()
            f:EnableMouse(false) -- Disable mouse interaction
            f:SetScript("OnEnter", nil) -- Ensure no tooltips scripts run
            f:SetScript("OnLeave", nil)
            
            if f.icon then f.icon:SetTexture(debuffInfo.icon) end
            if f.border then 
                f.border:SetVertexColor(debuffInfo.color.r, debuffInfo.color.g, debuffInfo.color.b)
                f.border:Show()
            end
            
            -- Add fake count for testing stack text
            if f.count then 
                f.count:SetText(i > 1 and i or "") -- Show count 2 and 3
                f.count:Show()
            end
        end
    end
    
    -- Hide excess debuffs
    for i = #fakeDebuffs + 1, #frame.debuffFrames do
        if frame.debuffFrames[i] then frame.debuffFrames[i]:Hide() end
    end

    -- 2. FAKE BUFFS (Standard Grid Layout)
    local fakeBuffs = {
        { icon = "Interface\\Icons\\Spell_Holy_PowerWordShield" },
        { icon = "Interface\\Icons\\Spell_Nature_Rejuvenation" },
        { icon = "Interface\\Icons\\Spell_Holy_FlashHeal" },
    }

    for i, buffInfo in ipairs(fakeBuffs) do
        local f = frame.buffFrames[i]
        if not f then
            f = CreateFrame("Button", nil, frame, "CompactAuraTemplate")
            frame.buffFrames[i] = f
        end
        
        if f then
            f:Show()
            f:EnableMouse(false) -- Disable mouse interaction
            f:SetScript("OnEnter", nil) -- Ensure no tooltips scripts run
            f:SetScript("OnLeave", nil)
            
            if f.icon then f.icon:SetTexture(buffInfo.icon) end
            if f.border then f.border:Hide() end -- Buffs usually don't have type borders
            
             -- Add fake count for testing stack text
            if f.count then 
                f.count:SetText(i > 1 and "5" or "") 
                f.count:Show()
            end
        end
    end
    
    -- Trigger Layout (for custom icons/stacks)
    DF:ApplyAuraLayout(frame)
    
    -- Trigger Dispels (Separate from main aura grid, applies show/hide toggles)
    DF:UpdateDispelIcons(frame)
end