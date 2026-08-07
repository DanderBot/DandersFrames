local addonName, DF = ...

-- ============================================================
-- FRAMES UPDATE MODULE
-- Contains frame update and layout functions
-- ============================================================

-- Core.lua sets DF.L and is listed well before this file in the .toc, so grabbing
-- it at file scope is safe -- the same thing TextDesigner/Resolver.lua does.
local L = DF.L

-- Local caching of frequently used globals and WoW API for performance.
-- Audit finding #3 (2026-04-06): UpdateHealthFast and UpdatePower are
-- called once per unit per UNIT_HEALTH / UNIT_POWER event, and each
-- call hits 3-5 of these unit API functions. In a 25-player raid at
-- typical combat event rates that's thousands of global hash lookups
-- per second that compile to nothing with these locals in scope.
-- Matching pattern: Frames/Bars.lua:8-19 already uses this pattern
-- for its own unit API calls.
local pairs, ipairs, type, tonumber, tostring = pairs, ipairs, type, tonumber, tostring
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local format = string.format
local issecretvalue = issecretvalue
local InCombatLockdown = InCombatLockdown
-- Unit health / power / state APIs (hot path in UpdateHealthFast + UpdatePower)
local UnitExists = UnitExists
local UnitClass = UnitClass
local UnitIsConnected = UnitIsConnected
local UnitIsDead = UnitIsDead
local UnitIsGhost = UnitIsGhost
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitHealthMissing = UnitHealthMissing
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local UnitPowerType = UnitPowerType

-- Shared default tables (avoid per-call allocation)

function DF:ApplyFrameLayout(frame)
    if not frame then return end
    
    -- Skip SetSize operations on secure header children during combat
    -- These frames are protected and cannot be resized in combat
    local isSecureChild = frame.dfIsHeaderChild
    local skipResize = isSecureChild and InCombatLockdown()
    
    local db = DF:GetFrameDB(frame)

    -- Frame size (with pixel-perfect support)
    -- Skip during combat for secure frames
    if not skipResize then
        -- Pinned frames carry their own resolved size (Match baseline + per-set
        -- Width/Height overrides, via PinnedFrames.GetSetFrameSize). Prefer it so the shared
        -- per-mode db.frameWidth/Height doesn't clobber a pinned set's size on
        -- the next update tick. Main frames have no stamp and use the mode db.
        local frameWidth = frame.dfPinnedWidth or db.frameWidth or 120
        local frameHeight = frame.dfPinnedHeight or db.frameHeight or 50
        DF:SetPixelPerfectSize(frame, frameWidth, frameHeight, db)
    end
    
    -- NOTE: We no longer skip layout during slider drag
    -- Throttling is now handled by ThrottledUpdateAll() instead
    
    -- ========================================
    -- HEALTH BAR
    -- ========================================
    local healthBar = frame.healthBar
    if healthBar then
        -- Texture
        local healthTex = db.healthTexture or "Interface\\TargetingFrame\\UI-StatusBar"
        -- Safe setter: falls back to the stock texture when the configured path
        -- is missing (imported profiles referencing another addon's media render
        -- solid green otherwise). Frame CREATION already used the safe setter,
        -- but this per-update raw call immediately clobbered its fallback.
        DF:SafeSetStatusBarTexture(healthBar, healthTex)
        
        -- Orientation
        local orientation = db.healthOrientation or "HORIZONTAL"
        if orientation == "HORIZONTAL" then
            healthBar:SetOrientation("HORIZONTAL")
            healthBar:SetReverseFill(false)
            healthBar:SetRotatesTexture(false)
        elseif orientation == "HORIZONTAL_INV" then
            healthBar:SetOrientation("HORIZONTAL")
            healthBar:SetReverseFill(true)
            healthBar:SetRotatesTexture(false)
        elseif orientation == "VERTICAL" then
            healthBar:SetOrientation("VERTICAL")
            healthBar:SetReverseFill(false)
            healthBar:SetRotatesTexture(true)
        elseif orientation == "VERTICAL_INV" then
            healthBar:SetOrientation("VERTICAL")
            healthBar:SetReverseFill(true)
            healthBar:SetRotatesTexture(true)
        end
        
        -- Also apply to missing health bar (opposite fill direction)
        if frame.missingHealthBar then
            if orientation == "HORIZONTAL" then
                frame.missingHealthBar:SetOrientation("HORIZONTAL")
                frame.missingHealthBar:SetReverseFill(true)  -- Opposite of health bar
                frame.missingHealthBar:SetRotatesTexture(false)
            elseif orientation == "HORIZONTAL_INV" then
                frame.missingHealthBar:SetOrientation("HORIZONTAL")
                frame.missingHealthBar:SetReverseFill(false)  -- Opposite of health bar
                frame.missingHealthBar:SetRotatesTexture(false)
            elseif orientation == "VERTICAL" then
                frame.missingHealthBar:SetOrientation("VERTICAL")
                frame.missingHealthBar:SetReverseFill(true)  -- Opposite of health bar
                frame.missingHealthBar:SetRotatesTexture(true)
            elseif orientation == "VERTICAL_INV" then
                frame.missingHealthBar:SetOrientation("VERTICAL")
                frame.missingHealthBar:SetReverseFill(false)  -- Opposite of health bar
                frame.missingHealthBar:SetRotatesTexture(true)
            end
        end
    end
    
    -- ========================================
    -- RESOURCE/POWER BAR LAYOUT
    -- Delegated to ApplyResourceBarLayout which handles show/hide,
    -- role filtering, layout, background, border, and frame level
    -- ========================================
    DF:ApplyResourceBarLayout(frame)
    
    -- ========================================
    -- ABSORB BAR LAYOUT
    -- ========================================
    local absorbBar = frame.dfAbsorbBar
    if absorbBar then
        local absorbMode = db.absorbBarMode or "OVERLAY"
        local absorbTex = db.absorbBarTexture or "Interface\\Buttons\\WHITE8x8"
        local absorbColor = db.absorbBarColor or {r = 0, g = 0.835, b = 1, a = 0.7}
        
        DF:SafeSetStatusBarTexture(absorbBar, absorbTex)
        absorbBar:SetStatusBarColor(absorbColor.r, absorbColor.g, absorbColor.b, absorbColor.a)
        
        if absorbMode == "FLOATING" then
            -- Floating mode positioning
            absorbBar:ClearAllPoints()
            local anchor = db.absorbBarAnchor or "BOTTOM"
            absorbBar:SetPoint(anchor, frame, anchor, db.absorbBarX or 0, db.absorbBarY or 0)
            
            -- Apply pixel-perfect sizing
            local absorbWidth = db.absorbBarWidth or 50
            local absorbHeight = db.absorbBarHeight or 6
            if db.pixelPerfect then
                absorbWidth = DF:PixelPerfect(absorbWidth)
                absorbHeight = DF:PixelPerfect(absorbHeight)
            end
            absorbBar:SetSize(absorbWidth, absorbHeight)
            
            local orient = db.absorbBarOrientation or "HORIZONTAL"
            absorbBar:SetOrientation(orient)
            absorbBar:SetReverseFill(db.absorbBarReverse or false)
            
            if absorbBar.bg then
                local bgC = db.absorbBarBackgroundColor or {r = 0, g = 0, b = 0, a = 0.5}
                absorbBar.bg:SetColorTexture(bgC.r, bgC.g, bgC.b, bgC.a)
            end
        end
    end
    
    -- ========================================
    -- HEAL ABSORB BAR LAYOUT
    -- ========================================
    local healAbsorbBar = frame.dfHealAbsorbBar
    if healAbsorbBar then
        local healAbsorbMode = db.healAbsorbBarMode or "OVERLAY"
        local healAbsorbTex = db.healAbsorbBarTexture or "Interface\\Buttons\\WHITE8x8"
        local healAbsorbColor = db.healAbsorbBarColor or {r = 0.4, g = 0.1, b = 0.1, a = 0.7}
        
        DF:SafeSetStatusBarTexture(healAbsorbBar, healAbsorbTex)
        healAbsorbBar:SetStatusBarColor(healAbsorbColor.r, healAbsorbColor.g, healAbsorbColor.b, healAbsorbColor.a)
        
        if healAbsorbMode == "FLOATING" then
            -- Floating mode positioning
            healAbsorbBar:ClearAllPoints()
            local anchor = db.healAbsorbBarAnchor or "BOTTOM"
            healAbsorbBar:SetPoint(anchor, frame, anchor, db.healAbsorbBarX or 0, db.healAbsorbBarY or -10)
            
            -- Apply pixel-perfect sizing
            local healAbsorbWidth = db.healAbsorbBarWidth or 50
            local healAbsorbHeight = db.healAbsorbBarHeight or 6
            if db.pixelPerfect then
                healAbsorbWidth = DF:PixelPerfect(healAbsorbWidth)
                healAbsorbHeight = DF:PixelPerfect(healAbsorbHeight)
            end
            healAbsorbBar:SetSize(healAbsorbWidth, healAbsorbHeight)
            
            local orient = db.healAbsorbBarOrientation or "HORIZONTAL"
            healAbsorbBar:SetOrientation(orient)
            healAbsorbBar:SetReverseFill(db.healAbsorbBarReverse or false)
            
            if healAbsorbBar.bg then
                local bgC = db.healAbsorbBarBackgroundColor or {r = 0, g = 0, b = 0, a = 0.5}
                healAbsorbBar.bg:SetColorTexture(bgC.r, bgC.g, bgC.b, bgC.a)
            end
        end
    end
    
    -- ========================================
    -- BORDER
    -- ========================================
    if frame.border then
        DF:ApplyFrameBorder(frame, db)
    end
    
    -- ========================================
    -- NAME TEXT
    -- ========================================
    if frame.nameText then
        local nameFont = db.nameFont or "Fonts\\FRIZQT__.TTF"
        local nameFontSize = db.nameFontSize or 11
        local nameOutline = db.nameTextOutline or "OUTLINE"
        if nameOutline == "NONE" then nameOutline = "" end
        
        DF:SafeSetFont(frame.nameText, nameFont, nameFontSize, nameOutline)
        
        local nameAnchor = db.nameTextAnchor or "TOP"
        frame.nameText:ClearAllPoints()
        frame.nameText:SetPoint(nameAnchor, frame, nameAnchor, db.nameTextX or 0, db.nameTextY or -2)
        
        -- Defer color AND alpha to the appearance system so OOR fading is respected.
        -- Previously this hardcoded alpha=1.0 which overrode range fading on roster changes.
        if DF.UpdateNameTextAppearance then
            DF:UpdateNameTextAppearance(frame)
        elseif not db.nameTextUseClassColor then
            local nameColor = db.nameTextColor or {r = 1, g = 1, b = 1, a = 1}
            frame.nameText:SetTextColor(nameColor.r, nameColor.g, nameColor.b, nameColor.a or 1)
        end
    end
    
    -- ========================================
    -- HEALTH TEXT
    -- ========================================
    if frame.healthText then
        local healthFont = db.healthFont or "Fonts\\FRIZQT__.TTF"
        local healthFontSize = db.healthFontSize or 10
        local healthOutline = db.healthTextOutline or "OUTLINE"
        if healthOutline == "NONE" then healthOutline = "" end
        
        DF:SafeSetFont(frame.healthText, healthFont, healthFontSize, healthOutline)
        
        local healthAnchor = db.healthTextAnchor or "CENTER"
        frame.healthText:ClearAllPoints()
        frame.healthText:SetPoint(healthAnchor, frame, healthAnchor, db.healthTextX or 0, db.healthTextY or 0)
        
        if DF.UpdateHealthTextAppearance then
            DF:UpdateHealthTextAppearance(frame)
        elseif not db.healthTextUseClassColor then
            local healthTextColor = db.healthTextColor or {r = 1, g = 1, b = 1, a = 1}
            frame.healthText:SetTextColor(healthTextColor.r, healthTextColor.g, healthTextColor.b, healthTextColor.a or 1)
        end
    end
    
    -- ========================================
    -- STATUS TEXT
    -- ========================================
    if frame.statusText then
        local statusFont = db.statusTextFont or "Fonts\\FRIZQT__.TTF"
        local statusFontSize = db.statusTextFontSize or 10
        local statusOutline = db.statusTextOutline or "OUTLINE"
        if statusOutline == "NONE" then statusOutline = "" end
        
        DF:SafeSetFont(frame.statusText, statusFont, statusFontSize, statusOutline)
        
        local statusAnchor = db.statusTextAnchor or "CENTER"
        frame.statusText:ClearAllPoints()
        frame.statusText:SetPoint(statusAnchor, frame, statusAnchor, db.statusTextX or 0, db.statusTextY or 0)
        
        if DF.UpdateStatusTextAppearance then
            DF:UpdateStatusTextAppearance(frame)
        else
            local statusColor = db.statusTextColor or {r = 1, g = 1, b = 1, a = 1}
            frame.statusText:SetTextColor(statusColor.r, statusColor.g, statusColor.b, statusColor.a or 1)
        end
    end
    
    -- ========================================
    -- ROLE ICON
    -- ========================================
    -- Role/raid-target icons: layout owns the flat BASE size only (matching the
    -- leader/ready-check pattern below); the user's scale is applied exactly once,
    -- via SetScale in the Bars.lua updaters + the slider lightweight path. The old
    -- code multiplied the scale into the size here too, so both icons rendered at
    -- base × scale² whenever the scale wasn't 1.0.
    if frame.roleIcon then
        local roleAnchor = db.roleIconAnchor or "TOPLEFT"
        local roleX = db.roleIconX or 2
        local roleY = db.roleIconY or -2

        local roleSize = 18
        if db.pixelPerfect then
            roleSize = DF:PixelPerfect(roleSize)
        end
        frame.roleIcon:SetSize(roleSize, roleSize)
        frame.roleIcon:ClearAllPoints()
        frame.roleIcon:SetPoint(roleAnchor, frame, roleAnchor, roleX, roleY)
    end

    -- ========================================
    -- RAID TARGET ICON
    -- ========================================
    if frame.raidTargetIcon then
        local raidTargetAnchor = db.raidTargetIconAnchor or "TOP"
        local raidTargetX = db.raidTargetIconX or 0
        local raidTargetY = db.raidTargetIconY or 2

        local raidTargetSize = 16
        if db.pixelPerfect then
            raidTargetSize = DF:PixelPerfect(raidTargetSize)
        end
        frame.raidTargetIcon:SetSize(raidTargetSize, raidTargetSize)
        frame.raidTargetIcon:ClearAllPoints()
        frame.raidTargetIcon:SetPoint(raidTargetAnchor, frame, raidTargetAnchor, raidTargetX, raidTargetY)
    end
    
    -- ========================================
    -- LEADER ICON
    -- ========================================
    -- Positioning handled by UpdateLeaderIcon in Bars.lua to avoid duplication
    if frame.leaderIcon then
        local leaderSize = 12
        if db.pixelPerfect then
            leaderSize = DF:PixelPerfect(leaderSize)
        end
        frame.leaderIcon:SetSize(leaderSize, leaderSize)
        -- Call UpdateLeaderIcon for positioning (respects user settings)
        if DF.UpdateLeaderIcon then
            DF:UpdateLeaderIcon(frame)
        end
    end
    
    -- ========================================
    -- READY CHECK ICON
    -- ========================================
    if frame.readyCheckIcon then
        local readyCheckSize = 16
        if db.pixelPerfect then
            readyCheckSize = DF:PixelPerfect(readyCheckSize)
        end
        frame.readyCheckIcon:SetSize(readyCheckSize, readyCheckSize)
    end
    
    -- ========================================
    -- RESTED INDICATOR
    -- ========================================
    if frame.restedIndicator then
        local restedSize = db.restedIndicatorSize or 20
        -- Use new corner-hanging defaults; ignore old values that were for inside-frame positioning
        local restedX = db.restedIndicatorOffsetX
        local restedY = db.restedIndicatorOffsetY
        -- If using old default values (around -2), switch to new defaults
        if not restedX or restedX > -10 then restedX = -18 end
        if not restedY or restedY > -10 then restedY = -14 end
        
        if db.pixelPerfect then
            restedSize = DF:PixelPerfect(restedSize)
        end
        -- Width is 1.2x height for the ZZZ layout
        frame.restedIndicator:SetSize(restedSize * 1.2, restedSize * 0.9)
        frame.restedIndicator:ClearAllPoints()
        frame.restedIndicator:SetPoint("BOTTOMLEFT", frame, "TOPRIGHT", restedX, restedY)
    end
    
    -- ========================================
    -- BACKGROUND COLOR & TEXTURE
    -- ========================================
    if frame.background then
        local bgTexture = db.backgroundTexture or "Solid"
        
        -- Apply texture only (color is handled by ElementAppearance)
        if bgTexture == "Solid" or bgTexture == "" then
            -- Solid color mode - just mark texture type, color set by ElementAppearance
            frame.dfCurrentBgTexture = "Solid"
        else
            -- Textured background - only call SetTexture if texture path changed
            if frame.dfCurrentBgTexture ~= bgTexture then
                DF:SafeSetTexture(frame.background, bgTexture)
                frame.background:SetHorizTile(false)
                frame.background:SetVertTile(false)
                frame.dfCurrentBgTexture = bgTexture
                frame.dfCurrentBgKey = nil  -- Clear key when switching to textured
            end
            
            -- Ensure SetAlpha is 1.0 for textured backgrounds (alpha controlled via vertex color)
            frame.background:SetAlpha(1.0)
        end
        
        -- Delegate color to ElementAppearance for centralized handling
        DF:UpdateBackgroundAppearance(frame)
    end
    
end

-- ============================================================
-- UNIFIED FRAME UPDATE
-- ============================================================

function DF:UpdateUnitFrame(frame, source)
    if DF.RosterDebugCount then 
        DF:RosterDebugCount("UpdateUnitFrame")
        if source then
            DF:RosterDebugCount("UpdateUnitFrame:" .. source)
        end
    end
    if not frame or not frame.unit then return end
    
    -- Skip if in test mode (test mode has its own update)
    local isRaid = DF:IsRaidFrame(frame)
    if isRaid and DF.raidTestMode then return end
    if not isRaid and DF.testMode then return end
    
    local unit = frame.unit
    if not UnitExists(unit) then return end

    local db = DF:GetFrameDB(frame)

    -- TD legacy-text suppression: when ON, hide name/status/health text on
    -- every branch so Phase C live TD rendering can be tested without overlap.
    local hideLegacyText = DF:IsLegacyTextHidden(frame)

    -- ========================================
    -- OFFLINE CHECK
    -- ========================================
    local isConnected = UnitIsConnected(unit)
    if not isConnected then
        -- Show offline state
        if frame.healthBar then
            -- FIX: Use SetMinMaxValues(0, 100) + SetValue(100) to match UpdateHealthFast.
            -- Previously used SetValue(1) without setting min/max, which could show as
            -- 1% health if the bar range was 0-100 from a prior SetHealthBarValue call.
            frame.healthBar:SetMinMaxValues(0, 100)
            frame.healthBar:SetValue(100)
        end
        if frame.nameText then
            if hideLegacyText then
                frame.nameText:Hide()
            else
                local name = DF:GetFrameName(unit) or unit
                -- Truncate name if needed (UTF-8 aware)
                local nameLength = db.nameTextLength or 0
                if nameLength > 0 and DF:UTF8Len(name) > nameLength then
                    if db.nameTextTruncateMode == "ELLIPSIS" then
                        name = DF:UTF8Sub(name, 1, nameLength) .. "..."
                    else
                        name = DF:UTF8Sub(name, 1, nameLength)
                    end
                end
                frame.nameText:SetText(name)
                frame.nameText:Show()
            end
        end
        if frame.statusText then
            if hideLegacyText or db.statusTextEnabled == false then
                frame.statusText:Hide()
            else
                frame.statusText:SetText(L["Offline"])
                frame.statusText:Show()
            end
        end
        if frame.healthText then
            frame.healthText:Hide()
        end
        if frame.dfPowerBar then
            frame.dfPowerBar:Hide()
        end
        if frame.dfAbsorbBar then
            frame.dfAbsorbBar:Hide()
        end
        if frame.dfHealAbsorbBar then
            frame.dfHealAbsorbBar:Hide()
        end
        if frame.dfReducedMaxHealthBar then
            frame.dfReducedMaxHealthBar:Hide()
            if DF.RestoreHealthBarFromReducedMax then DF:RestoreHealthBarFromReducedMax(frame) end
        end
        -- Apply dead fade for offline units
        DF:ApplyDeadFade(frame, "Offline")
        frame.dfLastKnownConnected = false
        -- ☠ This branch RETURNS, so the Text Designer render and the
        -- missing-buff visibility gate further down this function are never
        -- reached. Without them the TD keeps painting the last ALIVE state
        -- (a blank status) and the badge keeps claiming "missing" on a unit
        -- that can no longer be buffed — the field-reported follower-dungeon
        -- bug. Both are no-ops when nothing changed.
        if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "all") end
        if DF.RefreshMissingBuffVisibility then DF:RefreshMissingBuffVisibility(frame) end
        return
    end

    -- ========================================
    -- DEAD/GHOST CHECK
    -- ========================================
    local isDead = UnitIsDead(unit)
    local isGhost = UnitIsGhost(unit)

    if isDead or isGhost then
        if frame.healthBar then
            frame.healthBar:SetMinMaxValues(0, 100)
            frame.healthBar:SetValue(0)
        end
        if frame.nameText then
            if hideLegacyText then
                frame.nameText:Hide()
            else
                local name = DF:GetFrameName(unit) or unit
                -- Truncate name if needed (UTF-8 aware)
                local nameLength = db.nameTextLength or 0
                if nameLength > 0 and DF:UTF8Len(name) > nameLength then
                    if db.nameTextTruncateMode == "ELLIPSIS" then
                        name = DF:UTF8Sub(name, 1, nameLength) .. "..."
                    else
                        name = DF:UTF8Sub(name, 1, nameLength)
                    end
                end
                frame.nameText:SetText(name)
                frame.nameText:Show()
            end
        end
        if frame.statusText then
            if hideLegacyText or db.statusTextEnabled == false then
                frame.statusText:Hide()
            else
                frame.statusText:SetText(isGhost and L["Ghost"] or L["Dead"])
                frame.statusText:Show()
            end
        end
        if frame.healthText then
            frame.healthText:Hide()
        end
        if frame.dfPowerBar then
            frame.dfPowerBar:Hide()
        end
        if frame.dfAbsorbBar then
            frame.dfAbsorbBar:Hide()
        end
        if frame.dfHealAbsorbBar then
            frame.dfHealAbsorbBar:Hide()
        end
        if frame.dfReducedMaxHealthBar then
            frame.dfReducedMaxHealthBar:Hide()
            if DF.RestoreHealthBarFromReducedMax then DF:RestoreHealthBarFromReducedMax(frame) end
        end

        -- Still update leader and raid target icons (role icons handled separately)
        DF:UpdateLeaderIcon(frame)
        DF:UpdateRaidTargetIcon(frame)
        -- Apply dead fade for dead/ghost units
        DF:ApplyDeadFade(frame, "Dead")
        -- See the note on the offline branch above: this return skips the TD
        -- render and the missing-buff gate, which is why "Dead" never appeared
        -- while the Text Designer owned the text.
        if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "all") end
        if DF.RefreshMissingBuffVisibility then DF:RefreshMissingBuffVisibility(frame) end
        return
    end

    -- Unit is alive and connected - reset dead fade if it was applied
    DF:ResetDeadFade(frame)
    frame.dfLastKnownConnected = true

    -- Clear status text for alive units
    if frame.statusText then
        frame.statusText:SetText("")
        frame.statusText:Hide()
    end

    -- ========================================
    -- HEALTH
    -- ========================================
    if frame.healthBar then
        -- Use helper function that handles CurveConstants fallback
        DF.SetHealthBarValue(frame.healthBar, unit, frame)
        -- Feed the Aura Designer filled health-mirror bar (render-side passthrough only)

        -- Delegate color to ElementAppearance for centralized handling
        -- This prevents conflicts between multiple code paths trying to set color
        DF:UpdateHealthBarAppearance(frame)
    end
    
    -- ========================================
    -- MISSING HEALTH BAR
    -- ========================================
    if frame.missingHealthBar then
        DF.SetMissingHealthBarValue(frame.missingHealthBar, unit, frame)
    end
    
    -- ========================================
    -- BACKGROUND COLOR & TEXTURE
    -- ========================================
    -- Delegate to ElementAppearance for centralized handling
    -- This prevents conflicts between Update.lua, Colors.lua, and Range.lua
    DF:UpdateBackgroundAppearance(frame)

    -- ========================================
    -- NAME
    -- ========================================
    DF:UpdateName(frame)
    
    -- ========================================
    -- HEALTH TEXT
    -- ========================================
    DF:ApplyHealthText(frame, db, hideLegacyText)

    -- ========================================
    -- POWER BAR
    -- ========================================
    local showPower = DF:ShouldShowResourceBar(unit, db)

    -- Health bar positioning (resource bar is floating, doesn't affect health bar size)
    if frame.healthBar then
        local padding = db.framePadding or 0
        frame.healthBar:ClearAllPoints()
        frame.healthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, -padding)
        frame.healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -padding, padding)
        -- Keep the missing-health overlay inside the padding too (anchored once
        -- at creation, so it would otherwise sit over the padding after a change).
        if frame.missingHealthBar then
            frame.missingHealthBar:ClearAllPoints()
            frame.missingHealthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, -padding)
            frame.missingHealthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -padding, padding)
        end
    end
    
    if frame.dfPowerBar then
        if showPower then
            local power = UnitPower(unit)
            local maxPower = UnitPowerMax(unit)

            -- Secret value guard: UnitPowerMax/UnitPower return secret values for arena opponents
            -- SetMinMaxValues cannot handle secret values, so hide the bar when they appear
            if type(power) ~= "number" or type(maxPower) ~= "number" then
                frame.dfPowerBar:Hide()
            else
                frame.dfPowerBar:SetMinMaxValues(0, maxPower)
                frame.dfPowerBar:SetValue(power)

                -- Colour via the shared resolver (resourceBarColorMode: Power /
                -- Class / Custom), so this matches DF:UpdateResourceBar and the
                -- UNIT_DISPLAYPOWER path. The old inline check read only the legacy
                -- resourceBarClassColor boolean, which ignored a "Class" pick made
                -- via the new Color Mode dropdown.
                local cr, cg, cb = DF:GetResourceBarColor(unit, db)
                frame.dfPowerBar:SetStatusBarColor(cr, cg, cb, 1)
                frame.dfPowerBar:Show()
                -- Let the appearance system handle alpha (OOR, dead, element-specific)
                if DF.UpdatePowerBarAppearance then
                    DF:UpdatePowerBarAppearance(frame)
                end
            end
        else
            frame.dfPowerBar:Hide()
        end
    end
    
    -- ========================================
    -- ABSORB BAR
    -- ========================================
    DF:UpdateAbsorb(frame)
    
    -- ========================================
    -- HEAL ABSORB BAR
    -- ========================================
    DF:UpdateHealAbsorb(frame)
    
    -- ========================================
    -- HEAL PREDICTION BAR
    -- ========================================
    DF:UpdateHealPrediction(frame)

    -- ========================================
    -- REDUCED MAX HEALTH BAR
    -- ========================================
    if DF.UpdateReducedMaxHealth then DF:UpdateReducedMaxHealth(frame) end

    -- ========================================
    -- ICONS (Leader and Raid Target only - Role icons updated separately)
    -- ========================================
    -- Note: Role icons are NOT updated here - they are updated only on:
    -- GROUP_ROSTER_UPDATE, PLAYER_REGEN_ENABLED/DISABLED, and settings changes
    -- This prevents role icons from flickering when UnitGroupRolesAssigned
    -- temporarily returns "NONE" during other events
    DF:UpdateLeaderIcon(frame)
    DF:UpdateRaidTargetIcon(frame)
    
    -- ========================================
    -- DISPEL GRADIENT HEALTH UPDATE
    -- ========================================
    -- Update dispel gradient if it's tracking current health
    if DF.UpdateDispelGradientHealth then
        DF:UpdateDispelGradientHealth(frame)
    end
    

    -- ========================================
    -- RANGE CHECK
    -- ========================================
    -- Range checking is handled by Features/Range.lua using SetAlphaFromBoolean
    -- which properly handles "secret" values from UnitInRange() in raid contexts.
    -- See DF:UpdateRange() for the implementation.

    if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "all") end
end

-- ============================================================
-- FAST HEALTH UPDATE (Hot path for UNIT_HEALTH / UNIT_MAXHEALTH)
--
-- Lean update that only touches combat-critical health elements.
-- Called on every UNIT_HEALTH event (highest frequency combat event).
--
-- Includes: health bar, health text, absorbs, heal prediction,
--           missing health bar, dispel gradient, dead/offline guards.
-- Excludes: name text, background, power bar, icons, health bar
--           positioning (handled by full UpdateUnitFrame on unit
--           swap / settings changes / roster events / UNIT_CONNECTION).
-- ============================================================

function DF:UpdateHealthFast(frame)
    if not frame or not frame.unit then return end

    -- Skip test frames entirely — their health comes from UpdateTestFrame
    -- which reads fake data from DF:GetTestUnitData. Includes boss-mode pinned
    -- frames that Test Mode temporarily marks with dfIsTestFrame.
    if frame.dfIsTestFrame then return end

    -- Skip if in test mode (blanket skip for real live frames)
    local isRaidHF = DF:IsRaidFrame(frame)
    if isRaidHF and DF.raidTestMode then return end
    if not isRaidHF and DF.testMode then return end

    local unit = frame.unit
    if not UnitExists(unit) then return end

    local db = DF:GetFrameDB(frame)

    -- TD legacy-text suppression: keep the health bar / absorbs / power
    -- working, but force the text widgets hidden so Phase C live TD
    -- rendering can be tested without visual overlap.
    local hideLegacyText = DF:IsLegacyTextHidden(frame)

    -- ========================================
    -- OFFLINE CHECK
    -- ========================================
    local isConnected = UnitIsConnected(unit)
    if not isConnected then
        if frame.healthBar then
            frame.healthBar:SetMinMaxValues(0, 100)
            frame.healthBar:SetValue(100)
        end
        if frame.statusText then
            if hideLegacyText or db.statusTextEnabled == false then
                frame.statusText:Hide()
            else
                frame.statusText:SetText(L["Offline"])
                frame.statusText:Show()
            end
        end
        if frame.healthText then
            frame.healthText:Hide()
        end
        if frame.dfPowerBar then
            frame.dfPowerBar:Hide()
        end
        if frame.dfAbsorbBar then
            frame.dfAbsorbBar:Hide()
        end
        if frame.dfHealAbsorbBar then
            frame.dfHealAbsorbBar:Hide()
        end
        if frame.dfReducedMaxHealthBar then
            frame.dfReducedMaxHealthBar:Hide()
            if DF.RestoreHealthBarFromReducedMax then DF:RestoreHealthBarFromReducedMax(frame) end
        end
        DF:ApplyDeadFade(frame, "Offline")
        frame.dfLastKnownConnected = false
        -- Same early-return gap as UpdateUnitFrame (see the note there).
        if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "all") end
        if DF.RefreshMissingBuffVisibility then DF:RefreshMissingBuffVisibility(frame) end
        return
    end

    -- ========================================
    -- DEAD/GHOST CHECK
    -- ========================================
    local isDead = UnitIsDead(unit)
    local isGhost = UnitIsGhost(unit)

    if isDead or isGhost then
        if frame.healthBar then
            frame.healthBar:SetMinMaxValues(0, 100)
            frame.healthBar:SetValue(0)
        end
        if frame.statusText then
            if hideLegacyText or db.statusTextEnabled == false then
                frame.statusText:Hide()
            else
                frame.statusText:SetText(isGhost and L["Ghost"] or L["Dead"])
                frame.statusText:Show()
            end
        end
        if frame.healthText then
            frame.healthText:Hide()
        end
        if frame.dfPowerBar then
            frame.dfPowerBar:Hide()
        end
        if frame.dfAbsorbBar then
            frame.dfAbsorbBar:Hide()
        end
        if frame.dfHealAbsorbBar then
            frame.dfHealAbsorbBar:Hide()
        end
        if frame.dfReducedMaxHealthBar then
            frame.dfReducedMaxHealthBar:Hide()
            if DF.RestoreHealthBarFromReducedMax then DF:RestoreHealthBarFromReducedMax(frame) end
        end
        DF:ApplyDeadFade(frame, "Dead")
        -- Clear aura icons on the first dead tick only. WoW doesn't fire
        -- UNIT_AURA on death so the cache stays stale; flushing once is enough.
        -- The edge-detect flag prevents re-running the full AD engine on every
        -- subsequent UNIT_HEALTH tick while the unit stays dead (e.g. wipe spam).
        if not frame.dfLastKnownDead then
            frame.dfLastKnownDead = true
            if DF.UpdateAuras_Enhanced then DF:UpdateAuras_Enhanced(frame) end
        end
        -- Same early-return gap as UpdateUnitFrame. Note the comment above: WoW
        -- does not fire UNIT_AURA on death, which is exactly why the aura-driven
        -- missing-buff gate never re-ran on its own. Both calls are no-ops when
        -- the state is unchanged, so they are safe on this per-tick path.
        if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "all") end
        if DF.RefreshMissingBuffVisibility then DF:RefreshMissingBuffVisibility(frame) end
        return
    end

    -- Unit is alive and connected - reset dead fade if it was applied
    DF:ResetDeadFade(frame)
    frame.dfLastKnownDead = nil
    frame.dfLastKnownConnected = true

    -- Clear resurrection icon if unit was pending a res and is now alive
    if DF.HasPendingResurrection and DF:HasPendingResurrection(unit) then
        DF:UpdateResurrectionIcon(frame)
        -- Refresh auras so transient "Resurrected" buff icon clears
        if DF.UpdateAuras_Enhanced then DF:UpdateAuras_Enhanced(frame) end
    end

    -- Clear status text for alive units
    if frame.statusText then
        frame.statusText:SetText("")
        frame.statusText:Hide()
    end

    -- ========================================
    -- HEALTH BAR
    -- ========================================
    if frame.healthBar then
        DF.SetHealthBarValue(frame.healthBar, unit, frame)
        DF:UpdateHealthBarAppearance(frame)
    end

    -- ========================================
    -- MISSING HEALTH BAR
    -- ========================================
    if frame.missingHealthBar then
        DF.SetMissingHealthBarValue(frame.missingHealthBar, unit, frame)
    end

    -- ========================================
    -- HEALTH TEXT
    -- ========================================
    DF:ApplyHealthText(frame, db, hideLegacyText)

    -- ========================================
    -- ABSORB / HEAL ABSORB / HEAL PREDICTION
    -- ========================================
    -- These have their own dedicated events (UNIT_ABSORB_AMOUNT_CHANGED,
    -- UNIT_HEAL_ABSORB_AMOUNT_CHANGED, UNIT_HEAL_PREDICTION) that handle
    -- value changes. In ATTACHED/OVERLAY mode, bars anchor to the health fill
    -- texture edge, so position auto-updates when health changes.
    --
    -- EXCEPTION: ATTACHED mode with clamp (absorbBarAttachedClampMode > 0)
    -- clamps the displayed absorb to missing health, so health changes affect
    -- the clamped value even when absorb amount is unchanged.
    local absorbMode = db.absorbBarMode or "OVERLAY"
    if (absorbMode == "ATTACHED" or absorbMode == "ATTACHED_OVERFLOW") and (db.absorbBarAttachedClampMode or 1) > 0 then
        DF:UpdateAbsorb(frame)
    end

    -- Heal prediction is health-dependent for the same reason: the calculator
    -- clamps incoming heals to missing/max health, so the displayed amount
    -- changes as current health changes even with no new heal event. Refresh
    -- only when a bar is actively shown so idle frames (the common case — no
    -- incoming heals) cost just a single IsShown() check, not a full update.
    if frame.dfHealPredictionBar and frame.dfHealPredictionBar:IsShown() then
        DF:UpdateHealPrediction(frame)
    end

    -- ========================================
    -- REDUCED MAX HEALTH BAR
    -- ========================================
    -- Re-check on UNIT_HEALTH so dead→alive transitions re-evaluate the bar
    -- (UNIT_MAX_HEALTH_MODIFIERS_CHANGED doesn't refire on resurrect).
    if DF.UpdateReducedMaxHealth then DF:UpdateReducedMaxHealth(frame) end

    -- ========================================
    -- DISPEL GRADIENT HEALTH
    -- ========================================
    if DF.UpdateDispelGradientHealth then
        DF:UpdateDispelGradientHealth(frame)
    end
    
    -- NOTE: the TextDesigner "health" refresh is driven from the central
    -- event dispatcher (Frames/Headers.lua), not here. UpdateHealthFast has
    -- fast-path early returns (e.g. lines ~1024/1071) that a tail hook would
    -- miss, leaving text stale in the common in-combat case.
end

-- ============================================================
-- LEGACY FRAME CREATION (for backwards compatibility)
-- These now just call the unified CreateUnitFrame
-- ============================================================

-- ============================================================
-- DEDICATED POWER BAR UPDATE
-- ============================================================
-- Separate function for power bar updates, can be called independently
-- This is useful for combat reload when UnitExists may return false initially

function DF:UpdatePower(frame)
    if not frame or not frame.unit then return end
    if not frame.dfPowerBar then return end
    
    local unit = frame.unit
    local db = DF:GetFrameDB(frame)
    
    -- Check if power bar should be shown (uses centralized role filter)
    local showPower = DF:ShouldShowResourceBar(unit, db)

    if not showPower then
        frame.dfPowerBar:Hide()
        return
    end
    
    -- Only update if unit exists
    if not UnitExists(unit) then return end
    
    local power = UnitPower(unit)
    local maxPower = UnitPowerMax(unit)

    -- Secret value guard: UnitPowerMax/UnitPower return secret values for arena opponents
    -- SetMinMaxValues cannot handle secret values, so hide the bar when they appear
    if type(power) ~= "number" or type(maxPower) ~= "number" then
        frame.dfPowerBar:Hide()
        return
    end

    frame.dfPowerBar:SetMinMaxValues(0, maxPower)
    frame.dfPowerBar:SetValue(power)

    -- Update colour via the shared resolver so the UNIT_DISPLAYPOWER / shapeshift
    -- path honours resourceBarColorMode (Power / Class / Custom), not just the
    -- legacy resourceBarClassColor boolean. Previously a shapeshift fired this
    -- handler and reverted a "Class" bar back to power colour, because the inline
    -- legacy check didn't see a "Class" pick made via the new Color Mode dropdown.
    local cr, cg, cb = DF:GetResourceBarColor(unit, db)
    frame.dfPowerBar:SetStatusBarColor(cr, cg, cb, 1)
    frame.dfPowerBar:Show()
end

-- UPDATE FUNCTIONS
-- ============================================================

function DF:UpdateFrame(frame)
    if not DF.initialized then return end
    if not frame or not frame.unit then return end
    
    -- For party frames, use the unified update
    if not frame.isRaidFrame then
        DF:UpdateUnitFrame(frame)
        -- Also call aura update and other party-specific updates
        DF:UpdateAuras(frame)
        DF:UpdateReadyCheckIcon(frame)
        DF:UpdateCenterStatusIcon(frame)
        -- Explicit power bar update (in case UpdateUnitFrame early-exited)
        if DF.UpdatePower then
            DF:UpdatePower(frame)
        end
    end
end

-- (Removed 2026-08-04) DF:UpdateHealth -- 142 lines, ZERO callers anywhere in either
-- addon: only its own definition, a Profiler wrap-array string and two comments that
-- named it as the health driver. The live driver is DF:UpdateHealthFast, dispatched
-- from Frames/Headers.lua. It also owned two of the four (now removed) health-mirror
-- feed calls, which made the mirror look better wired than it was.

-- ============================================================
-- Apply all visual styles to a frame (called when settings change).
-- A thin alias for ApplyFrameLayout, and the name most call sites use — 14 of them
-- across Core, Init, PinnedFrames, TestFramePool and TestMode. It carried a
-- "DEPRECATED - use ApplyFrameLayout instead" label that was simply untrue.
function DF:ApplyFrameStyle(frame)
    if not frame then return end
    DF:ApplyFrameLayout(frame)
end

-- ============================================================
-- REFRESH ALL FONTS
-- ============================================================
-- Lightweight function to re-apply fonts to all frames
-- Called at PLAYER_LOGIN to ensure fonts are properly initialized
-- (during combat reload, fonts may not be fully available at ADDON_LOADED)

local function RefreshFrameFonts(frame, db)
    if not frame or not db then return end

    -- Name text
    if frame.nameText then
        local nameFont = db.nameFont or "Fonts\\FRIZQT__.TTF"
        local nameFontSize = db.nameFontSize or 11
        local nameOutline = db.nameTextOutline or "OUTLINE"
        if nameOutline == "NONE" then nameOutline = "" end
        DF:SafeSetFont(frame.nameText, nameFont, nameFontSize, nameOutline)
    end
    
    -- Health text
    if frame.healthText then
        local healthFont = db.healthFont or "Fonts\\FRIZQT__.TTF"
        local healthFontSize = db.healthFontSize or 10
        local healthOutline = db.healthTextOutline or "OUTLINE"
        if healthOutline == "NONE" then healthOutline = "" end
        DF:SafeSetFont(frame.healthText, healthFont, healthFontSize, healthOutline)
    end
    
    -- Status text
    if frame.statusText then
        local statusFont = db.statusTextFont or "Fonts\\FRIZQT__.TTF"
        local statusFontSize = db.statusTextFontSize or 10
        local statusOutline = db.statusTextOutline or "OUTLINE"
        if statusOutline == "NONE" then statusOutline = "" end
        DF:SafeSetFont(frame.statusText, statusFont, statusFontSize, statusOutline)
    end
end

-- Exposed so the pinned-frame pool (Features/PinnedFrames.lua) can re-font itself
-- on a global font/shadow change — RefreshAllFonts' iterators don't reach it.
DF.RefreshFrameFonts = RefreshFrameFonts

function DF:RefreshAllFonts()
    local partyDb = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    -- Refresh party frames via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(function(frame)
            RefreshFrameFonts(frame, partyDb)
        end)
    end
    
    -- Refresh raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(frame)
            RefreshFrameFonts(frame, raidDb)
        end)
    end
    
    -- Refresh pet frames (use pet-specific font keys, not main frame keys)
    local function RefreshPetFonts(frame, db)
        if not frame then return end
        if frame.nameText then
            local nameFont = db.petNameFont or "Fonts\\FRIZQT__.TTF"
            local nameFontSize = db.petNameFontSize or 9
            local nameFontOutline = db.petNameFontOutline or "OUTLINE"
            if nameFontOutline == "NONE" then nameFontOutline = "" end
            DF:SafeSetFont(frame.nameText, nameFont, nameFontSize, nameFontOutline)
        end
        if frame.healthText then
            local healthFont = db.petHealthFont or "Fonts\\ARIALN.TTF"
            local healthFontSize = db.petHealthFontSize or 8
            local healthFontOutline = db.petHealthFontOutline or "OUTLINE"
            if healthFontOutline == "NONE" then healthFontOutline = "" end
            DF:SafeSetFont(frame.healthText, healthFont, healthFontSize, healthFontOutline)
        end
    end

    -- Refresh live pet frames
    if DF.petFrames and DF.petFrames.player then
        RefreshPetFonts(DF.petFrames.player, partyDb)
    end

    if DF.partyPetFrames then
        for _, frame in pairs(DF.partyPetFrames) do
            RefreshPetFonts(frame, partyDb)
        end
    end

    if DF.raidPetFrames then
        for _, frame in pairs(DF.raidPetFrames) do
            RefreshPetFonts(frame, raidDb)
        end
    end

    -- Refresh test pet frames (these exist when in test mode)
    if DF.testMode and DF.testPetFrames then
        for i = 0, 4 do
            RefreshPetFonts(DF.testPetFrames[i], partyDb)
        end
    end

    if DF.raidTestMode and DF.testRaidPetFrames then
        for i = 1, 40 do
            RefreshPetFonts(DF.testRaidPetFrames[i], raidDb)
        end
    end

    -- Also refresh test party/raid frames for main frame fonts
    if DF.testMode and DF.testPartyFrames then
        for i = 0, 4 do
            if DF.testPartyFrames[i] then
                RefreshFrameFonts(DF.testPartyFrames[i], partyDb)
            end
        end
    end

    if DF.raidTestMode and DF.testRaidFrames then
        for i = 1, 40 do
            if DF.testRaidFrames[i] then
                RefreshFrameFonts(DF.testRaidFrames[i], raidDb)
            end
        end
    end

    -- Pinned frames keep their own pool (live boss/header + non-secure test pool)
    -- which none of the iterators above reach.
    if DF.RefreshPinnedFonts then DF:RefreshPinnedFonts() end
end