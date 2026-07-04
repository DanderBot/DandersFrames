local addonName, DF = ...

-- ============================================================
-- FRAMES CORE MODULE
-- Contains shared containers, helpers, and utilities
-- ============================================================

-- ============================================================
-- FRAME CONTAINERS
-- ============================================================

-- NOTE: Party/raid frames are now created by SecureGroupHeaderTemplate in Headers.lua
-- These legacy tables are kept empty for backwards compatibility
-- Access frames via DF:IteratePartyFrames() and DF:IterateRaidFrames() instead
-- Legacy frame references for backward compatibility
-- In the old (pre-header) system, these were populated directly:
--   DF.playerFrame = CreatePartyFrame("player")
--   DF.partyFrames[i] = CreatePartyFrame("party"..i)
--   DF.raidFrames[i] = CreateRaidFrame("raid"..i)
-- Now frames are managed by SecureGroupHeaderTemplate, so these use
-- proxy tables that dynamically resolve via the header-based getters.
-- This preserves the API for external addons using AllowAddOnTableAccess.
DF.playerFrame = nil  -- Updated by Headers.lua OnAttributeChanged when unit=="player"
DF.partyFrames = setmetatable({}, {
    __index = function(_, k)
        if type(k) == "number" and DF.GetPartyFrame then
            return DF:GetPartyFrame(k)
        end
    end
})
DF.raidFrames = setmetatable({}, {
    __index = function(_, k)
        if type(k) == "number" and DF.GetRaidFrame then
            return DF:GetRaidFrame(k)
        end
    end
})

DF.container = nil
DF.moverFrame = nil
DF.testMode = false

-- Raid frame containers
DF.raidContainer = nil
DF.raidMoverFrame = nil

-- Color curve cache for gradient mode
DF.CurveCache = {}

-- ============================================================
-- SECRET VALUE HANDLING (WoW 12.0+ / Midnight Beta)
-- ============================================================
-- In WoW 12.0+, certain Unit APIs may return "secret values" that cannot
-- be used in arithmetic operations. The proper handling is:
--
-- 1. HEALTH BARS: Use GetSafeHealthPercent() helper which tries CurveConstants
--    first, then falls back to old boolean API
-- 2. POWER BARS: Check type(value) ~= "number" to detect secrets, then either
--    hide the bar or pass values directly to StatusBar APIs
-- 3. ABSORB BARS: UnitHealthMax is safe, but UnitGetTotalAbsorbs/HealAbsorbs
--    may be secret - pass directly to StatusBar:SetValue() without comparison
-- 4. HEALTH TEXT: Use SetFormattedText which handles secret values internally
-- 5. COLORS: Use UnitHealthPercent(unit, true, curve) to get colors directly
-- ============================================================

-- Helper to get health percent safely with proper scale (0-100)
-- Uses CurveConstants.ScaleTo100 which returns 0-100 directly
local function GetSafeHealthPercent(unit)
    -- Use ScaleTo100 curve - returns 0-100 directly
    return UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)
end

-- Export for use in other files
DF.GetSafeHealthPercent = GetSafeHealthPercent

-- Helper to set health bar value safely
-- Uses CurveConstants.ScaleTo100 for the bar value, then delegates
-- threshold fading to HealthFade.lua's curve-based system.
local function SetHealthBarValue(bar, unit, frame)
    if not bar then return end

    -- Get health percent (0-100) via CurveConstants.ScaleTo100
    local pct = GetSafeHealthPercent(unit)

    -- Set bar range and value
    bar:SetMinMaxValues(0, 100)

    -- Get the appropriate db for this frame
    local db
    if frame and frame.isRaidFrame then
        db = DF.GetRaidDB and DF:GetRaidDB()
    else
        db = DF.GetDB and DF:GetDB()
    end
    local smoothEnabled = db and db.smoothBars

    if smoothEnabled and Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut then
        bar:SetValue(pct, Enum.StatusBarInterpolation.ExponentialEaseOut)
    else
        bar:SetValue(pct)
    end

    -- Health threshold fading (curve-based, no Lua-side secret comparison)
    if frame then
        if DF.UpdateHealthFade then
            DF:UpdateHealthFade(frame)
        end
    end
end

-- Export for use in other files
DF.SetHealthBarValue = SetHealthBarValue

-- Helper to set missing health bar value safely
-- Uses UnitHealthMissing API which is safe with secret values
-- IMPORTANT: We pass values directly to StatusBar APIs without arithmetic
local function SetMissingHealthBarValue(bar, unit, frame)
    if not bar then return end
    
    -- Get the appropriate db for this frame
    local db
    if frame and frame.isRaidFrame then
        db = DF.GetRaidDB and DF:GetRaidDB()
    else
        db = DF.GetDB and DF:GetDB()
    end
    
    local backgroundMode = db and db.backgroundMode or "BACKGROUND"
    
    -- Only show if mode includes missing health
    if backgroundMode == "BACKGROUND" then
        bar:Hide()
        return
    end
    
    -- Use UnitHealthMissing API - safe with secret values
    -- Second param true means use predicted/displayable value
    -- CRITICAL: Do NOT do arithmetic on these values - pass directly to StatusBar
    local missingHealth = UnitHealthMissing(unit, true)
    local maxHealth = UnitHealthMax(unit)
    
    -- Set bar range using maxHealth, value using missingHealth
    -- StatusBar handles the math internally (safe with secret values)
    bar:SetMinMaxValues(0, maxHealth)
    
    local smoothEnabled = db and db.smoothBars
    if smoothEnabled and Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut then
        bar:SetValue(missingHealth, Enum.StatusBarInterpolation.ExponentialEaseOut)
    else
        bar:SetValue(missingHealth)
    end
    
    -- Update texture before color (SetStatusBarTexture resets vertex color)
    local texture = db and db.missingHealthTexture
    if not texture or texture == "" then
        texture = db and db.healthTexture or "Interface\\TargetingFrame\\UI-StatusBar"
    end
    DF:SafeSetStatusBarTexture(bar, texture)

    -- Update color based on color mode
    local colorMode = db and db.missingHealthColorMode or "CUSTOM"
    local r, g, b, a
    
    -- Check for dead/offline state with custom dead color enabled
    local isDeadOrOffline = unit and UnitExists(unit) and (UnitIsDeadOrGhost(unit) or not UnitIsConnected(unit))
    local useDeadColor = isDeadOrOffline and db.fadeDeadFrames and db.fadeDeadUseCustomColor
    
    if useDeadColor then
        -- Use custom dead color (same as background uses)
        local c = db.fadeDeadBackgroundColor or {r = 0.3, g = 0, b = 0}
        r, g, b = c.r, c.g, c.b
        a = db.fadeDeadBackground or 0.4
    elseif colorMode == "PERCENT" and unit and UnitExists(unit) then
        -- Use health gradient curve
        local applied = false
        local curve = DF:GetCurveForUnit(unit, db, "missingHealthColor", DF.MissingHealthCurveCache)
        if curve and UnitHealthPercent then
            local color = UnitHealthPercent(unit, true, curve)
            local tex = bar:GetStatusBarTexture()
            if color and tex then
                tex:SetVertexColor(color:GetRGB())
                tex:SetAlpha(db.missingHealthGradientAlpha or 0.8)
                applied = true
            end
        end
        if not applied then
            r, g, b = 0.5, 0, 0
            a = db.missingHealthGradientAlpha or 0.8
        end
    elseif colorMode == "CLASS" and unit and UnitExists(unit) then
        -- Use class color
        local _, class = UnitClass(unit)
        local classColor = DF:GetClassColor(class)
        if classColor then
            r, g, b = classColor.r, classColor.g, classColor.b
        else
            r, g, b = 0.5, 0, 0  -- Fallback dark red
        end
        a = db and db.missingHealthClassAlpha or 0.8
    else
        -- Use custom color
        local missingColor = db and db.missingHealthColor or {r = 0.5, g = 0, b = 0, a = 0.8}
        r, g, b, a = missingColor.r, missingColor.g, missingColor.b, missingColor.a or 0.8
    end
    if r then
        bar:SetStatusBarColor(r, g, b, a)
    end
    
    bar:Show()
end

-- Export for use in other files
DF.SetMissingHealthBarValue = SetMissingHealthBarValue

-- ============================================================
-- PIXEL-PERFECT SCALING
-- ============================================================

-- Cached pixel scale value (updated on UI scale changes)
local cachedPixelScale = nil

-- Calculate the pixel-perfect scale factor
-- This ensures 1 unit in WoW coordinates equals exactly 1 screen pixel
function DF:UpdatePixelScale()
    local physicalWidth, physicalHeight = GetPhysicalScreenSize()
    local uiScale = UIParent:GetEffectiveScale()
    -- WoW's reference resolution is 768 pixels high
    local pixelScale = 768 / physicalHeight
    cachedPixelScale = pixelScale / uiScale
end

-- Get the cached pixel scale (calculates if not yet cached)
function DF:GetPixelScale()
    if not cachedPixelScale then
        self:UpdatePixelScale()
    end
    return cachedPixelScale
end

-- Snap a value to the nearest pixel boundary
-- Returns the adjusted value that will render pixel-perfectly
function DF:PixelPerfect(value)
    local scale = self:GetPixelScale()
    return math.floor(value / scale + 0.5) * scale
end

-- Snap a value to the nearest pixel boundary, but ensure minimum 1 pixel for thickness values
function DF:PixelPerfectThickness(value)
    local scale = self:GetPixelScale()
    local result = math.floor(value / scale + 0.5) * scale
    -- Ensure minimum 1 pixel thickness
    if result < scale then
        result = scale
    end
    return result
end

-- Snap a value UP to the next pixel boundary (ceiling)
function DF:PixelPerfectCeil(value)
    local scale = self:GetPixelScale()
    return math.ceil(value / scale) * scale
end

-- Adjust a size to ensure borders fit evenly on all sides
-- Takes a desired size and border thickness, returns adjusted size
-- Ensures the inner content area (size - 2*border) is a whole pixel count
-- and the overall size accommodates the border cleanly
function DF:PixelPerfectSizeForBorder(size, borderThickness)
    local scale = self:GetPixelScale()
    
    -- Snap border to nearest pixel (minimum 1 pixel if > 0)
    local borderPixels = math.floor(borderThickness / scale + 0.5)
    if borderThickness > 0 and borderPixels < 1 then
        borderPixels = 1
    end
    local ppBorder = borderPixels * scale
    
    -- Snap size to nearest pixel
    local sizePixels = math.floor(size / scale + 0.5)
    
    -- Calculate content area (what's left after borders on both sides)
    local contentPixels = sizePixels - (2 * borderPixels)
    
    -- If content would be less than 1 pixel, increase size
    if contentPixels < 1 then
        contentPixels = 1
        sizePixels = contentPixels + (2 * borderPixels)
    end
    
    return sizePixels * scale, ppBorder
end

-- Adjust size and scale together to ensure pixel-perfect rendering with borders
-- The key insight: SetScale scales EVERYTHING including border thickness
-- So a 1px border at scale 1.15 becomes 1.15px which won't render cleanly
-- Solution: Calculate final size, set that directly, and use scale=1.0
-- Returns: finalSize (to use with SetSize), scale (always 1.0), adjustedBorder
function DF:PixelPerfectSizeAndScaleForBorder(size, iconScale, borderThickness)
    local pixelScale = self:GetPixelScale()
    
    -- Calculate the desired final rendered size (what the user expects to see)
    local desiredFinalSize = size * iconScale
    
    -- Snap border to nearest pixel (minimum 1 pixel if > 0)
    local borderPixels = math.floor(borderThickness / pixelScale + 0.5)
    if borderThickness > 0 and borderPixels < 1 then
        borderPixels = 1
    end
    local ppBorder = borderPixels * pixelScale
    
    -- Snap the final size to nearest pixel
    local finalSizePixels = math.floor(desiredFinalSize / pixelScale + 0.5)
    
    -- Calculate content area (what's left after borders on both sides)
    local contentPixels = finalSizePixels - (2 * borderPixels)
    
    -- If content would be less than 1 pixel, increase size
    if contentPixels < 1 then
        contentPixels = 1
        finalSizePixels = contentPixels + (2 * borderPixels)
    end
    
    local ppFinalSize = finalSizePixels * pixelScale
    
    -- Return: the pixel-perfect final size, scale=1.0 (no scaling), and border
    -- By using scale=1.0, the border stays at exactly the specified pixel width
    return ppFinalSize, 1.0, ppBorder
end

-- Nudge an already-anchored, SINGLE-point frame onto the physical pixel grid by
-- shifting its anchor offset by the sub-pixel remainder (<=0.5px). A 1px DF.Border
-- on a fractionally-positioned frame straddles two physical rows so a side drops;
-- this lands all four edges on the grid. Anchor/offset-agnostic and BOUNDED — it
-- can never move the frame more than half a pixel from where it was placed, so it
-- cannot mis-position. No-op unless pp is true, the frame has exactly one anchor
-- point, and it's laid out — so call it AFTER positioning, on a path that re-runs
-- post-layout (e.g. an icon's per-update placement), not at one-time creation.
function DF:SnapPointToPixelGrid(frame, pp)
    if not pp or not frame or not frame.GetNumPoints or frame:GetNumPoints() ~= 1 then return end
    local point, relTo, relPoint, x, y = frame:GetPoint(1)
    if not x or not y then return end
    local eff = frame:GetEffectiveScale()
    local l, b = frame:GetLeft(), frame:GetBottom()
    local _, physH = GetPhysicalScreenSize()
    if not (l and b and eff and eff > 0 and physH and physH > 0) then return end
    local ppu = eff * physH / 768  -- physical pixels per UI unit
    local dx = (math.floor(l * ppu + 0.5) - l * ppu) / ppu
    local dy = (math.floor(b * ppu + 0.5) - b * ppu) / ppu
    if dx ~= 0 or dy ~= 0 then
        frame:SetPoint(point, relTo, relPoint, x + dx, y + dy)
    end
end

-- Pixel-perfect SetSize helper
-- Only applies pixel snapping if pixelPerfect is enabled in the given db
-- Skips SetSize for secure header children during combat
function DF:SetPixelPerfectSize(frame, width, height, db)
    -- Skip for secure header children during combat (protected frame restriction)
    if frame.dfIsHeaderChild and InCombatLockdown() then
        return
    end
    
    if db and db.pixelPerfect then
        frame:SetSize(self:PixelPerfect(width), self:PixelPerfect(height))
    else
        frame:SetSize(width, height)
    end
end

-- Pixel-perfect SetWidth helper
-- Skips SetWidth for secure header children during combat
function DF:SetPixelPerfectWidth(frame, width, db)
    -- Skip for secure header children during combat (protected frame restriction)
    if frame.dfIsHeaderChild and InCombatLockdown() then
        return
    end
    
    if db and db.pixelPerfect then
        frame:SetWidth(self:PixelPerfect(width))
    else
        frame:SetWidth(width)
    end
end

-- Pixel-perfect SetHeight helper
-- Skips SetHeight for secure header children during combat
function DF:SetPixelPerfectHeight(frame, height, db)
    -- Skip for secure header children during combat (protected frame restriction)
    if frame.dfIsHeaderChild and InCombatLockdown() then
        return
    end
    
    if db and db.pixelPerfect then
        frame:SetHeight(self:PixelPerfect(height))
    else
        frame:SetHeight(height)
    end
end

-- Register for UI scale change events to update pixel scale
local pixelScaleFrame = CreateFrame("Frame")
pixelScaleFrame:RegisterEvent("UI_SCALE_CHANGED")
pixelScaleFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
pixelScaleFrame:SetScript("OnEvent", function()
    DF:UpdatePixelScale()
    -- Refresh all frames to apply new pixel scale
    if DF.initialized then
        if DF.UpdateAllFrames then
            DF:UpdateAllFrames()
        end
        if DF.UpdateRaidLayout then
            DF:UpdateRaidLayout()
        end
    end
end)

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

-- External lookup table for raid frame status
-- WoW 12.0's SecureGroupHeader_Update (C code) clears custom Lua fields on child
-- frames during template processing. This table lives OUTSIDE the frame object,
-- so the secure template can't touch it.
DF.raidFrameRegistry = DF.raidFrameRegistry or setmetatable({}, {__mode = "k"})

-- Register a frame as a raid frame (call from InitializeHeaderChild and FlatRaidFrames)
function DF:RegisterRaidFrame(frame)
    if frame then
        self.raidFrameRegistry[frame] = true
        frame.isRaidFrame = true  -- Also set the field (fast path if it sticks)
    end
end

-- Check if a frame is a raid frame (checks external registry first, then field)
function DF:IsRaidFrame(frame)
    if not frame then return false end
    return frame.isRaidFrame or self.raidFrameRegistry[frame] or false
end

-- Helper to get correct DB based on frame type
function DF:GetFrameDB(frame)
    -- Pinned frames with Hide Auras / Hide Status Icons carry an effective DB that
    -- forces the relevant show flags off over the mode base — so every aura/icon
    -- updater (which all read GetFrameDB(frame).<flag>) hides via its existing path.
    if frame and frame.dfPinnedEffDB then return frame.dfPinnedEffDB end
    if frame and DF:IsRaidFrame(frame) then
        return DF:GetRaidDB()
    else
        return DF:GetDB()
    end
end

-- Returns true when the user has flipped the Text Designer
-- "Hide Legacy Text" toggle on for the frame's mode (party/raid).
-- Used by legacy text-widget update paths (nameText / healthText /
-- statusText / pet equivalents) to early-return-with-Hide so Phase C
-- live TD rendering can be tested without visual overlap.
function DF:IsLegacyTextHidden(frame)
    -- LEGACY-TEXT-CLEANUP (v4.4.x): Legacy name/health/status text is retired in
    -- favour of the Text Designer. Every legacy text render path funnels through
    -- this single gate (Frames/Bars.lua, Frames/Update.lua, Frames/Pets.lua,
    -- TestMode/TestMode.lua), so returning true force-hides legacy text addon-wide
    -- without touching each call site. The per-profile "Hide Legacy Text" toggle
    -- and the legacy text settings pages are hidden from the UI. To temporarily
    -- restore the old per-profile behaviour, return the commented expression below.
    --
    -- EXCEPTION: pet frames are not part of the Text Designer. Their name/health text
    -- is driven by the legacy fontstrings with pet-specific settings (petNameFont,
    -- petShowHealthText, petNameMaxLength, …), so they must keep it — otherwise pet
    -- name/health text disappears entirely and those settings have no effect.
    if frame and frame.isPetFrame then return false end
    return true
    -- local db = DF:GetFrameDB(frame)
    -- return db and db.textDesigner and db.textDesigner.hideLegacyText or false
end

-- Note: FormatNumber should only be used with known-accessible values
-- For secret values from Unit APIs, use SetFormattedText with %s directly
function DF:FormatNumber(num)
    if not num then return "0" end
    
    -- Use Blizzard's abbreviation if available (handles large numbers)
    if AbbreviateNumbers then
        return AbbreviateNumbers(num)
    elseif AbbreviateLargeNumbers then
        return AbbreviateLargeNumbers(num)
    end
    
    return tostring(num)
end

-- Abbreviate large numbers (for health text, etc.)
function DF:AbbreviateNumber(num)
    if not num then return "0" end
    
    if num >= 1000000000 then
        return string.format("%.1fB", num / 1000000000)
    elseif num >= 1000000 then
        return string.format("%.1fM", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.1fK", num / 1000)
    else
        return tostring(math.floor(num))
    end
end

-- Get duration text color based on remaining percentage (for test mode)
-- Returns r, g, b values matching the color curve used for live frames
-- 0% = red, 30% = orange, 50% = yellow, 100% = green
function DF:GetDurationColorByPercent(percent)
    if not percent then return 1, 1, 1 end
    
    -- Clamp to 0-1 range
    percent = math.max(0, math.min(1, percent))
    
    if percent < 0.3 then
        -- Red to Orange (0% to 30%)
        local t = percent / 0.3
        return 1, 0.5 * t, 0
    elseif percent < 0.5 then
        -- Orange to Yellow (30% to 50%)
        local t = (percent - 0.3) / 0.2
        return 1, 0.5 + 0.5 * t, 0
    else
        -- Yellow to Green (50% to 100%)
        local t = (percent - 0.5) / 0.5
        return 1 - t, 1, 0
    end
end

-- Check if frame is valid for updates
function DF:IsValidFrame(frame)
    return frame and frame.healthBar and true or false
end

-- ============================================================
-- EXTERNAL ADDON API
-- Provides methods for other addons (like RG_Aliases) to hook
-- ============================================================

-- Get unit name - can be overridden by other addons (like RG_Aliases)
-- This is the primary hook point for nickname addons
function DF:GetUnitName(unit)
    return UnitName(unit) or unit
end

-- Display name used by our own frame rendering. DandersFrames' native nicknames
-- resolve FIRST here, so they stay authoritative on our frames even when another
-- nickname addon (e.g. NSRT) overwrites DF:GetUnitName. NK:HasPrecedence() gates
-- this: it returns false only when the user has explicitly chosen to let the
-- other addon win, in which case we fall through to DF:GetUnitName (which that
-- addon may own) and finally the raw name.
function DF:GetFrameName(unit)
    local NK = DF.Nicknames
    if NK and NK.GetDisplayName then
        return NK:GetDisplayName(unit)
    end
    return DF:GetUnitName(unit)
end

-- Iterator for all compact unit frames (player, party, raid)
-- Accepts a callback function OR returns an iterator if no callback provided
-- Usage with callback: DF:IterateCompactFrames(function(frame) ... end)
-- Usage as iterator: for frame in DF:IterateCompactFrames() do ... end
function DF:IterateCompactFrames(callback)
    local frames = {}

    -- Arena first (IsInRaid()=true in arena, so must check before raid)
    if DF.IsInArena and DF:IsInArena() then
        if DF.IterateArenaFrames then
            DF:IterateArenaFrames(function(frame)
                if frame then
                    table.insert(frames, frame)
                end
            end)
        end
    else
        -- Add party frames (includes player via headers)
        if DF.IteratePartyFrames then
            DF:IteratePartyFrames(function(frame)
                if frame then
                    table.insert(frames, frame)
                end
            end)
        end

        -- Add raid frames
        if DF.IterateRaidFrames then
            DF:IterateRaidFrames(function(frame)
                if frame then
                    table.insert(frames, frame)
                end
            end)
        end
    end
    
    -- If callback provided, call it for each frame (RG_Aliases style)
    if callback and type(callback) == "function" then
        for _, frame in ipairs(frames) do
            callback(frame)
        end
        return
    end
    
    -- Otherwise return an iterator
    local i = 0
    return function()
        i = i + 1
        return frames[i]
    end
end

-- Get all visible frames as a table (alternative to iterator)
function DF:GetAllFrames()
    local frames = {}

    -- Arena first (IsInRaid()=true in arena, so must check before raid)
    if DF.IsInArena and DF:IsInArena() then
        if DF.IterateArenaFrames then
            DF:IterateArenaFrames(function(frame)
                if frame and frame:IsShown() then
                    table.insert(frames, frame)
                end
            end)
        end
        return frames
    end

    -- Add party frames (includes player via headers)
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(function(frame)
            if frame and frame:IsShown() then
                table.insert(frames, frame)
            end
        end)
    end

    -- Add raid frames
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(frame)
            if frame and frame:IsShown() then
                table.insert(frames, frame)
            end
        end)
    end

    return frames
end

-- Get frame for a specific unit
function DF:GetFrameForUnit(unit)
    if not unit then return nil end

    local foundFrame = nil

    -- Arena first (IsInRaid()=true in arena, so must check before raid)
    if DF.IsInArena and DF:IsInArena() then
        if DF.IterateArenaFrames then
            DF:IterateArenaFrames(function(frame)
                if frame and frame.unit == unit then
                    foundFrame = frame
                    return true  -- Stop iteration
                end
            end)
        end
        return foundFrame
    end

    -- Check party frames (includes player)
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(function(frame)
            if frame and frame.unit == unit then
                foundFrame = frame
                return true  -- Stop iteration
            end
        end)
        if foundFrame then return foundFrame end
    end

    -- Check raid frames
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(frame)
            if frame and frame.unit == unit then
                foundFrame = frame
                return true  -- Stop iteration
            end
        end)
    end

    return foundFrame
end

-- ============================================================
-- ROLE ICON TEXTURE HELPER
-- Centralizes texture resolution for all role icon styles
-- ============================================================
local ROLE_ICON_TEXTURES = {
    TANK = "Interface\\AddOns\\DandersFrames\\Media\\DF_Tank",
    HEALER = "Interface\\AddOns\\DandersFrames\\Media\\DF_Healer",
    DAMAGER = "Interface\\AddOns\\DandersFrames\\Media\\DF_DPS",
}

local BLIZZARD_ROLE_COORDS = {
    TANK = {0, 0.296875, 0.296875, 0.65},
    HEALER = {0.296875, 0.59375, 0, 0.296875},
    DAMAGER = {0.296875, 0.59375, 0.296875, 0.65},
}

-- Modern micro role atlases — sharper than the legacy PORTRAITROLES texcoord
-- crop. Preferred when present; GetRoleIconTexture falls back to the legacy
-- texture below so older / edge-case clients still render.
local BLIZZARD_ROLE_ATLAS = {
    TANK    = "UI-LFG-RoleIcon-Tank-Micro",
    HEALER  = "UI-LFG-RoleIcon-Healer-Micro",
    DAMAGER = "UI-LFG-RoleIcon-DPS-Micro",
}

function DF:GetRoleIconTexture(db, role)
    local style = db.roleIconStyle or "BLIZZARD"

    if style == "EXTERNAL" then
        local path
        if role == "TANK" then path = db.roleIconExternalTank
        elseif role == "HEALER" then path = db.roleIconExternalHealer
        elseif role == "DAMAGER" then path = db.roleIconExternalDPS
        end
        -- Fall back to DF Icons if path is empty
        if path and path ~= "" then
            -- Strip everything before "Interface" (e.g. full filesystem paths)
            path = path:gsub("^.*[/\\]([Ii]nterface)", "%1")
            -- Strip file extensions (.tga, .blp, .png) — WoW expects paths without them
            path = path:gsub("%.[tT][gG][aA]$", "")
            path = path:gsub("%.[bB][lL][pP]$", "")
            path = path:gsub("%.[pP][nN][gG]$", "")
            return path, 0, 1, 0, 1
        end
        style = "CUSTOM"
    end

    if style == "CUSTOM" then
        return ROLE_ICON_TEXTURES[role], 0, 1, 0, 1
    else
        -- BLIZZARD — prefer the modern micro role atlas, fall back to the legacy
        -- portrait-roles texture + texcoords when the atlas isn't available.
        local atlas = BLIZZARD_ROLE_ATLAS[role]
        if atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
            return atlas  -- atlas name, no texcoords
        end
        local c = BLIZZARD_ROLE_COORDS[role]
        -- Unknown/missing role (e.g. "NONE" or nil for a roleless unit): no icon.
        -- Callers pass the result to SetIconTextureOrAtlas, which no-ops on nil.
        -- Guard prevents indexing a nil coord table (a roleless test/raid unit
        -- otherwise crashed GetRoleIconTexture).
        if not c then return nil end
        return "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES", c[1], c[2], c[3], c[4]
    end
end

-- Sets a texture region from EITHER a Blizzard atlas name or a texture file
-- path, preferring the atlas (sharper, modern) when the name resolves and
-- falling back to the file path otherwise. Mirrors oUF's approach so status
-- icons render crisply on current clients but never break on older ones.
--   value   : atlas name OR texture path
--   l,r,t,b : optional tex coords, applied only on the texture-file path
function DF:SetIconTextureOrAtlas(region, value, l, r, t, b)
    if not region or not value then return end
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(value) then
        region:SetAtlas(value)
    else
        region:SetTexture(value)
        if l then
            region:SetTexCoord(l, r, t, b)
        else
            region:SetTexCoord(0, 1, 0, 1)
        end
    end
end

-- Legacy raid-frame status icon textures → their modern atlas equivalents.
-- The atlas versions (used by Blizzard's own raid frames) are sharper; we keep
-- the legacy path as the lookup key AND the fallback so nothing breaks if an
-- atlas is ever absent.
local LEGACY_STATUS_ICON_ATLAS = {
    ["Interface\\RaidFrame\\ReadyCheck-Ready"]         = "UI-LFG-ReadyMark-Raid",
    ["Interface\\RaidFrame\\ReadyCheck-NotReady"]      = "UI-LFG-DeclineMark-Raid",
    ["Interface\\RaidFrame\\ReadyCheck-Waiting"]       = "UI-LFG-PendingMark-Raid",
    ["Interface\\RaidFrame\\Raid-Icon-SummonPending"]  = "RaidFrame-Icon-SummonPending",
    ["Interface\\RaidFrame\\Raid-Icon-SummonAccepted"] = "RaidFrame-Icon-SummonAccepted",
    ["Interface\\RaidFrame\\Raid-Icon-SummonDeclined"] = "RaidFrame-Icon-SummonDeclined",
    ["Interface\\RaidFrame\\Raid-Icon-Rez"]            = "RaidFrame-Icon-Rez",
    ["Interface\\TargetingFrame\\UI-PhasingIcon"]      = "RaidFrame-Icon-Phasing",
    ["Interface\\LFGFrame\\LFG-Eye"]                   = "RaidFrame-Icon-LFR",
    ["Interface\\FriendsFrame\\StatusIcon-Away"]       = "characterupdate_clock-icon",
    ["Interface\\Vehicles\\UI-Vehicles-Raid-Icon"]     = "RaidFrame-Icon-Vehicle",
    ["Interface\\GroupFrame\\UI-Group-MainTankIcon"]   = "RaidFrame-Icon-MainTank",
    ["Interface\\GroupFrame\\UI-Group-MainAssistIcon"] = "RaidFrame-Icon-MainAssist",
}

-- Render a known legacy status-icon texture as its modern atlas (sharper),
-- falling back to the legacy file when the atlas isn't available. Owns the
-- texcoord state, so call sites must NOT add a trailing SetTexCoord — passing
-- the legacy path as the single source of truth is enough.
function DF:SetUpgradedStatusIcon(region, legacyTexture)
    if not region or not legacyTexture then return end
    local atlas = LEGACY_STATUS_ICON_ATLAS[legacyTexture]
    if atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        region:SetAtlas(atlas)
    else
        region:SetTexture(legacyTexture)
        region:SetTexCoord(0, 1, 0, 1)
    end
end

-- Icon-section header previews (options) register a refresher here. Hooked
-- frame-update functions call DF:RefreshIconPreviews so previews track live
-- setting changes (enable/text toggles). Each refresher self-guards on its
-- section being visible, so this is nearly free when options are closed.
DF.iconPreviewRefreshers = {}
function DF:RefreshIconPreviews()
    local list = self.iconPreviewRefreshers
    if not list then return end
    for i = 1, #list do list[i]() end
end
