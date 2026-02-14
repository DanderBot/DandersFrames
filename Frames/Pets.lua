local addonName, DF = ...

-- ============================================================
-- PET FRAMES MODULE
-- Handles creation, positioning, and updates for pet frames
-- ============================================================

-- Storage for pet frames
DF.petFrames = DF.petFrames or {}
DF.partyPetFrames = DF.partyPetFrames or {}
DF.raidPetFrames = DF.raidPetFrames or {}

-- ============================================================
-- PET FRAME CREATION
-- ============================================================

function DF:CreatePetFrame(unit, ownerFrame, isRaid)
    local db = isRaid and DF:GetRaidDB() or DF:GetDB()
    local parent = ownerFrame or (isRaid and DF.raidContainer or DF.container)
    
    -- Generate frame name based on unit
    local frameName = "DandersFrames_Pet_" .. unit:gsub("pet", "Pet")
    
    local frame = CreateFrame("Button", frameName, parent, "SecureUnitButtonTemplate")
    frame:SetSize(db.petFrameWidth or 80, db.petFrameHeight or 20)
    frame.unit = unit
    frame.ownerFrame = ownerFrame
    frame.isPetFrame = true
    frame.isRaidFrame = isRaid
    frame.dfIsDandersFrame = true  -- Mark as DandersFrames frame for click casting module
    
    -- Register unit attribute
    frame:SetAttribute("unit", unit)
    -- Note: type1/type2 are set by click-casting module (or RestoreBlizzardDefaults when disabled)
    
    -- Background
    frame.background = frame:CreateTexture(nil, "BACKGROUND")
    frame.background:SetAllPoints()
    frame.background:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    
    -- Health bar
    frame.healthBar = CreateFrame("StatusBar", nil, frame)
    frame.healthBar:SetAllPoints()
    frame.healthBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    frame.healthBar:SetMinMaxValues(0, 100)
    frame.healthBar:SetValue(100)
    frame.healthBar:SetStatusBarColor(0, 0.8, 0)
    
    -- Health bar background (for deficit)
    frame.healthBar.bg = frame.healthBar:CreateTexture(nil, "BACKGROUND")
    frame.healthBar.bg:SetAllPoints()
    frame.healthBar.bg:SetColorTexture(0.2, 0.2, 0.2, 0.8)
    
    -- Border
    frame.border = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.border:SetPoint("TOPLEFT", -1, 1)
    frame.border:SetPoint("BOTTOMRIGHT", 1, -1)
    frame.border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame.border:SetBackdropBorderColor(0, 0, 0, 1)
    
    -- Name text
    frame.nameText = frame.healthBar:CreateFontString(nil, "OVERLAY")
    frame.nameText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")  -- Default font, updated by UpdatePetFrameAppearance
    frame.nameText:SetPoint("CENTER", 0, 0)
    frame.nameText:SetTextColor(1, 1, 1)
    frame.nameText:SetText("")
    
    -- Health text (optional, can be toggled)
    frame.healthText = frame.healthBar:CreateFontString(nil, "OVERLAY")
    frame.healthText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")  -- Default font, updated by UpdatePetFrameAppearance
    frame.healthText:SetPoint("RIGHT", -2, 0)
    frame.healthText:SetTextColor(1, 1, 1)
    frame.healthText:SetText("")
    frame.healthText:Hide()
    
    -- Store owner unit for death checking
    local ownerUnit = unit:gsub("pet", "")
    if ownerUnit == "" then ownerUnit = "player" end
    frame.ownerUnit = ownerUnit
    
    -- Register events for this pet frame
    frame:SetScript("OnEvent", function(self, event, ...)
        DF:OnPetFrameEvent(self, event, ...)
    end)
    
    -- PERFORMANCE FIX 2025-01-20: Use RegisterUnitEvent for C++ level filtering
    -- Pet frames need to listen to both the pet unit AND the owner unit:
    -- - Pet unit: for health, name updates
    -- - Owner unit: for death detection (hide pet when owner dies) and UNIT_PET
    frame:RegisterUnitEvent("UNIT_HEALTH", unit, ownerUnit)  -- Need both pet and owner
    frame:RegisterUnitEvent("UNIT_MAXHEALTH", unit)          -- Pet only
    frame:RegisterUnitEvent("UNIT_NAME_UPDATE", unit)        -- Pet only
    frame:RegisterUnitEvent("UNIT_FLAGS", unit, ownerUnit)   -- Need both (death detection)
    frame:RegisterUnitEvent("UNIT_PET", ownerUnit)           -- Fires on owner when pet changes
    
    --[[ OLD CODE - Remove after testing (was causing event flooding in cities)
    frame:RegisterEvent("UNIT_HEALTH")
    frame:RegisterEvent("UNIT_MAXHEALTH")
    frame:RegisterEvent("UNIT_NAME_UPDATE")
    frame:RegisterEvent("UNIT_FLAGS")  -- For detecting death
    frame:RegisterEvent("UNIT_PET")    -- For detecting pet summon/dismiss
    --]]
    
    -- Mouse interaction - use HookScript to not interfere with other handlers
    frame:HookScript("OnEnter", function(self)
        if db.tooltipFrameEnabled then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetUnit(self.unit)
            GameTooltip:Show()
        end
    end)
    
    frame:HookScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
    
    -- Ping support
    DF:RegisterFrameForPing(frame)
    
    -- Register with external click-casting addons (Clique, Clicked, etc.)
    if ClickCastFrames then
        ClickCastFrames[frame] = true
    end
    
    -- Initial hide - will be shown when pet exists
    frame:Hide()
    
    return frame
end

-- ============================================================
-- PET FRAME EVENTS
-- ============================================================

function DF:OnPetFrameEvent(frame, event, unit, ...)
    -- Handle UNIT_PET event (fires on owner unit when pet changes)
    if event == "UNIT_PET" then
        if unit == frame.ownerUnit then
            -- Owner's pet changed - update visibility
            if UnitExists(frame.unit) and not UnitIsDeadOrGhost(frame.ownerUnit) then
                DF:SetPetFrameVisible(frame, true)
                DF:UpdatePetHealth(frame)
                DF:UpdatePetName(frame)
            else
                DF:SetPetFrameVisible(frame, false)
            end
        end
        return
    end
    
    -- Check for owner unit events (for death detection)
    if unit == frame.ownerUnit then
        if event == "UNIT_HEALTH" or event == "UNIT_FLAGS" then
            -- Check if owner died - hide pet frame
            if UnitIsDeadOrGhost(frame.ownerUnit) then
                DF:SetPetFrameVisible(frame, false)
            else
                -- Owner alive, check if pet exists
                if UnitExists(frame.unit) then
                    DF:SetPetFrameVisible(frame, true)
                    DF:UpdatePetHealth(frame)
                end
            end
        end
        return
    end
    
    -- Handle pet unit events
    if unit ~= frame.unit then return end
    
    if event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        DF:UpdatePetHealth(frame)
    elseif event == "UNIT_NAME_UPDATE" then
        DF:UpdatePetName(frame)
    elseif event == "UNIT_FLAGS" then
        -- Pet may have been dismissed or died
        if not UnitExists(frame.unit) then
            DF:SetPetFrameVisible(frame, false)
        end
    end
end

-- ============================================================
-- PET FRAME UPDATES
-- ============================================================

-- Helper to set pet frame visibility (uses SetAlpha to work in combat)
-- Note: When showing, we don't set alpha to 1 because range fading may need a different alpha
function DF:SetPetFrameVisible(frame, visible)
    if not frame then return end
    
    if visible then
        -- Mark as visible - range system will set appropriate alpha
        frame.dfPetHidden = false
        -- Set to 1 so range system can take over (don't compare current alpha - it may be secret)
        frame:SetAlpha(1)
        -- Also try to show if not in combat (for proper click targeting)
        if not InCombatLockdown() then
            frame:Show()
        end
    else
        -- Mark as hidden and set alpha to 0
        frame.dfPetHidden = true
        frame:SetAlpha(0)
        -- Also try to hide if not in combat
        if not InCombatLockdown() then
            frame:Hide()
        end
    end
end

function DF:UpdatePetHealth(frame)
    if not frame or not frame.unit then return end
    
    local unit = frame.unit
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    
    -- Check if pet exists
    if not UnitExists(unit) then 
        DF:SetPetFrameVisible(frame, false)
        return 
    end
    
    -- Check if owner is dead - hide pet frame if so
    local ownerUnit = unit:gsub("pet", "")
    if ownerUnit == "" then ownerUnit = "player" end
    if UnitIsDeadOrGhost(ownerUnit) then
        DF:SetPetFrameVisible(frame, false)
        return
    end
    
    -- Pet exists and owner is alive - show frame
    DF:SetPetFrameVisible(frame, true)
    
    -- Use the safe SetHealthBarValue function which handles secrets properly
    DF.SetHealthBarValue(frame.healthBar, unit, frame)
    
    -- Update health text if shown
    -- Pass secret value directly to SetFormattedText - it handles secrets internally
    if db.petShowHealthText and frame.healthText then
        local success = pcall(function()
            local pct = DF.GetSafeHealthPercent(unit)
            frame.healthText:SetFormattedText("%.0f%%", pct)
        end)
        if not success then
            frame.healthText:SetText("")
        end
        frame.healthText:Show()
    elseif frame.healthText then
        frame.healthText:Hide()
    end
    
    -- Color health bar based on settings
    if db.petHealthColorMode == "CLASS" then
        -- Try to get pet owner's class color
        local _, class = UnitClass(ownerUnit)
        if class then
            local color = DF:GetClassColor(class)
            if color then
                frame.healthBar:SetStatusBarColor(color.r, color.g, color.b)
                return
            end
        end
    elseif db.petHealthColorMode == "HEALTH" then
        -- Use gradient curve to get color based on health percentage
        -- UnitHealthPercent with a color curve returns the color directly
        local curve = DF:GetPetHealthGradientCurve()
        if curve then
            local success = pcall(function()
                local color = UnitHealthPercent(unit, true, curve)
                if color and color.GetRGB then
                    local tex = frame.healthBar:GetStatusBarTexture()
                    if tex then
                        tex:SetVertexColor(color:GetRGB())
                    end
                end
            end)
            if success then
                return
            end
        end
        -- Fallback if curve not available or failed - just use green
        frame.healthBar:SetStatusBarColor(0, 0.8, 0)
        return
    elseif db.petHealthColorMode == "CUSTOM" then
        local c = db.petHealthColor or {r = 0, g = 0.8, b = 0}
        frame.healthBar:SetStatusBarColor(c.r, c.g, c.b)
        return
    end
    
    -- Default green
    frame.healthBar:SetStatusBarColor(0, 0.8, 0)
end

-- Get or create a health gradient curve for pet frames
function DF:GetPetHealthGradientCurve()
    if not DF.petHealthCurve then
        -- Create a simple red-yellow-green gradient curve using C_CurveUtil
        if C_CurveUtil and C_CurveUtil.CreateColorCurve then
            local curve = C_CurveUtil.CreateColorCurve()
            curve:SetType(Enum.LuaCurveType.Linear)
            
            -- Add color points: red at 0%, yellow at 50%, green at 100%
            local red = CreateColor(1, 0, 0, 1)
            local yellow = CreateColor(1, 0.8, 0, 1)
            local green = CreateColor(0, 0.8, 0, 1)
            
            curve:AddPoint(0, red)
            curve:AddPoint(0.5, yellow)
            curve:AddPoint(1, green)
            
            DF.petHealthCurve = curve
        end
    end
    return DF.petHealthCurve
end

-- Apply visual styling to pet frame
function DF:ApplyPetFrameStyle(frame)
    if not frame then return end
    
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    
    -- Calculate size - optionally match owner's dimensions (only in ATTACHED mode)
    local width = db.petFrameWidth or 80
    local height = db.petFrameHeight or 20
    
    -- Match Owner Width/Height only applies in ATTACHED mode, not GROUPED mode
    local isGroupedMode = db.petGroupMode == "GROUPED"
    
    if not isGroupedMode and frame.ownerFrame then
        if db.petMatchOwnerWidth then
            width = frame.ownerFrame:GetWidth()
        end
        if db.petMatchOwnerHeight then
            height = frame.ownerFrame:GetHeight()
        end
    end
    
    frame:SetSize(width, height)
    
    -- Update health bar texture - use path directly (dropdown saves paths)
    local texture = db.petTexture or "Interface\\TargetingFrame\\UI-StatusBar"
    frame.healthBar:SetStatusBarTexture(texture)
    frame.healthBar.bg:SetTexture(texture)
    
    -- Background color
    local bgColor = db.petBackgroundColor or {r = 0.1, g = 0.1, b = 0.1, a = 0.8}
    frame.background:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)
    
    -- Health bar background color
    local healthBgColor = db.petHealthBgColor or {r = 0.2, g = 0.2, b = 0.2, a = 0.8}
    frame.healthBar.bg:SetVertexColor(healthBgColor.r, healthBgColor.g, healthBgColor.b, healthBgColor.a or 0.8)
    
    -- Border
    if db.petShowBorder then
        local borderColor = db.petBorderColor or {r = 0, g = 0, b = 0, a = 1}
        frame.border:SetBackdropBorderColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
        frame.border:Show()
    else
        frame.border:Hide()
    end
    
    -- Name text styling - use SafeSetFont like main frames
    local nameFont = db.petNameFont or "Fonts\\FRIZQT__.TTF"
    local nameFontSize = db.petNameFontSize or 9
    local nameFontOutline = db.petNameFontOutline or "OUTLINE"
    DF:SafeSetFont(frame.nameText, nameFont, nameFontSize, nameFontOutline)
    
    -- Name text position
    frame.nameText:ClearAllPoints()
    local nameAnchor = db.petNameAnchor or "CENTER"
    local nameX = db.petNameX or 0
    local nameY = db.petNameY or 0
    frame.nameText:SetPoint(nameAnchor, frame.healthBar, nameAnchor, nameX, nameY)
    
    -- Name text color
    local nameColor = db.petNameColor or {r = 1, g = 1, b = 1}
    frame.nameText:SetTextColor(nameColor.r, nameColor.g, nameColor.b)
    
    -- Health text styling
    if frame.healthText then
        local healthFont = db.petHealthFont or "Fonts\\ARIALN.TTF"
        local healthFontSize = db.petHealthFontSize or 8
        local healthFontOutline = db.petHealthFontOutline or "OUTLINE"
        DF:SafeSetFont(frame.healthText, healthFont, healthFontSize, healthFontOutline)
        
        -- Health text position
        frame.healthText:ClearAllPoints()
        local healthAnchor = db.petHealthAnchor or "RIGHT"
        local healthX = db.petHealthX or -2
        local healthY = db.petHealthY or 0
        frame.healthText:SetPoint(healthAnchor, frame.healthBar, healthAnchor, healthX, healthY)
        
        -- Health text color
        local healthColor = db.petHealthTextColor or {r = 1, g = 1, b = 1}
        frame.healthText:SetTextColor(healthColor.r, healthColor.g, healthColor.b)
    end
end

function DF:UpdatePetName(frame)
    if not frame or not frame.unit then return end
    if not UnitExists(frame.unit) then return end
    
    local name = UnitName(frame.unit)
    if name then
        -- Truncate long names
        local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
        local maxLen = db.petNameMaxLength or 12
        if #name > maxLen then
            name = name:sub(1, maxLen) .. "..."
        end
        frame.nameText:SetText(name)
    end
end

function DF:UpdatePetFrame(frame)
    if not frame then return end
    
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    
    -- Check if owner is dead - hide pet frame if so
    local ownerUnit = frame.unit:gsub("pet", "")
    if ownerUnit == "" then ownerUnit = "player" end
    
    -- Test mode handling
    local isInTestMode = (frame.isRaidFrame and DF.raidTestMode) or (not frame.isRaidFrame and DF.testMode)
    
    if isInTestMode then
        -- Check if pets should be shown in test mode
        if db.testShowPets == false then
            DF:SetPetFrameVisible(frame, false)
            return
        end
        -- In test mode, show pet frames with fake data
        DF:ApplyPetFrameStyle(frame)
        DF:UpdatePetFrameTestMode(frame)
        DF:SetPetFrameVisible(frame, true)
        return
    end
    
    -- Update visibility and data
    if UnitExists(frame.unit) and not UnitIsDeadOrGhost(ownerUnit) then
        -- Apply visual styling
        DF:ApplyPetFrameStyle(frame)
        -- Update health and name
        DF:UpdatePetHealth(frame)
        DF:UpdatePetName(frame)
        DF:SetPetFrameVisible(frame, true)
    else
        DF:SetPetFrameVisible(frame, false)
    end
end

-- Update pet frame with test mode fake data
function DF:UpdatePetFrameTestMode(frame)
    if not frame then return end
    
    -- Set fake name
    local petNames = {"Wolf", "Cat", "Bear", "Imp", "Voidwalker", "Felguard", "Water Elemental", "Ghoul", "Treant", "Earth Elemental"}
    local index = 1
    if frame.unit:match("partypet(%d+)") then
        index = tonumber(frame.unit:match("partypet(%d+)")) or 1
    elseif frame.unit:match("raidpet(%d+)") then
        index = tonumber(frame.unit:match("raidpet(%d+)")) or 1
    end
    local name = petNames[((index - 1) % #petNames) + 1]
    frame.nameText:SetText(name)
    
    -- Set fake health (random between 60-100%)
    local healthPercent = 0.6 + (math.random() * 0.4)
    frame.healthBar:SetMinMaxValues(0, 1)
    frame.healthBar:SetValue(healthPercent)
    
    -- Set health bar color (green)
    frame.healthBar:SetStatusBarColor(0.2, 0.8, 0.2)
    
    -- Update health text if shown
    if frame.healthText then
        local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
        if db.petShowHealth then
            local maxHealth = 50000
            local currentHealth = math.floor(maxHealth * healthPercent)
            frame.healthText:SetText(string.format("%d%%", math.floor(healthPercent * 100)))
            frame.healthText:Show()
        else
            frame.healthText:Hide()
        end
    end
end

-- Lightweight update for live slider preview (no full rebuild)
function DF:LightweightUpdatePetFrames()
    -- Update player pet
    if DF.petFrames.player then
        DF:ApplyPetFrameStyle(DF.petFrames.player)
        DF:PositionPetFrame(DF.petFrames.player)
    end
    
    -- Update party pets
    for i = 1, 4 do
        if DF.partyPetFrames[i] then
            DF:ApplyPetFrameStyle(DF.partyPetFrames[i])
            DF:PositionPetFrame(DF.partyPetFrames[i])
        end
    end
    
    -- Update raid pets
    for i = 1, 40 do
        if DF.raidPetFrames[i] then
            DF:ApplyPetFrameStyle(DF.raidPetFrames[i])
            DF:PositionPetFrame(DF.raidPetFrames[i])
        end
    end
end

-- ============================================================
-- PET FRAME POSITIONING
-- ============================================================

function DF:PositionPetFrame(frame)
    if not frame then return end
    
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    
    -- Check if we're using grouped mode
    if db.petGroupMode == "GROUPED" then
        -- In grouped mode, positioning is handled by UpdatePetGroupLayout
        return
    end
    
    -- ATTACHED mode - position relative to owner
    if not frame.ownerFrame then return end
    
    local anchor = db.petAnchor or "BOTTOM"
    local offsetX = db.petOffsetX or 0
    local offsetY = db.petOffsetY or -2
    
    frame:ClearAllPoints()
    frame:SetParent(frame.ownerFrame:GetParent())
    
    if anchor == "BOTTOM" then
        frame:SetPoint("TOP", frame.ownerFrame, "BOTTOM", offsetX, offsetY)
    elseif anchor == "TOP" then
        frame:SetPoint("BOTTOM", frame.ownerFrame, "TOP", offsetX, -offsetY)
    elseif anchor == "LEFT" then
        frame:SetPoint("RIGHT", frame.ownerFrame, "LEFT", offsetX, offsetY)
    elseif anchor == "RIGHT" then
        frame:SetPoint("LEFT", frame.ownerFrame, "RIGHT", -offsetX, offsetY)
    end
end

-- ============================================================
-- PET GROUP CONTAINER (Party Mode)
-- ============================================================

function DF:CreatePetGroupContainer()
    if DF.petGroupContainer then return DF.petGroupContainer end
    
    local container = CreateFrame("Frame", "DandersFrames_PetGroupContainer", UIParent)
    container:SetSize(200, 50)
    container:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    container:Hide()
    
    DF.petGroupContainer = container
    return container
end

function DF:UpdatePetGroupLayout()
    local db = DF:GetDB()
    
    -- Only use group layout if in GROUPED mode and pets are enabled
    if db.petGroupMode ~= "GROUPED" or not db.petEnabled then
        -- Hide pet group container if it exists
        if DF.petGroupContainer then
            DF.petGroupContainer:Hide()
        end
        return
    end
    
    -- Create container if needed
    if not DF.petGroupContainer then
        DF:CreatePetGroupContainer()
    end
    
    local container = DF.petGroupContainer
    local partyContainer = DF.container
    
    if not partyContainer then return end
    
    -- Collect visible pet frames
    local petFrames = {}
    
    -- In test mode, show all pet frames based on testFrameCount
    local isTestMode = DF.testMode
    
    if isTestMode then
        if db.testShowPets == false then
            container:Hide()
            return
        end
        local testFrameCount = db.testFrameCount or 5
        if testFrameCount >= 1 and DF.petFrames.player then
            table.insert(petFrames, DF.petFrames.player)
        end
        for i = 1, 4 do
            if (i + 1) <= testFrameCount and DF.partyPetFrames[i] then
                table.insert(petFrames, DF.partyPetFrames[i])
            end
        end
    else
        -- Normal mode - check which pets actually exist
        if DF.petFrames.player and UnitExists("pet") then
            table.insert(petFrames, DF.petFrames.player)
        end
        for i = 1, 4 do
            if DF.partyPetFrames[i] and UnitExists("partypet" .. i) then
                table.insert(petFrames, DF.partyPetFrames[i])
            end
        end
    end
    
    if #petFrames == 0 then
        container:Hide()
        return
    end
    
    -- Get settings
    local growth = db.petGroupGrowth or "HORIZONTAL"
    local spacing = db.petGroupSpacing or 2
    local anchor = db.petGroupAnchor or "BOTTOM"
    local offsetX = db.petGroupOffsetX or 0
    local offsetY = db.petGroupOffsetY or -5
    
    -- Calculate container size using pet frame dimensions
    -- Note: Match Owner Width/Height only applies to ATTACHED mode, not GROUPED mode
    local petWidth = db.petFrameWidth or 80
    local petHeight = db.petFrameHeight or 18
    
    local containerWidth, containerHeight
    
    if growth == "HORIZONTAL" then
        containerWidth = (#petFrames * petWidth) + ((#petFrames - 1) * spacing)
        containerHeight = petHeight
    else
        containerWidth = petWidth
        containerHeight = (#petFrames * petHeight) + ((#petFrames - 1) * spacing)
    end
    
    container:SetSize(containerWidth, containerHeight)
    
    -- Calculate the actual center of visible party frames
    local visibleFrames = {}
    local testFrameCount = db.testFrameCount or 5
    
    -- Collect visible party frames via iterator
    if DF.IteratePartyFrames then
        local frameIdx = 0
        DF:IteratePartyFrames(function(frame)
            frameIdx = frameIdx + 1
            if frame and frame:IsShown() then
                if DF.testMode then
                    -- In test mode, only use frames up to testFrameCount
                    if frameIdx <= testFrameCount then
                        table.insert(visibleFrames, frame)
                    end
                else
                    -- Normal mode
                    table.insert(visibleFrames, frame)
                end
            end
        end)
    end
    
    -- Position container relative to party frames
    container:ClearAllPoints()
    
    if #visibleFrames > 0 then
        local partyGrowth = db.growDirection or "HORIZONTAL"
        
        -- Find the actual bounds of all visible party frames using GetRect
        -- This handles frame sorting correctly - find actual leftmost/rightmost frames
        local minX, maxX, minY, maxY
        local leftmostFrame, rightmostFrame, topmostFrame, bottommostFrame
        
        for _, frame in ipairs(visibleFrames) do
            local left, bottom, width, height = frame:GetRect()
            if left and bottom and width and height then
                local right = left + width
                local top = bottom + height
                
                if not minX or left < minX then 
                    minX = left 
                    leftmostFrame = frame
                end
                if not maxX or right > maxX then 
                    maxX = right 
                    rightmostFrame = frame
                end
                if not minY or bottom < minY then 
                    minY = bottom 
                    bottommostFrame = frame
                end
                if not maxY or top > maxY then 
                    maxY = top 
                    topmostFrame = frame
                end
            end
        end
        
        if minX and maxX and minY and maxY and leftmostFrame then
            local totalPartyWidth = maxX - minX
            local totalPartyHeight = maxY - minY
            
            -- Calculate centering offset
            local centerOffsetX = (totalPartyWidth - containerWidth) / 2
            local centerOffsetY = (totalPartyHeight - containerHeight) / 2
            
            -- Position based on anchor - use the appropriate edge frame
            if anchor == "BOTTOM" then
                if partyGrowth == "HORIZONTAL" then
                    container:SetPoint("TOPLEFT", leftmostFrame, "BOTTOMLEFT", centerOffsetX + offsetX, offsetY)
                else
                    container:SetPoint("TOP", bottommostFrame, "BOTTOM", offsetX, offsetY)
                end
            elseif anchor == "TOP" then
                if partyGrowth == "HORIZONTAL" then
                    container:SetPoint("BOTTOMLEFT", leftmostFrame, "TOPLEFT", centerOffsetX + offsetX, -offsetY)
                else
                    container:SetPoint("BOTTOM", topmostFrame, "TOP", offsetX, -offsetY)
                end
            elseif anchor == "LEFT" then
                if partyGrowth == "HORIZONTAL" then
                    container:SetPoint("RIGHT", leftmostFrame, "LEFT", offsetX, offsetY)
                else
                    container:SetPoint("TOPRIGHT", topmostFrame, "TOPLEFT", offsetX, -centerOffsetY + offsetY)
                end
            elseif anchor == "RIGHT" then
                if partyGrowth == "HORIZONTAL" then
                    container:SetPoint("LEFT", rightmostFrame, "RIGHT", -offsetX, offsetY)
                else
                    container:SetPoint("TOPLEFT", bottommostFrame, "TOPRIGHT", -offsetX, -centerOffsetY + offsetY)
                end
            end
            
            container:Show()
            
            -- Position pet frames within container
            for i, frame in ipairs(petFrames) do
                frame:ClearAllPoints()
                frame:SetParent(container)
                
                if i == 1 then
                    if growth == "HORIZONTAL" then
                        frame:SetPoint("LEFT", container, "LEFT", 0, 0)
                    else
                        frame:SetPoint("TOP", container, "TOP", 0, 0)
                    end
                else
                    local prevFrame = petFrames[i - 1]
                    if growth == "HORIZONTAL" then
                        frame:SetPoint("LEFT", prevFrame, "RIGHT", spacing, 0)
                    else
                        frame:SetPoint("TOP", prevFrame, "BOTTOM", 0, -spacing)
                    end
                end
            end
            return
        end
    end
    
    -- Fallback: use party container directly
    if anchor == "BOTTOM" then
        container:SetPoint("TOP", partyContainer, "BOTTOM", offsetX, offsetY)
    elseif anchor == "TOP" then
        container:SetPoint("BOTTOM", partyContainer, "TOP", offsetX, -offsetY)
    elseif anchor == "LEFT" then
        container:SetPoint("RIGHT", partyContainer, "LEFT", offsetX, offsetY)
    elseif anchor == "RIGHT" then
        container:SetPoint("LEFT", partyContainer, "RIGHT", -offsetX, offsetY)
    end
    
    -- Position pet frames within container (fallback path)
    for i, frame in ipairs(petFrames) do
        frame:ClearAllPoints()
        frame:SetParent(container)
        
        if i == 1 then
            if growth == "HORIZONTAL" then
                frame:SetPoint("LEFT", container, "LEFT", 0, 0)
            else
                frame:SetPoint("TOP", container, "TOP", 0, 0)
            end
        else
            local prevFrame = petFrames[i - 1]
            if growth == "HORIZONTAL" then
                frame:SetPoint("LEFT", prevFrame, "RIGHT", spacing, 0)
            else
                frame:SetPoint("TOP", prevFrame, "BOTTOM", 0, -spacing)
            end
        end
    end
    
    container:Show()
end

-- ============================================================
-- RAID PET GROUP
-- ============================================================

function DF:CreateRaidPetGroupContainer()
    if DF.raidPetGroupContainer then return DF.raidPetGroupContainer end
    
    local container = CreateFrame("Frame", "DandersFrames_RaidPetGroupContainer", DF.raidContainer or UIParent)
    container:SetSize(200, 100)
    container:Hide()
    
    -- Create group label
    container.label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    container.label:SetPoint("BOTTOM", container, "TOP", 0, 2)
    container.label:SetText("Pets")
    
    DF.raidPetGroupContainer = container
    return container
end

function DF:UpdateRaidPetGroupLayout()
    local db = DF:GetRaidDB()
    
    -- Only use group layout if in GROUPED mode and pets are enabled
    if db.petGroupMode ~= "GROUPED" or not db.petEnabled then
        if DF.raidPetGroupContainer then
            DF.raidPetGroupContainer:Hide()
        end
        return
    end
    
    -- Create container if needed
    if not DF.raidPetGroupContainer then
        DF:CreateRaidPetGroupContainer()
    end
    
    local container = DF.raidPetGroupContainer
    local raidContainer = DF.raidContainer
    
    if not raidContainer then return end
    
    -- Collect visible pet frames (cap at 10 for test mode)
    local petFrames = {}
    local isTestMode = DF.raidTestMode
    local maxPets = 10  -- Cap for test mode display
    
    if isTestMode then
        if db.testShowPets == false then
            container:Hide()
            return
        end
        local testFrameCount = math.min(db.raidTestFrameCount or 10, maxPets)
        for i = 1, testFrameCount do
            if DF.raidPetFrames[i] then
                table.insert(petFrames, DF.raidPetFrames[i])
            end
        end
    else
        for i = 1, 40 do
            if DF.raidPetFrames[i] and UnitExists("raidpet" .. i) then
                table.insert(petFrames, DF.raidPetFrames[i])
            end
        end
    end
    
    if #petFrames == 0 then
        container:Hide()
        return
    end
    
    -- Get pet group settings
    local petFrameWidth = db.petFrameWidth or 72
    local petFrameHeight = db.petFrameHeight or 18
    local petSpacing = db.petGroupSpacing or 2
    local petGrowth = db.petGroupGrowth or "VERTICAL"
    local petAnchor = db.petGroupAnchor or "RIGHT"
    local offsetX = db.petGroupOffsetX or 5
    local offsetY = db.petGroupOffsetY or 0
    
    -- Size container based on pet frame dimensions and growth direction
    local containerWidth, containerHeight
    if petGrowth == "HORIZONTAL" then
        containerWidth = (#petFrames * petFrameWidth) + ((#petFrames - 1) * petSpacing)
        containerHeight = petFrameHeight
    else
        containerWidth = petFrameWidth
        containerHeight = (#petFrames * petFrameHeight) + ((#petFrames - 1) * petSpacing)
    end
    container:SetSize(containerWidth, containerHeight)
    
    -- Find actual bounds and edge frames of visible raid frames
    local minX, maxX, minY, maxY
    local leftmostFrame, rightmostFrame, topmostFrame, bottommostFrame
    
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(frame)
            if frame and frame:IsShown() then
                local left, bottom, width, height = frame:GetRect()
                if left and bottom and width and height then
                    local right = left + width
                    local top = bottom + height
                    
                    if not minX or left < minX then 
                        minX = left 
                        leftmostFrame = frame
                    end
                    if not maxX or right > maxX then 
                        maxX = right 
                        rightmostFrame = frame
                    end
                    if not minY or bottom < minY then 
                        minY = bottom 
                        bottommostFrame = frame
                    end
                    if not maxY or top > maxY then 
                        maxY = top 
                        topmostFrame = frame
                    end
                end
            end
        end)
    end
    
    -- Position container relative to raid frames by anchoring to edge frames
    container:ClearAllPoints()
    container:SetParent(raidContainer)
    
    if minX and maxX and minY and maxY and leftmostFrame and rightmostFrame and topmostFrame and bottommostFrame then
        local raidWidth = maxX - minX
        local raidHeight = maxY - minY
        
        -- Calculate centering offsets
        local centerOffsetX = (raidWidth - containerWidth) / 2
        local centerOffsetY = (raidHeight - containerHeight) / 2
        
        if petAnchor == "RIGHT" then
            -- Right of raid frames, vertically centered
            -- Anchor to rightmostFrame, but need to offset Y since rightmostFrame might not be at top
            local rmLeft, rmBottom, rmWidth, rmHeight = rightmostFrame:GetRect()
            local rmTop = rmBottom + rmHeight
            local yAdjust = maxY - rmTop  -- How far down from the raid's top is this frame's top
            container:SetPoint("TOPLEFT", rightmostFrame, "TOPRIGHT", offsetX, yAdjust - centerOffsetY + offsetY)
            
        elseif petAnchor == "LEFT" then
            -- Left of raid frames, vertically centered
            -- Anchor to leftmostFrame, but need to offset Y since leftmostFrame might not be at top
            local lmLeft, lmBottom, lmWidth, lmHeight = leftmostFrame:GetRect()
            local lmTop = lmBottom + lmHeight
            local yAdjust = maxY - lmTop  -- How far down from the raid's top is this frame's top
            container:SetPoint("TOPRIGHT", leftmostFrame, "TOPLEFT", -offsetX, yAdjust - centerOffsetY + offsetY)
            
        elseif petAnchor == "BOTTOM" then
            -- Below raid frames, horizontally centered
            -- Anchor to bottommostFrame, but need to offset X since bottommostFrame might not be at left
            local bmLeft = select(1, bottommostFrame:GetRect())
            local xAdjust = bmLeft - minX  -- How far right from the raid's left is this frame
            container:SetPoint("TOPLEFT", bottommostFrame, "BOTTOMLEFT", -xAdjust + centerOffsetX + offsetX, -offsetY)
            
        elseif petAnchor == "TOP" then
            -- Above raid frames, horizontally centered
            -- Anchor to topmostFrame, but need to offset X since topmostFrame might not be at left
            local tmLeft = select(1, topmostFrame:GetRect())
            local xAdjust = tmLeft - minX  -- How far right from the raid's left is this frame
            container:SetPoint("BOTTOMLEFT", topmostFrame, "TOPLEFT", -xAdjust + centerOffsetX + offsetX, offsetY)
        end
    else
        -- Fallback: anchor to raid container directly
        container:SetPoint("TOPLEFT", raidContainer, "TOPRIGHT", offsetX, offsetY)
    end
    
    -- Update label
    if db.petGroupShowLabel ~= false then
        container.label:SetText(db.petGroupLabel or "Pets")
        container.label:Show()
        
        -- Apply group label styling from raid settings
        local labelFont = db.groupLabelFont or "Fonts\\FRIZQT__.TTF"
        local labelSize = db.groupLabelFontSize or 12
        local labelOutline = db.groupLabelOutline or "OUTLINE"
        DF:SafeSetFont(container.label, labelFont, labelSize, labelOutline)
        
        local labelColor = db.groupLabelColor or {r = 1, g = 1, b = 1}
        container.label:SetTextColor(labelColor.r, labelColor.g, labelColor.b)
    else
        container.label:Hide()
    end
    
    -- Position pet frames within container
    for i, frame in ipairs(petFrames) do
        frame:ClearAllPoints()
        frame:SetParent(container)
        
        if i == 1 then
            if petGrowth == "HORIZONTAL" then
                frame:SetPoint("LEFT", container, "LEFT", 0, 0)
            else
                frame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
            end
        else
            local prevFrame = petFrames[i - 1]
            if petGrowth == "HORIZONTAL" then
                frame:SetPoint("LEFT", prevFrame, "RIGHT", petSpacing, 0)
            else
                frame:SetPoint("TOP", prevFrame, "BOTTOM", 0, -petSpacing)
            end
        end
    end
    
    container:Show()
end

-- ============================================================
-- PET FRAME INITIALIZATION
-- ============================================================

function DF:InitializePetFrames()
    local db = DF:GetDB()
    
    -- Don't create if pets are disabled
    if not db.petEnabled then return end
    
    -- Create player pet frame
    local playerFrame = DF:GetPlayerFrame()
    if not DF.petFrames.player and playerFrame then
        DF.petFrames.player = DF:CreatePetFrame("pet", playerFrame, false)
    end
    
    -- Create party pet frames
    for i = 1, 4 do
        local partyFrame = DF:GetPartyFrame(i)
        if not DF.partyPetFrames[i] and partyFrame then
            DF.partyPetFrames[i] = DF:CreatePetFrame("partypet" .. i, partyFrame, false)
        end
    end
    
    -- Mark as initialized
    DF.petFramesInitialized = true
    
    -- Position all pet frames
    DF:UpdateAllPetFramePositions()
end

function DF:InitializeRaidPetFrames()
    local db = DF:GetRaidDB()
    
    -- Don't create if pets are disabled for raid
    if not db.petEnabled then return end
    
    -- Create raid pet frames via iterator
    local frameIdx = 0
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(frame)
            frameIdx = frameIdx + 1
            if not DF.raidPetFrames[frameIdx] and frame then
                DF.raidPetFrames[frameIdx] = DF:CreatePetFrame("raidpet" .. frameIdx, frame, true)
            end
        end)
    end
end

-- ============================================================
-- UPDATE ALL PET FRAMES
-- ============================================================

function DF:UpdateAllPetFrames()
    local db = DF:GetDB()
    
    -- Hide party pet group container if in raid test mode
    if DF.raidTestMode then
        if DF.petFrames.player then DF.petFrames.player:Hide() end
        for i = 1, 4 do
            if DF.partyPetFrames[i] then DF.partyPetFrames[i]:Hide() end
        end
        if DF.petGroupContainer then DF.petGroupContainer:Hide() end
        return
    end
    
    -- In test mode, check testShowPets; outside test mode, check petEnabled
    local shouldShowPets = DF.testMode and (db.testShowPets ~= false) or (not DF.testMode and db.petEnabled)
    
    if not shouldShowPets then
        -- Hide all pet frames if disabled
        if DF.petFrames.player then DF.petFrames.player:Hide() end
        for i = 1, 4 do
            if DF.partyPetFrames[i] then DF.partyPetFrames[i]:Hide() end
        end
        if DF.petGroupContainer then DF.petGroupContainer:Hide() end
        return
    end
    
    -- Initialize if needed
    DF:InitializePetFrames()
    
    -- Update player pet
    if DF.petFrames.player then
        DF:UpdatePetFrame(DF.petFrames.player)
        DF:PositionPetFrame(DF.petFrames.player)
    end
    
    -- Update party pets
    for i = 1, 4 do
        if DF.partyPetFrames[i] then
            DF:UpdatePetFrame(DF.partyPetFrames[i])
            DF:PositionPetFrame(DF.partyPetFrames[i])
        end
    end
    
    -- Update group layout if in grouped mode
    if db.petGroupMode == "GROUPED" then
        DF:UpdatePetGroupLayout()
    end
end

function DF:UpdateAllRaidPetFrames()
    local db = DF:GetRaidDB()
    
    -- Hide raid pet frames if in party test mode (not raid test mode)
    if DF.testMode and not DF.raidTestMode then
        for i = 1, 40 do
            if DF.raidPetFrames[i] then DF.raidPetFrames[i]:Hide() end
        end
        if DF.raidPetGroupContainer then DF.raidPetGroupContainer:Hide() end
        return
    end
    
    -- In test mode, check testShowPets; outside test mode, check petEnabled
    local shouldShowPets = DF.raidTestMode and (db.testShowPets ~= false) or (not DF.raidTestMode and db.petEnabled)
    
    if not shouldShowPets then
        -- Hide all raid pet frames if disabled
        for i = 1, 40 do
            if DF.raidPetFrames[i] then DF.raidPetFrames[i]:Hide() end
        end
        if DF.raidPetGroupContainer then DF.raidPetGroupContainer:Hide() end
        return
    end
    
    -- Initialize if needed (deferred creation)
    -- Only create pet frames for existing raid frames
    local frameIdx = 0
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(frame)
            frameIdx = frameIdx + 1
            if frame and not DF.raidPetFrames[frameIdx] then
                DF.raidPetFrames[frameIdx] = DF:CreatePetFrame("raidpet" .. frameIdx, frame, true)
            end
        end)
    end
    
    -- Update all raid pets
    for i = 1, 40 do
        if DF.raidPetFrames[i] then
            DF:UpdatePetFrame(DF.raidPetFrames[i])
            DF:PositionPetFrame(DF.raidPetFrames[i])
        end
    end
    
    -- Update group layout if in grouped mode
    if db.petGroupMode == "GROUPED" then
        DF:UpdateRaidPetGroupLayout()
    end
end

function DF:UpdateAllPetFramePositions()
    -- Update party pet positions
    if DF.petFrames.player then
        DF:PositionPetFrame(DF.petFrames.player)
    end
    
    for i = 1, 4 do
        if DF.partyPetFrames[i] then
            DF:PositionPetFrame(DF.partyPetFrames[i])
        end
    end
    
    -- Update raid pet positions
    for i = 1, 40 do
        if DF.raidPetFrames[i] then
            DF:PositionPetFrame(DF.raidPetFrames[i])
        end
    end
end

-- ============================================================
-- PET EVENT HANDLING
-- ============================================================

function DF:OnPetChanged(unit)
    -- Determine which pet frame to update based on unit
    if unit == "player" or unit == "pet" then
        if DF.petFrames.player then
            DF:UpdatePetFrame(DF.petFrames.player)
        end
    elseif unit:match("^party%d$") then
        local index = tonumber(unit:match("party(%d)"))
        if index and DF.partyPetFrames[index] then
            DF:UpdatePetFrame(DF.partyPetFrames[index])
        end
    elseif unit:match("^partypet%d$") then
        local index = tonumber(unit:match("partypet(%d)"))
        if index and DF.partyPetFrames[index] then
            DF:UpdatePetFrame(DF.partyPetFrames[index])
        end
    elseif unit:match("^raid%d+$") then
        local index = tonumber(unit:match("raid(%d+)"))
        if index and DF.raidPetFrames[index] then
            DF:UpdatePetFrame(DF.raidPetFrames[index])
        end
    elseif unit:match("^raidpet%d+$") then
        local index = tonumber(unit:match("raidpet(%d+)"))
        if index and DF.raidPetFrames[index] then
            DF:UpdatePetFrame(DF.raidPetFrames[index])
        end
    end
end

-- Register for UNIT_PET event in main addon
-- This will be called from the main event handler
function DF:HandleUnitPetEvent(unit)
    local db = DF:GetDB()
    
    -- Lazy-load pet frames on first pet event (if pets are enabled)
    if db.petEnabled and not DF.petFramesInitialized then
        DF:InitializePetFrames()
        DF.petFramesInitialized = true
    end
    
    DF:OnPetChanged(unit)
end

-- ============================================================
-- APPLY PET SETTINGS (called when settings change)
-- ============================================================

function DF:ApplyPetSettings()
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    -- Update party/solo pet frames
    if db.petEnabled then
        DF:InitializePetFrames()
        DF:UpdateAllPetFrames()
    else
        -- Hide all party pet frames
        if DF.petFrames.player then DF.petFrames.player:Hide() end
        for i = 1, 4 do
            if DF.partyPetFrames[i] then DF.partyPetFrames[i]:Hide() end
        end
    end
    
    -- Update raid pet frames
    if raidDb.petEnabled then
        DF:UpdateAllRaidPetFrames()
    else
        for i = 1, 40 do
            if DF.raidPetFrames[i] then DF.raidPetFrames[i]:Hide() end
        end
    end
end
