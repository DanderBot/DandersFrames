local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - INDICATORS
-- Visual rendering for all 8 indicator types. Creates, shows,
-- hides, and updates indicator elements on unit frames.
--
-- Uses a Begin/Apply/End pattern per frame update:
--   BeginFrame(frame)  -- reset per-frame state
--   Apply(frame, ...)  -- called per active indicator
--   EndFrame(frame)    -- revert anything not applied
--
-- Key design decisions:
--   - Border: Own overlay frame (like highlight system), not
--     modifying the existing frame.border
--   - Icons: Created via DF:CreateAuraIcon() for full expiring
--     indicator, duration text, and stack support
--   - Placed indicators: One per aura name at its configured
--     anchor point — no growth/pushing between auras
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local format = string.format
local GetTime = GetTime
local max, min = math.max, math.min
local issecretvalue = issecretvalue or function() return false end
local GetAuraDataByAuraInstanceID = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID

DF.AuraDesigner = DF.AuraDesigner or {}

local Indicators = {}
DF.AuraDesigner.Indicators = Indicators

-- ============================================================
-- SAFE HELPERS (match the pattern in Features/Auras.lua)
-- ============================================================

local function SafeSetTexture(icon, texture)
    if icon and icon.texture and texture then
        icon.texture:SetTexture(texture)
        return true
    end
end

-- Secret-safe cooldown setter using Duration objects.
-- Real unit: C_UnitAuras.GetAuraDuration → SetCooldownFromDurationObject
-- Preview:  C_DurationUtil.CreateDuration → SetCooldownFromDurationObject
-- Fallback: SetCooldownFromExpirationTime
local function SafeSetCooldown(cooldown, auraData, unit)
    if not cooldown then return end

    -- Path 1: Real unit — get Duration object from the API (handles secrets)
    if unit and auraData.auraInstanceID
       and C_UnitAuras and C_UnitAuras.GetAuraDuration
       and cooldown.SetCooldownFromDurationObject then
        local durationObj = C_UnitAuras.GetAuraDuration(unit, auraData.auraInstanceID)
        if durationObj then
            cooldown:SetCooldownFromDurationObject(durationObj)
            return
        end
    end

    -- Path 2: Preview (no real unit) — build a synthetic Duration object
    local dur = auraData.duration
    local exp = auraData.expirationTime
    if dur and exp and not issecretvalue(dur) and not issecretvalue(exp) and dur > 0 then
        if C_DurationUtil and C_DurationUtil.CreateDuration and cooldown.SetCooldownFromDurationObject then
            local durationObj = C_DurationUtil.CreateDuration()
            durationObj:SetTimeFromStart(exp - dur, dur)
            cooldown:SetCooldownFromDurationObject(durationObj)
            return
        end
        -- Final fallback
        if cooldown.SetCooldownFromExpirationTime then
            cooldown:SetCooldownFromExpirationTime(exp, dur)
        elseif cooldown.SetCooldown then
            cooldown:SetCooldown(exp - dur, dur)
        end
    end
end

-- Secret-safe check for whether an aura has a timer.
-- Uses C_UnitAuras.DoesAuraHaveExpirationTime when available (handles secrets).
-- Falls back to direct comparison when values are non-secret (e.g., preview).
local function HasAuraDuration(auraData, unit)
    -- When a real unit is present, the Duration object pipeline
    -- (SetCooldownFromDurationObject / SetTimerDuration) handles everything
    -- including permanent auras. Return true so we enter those code paths;
    -- the APIs are secret-safe and handle zero-duration correctly.
    -- We avoid DoesAuraHaveExpirationTime because it returns a secret boolean
    -- that can't be used in conditionals.
    if unit and auraData.auraInstanceID then
        return true
    end
    -- Fallback for preview (non-secret mock data)
    local dur = auraData.duration
    local exp = auraData.expirationTime
    if dur and exp then
        if issecretvalue(dur) or issecretvalue(exp) then
            return true
        end
        return dur > 0 and exp > 0
    end
    return false
end

-- ============================================================
-- BORDER OFFSET COMPENSATION
-- Adjusts indicator position so borders don't hang off the frame
-- edge when anchored at a boundary (e.g. TOPLEFT offset 0,0).
-- ============================================================

local function AdjustOffsetForBorder(anchor, offsetX, offsetY, borderSize, borderEnabled)
    if not borderEnabled or not borderSize or borderSize <= 0 then
        return offsetX, offsetY
    end
    local a = anchor or "CENTER"
    if a:find("LEFT") then
        offsetX = offsetX + borderSize
    elseif a:find("RIGHT") then
        offsetX = offsetX - borderSize
    end
    if a:find("TOP") then
        offsetY = offsetY - borderSize
    elseif a:find("BOTTOM") then
        offsetY = offsetY + borderSize
    end
    return offsetX, offsetY
end

-- ============================================================
-- SHARED EXPIRING TICKER
-- Processes all registered indicators with expiring settings
-- at ~3 FPS. Same dual-path approach as bar's OnUpdate:
--   API path:     Build a Step color curve per element, evaluate
--                 via durationObj:EvaluateRemainingPercent → apply
--   Preview path: Manual pct calculation, compare to threshold
-- ============================================================

local expiringRegistry = {}

local function RegisterExpiring(element, entryData)
    expiringRegistry[element] = entryData

    -- Evaluate immediately so the Apply function ends with the correct
    -- color.  Without this the Apply sets the *original* color, then the
    -- ticker (3 FPS) overrides it later → visible flicker.
    -- Same approach as bar's "Set initial bar color" block in ApplyBar.
    local applied = false
    if entryData.colorCurve and entryData.unit and entryData.auraInstanceID
       and C_UnitAuras and C_UnitAuras.GetAuraDuration then
        local durationObj = C_UnitAuras.GetAuraDuration(entryData.unit, entryData.auraInstanceID)
        if durationObj and durationObj.EvaluateRemainingPercent then
            local result = durationObj:EvaluateRemainingPercent(entryData.colorCurve)
            if result and entryData.applyResult then
                entryData.applyResult(element, result, entryData)
                applied = true
            end
        end
    end
    if not applied then
        local dur = entryData.duration
        local exp = entryData.expirationTime
        if dur and exp and not issecretvalue(dur) and not issecretvalue(exp) and dur > 0 then
            local remaining = max(0, exp - GetTime())
            local pct = remaining / dur
            local isExpiring = pct <= ((entryData.threshold or 30) / 100)
            if entryData.applyManual then
                entryData.applyManual(element, isExpiring, entryData)
            end
        end
    end
end

local function UnregisterExpiring(element)
    if element then
        expiringRegistry[element] = nil
    end
end

-- Build a Step color curve encoding two states:
--   Below threshold → expiring color
--   At/above threshold → original color
-- Same pattern as bar's dfAD_colorCurve for expiring-only mode.
local function BuildExpiringColorCurve(threshold, expiringColor, originalColor)
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then return nil end
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    local ecR = expiringColor.r or 1
    local ecG = expiringColor.g or 0.2
    local ecB = expiringColor.b or 0.2
    local ocR = originalColor.r or 1
    local ocG = originalColor.g or 1
    local ocB = originalColor.b or 1
    curve:AddPoint(0, CreateColor(ecR, ecG, ecB, 1))
    curve:AddPoint(threshold / 100, CreateColor(ocR, ocG, ocB, 1))
    curve:AddPoint(1, CreateColor(ocR, ocG, ocB, 1))
    return curve
end

local expiringFrame = CreateFrame("Frame")
local expiringElapsed = 0
expiringFrame:Show()  -- CRITICAL: OnUpdate only fires on visible frames

expiringFrame:SetScript("OnUpdate", function(_, elapsed)
    expiringElapsed = expiringElapsed + elapsed
    if expiringElapsed < 0.33 then return end  -- ~3 FPS
    expiringElapsed = 0

    for element, entry in pairs(expiringRegistry) do
        if not element:IsShown() then
            expiringRegistry[element] = nil
        else
            local applied = false

            -- API path: evaluate color curve (same as bar's OnUpdate)
            if entry.colorCurve and entry.unit and entry.auraInstanceID
               and C_UnitAuras and C_UnitAuras.GetAuraDuration then
                local durationObj = C_UnitAuras.GetAuraDuration(entry.unit, entry.auraInstanceID)
                if durationObj and durationObj.EvaluateRemainingPercent then
                    local result = durationObj:EvaluateRemainingPercent(entry.colorCurve)
                    if result and entry.applyResult then
                        entry.applyResult(element, result, entry)
                        applied = true
                    end
                end
            end

            -- Preview fallback: manual pct comparison (same as bar's preview path)
            if not applied then
                local dur = entry.duration
                local exp = entry.expirationTime
                if dur and exp and not issecretvalue(dur) and not issecretvalue(exp) and dur > 0 then
                    local remaining = max(0, exp - GetTime())
                    local pct = remaining / dur
                    local isExpiring = pct <= ((entry.threshold or 30) / 100)
                    if entry.applyManual then
                        entry.applyManual(element, isExpiring, entry)
                    end
                end
            end
        end
    end
end)

-- ============================================================
-- PER-FRAME STATE
-- Tracks which frame-level indicators were applied this frame
-- so EndFrame can revert unclaimed ones.
-- ============================================================

local function EnsureFrameState(frame)
    if not frame.dfAD then
        frame.dfAD = {
            -- Frame-level claim flags (reset each BeginFrame)
            border = false,
            healthbar = false,
            nametext = false,
            healthtext = false,
            framealpha = false,
            -- Placed indicator tracking: { [auraName] = true } for active this frame
            activeIcons = {},
            activeSquares = {},
            activeBars = {},
            -- Saved defaults for reverting (tintOverlay cached separately)
            savedNameColor = nil,
            savedHealthTextColor = nil,
            savedAlpha = nil,
        }
    end
    return frame.dfAD
end

-- ============================================================
-- BEGIN FRAME
-- Reset per-frame state before Apply calls
-- ============================================================

function Indicators:BeginFrame(frame)
    local state = EnsureFrameState(frame)
    state.border = false
    state.healthbar = false
    state.nametext = false
    state.healthtext = false
    state.framealpha = false
    table.wipe(state.activeIcons)
    table.wipe(state.activeSquares)
    table.wipe(state.activeBars)
end

-- ============================================================
-- APPLY -- DISPATCH TO TYPE HANDLERS
-- ============================================================

function Indicators:Apply(frame, typeKey, config, auraData, defaults, auraName, priority)
    if typeKey == "border" then
        self:ApplyBorder(frame, config, auraData)
    elseif typeKey == "healthbar" then
        self:ApplyHealthBar(frame, config, auraData)
    elseif typeKey == "nametext" then
        self:ApplyNameText(frame, config, auraData)
    elseif typeKey == "healthtext" then
        self:ApplyHealthText(frame, config, auraData)
    elseif typeKey == "framealpha" then
        self:ApplyFrameAlpha(frame, config, auraData)
    elseif typeKey == "icon" then
        self:ApplyIcon(frame, config, auraData, defaults, auraName, priority)
    elseif typeKey == "square" then
        self:ApplySquare(frame, config, auraData, defaults, auraName, priority)
    elseif typeKey == "bar" then
        self:ApplyBar(frame, config, auraData, defaults, auraName, priority)
    end
end

-- ============================================================
-- END FRAME
-- Revert anything not claimed during this frame's Apply calls
-- ============================================================

function Indicators:EndFrame(frame)
    local state = frame.dfAD
    if not state then return end

    -- Revert border
    if not state.border then
        self:RevertBorder(frame)
    end

    -- Revert health bar color
    if not state.healthbar then
        self:RevertHealthBar(frame)
    end

    -- Revert name text color
    if not state.nametext then
        self:RevertNameText(frame)
    end

    -- Revert health text color
    if not state.healthtext then
        self:RevertHealthText(frame)
    end

    -- Revert frame alpha
    if not state.framealpha then
        self:RevertFrameAlpha(frame)
    end

    -- Hide placed indicators not active this frame
    self:HideUnusedIcons(frame, state.activeIcons)
    self:HideUnusedSquares(frame, state.activeSquares)
    self:HideUnusedBars(frame, state.activeBars)
end

-- ============================================================
-- HIDE ALL -- Clear everything (used when AD disabled or no unit)
-- ============================================================

function Indicators:HideAll(frame)
    self:RevertBorder(frame)
    self:RevertHealthBar(frame)
    self:RevertNameText(frame)
    self:RevertHealthText(frame)
    self:RevertFrameAlpha(frame)
    self:HideUnusedIcons(frame, {})
    self:HideUnusedSquares(frame, {})
    self:HideUnusedBars(frame, {})
end

-- ============================================================
-- FRAME-LEVEL INDICATORS
-- These modify existing frame elements. Only the highest
-- priority aura claiming a type wins (first Apply call claims).
-- ============================================================

-- ============================================================
-- BORDER (own overlay frame, like the highlight system)
-- Creates a separate frame parented to UIParent with 4 edge
-- textures. Does NOT modify the existing frame.border.
-- ============================================================

-- Map old border style names to highlight-compatible uppercase keys
local BORDER_STYLE_MIGRATION = { Solid = "SOLID", Glow = "GLOW", Pulse = "SOLID" }

local function GetOrCreateADBorder(frame)
    if frame.dfAD_border then
        -- Update points (frame may have moved)
        frame.dfAD_border:ClearAllPoints()
        frame.dfAD_border:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        frame.dfAD_border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        return frame.dfAD_border
    end

    -- Create overlay frame parented to UIParent (avoids clipping)
    -- Uses same structure as the highlight system so we can reuse
    -- DF.ApplyHighlightStyle for all 6 border modes.
    local ch = CreateFrame("Frame", nil, UIParent)
    ch:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    ch:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    ch:SetFrameStrata(frame:GetFrameStrata())
    ch:SetFrameLevel(frame:GetFrameLevel() + 8)  -- Below aggro(+9) highlight
    ch:Hide()

    -- 4 edge textures (named to match highlight system)
    ch.topLine = ch:CreateTexture(nil, "OVERLAY")
    ch.bottomLine = ch:CreateTexture(nil, "OVERLAY")
    ch.leftLine = ch:CreateTexture(nil, "OVERLAY")
    ch.rightLine = ch:CreateTexture(nil, "OVERLAY")

    -- Hook owner OnHide to hide border
    frame:HookScript("OnHide", function()
        if frame.dfAD_border then
            frame.dfAD_border:Hide()
        end
    end)

    frame.dfAD_border = ch
    return ch
end

function Indicators:ApplyBorder(frame, config, auraData)
    local state = EnsureFrameState(frame)
    if state.border then return end  -- Already claimed by higher priority
    state.border = true

    local color = config.color
    if not color then return end

    local ch = GetOrCreateADBorder(frame)
    local r, g, b = color[1] or color.r or 1, color[2] or color.g or 1, color[3] or color.b or 1
    local alpha = color[4] or color.a or 1
    local thickness = config.thickness or 2
    local inset = config.inset or 0

    -- Migrate old style names (Solid→SOLID, Glow→GLOW, Pulse→SOLID)
    local style = BORDER_STYLE_MIGRATION[config.style] or config.style or "SOLID"

    -- Skip redundant re-apply when the border is already showing with the
    -- same settings.  ApplyHighlightStyle hides everything then rebuilds,
    -- which causes a one-frame flicker for animated borders.
    local auraID = auraData and auraData.auraInstanceID
    if ch:IsShown()
        and ch.dfAD_style == style
        and ch.dfAD_r == r and ch.dfAD_g == g and ch.dfAD_b == b and ch.dfAD_a == alpha
        and ch.dfAD_thickness == thickness and ch.dfAD_inset == inset
        and ch.dfAD_auraID == auraID then
        -- Nothing changed — leave border as-is (animation continues uninterrupted)
        return
    end

    -- Reuse the highlight system's rendering for all 6 border modes
    DF.ApplyHighlightStyle(ch, style, thickness, inset, r, g, b, alpha)

    -- Cache current state for change detection
    ch.dfAD_style = style
    ch.dfAD_r, ch.dfAD_g, ch.dfAD_b, ch.dfAD_a = r, g, b, alpha
    ch.dfAD_thickness = thickness
    ch.dfAD_inset = inset
    ch.dfAD_auraID = auraID

    -- ========================================
    -- EXPIRING: register with shared ticker
    -- ========================================
    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end
    if expiringEnabled then
        local ec = config.expiringColor or {r = 1, g = 0.2, b = 0.2}
        local oc = {r = r, g = g, b = b}
        RegisterExpiring(ch, {
            unit = frame.unit,
            auraInstanceID = auraID,
            threshold = config.expiringThreshold or 30,
            duration = auraData and auraData.duration,
            expirationTime = auraData and auraData.expirationTime,
            colorCurve = BuildExpiringColorCurve(config.expiringThreshold or 30, ec, oc),
            color = ec, originalColor = oc,
            originalAlpha = alpha, style = style, thickness = thickness, inset = inset,
            applyResult = function(el, result, entry)
                DF.ApplyHighlightStyle(el, entry.style, entry.thickness, entry.inset, result.r, result.g, result.b, entry.originalAlpha)
            end,
            applyManual = function(el, isExp, entry)
                if isExp then
                    local c = entry.color
                    DF.ApplyHighlightStyle(el, entry.style, entry.thickness, entry.inset, c.r or 1, c.g or 0.2, c.b or 0.2, entry.originalAlpha)
                else
                    local c = entry.originalColor
                    DF.ApplyHighlightStyle(el, entry.style, entry.thickness, entry.inset, c.r, c.g, c.b, entry.originalAlpha)
                end
            end,
        })
    else
        UnregisterExpiring(ch)
    end
end

function Indicators:RevertBorder(frame)
    if frame and frame.dfAD_border then
        UnregisterExpiring(frame.dfAD_border)
        -- Use NONE mode to properly clean up all styles (animated, glow, corners, etc.)
        DF.ApplyHighlightStyle(frame.dfAD_border, "NONE", 2, 0, 1, 1, 1, 1)
        -- Clear cached state so next ApplyBorder won't skip via change detection
        frame.dfAD_border.dfAD_style = nil
        frame.dfAD_border.dfAD_auraID = nil
    end
end

-- ============================================================
-- HEALTH BAR COLOR
-- Tint mode uses a colored overlay texture instead of arithmetic
-- blending — health bar colors may be secret (tainted) values
-- that cannot be used in Lua math. The blend slider controls
-- the overlay alpha, so the bar color shows through naturally.
-- ============================================================

local function GetOrCreateTintOverlay(frame)
    local state = frame.dfAD
    if state and state.tintOverlay then return state.tintOverlay end

    local healthBar = frame.healthBar
    if not healthBar then return nil end

    -- StatusBar so the fill tracks current health (same pattern as dispel gradient
    -- and buff indicator overlays). Parented to healthBar for proper layering.
    local overlay = CreateFrame("StatusBar", nil, healthBar)
    overlay:SetAllPoints(healthBar)
    overlay:SetFrameLevel(healthBar:GetFrameLevel() + 1)
    overlay:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    overlay:SetMinMaxValues(0, 1)
    overlay:SetValue(1)
    overlay:Hide()

    if state then
        state.tintOverlay = overlay
    end
    return overlay
end

function Indicators:ApplyHealthBar(frame, config, auraData)
    local state = EnsureFrameState(frame)
    if state.healthbar then return end
    state.healthbar = true

    local healthBar = frame.healthBar
    if not healthBar then return end

    local color = config.color
    if not color then return end

    local r, g, b = color[1] or color.r or 1, color[2] or color.g or 1, color[3] or color.b or 1
    local mode = string.lower(config.mode or "replace")
    -- Both modes use the overlay — replace forces full opacity, tint uses blend slider
    local blend = (mode == "replace") and 1 or (config.blend or 0.5)

    local overlay = GetOrCreateTintOverlay(frame)
    if overlay then
        overlay:SetStatusBarColor(r, g, b, blend)
        overlay:Show()
        -- Sync fill with current health
        if DF.UpdateADTintHealth then
            DF:UpdateADTintHealth(frame)
        end
    end

    -- ========================================
    -- EXPIRING: register overlay with ticker
    -- ========================================
    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end
    if expiringEnabled and overlay then
        local ec = config.expiringColor or {r = 1, g = 0.2, b = 0.2}
        local oc = {r = r, g = g, b = b}
        RegisterExpiring(overlay, {
            unit = frame.unit,
            auraInstanceID = auraData and auraData.auraInstanceID,
            threshold = config.expiringThreshold or 30,
            duration = auraData and auraData.duration,
            expirationTime = auraData and auraData.expirationTime,
            blend = blend,
            colorCurve = BuildExpiringColorCurve(config.expiringThreshold or 30, ec, oc),
            color = ec, originalColor = oc,
            applyResult = function(el, result, entry)
                el:SetStatusBarColor(result.r, result.g, result.b, entry.blend)
            end,
            applyManual = function(el, isExp, entry)
                local c = isExp and entry.color or entry.originalColor
                el:SetStatusBarColor(c.r or 1, c.g or 1, c.b or 1, entry.blend)
            end,
        })
    elseif overlay then
        UnregisterExpiring(overlay)
    end
end

function Indicators:RevertHealthBar(frame)
    local state = frame and frame.dfAD
    if not state then return end

    -- Hide overlay and unregister its expiring ticker
    if state.tintOverlay then
        UnregisterExpiring(state.tintOverlay)
        state.tintOverlay:Hide()
    end
end

-- Update tint overlay fill to match current health.
-- Called from UpdateUnitFrame and UpdateHealthFast (same pattern as
-- DF:UpdateDispelGradientHealth and DF:UpdateMyBuffGradientHealth).
function DF:UpdateADTintHealth(frame)
    if not frame or not frame.dfAD then return end

    local overlay = frame.dfAD.tintOverlay
    if not overlay or not overlay:IsShown() then return end

    local unit = frame.unit
    if not unit or not UnitExists(unit) then return end

    local db = DF:GetFrameDB(frame)

    -- Match health bar orientation and fill direction
    local orient = db and db.healthOrientation or "HORIZONTAL"
    if orient == "HORIZONTAL" then
        overlay:SetOrientation("HORIZONTAL")
        overlay:SetReverseFill(false)
    elseif orient == "HORIZONTAL_INV" then
        overlay:SetOrientation("HORIZONTAL")
        overlay:SetReverseFill(true)
    elseif orient == "VERTICAL" then
        overlay:SetOrientation("VERTICAL")
        overlay:SetReverseFill(false)
    elseif orient == "VERTICAL_INV" then
        overlay:SetOrientation("VERTICAL")
        overlay:SetReverseFill(true)
    end

    -- StatusBar API handles secret values internally
    local maxHealth = UnitHealthMax(unit)
    local currentHealth = UnitHealth(unit, true)

    overlay:SetMinMaxValues(0, maxHealth)

    local smoothEnabled = db and db.smoothBars
    if smoothEnabled and Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut then
        overlay:SetValue(currentHealth, Enum.StatusBarInterpolation.ExponentialEaseOut)
    else
        overlay:SetValue(currentHealth)
    end
end

-- ============================================================
-- NAME TEXT COLOR
-- ============================================================

function Indicators:ApplyNameText(frame, config, auraData)
    local state = EnsureFrameState(frame)
    if state.nametext then return end
    state.nametext = true

    local nameText = frame.nameText
    if not nameText then return end

    -- Save original color on first use
    if not state.savedNameColor then
        local r, g, b, a = nameText:GetTextColor()
        state.savedNameColor = { r = r, g = g, b = b, a = a }
    end

    local color = config.color
    if color then
        local r, g, b = color[1] or color.r or 1, color[2] or color.g or 1, color[3] or color.b or 1
        nameText:SetTextColor(r, g, b, 1)

        -- ========================================
        -- EXPIRING: register with shared ticker
        -- ========================================
        local expiringEnabled = config.expiringEnabled
        if expiringEnabled == nil then expiringEnabled = false end
        if expiringEnabled then
            local ec = config.expiringColor or {r = 1, g = 0.2, b = 0.2}
            local oc = {r = r, g = g, b = b}
            RegisterExpiring(nameText, {
                unit = frame.unit,
                auraInstanceID = auraData and auraData.auraInstanceID,
                threshold = config.expiringThreshold or 30,
                duration = auraData and auraData.duration,
                expirationTime = auraData and auraData.expirationTime,
                colorCurve = BuildExpiringColorCurve(config.expiringThreshold or 30, ec, oc),
                color = ec, originalColor = oc,
                applyResult = function(el, result, entry)
                    el:SetTextColor(result.r, result.g, result.b, result.a or 1)
                end,
                applyManual = function(el, isExp, entry)
                    if isExp then
                        local c = entry.color
                        el:SetTextColor(c.r or 1, c.g or 0.2, c.b or 0.2, 1)
                    else
                        local c = entry.originalColor
                        el:SetTextColor(c.r, c.g, c.b, 1)
                    end
                end,
            })
        else
            UnregisterExpiring(nameText)
        end
    end
end

function Indicators:RevertNameText(frame)
    local state = frame and frame.dfAD
    if not state or not state.savedNameColor then return end

    local nameText = frame.nameText
    if not nameText then return end

    UnregisterExpiring(nameText)
    local c = state.savedNameColor
    nameText:SetTextColor(c.r, c.g, c.b, c.a)
    state.savedNameColor = nil  -- Re-capture next time
end

-- ============================================================
-- HEALTH TEXT COLOR
-- ============================================================

function Indicators:ApplyHealthText(frame, config, auraData)
    local state = EnsureFrameState(frame)
    if state.healthtext then return end
    state.healthtext = true

    local healthText = frame.healthText
    if not healthText then return end

    -- Save original color on first use
    if not state.savedHealthTextColor then
        local r, g, b, a = healthText:GetTextColor()
        state.savedHealthTextColor = { r = r, g = g, b = b, a = a }
    end

    local color = config.color
    if color then
        local r, g, b = color[1] or color.r or 1, color[2] or color.g or 1, color[3] or color.b or 1
        healthText:SetTextColor(r, g, b, 1)

        -- ========================================
        -- EXPIRING: register with shared ticker
        -- ========================================
        local expiringEnabled = config.expiringEnabled
        if expiringEnabled == nil then expiringEnabled = false end
        if expiringEnabled then
            local ec = config.expiringColor or {r = 1, g = 0.2, b = 0.2}
            local oc = {r = r, g = g, b = b}
            RegisterExpiring(healthText, {
                unit = frame.unit,
                auraInstanceID = auraData and auraData.auraInstanceID,
                threshold = config.expiringThreshold or 30,
                duration = auraData and auraData.duration,
                expirationTime = auraData and auraData.expirationTime,
                colorCurve = BuildExpiringColorCurve(config.expiringThreshold or 30, ec, oc),
                color = ec, originalColor = oc,
                applyResult = function(el, result, entry)
                    el:SetTextColor(result.r, result.g, result.b, result.a or 1)
                end,
                applyManual = function(el, isExp, entry)
                    if isExp then
                        local c = entry.color
                        el:SetTextColor(c.r or 1, c.g or 0.2, c.b or 0.2, 1)
                    else
                        local c = entry.originalColor
                        el:SetTextColor(c.r, c.g, c.b, 1)
                    end
                end,
            })
        else
            UnregisterExpiring(healthText)
        end
    end
end

function Indicators:RevertHealthText(frame)
    local state = frame and frame.dfAD
    if not state or not state.savedHealthTextColor then return end

    local healthText = frame.healthText
    if not healthText then return end

    UnregisterExpiring(healthText)
    local c = state.savedHealthTextColor
    healthText:SetTextColor(c.r, c.g, c.b, c.a)
    state.savedHealthTextColor = nil
end

-- ============================================================
-- FRAME ALPHA
-- ============================================================

function Indicators:ApplyFrameAlpha(frame, config, auraData)
    local state = EnsureFrameState(frame)
    if state.framealpha then return end
    state.framealpha = true

    -- Save original alpha on first use
    if not state.savedAlpha then
        state.savedAlpha = frame:GetAlpha()
    end

    local alpha = config.alpha
    if alpha then
        frame:SetAlpha(alpha)
    end

    -- ========================================
    -- EXPIRING: register with shared ticker
    -- ========================================
    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end
    if expiringEnabled then
        local expiringAlpha = config.expiringAlpha or 1.0
        local originalAlpha = alpha or (state.savedAlpha or 1.0)
        -- Encode alpha values in the R channel of a color curve
        local ec = {r = expiringAlpha, g = 0, b = 0}
        local oc = {r = originalAlpha, g = 0, b = 0}
        RegisterExpiring(frame, {
            unit = frame.unit,
            auraInstanceID = auraData and auraData.auraInstanceID,
            threshold = config.expiringThreshold or 30,
            duration = auraData and auraData.duration,
            expirationTime = auraData and auraData.expirationTime,
            colorCurve = BuildExpiringColorCurve(config.expiringThreshold or 30, ec, oc),
            expiringAlpha = expiringAlpha,
            originalAlpha = originalAlpha,
            applyResult = function(el, result, entry)
                -- Alpha encoded in R channel of the curve
                el:SetAlpha(result.r)
            end,
            applyManual = function(el, isExp, entry)
                if isExp then
                    el:SetAlpha(entry.expiringAlpha)
                else
                    el:SetAlpha(entry.originalAlpha)
                end
            end,
        })
    else
        UnregisterExpiring(frame)
    end
end

function Indicators:RevertFrameAlpha(frame)
    local state = frame and frame.dfAD
    if not state or not state.savedAlpha then return end

    UnregisterExpiring(frame)
    frame:SetAlpha(state.savedAlpha)
    state.savedAlpha = nil
end

-- ============================================================
-- PLACED INDICATORS -- ICON
-- One icon per aura at its configured anchor point.
-- Uses DF:CreateAuraIcon() for full expiring indicator,
-- duration text, stack count, and cooldown swipe support.
-- ============================================================

-- Get or create the icon map for a frame: { [auraName] = icon }
local function GetIconMap(frame)
    if not frame.dfAD_icons then
        frame.dfAD_icons = {}
    end
    return frame.dfAD_icons
end

local function GetOrCreateADIcon(frame, auraName)
    local map = GetIconMap(frame)
    if map[auraName] then return map[auraName] end

    -- Use the same icon creation as the rest of the addon
    local icon = DF:CreateAuraIcon(frame, 0, "BUFF")
    icon.dfAD_auraName = auraName

    -- Store default settings for the aura timer system
    icon.showDuration = true
    icon.durationColorByTime = true
    icon.durationAnchor = "CENTER"
    icon.durationX = 0
    icon.durationY = 0
    icon.stackMinimum = 2

    map[auraName] = icon
    return icon
end

function Indicators:ApplyIcon(frame, config, auraData, defaults, auraName, priority)
    local state = EnsureFrameState(frame)
    state.activeIcons[auraName] = true

    local icon = GetOrCreateADIcon(frame, auraName)

    -- Store aura data for tooltip lookups (parent-driven via ShowDFAuraTooltip)
    if auraData then
        if not icon.auraData then
            icon.auraData = { index = 0, auraInstanceID = nil }
        end
        icon.auraData.auraInstanceID = auraData.auraInstanceID
    end

    -- Size
    local size = config.size or (defaults and defaults.iconSize) or 24
    local scale = config.scale or (defaults and defaults.iconScale) or 1.0
    icon:SetSize(size, size)
    icon:SetScale(scale)

    -- Alpha
    icon:SetAlpha(config.alpha or 1.0)

    -- Position — each aura has its own anchor, no growth
    local anchor = config.anchor or "TOPLEFT"
    local offsetX = config.offsetX or 0
    local offsetY = config.offsetY or 0
    -- Compensate for border overhang at frame edges
    local borderEnabledForPos = config.borderEnabled
    if borderEnabledForPos == nil then borderEnabledForPos = true end
    offsetX, offsetY = AdjustOffsetForBorder(anchor, offsetX, offsetY, config.borderInset or 1, borderEnabledForPos)
    icon:ClearAllPoints()
    icon:SetPoint(anchor, frame, anchor, offsetX, offsetY)

    -- Frame level: higher priority (lower number) = higher frame level
    local baseLevel = (frame.contentOverlay or frame):GetFrameLevel() + 10
    local priorityBoost = 20 - (priority or 5)
    icon:SetFrameLevel(baseLevel + priorityBoost)

    -- Texture
    if auraData.icon then
        SafeSetTexture(icon, auraData.icon)
    elseif auraData.spellId and C_Spell and C_Spell.GetSpellTexture then
        SafeSetTexture(icon, C_Spell.GetSpellTexture(auraData.spellId))
    end

    -- Cooldown — uses Duration object pipeline (secret-safe)
    local hasDuration = HasAuraDuration(auraData, frame.unit)
    if hasDuration then
        SafeSetCooldown(icon.cooldown, auraData, frame.unit)
        icon.cooldown:SetDrawSwipe(not config.hideSwipe)
        icon.cooldown:Show()
    else
        icon.cooldown:SetDrawSwipe(false)
        icon.cooldown:Hide()
    end

    -- ========================================
    -- BORDER (the black background behind the icon texture)
    -- ========================================
    local borderEnabled = config.borderEnabled
    if borderEnabled == nil then borderEnabled = true end
    local borderThickness = config.borderThickness or 1
    local borderInset = config.borderInset or 1

    if icon.border then
        if borderEnabled then
            icon.border:ClearAllPoints()
            icon.border:SetPoint("TOPLEFT", icon, "TOPLEFT", -borderInset, borderInset)
            icon.border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", borderInset, -borderInset)
            icon.border:SetColorTexture(0, 0, 0, 0.8)
            icon.border:Show()
        else
            icon.border:Hide()
        end
    end

    -- Adjust texture inset to sit inside border
    if icon.texture then
        icon.texture:ClearAllPoints()
        local texInset = borderEnabled and borderThickness or 0
        icon.texture:SetPoint("TOPLEFT", texInset, -texInset)
        icon.texture:SetPoint("BOTTOMRIGHT", -texInset, texInset)
        icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end

    -- ========================================
    -- STACK COUNT
    -- ========================================
    local showStacks = config.showStacks
    if showStacks == nil then showStacks = true end
    local stackMin = config.stackMinimum or 2
    icon.stackMinimum = stackMin

    -- Stack font/style (instance → global defaults → hardcoded)
    local stackFont = config.stackFont or (defaults and defaults.stackFont) or "Fonts\\FRIZQT__.TTF"
    local stackScale = config.stackScale or (defaults and defaults.stackScale) or 1.0
    local stackOutline = config.stackOutline or (defaults and defaults.stackOutline) or "OUTLINE"
    if stackOutline == "NONE" then stackOutline = "" end
    local stackAnchor = config.stackAnchor or "BOTTOMRIGHT"
    local stackX = config.stackX or 0
    local stackY = config.stackY or 0

    if icon.count then
        local stackSize = 10 * stackScale
        DF:SafeSetFont(icon.count, stackFont, stackSize, stackOutline)
        icon.count:ClearAllPoints()
        icon.count:SetPoint(stackAnchor, icon, stackAnchor, stackX, stackY)

        -- Secret-safe stack display: use Blizzard API when available
        icon.count:SetText("")
        icon.count:Hide()
        if showStacks then
            local unit = frame.unit
            local auraInstanceID = auraData.auraInstanceID
            if unit and auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
                -- Blizzard API: returns pre-formatted display text, handles secrets
                local stackText = C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID, stackMin, 99)
                if stackText then
                    icon.count:SetText(stackText)
                    icon.count:Show()
                end
            elseif auraData.stacks then
                -- Fallback for preview (no unit/auraInstanceID)
                if not issecretvalue(auraData.stacks) and auraData.stacks >= stackMin then
                    icon.count:SetText(auraData.stacks)
                    icon.count:Show()
                end
            end
        end
    end

    -- ========================================
    -- DURATION TEXT (via native cooldown text, same as Auras.lua)
    -- ========================================
    local showDuration = config.showDuration
    if showDuration == nil then showDuration = true end
    local durationFont = config.durationFont or (defaults and defaults.durationFont) or "Fonts\\FRIZQT__.TTF"
    local durationScale = config.durationScale or (defaults and defaults.durationScale) or 1.0
    local durationOutline = config.durationOutline or (defaults and defaults.durationOutline) or "OUTLINE"
    if durationOutline == "NONE" then durationOutline = "" end
    local durationAnchor = config.durationAnchor or "CENTER"
    local durationX = config.durationX or 0
    local durationY = config.durationY or 0
    local durationColorByTime = config.durationColorByTime
    if durationColorByTime == nil then durationColorByTime = true end

    -- Wire settings to icon properties (read by shared aura timer if registered)
    icon.showDuration = showDuration
    icon.durationColorByTime = durationColorByTime
    icon.durationAnchor = durationAnchor
    icon.durationX = durationX
    icon.durationY = durationY
    icon.cooldown:SetHideCountdownNumbers(not showDuration)

    -- Find native cooldown text if not yet cached (same scan as the shared timer)
    if not icon.nativeCooldownText and icon.cooldown then
        local regions = { icon.cooldown:GetRegions() }
        for _, region in pairs(regions) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                icon.nativeCooldownText = region
                icon.nativeTextReparented = false
                break
            end
        end
    end

    -- Reparent, style, and position the native countdown text directly
    -- (AD icons may not be registered with the shared timer, so we do it here)
    if icon.nativeCooldownText then
        if showDuration then
            -- Reparent to textOverlay so it draws above cooldown swipe
            if not icon.nativeTextReparented and icon.textOverlay then
                icon.nativeCooldownText:SetParent(icon.textOverlay)
                icon.nativeTextReparented = true
            end
            -- Style
            local durationSize = 10 * durationScale
            DF:SafeSetFont(icon.nativeCooldownText, durationFont, durationSize, durationOutline)
            -- Position
            icon.nativeCooldownText:ClearAllPoints()
            icon.nativeCooldownText:SetPoint(durationAnchor, icon, durationAnchor, durationX, durationY)
            icon.nativeCooldownText:Show()

            -- Color by remaining time (green → yellow → orange → red)
            if durationColorByTime and hasDuration then
                local usedAPI = false
                -- API path: works with secret values (in combat)
                if frame.unit and auraData.auraInstanceID
                   and C_UnitAuras and C_UnitAuras.GetAuraDuration
                   and C_CurveUtil and C_CurveUtil.CreateColorCurve then
                    local durationObj = C_UnitAuras.GetAuraDuration(frame.unit, auraData.auraInstanceID)
                    if durationObj and durationObj.EvaluateRemainingPercent then
                        if not DF.durationColorCurve then
                            DF.durationColorCurve = C_CurveUtil.CreateColorCurve()
                            DF.durationColorCurve:SetType(Enum.LuaCurveType.Linear)
                            DF.durationColorCurve:AddPoint(0, CreateColor(1, 0, 0, 1))
                            DF.durationColorCurve:AddPoint(0.3, CreateColor(1, 0.5, 0, 1))
                            DF.durationColorCurve:AddPoint(0.5, CreateColor(1, 1, 0, 1))
                            DF.durationColorCurve:AddPoint(1, CreateColor(0, 1, 0, 1))
                        end
                        local result = durationObj:EvaluateRemainingPercent(DF.durationColorCurve)
                        if result and result.r then
                            icon.nativeCooldownText:SetTextColor(result.r, result.g, result.b)
                        end
                        usedAPI = true
                    end
                end
                -- Manual fallback for preview (non-secret values)
                if not usedAPI then
                    local exp = auraData.expirationTime
                    local dur = auraData.duration
                    if exp and dur and not issecretvalue(exp) and not issecretvalue(dur) and dur > 0 then
                        local remaining = exp - GetTime()
                        local pct = max(0, min(1, remaining / dur))
                        local r, g, b
                        if pct < 0.3 then
                            local t = pct / 0.3
                            r, g, b = 1, 0.5 * t, 0
                        elseif pct < 0.5 then
                            local t = (pct - 0.3) / 0.2
                            r, g, b = 1, 0.5 + 0.5 * t, 0
                        else
                            local t = (pct - 0.5) / 0.5
                            r, g, b = 1 - t, 1, 0
                        end
                        icon.nativeCooldownText:SetTextColor(r, g, b, 1)
                    end
                end
            else
                icon.nativeCooldownText:SetTextColor(1, 1, 1, 1)
            end
        else
            icon.nativeCooldownText:Hide()
        end
    end

    -- ========================================
    -- EXPIRING: register with shared ticker
    -- ========================================
    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end
    if expiringEnabled then
        local ec = config.expiringColor or {r = 1, g = 0.2, b = 0.2}
        local oc = {r = 0, g = 0, b = 0}  -- icon border default = black
        RegisterExpiring(icon, {
            unit = frame.unit,
            auraInstanceID = auraData and auraData.auraInstanceID,
            threshold = config.expiringThreshold or 30,
            duration = auraData and auraData.duration,
            expirationTime = auraData and auraData.expirationTime,
            colorCurve = BuildExpiringColorCurve(config.expiringThreshold or 30, ec, oc),
            color = ec,
            applyResult = function(el, result, entry)
                if el.border then
                    el.border:SetColorTexture(result.r, result.g, result.b, result.a or 1)
                end
            end,
            applyManual = function(el, isExp, entry)
                if el.border then
                    if isExp then
                        local c = entry.color
                        el.border:SetColorTexture(c.r or 1, c.g or 0.2, c.b or 0.2, 1)
                    else
                        el.border:SetColorTexture(0, 0, 0, 0.8)
                    end
                end
            end,
        })
    else
        UnregisterExpiring(icon)
    end

    -- Mouse handling: propagate motion/clicks to parent for tooltips and click-casting
    if not InCombatLockdown() then
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

    icon:Show()
end

function Indicators:HideUnusedIcons(frame, activeMap)
    local map = frame and frame.dfAD_icons
    if not map then return end
    for auraName, icon in pairs(map) do
        if not activeMap[auraName] then
            UnregisterExpiring(icon)
            icon:Hide()
        end
    end
end

-- ============================================================
-- PLACED INDICATORS -- SQUARE
-- One colored square per aura at its configured anchor point.
-- ============================================================

local function GetSquareMap(frame)
    if not frame.dfAD_squares then
        frame.dfAD_squares = {}
    end
    return frame.dfAD_squares
end

local function CreateADSquare(frame, auraName)
    local sq = CreateFrame("Frame", nil, frame.contentOverlay or frame)
    sq:SetSize(8, 8)
    sq:SetFrameLevel((frame.contentOverlay or frame):GetFrameLevel() + 10)
    sq.dfAD_auraName = auraName

    sq.border = sq:CreateTexture(nil, "BACKGROUND")
    sq.border:SetAllPoints()
    sq.border:SetColorTexture(0, 0, 0, 1)

    sq.texture = sq:CreateTexture(nil, "ARTWORK")
    sq.texture:SetPoint("TOPLEFT", 1, -1)
    sq.texture:SetPoint("BOTTOMRIGHT", -1, 1)

    -- Cooldown (swipe effect) — same setup as DF:CreateAuraIcon
    sq.cooldown = CreateFrame("Cooldown", nil, sq, "CooldownFrameTemplate")
    sq.cooldown:SetAllPoints(sq.texture)
    sq.cooldown:SetDrawEdge(false)
    sq.cooldown:SetDrawSwipe(true)
    sq.cooldown:SetReverse(true)
    sq.cooldown:SetHideCountdownNumbers(false)

    -- Text overlay above the cooldown swipe for stacks + duration
    sq.textOverlay = CreateFrame("Frame", nil, sq)
    sq.textOverlay:SetAllPoints(sq)
    sq.textOverlay:SetFrameLevel(sq.cooldown:GetFrameLevel() + 5)
    sq.textOverlay:EnableMouse(false)

    -- Stack count (on textOverlay so it draws above swipe)
    sq.count = sq.textOverlay:CreateFontString(nil, "OVERLAY")
    sq.count:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
    sq.count:SetPoint("CENTER", 0, 0)
    sq.count:SetTextColor(1, 1, 1)

    sq:Hide()
    return sq
end

local function GetOrCreateADSquare(frame, auraName)
    local map = GetSquareMap(frame)
    if map[auraName] then return map[auraName] end
    local sq = CreateADSquare(frame, auraName)
    map[auraName] = sq
    return sq
end

function Indicators:ApplySquare(frame, config, auraData, defaults, auraName, priority)
    local state = EnsureFrameState(frame)
    state.activeSquares[auraName] = true

    local sq = GetOrCreateADSquare(frame, auraName)

    -- Size & scale (fall back to global defaults, same as icon)
    local size = config.size or (defaults and defaults.iconSize) or 24
    local scale = config.scale or (defaults and defaults.iconScale) or 1.0
    sq:SetSize(size, size)
    sq:SetScale(scale)

    -- Alpha
    sq:SetAlpha(config.alpha or 1.0)

    -- Color
    local color = config.color
    if color then
        sq.texture:SetColorTexture(color[1] or color.r or 1, color[2] or color.g or 1, color[3] or color.b or 1, 1)
    else
        sq.texture:SetColorTexture(1, 1, 1, 1)
    end

    -- Position — each aura has its own anchor, no growth
    local anchor = config.anchor or "TOPLEFT"
    local offsetX = config.offsetX or 0
    local offsetY = config.offsetY or 0
    -- Compensate for border overhang at frame edges
    local showBorderForPos = config.showBorder
    if showBorderForPos == nil then showBorderForPos = true end
    offsetX, offsetY = AdjustOffsetForBorder(anchor, offsetX, offsetY, config.borderInset or 1, showBorderForPos)
    sq:ClearAllPoints()
    sq:SetPoint(anchor, frame, anchor, offsetX, offsetY)

    -- Frame level: higher priority (lower number) = higher frame level
    local baseLevel = (frame.contentOverlay or frame):GetFrameLevel() + 10
    local priorityBoost = 20 - (priority or 5)
    sq:SetFrameLevel(baseLevel + priorityBoost)

    -- ========================================
    -- BORDER
    -- ========================================
    local showBorder = config.showBorder
    if showBorder == nil then showBorder = true end
    local borderThickness = config.borderThickness or 1
    local borderInset = config.borderInset or 1

    if showBorder then
        sq.border:ClearAllPoints()
        sq.border:SetPoint("TOPLEFT", sq, "TOPLEFT", -borderInset, borderInset)
        sq.border:SetPoint("BOTTOMRIGHT", sq, "BOTTOMRIGHT", borderInset, -borderInset)
        sq.border:SetColorTexture(0, 0, 0, 1)
        sq.border:Show()
    else
        sq.border:Hide()
    end

    -- Adjust texture inset to sit inside border
    sq.texture:ClearAllPoints()
    local texInset = showBorder and borderThickness or 0
    sq.texture:SetPoint("TOPLEFT", texInset, -texInset)
    sq.texture:SetPoint("BOTTOMRIGHT", -texInset, texInset)

    -- ========================================
    -- COOLDOWN SWIPE (Duration object pipeline)
    -- ========================================
    local hasDuration = HasAuraDuration(auraData, frame.unit)
    if sq.cooldown then
        if hasDuration then
            SafeSetCooldown(sq.cooldown, auraData, frame.unit)
            sq.cooldown:SetDrawSwipe(not config.hideSwipe)
            sq.cooldown:Show()
        else
            sq.cooldown:SetDrawSwipe(false)
            sq.cooldown:Hide()
        end
    end

    -- ========================================
    -- STACK COUNT (secret-safe via Blizzard API)
    -- ========================================
    local showStacks = config.showStacks
    if showStacks == nil then showStacks = true end
    local stackMin = config.stackMinimum or 2
    local stackFont = config.stackFont or (defaults and defaults.stackFont) or "Fonts\\FRIZQT__.TTF"
    local stackScale = config.stackScale or (defaults and defaults.stackScale) or 1.0
    local stackOutline = config.stackOutline or (defaults and defaults.stackOutline) or "OUTLINE"
    if stackOutline == "NONE" then stackOutline = "" end
    local stackAnchor = config.stackAnchor or "BOTTOMRIGHT"
    local stackX = config.stackX or 0
    local stackY = config.stackY or 0

    if sq.count then
        local stackSize = 10 * stackScale
        DF:SafeSetFont(sq.count, stackFont, stackSize, stackOutline)
        sq.count:ClearAllPoints()
        sq.count:SetPoint(stackAnchor, sq, stackAnchor, stackX, stackY)

        sq.count:SetText("")
        sq.count:Hide()
        if showStacks then
            local unit = frame.unit
            local auraInstanceID = auraData.auraInstanceID
            if unit and auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
                local stackText = C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID, stackMin, 99)
                if stackText then
                    sq.count:SetText(stackText)
                    sq.count:Show()
                end
            elseif auraData.stacks then
                if not issecretvalue(auraData.stacks) and auraData.stacks >= stackMin then
                    sq.count:SetText(auraData.stacks)
                    sq.count:Show()
                end
            end
        end
    end

    -- ========================================
    -- DURATION TEXT (via native cooldown text, same approach as icons)
    -- ========================================
    local showDuration = config.showDuration
    if showDuration == nil then showDuration = true end
    local durationFont = config.durationFont or (defaults and defaults.durationFont) or "Fonts\\FRIZQT__.TTF"
    local durationScale = config.durationScale or (defaults and defaults.durationScale) or 1.0
    local durationOutline = config.durationOutline or (defaults and defaults.durationOutline) or "OUTLINE"
    if durationOutline == "NONE" then durationOutline = "" end
    local durationAnchor = config.durationAnchor or "CENTER"
    local durationX = config.durationX or 0
    local durationY = config.durationY or 0
    local durationColorByTime = config.durationColorByTime
    if durationColorByTime == nil then durationColorByTime = true end

    if sq.cooldown then
        sq.cooldown:SetHideCountdownNumbers(not showDuration)
    end

    -- Find native cooldown text if not yet cached (same region scan as icons)
    if not sq.nativeCooldownText and sq.cooldown then
        local regions = { sq.cooldown:GetRegions() }
        for _, region in pairs(regions) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                sq.nativeCooldownText = region
                sq.nativeTextReparented = false
                break
            end
        end
    end

    -- Reparent, style, and position the native countdown text
    if sq.nativeCooldownText then
        if showDuration and hasDuration then
            if not sq.nativeTextReparented and sq.textOverlay then
                sq.nativeCooldownText:SetParent(sq.textOverlay)
                sq.nativeTextReparented = true
            end
            local durationSize = 10 * durationScale
            DF:SafeSetFont(sq.nativeCooldownText, durationFont, durationSize, durationOutline)
            sq.nativeCooldownText:ClearAllPoints()
            sq.nativeCooldownText:SetPoint(durationAnchor, sq, durationAnchor, durationX, durationY)
            sq.nativeCooldownText:Show()

            -- Color by remaining time (green → yellow → orange → red)
            if durationColorByTime then
                local usedAPI = false
                if frame.unit and auraData.auraInstanceID
                   and C_UnitAuras and C_UnitAuras.GetAuraDuration
                   and C_CurveUtil and C_CurveUtil.CreateColorCurve then
                    local durationObj = C_UnitAuras.GetAuraDuration(frame.unit, auraData.auraInstanceID)
                    if durationObj and durationObj.EvaluateRemainingPercent then
                        if not DF.durationColorCurve then
                            DF.durationColorCurve = C_CurveUtil.CreateColorCurve()
                            DF.durationColorCurve:SetType(Enum.LuaCurveType.Linear)
                            DF.durationColorCurve:AddPoint(0, CreateColor(1, 0, 0, 1))
                            DF.durationColorCurve:AddPoint(0.3, CreateColor(1, 0.5, 0, 1))
                            DF.durationColorCurve:AddPoint(0.5, CreateColor(1, 1, 0, 1))
                            DF.durationColorCurve:AddPoint(1, CreateColor(0, 1, 0, 1))
                        end
                        local result = durationObj:EvaluateRemainingPercent(DF.durationColorCurve)
                        if result and result.r then
                            sq.nativeCooldownText:SetTextColor(result.r, result.g, result.b)
                        end
                        usedAPI = true
                    end
                end
                if not usedAPI then
                    local exp = auraData.expirationTime
                    local dur = auraData.duration
                    if exp and dur and not issecretvalue(exp) and not issecretvalue(dur) and dur > 0 then
                        local remaining = max(0, exp - GetTime())
                        local pct = max(0, min(1, remaining / dur))
                        local r, g, b
                        if pct < 0.3 then
                            local t = pct / 0.3
                            r, g, b = 1, 0.5 * t, 0
                        elseif pct < 0.5 then
                            local t = (pct - 0.3) / 0.2
                            r, g, b = 1, 0.5 + 0.5 * t, 0
                        else
                            local t = (pct - 0.5) / 0.5
                            r, g, b = 1 - t, 1, 0
                        end
                        sq.nativeCooldownText:SetTextColor(r, g, b, 1)
                    end
                end
            else
                sq.nativeCooldownText:SetTextColor(1, 1, 1, 1)
            end
        else
            sq.nativeCooldownText:Hide()
        end
    end

    -- ========================================
    -- EXPIRING: register with shared ticker
    -- ========================================
    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end
    if expiringEnabled then
        local ec = config.expiringColor or {r = 1, g = 0.2, b = 0.2}
        local oc = {r = color and (color[1] or color.r) or 1, g = color and (color[2] or color.g) or 1, b = color and (color[3] or color.b) or 1}
        RegisterExpiring(sq, {
            unit = frame.unit,
            auraInstanceID = auraData and auraData.auraInstanceID,
            threshold = config.expiringThreshold or 30,
            duration = auraData and auraData.duration,
            expirationTime = auraData and auraData.expirationTime,
            colorCurve = BuildExpiringColorCurve(config.expiringThreshold or 30, ec, oc),
            color = ec, originalColor = oc,
            applyResult = function(el, result, entry)
                if el.texture then
                    el.texture:SetColorTexture(result.r, result.g, result.b, result.a or 1)
                end
            end,
            applyManual = function(el, isExp, entry)
                if el.texture then
                    if isExp then
                        local c = entry.color
                        el.texture:SetColorTexture(c.r or 1, c.g or 0.2, c.b or 0.2, 1)
                    else
                        local c = entry.originalColor
                        el.texture:SetColorTexture(c.r or 1, c.g or 1, c.b or 1, 1)
                    end
                end
            end,
        })
    else
        UnregisterExpiring(sq)
    end

    sq:Show()
end

function Indicators:HideUnusedSquares(frame, activeMap)
    local map = frame and frame.dfAD_squares
    if not map then return end
    for auraName, sq in pairs(map) do
        if not activeMap[auraName] then
            UnregisterExpiring(sq)
            sq:Hide()
        end
    end
end

-- ============================================================
-- PLACED INDICATORS -- BAR
-- One progress bar per aura at its configured anchor point.
-- ============================================================

local function GetBarMap(frame)
    if not frame.dfAD_bars then
        frame.dfAD_bars = {}
    end
    return frame.dfAD_bars
end

local DEFAULT_BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

-- Cached color curves for bar color-by-time (same approach as Auras.lua expiring system)
-- Bar color curves are now pre-built per-bar in ApplyBar (stored as bar.dfAD_colorCurve)

local function CreateADBar(frame, auraName)
    local bar = CreateFrame("StatusBar", nil, frame.contentOverlay or frame)
    bar:SetSize(60, 6)
    bar:SetStatusBarTexture(DEFAULT_BAR_TEXTURE)
    bar:SetMinMaxValues(0, 1)
    bar:SetFrameLevel((frame.contentOverlay or frame):GetFrameLevel() + 10)
    bar.dfAD_auraName = auraName

    -- Background texture
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetTexture(DEFAULT_BAR_TEXTURE)
    bar.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)

    -- Border frame
    bar.borderFrame = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    bar.borderFrame:SetPoint("TOPLEFT", -1, 1)
    bar.borderFrame:SetPoint("BOTTOMRIGHT", 1, -1)
    if bar.borderFrame.SetBackdrop then
        bar.borderFrame:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        bar.borderFrame:SetBackdropBorderColor(0, 0, 0, 1)
    end

    -- Text overlay (above everything for duration text)
    bar.textOverlay = CreateFrame("Frame", nil, bar)
    bar.textOverlay:SetAllPoints(bar)
    bar.textOverlay:SetFrameLevel(bar:GetFrameLevel() + 5)
    bar.textOverlay:EnableMouse(false)

    -- Duration text (manual, for preview)
    bar.duration = bar.textOverlay:CreateFontString(nil, "OVERLAY")
    bar.duration:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    bar.duration:SetPoint("CENTER", 0, 0)
    bar.duration:SetTextColor(1, 1, 1)

    -- Cooldown frame for native countdown text in combat (secret-safe)
    -- Invisible swipe — we only use its built-in countdown FontString
    bar.durationCooldown = CreateFrame("Cooldown", nil, bar.textOverlay, "CooldownFrameTemplate")
    bar.durationCooldown:SetAllPoints(bar)
    bar.durationCooldown:SetDrawSwipe(false)
    bar.durationCooldown:SetDrawEdge(false)
    bar.durationCooldown:SetDrawBling(false)
    bar.durationCooldown:SetHideCountdownNumbers(false)
    bar.durationCooldown:Hide()

    -- OnUpdate: handles bar color + preview-only value/text
    -- Real unit bars use SetTimerDuration for fill (no manual arithmetic needed).
    -- Preview bars use manual OnUpdate for fill and text.
    bar.dfAD_duration = 0
    bar.dfAD_expirationTime = 0
    bar.dfAD_colorElapsed = 0
    bar.dfAD_usedTimerDuration = false
    bar.dfAD_expiryCheckElapsed = 0
    bar:SetScript("OnUpdate", function(self, elapsed)
        -- Expiration guard: if the aura is gone, hide the bar (#406)
        -- Throttled to ~1 FPS to avoid per-frame API calls
        self.dfAD_expiryCheckElapsed = (self.dfAD_expiryCheckElapsed or 0) + elapsed
        if self.dfAD_expiryCheckElapsed >= 1.0 then
            self.dfAD_expiryCheckElapsed = 0
            local unit = self.dfAD_unit
            local auraID = self.dfAD_auraInstanceID
            if unit and auraID then
                if not C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraID) then
                    self:SetValue(0)
                    self:Hide()
                    return
                end
            end
        end

        self.dfAD_colorElapsed = (self.dfAD_colorElapsed or 0) + elapsed

        -- ============================================
        -- PREVIEW: Manual bar value + text (~30 fps)
        -- Only runs when SetTimerDuration is NOT driving the bar
        -- ============================================
        if not self.dfAD_usedTimerDuration then
            local dur = self.dfAD_duration
            local exp = self.dfAD_expirationTime
            if dur and exp and dur > 0 and exp > 0 then
                local remaining = max(0, exp - GetTime())
                local pct = min(1, remaining / dur)
                self:SetValue(pct)

                -- Duration text
                if self.duration and self.duration:IsShown() then
                    if remaining >= 60 then
                        self.duration:SetText(format("%dm", remaining / 60))
                    else
                        self.duration:SetText(format("%.1f", remaining))
                    end
                    if self.dfAD_durationColorByTime then
                        local r, g, b
                        if pct < 0.3 then
                            local t = pct / 0.3
                            r, g, b = 1, 0.5 * t, 0
                        elseif pct < 0.5 then
                            local t = (pct - 0.3) / 0.2
                            r, g, b = 1, 0.5 + 0.5 * t, 0
                        else
                            local t = (pct - 0.5) / 0.5
                            r, g, b = 1 - t, 1, 0
                        end
                        self.duration:SetTextColor(r, g, b, 1)
                    end
                end
            end
        end

        -- ============================================
        -- BAR COLOR (API-driven when available, manual fallback)
        -- Throttled to ~1 FPS for performance
        -- ============================================
        if self.dfAD_colorElapsed < 1.0 then return end
        self.dfAD_colorElapsed = 0

        -- API path: evaluate pre-built color curve (no secret comparisons)
        -- The curve is built in ApplyBar and encodes gradient + expiring logic
        if self.dfAD_colorCurve then
            local unit = self.dfAD_unit
            local auraInstanceID = self.dfAD_auraInstanceID
            if unit and auraInstanceID
               and C_UnitAuras and C_UnitAuras.GetAuraDuration then
                local durationObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
                if durationObj and durationObj.EvaluateRemainingPercent then
                    local result = durationObj:EvaluateRemainingPercent(self.dfAD_colorCurve)
                    if result and result.r then
                        self:SetStatusBarColor(result.r, result.g, result.b)
                        return
                    end
                end
            end
        end

        -- Manual color fallback for preview
        if not self.dfAD_usedTimerDuration then
            local dur = self.dfAD_duration
            local exp = self.dfAD_expirationTime
            if dur and exp and dur > 0 and exp > 0 then
                local pct = min(1, max(0, exp - GetTime()) / dur)
                local barR = self.dfAD_fillR or 1
                local barG = self.dfAD_fillG or 1
                local barB = self.dfAD_fillB or 1
                if self.dfAD_barColorByTime then
                    if pct < 0.3 then
                        local t = pct / 0.3
                        barR, barG, barB = 1, 0.5 * t, 0
                    elseif pct < 0.5 then
                        local t = (pct - 0.3) / 0.2
                        barR, barG, barB = 1, 0.5 + 0.5 * t, 0
                    else
                        local t = (pct - 0.5) / 0.5
                        barR, barG, barB = 1 - t, 1, 0
                    end
                end
                if self.dfAD_expiringEnabled and self.dfAD_expiringThreshold then
                    if pct <= (self.dfAD_expiringThreshold / 100) then
                        local ec = self.dfAD_expiringColor
                        if ec then
                            barR = ec.r or 1
                            barG = ec.g or 0.2
                            barB = ec.b or 0.2
                        end
                    end
                end
                self:SetStatusBarColor(barR, barG, barB, 1)
            end
        end
    end)

    bar:Hide()
    return bar
end

local function GetOrCreateADBar(frame, auraName)
    local map = GetBarMap(frame)
    if map[auraName] then return map[auraName] end
    local bar = CreateADBar(frame, auraName)
    map[auraName] = bar
    return bar
end

function Indicators:ApplyBar(frame, config, auraData, defaults, auraName, priority)
    local state = EnsureFrameState(frame)
    state.activeBars[auraName] = true

    local bar = GetOrCreateADBar(frame, auraName)

    -- ========================================
    -- SIZE & ORIENTATION
    -- ========================================
    local matchW = config.matchFrameWidth
    local matchH = config.matchFrameHeight
    if matchW == nil then matchW = true end   -- default: match frame width
    if matchH == nil then matchH = false end  -- default: don't match height
    local width = config.width or 60
    local height = config.height or 6
    if matchW then width = frame:GetWidth() end
    if matchH then height = frame:GetHeight() end
    bar:SetSize(width, height)

    bar:SetAlpha(config.alpha or 1.0)

    local orientation = config.orientation or "HORIZONTAL"
    bar:SetOrientation(orientation)

    -- ========================================
    -- TEXTURE
    -- ========================================
    local texture = config.texture or DEFAULT_BAR_TEXTURE
    bar:SetStatusBarTexture(texture)
    if bar.bg then
        bar.bg:SetTexture(texture)
    end

    -- ========================================
    -- COLORS
    -- ========================================
    local fillColor = config.fillColor
    local fillR = fillColor and (fillColor[1] or fillColor.r) or 1
    local fillG = fillColor and (fillColor[2] or fillColor.g) or 1
    local fillB = fillColor and (fillColor[3] or fillColor.b) or 1

    local bgColor = config.bgColor
    if bgColor and bar.bg then
        bar.bg:SetVertexColor(bgColor[1] or bgColor.r or 0, bgColor[2] or bgColor.g or 0, bgColor[3] or bgColor.b or 0, bgColor[4] or bgColor.a or 0.5)
    end

    -- Bar color by time (stored for OnUpdate to read)
    local barColorByTime = config.barColorByTime
    if barColorByTime == nil then barColorByTime = false end
    bar.dfAD_barColorByTime = barColorByTime

    -- Expiring color (stored for OnUpdate to read)
    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end
    bar.dfAD_expiringEnabled = expiringEnabled
    bar.dfAD_expiringThreshold = config.expiringThreshold or 30
    bar.dfAD_expiringColor = config.expiringColor or { r = 1, g = 0.2, b = 0.2 }

    -- Store unit + auraInstanceID for API-based color evaluation
    bar.dfAD_unit = frame.unit
    bar.dfAD_auraInstanceID = auraData.auraInstanceID

    -- Store base fill color for OnUpdate fallback
    bar.dfAD_fillR = fillR
    bar.dfAD_fillG = fillG
    bar.dfAD_fillB = fillB

    -- ========================================
    -- COLOR CURVE (pre-built for OnUpdate)
    -- Single curve handles gradient + expiring without secret comparisons.
    -- OnUpdate evaluates: durationObj:EvaluateRemainingPercent(curve) → SetStatusBarColor
    -- ========================================
    local needsColorCurve = barColorByTime or expiringEnabled
    if needsColorCurve and C_CurveUtil and C_CurveUtil.CreateColorCurve then
        local curve = C_CurveUtil.CreateColorCurve()
        local expiringColor = config.expiringColor or { r = 1, g = 0.2, b = 0.2 }
        local expiringThreshold = (config.expiringThreshold or 30) / 100

        if expiringEnabled and barColorByTime then
            -- Composite: expiring color below threshold, gradient above
            curve:SetType(Enum.LuaCurveType.Linear)
            local ecR = expiringColor.r or 1
            local ecG = expiringColor.g or 0.2
            local ecB = expiringColor.b or 0.2
            -- Expiring zone (flat color up to threshold)
            curve:AddPoint(0, CreateColor(ecR, ecG, ecB, 1))
            if expiringThreshold > 0.002 then
                curve:AddPoint(expiringThreshold - 0.001, CreateColor(ecR, ecG, ecB, 1))
            end
            -- Compute gradient color at threshold for smooth transition
            local gR, gG, gB
            if expiringThreshold < 0.3 then
                local t = expiringThreshold / 0.3
                gR, gG, gB = 1, 0.5 * t, 0
            elseif expiringThreshold < 0.5 then
                local t = (expiringThreshold - 0.3) / 0.2
                gR, gG, gB = 1, 0.5 + 0.5 * t, 0
            else
                local t = (expiringThreshold - 0.5) / 0.5
                gR, gG, gB = 1 - t, 1, 0
            end
            curve:AddPoint(expiringThreshold, CreateColor(gR, gG, gB, 1))
            -- Add gradient key points above threshold
            if expiringThreshold < 0.3 then
                curve:AddPoint(0.3, CreateColor(1, 0.5, 0, 1))
            end
            if expiringThreshold < 0.5 then
                curve:AddPoint(0.5, CreateColor(1, 1, 0, 1))
            end
            curve:AddPoint(1, CreateColor(0, 1, 0, 1))

        elseif expiringEnabled then
            -- Expiring only: step from expiring color to fill color
            curve:SetType(Enum.LuaCurveType.Step)
            local ecR = expiringColor.r or 1
            local ecG = expiringColor.g or 0.2
            local ecB = expiringColor.b or 0.2
            curve:AddPoint(0, CreateColor(ecR, ecG, ecB, 1))
            curve:AddPoint(expiringThreshold, CreateColor(fillR, fillG, fillB, 1))
            curve:AddPoint(1, CreateColor(fillR, fillG, fillB, 1))

        elseif barColorByTime then
            -- Gradient only: red → orange → yellow → green
            curve:SetType(Enum.LuaCurveType.Linear)
            curve:AddPoint(0, CreateColor(1, 0, 0, 1))
            curve:AddPoint(0.3, CreateColor(1, 0.5, 0, 1))
            curve:AddPoint(0.5, CreateColor(1, 1, 0, 1))
            curve:AddPoint(1, CreateColor(0, 1, 0, 1))
        end

        bar.dfAD_colorCurve = curve
    else
        bar.dfAD_colorCurve = nil
    end

    -- Set initial bar color
    -- When a color curve exists, evaluate it immediately to avoid flicker
    -- (ApplyBar runs on every aura update; without this, the fill color
    -- would flash briefly until the throttled OnUpdate re-evaluates the curve)
    if bar.dfAD_colorCurve and frame.unit and auraData.auraInstanceID
       and C_UnitAuras and C_UnitAuras.GetAuraDuration then
        local durationObj = C_UnitAuras.GetAuraDuration(frame.unit, auraData.auraInstanceID)
        if durationObj and durationObj.EvaluateRemainingPercent then
            local result = durationObj:EvaluateRemainingPercent(bar.dfAD_colorCurve)
            if result and result.r then
                bar:SetStatusBarColor(result.r, result.g, result.b)
            else
                bar:SetStatusBarColor(fillR, fillG, fillB, 1)
            end
        else
            bar:SetStatusBarColor(fillR, fillG, fillB, 1)
        end
    else
        bar:SetStatusBarColor(fillR, fillG, fillB, 1)
    end

    -- ========================================
    -- BORDER
    -- ========================================
    local showBorder = config.showBorder
    if showBorder == nil then showBorder = true end
    local borderThickness = config.borderThickness or 1

    if bar.borderFrame then
        if showBorder then
            bar.borderFrame:ClearAllPoints()
            bar.borderFrame:SetPoint("TOPLEFT", -borderThickness, borderThickness)
            bar.borderFrame:SetPoint("BOTTOMRIGHT", borderThickness, -borderThickness)
            if bar.borderFrame.SetBackdrop then
                bar.borderFrame:SetBackdrop({
                    edgeFile = "Interface\\Buttons\\WHITE8x8",
                    edgeSize = borderThickness,
                })
                local borderColor = config.borderColor
                if borderColor then
                    bar.borderFrame:SetBackdropBorderColor(borderColor[1] or borderColor.r or 0, borderColor[2] or borderColor.g or 0, borderColor[3] or borderColor.b or 0, borderColor[4] or borderColor.a or 1)
                else
                    bar.borderFrame:SetBackdropBorderColor(0, 0, 0, 1)
                end
            end
            bar.borderFrame:Show()
        else
            bar.borderFrame:Hide()
        end
    end

    -- ========================================
    -- POSITION
    -- ========================================
    local anchor = config.anchor or "BOTTOM"
    local offsetX = config.offsetX or 0
    local offsetY = config.offsetY or 0
    -- Compensate for border overhang at frame edges
    local showBorderForPos = config.showBorder
    if showBorderForPos == nil then showBorderForPos = true end
    offsetX, offsetY = AdjustOffsetForBorder(anchor, offsetX, offsetY, config.borderThickness or 1, showBorderForPos)
    bar:ClearAllPoints()
    bar:SetPoint(anchor, frame, anchor, offsetX, offsetY)

    -- Frame level: higher priority (lower number) = higher frame level
    local baseLevel = (frame.contentOverlay or frame):GetFrameLevel() + 10
    local priorityBoost = 20 - (priority or 5)
    bar:SetFrameLevel(baseLevel + priorityBoost)

    -- ========================================
    -- COUNTDOWN DATA (drives bar fill)
    -- Real unit: SetTimerDuration handles fill natively (secret-safe)
    -- Preview:   Manual SetValue in OnUpdate
    -- ========================================
    local hasDuration = HasAuraDuration(auraData, frame.unit)
    local usedTimerDuration = false

    if hasDuration then
        -- Path 1: Real unit — SetTimerDuration with Duration object
        if frame.unit and auraData.auraInstanceID
           and C_UnitAuras and C_UnitAuras.GetAuraDuration
           and bar.SetTimerDuration then
            local durationObj = C_UnitAuras.GetAuraDuration(frame.unit, auraData.auraInstanceID)
            if durationObj then
                bar:SetTimerDuration(durationObj, Enum.StatusBarInterpolation.Immediate, Enum.StatusBarTimerDirection.RemainingTime)
                usedTimerDuration = true
            end
        end

        -- Path 2: Preview fallback — manual SetValue
        if not usedTimerDuration then
            local dur = auraData.duration
            local exp = auraData.expirationTime
            bar.dfAD_duration = dur
            bar.dfAD_expirationTime = exp
            if dur and exp and not issecretvalue(dur) and not issecretvalue(exp) and dur > 0 then
                local remaining = exp - GetTime()
                local pct = max(0, min(1, remaining / dur))
                bar:SetValue(pct)
            else
                bar:SetValue(1)
            end
        end
    else
        bar.dfAD_duration = 0
        bar.dfAD_expirationTime = 0
        bar:SetValue(1)  -- Permanent aura = full bar
    end

    bar.dfAD_usedTimerDuration = usedTimerDuration

    -- ========================================
    -- DURATION TEXT
    -- ========================================
    local showDuration = config.showDuration
    if showDuration == nil then showDuration = false end
    local durationFont = config.durationFont or (defaults and defaults.durationFont) or "Fonts\\FRIZQT__.TTF"
    local durationScale = config.durationScale or (defaults and defaults.durationScale) or 1.0
    local durationOutline = config.durationOutline or (defaults and defaults.durationOutline) or "OUTLINE"
    if durationOutline == "NONE" then durationOutline = "" end
    local durationAnchor = config.durationAnchor or "CENTER"
    local durationX = config.durationX or 0
    local durationY = config.durationY or 0
    local durationColorByTime = config.durationColorByTime
    if durationColorByTime == nil then durationColorByTime = true end

    -- Store color-by-time flag for OnUpdate to read
    bar.dfAD_durationColorByTime = durationColorByTime

    if showDuration and hasDuration then
        local durationSize = 10 * durationScale

        if usedTimerDuration and bar.durationCooldown then
            -- COMBAT PATH: Use native cooldown countdown text (secret-safe)
            -- The cooldown frame handles formatting and updating automatically
            bar.duration:Hide()

            -- Set the cooldown with the same Duration object
            local durationObj = C_UnitAuras.GetAuraDuration(frame.unit, auraData.auraInstanceID)
            if durationObj then
                bar.durationCooldown:SetCooldownFromDurationObject(durationObj)
                bar.durationCooldown:Show()
            end

            -- Find native cooldown text if not yet cached
            if not bar.nativeCooldownText then
                local regions = { bar.durationCooldown:GetRegions() }
                for _, region in pairs(regions) do
                    if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                        bar.nativeCooldownText = region
                        bar.nativeTextReparented = false
                        break
                    end
                end
            end

            -- Style and position the native countdown text
            if bar.nativeCooldownText then
                if not bar.nativeTextReparented and bar.textOverlay then
                    bar.nativeCooldownText:SetParent(bar.textOverlay)
                    bar.nativeTextReparented = true
                end
                DF:SafeSetFont(bar.nativeCooldownText, durationFont, durationSize, durationOutline)
                bar.nativeCooldownText:ClearAllPoints()
                bar.nativeCooldownText:SetPoint(durationAnchor, bar, durationAnchor, durationX, durationY)
                bar.nativeCooldownText:Show()

                if not durationColorByTime then
                    bar.nativeCooldownText:SetTextColor(1, 1, 1, 1)
                elseif durationObj and durationObj.EvaluateRemainingPercent then
                    if not DF.durationColorCurve then
                        DF.durationColorCurve = C_CurveUtil.CreateColorCurve()
                        DF.durationColorCurve:SetType(Enum.LuaCurveType.Linear)
                        DF.durationColorCurve:AddPoint(0, CreateColor(1, 0, 0, 1))
                        DF.durationColorCurve:AddPoint(0.3, CreateColor(1, 0.5, 0, 1))
                        DF.durationColorCurve:AddPoint(0.5, CreateColor(1, 1, 0, 1))
                        DF.durationColorCurve:AddPoint(1, CreateColor(0, 1, 0, 1))
                    end
                    local result = durationObj:EvaluateRemainingPercent(DF.durationColorCurve)
                    if result and result.r then
                        bar.nativeCooldownText:SetTextColor(result.r, result.g, result.b)
                    end
                end
            end

        elseif bar.duration then
            -- PREVIEW PATH: Manual FontString (non-secret values)
            if bar.durationCooldown then
                bar.durationCooldown:Hide()
            end
            if bar.nativeCooldownText then
                bar.nativeCooldownText:Hide()
            end

            DF:SafeSetFont(bar.duration, durationFont, durationSize, durationOutline)
            bar.duration:ClearAllPoints()
            bar.duration:SetPoint(durationAnchor, bar, durationAnchor, durationX, durationY)

            local dur = auraData.duration
            local exp = auraData.expirationTime
            if dur and exp and not issecretvalue(dur) and not issecretvalue(exp) and dur > 0 then
                local remaining = max(0, exp - GetTime())
                if remaining >= 60 then
                    bar.duration:SetText(format("%dm", remaining / 60))
                else
                    bar.duration:SetText(format("%.1f", remaining))
                end
            else
                bar.duration:SetText("")
            end

            if not durationColorByTime then
                bar.duration:SetTextColor(1, 1, 1, 1)
            end
            bar.duration:Show()
        end
    else
        if bar.duration then bar.duration:Hide() end
        if bar.durationCooldown then bar.durationCooldown:Hide() end
        if bar.nativeCooldownText then bar.nativeCooldownText:Hide() end
    end

    -- Ensure mouse doesn't block clicks on the unit frame
    if not InCombatLockdown() and bar.SetMouseClickEnabled then
        bar:SetMouseClickEnabled(false)
    end

    bar:Show()
end

function Indicators:HideUnusedBars(frame, activeMap)
    local map = frame and frame.dfAD_bars
    if not map then return end
    for auraName, bar in pairs(map) do
        if not activeMap[auraName] then
            bar:Hide()
            -- Clear stale metadata so OnUpdate doesn't run with expired
            -- auraInstanceIDs causing stuck/corrupted bar state (#406)
            bar:SetValue(0)
            bar.dfAD_auraInstanceID = nil
            bar.dfAD_unit = nil
            bar.dfAD_duration = 0
            bar.dfAD_expirationTime = 0
            bar.dfAD_colorCurve = nil
            bar.dfAD_usedTimerDuration = false
            if bar.durationCooldown then
                bar.durationCooldown:Hide()
            end
        end
    end
end
