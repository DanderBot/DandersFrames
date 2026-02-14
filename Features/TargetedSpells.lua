local addonName, DF = ...

-- ============================================================
-- TARGETED SPELLS SYSTEM
-- Shows incoming spell casts targeting party/raid members
-- 
-- When an enemy casts a spell targeting a party member, this
-- displays an icon with cast bar on that member's frame to
-- warn healers of incoming damage.
--
-- Supports multiple simultaneous incoming spells with stacking.
-- Features:
--   - Highlight important spells (C_Spell.IsSpellImportant)
--   - Sort by cast time (newest/oldest first)
--   - Max icons limit
--   - Interrupted visual feedback
--   - Off-screen nameplate support
-- ============================================================

local pairs, ipairs, wipe = pairs, ipairs, wipe
local GetTime = GetTime
local UnitExists = UnitExists
local UnitIsUnit = UnitIsUnit
local UnitGUID = UnitGUID
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local UnitCastingDuration = UnitCastingDuration
local UnitChannelDuration = UnitChannelDuration
local UnitCanAttack = UnitCanAttack
local C_Spell = C_Spell
local C_CVar = C_CVar

-- Track all enemy casters we're monitoring
-- Structure: activeCasters[casterUnit] = { startTime = time, spellID = id, isChannel = bool }
-- Using unit token (e.g. "nameplate7") as key instead of GUID because GUIDs are secret values
local activeCasters = {}

-- Personal display variables (declared early for HandleTargetChange access)
local personalContainer = nil
local personalIcons = {}
local personalActiveSpells = {}

-- Cast history for learning/review (test feature)
-- Stores recent enemy casts with targeting info
local castHistory = {}
local MAX_HISTORY = 50

-- Event frame for tracking casts
local eventFrame = CreateFrame("Frame")
eventFrame:Hide()

-- ============================================================
-- HIGHLIGHT STYLE ANIMATIONS
-- ============================================================

-- Animation settings for marching ants
local ANIM_SPEED = 40
local DASH_LENGTH = 4
local GAP_LENGTH = 4
local PATTERN_LENGTH = DASH_LENGTH + GAP_LENGTH

-- Global animator for marching ants and pulse on targeted spell icons
local TargetedSpellAnimator = CreateFrame("Frame")
TargetedSpellAnimator.elapsed = 0
TargetedSpellAnimator.frames = {}
TargetedSpellAnimator.pulseFrames = {}
TargetedSpellAnimator.hasWork = false  -- Track whether any frames are registered

local function TargetedSpellAnimator_OnUpdate(self, elapsed)
    -- PERF TEST: Skip animations if disabled
    if DF.PerfTest and not DF.PerfTest.enableAnimations then return end
    
    -- Marching ants animation
    self.elapsed = self.elapsed + elapsed
    local offset = (self.elapsed * ANIM_SPEED) % PATTERN_LENGTH
    for highlightFrame in pairs(self.frames) do
        if highlightFrame:IsShown() and highlightFrame.animBorder then
            DF:UpdateTargetedSpellAnimatedBorder(highlightFrame, offset)
        end
    end
    
    -- Pulse animation (animates border texture alpha, not frame alpha)
    for highlightFrame in pairs(self.pulseFrames) do
        if highlightFrame:IsShown() and highlightFrame.pulseState and highlightFrame.glowBorder then
            local state = highlightFrame.pulseState
            state.elapsed = state.elapsed + elapsed
            
            -- Calculate current alpha based on time
            local progress = state.elapsed / state.duration
            if progress >= 1 then
                -- Reverse direction
                state.direction = -state.direction
                state.elapsed = 0
                progress = 0
            end
            
            -- Smooth interpolation (smoothstep)
            local smoothProgress = progress * progress * (3 - 2 * progress)
            
            local alpha
            if state.direction == 1 then
                alpha = state.minAlpha + (state.maxAlpha - state.minAlpha) * smoothProgress
            else
                alpha = state.maxAlpha - (state.maxAlpha - state.minAlpha) * smoothProgress
            end
            
            -- Apply alpha to border textures
            local border = highlightFrame.glowBorder
            local r = highlightFrame.pulseR or 1
            local g = highlightFrame.pulseG or 0.8
            local b = highlightFrame.pulseB or 0
            
            if border.top then border.top:SetColorTexture(r, g, b, alpha * 0.8) end
            if border.bottom then border.bottom:SetColorTexture(r, g, b, alpha * 0.8) end
            if border.left then border.left:SetColorTexture(r, g, b, alpha * 0.8) end
            if border.right then border.right:SetColorTexture(r, g, b, alpha * 0.8) end
        end
    end
end

-- Check if animator has any work to do and enable/disable accordingly
local function TargetedSpellAnimator_UpdateState()
    local hasWork = next(TargetedSpellAnimator.frames) or next(TargetedSpellAnimator.pulseFrames)
    if hasWork and not TargetedSpellAnimator.hasWork then
        TargetedSpellAnimator.hasWork = true
        TargetedSpellAnimator:SetScript("OnUpdate", TargetedSpellAnimator_OnUpdate)
    elseif not hasWork and TargetedSpellAnimator.hasWork then
        TargetedSpellAnimator.hasWork = false
        TargetedSpellAnimator:SetScript("OnUpdate", nil)
    end
end

-- Export for test mode access
DF.TargetedSpellAnimator = TargetedSpellAnimator

-- Create dashes for one edge of the animated border
local function CreateEdgeDashes(parent, count)
    local dashes = {}
    for i = 1, count do
        local dash = parent:CreateTexture(nil, "OVERLAY")
        dash:SetColorTexture(1, 1, 1, 1)
        dash:Hide()
        dashes[i] = dash
    end
    return dashes
end

-- Initialize animated border on a highlight frame
local function InitAnimatedBorder(highlightFrame)
    if highlightFrame.animBorder then return highlightFrame.animBorder end
    highlightFrame.animBorder = {
        topDashes = CreateEdgeDashes(highlightFrame, 15),
        bottomDashes = CreateEdgeDashes(highlightFrame, 15),
        leftDashes = CreateEdgeDashes(highlightFrame, 15),
        rightDashes = CreateEdgeDashes(highlightFrame, 15),
    }
    return highlightFrame.animBorder
end
DF.InitAnimatedBorder = InitAnimatedBorder

-- Update animated border with current offset
function DF:UpdateTargetedSpellAnimatedBorder(highlightFrame, offset)
    local border = highlightFrame.animBorder
    if not border then return end
    local thick = highlightFrame.animThickness or 2
    local r, g, b, a = highlightFrame.animR or 1, highlightFrame.animG or 0.8, highlightFrame.animB or 0, highlightFrame.animA or 1
    local frameWidth, frameHeight = highlightFrame:GetWidth(), highlightFrame:GetHeight()
    if frameWidth <= 0 or frameHeight <= 0 then return end

    local function DrawHorizontalEdge(dashes, isTop, edgeOffset)
        local numDashes = math.ceil(frameWidth / PATTERN_LENGTH) + 2
        for i, dash in ipairs(dashes) do dash:Hide() end
        local startPos = -(edgeOffset % PATTERN_LENGTH)
        for i = 1, numDashes do
            local dashStart = startPos + (i - 1) * PATTERN_LENGTH
            local dashEnd = dashStart + DASH_LENGTH
            local visStart, visEnd = math.max(0, dashStart), math.min(frameWidth, dashEnd)
            if visEnd > visStart and dashes[i] then
                local dash = dashes[i]
                dash:ClearAllPoints()
                dash:SetSize(visEnd - visStart, thick)
                if isTop then
                    dash:SetPoint("TOPLEFT", highlightFrame, "TOPLEFT", visStart, 0)
                else
                    dash:SetPoint("BOTTOMLEFT", highlightFrame, "BOTTOMLEFT", visStart, 0)
                end
                dash:SetColorTexture(r, g, b, a)
                dash:Show()
            end
        end
    end

    local function DrawVerticalEdge(dashes, isRight, edgeOffset)
        local numDashes = math.ceil(frameHeight / PATTERN_LENGTH) + 2
        for i, dash in ipairs(dashes) do dash:Hide() end
        local startPos = -(edgeOffset % PATTERN_LENGTH)
        for i = 1, numDashes do
            local dashStart = startPos + (i - 1) * PATTERN_LENGTH
            local dashEnd = dashStart + DASH_LENGTH
            local visStart, visEnd = math.max(0, dashStart), math.min(frameHeight, dashEnd)
            if visEnd > visStart and dashes[i] then
                local dash = dashes[i]
                dash:ClearAllPoints()
                dash:SetSize(thick, visEnd - visStart)
                if isRight then
                    dash:SetPoint("TOPRIGHT", highlightFrame, "TOPRIGHT", 0, -visStart)
                else
                    dash:SetPoint("TOPLEFT", highlightFrame, "TOPLEFT", 0, -visStart)
                end
                dash:SetColorTexture(r, g, b, a)
                dash:Show()
            end
        end
    end

    -- Counter-clockwise marching ants
    DrawHorizontalEdge(border.bottomDashes, false, offset)
    DrawVerticalEdge(border.leftDashes, false, frameWidth + offset)
    DrawHorizontalEdge(border.topDashes, true, frameWidth + frameHeight - offset)
    DrawVerticalEdge(border.rightDashes, true, (2 * frameWidth) + frameHeight - offset)
end

-- Hide animated border
local function HideAnimatedBorder(highlightFrame)
    if not highlightFrame.animBorder then return end
    for _, dashes in pairs(highlightFrame.animBorder) do
        for _, dash in ipairs(dashes) do dash:Hide() end
    end
end
DF.HideAnimatedBorder = HideAnimatedBorder

-- Create solid border (4 edge textures)
local function InitSolidBorder(highlightFrame)
    if highlightFrame.solidBorder then return highlightFrame.solidBorder end
    highlightFrame.solidBorder = {
        top = highlightFrame:CreateTexture(nil, "BORDER"),
        bottom = highlightFrame:CreateTexture(nil, "BORDER"),
        left = highlightFrame:CreateTexture(nil, "BORDER"),
        right = highlightFrame:CreateTexture(nil, "BORDER"),
    }
    return highlightFrame.solidBorder
end
DF.InitSolidBorder = InitSolidBorder

-- Update solid border
local function UpdateSolidBorder(highlightFrame, thickness, r, g, b, a)
    local border = highlightFrame.solidBorder
    if not border then return end
    
    border.top:ClearAllPoints()
    border.top:SetPoint("TOPLEFT", highlightFrame, "TOPLEFT", 0, 0)
    border.top:SetPoint("TOPRIGHT", highlightFrame, "TOPRIGHT", 0, 0)
    border.top:SetHeight(thickness)
    border.top:SetColorTexture(r, g, b, a)
    border.top:SetBlendMode("BLEND")
    border.top:Show()
    
    border.bottom:ClearAllPoints()
    border.bottom:SetPoint("BOTTOMLEFT", highlightFrame, "BOTTOMLEFT", 0, 0)
    border.bottom:SetPoint("BOTTOMRIGHT", highlightFrame, "BOTTOMRIGHT", 0, 0)
    border.bottom:SetHeight(thickness)
    border.bottom:SetColorTexture(r, g, b, a)
    border.bottom:SetBlendMode("BLEND")
    border.bottom:Show()
    
    border.left:ClearAllPoints()
    border.left:SetPoint("TOPLEFT", highlightFrame, "TOPLEFT", 0, -thickness)
    border.left:SetPoint("BOTTOMLEFT", highlightFrame, "BOTTOMLEFT", 0, thickness)
    border.left:SetWidth(thickness)
    border.left:SetColorTexture(r, g, b, a)
    border.left:SetBlendMode("BLEND")
    border.left:Show()
    
    border.right:ClearAllPoints()
    border.right:SetPoint("TOPRIGHT", highlightFrame, "TOPRIGHT", 0, -thickness)
    border.right:SetPoint("BOTTOMRIGHT", highlightFrame, "BOTTOMRIGHT", 0, thickness)
    border.right:SetWidth(thickness)
    border.right:SetColorTexture(r, g, b, a)
    border.right:SetBlendMode("BLEND")
    border.right:Show()
end
DF.UpdateSolidBorder = UpdateSolidBorder

-- Hide solid border
local function HideSolidBorder(highlightFrame)
    if not highlightFrame or not highlightFrame.solidBorder then return end
    highlightFrame.solidBorder.top:Hide()
    highlightFrame.solidBorder.bottom:Hide()
    highlightFrame.solidBorder.left:Hide()
    highlightFrame.solidBorder.right:Hide()
end
DF.HideSolidBorder = HideSolidBorder

-- Create glow border (4 edge textures with ADD blend mode for glow effect)
local function InitGlowBorder(highlightFrame)
    if highlightFrame.glowBorder then return highlightFrame.glowBorder end
    highlightFrame.glowBorder = {
        top = highlightFrame:CreateTexture(nil, "OVERLAY"),
        bottom = highlightFrame:CreateTexture(nil, "OVERLAY"),
        left = highlightFrame:CreateTexture(nil, "OVERLAY"),
        right = highlightFrame:CreateTexture(nil, "OVERLAY"),
    }
    -- Set ADD blend mode for glow effect
    for _, tex in pairs(highlightFrame.glowBorder) do
        tex:SetBlendMode("ADD")
    end
    return highlightFrame.glowBorder
end
DF.InitGlowBorder = InitGlowBorder

-- Update glow border
local function UpdateGlowBorder(highlightFrame, thickness, r, g, b, a)
    local border = highlightFrame.glowBorder
    if not border then return end
    
    border.top:ClearAllPoints()
    border.top:SetPoint("TOPLEFT", highlightFrame, "TOPLEFT", 0, 0)
    border.top:SetPoint("TOPRIGHT", highlightFrame, "TOPRIGHT", 0, 0)
    border.top:SetHeight(thickness)
    border.top:SetColorTexture(r, g, b, a)
    border.top:SetBlendMode("ADD")
    border.top:Show()
    
    border.bottom:ClearAllPoints()
    border.bottom:SetPoint("BOTTOMLEFT", highlightFrame, "BOTTOMLEFT", 0, 0)
    border.bottom:SetPoint("BOTTOMRIGHT", highlightFrame, "BOTTOMRIGHT", 0, 0)
    border.bottom:SetHeight(thickness)
    border.bottom:SetColorTexture(r, g, b, a)
    border.bottom:SetBlendMode("ADD")
    border.bottom:Show()
    
    border.left:ClearAllPoints()
    border.left:SetPoint("TOPLEFT", highlightFrame, "TOPLEFT", 0, -thickness)
    border.left:SetPoint("BOTTOMLEFT", highlightFrame, "BOTTOMLEFT", 0, thickness)
    border.left:SetWidth(thickness)
    border.left:SetColorTexture(r, g, b, a)
    border.left:SetBlendMode("ADD")
    border.left:Show()
    
    border.right:ClearAllPoints()
    border.right:SetPoint("TOPRIGHT", highlightFrame, "TOPRIGHT", 0, -thickness)
    border.right:SetPoint("BOTTOMRIGHT", highlightFrame, "BOTTOMRIGHT", 0, thickness)
    border.right:SetWidth(thickness)
    border.right:SetColorTexture(r, g, b, a)
    border.right:SetBlendMode("ADD")
    border.right:Show()
end
DF.UpdateGlowBorder = UpdateGlowBorder

-- Hide glow border
local function HideGlowBorder(highlightFrame)
    if not highlightFrame or not highlightFrame.glowBorder then return end
    highlightFrame.glowBorder.top:Hide()
    highlightFrame.glowBorder.bottom:Hide()
    highlightFrame.glowBorder.left:Hide()
    highlightFrame.glowBorder.right:Hide()
end
DF.HideGlowBorder = HideGlowBorder

-- Create pulse animation group - animates border texture alpha, not frame alpha
-- This prevents the animation from overriding SetAlphaFromBoolean on the frame
local function InitPulseAnimation(highlightFrame)
    if highlightFrame.pulseAnim then return highlightFrame.pulseAnim end
    
    -- Store pulse state on the frame
    highlightFrame.pulseState = {
        elapsed = 0,
        minAlpha = 0.3,
        maxAlpha = 1.0,
        duration = 0.5,
        direction = 1,  -- 1 = fading in, -1 = fading out
    }
    
    -- Create a dummy animation group that we use to track if pulsing is active
    local ag = {}
    ag.isPlaying = false
    ag.Play = function(self)
        self.isPlaying = true
        highlightFrame.pulseState.elapsed = 0
        highlightFrame.pulseState.direction = 1
        -- Register with animator
        TargetedSpellAnimator.pulseFrames[highlightFrame] = true
        TargetedSpellAnimator_UpdateState()
    end
    ag.Stop = function(self)
        self.isPlaying = false
        TargetedSpellAnimator.pulseFrames[highlightFrame] = nil
        TargetedSpellAnimator_UpdateState()
    end
    ag.IsPlaying = function(self)
        return self.isPlaying
    end
    
    highlightFrame.pulseAnim = ag
    return ag
end
DF.InitPulseAnimation = InitPulseAnimation



-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

-- Get all party/raid units to check
local function GetGroupUnits()
    local units = {}
    
    -- Always include player
    table.insert(units, "player")
    
    if IsInRaid() then
        for i = 1, 40 do
            local unit = "raid" .. i
            -- Note: "raidN" tokens never equal "player" string, so simple ~= check is safe
            -- (avoids potential secret value issues with UnitIsUnit)
            if UnitExists(unit) and unit ~= "player" then
                table.insert(units, unit)
            end
        end
    else
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                table.insert(units, unit)
            end
        end
    end
    
    return units
end

-- Get current content type
-- Returns: "openworld", "dungeon", "raid", "arena", "battleground"
local function GetContentType()
    local inInstance, instanceType = IsInInstance()
    
    if not inInstance then
        return "openworld"
    end
    
    if instanceType == "party" then
        return "dungeon"
    elseif instanceType == "raid" then
        return "raid"
    elseif instanceType == "arena" then
        return "arena"
    elseif instanceType == "pvp" then
        return "battleground"
    elseif instanceType == "scenario" then
        return "dungeon"  -- Treat scenarios as dungeons
    end
    
    return "openworld"
end

-- Check if targeted spells should be shown for party/player frames based on content type
local function ShouldShowTargetedSpells(db)
    if not db.targetedSpellEnabled then return false end
    
    local contentType = GetContentType()
    
    if contentType == "openworld" then
        return db.targetedSpellInOpenWorld ~= false
    elseif contentType == "dungeon" then
        return db.targetedSpellInDungeons ~= false
    elseif contentType == "arena" then
        return db.targetedSpellInArena ~= false
    end
    
    return true  -- Default to showing
end

-- Check if targeted spells should be shown for raid frames based on content type
local function ShouldShowRaidTargetedSpells(db)
    if not db.targetedSpellEnabled then return false end
    
    local contentType = GetContentType()
    
    if contentType == "openworld" then
        return db.targetedSpellInOpenWorld ~= false
    elseif contentType == "raid" then
        return db.targetedSpellInRaids ~= false
    elseif contentType == "battleground" then
        return db.targetedSpellInBattlegrounds ~= false
    end
    
    return true  -- Default to showing
end

-- Check if personal targeted spells should be shown based on content type
local function ShouldShowPersonalTargetedSpells(db)
    if not db.personalTargetedSpellEnabled then return false end
    
    local contentType = GetContentType()
    
    if contentType == "openworld" then
        return db.personalTargetedSpellInOpenWorld ~= false
    elseif contentType == "dungeon" then
        return db.personalTargetedSpellInDungeons ~= false
    elseif contentType == "raid" then
        return db.personalTargetedSpellInRaids ~= false
    elseif contentType == "arena" then
        return db.personalTargetedSpellInArena ~= false
    elseif contentType == "battleground" then
        return db.personalTargetedSpellInBattlegrounds ~= false
    end
    
    return true  -- Default to showing
end

-- Check if a unit is valid for targeted spell tracking
-- We ONLY track nameplate units - boss/arena/target/focus all have nameplates too
-- so tracking them separately would cause duplicates
local function IsValidCasterUnit(unit)
    if not unit then return false end
    
    -- Only nameplate units
    if string.find(unit, "nameplate") then
        return true
    end
    
    return false
end

-- Get enemy units that might be casting at us
-- Note: We only track nameplates - boss/arena units have nameplates too
local function GetEnemyUnits()
    local units = {}
    
    -- Nameplates only (boss/arena/target/focus all have nameplates)
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
            table.insert(units, unit)
        end
    end
    
    return units
end

-- Get the frame for a unit
local function GetFrameForUnit(unit)
    -- Fast path: use unitFrameMap
    if DF.unitFrameMap and DF.unitFrameMap[unit] then
        return DF.unitFrameMap[unit]
    end
    
    local foundFrame = nil
    
    DF:IterateAllFrames(function(frame)
        if frame and frame.unit and frame.unit == unit then
            foundFrame = frame
            return true  -- Stop iteration
        end
    end)
    
    return foundFrame
end

-- Check if a spell is "important" using the new API
-- Returns a secret boolean that must be used with SetAlphaFromBoolean
local function IsSpellImportant(spellID)
    if not spellID then return false end
    if C_Spell and C_Spell.IsSpellImportant then
        -- This returns a secret boolean - can't use in if statements
        -- Must use SetAlphaFromBoolean on a frame
        local ok, result = pcall(C_Spell.IsSpellImportant, spellID)
        if ok then return result end
    end
    return false
end

-- ============================================================
-- ICON CREATION AND POOLING
-- ============================================================

-- Create a single targeted spell icon
local function CreateSingleIcon(parent, index)
    local container = CreateFrame("Frame", nil, parent)
    container:SetFrameLevel(parent:GetFrameLevel() + 30 + index)
    container:Hide()
    container.index = index
    
    -- Disable mouse completely - these should be click-through
    container:EnableMouse(false)
    -- Make hitbox zero so clicks pass through
    container:SetHitRectInsets(10000, 10000, 10000, 10000)
    
    -- Importance filter frame - nested inside container
    -- This allows us to filter by importance using SetAlphaFromBoolean
    -- when importantOnly is enabled, without affecting the targeting logic
    local importanceFilterFrame = CreateFrame("Frame", nil, container)
    importanceFilterFrame:SetAllPoints()
    importanceFilterFrame:EnableMouse(false)
    importanceFilterFrame:SetHitRectInsets(10000, 10000, 10000, 10000)
    container.importanceFilterFrame = importanceFilterFrame
    
    -- Icon container (with border) - now parented to importanceFilterFrame
    local iconFrame = CreateFrame("Frame", nil, importanceFilterFrame)
    iconFrame:SetSize(28, 28)
    iconFrame:EnableMouse(false)
    iconFrame:SetHitRectInsets(10000, 10000, 10000, 10000)
    container.iconFrame = iconFrame
    
    -- Icon border - 4 edge textures (consistent with defensive/missing buff icons)
    local defBorderSize = 2
    local borderLeft = iconFrame:CreateTexture(nil, "BACKGROUND")
    borderLeft:SetPoint("TOPLEFT", 0, 0)
    borderLeft:SetPoint("BOTTOMLEFT", 0, 0)
    borderLeft:SetWidth(defBorderSize)
    borderLeft:SetColorTexture(1, 0.3, 0, 1)
    container.borderLeft = borderLeft
    iconFrame.borderLeft = borderLeft
    
    local borderRight = iconFrame:CreateTexture(nil, "BACKGROUND")
    borderRight:SetPoint("TOPRIGHT", 0, 0)
    borderRight:SetPoint("BOTTOMRIGHT", 0, 0)
    borderRight:SetWidth(defBorderSize)
    borderRight:SetColorTexture(1, 0.3, 0, 1)
    container.borderRight = borderRight
    iconFrame.borderRight = borderRight
    
    local borderTop = iconFrame:CreateTexture(nil, "BACKGROUND")
    borderTop:SetPoint("TOPLEFT", defBorderSize, 0)
    borderTop:SetPoint("TOPRIGHT", -defBorderSize, 0)
    borderTop:SetHeight(defBorderSize)
    borderTop:SetColorTexture(1, 0.3, 0, 1)
    container.borderTop = borderTop
    iconFrame.borderTop = borderTop
    
    local borderBottom = iconFrame:CreateTexture(nil, "BACKGROUND")
    borderBottom:SetPoint("BOTTOMLEFT", defBorderSize, 0)
    borderBottom:SetPoint("BOTTOMRIGHT", -defBorderSize, 0)
    borderBottom:SetHeight(defBorderSize)
    borderBottom:SetColorTexture(1, 0.3, 0, 1)
    container.borderBottom = borderBottom
    iconFrame.borderBottom = borderBottom
    
    -- Important spell highlight frame - use a frame so we can SetAlphaFromBoolean
    -- Set frame level ABOVE iconFrame so it renders on top when inset
    local highlightFrame = CreateFrame("Frame", nil, iconFrame)
    highlightFrame:SetPoint("TOPLEFT", -4, 4)
    highlightFrame:SetPoint("BOTTOMRIGHT", 4, -4)
    highlightFrame:SetFrameLevel(iconFrame:GetFrameLevel() + 5)
    highlightFrame:Hide()
    highlightFrame:EnableMouse(false)
    highlightFrame:SetHitRectInsets(10000, 10000, 10000, 10000)
    container.highlightFrame = highlightFrame
    
    iconFrame.highlightFrame = highlightFrame
    
    -- Icon texture - positioned with inset for border, with TexCoord cropping
    local icon = iconFrame:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", defBorderSize, -defBorderSize)
    icon:SetPoint("BOTTOMRIGHT", -defBorderSize, defBorderSize)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    container.icon = icon
    iconFrame.icon = icon
    
    -- Cooldown frame for swipe animation on icon
    local cooldown = CreateFrame("Cooldown", nil, iconFrame, "CooldownFrameTemplate")
    cooldown:SetAllPoints(icon)
    cooldown:SetDrawEdge(false)
    cooldown:SetDrawBling(false)
    cooldown:SetDrawSwipe(true)
    cooldown:SetReverse(true)
    cooldown:SetHideCountdownNumbers(true)  -- We use our own duration text
    cooldown:EnableMouse(false)
    cooldown:SetHitRectInsets(10000, 10000, 10000, 10000)
    container.cooldown = cooldown
    iconFrame.cooldown = cooldown
    
    -- Overlay frame for duration text (sits above cooldown swipe)
    local textOverlay = CreateFrame("Frame", nil, iconFrame)
    textOverlay:SetAllPoints()
    textOverlay:SetFrameLevel(cooldown:GetFrameLevel() + 5)
    textOverlay:EnableMouse(false)
    textOverlay:SetHitRectInsets(10000, 10000, 10000, 10000)
    container.textOverlay = textOverlay
    
    -- Custom duration text (on overlay so it's above the swipe)
    local durationText = textOverlay:CreateFontString(nil, "OVERLAY")
    durationText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    durationText:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
    durationText:SetTextColor(1, 1, 1, 1)
    container.durationText = durationText
    iconFrame.durationText = durationText
    
    -- Interrupted overlay (X mark)
    local interruptOverlay = CreateFrame("Frame", nil, iconFrame)
    interruptOverlay:SetAllPoints()
    interruptOverlay:SetFrameLevel(cooldown:GetFrameLevel() + 10)
    interruptOverlay:Hide()
    interruptOverlay:EnableMouse(false)
    interruptOverlay:SetHitRectInsets(10000, 10000, 10000, 10000)
    container.interruptOverlay = interruptOverlay
    
    -- Red tint for interrupted
    local interruptTint = interruptOverlay:CreateTexture(nil, "OVERLAY")
    interruptTint:SetAllPoints()
    interruptTint:SetColorTexture(1, 0, 0, 0.5)
    container.interruptTint = interruptTint
    
    -- X mark for interrupted
    local interruptX = interruptOverlay:CreateFontString(nil, "OVERLAY")
    interruptX:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
    interruptX:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
    interruptX:SetText("X")
    interruptX:SetTextColor(1, 0, 0, 1)
    container.interruptX = interruptX
    
    -- OnUpdate for cleanup checking and duration text
    local durationThrottle = 0
    container:SetScript("OnUpdate", function(self, elapsed)
        -- Skip if not active (alpha is controlled by SetAlphaFromBoolean, can't read it)
        if not self.isActive then return end
        
        -- Handle interrupted animation (needs to run every frame for smooth animation)
        if self.isInterrupted then
            self.interruptTimer = (self.interruptTimer or 0) + elapsed
            local db = self.unitFrame and (self.unitFrame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()) or DF:GetDB()
            local duration = db.targetedSpellInterruptedDuration or 0.5
            
            if self.interruptTimer >= duration then
                -- Animation complete, hide icon
                if self.unitFrame and self.casterKey then
                    DF:HideTargetedSpellIcon(self.unitFrame, self.casterKey, true)
                end
            end
            return
        end
        
        -- Throttle duration text updates to ~10 FPS for performance
        durationThrottle = durationThrottle + elapsed
        if durationThrottle < 0.1 then return end
        durationThrottle = 0
        
        -- Update duration text from duration object
        -- Note: GetRemainingDuration returns a secret value so we can't compare it
        -- Just display it and use a fixed color from settings
        -- TODO: Can use durationObject:EvaluateRemainingPercent(colorCurve) for dynamic color-by-time
        -- similar to how aura icons do it in Frames/Create.lua
        if self.durationObject and self.durationText then
            local ok, remaining = pcall(self.durationObject.GetRemainingDuration, self.durationObject)
            if ok and remaining then
                -- Use SetFormattedText which handles secret values
                self.durationText:SetFormattedText("%.1f", remaining)
                
                -- Apply the configured color (can't do color-by-time with secret values)
                if self.durationColor then
                    self.durationText:SetTextColor(self.durationColor.r, self.durationColor.g, self.durationColor.b, 1)
                end
            end
        end
        
        -- Note: We DON'T check if cast is still active here anymore
        -- Events (UNIT_SPELLCAST_STOP, INTERRUPTED, etc.) handle all cleanup
        -- This prevents race conditions with interrupt visuals
    end)
    
    return container
end

-- Ensure icon pool exists for a frame
local function EnsureIconPool(frame, count)
    -- Create OOR container if it doesn't exist
    -- This container receives out-of-range alpha, so individual icons
    -- can use SetAlphaFromBoolean for targeting without conflict
    if not frame.targetedSpellContainer then
        local container = CreateFrame("Frame", nil, frame)
        container:SetAllPoints()
        container:SetFrameLevel(frame:GetFrameLevel() + 29)
        container:EnableMouse(false)
        container:SetHitRectInsets(10000, 10000, 10000, 10000)
        frame.targetedSpellContainer = container
    end
    
    if not frame.targetedSpellIcons then
        frame.targetedSpellIcons = {}
    end
    if not frame.dfActiveTargetedSpells then
        frame.dfActiveTargetedSpells = {}
    end
    
    count = count or 5  -- Default pool size
    
    for i = #frame.targetedSpellIcons + 1, count do
        -- Parent icons to the OOR container, not directly to frame
        frame.targetedSpellIcons[i] = CreateSingleIcon(frame.targetedSpellContainer, i)
        frame.targetedSpellIcons[i].unitFrame = frame
    end
end

-- Expose EnsureIconPool for test mode
function DF:EnsureTargetedSpellIconPool(frame, count)
    EnsureIconPool(frame, count)
end

-- Get an available icon from the pool
local function GetAvailableIcon(frame)
    EnsureIconPool(frame, 5)
    
    for i, icon in ipairs(frame.targetedSpellIcons) do
        if not icon:IsShown() or not icon.isActive then
            return icon, i
        end
    end
    
    -- All icons in use, create a new one - parent to container
    local newIndex = #frame.targetedSpellIcons + 1
    frame.targetedSpellIcons[newIndex] = CreateSingleIcon(frame.targetedSpellContainer, newIndex)
    frame.targetedSpellIcons[newIndex].unitFrame = frame
    return frame.targetedSpellIcons[newIndex], newIndex
end

-- ============================================================
-- LAYOUT AND POSITIONING
-- ============================================================

-- Position all icons based on growth direction
-- Sorts by cast start time for consistent ordering
local function PositionIcons(frame)
    if not frame or not frame.targetedSpellIcons or not frame.dfActiveTargetedSpells then return end
    
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    
    local iconSize = db.targetedSpellSize or 28
    local scale = db.targetedSpellScale or 1.0
    local anchor = db.targetedSpellAnchor or "LEFT"
    local x = db.targetedSpellX or -30
    local y = db.targetedSpellY or 0
    local growthDirection = db.targetedSpellGrowth or "DOWN"
    local spacing = db.targetedSpellSpacing or 2
    local frameLevel = db.targetedSpellFrameLevel or 0
    local maxIcons = db.targetedSpellMaxIcons or 5
    -- local sortByTime = db.targetedSpellSortByTime ~= false  -- Keep for future use
    -- local newestFirst = db.targetedSpellSortNewestFirst ~= false  -- Keep for future use
    
    -- Apply pixel perfect to icon size
    if db.pixelPerfect then
        iconSize = DF:PixelPerfect(iconSize)
        spacing = DF:PixelPerfect(spacing)
    end
    
    -- Apply scale to size for positioning calculations
    local scaledSize = iconSize * scale
    local scaledSpacing = spacing * scale
    
    -- Collect active casters with their data
    local casterData = {}
    for casterKey, iconIndex in pairs(frame.dfActiveTargetedSpells) do
        local icon = frame.targetedSpellIcons[iconIndex]
        if icon and icon.isActive then
            table.insert(casterData, {
                casterKey = casterKey,
                iconIndex = iconIndex,
                startTime = icon.startTime or 0
            })
        end
    end
    
    -- Sort by caster key (unit token) for deterministic order
    -- This ensures icons don't jump around as casts end
    table.sort(casterData, function(a, b)
        return a.casterKey < b.casterKey
    end)
    
    --[[ ALTERNATIVE: Sort by time (uncomment to use)
    if sortByTime then
        table.sort(casterData, function(a, b)
            if newestFirst then
                return a.startTime > b.startTime
            else
                return a.startTime < b.startTime
            end
        end)
    end
    --]]
    
    -- Limit to max icons
    local numIcons = math.min(#casterData, maxIcons)
    
    -- Position each icon based on its sorted position
    for i = 1, #casterData do
        local data = casterData[i]
        local icon = frame.targetedSpellIcons[data.iconIndex]
        
        if icon then
            if i <= maxIcons then
                local offsetX, offsetY = 0, 0
                local index = i - 1  -- 0-based for calculation
                
                if growthDirection == "UP" then
                    offsetY = index * (scaledSize + scaledSpacing)
                elseif growthDirection == "DOWN" then
                    offsetY = -index * (scaledSize + scaledSpacing)
                elseif growthDirection == "LEFT" then
                    offsetX = -index * (scaledSize + scaledSpacing)
                elseif growthDirection == "RIGHT" then
                    offsetX = index * (scaledSize + scaledSpacing)
                elseif growthDirection == "CENTER_H" then
                    -- Grow horizontally from center
                    local centerOffset = (numIcons - 1) * (scaledSize + scaledSpacing) / 2
                    offsetX = index * (scaledSize + scaledSpacing) - centerOffset
                elseif growthDirection == "CENTER_V" then
                    -- Grow vertically from center
                    local centerOffset = (numIcons - 1) * (scaledSize + scaledSpacing) / 2
                    offsetY = index * (scaledSize + scaledSpacing) - centerOffset
                end
                
                icon:ClearAllPoints()
                icon:SetPoint(anchor, frame, anchor, x + offsetX, y + offsetY)
                icon:SetSize(scaledSize, scaledSize)
                
                -- Set frame level
                icon:SetFrameLevel(frame:GetFrameLevel() + 30 + frameLevel + data.iconIndex)
                
                -- Position icon frame within container
                icon.iconFrame:SetSize(scaledSize, scaledSize)
                icon.iconFrame:ClearAllPoints()
                icon.iconFrame:SetPoint("CENTER", icon, "CENTER", 0, 0)
                
                icon:Show()
            else
                -- Hide icons beyond max limit
                icon:Hide()
            end
        end
    end
end

-- Apply settings to a single icon
local function ApplyIconSettings(icon, db, spellID)
    local borderColor = db.targetedSpellBorderColor or {r = 1, g = 0.3, b = 0}
    local borderSize = db.targetedSpellBorderSize or 2
    local showBorder = db.targetedSpellShowBorder ~= false
    local showSwipe = not db.targetedSpellHideSwipe
    local showDuration = db.targetedSpellShowDuration ~= false
    local durationFont = db.targetedSpellDurationFont or "Fonts\\FRIZQT__.TTF"
    local durationScale = db.targetedSpellDurationScale or 1.0
    local durationOutline = db.targetedSpellDurationOutline or "OUTLINE"
    local durationX = db.targetedSpellDurationX or 0
    local durationY = db.targetedSpellDurationY or 0
    local durationColor = db.targetedSpellDurationColor or {r = 1, g = 1, b = 1}
    local alpha = db.targetedSpellAlpha or 1.0
    local highlightImportant = db.targetedSpellHighlightImportant ~= false
    local highlightStyle = db.targetedSpellHighlightStyle or "glow"
    local highlightColor = db.targetedSpellHighlightColor or {r = 1, g = 0.8, b = 0}
    local highlightSize = db.targetedSpellHighlightSize or 3
    local highlightInset = db.targetedSpellHighlightInset or 0
    local importantOnly = db.targetedSpellImportantOnly
    if durationOutline == "NONE" then durationOutline = "" end
    
    -- Apply pixel perfect to border size
    if db.pixelPerfect then
        borderSize = DF:PixelPerfect(borderSize)
    end
    
    -- Store settings on icon for OnUpdate to use
    icon.durationColor = durationColor
    icon.baseAlpha = alpha
    
    -- Important spell filter (nested frame approach)
    -- When importantOnly is enabled, use SetAlphaFromBoolean to hide non-important spells
    if icon.importanceFilterFrame then
        if importantOnly and spellID then
            local isImportant = IsSpellImportant(spellID)
            icon.importanceFilterFrame:SetAlphaFromBoolean(isImportant)
        else
            -- Not filtering, show everything
            icon.importanceFilterFrame:SetAlpha(1)
        end
    end
    
    -- Important spell highlight
    if icon.highlightFrame then
        -- Calculate position with inset (negative inset = larger, positive = smaller/inward)
        local offset = borderSize + highlightSize - highlightInset
        
        -- Position the highlight frame
        icon.highlightFrame:ClearAllPoints()
        icon.highlightFrame:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", -offset, offset)
        icon.highlightFrame:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", offset, -offset)
        
        -- Hide all highlight styles first
        HideAnimatedBorder(icon.highlightFrame)
        HideSolidBorder(icon.highlightFrame)
        HideGlowBorder(icon.highlightFrame)
        if icon.highlightFrame.pulseAnim then icon.highlightFrame.pulseAnim:Stop() end
        TargetedSpellAnimator.frames[icon.highlightFrame] = nil
        TargetedSpellAnimator_UpdateState()
        
        if highlightImportant and spellID and highlightStyle ~= "none" then
            local isImportant = IsSpellImportant(spellID)
            
            if highlightStyle == "glow" then
                -- Glow effect using edge borders with ADD blend mode
                InitGlowBorder(icon.highlightFrame)
                UpdateGlowBorder(icon.highlightFrame, highlightSize, highlightColor.r, highlightColor.g, highlightColor.b, 0.8)
                icon.highlightFrame:Show()
                icon.highlightFrame:SetAlphaFromBoolean(isImportant)
                
            elseif highlightStyle == "marchingAnts" then
                -- Animated marching ants border
                InitAnimatedBorder(icon.highlightFrame)
                icon.highlightFrame.animThickness = math.max(1, highlightSize)
                icon.highlightFrame.animR = highlightColor.r
                icon.highlightFrame.animG = highlightColor.g
                icon.highlightFrame.animB = highlightColor.b
                icon.highlightFrame.animA = 1
                icon.highlightFrame:Show()
                icon.highlightFrame:SetAlphaFromBoolean(isImportant)
                TargetedSpellAnimator.frames[icon.highlightFrame] = true
                TargetedSpellAnimator_UpdateState()
                
            elseif highlightStyle == "solidBorder" then
                -- Solid colored border (4 edge textures, no fill)
                InitSolidBorder(icon.highlightFrame)
                UpdateSolidBorder(icon.highlightFrame, highlightSize, highlightColor.r, highlightColor.g, highlightColor.b, 1)
                icon.highlightFrame:Show()
                icon.highlightFrame:SetAlphaFromBoolean(isImportant)
                
            elseif highlightStyle == "pulse" then
                -- Pulsing glow using edge borders with ADD blend
                InitGlowBorder(icon.highlightFrame)
                UpdateGlowBorder(icon.highlightFrame, highlightSize, highlightColor.r, highlightColor.g, highlightColor.b, 0.8)
                InitPulseAnimation(icon.highlightFrame)
                -- Store color for pulse animation to use
                icon.highlightFrame.pulseR = highlightColor.r
                icon.highlightFrame.pulseG = highlightColor.g
                icon.highlightFrame.pulseB = highlightColor.b
                icon.highlightFrame:Show()
                icon.highlightFrame:SetAlphaFromBoolean(isImportant)
                icon.highlightFrame.pulseAnim:Play()
            end
        else
            icon.highlightFrame:Hide()
        end
    end
    
    -- Border
    -- Border - 4 edge textures (consistent with defensive/missing buff icons)
    if showBorder then
        if icon.borderLeft then
            icon.borderLeft:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, 1)
            icon.borderLeft:SetWidth(borderSize)
            icon.borderLeft:Show()
        end
        if icon.borderRight then
            icon.borderRight:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, 1)
            icon.borderRight:SetWidth(borderSize)
            icon.borderRight:Show()
        end
        if icon.borderTop then
            icon.borderTop:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, 1)
            icon.borderTop:SetHeight(borderSize)
            icon.borderTop:ClearAllPoints()
            icon.borderTop:SetPoint("TOPLEFT", borderSize, 0)
            icon.borderTop:SetPoint("TOPRIGHT", -borderSize, 0)
            icon.borderTop:Show()
        end
        if icon.borderBottom then
            icon.borderBottom:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, 1)
            icon.borderBottom:SetHeight(borderSize)
            icon.borderBottom:ClearAllPoints()
            icon.borderBottom:SetPoint("BOTTOMLEFT", borderSize, 0)
            icon.borderBottom:SetPoint("BOTTOMRIGHT", -borderSize, 0)
            icon.borderBottom:Show()
        end
        
        -- Adjust icon texture position for border
        if icon.icon then
            icon.icon:ClearAllPoints()
            icon.icon:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", borderSize, -borderSize)
            icon.icon:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", -borderSize, borderSize)
        end
        
        -- Adjust cooldown to match icon texture
        if icon.cooldown then
            icon.cooldown:ClearAllPoints()
            icon.cooldown:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", borderSize, -borderSize)
            icon.cooldown:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", -borderSize, borderSize)
        end
    else
        -- Hide all border edges
        if icon.borderLeft then icon.borderLeft:Hide() end
        if icon.borderRight then icon.borderRight:Hide() end
        if icon.borderTop then icon.borderTop:Hide() end
        if icon.borderBottom then icon.borderBottom:Hide() end
        
        -- Full size icon when no border
        if icon.icon then
            icon.icon:ClearAllPoints()
            icon.icon:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", 0, 0)
            icon.icon:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", 0, 0)
        end
        
        -- Adjust cooldown to match
        if icon.cooldown then
            icon.cooldown:ClearAllPoints()
            icon.cooldown:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", 0, 0)
            icon.cooldown:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", 0, 0)
        end
    end
    
    -- Cooldown on icon (hide native countdown, we use custom)
    if icon.cooldown then
        icon.cooldown:SetDrawSwipe(showSwipe)
        icon.cooldown:SetHideCountdownNumbers(true)
    end
    
    -- Custom duration text
    if icon.durationText then
        if showDuration then
            icon.durationText:Show()
            local fontSize = 10 * durationScale
            DF:SafeSetFont(icon.durationText, durationFont, fontSize, durationOutline)
            icon.durationText:ClearAllPoints()
            icon.durationText:SetPoint("CENTER", icon.iconFrame, "CENTER", durationX, durationY)
            icon.durationText:SetTextColor(durationColor.r, durationColor.g, durationColor.b, 1)
        else
            icon.durationText:Hide()
        end
    end
end

-- ============================================================
-- SHOW/HIDE FUNCTIONS
-- ============================================================

-- Show a targeted spell icon for a specific caster on a frame
-- casterKey is the unit token (e.g. "nameplate7") used as table key
function DF:ShowTargetedSpellIcon(frame, casterKey, casterUnit, texture, spellName, durationObject, isChannel, spellID, startTime)
    if not frame then return end
    
    -- PERF TEST: Skip if disabled
    if DF.PerfTest and not DF.PerfTest.enableTargetedSpells then return end
    
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    if not db.targetedSpellEnabled then return end
    
    EnsureIconPool(frame, 5)
    
    -- Check if we already have an icon for this caster (using unit token as key)
    local existingIndex = frame.dfActiveTargetedSpells[casterKey]
    local icon
    
    if existingIndex and frame.targetedSpellIcons[existingIndex] then
        icon = frame.targetedSpellIcons[existingIndex]
    else
        -- Get a new icon
        icon, existingIndex = GetAvailableIcon(frame)
        frame.dfActiveTargetedSpells[casterKey] = existingIndex
    end
    
    if not icon then return end
    
    -- Store tracking data
    icon.casterKey = casterKey  -- Unit token used as table key
    icon.casterUnit = casterUnit
    icon.spellName = spellName
    icon.spellID = spellID
    icon.isChannel = isChannel
    icon.durationObject = durationObject  -- Store for OnUpdate to get remaining time
    icon.startTime = startTime or GetTime()
    icon.isInterrupted = false
    icon.interruptTimer = nil
    
    -- Hide interrupt overlay
    if icon.interruptOverlay then
        icon.interruptOverlay:Hide()
    end
    
    -- Set icon texture
    if texture and icon.icon then
        icon.icon:SetTexture(texture)
        icon.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon.icon:SetDesaturated(false)
    end
    
    -- Apply settings (including important spell highlight)
    ApplyIconSettings(icon, db, spellID)
    
    -- Set up cooldown on icon
    if icon.cooldown and durationObject then
        icon.cooldown:SetCooldownFromDurationObject(durationObject)
    end
    
    -- Mark as active (for OnUpdate cleanup checks)
    icon.isActive = true
    
    -- Show the icon (alpha will be set by caller via SetAlphaFromBoolean)
    icon:Show()
    
    return icon
end

-- Show interrupted visual on an icon
local function ShowInterruptedVisual(icon, db)
    if not icon or not db.targetedSpellShowInterrupted then return end
    
    icon.isInterrupted = true
    icon.interruptTimer = 0
    
    -- Desaturate the icon
    if icon.icon then
        icon.icon:SetDesaturated(true)
    end
    
    -- Hide duration text
    if icon.durationText then
        icon.durationText:Hide()
    end
    
    -- Stop cooldown
    if icon.cooldown then
        icon.cooldown:Clear()
    end
    
    -- Apply interrupted visual settings
    local tintColor = db.targetedSpellInterruptedTintColor or {r = 1, g = 0, b = 0}
    local tintAlpha = db.targetedSpellInterruptedTintAlpha or 0.5
    local showX = db.targetedSpellInterruptedShowX ~= false
    local xColor = db.targetedSpellInterruptedXColor or {r = 1, g = 0, b = 0}
    local xSize = db.targetedSpellInterruptedXSize or 16
    
    -- Apply tint
    if icon.interruptTint then
        icon.interruptTint:SetColorTexture(tintColor.r, tintColor.g, tintColor.b, tintAlpha)
    end
    
    -- Apply X mark settings
    if icon.interruptX then
        if showX then
            icon.interruptX:Show()
            icon.interruptX:SetTextColor(xColor.r, xColor.g, xColor.b, 1)
            icon.interruptX:SetFont("Fonts\\FRIZQT__.TTF", xSize, "OUTLINE")
        else
            icon.interruptX:Hide()
        end
    end
    
    -- Show interrupt overlay
    if icon.interruptOverlay then
        icon.interruptOverlay:Show()
    end
end

-- Hide a specific targeted spell icon by caster key (unit token)
function DF:HideTargetedSpellIcon(frame, casterKey, skipInterruptAnim)
    if not frame or not frame.dfActiveTargetedSpells then return end
    
    local iconIndex = frame.dfActiveTargetedSpells[casterKey]
    if not iconIndex then return end
    
    local icon = frame.targetedSpellIcons and frame.targetedSpellIcons[iconIndex]
    if icon then
        -- If already showing interrupt animation, let it finish
        if icon.isInterrupted and not skipInterruptAnim then
            return
        end
        
        icon:Hide()
        icon.isActive = nil
        icon.casterKey = nil
        icon.casterUnit = nil
        icon.spellName = nil
        icon.spellID = nil
        icon.isChannel = nil
        icon.durationObject = nil
        icon.startTime = nil
        icon.isInterrupted = nil
        icon.interruptTimer = nil
        icon.isImportant = nil
        
        if icon.cooldown then
            icon.cooldown:Clear()
        end
        if icon.durationText then
            icon.durationText:SetText("")
        end
        if icon.interruptOverlay then
            icon.interruptOverlay:Hide()
        end
        if icon.highlightFrame then
            icon.highlightFrame:Hide()
            -- Clean up animator reference
            TargetedSpellAnimator.frames[icon.highlightFrame] = nil
            TargetedSpellAnimator_UpdateState()
            HideAnimatedBorder(icon.highlightFrame)
            HideSolidBorder(icon.highlightFrame)
            if icon.highlightFrame.pulseAnim then
                icon.highlightFrame.pulseAnim:Stop()
            end
        end
        if icon.icon then
            icon.icon:SetDesaturated(false)
        end
    end
    
    frame.dfActiveTargetedSpells[casterKey] = nil
    
    -- Reposition remaining icons
    PositionIcons(frame)
end

-- Hide all targeted spell icons on a frame
function DF:HideAllTargetedSpells(frame)
    if not frame then return end
    
    if frame.targetedSpellIcons then
        for _, icon in ipairs(frame.targetedSpellIcons) do
            icon:Hide()
            icon.isActive = nil
            icon.casterKey = nil
            icon.casterUnit = nil
            icon.spellName = nil
            icon.spellID = nil
            icon.isChannel = nil
            icon.durationObject = nil
            icon.startTime = nil
            icon.isInterrupted = nil
            icon.interruptTimer = nil
            icon.isImportant = nil
            
            if icon.cooldown then
                icon.cooldown:Clear()
            end
            if icon.durationText then
                icon.durationText:SetText("")
            end
            if icon.interruptOverlay then
                icon.interruptOverlay:Hide()
            end
            if icon.highlightFrame then
                icon.highlightFrame:Hide()
                -- Clean up animator reference
                TargetedSpellAnimator.frames[icon.highlightFrame] = nil
                TargetedSpellAnimator_UpdateState()
                HideAnimatedBorder(icon.highlightFrame)
                HideSolidBorder(icon.highlightFrame)
                if icon.highlightFrame.pulseAnim then
                    icon.highlightFrame.pulseAnim:Stop()
                end
            end
            if icon.icon then
                icon.icon:SetDesaturated(false)
            end
        end
    end
    
    if frame.dfActiveTargetedSpells then
        wipe(frame.dfActiveTargetedSpells)
    end
end

-- Legacy compatibility function
function DF:HideTargetedSpell(frame)
    DF:HideAllTargetedSpells(frame)
end

-- ============================================================
-- LAYOUT UPDATE FUNCTIONS
-- ============================================================

-- Update layout for all icons on a frame
function DF:UpdateTargetedSpellLayout(frame)
    if not frame or not frame.targetedSpellIcons then return end
    
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
    
    -- Apply settings to all active icons
    for _, icon in ipairs(frame.targetedSpellIcons) do
        if icon.isActive then
            ApplyIconSettings(icon, db, icon.spellID)
        end
    end
    
    -- Reposition
    PositionIcons(frame)
end

-- Update all frames
function DF:UpdateAllTargetedSpellLayouts()
    DF:IterateAllFrames(function(frame)
        if frame then
            DF:UpdateTargetedSpellLayout(frame)
        end
    end)
end

-- Legacy compatibility
function DF:CreateTargetedSpellIndicator(frame)
    EnsureIconPool(frame, 5)
end

-- ============================================================
-- CAST EVENT HANDLING
-- ============================================================

-- Actually process and show the cast
local function ProcessCastInternal(casterUnit, isChannel)
    if not casterUnit or not UnitExists(casterUnit) then return end
    
    -- Only process valid unit types (nameplate, boss, arena)
    -- This prevents duplicates from "target"/"focus" which reference other units
    if not IsValidCasterUnit(casterUnit) then return end
    
    -- Only show casts from enemies
    if not UnitCanAttack("player", casterUnit) then return end
    
    -- Get cast info
    local name, displayName, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID
    local durationObject
    
    if isChannel then
        name, displayName, texture, startTimeMS, endTimeMS, isTradeSkill, notInterruptible, spellID = UnitChannelInfo(casterUnit)
        durationObject = UnitChannelDuration(casterUnit)
    else
        name, displayName, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID = UnitCastingInfo(casterUnit)
        durationObject = UnitCastingDuration(casterUnit)
    end
    
    -- No active cast
    if not name or not durationObject then return end
    
    -- Use GetTime() for start time - we can't do arithmetic on secret values from UnitCastingInfo
    local startTime = GetTime()
    
    -- Clean up any existing icons for this caster before creating new ones
    -- This prevents duplicate icons from multiple events
    if activeCasters[casterUnit] then
        -- Already tracking this caster, update instead of duplicate
        local groupUnits = GetGroupUnits()
        for _, targetUnit in ipairs(groupUnits) do
            local frame = GetFrameForUnit(targetUnit)
            if frame then
                DF:HideTargetedSpellIcon(frame, casterUnit)
            end
        end
    end
    
    -- Track this caster by unit token (not GUID - GUIDs are secret values)
    activeCasters[casterUnit] = {
        startTime = startTime,
        spellID = spellID,
        isChannel = isChannel
    }
    
    -- For each group member, create icon with visibility controlled by SetAlphaFromBoolean
    local groupUnits = GetGroupUnits()
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    -- Check content type for party frames
    local showOnPartyFrames = ShouldShowTargetedSpells(db)
    -- Check content type for raid frames
    local showOnRaidFrames = ShouldShowRaidTargetedSpells(raidDb)
    
    for _, targetUnit in ipairs(groupUnits) do
        local frame = GetFrameForUnit(targetUnit)
        if frame then
            -- Check if this frame type should show targeted spells in current content
            local shouldShow = frame.isRaidFrame and showOnRaidFrames or showOnPartyFrames
            
            if shouldShow then
                -- Show icon (creates/reuses icon for this caster on this frame)
                local icon = DF:ShowTargetedSpellIcon(frame, casterUnit, casterUnit, texture, name, durationObject, isChannel, spellID, startTime)
                
                -- Control visibility: show if enemy is targeting this unit
                -- Using UnitIsUnit for broader detection (catches AoE and target-focused casts)
                if icon then
                    local isTargeted = UnitIsUnit(casterUnit .. "target", targetUnit)
                    icon:SetAlphaFromBoolean(isTargeted, 1, 0)
                end
                
                -- Position icons (all at same spot - invisible ones don't matter)
                PositionIcons(frame)
            end
        end
    end
    
    -- Create personal display icon (always, for every cast - use SetAlphaFromBoolean for visibility)
    if ShouldShowPersonalTargetedSpells(db) then
        -- Always show icon, let SetAlphaFromBoolean control visibility based on targeting
        DF:ShowPersonalTargetedSpellIcon(casterUnit, casterUnit, spellID, texture, durationObject, isChannel, startTime)
    end
    
    -- Log cast to history for review
    -- Store secrets in separate table to avoid contaminating UI calculations
    
    local entryID = tostring(GetTime()) .. "_" .. tostring(casterUnit or "unknown") .. "_" .. tostring(math.random(10000))
    
    -- Store secrets in separate isolated table
    if not DF.castHistorySecrets then
        DF.castHistorySecrets = {}
    end
    
    local secrets = {
        targets = {},
        isImportant = nil,
    }
    
    -- Store player targeting (raw secret value)
    secrets.targets["player"] = UnitIsUnit(casterUnit .. "target", "player")
    
    -- Store party member targeting (raw secret values)
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            secrets.targets[unit] = UnitIsUnit(casterUnit .. "target", unit)
        end
    end
    
    -- Store isImportant secret
    if C_Spell and C_Spell.IsSpellImportant and spellID then
        local ok, result = pcall(C_Spell.IsSpellImportant, spellID)
        if ok then
            secrets.isImportant = result
        end
    end
    
    DF.castHistorySecrets[entryID] = secrets
    
    -- Store only regular values in the history entry (no secrets!)
    local targetNames = {}
    targetNames["player"] = UnitName("player")
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            targetNames[unit] = UnitName(unit)
        end
    end
    
    local historyEntry = {
        entryID = entryID,  -- Link to secrets table
        spellID = spellID,
        name = name,
        texture = texture,
        timestamp = GetTime(),
        isChannel = isChannel,
        casterUnit = casterUnit,
        casterName = UnitName(casterUnit),
        targetNames = targetNames,  -- Just names, no secrets
        interrupted = false,  -- Regular boolean
    }
    
    table.insert(castHistory, 1, historyEntry)  -- Insert at beginning (newest first)
    
    -- Trim to max size
    while #castHistory > MAX_HISTORY do
        local removed = table.remove(castHistory)
        if removed and removed.entryID then
            DF.castHistorySecrets[removed.entryID] = nil  -- Clean up secrets
        end
    end
end

-- Schedule cast processing after a short delay
-- The 0.2s delay ensures the caster's target info (nameplateXtarget) has
-- settled before we read it. Without this, we can read stale target data
-- from the previous frame, causing icons to appear on the wrong party member.
-- After the delay, we validate the cast is still active to avoid phantom
-- icon flashes from very fast casts that ended during the delay.
local CAST_PROCESS_DELAY = 0.2

local function ProcessCast(casterUnit, isChannel)
    if not casterUnit then return end
    if not IsValidCasterUnit(casterUnit) then return end
    
    C_Timer.After(CAST_PROCESS_DELAY, function()
        -- Validate the cast is still active after the delay
        -- If it finished/was interrupted during the delay, don't show anything
        if isChannel then
            if not UnitChannelInfo(casterUnit) then return end
        else
            if not UnitCastingInfo(casterUnit) then return end
        end
        
        ProcessCastInternal(casterUnit, isChannel)
    end)
end

-- Handle target change (enemy switched targets mid-cast)
local function HandleTargetChange(casterUnit)
    if not casterUnit or not UnitExists(casterUnit) then return end
    if not IsValidCasterUnit(casterUnit) then return end
    if not UnitCanAttack("player", casterUnit) then return end
    
    -- Check if this caster has an active cast we're tracking (by unit token)
    if not activeCasters[casterUnit] then return end
    
    local db = DF:GetDB()
    
    -- Update visibility for all group members (unit frame icons)
    local groupUnits = GetGroupUnits()
    
    for _, targetUnit in ipairs(groupUnits) do
        local frame = GetFrameForUnit(targetUnit)
        if frame and frame.dfActiveTargetedSpells then
            local iconIndex = frame.dfActiveTargetedSpells[casterUnit]
            if iconIndex then
                local icon = frame.targetedSpellIcons and frame.targetedSpellIcons[iconIndex]
                if icon and icon.isActive and not icon.isInterrupted then
                    local isTargeted = UnitIsUnit(casterUnit .. "target", targetUnit)
                    icon:SetAlphaFromBoolean(isTargeted, 1, 0)
                end
            end
        end
    end
    
    -- Update personal display visibility using SetAlphaFromBoolean
    if db.personalTargetedSpellEnabled then
        local iconIndex = personalActiveSpells[casterUnit]
        if iconIndex then
            local icon = personalIcons[iconIndex]
            if icon and icon.isActive and not icon.isInterrupted then
                local isTargetingPlayer = UnitIsUnit(casterUnit .. "target", "player")
                icon:SetAlphaFromBoolean(isTargetingPlayer, 1, 0)
            end
        end
    end
end

-- Handle cast ending (including interrupts)
local function HandleCastStop(casterUnit, wasInterrupted)
    if not casterUnit then return end
    if not IsValidCasterUnit(casterUnit) then return end
    
    -- Mark history entry as interrupted if applicable
    -- Can't compare spellID (it's a secret), so just mark the most recent entry for this caster
    if wasInterrupted then
        local casterInfo = activeCasters[casterUnit]
        if casterInfo then
            -- Find the most recent history entry for this caster (by timestamp match)
            for _, entry in ipairs(castHistory) do
                if entry.casterUnit == casterUnit and entry.timestamp == casterInfo.startTime and not entry.interrupted then
                    entry.interrupted = true
                    break  -- Only mark the most recent one
                end
            end
        end
    end
    
    -- Remove from active casters (using unit token, not GUID)
    activeCasters[casterUnit] = nil
    
    -- Get db for interrupt setting
    local db = DF:GetDB()
    
    -- Process icons on all frames
    local function ProcessFrame(frame)
        if not frame or not frame.dfActiveTargetedSpells then return end
        
        local iconIndex = frame.dfActiveTargetedSpells[casterUnit]
        if not iconIndex then return end
        
        local icon = frame.targetedSpellIcons and frame.targetedSpellIcons[iconIndex]
        if not icon or not icon.isActive then return end
        
        -- Check frame-specific db for raid frames
        local frameDb = frame.isRaidFrame and DF:GetRaidDB() or db
        
        if wasInterrupted and frameDb.targetedSpellShowInterrupted then
            -- Show interrupted visual
            ShowInterruptedVisual(icon, frameDb)
        else
            -- Just hide immediately
            DF:HideTargetedSpellIcon(frame, casterUnit)
        end
    end
    
    -- Process icons on all frames using iterators
    DF:IterateAllFrames(function(frame)
        ProcessFrame(frame)
    end)
    
    -- Also hide personal targeted spell icon for this caster
    if db.personalTargetedSpellEnabled then
        if wasInterrupted and db.personalTargetedSpellShowInterrupted then
            -- Will show interrupted animation then hide
            DF:HidePersonalTargetedSpellIcon(casterUnit, false)
        else
            DF:HidePersonalTargetedSpellIcon(casterUnit, true)
        end
    end
end

-- ============================================================
-- SCANNING FUNCTIONS
-- ============================================================

-- Scan all enemy units for casts
local function ScanAllEnemyCasts()
    local enemyUnits = GetEnemyUnits()
    
    for _, unit in ipairs(enemyUnits) do
        if UnitExists(unit) then
            -- Check for casting
            local castName = UnitCastingInfo(unit)
            if castName then
                ProcessCast(unit, false)
            else
                -- Check for channeling
                local channelName = UnitChannelInfo(unit)
                if channelName then
                    ProcessCast(unit, true)
                end
            end
        end
    end
end

-- ============================================================
-- EVENT HANDLING
-- ============================================================

local function OnEvent(self, event, unit, ...)
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_EMPOWER_START" then
        ProcessCast(unit, false)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        ProcessCast(unit, true)
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        HandleCastStop(unit, true)  -- Was interrupted
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED" or 
           event == "UNIT_SPELLCAST_SUCCEEDED" or
           event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        HandleCastStop(unit, false)  -- Normal end
    elseif event == "UNIT_TARGET" then
        -- Enemy changed target mid-cast
        HandleTargetChange(unit)
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- New nameplate, check if casting
        local castName = UnitCastingInfo(unit)
        if castName then
            ProcessCast(unit, false)
        else
            local channelName = UnitChannelInfo(unit)
            if channelName then
                ProcessCast(unit, true)
            end
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        HandleCastStop(unit, false)
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED" then
        ScanAllEnemyCasts()
    end
end

eventFrame:SetScript("OnEvent", OnEvent)

-- ============================================================
-- NAMEPLATE OFFSCREEN CVAR
-- ============================================================

function DF:SetNameplateOffscreen(enabled)
    if C_CVar and C_CVar.SetCVar then
        C_CVar.SetCVar("nameplateShowOffscreen", enabled and "1" or "0")
    end
end

function DF:GetNameplateOffscreen()
    if C_CVar and C_CVar.GetCVar then
        return C_CVar.GetCVar("nameplateShowOffscreen") == "1"
    end
    return false
end

-- ============================================================
-- ENABLE/DISABLE
-- ============================================================

function DF:EnableTargetedSpells()
    -- Register events
    eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_STOP")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_FAILED")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_EMPOWER_START")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_EMPOWER_STOP")
    eventFrame:RegisterEvent("UNIT_TARGET")
    eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
    eventFrame:Show()
    
    -- Track enabled state for unified handler
    DF.targetedSpellsEnabled = true
    
    -- Initial scan
    ScanAllEnemyCasts()
end

function DF:DisableTargetedSpells()
    eventFrame:UnregisterAllEvents()
    eventFrame:Hide()
    
    -- Track enabled state
    DF.targetedSpellsEnabled = false
    
    -- Hide all icons
    DF:IterateAllFrames(function(frame)
        if frame then
            DF:HideAllTargetedSpells(frame)
        end
    end)
    
    wipe(activeCasters)
end

-- Export scan function for unified roster handler
function DF:ScanAllEnemyCasts()
    ScanAllEnemyCasts()
end

-- Export active casters clear for unified roster handler
function DF:ClearActiveCasters()
    wipe(activeCasters)
end

function DF:ToggleTargetedSpells(enabled)
    if enabled then
        DF:EnableTargetedSpells()
    else
        DF:DisableTargetedSpells()
    end
end

-- ============================================================
-- PERSONAL TARGETED SPELLS DISPLAY
-- Shows incoming spells targeting the player in center of screen
-- ============================================================

-- personalContainer, personalIcons, personalActiveSpells declared at top of file

-- Calculate mover size based on settings
local function GetPersonalMoverSize()
    local db = DF:GetDB()
    local iconSize = db.personalTargetedSpellSize or 40
    local scale = db.personalTargetedSpellScale or 1.0
    local maxIcons = db.personalTargetedSpellMaxIcons or 5
    local spacing = db.personalTargetedSpellSpacing or 4
    local growthDirection = db.personalTargetedSpellGrowth or "RIGHT"
    
    local scaledSize = iconSize * scale
    local scaledSpacing = spacing * scale
    
    local width, height
    if growthDirection == "LEFT" or growthDirection == "RIGHT" or growthDirection == "CENTER_H" then
        width = maxIcons * scaledSize + (maxIcons - 1) * scaledSpacing
        height = scaledSize
    else
        width = scaledSize
        height = maxIcons * scaledSize + (maxIcons - 1) * scaledSpacing
    end
    
    return math.max(width, 50), math.max(height, 50)
end

-- Create the personal targeted spells container
local function CreatePersonalContainer()
    if personalContainer then return personalContainer end
    
    local db = DF:GetDB()
    local x = db.personalTargetedSpellX or 0
    local y = db.personalTargetedSpellY or -150
    
    local container = CreateFrame("Frame", "DandersFramesPersonalTargetedSpells", UIParent)
    local w, h = GetPersonalMoverSize()
    container:SetSize(w, h)
    container:SetPoint("CENTER", UIParent, "CENTER", x, y)
    container:SetFrameStrata("HIGH")
    container:Hide()
    container:EnableMouse(false)
    container:SetHitRectInsets(10000, 10000, 10000, 10000)
    
    personalContainer = container
    DF.personalTargetedSpellsContainer = container
    
    return container
end

-- Create icon for personal display (similar to unit frame icons)
local function CreatePersonalIcon(index)
    CreatePersonalContainer()
    
    local icon = CreateFrame("Frame", nil, personalContainer)
    icon:SetSize(40, 40)
    icon:Hide()
    icon.index = index
    icon:EnableMouse(false)
    icon:SetHitRectInsets(10000, 10000, 10000, 10000)
    
    -- Importance filter frame - nested inside icon
    local importanceFilterFrame = CreateFrame("Frame", nil, icon)
    importanceFilterFrame:SetAllPoints()
    importanceFilterFrame:EnableMouse(false)
    importanceFilterFrame:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.importanceFilterFrame = importanceFilterFrame
    
    -- Main icon frame with border
    local iconFrame = CreateFrame("Frame", nil, importanceFilterFrame)
    iconFrame:SetAllPoints()
    iconFrame:EnableMouse(false)
    iconFrame:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.iconFrame = iconFrame
    
    -- Border textures - 4 edge borders (consistent with other icons)
    local defBorderSize = 2
    local borderLeft = iconFrame:CreateTexture(nil, "BACKGROUND")
    borderLeft:SetPoint("TOPLEFT", 0, 0)
    borderLeft:SetPoint("BOTTOMLEFT", 0, 0)
    borderLeft:SetWidth(defBorderSize)
    borderLeft:SetColorTexture(1, 0.3, 0, 1)
    icon.borderLeft = borderLeft
    
    local borderRight = iconFrame:CreateTexture(nil, "BACKGROUND")
    borderRight:SetPoint("TOPRIGHT", 0, 0)
    borderRight:SetPoint("BOTTOMRIGHT", 0, 0)
    borderRight:SetWidth(defBorderSize)
    borderRight:SetColorTexture(1, 0.3, 0, 1)
    icon.borderRight = borderRight
    
    local borderTop = iconFrame:CreateTexture(nil, "BACKGROUND")
    borderTop:SetPoint("TOPLEFT", defBorderSize, 0)
    borderTop:SetPoint("TOPRIGHT", -defBorderSize, 0)
    borderTop:SetHeight(defBorderSize)
    borderTop:SetColorTexture(1, 0.3, 0, 1)
    icon.borderTop = borderTop
    
    local borderBottom = iconFrame:CreateTexture(nil, "BACKGROUND")
    borderBottom:SetPoint("BOTTOMLEFT", defBorderSize, 0)
    borderBottom:SetPoint("BOTTOMRIGHT", -defBorderSize, 0)
    borderBottom:SetHeight(defBorderSize)
    borderBottom:SetColorTexture(1, 0.3, 0, 1)
    icon.borderBottom = borderBottom
    
    -- Important spell highlight frame - set frame level ABOVE iconFrame so it renders on top
    local highlightFrame = CreateFrame("Frame", nil, iconFrame)
    highlightFrame:SetPoint("TOPLEFT", -5, 5)
    highlightFrame:SetPoint("BOTTOMRIGHT", 5, -5)
    highlightFrame:SetFrameLevel(iconFrame:GetFrameLevel() + 5)
    highlightFrame:Hide()
    highlightFrame:EnableMouse(false)
    highlightFrame:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.highlightFrame = highlightFrame
    
    -- Icon texture - positioned with inset for border
    local texture = iconFrame:CreateTexture(nil, "ARTWORK")
    texture:SetPoint("TOPLEFT", defBorderSize, -defBorderSize)
    texture:SetPoint("BOTTOMRIGHT", -defBorderSize, defBorderSize)
    texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon.texture = texture
    icon.icon = texture
    
    -- Cooldown - attached to icon texture
    local cooldown = CreateFrame("Cooldown", nil, iconFrame, "CooldownFrameTemplate")
    cooldown:SetPoint("TOPLEFT", texture, "TOPLEFT", 0, 0)
    cooldown:SetPoint("BOTTOMRIGHT", texture, "BOTTOMRIGHT", 0, 0)
    cooldown:SetDrawEdge(false)
    cooldown:SetDrawBling(false)
    cooldown:SetDrawSwipe(true)
    cooldown:SetReverse(true)
    cooldown:SetHideCountdownNumbers(true)
    cooldown:EnableMouse(false)
    cooldown:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.cooldown = cooldown
    
    -- Text overlay (above cooldown)
    local textOverlay = CreateFrame("Frame", nil, iconFrame)
    textOverlay:SetAllPoints()
    textOverlay:SetFrameLevel(cooldown:GetFrameLevel() + 5)
    textOverlay:EnableMouse(false)
    textOverlay:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.textOverlay = textOverlay
    
    -- Duration text
    local durationText = textOverlay:CreateFontString(nil, "OVERLAY")
    durationText:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    durationText:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
    durationText:SetTextColor(1, 1, 1, 1)
    icon.durationText = durationText
    
    -- Interrupted overlay
    local interruptOverlay = CreateFrame("Frame", nil, iconFrame)
    interruptOverlay:SetAllPoints()
    interruptOverlay:SetFrameLevel(cooldown:GetFrameLevel() + 10)
    interruptOverlay:Hide()
    interruptOverlay:EnableMouse(false)
    interruptOverlay:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.interruptOverlay = interruptOverlay
    
    local interruptTint = interruptOverlay:CreateTexture(nil, "OVERLAY")
    interruptTint:SetAllPoints()
    interruptTint:SetColorTexture(1, 0, 0, 0.5)
    icon.interruptTint = interruptTint
    
    local interruptX = interruptOverlay:CreateFontString(nil, "OVERLAY")
    interruptX:SetFont("Fonts\\FRIZQT__.TTF", 20, "OUTLINE")
    interruptX:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
    interruptX:SetText("X")
    interruptX:SetTextColor(1, 0, 0, 1)
    icon.interruptX = interruptX
    
    -- OnUpdate for duration and cleanup
    local durationThrottle = 0
    icon:SetScript("OnUpdate", function(self, elapsed)
        if not self.isActive then return end
        
        -- Skip cleanup check for test mode icons
        if self.isTestIcon then
            -- Throttle test mode duration updates too
            durationThrottle = durationThrottle + elapsed
            if durationThrottle < 0.1 then return end
            durationThrottle = 0
            
            -- Only update duration text for test icons
            if self.testTimeRemaining and self.durationText and self.durationText:IsShown() then
                self.testTimeRemaining = self.testTimeRemaining - elapsed * 10  -- Compensate for throttle
                if self.testTimeRemaining < 0 then self.testTimeRemaining = 3.0 end  -- Loop
                self.durationText:SetFormattedText("%.1f", self.testTimeRemaining)
            end
            return
        end
        
        -- Handle interrupted animation (needs to run every frame for smooth animation)
        if self.isInterrupted then
            self.interruptTimer = (self.interruptTimer or 0) + elapsed
            local db = DF:GetDB()
            local duration = db.personalTargetedSpellInterruptedDuration or 0.5
            
            if self.interruptTimer >= duration then
                DF:HidePersonalTargetedSpellIcon(self.casterKey, true, true)  -- fromTimer=true
            end
            return
        end
        
        -- Throttle duration text updates to ~10 FPS for performance
        durationThrottle = durationThrottle + elapsed
        if durationThrottle < 0.1 then return end
        durationThrottle = 0
        
        -- Update duration text from duration object
        -- TODO: Can use durationObject:EvaluateRemainingPercent(colorCurve) for dynamic color-by-time
        if self.durationObject and self.durationText and self.durationText:IsShown() then
            local ok, remaining = pcall(self.durationObject.GetRemainingDuration, self.durationObject)
            if ok and remaining then
                self.durationText:SetFormattedText("%.1f", remaining)
                if self.durationColor then
                    self.durationText:SetTextColor(self.durationColor.r, self.durationColor.g, self.durationColor.b, 1)
                end
            end
        end
        
        -- Note: Target change detection is handled by UNIT_TARGET event + HandleTargetChange
        -- which uses SetAlphaFromBoolean. We can't do boolean checks on secret values here.
    end)
    
    return icon
end

-- Get or create personal icon
local function GetPersonalIcon(index)
    if not personalIcons[index] then
        personalIcons[index] = CreatePersonalIcon(index)
    end
    return personalIcons[index]
end

-- Apply settings to a personal icon
local function ApplyPersonalIconSettings(icon, db, spellID)
    local borderColor = db.personalTargetedSpellBorderColor or {r = 1, g = 0.3, b = 0}
    local borderSize = db.personalTargetedSpellBorderSize or 2
    local showBorder = db.personalTargetedSpellShowBorder ~= false
    local showSwipe = db.personalTargetedSpellShowSwipe ~= false
    local showDuration = db.personalTargetedSpellShowDuration ~= false
    local durationFont = db.personalTargetedSpellDurationFont or "Fonts\\FRIZQT__.TTF"
    local durationScale = db.personalTargetedSpellDurationScale or 1.2
    local durationOutline = db.personalTargetedSpellDurationOutline or "OUTLINE"
    local durationX = db.personalTargetedSpellDurationX or 0
    local durationY = db.personalTargetedSpellDurationY or 0
    local durationColor = db.personalTargetedSpellDurationColor or {r = 1, g = 1, b = 1}
    local highlightImportant = db.personalTargetedSpellHighlightImportant ~= false
    local highlightStyle = db.personalTargetedSpellHighlightStyle or "glow"
    local highlightColor = db.personalTargetedSpellHighlightColor or {r = 1, g = 0.8, b = 0}
    local highlightSize = db.personalTargetedSpellHighlightSize or 3
    local highlightInset = db.personalTargetedSpellHighlightInset or 0
    local importantOnly = db.personalTargetedSpellImportantOnly
    
    if durationOutline == "NONE" then durationOutline = "" end
    
    -- Apply pixel perfect to border size
    if db.pixelPerfect then
        borderSize = DF:PixelPerfect(borderSize)
    end
    
    icon.durationColor = durationColor
    
    -- Important spell filter
    if icon.importanceFilterFrame then
        if importantOnly and spellID then
            local isImportant = IsSpellImportant(spellID)
            icon.importanceFilterFrame:SetAlphaFromBoolean(isImportant)
        else
            icon.importanceFilterFrame:SetAlpha(1)
        end
    end
    
    -- Important spell highlight
    if icon.highlightFrame then
        -- Calculate position with inset (negative inset = larger, positive = smaller/inward)
        local offset = borderSize + highlightSize - highlightInset
        
        -- Position the highlight frame
        icon.highlightFrame:ClearAllPoints()
        icon.highlightFrame:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", -offset, offset)
        icon.highlightFrame:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", offset, -offset)
        
        -- Hide all highlight styles first
        HideAnimatedBorder(icon.highlightFrame)
        HideSolidBorder(icon.highlightFrame)
        HideGlowBorder(icon.highlightFrame)
        if icon.highlightFrame.pulseAnim then icon.highlightFrame.pulseAnim:Stop() end
        TargetedSpellAnimator.frames[icon.highlightFrame] = nil
        TargetedSpellAnimator_UpdateState()
        
        if highlightImportant and spellID and highlightStyle ~= "none" then
            local isImportant = IsSpellImportant(spellID)
            
            if highlightStyle == "glow" then
                -- Glow effect using edge borders with ADD blend mode
                InitGlowBorder(icon.highlightFrame)
                UpdateGlowBorder(icon.highlightFrame, highlightSize, highlightColor.r, highlightColor.g, highlightColor.b, 0.8)
                icon.highlightFrame:Show()
                icon.highlightFrame:SetAlphaFromBoolean(isImportant)
                
            elseif highlightStyle == "marchingAnts" then
                -- Animated marching ants border
                InitAnimatedBorder(icon.highlightFrame)
                icon.highlightFrame.animThickness = math.max(1, highlightSize)
                icon.highlightFrame.animR = highlightColor.r
                icon.highlightFrame.animG = highlightColor.g
                icon.highlightFrame.animB = highlightColor.b
                icon.highlightFrame.animA = 1
                icon.highlightFrame:Show()
                icon.highlightFrame:SetAlphaFromBoolean(isImportant)
                TargetedSpellAnimator.frames[icon.highlightFrame] = true
                TargetedSpellAnimator_UpdateState()
                
            elseif highlightStyle == "solidBorder" then
                -- Solid colored border (4 edge textures, no fill)
                InitSolidBorder(icon.highlightFrame)
                UpdateSolidBorder(icon.highlightFrame, highlightSize, highlightColor.r, highlightColor.g, highlightColor.b, 1)
                icon.highlightFrame:Show()
                icon.highlightFrame:SetAlphaFromBoolean(isImportant)
                
            elseif highlightStyle == "pulse" then
                -- Pulsing glow using edge borders with ADD blend
                InitGlowBorder(icon.highlightFrame)
                UpdateGlowBorder(icon.highlightFrame, highlightSize, highlightColor.r, highlightColor.g, highlightColor.b, 0.8)
                InitPulseAnimation(icon.highlightFrame)
                -- Store color for pulse animation to use
                icon.highlightFrame.pulseR = highlightColor.r
                icon.highlightFrame.pulseG = highlightColor.g
                icon.highlightFrame.pulseB = highlightColor.b
                icon.highlightFrame:Show()
                icon.highlightFrame:SetAlphaFromBoolean(isImportant)
                icon.highlightFrame.pulseAnim:Play()
            end
        else
            icon.highlightFrame:Hide()
        end
    end
    
    -- Border - 4 edge textures (consistent with other icons)
    if showBorder then
        if icon.borderLeft then
            icon.borderLeft:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, 1)
            icon.borderLeft:SetWidth(borderSize)
            icon.borderLeft:Show()
        end
        if icon.borderRight then
            icon.borderRight:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, 1)
            icon.borderRight:SetWidth(borderSize)
            icon.borderRight:Show()
        end
        if icon.borderTop then
            icon.borderTop:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, 1)
            icon.borderTop:SetHeight(borderSize)
            icon.borderTop:ClearAllPoints()
            icon.borderTop:SetPoint("TOPLEFT", borderSize, 0)
            icon.borderTop:SetPoint("TOPRIGHT", -borderSize, 0)
            icon.borderTop:Show()
        end
        if icon.borderBottom then
            icon.borderBottom:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, 1)
            icon.borderBottom:SetHeight(borderSize)
            icon.borderBottom:ClearAllPoints()
            icon.borderBottom:SetPoint("BOTTOMLEFT", borderSize, 0)
            icon.borderBottom:SetPoint("BOTTOMRIGHT", -borderSize, 0)
            icon.borderBottom:Show()
        end
        
        -- Adjust icon texture position for border
        if icon.icon then
            icon.icon:ClearAllPoints()
            icon.icon:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", borderSize, -borderSize)
            icon.icon:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", -borderSize, borderSize)
        end
        
        -- Adjust cooldown to match
        if icon.cooldown then
            icon.cooldown:ClearAllPoints()
            icon.cooldown:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", borderSize, -borderSize)
            icon.cooldown:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", -borderSize, borderSize)
        end
    else
        -- Hide all border edges
        if icon.borderLeft then icon.borderLeft:Hide() end
        if icon.borderRight then icon.borderRight:Hide() end
        if icon.borderTop then icon.borderTop:Hide() end
        if icon.borderBottom then icon.borderBottom:Hide() end
        
        -- Full size icon when no border
        if icon.icon then
            icon.icon:ClearAllPoints()
            icon.icon:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", 0, 0)
            icon.icon:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", 0, 0)
        end
        
        -- Adjust cooldown to match
        if icon.cooldown then
            icon.cooldown:ClearAllPoints()
            icon.cooldown:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", 0, 0)
            icon.cooldown:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", 0, 0)
        end
    end
    
    -- Cooldown swipe
    if icon.cooldown then
        icon.cooldown:SetDrawSwipe(showSwipe)
        icon.cooldown:SetHideCountdownNumbers(true)
    end
    
    -- Duration text
    if icon.durationText then
        if showDuration then
            icon.durationText:Show()
            local fontSize = 10 * durationScale
            DF:SafeSetFont(icon.durationText, durationFont, fontSize, durationOutline)
            icon.durationText:ClearAllPoints()
            icon.durationText:SetPoint("CENTER", icon.iconFrame, "CENTER", durationX, durationY)
            icon.durationText:SetTextColor(durationColor.r, durationColor.g, durationColor.b, 1)
        else
            icon.durationText:Hide()
        end
    end
    
    -- Interrupt visual settings
    local interruptTintColor = db.personalTargetedSpellInterruptedTintColor or {r = 1, g = 0, b = 0}
    local interruptTintAlpha = db.personalTargetedSpellInterruptedTintAlpha or 0.5
    local interruptShowX = db.personalTargetedSpellInterruptedShowX ~= false
    local interruptXColor = db.personalTargetedSpellInterruptedXColor or {r = 1, g = 0, b = 0}
    local interruptXSize = db.personalTargetedSpellInterruptedXSize or 20
    
    -- Apply interrupt tint settings
    if icon.interruptTint then
        icon.interruptTint:SetColorTexture(interruptTintColor.r, interruptTintColor.g, interruptTintColor.b, interruptTintAlpha)
    end
    
    -- Apply interrupt X mark settings
    if icon.interruptX then
        if interruptShowX then
            icon.interruptX:Show()
            icon.interruptX:SetTextColor(interruptXColor.r, interruptXColor.g, interruptXColor.b, 1)
            icon.interruptX:SetFont("Fonts\\FRIZQT__.TTF", interruptXSize, "OUTLINE")
        else
            icon.interruptX:Hide()
        end
    end
end

-- Position personal icons
local function PositionPersonalIcons()
    local db = DF:GetDB()
    if not personalContainer then return end
    
    local iconSize = db.personalTargetedSpellSize or 40
    local scale = db.personalTargetedSpellScale or 1.0
    local growthDirection = db.personalTargetedSpellGrowth or "RIGHT"
    local spacing = db.personalTargetedSpellSpacing or 4
    local maxIcons = db.personalTargetedSpellMaxIcons or 5
    
    -- Apply pixel perfect
    if db.pixelPerfect then
        iconSize = DF:PixelPerfect(iconSize)
        spacing = DF:PixelPerfect(spacing)
    end
    
    local scaledSize = iconSize * scale
    local scaledSpacing = spacing * scale
    
    -- Collect active spells
    local casterData = {}
    for casterKey, iconIndex in pairs(personalActiveSpells) do
        local icon = personalIcons[iconIndex]
        if icon and icon.isActive then
            table.insert(casterData, {
                casterKey = casterKey,
                iconIndex = iconIndex,
                startTime = icon.startTime or 0
            })
        end
    end
    
    -- Sort for consistent order
    table.sort(casterData, function(a, b)
        return a.casterKey < b.casterKey
    end)
    
    local numIcons = math.min(#casterData, maxIcons)
    
    for i = 1, #casterData do
        local data = casterData[i]
        local icon = personalIcons[data.iconIndex]
        
        if icon then
            if i <= maxIcons then
                local offsetX, offsetY = 0, 0
                local index = i - 1
                
                if growthDirection == "UP" then
                    offsetY = index * (scaledSize + scaledSpacing)
                elseif growthDirection == "DOWN" then
                    offsetY = -index * (scaledSize + scaledSpacing)
                elseif growthDirection == "LEFT" then
                    offsetX = -index * (scaledSize + scaledSpacing)
                elseif growthDirection == "RIGHT" then
                    offsetX = index * (scaledSize + scaledSpacing)
                elseif growthDirection == "CENTER_H" then
                    local centerOffset = (numIcons - 1) * (scaledSize + scaledSpacing) / 2
                    offsetX = index * (scaledSize + scaledSpacing) - centerOffset
                elseif growthDirection == "CENTER_V" then
                    local centerOffset = (numIcons - 1) * (scaledSize + scaledSpacing) / 2
                    offsetY = index * (scaledSize + scaledSpacing) - centerOffset
                end
                
                icon:ClearAllPoints()
                icon:SetPoint("CENTER", personalContainer, "CENTER", offsetX, offsetY)
                icon:SetSize(scaledSize, scaledSize)
                icon.iconFrame:SetAllPoints(icon)
                
                icon:Show()
            else
                icon:Hide()
            end
        end
    end
end

-- Show a personal targeted spell icon
function DF:ShowPersonalTargetedSpellIcon(casterUnit, casterKey, spellID, texture, durationObject, isChannel, startTime)
    local db = DF:GetDB()
    if not db.personalTargetedSpellEnabled then return end
    
    CreatePersonalContainer()
    
    -- Check if already tracking this caster
    if personalActiveSpells[casterKey] then
        return
    end
    
    -- Find available icon
    local iconIndex = nil
    for i = 1, db.personalTargetedSpellMaxIcons or 5 do
        local icon = GetPersonalIcon(i)
        if not icon.isActive then
            iconIndex = i
            break
        end
    end
    
    if not iconIndex then
        iconIndex = #personalIcons + 1
        GetPersonalIcon(iconIndex)
    end
    
    local icon = personalIcons[iconIndex]
    personalActiveSpells[casterKey] = iconIndex
    
    -- Setup icon
    icon.casterUnit = casterUnit
    icon.casterKey = casterKey
    icon.spellID = spellID
    icon.isChannel = isChannel
    icon.durationObject = durationObject
    icon.startTime = startTime or GetTime()
    icon.isActive = true
    icon.isInterrupted = false
    icon.interruptTimer = 0
    icon.isTestIcon = false
    
    -- Hide interrupt overlay
    if icon.interruptOverlay then
        icon.interruptOverlay:Hide()
    end
    
    -- Set icon texture
    if texture and icon.icon then
        icon.icon:SetTexture(texture)
        icon.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon.icon:SetDesaturated(false)
    end
    
    -- Apply settings
    ApplyPersonalIconSettings(icon, db, spellID)
    
    -- Set up cooldown from duration object
    if icon.cooldown and durationObject then
        icon.cooldown:SetCooldownFromDurationObject(durationObject)
    end
    
    -- Use SetAlphaFromBoolean to control visibility based on targeting
    local isTargetingPlayer = UnitIsUnit(casterUnit .. "target", "player")
    icon:SetAlphaFromBoolean(isTargetingPlayer, 1, 0)
    
    -- Show container
    personalContainer:Show()
    
    PositionPersonalIcons()
end

-- Hide a personal targeted spell icon
function DF:HidePersonalTargetedSpellIcon(casterKey, immediate, fromTimer)
    local iconIndex = personalActiveSpells[casterKey]
    if not iconIndex then return end
    
    local icon = personalIcons[iconIndex]
    if not icon then return end
    
    local db = DF:GetDB()
    
    -- If already showing interrupt animation, only hide if timer completed (fromTimer=true)
    -- This prevents UNIT_SPELLCAST_STOP from hiding the icon during interrupt animation
    if icon.isInterrupted and not icon.isTestIcon and not fromTimer then
        return
    end
    
    -- Show interrupted animation if not immediate and enabled
    if not immediate and db.personalTargetedSpellShowInterrupted and not icon.isInterrupted and not icon.isTestIcon then
        icon.isInterrupted = true
        icon.interruptTimer = 0
        icon.interruptOverlay:Show()
        icon.durationText:Hide()
        if icon.icon then
            icon.icon:SetDesaturated(true)
        end
        return
    end
    
    -- Fully hide the icon
    icon.isActive = false
    icon.isInterrupted = false
    icon:Hide()
    if icon.highlightFrame then
        icon.highlightFrame:Hide()
        -- Clean up animator reference
        TargetedSpellAnimator.frames[icon.highlightFrame] = nil
        TargetedSpellAnimator_UpdateState()
        HideAnimatedBorder(icon.highlightFrame)
        HideSolidBorder(icon.highlightFrame)
        if icon.highlightFrame.pulseAnim then
            icon.highlightFrame.pulseAnim:Stop()
        end
    end
    icon.interruptOverlay:Hide()
    if icon.icon then
        icon.icon:SetDesaturated(false)
    end
    
    personalActiveSpells[casterKey] = nil
    
    PositionPersonalIcons()
    
    -- Hide container if no active spells
    local hasActive = false
    for _ in pairs(personalActiveSpells) do
        hasActive = true
        break
    end
    if not hasActive and personalContainer then
        personalContainer:Hide()
    end
end

-- Hide all personal targeted spell icons
function DF:HideAllPersonalTargetedSpells()
    for casterKey, iconIndex in pairs(personalActiveSpells) do
        local icon = personalIcons[iconIndex]
        if icon then
            icon.isActive = false
            icon.isInterrupted = false
            icon:Hide()
            if icon.highlightFrame then
                icon.highlightFrame:Hide()
                -- Clean up animator reference
                TargetedSpellAnimator.frames[icon.highlightFrame] = nil
                TargetedSpellAnimator_UpdateState()
                HideAnimatedBorder(icon.highlightFrame)
                HideSolidBorder(icon.highlightFrame)
                if icon.highlightFrame.pulseAnim then
                    icon.highlightFrame.pulseAnim:Stop()
                end
            end
            icon.interruptOverlay:Hide()
            if icon.icon then
                icon.icon:SetDesaturated(false)
            end
        end
    end
    wipe(personalActiveSpells)
    
    if personalContainer then
        personalContainer:Hide()
    end
end

-- Update personal display position from settings
function DF:UpdatePersonalTargetedSpellsPosition()
    local db = DF:GetDB()
    local x = db.personalTargetedSpellX or 0
    local y = db.personalTargetedSpellY or -150
    local iconAlpha = db.personalTargetedSpellAlpha or 1.0
    
    if personalContainer then
        personalContainer:ClearAllPoints()
        personalContainer:SetPoint("CENTER", UIParent, "CENTER", x, y)
        local w, h = GetPersonalMoverSize()
        personalContainer:SetSize(w, h)
        personalContainer:SetAlpha(iconAlpha)
    end
    
    -- Re-apply settings to active icons
    for casterKey, iconIndex in pairs(personalActiveSpells) do
        local icon = personalIcons[iconIndex]
        if icon and icon.isActive then
            ApplyPersonalIconSettings(icon, db, icon.spellID)
            icon:SetAlpha(iconAlpha)
        end
    end
    
    PositionPersonalIcons()
end

-- Update mover size to match settings
local function UpdateMoverSize()
    if not DF.personalTargetedSpellsMover then return end
    local w, h = GetPersonalMoverSize()
    DF.personalTargetedSpellsMover:SetSize(w, h)
end

-- Create mover for personal targeted spells
function DF:CreatePersonalTargetedSpellsMover()
    if DF.personalTargetedSpellsMover then return end
    
    CreatePersonalContainer()
    
    local w, h = GetPersonalMoverSize()
    
    local mover = CreateFrame("Frame", "DandersFramesPersonalTargetedSpellsMover", UIParent, "BackdropTemplate")
    mover:SetSize(w, h)
    mover:SetFrameStrata("DIALOG")
    mover:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    mover:SetBackdropColor(1.0, 0.5, 0.2, 0.3)
    mover:SetBackdropBorderColor(1.0, 0.5, 0.2, 0.8)
    mover:EnableMouse(true)
    mover:SetMovable(true)
    mover:RegisterForDrag("LeftButton")
    mover:Hide()
    
    local label = mover:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText("Personal\nTargeted Spells")
    label:SetTextColor(1, 1, 1, 1)
    mover.label = label
    
    -- Add center snap lines (visual guides)
    local centerLineH = mover:CreateTexture(nil, "OVERLAY")
    centerLineH:SetColorTexture(1, 1, 1, 0.5)
    centerLineH:SetSize(2000, 1)
    centerLineH:SetPoint("CENTER", mover, "CENTER", 0, 0)
    mover.centerLineH = centerLineH
    
    local centerLineV = mover:CreateTexture(nil, "OVERLAY")
    centerLineV:SetColorTexture(1, 1, 1, 0.5)
    centerLineV:SetSize(1, 2000)
    centerLineV:SetPoint("CENTER", mover, "CENTER", 0, 0)
    mover.centerLineV = centerLineV
    
    mover:SetScript("OnDragStart", function(self)
        self:StartMoving()
        
        local db = DF:GetDB()
        self:SetScript("OnUpdate", function()
            -- Update icons to follow mover during drag
            local screenWidth, screenHeight = GetScreenWidth(), GetScreenHeight()
            local centerX, centerY = self:GetCenter()
            local x = centerX - screenWidth / 2
            local y = centerY - screenHeight / 2
            
            -- Update container position live
            if personalContainer then
                personalContainer:ClearAllPoints()
                personalContainer:SetPoint("CENTER", UIParent, "CENTER", x, y)
            end
            
            -- Snap preview
            if db.snapToGrid and DF.gridFrame and DF.gridFrame:IsShown() then
                DF:UpdateSnapPreview(self)
            end
        end)
    end)
    
    mover:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetScript("OnUpdate", nil)
        DF:HideSnapPreview()
        
        local screenWidth, screenHeight = GetScreenWidth(), GetScreenHeight()
        local centerX, centerY = self:GetCenter()
        local x = centerX - screenWidth / 2
        local y = centerY - screenHeight / 2
        
        local db = DF:GetDB()
        if db.snapToGrid and DF.gridFrame and DF.gridFrame:IsShown() then
            x, y = DF:SnapToGrid(x, y)
        end
        
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "CENTER", x, y)
        
        -- Save to DB
        db.personalTargetedSpellX = x
        db.personalTargetedSpellY = y
        
        -- Update actual container
        DF:UpdatePersonalTargetedSpellsPosition()
    end)
    
    mover:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            DF:LockFrames()
        end
    end)
    
    DF.personalTargetedSpellsMover = mover
end

-- Show/hide the personal targeted spells mover
function DF:ShowPersonalTargetedSpellsMover()
    if not DF.personalTargetedSpellsMover then
        DF:CreatePersonalTargetedSpellsMover()
    end
    
    local db = DF:GetDB()
    local x = db.personalTargetedSpellX or 0
    local y = db.personalTargetedSpellY or -150
    
    UpdateMoverSize()
    DF.personalTargetedSpellsMover:ClearAllPoints()
    DF.personalTargetedSpellsMover:SetPoint("CENTER", UIParent, "CENTER", x, y)
    DF.personalTargetedSpellsMover:Show()
    
    -- Show test icons
    DF:ShowTestPersonalTargetedSpells()
end

function DF:HidePersonalTargetedSpellsMover()
    if DF.personalTargetedSpellsMover then
        DF.personalTargetedSpellsMover:Hide()
    end
    -- Hide test icons
    DF:HideTestPersonalTargetedSpells()
end

-- Test mode support for personal targeted spells
function DF:ShowTestPersonalTargetedSpells()
    local db = DF:GetDB()
    if not db.personalTargetedSpellEnabled then return end
    
    CreatePersonalContainer()
    
    -- Clear any existing test icons
    DF:HideAllPersonalTargetedSpells()
    
    local maxIcons = db.personalTargetedSpellMaxIcons or 5
    local numTestIcons = math.min(3, maxIcons)  -- Show up to 3 test icons
    local iconAlpha = db.personalTargetedSpellAlpha or 1.0
    local importantOnly = db.personalTargetedSpellImportantOnly
    
    -- Test spells - include one interrupted if settings allow
    local testSpells = {
        {id = 686, texture = "Interface\\Icons\\Spell_Shadow_ShadowBolt", isImportant = true, isInterrupted = false},
        {id = 348, texture = "Interface\\Icons\\Spell_Fire_Immolation", isImportant = false, isInterrupted = false},
        {id = 172, texture = "Interface\\Icons\\Spell_Shadow_AbominationExplosion", isImportant = true, isInterrupted = db.personalTargetedSpellShowInterrupted},
    }
    
    for i = 1, numTestIcons do
        local testData = testSpells[i]
        
        -- Skip non-important spells if importantOnly is enabled
        if importantOnly and not testData.isImportant then
            -- Skip this icon but continue loop
        else
            local testKey = "test-personal-" .. i
            
            local icon = GetPersonalIcon(i)
            personalActiveSpells[testKey] = i
            
            -- Setup icon
            icon.casterUnit = nil
            icon.casterKey = testKey
            icon.spellID = testData.id
            icon.isChannel = false
            icon.durationObject = nil
            icon.startTime = GetTime()
            icon.isActive = true
            icon.isInterrupted = false
            icon.interruptTimer = 0
            icon.isTestIcon = true
            icon.testTimeRemaining = 2.0 + i * 0.5  -- Varying durations
            
            -- Set icon texture
            if icon.icon then
                icon.icon:SetTexture(testData.texture)
                icon.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                icon.icon:SetDesaturated(testData.isInterrupted)
            end
            
            -- Apply settings (use real spellID for importance check in test)
            ApplyPersonalIconSettings(icon, db, testData.isImportant and testData.id or nil)
            
            -- For test mode, manually set highlight visibility based on test data
            if icon.highlightFrame then
                if db.personalTargetedSpellHighlightImportant and testData.isImportant and not testData.isInterrupted then
                    icon.highlightFrame:Show()
                    icon.highlightFrame:SetAlpha(1)
                else
                    icon.highlightFrame:Hide()
                end
            end
            
            -- Show interrupt overlay for the test interrupted icon
            if icon.interruptOverlay then
                if testData.isInterrupted then
                    icon.interruptOverlay:Show()
                    icon.durationText:Hide()
                else
                    icon.interruptOverlay:Hide()
                end
            end
            
            -- Set up fake cooldown for test (3 second duration)
            if icon.cooldown then
                if testData.isInterrupted then
                    -- Interrupted icons show partial cooldown
                    icon.cooldown:SetCooldown(GetTime() - 1.5, 3)
                else
                    icon.cooldown:SetCooldown(GetTime(), 3)
                end
            end
            
            -- Apply alpha setting
            icon:SetAlpha(iconAlpha)
            
            icon:Show()
        end
    end
    
    -- Apply alpha to container as well
    if personalContainer then
        personalContainer:SetAlpha(iconAlpha)
    end
    
    -- Show container
    personalContainer:Show()
    
    PositionPersonalIcons()
end

function DF:HideTestPersonalTargetedSpells()
    DF:HideAllPersonalTargetedSpells()
end

-- Update test personal targeted spells (called when settings change)
function DF:UpdateTestPersonalTargetedSpells()
    -- Update if mover is shown OR if in test mode with personal enabled
    local db = DF:GetDB()
    local moverShown = DF.personalTargetedSpellsMover and DF.personalTargetedSpellsMover:IsShown()
    -- Show personal targeted spells in test mode if personal is enabled (don't require testShowTargetedSpell)
    local inTestMode = (DF.testMode or DF.raidTestMode) and db.personalTargetedSpellEnabled
    
    if moverShown or inTestMode then
        UpdateMoverSize()
        DF:ShowTestPersonalTargetedSpells()
    end
end

-- Toggle personal targeted spells
function DF:TogglePersonalTargetedSpells(enabled)
    if enabled then
        CreatePersonalContainer()
        DF:CreatePersonalTargetedSpellsMover()
    else
        DF:HideAllPersonalTargetedSpells()
    end
end

-- ============================================================
-- CAST HISTORY (TEST FEATURE)
-- ============================================================

-- Get cast history table
function DF:GetCastHistory()
    return castHistory
end

-- Clear cast history
function DF:ClearCastHistory()
    wipe(castHistory)
    -- Also clear the secrets table
    if DF.castHistorySecrets then
        wipe(DF.castHistorySecrets)
    end
    print("|cff00ff00DandersFrames:|r Cast history cleared")
    -- Refresh UI if open
    if DF.castHistoryFrame and DF.castHistoryFrame:IsShown() then
        DF:RefreshCastHistoryUI()
    end
end

-- Cast history UI frame
local castHistoryFrame = nil
local castHistoryRows = {}
local HISTORY_ROW_HEIGHT = 28
local ROWS_PER_PAGE = 10
local currentPage = 1

-- Create the cast history UI with PAGINATION (no scroll frame to avoid secret contamination)
function DF:CreateCastHistoryUI()
    if castHistoryFrame then return castHistoryFrame end
    
    -- Theme colors (matching GUI.lua)
    local C_BACKGROUND = {r = 0.08, g = 0.08, b = 0.08, a = 0.95}
    local C_PANEL      = {r = 0.12, g = 0.12, b = 0.12, a = 1}
    local C_ELEMENT    = {r = 0.18, g = 0.18, b = 0.18, a = 1}
    local C_BORDER     = {r = 0.25, g = 0.25, b = 0.25, a = 1}
    local C_ACCENT     = {r = 0.45, g = 0.45, b = 0.95, a = 1}
    local C_TEXT       = {r = 0.9, g = 0.9, b = 0.9, a = 1}
    local C_TEXT_DIM   = {r = 0.6, g = 0.6, b = 0.6, a = 1}
    
    -- Main frame
    local frame = CreateFrame("Frame", "DFCastHistoryFrame", UIParent, "BackdropTemplate")
    frame:SetSize(590, 404)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:Hide()
    
    -- Backdrop - dark charcoal like main options
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b, C_BACKGROUND.a)
    frame:SetBackdropBorderColor(0, 0, 0, 1)
    
    -- Title bar with accent color
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(32)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    titleBar:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 1)
    titleBar:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 10, 4)
    title:SetText("Cast History")
    title:SetTextColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b)
    
    -- Subtitle note
    local subtitle = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, 0)
    subtitle:SetText("Persists through load screens, resets on /reload")
    subtitle:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
    
    -- Close button (styled X)
    local closeBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("RIGHT", -4, 0)
    closeBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    closeBtn:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    closeBtn:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    local closeIcon = closeBtn:CreateTexture(nil, "OVERLAY")
    closeIcon:SetPoint("CENTER", 0, 0)
    closeIcon:SetSize(12, 12)
    closeIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
    closeIcon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    closeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.4, 0.15, 0.15, 1)
        closeIcon:SetVertexColor(1, 0.3, 0.3)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        closeIcon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    end)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)
    
    -- Clear button (themed)
    local clearBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    clearBtn:SetSize(50, 20)
    clearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -5, 0)
    clearBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    clearBtn:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    clearBtn:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    local clearTxt = clearBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clearTxt:SetPoint("CENTER")
    clearTxt:SetText("Clear")
    clearTxt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    clearBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.25, 0.25, 0.25, 1)
    end)
    clearBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)
    clearBtn:SetScript("OnClick", function()
        DF:ClearCastHistory()
    end)
    
    -- Column headers
    local headerFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    headerFrame:SetHeight(22)
    headerFrame:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -2)
    headerFrame:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, -2)
    headerFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    headerFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 1)
    headerFrame:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.3)
    
    local headerTime = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerTime:SetPoint("LEFT", 5, 0)
    headerTime:SetWidth(30)
    headerTime:SetText("Time")
    headerTime:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local headerSpell = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerSpell:SetPoint("LEFT", 40, 0)
    headerSpell:SetWidth(100)
    headerSpell:SetText("Spell")
    headerSpell:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local headerCaster = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerCaster:SetPoint("LEFT", 165, 0)
    headerCaster:SetWidth(70)
    headerCaster:SetText("Caster")
    headerCaster:SetTextColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b)
    
    -- Player name headers (will be updated dynamically)
    frame.playerHeaders = {}
    for i = 1, 5 do
        local header = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("LEFT", 240 + (i-1) * 65, 0)
        header:SetWidth(60)
        header:SetJustifyH("CENTER")
        header:SetTextColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b)
        header:Hide()
        frame.playerHeaders[i] = header
    end
    
    -- Content area (no scroll frame!)
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", headerFrame, "BOTTOMLEFT", 0, -2)
    content:SetPoint("TOPRIGHT", headerFrame, "BOTTOMRIGHT", 0, -2)
    content:SetHeight(ROWS_PER_PAGE * HISTORY_ROW_HEIGHT)
    frame.content = content
    
    -- Store theme colors for row access
    frame.themeColors = {
        C_BACKGROUND = C_BACKGROUND,
        C_PANEL = C_PANEL,
        C_ELEMENT = C_ELEMENT,
        C_BORDER = C_BORDER,
        C_ACCENT = C_ACCENT,
        C_TEXT = C_TEXT,
        C_TEXT_DIM = C_TEXT_DIM,
    }
    
    -- Create row pool for current page only
    for i = 1, ROWS_PER_PAGE do
        local row = CreateFrame("Frame", nil, content, "BackdropTemplate")
        row:SetHeight(HISTORY_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i-1) * HISTORY_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -(i-1) * HISTORY_ROW_HEIGHT)
        row:EnableMouse(true)
        row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        row:SetBackdropColor(C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b, 0)
        row.rowIndex = i  -- Store for alternating colors
        
        -- Time text
        local timeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        timeText:SetPoint("LEFT", 5, 0)
        timeText:SetWidth(30)
        timeText:SetJustifyH("LEFT")
        timeText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        row.timeText = timeText
        
        -- Icon frame with border
        local iconFrame = CreateFrame("Frame", nil, row, "BackdropTemplate")
        iconFrame:SetSize(22, 22)
        iconFrame:SetPoint("LEFT", 35, 0)
        iconFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        iconFrame:SetBackdropColor(0, 0, 0, 0.5)
        iconFrame:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 1)
        
        local icon = iconFrame:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.icon = icon
        row.iconFrame = iconFrame
        
        -- Interrupted X overlay
        local interruptedX = iconFrame:CreateTexture(nil, "OVERLAY")
        interruptedX:SetAllPoints()
        interruptedX:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
        interruptedX:SetVertexColor(1, 0.3, 0.3, 0.9)
        interruptedX:Hide()
        row.interruptedX = interruptedX
        
        -- Important spell border (controlled by SetAlphaFromBoolean)
        local importantBorder = CreateFrame("Frame", nil, row, "BackdropTemplate")
        importantBorder:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", -2, 2)
        importantBorder:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", 2, -2)
        importantBorder:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 2,
        })
        importantBorder:SetBackdropBorderColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 1)  -- Accent color
        importantBorder:SetAlpha(0)
        row.importantBorder = importantBorder
        
        -- Spell name
        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameText:SetPoint("LEFT", iconFrame, "RIGHT", 4, 0)
        nameText:SetWidth(100)
        nameText:SetJustifyH("LEFT")
        nameText:SetWordWrap(false)
        nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        row.nameText = nameText
        
        -- Caster name
        local casterText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        casterText:SetPoint("LEFT", 165, 0)
        casterText:SetWidth(70)
        casterText:SetJustifyH("LEFT")
        casterText:SetWordWrap(false)
        casterText:SetTextColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b)
        row.casterText = casterText
        
        -- Target indicators (5 columns for party members)
        row.targetIndicators = {}
        for j = 1, 5 do
            local container = CreateFrame("Frame", nil, row)
            container:SetSize(60, 20)
            container:SetPoint("LEFT", 240 + (j-1) * 65, 0)
            
            -- YES frame (shown when targeted)
            local yesFrame = CreateFrame("Frame", nil, container)
            yesFrame:SetAllPoints()
            local yesText = yesFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            yesText:SetAllPoints()
            yesText:SetText("|cffff6666YES|r")
            yesText:SetJustifyH("CENTER")
            container.yesFrame = yesFrame
            
            -- No frame (shown when not targeted)
            local noFrame = CreateFrame("Frame", nil, container)
            noFrame:SetAllPoints()
            local noText = noFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noText:SetAllPoints()
            noText:SetText("|cff444444-|r")
            noText:SetJustifyH("CENTER")
            container.noFrame = noFrame
            
            -- N/A text
            local naText = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            naText:SetAllPoints()
            naText:SetText("|cff222222--|r")
            naText:SetJustifyH("CENTER")
            naText:Hide()
            container.naText = naText
            
            container:Hide()
            row.targetIndicators[j] = container
        end
        
        -- Tooltip on hover with themed highlight
        row:SetScript("OnEnter", function(self)
            self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.8)
            -- Only show spell tooltips out of combat (some spells are "secret" in combat)
            if self.spellID and not InCombatLockdown() then
                GameTooltip:SetOwner(self.iconFrame, "ANCHOR_RIGHT")
                -- Still wrap in pcall as a safety net
                local success = pcall(function()
                    GameTooltip:SetSpellByID(self.spellID)
                end)
                if success then
                    GameTooltip:Show()
                else
                    GameTooltip:Hide()
                end
            end
        end)
        row:SetScript("OnLeave", function(self)
            -- Restore alternating background
            if self.rowIndex % 2 == 0 then
                self:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.5)
            else
                self:SetBackdropColor(C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b, 0)
            end
            GameTooltip:Hide()
        end)
        
        row:Hide()
        castHistoryRows[i] = row
    end
    
    -- Pagination controls at bottom (themed)
    local pageFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    pageFrame:SetHeight(32)
    pageFrame:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    pageFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    pageFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    pageFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 1)
    pageFrame:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.3)
    
    -- Helper to create themed button
    local function CreateThemedButton(parent, text)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(60, 22)
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        btn:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        
        local btnText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btnText:SetPoint("CENTER")
        btnText:SetText(text)
        btnText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        btn.text = btnText
        btn.isEnabled = true
        
        btn:SetScript("OnEnter", function(self)
            if self.isEnabled then
                self:SetBackdropColor(C_ACCENT.r * 0.5, C_ACCENT.g * 0.5, C_ACCENT.b * 0.5, 1)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if self.isEnabled then
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            end
        end)
        
        -- Custom SetEnabled for themed button
        btn.SetEnabled = function(self, enabled)
            self.isEnabled = enabled
            if enabled then
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
                self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
                self.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                self:EnableMouse(true)
            else
                self:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
                self:SetBackdropBorderColor(0.15, 0.15, 0.15, 0.3)
                self.text:SetTextColor(0.4, 0.4, 0.4)
                self:EnableMouse(false)
            end
        end
        
        return btn
    end
    
    local prevBtn = CreateThemedButton(pageFrame, "< Prev")
    prevBtn:SetPoint("LEFT", 10, 0)
    prevBtn:SetScript("OnClick", function()
        if currentPage > 1 then
            currentPage = currentPage - 1
            DF:RefreshCastHistoryUI()
        end
    end)
    frame.prevBtn = prevBtn
    
    local nextBtn = CreateThemedButton(pageFrame, "Next >")
    nextBtn:SetPoint("RIGHT", -10, 0)
    nextBtn:SetScript("OnClick", function()
        local maxPage = math.ceil(#castHistory / ROWS_PER_PAGE)
        if currentPage < maxPage then
            currentPage = currentPage + 1
            DF:RefreshCastHistoryUI()
        end
    end)
    frame.nextBtn = nextBtn
    
    local pageText = pageFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pageText:SetPoint("CENTER", 0, 0)
    pageText:SetText("Page 1 / 1")
    pageText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    frame.pageText = pageText
    
    castHistoryFrame = frame
    DF.castHistoryFrame = frame
    
    return frame
end

-- Update player headers
local function UpdatePlayerHeaders()
    if not castHistoryFrame then return end
    
    local headers = castHistoryFrame.playerHeaders
    local sortOrder = {"player", "party1", "party2", "party3", "party4"}
    
    local idx = 1
    for _, unit in ipairs(sortOrder) do
        if unit == "player" or UnitExists(unit) then
            local name = UnitName(unit) or unit
            if #name > 7 then
                name = name:sub(1, 6) .. ".."
            end
            headers[idx]:SetText(name)
            headers[idx]:Show()
            idx = idx + 1
        end
    end
    
    for i = idx, 5 do
        headers[i]:Hide()
    end
end

-- Refresh the cast history UI with pagination
function DF:RefreshCastHistoryUI()
    if not castHistoryFrame then return end
    
    UpdatePlayerHeaders()
    
    local currentTime = GetTime()
    local totalEntries = #castHistory
    local maxPage = math.max(1, math.ceil(totalEntries / ROWS_PER_PAGE))
    
    -- Clamp current page
    if currentPage > maxPage then currentPage = maxPage end
    if currentPage < 1 then currentPage = 1 end
    
    -- Update page text
    castHistoryFrame.pageText:SetText(string.format("Page %d / %d  (%d casts)", currentPage, maxPage, totalEntries))
    
    -- Enable/disable pagination buttons
    castHistoryFrame.prevBtn:SetEnabled(currentPage > 1)
    castHistoryFrame.nextBtn:SetEnabled(currentPage < maxPage)
    
    -- Build current group order
    local sortOrder = {"player", "party1", "party2", "party3", "party4"}
    local activeUnits = {}
    for _, unit in ipairs(sortOrder) do
        if unit == "player" or UnitExists(unit) then
            table.insert(activeUnits, unit)
        end
    end
    
    -- Calculate which entries to show
    local startIdx = (currentPage - 1) * ROWS_PER_PAGE + 1
    
    -- Update rows
    for i, row in ipairs(castHistoryRows) do
        local entryIdx = startIdx + i - 1
        local entry = castHistory[entryIdx]
        
        if entry then
            -- Time
            local timeAgo = currentTime - entry.timestamp
            local timeStr
            if timeAgo < 60 then
                timeStr = string.format("%.0fs", timeAgo)
            elseif timeAgo < 3600 then
                timeStr = string.format("%.0fm", timeAgo / 60)
            else
                timeStr = string.format("%.0fh", timeAgo / 3600)
            end
            row.timeText:SetText(timeStr)
            
            -- Icon - just pass directly, let WoW handle it
            row.icon:SetTexture(entry.texture)
            row.spellID = entry.spellID
            
            -- Get secrets from separate table
            local secrets = DF.castHistorySecrets and DF.castHistorySecrets[entry.entryID]
            
            -- Important spell border - use SetAlphaFromBoolean directly (can't test secrets)
            -- If secrets exist, pass the isImportant secret; otherwise hide the border
            if secrets then
                row.importantBorder:SetAlphaFromBoolean(secrets.isImportant, 1, 0)
            else
                row.importantBorder:SetAlpha(0)
            end
            
            -- Alternating background (themed)
            if i % 2 == 0 then
                row:SetBackdropColor(0.12, 0.12, 0.12, 0.5)  -- C_PANEL
            else
                row:SetBackdropColor(0.08, 0.08, 0.08, 0)    -- C_BACKGROUND
            end
            
            -- Interrupted visual
            if entry.interrupted then
                row.interruptedX:Show()
                row.icon:SetDesaturated(true)
                row.icon:SetVertexColor(0.6, 0.6, 0.6)
            else
                row.interruptedX:Hide()
                row.icon:SetDesaturated(false)
                row.icon:SetVertexColor(1, 1, 1)
            end
            
            -- Name - just pass directly, let WoW handle secrets
            row.nameText:SetText(entry.name)
            
            -- Caster name - just pass directly
            row.casterText:SetText(entry.casterName)
            
            -- Hide all target indicators first
            for _, indicator in ipairs(row.targetIndicators) do
                indicator:Hide()
            end
            
            -- Show target indicators
            if entry.targetNames and secrets and secrets.targets then
                for idx, unit in ipairs(activeUnits) do
                    local hasName = entry.targetNames[unit]
                    local targetSecret = secrets.targets[unit]
                    local indicator = row.targetIndicators[idx]
                    
                    -- Can't test targetSecret (it's a secret), just check if hasName and indicator exist
                    if hasName and indicator then
                        -- Use SetAlphaFromBoolean for secret display
                        indicator.yesFrame:SetAlphaFromBoolean(targetSecret, 1, 0)
                        indicator.noFrame:SetAlphaFromBoolean(targetSecret, 0, 1)
                        indicator.naText:Hide()
                        indicator:Show()
                    elseif indicator then
                        indicator.yesFrame:SetAlpha(0)
                        indicator.noFrame:SetAlpha(0)
                        indicator.naText:Show()
                        indicator:Show()
                    end
                end
            end
            
            row:Show()
        else
            row:Hide()
        end
    end
end

-- Show cast history UI
function DF:ShowCastHistoryUI()
    local frame = DF:CreateCastHistoryUI()
    currentPage = 1  -- Reset to first page
    DF:RefreshCastHistoryUI()
    frame:Show()
    
    -- Set up periodic refresh while open
    if not frame.refreshTicker then
        frame.refreshTicker = C_Timer.NewTicker(1, function()
            if frame:IsShown() then
                DF:RefreshCastHistoryUI()
            end
        end)
    end
end

-- Toggle cast history UI
function DF:ToggleCastHistoryUI()
    if castHistoryFrame and castHistoryFrame:IsShown() then
        castHistoryFrame:Hide()
    else
        DF:ShowCastHistoryUI()
    end
end

-- Legacy chat output (keep for quick debug)
function DF:ShowCastHistory()
    DF:ShowCastHistoryUI()
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

function DF:InitTargetedSpells()
    local db = DF:GetDB()
    if db.targetedSpellEnabled then
        DF:EnableTargetedSpells()
    end
    
    -- Apply nameplate offscreen setting if enabled
    if db.targetedSpellNameplateOffscreen then
        DF:SetNameplateOffscreen(true)
    end
    
    -- Initialize personal targeted spells
    if db.personalTargetedSpellEnabled then
        DF:TogglePersonalTargetedSpells(true)
    end
end
