local addonName, DF = ...

-- Hot-path math cached at file scope (the pulse ticker below runs every frame).
local cos = math.cos

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
local IsAuraFilteredOut = C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID

-- Secret-safe "is this colour-curve result the expiring colour?" — now lives on
-- the shared DF.Expiring engine; kept as a local alias so the call sites below
-- read unchanged.
local IsColorExpiring = DF.Expiring.IsColorExpiring

DF.AuraDesigner = DF.AuraDesigner or {}

local Indicators = {}
DF.AuraDesigner.Indicators = Indicators

-- Strata ordering for safe strata assignment (never lower an indicator below its parent frame)
local STRATA_ORDER = {
    BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4,
    DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}

local function SafeSetFrameStrata(widget, frame, targetStrata)
    local parentStrata = frame:GetFrameStrata()
    local parentOrder = STRATA_ORDER[parentStrata] or 3
    local targetOrder = STRATA_ORDER[targetStrata] or 3
    -- Don't lower below the parent (prevents vanishing in preview panels)
    if targetOrder < parentOrder then
        widget:SetFrameStrata(parentStrata)
    else
        widget:SetFrameStrata(targetStrata)
    end
end

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

-- Anchor a frame, then (pixel-perfect only) snap it onto the physical pixel grid
-- so a 1px DF.Border on it doesn't straddle two physical rows and drop a side.
-- The SetPoint offset is a pure translation, so we shift the frame by the
-- sub-pixel remainder of its left/bottom edges (<=0.5px). Anchor-agnostic; the
-- frame's SIZE must already be whole pixels (snapped in the Configure step). A
-- no-op when pp is off or the geometry isn't laid out yet — so it MUST be called
-- after the frame is positioned (in Update*, not Configure*).
local function AnchorPixelSnapped(child, anchor, relTo, offsetX, offsetY, pp)
    child:ClearAllPoints()
    child:SetPoint(anchor, relTo, anchor, offsetX, offsetY)
    DF:SnapPointToPixelGrid(child, pp)  -- shared primitive in Frames/Core.lua
end

-- ============================================================
-- EXPIRING — thin AD-side adapters over the shared DF.Expiring engine
-- (engine: registry + ~3 FPS ticker + colour curve live in Frames/Expiring.lua).
-- The pending* flags are AD's "Show When Missing" mechanism: Apply sets them
-- before dispatching to Configure, and the RegisterExpiring wrapper injects them
-- into entryData (keeping that coupling AD-side; the shared engine reads only
-- entryData).  The call sites below (RegisterExpiring / UnregisterExpiring /
-- BuildExpiringColorCurve) are unchanged — these locals just delegate.
-- ============================================================

local pendingHideWhenNotExpiring = false  -- Set by Apply before dispatch, read by RegisterExpiring
local pendingUseShowHide = false          -- When true, ticker uses Show/Hide instead of SetAlpha
local pendingHiddenAlpha = nil            -- Alpha to use when "not expiring" (nil = 0 for borders, savedAlpha for framealpha)

local function RegisterExpiring(element, entryData)
    -- Propagate Show When Missing visibility flag into entryData (the shared
    -- engine has no knowledge of AD's pending state).
    if pendingHideWhenNotExpiring then
        entryData.hideWhenNotExpiring = true
        entryData.visibleAlpha = entryData.originalAlpha or 1
        entryData.useShowHide = pendingUseShowHide or false
        entryData.hiddenAlpha = pendingHiddenAlpha  -- nil = use 0, number = use that alpha
    end
    DF.Expiring:Register(element, entryData)
end

local function UnregisterExpiring(element)
    DF.Expiring:Unregister(element)
end

local function BuildExpiringColorCurve(threshold, expiringColor, originalColor, thresholdMode)
    return DF.Expiring:BuildColorCurve(threshold, expiringColor, originalColor, thresholdMode)
end

-- Build a Step color curve for hiding duration text above a seconds threshold.
-- Returns alpha=1 (visible) when remaining <= threshold, alpha=0 (hidden) above.
-- Only uses EvaluateRemainingDuration (always seconds-based).
-- ============================================================
-- EXPIRING PULSE — one shared ticker for all AD health bars
-- ============================================================
-- A single OnUpdate drives every pulsing AD health bar from a SHARED phase
-- (GetTime), so they all breathe in unison regardless of when each aura crossed
-- the expiring threshold. WoW AnimationGroups can't share a phase — every
-- :Play() restarts the cycle at 0 — so the pulse is hand-driven here. One ticker
-- for the whole addon (same pattern as DF.Expiring), shown only while something
-- is actually pulsing.
--
-- The pulse multiplies the bar's steady opacity by a 1 ↔ 0.3 factor:
--   replace → fade the fill texture's FRAME alpha (base = the OOR-aware blend;
--             vertex alpha is unusable — StatusBar:SetValue resets it each tick).
--   tint    → fade the overlay's FRAME alpha (factor alone — the blend rides the
--             overlay's COLOUR alpha on a separate channel, so the two multiply).
local pulseRegistry = {}  -- [frame] = true while its AD health bar is pulsing
local pulseTicker = CreateFrame("Frame")
pulseTicker:Hide()  -- OnUpdate only fires while shown; shown only when non-empty

local function RestorePulseAlpha(frame, st)
    -- Return the pulsing layer to its steady (non-pulsing) opacity.
    if st.healthbarMode == "replace" then
        local hbTex = frame.healthBar and frame.healthBar:GetStatusBarTexture()
        if hbTex then hbTex:SetAlpha((st.healthbarEffectiveBlend or st.healthbarCurrentBlend) or 1) end
    elseif st.tintOverlay then
        st.tintOverlay:SetAlpha(1)
    end
end

pulseTicker:SetScript("OnUpdate", function()
    local factor = 0.65 + 0.35 * cos((GetTime() % 1.0) * 6.2831853)
    local any = false
    for frame in pairs(pulseRegistry) do
        local st = frame.dfAD
        if not (st and st.healthbar and st.healthbarPulseOn) then
            pulseRegistry[frame] = nil  -- reverted / stale
        elseif st.healthbarMode == "replace" then
            local hbTex = frame.healthBar and frame.healthBar:GetStatusBarTexture()
            if hbTex then
                local base = st.healthbarEffectiveBlend or st.healthbarCurrentBlend or 1
                hbTex:SetAlpha(base * factor)
            end
            any = true
        else
            if st.tintOverlay then st.tintOverlay:SetAlpha(factor) end
            any = true
        end
    end
    if not any then pulseTicker:Hide() end
end)

-- Toggle a frame's AD health-bar pulse: register/unregister with the shared
-- ticker and restore the steady alpha when stopping.
local function SetHealthBarPulse(frame, on)
    local st = frame.dfAD
    if not st then return end
    if on then
        -- Idempotent + self-healing: always re-assert registry membership. The
        -- ticker can drop a frame on a transient state.healthbar=false (BeginFrame)
        -- while pulseOn stays true; re-adding here keeps the two in lockstep so the
        -- bar can never freeze mid-pulse out of the registry.
        st.healthbarPulseOn = true
        pulseRegistry[frame] = true
        pulseTicker:Show()
    elseif st.healthbarPulseOn or pulseRegistry[frame] then
        st.healthbarPulseOn = false
        pulseRegistry[frame] = nil
        RestorePulseAlpha(frame, st)
    end
end

-- Drive the HEALTH BAR pulse from the expiring state (called by its expiring
-- callbacks). The health bar uses the shared global ticker above; icons, squares
-- and custom borders use the per-element AnimationGroup pulse below.
local function UpdateHealthBarPulse(frame, isExpiring)
    local st = frame.dfAD
    SetHealthBarPulse(frame, (isExpiring and st and st.healthbarExpiringPulsate) or false)
end

-- Create (or return cached) pulse AnimationGroup on a frame. Used by AD icon
-- borders, square fills and custom borders (NOT the health bar). Matches the buff
-- tab's expiring border pulse: 1→0.3→1, 0.5s each, IN_OUT, REPEAT.
local function GetOrCreatePulseAnim(frame)
    if not frame.dfAD_pulse then
        frame.dfAD_pulse = frame:CreateAnimationGroup()
        frame.dfAD_pulse:SetLooping("REPEAT")
        local fadeOut = frame.dfAD_pulse:CreateAnimation("Alpha")
        fadeOut:SetFromAlpha(1)
        fadeOut:SetToAlpha(0.3)
        fadeOut:SetDuration(0.5)
        fadeOut:SetOrder(1)
        fadeOut:SetSmoothing("IN_OUT")
        local fadeIn = frame.dfAD_pulse:CreateAnimation("Alpha")
        fadeIn:SetFromAlpha(0.3)
        fadeIn:SetToAlpha(1)
        fadeIn:SetDuration(0.5)
        fadeIn:SetOrder(2)
        fadeIn:SetSmoothing("IN_OUT")
    end
    return frame.dfAD_pulse
end

-- Play or stop a per-element AnimationGroup pulse based on expiring state.
-- Used by icons / squares / custom borders (el is the pulse frame).
local function UpdatePulseState(el, isExpiring)
    if el.dfAD_expiringPulsate and el.dfAD_pulse then
        if isExpiring and not el.dfAD_pulse:IsPlaying() then
            el.dfAD_pulse:Play()
        elseif not isExpiring and el.dfAD_pulse:IsPlaying() then
            el.dfAD_pulse:Stop()
            el:SetAlpha(1)
        end
    end
end

-- Create or return a whole-frame alpha pulse animation (pulses entire icon/square).
local function GetOrCreateWholeAlphaPulse(frame)
    if not frame.dfAD_wholeAlphaPulse then
        frame.dfAD_wholeAlphaPulse = frame:CreateAnimationGroup()
        frame.dfAD_wholeAlphaPulse:SetLooping("REPEAT")
        local fadeOut = frame.dfAD_wholeAlphaPulse:CreateAnimation("Alpha")
        fadeOut:SetFromAlpha(1)
        fadeOut:SetToAlpha(0.3)
        fadeOut:SetDuration(0.5)
        fadeOut:SetOrder(1)
        fadeOut:SetSmoothing("IN_OUT")
        local fadeIn = frame.dfAD_wholeAlphaPulse:CreateAnimation("Alpha")
        fadeIn:SetFromAlpha(0.3)
        fadeIn:SetToAlpha(1)
        fadeIn:SetDuration(0.5)
        fadeIn:SetOrder(2)
        fadeIn:SetSmoothing("IN_OUT")
    end
    return frame.dfAD_wholeAlphaPulse
end

-- Bounce driver.  A real Translation animation moves the frame's render
-- TRANSFORM, which child-frame overlays (the expiring Tint and the Expiring-
-- Animation glow) don't track cleanly under the AD preview's per-frame refresh —
-- they accumulate the offset and drift off-screen.  Instead we move the element
-- with a real SetPoint LAYOUT offset (relative to its base anchor, stored as
-- el.dfAD_basePos by UpdateIcon/Square/Bar), which propagates to every descendant
-- correctly.  The driver mimics the AnimationGroup interface (Play/Stop/IsPlaying)
-- so every existing call site works unchanged.
local BOUNCE_AMP, BOUNCE_PERIOD = 4, 0.6  -- pixels, seconds per full up-down cycle
local function GetOrCreateBounceAnim(frame)
    if not frame.dfAD_bounceAnim then
        local d = CreateFrame("Frame")
        d:Hide()
        d.elapsed = 0
        d.IsPlaying = function(self) return self:IsShown() end
        d.Play = function(self) self.elapsed = 0; self:Show() end
        d.Stop = function(self)
            self:Hide()
            local b = frame.dfAD_basePos  -- snap back to the resting position
            if b then frame:ClearAllPoints(); frame:SetPoint(b.point, b.rel, b.relPoint, b.x, b.y) end
        end
        d:SetScript("OnUpdate", function(self, dt)
            self.elapsed = self.elapsed + dt
            local b = frame.dfAD_basePos
            if not b then return end
            -- Smooth 0→AMP→0 each cycle (zero-slope endpoints, no seam on loop).
            local off = (1 - cos(self.elapsed * (2 * math.pi / BOUNCE_PERIOD))) * 0.5 * BOUNCE_AMP
            frame:ClearAllPoints()
            frame:SetPoint(b.point, b.rel, b.relPoint, b.x, b.y + off)
        end)
        frame.dfAD_bounceAnim = d
    end
    return frame.dfAD_bounceAnim
end

-- Play or stop whole-alpha pulse based on expiring state.
local function UpdateWholeAlphaPulseState(el, isExpiring)
    if el.dfAD_expiringWholeAlphaPulse and el.dfAD_wholeAlphaPulse then
        if isExpiring and not el.dfAD_wholeAlphaPulse:IsPlaying() then
            el.dfAD_wholeAlphaPulse:Play()
        elseif not isExpiring and el.dfAD_wholeAlphaPulse:IsPlaying() then
            el.dfAD_wholeAlphaPulse:Stop()
            el:SetAlpha(1)
        end
    end
end

-- Play or stop bounce animation based on expiring state.
local function UpdateBounceState(el, isExpiring)
    if el.dfAD_expiringBounce and el.dfAD_bounceAnim then
        if isExpiring and not el.dfAD_bounceAnim:IsPlaying() then
            el.dfAD_bounceAnim:Play()
        elseif not isExpiring and el.dfAD_bounceAnim:IsPlaying() then
            el.dfAD_bounceAnim:Stop()
        end
    end
end

-- Drive the anim effects (pulse / whole-alpha / bounce) from an applyResult tick,
-- but ONLY on NON-secret auras.  On a secret aura the curve result is tainted, so
-- IsColorExpiring returns true-always — a play/stop that branches on that would
-- keep the effect running forever (e.g. a bounce that never stops drifts upward
-- and "flies off" in the preview).  Per design the anim effects are non-secret-
-- only, so on a secret aura we force them STOPPED (effExp = false → revert to base
-- position/alpha).  `pulseFrame` = the element's fill/border pulse frame (or nil).
local function DriveExpiringEffects(el, result, isExp, pulseFrame)
    local effExp = (not issecretvalue(result.r)) and isExp or false
    if pulseFrame then UpdatePulseState(pulseFrame, effExp) end
    UpdateWholeAlphaPulseState(el, effExp)
    UpdateBounceState(el, effExp)
end

-- Secret-safe expiring TINT for AD indicators (icon / square / bar).  A colour
-- overlay that fades in below threshold, driven by the shared DF.Expiring engine
-- (alpha-gated via SetAlphaFromBoolean — works on SECRET auras, never branches on
-- the secret remaining-time).  `host` is the frame the texture attaches to
-- (textOverlay where present, else the element).  Idempotent: reuses host.dfAD_tint.
-- `host` = frame the texture attaches to (textOverlay where present, else the
-- element); `el` = the element carrying the stored dfAD_* config (set in Configure).
local function SetupExpiringTint(host, layer, el, frame, auraData)
    if not host or not el then return end
    -- Lazy: don't allocate a tint texture for the common (disabled) case; just
    -- tear down any existing one.
    if not el.dfAD_expiringTintEnabled then
        if host.dfAD_tint then
            DF.Expiring:Unregister(host.dfAD_tint)
            host.dfAD_tint:Hide()
        end
        return
    end
    if not host.dfAD_tint then
        host.dfAD_tint = host:CreateTexture(nil, layer or "ARTWORK")
        host.dfAD_tint:SetAllPoints(host)
        host.dfAD_tint:SetBlendMode("ADD")
        host.dfAD_tint:Hide()
    end
    DF.Expiring:UpdateTint(host.dfAD_tint, {
        unit           = frame and frame.unit,
        auraInstanceID = auraData and auraData.auraInstanceID,
        threshold      = el.dfAD_expiringThreshold or 30,
        thresholdMode  = el.dfAD_expiringThresholdMode,
        duration       = auraData and auraData.duration,
        expirationTime = auraData and auraData.expirationTime,
        enabled        = el.dfAD_expiringTintEnabled,
        color          = el.dfAD_expiringTintColor,
    })
end

-- Tear down an element's tint (unregister from the engine + hide).
local function ClearExpiringTint(host)
    if host and host.dfAD_tint then
        DF.Expiring:Unregister(host.dfAD_tint)
        host.dfAD_tint:Hide()
    end
end

-- ============================================================
-- EXPIRING BORDER STATE (shared by indicator types)
-- Generic versions of the icon's per-aura buildAnim / applyState, reading
-- every input from `el.dfAD_*` fields so any indicator that stores the same
-- fields (icon, square, …) can drive its DF.Border through the expiring
-- state-replace model.  The element must carry, from its Configure pass:
--   dfADBorder, texture, dfAD_hideIcon
--   dfAD_baseBorderSize/Inset/Color/Style/Gradient/Texture/Shadow/Blend/OffsetX/Y
--   dfAD_baseAnim* (Type/Color/Frequency/Particles/Length/Thickness/Scale/
--                   Inset/OffsetX/OffsetY/Mask/SidesAxis/CornerLength)
--   dfAD_ExpiringBorderSize/Alpha, dfAD_ExpiringAnimation*
--   dfAD_expiringEnabled (colour override on), dfAD_expiringColor
-- All three placed border indicators (icon / square / bar) now drive their
-- DF.Border through these shared helpers — the icon's old inline closures were
-- removed (task #46), so there is a single source of truth for the expiring
-- border state-swap.
-- ============================================================
local function ADExpiringBorderHasAnim(el)
    local t = el.dfAD_ExpiringAnimationType
    return t and t ~= "NONE"
end

-- State-replace: below threshold with an expiring animation, use the FULL
-- expiring tunable set (own colour/particles/etc.); else the base animation.
local function ADBuildExpiringBorderAnim(el, isExp)
    if isExp and ADExpiringBorderHasAnim(el) then
        return {
            type         = el.dfAD_ExpiringAnimationType,
            color        = el.dfAD_ExpiringAnimationColor or el.dfAD_expiringColor,
            frequency    = el.dfAD_ExpiringAnimationFrequency,
            particles    = el.dfAD_ExpiringAnimationParticles,
            length       = el.dfAD_ExpiringAnimationLength,
            thickness    = el.dfAD_ExpiringAnimationThickness,
            scale        = el.dfAD_ExpiringAnimationScale,
            inset        = el.dfAD_ExpiringAnimationInset,
            offsetX      = el.dfAD_ExpiringAnimationOffsetX,
            offsetY      = el.dfAD_ExpiringAnimationOffsetY,
            mask         = el.dfAD_ExpiringAnimationMask,
            sidesAxis    = el.dfAD_ExpiringAnimationSidesAxis,
            cornerLength = el.dfAD_ExpiringAnimationCornerLength,
        }
    elseif el.dfAD_baseAnimType and el.dfAD_baseAnimType ~= "NONE" then
        return {
            type         = el.dfAD_baseAnimType,
            color        = el.dfAD_baseAnimColor,
            frequency    = el.dfAD_baseAnimFrequency,
            particles    = el.dfAD_baseAnimParticles,
            length       = el.dfAD_baseAnimLength,
            thickness    = el.dfAD_baseAnimThickness,
            scale        = el.dfAD_baseAnimScale,
            inset        = el.dfAD_baseAnimInset,
            offsetX      = el.dfAD_baseAnimOffsetX,
            offsetY      = el.dfAD_baseAnimOffsetY,
            mask         = el.dfAD_baseAnimMask,
            sidesAxis    = el.dfAD_baseAnimSidesAxis,
            cornerLength = el.dfAD_baseAnimCornerLength,
        }
    end
    return nil
end

-- Apply the expiring (or base) border state to el.dfADBorder.  `color` is the
-- tint for SOLID mode (curve / override colour when expiring, base otherwise).
local function ADApplyExpiringBorderState(el, isExp, color)
    if not el.dfADBorder then return end
    local applyColor = el.dfAD_expiringEnabled
    local thickness
    if isExp then
        thickness = el.dfAD_ExpiringBorderSize  or el.dfAD_baseBorderSize  or 1
    else
        thickness = el.dfAD_baseBorderSize  or 1
    end
    local insetVal = el.dfAD_baseBorderInset or 1
    local sizeVal  = thickness
    -- Inset the artwork/fill by the current thickness so the band frames it and
    -- a thicker expiring band stays visible (not covered by the texture).
    if el.texture and not el.dfAD_hideIcon then
        el.texture:ClearAllPoints()
        el.texture:SetPoint("TOPLEFT",     thickness, -thickness)
        el.texture:SetPoint("BOTTOMRIGHT", -thickness,  thickness)
    end
    -- Colour carries its own alpha (the expiring border colour's alpha below
    -- threshold via borderTintFor, base alpha otherwise) — no separate
    -- multiplier, so the picker's alpha is the single source of truth.
    local pickedColor = color
    -- Preserve the base presentation (gradient / texture / shadow / blend);
    -- flatten to SOLID only when the colour override is actively tinting below
    -- threshold (a single override colour can't be drawn as a two-stop gradient).
    local flattenToSolid = applyColor and isExp
    local useStyle    = flattenToSolid and "SOLID" or (el.dfAD_baseBorderStyle or "SOLID")
    local useGradient = (not flattenToSolid) and el.dfAD_baseBorderGradient or nil
    local useTexture  = (not flattenToSolid) and el.dfAD_baseBorderTexture or nil
    -- Respect the base Show Border state — don't let an expiring override
    -- re-enable a border the user has turned off (defaults to enabled when the
    -- field is unset, so consumers that don't store it behave as before).
    DF.Border:Apply(el.dfADBorder, {
        enabled   = el.dfAD_baseBorderEnabled ~= false,
        style     = useStyle,
        texture   = useTexture,
        gradient  = useGradient,
        shadow    = el.dfAD_baseBorderShadow,
        blendMode = el.dfAD_baseBorderBlend,
        size      = sizeVal,
        inset     = -insetVal,
        offsetX   = el.dfAD_baseBorderOffsetX or 0,
        offsetY   = el.dfAD_baseBorderOffsetY or 0,
        color     = pickedColor,
        animation = ADBuildExpiringBorderAnim(el, isExp),
    })
end

local function BuildDurationHideCurve(threshold)
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then return nil end
    DF.durationHideCurves = DF.durationHideCurves or {}
    local cacheKey = threshold
    if not DF.durationHideCurves[cacheKey] then
        local curve = C_CurveUtil.CreateColorCurve()
        curve:SetType(Enum.LuaCurveType.Step)
        curve:AddPoint(0, CreateColor(1, 1, 1, 1))          -- visible
        curve:AddPoint(threshold, CreateColor(1, 1, 1, 0))  -- hidden
        curve:AddPoint(600, CreateColor(1, 1, 1, 0))        -- cap
        DF.durationHideCurves[cacheKey] = curve
    end
    return DF.durationHideCurves[cacheKey]
end

-- Scan for the native cooldown FontString that Blizzard creates lazily.
-- Returns true if it was newly found this call (caller should apply deferred styling).
local function EnsureNativeCooldownText(indicator, cooldownFrame)
    if indicator.nativeCooldownText then return false end
    if not cooldownFrame then return false end
    local regions = { cooldownFrame:GetRegions() }
    for _, region in pairs(regions) do
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            indicator.nativeCooldownText = region
            indicator.nativeTextReparented = false
            return true
        end
    end
    return false
end

-- Apply deferred duration text styling when the native cooldown FontString
-- is discovered after Configure (because Blizzard creates it lazily on
-- first SetCooldown).  Mirrors the reparent+style+position block in Configure.
local function ApplyDeferredDurationStyling(indicator)
    local text = indicator.nativeCooldownText
    if not text then return end
    if not indicator.showDuration and indicator.showDuration ~= nil then
        text:Hide()
        return
    end
    -- Create duration hide wrapper if needed
    if not indicator.durationHideWrapper and indicator.textOverlay then
        indicator.durationHideWrapper = CreateFrame("Frame", nil, indicator.textOverlay)
        indicator.durationHideWrapper:SetAllPoints(indicator.textOverlay)
        indicator.durationHideWrapper:SetFrameLevel(indicator.textOverlay:GetFrameLevel())
        indicator.durationHideWrapper:EnableMouse(false)
    end
    -- Reparent into wrapper
    if not indicator.nativeTextReparented and indicator.durationHideWrapper then
        text:SetParent(indicator.durationHideWrapper)
        indicator.nativeTextReparented = true
    end
    -- Style
    local font = indicator.dfAD_durationFont or "Fonts\\FRIZQT__.TTF"
    local scale = indicator.dfAD_durationScale or 1.0
    local outline = indicator.dfAD_durationOutline or "OUTLINE"
    if outline == "NONE" then outline = "" end
    local size = 10 * scale
    DF:SafeSetFont(text, font, size, outline)
    -- Position
    local anchor = indicator.durationAnchor or indicator.dfAD_durationAnchor or "CENTER"
    local dx = indicator.durationX or indicator.dfAD_durationX or 0
    local dy = indicator.durationY or indicator.dfAD_durationY or 0
    text:ClearAllPoints()
    text:SetPoint(anchor, indicator, anchor, dx, dy)
    text:Show()
end

-- (The ~3 FPS expiring ticker now lives on the shared DF.Expiring engine in
-- Frames/Expiring.lua — every registered element across the addon, AD indicators
-- and standard buff borders alike, is driven by that one OnUpdate.)

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
            -- Custom border tracking: { [auraName] = true } for active this frame
            activeCustomBorders = {},
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
    state.background = false
    state.nametext = false
    state.healthtext = false
    state.framealpha = false
    table.wipe(state.activeIcons)
    table.wipe(state.activeSquares)
    table.wipe(state.activeBars)
    table.wipe(state.activeCustomBorders)
end

-- ============================================================
-- CONFIGURE DISPATCH
-- Routes to type-specific Configure functions for pooled indicator types.
-- Called only when dfAD_configVersion is stale.
-- ============================================================
function Indicators:Configure(frame, typeKey, config, defaults, auraName, priority)
    if typeKey == "icon" then
        self:ConfigureIcon(frame, config, defaults, auraName, priority)
    elseif typeKey == "square" then
        self:ConfigureSquare(frame, config, defaults, auraName, priority)
    elseif typeKey == "bar" then
        self:ConfigureBar(frame, config, defaults, auraName, priority)
    end
    -- border, healthbar, nametext, healthtext, framealpha don't need configure-once
    -- (they modify the unit frame itself, not pooled indicator frames)
end

-- ============================================================
-- APPLY -- DISPATCH TO TYPE HANDLERS
-- ============================================================

function Indicators:Apply(frame, typeKey, config, auraData, defaults, auraName, priority)
    -- Show When Missing + aura is present: hide unless expiring
    local hideUntilExpiring = config.showWhenMissing and auraData and not auraData.isMissingAura
    if hideUntilExpiring and not config.expiringEnabled then
        -- No expiring configured; nothing to show when aura is present
        return
    end

    -- Validate aura still exists and matches expectations before rendering.
    -- Mirrors the defensive bar post-validation pattern (commit 7b141a8).
    local unit = frame.unit
    local auraID = auraData and auraData.auraInstanceID
    if auraID then
        -- Secret auraInstanceID = stale cache hit from a different aura
        if issecretvalue(auraID) then return end

        -- Verify the aura still exists on this unit
        if unit and GetAuraDataByAuraInstanceID then
            local live = GetAuraDataByAuraInstanceID(unit, auraID)
            if not live then return end
        end

        -- Verify the aura belongs to the player (not another player's buff)
        -- Skip for selfOnly auras (e.g. Symbiotic Relationship) where the
        -- source is another unit but the buff legitimately appears on the player
        if unit and IsAuraFilteredOut and not auraData.selfOnly then
            if IsAuraFilteredOut(unit, auraID, "HELPFUL|PLAYER") then return end
        end
    end

    -- Set module flags so RegisterExpiring (called inside Apply*) picks them up
    pendingHideWhenNotExpiring = hideUntilExpiring or false
    -- Icons and squares use Show/Hide to avoid OOR alpha restore undoing the hide
    pendingUseShowHide = (typeKey == "icon" or typeKey == "square") and hideUntilExpiring or false
    -- Frame alpha reverts to saved alpha instead of 0 when "not expiring"
    if typeKey == "framealpha" and hideUntilExpiring then
        local state = frame.dfAD
        pendingHiddenAlpha = state and state.savedAlpha or 1.0
    else
        pendingHiddenAlpha = nil
    end

    if typeKey == "border" then
        self:ApplyBorder(frame, config, auraData, auraName)
    elseif typeKey == "healthbar" then
        self:ApplyHealthBar(frame, config, auraData)
    elseif typeKey == "background" then
        self:ApplyBackground(frame, config, auraData)
    elseif typeKey == "nametext" then
        self:ApplyNameText(frame, config, auraData)
    elseif typeKey == "healthtext" then
        self:ApplyHealthText(frame, config, auraData)
    elseif typeKey == "framealpha" then
        self:ApplyFrameAlpha(frame, config, auraData)
    elseif typeKey == "icon" then
        self:UpdateIcon(frame, config, auraData, defaults, auraName, priority)
    elseif typeKey == "square" then
        self:UpdateSquare(frame, config, auraData, defaults, auraName, priority)
    elseif typeKey == "bar" then
        self:UpdateBar(frame, config, auraData, defaults, auraName, priority)
    end

    pendingHideWhenNotExpiring = false  -- Reset
    pendingUseShowHide = false
    pendingHiddenAlpha = nil

    -- After rendering, hide the indicator if we're in "present but hide until expiring" mode.
    -- The expiring ticker (3 FPS) will toggle visibility when the threshold is met.
    -- Use Hide() for icons/squares so OOR alpha restore (UpdateAuraDesignerAppearance)
    -- won't undo our visibility override. Borders keep SetAlpha since they're not in
    -- the OOR icon/square loop.
    if hideUntilExpiring then
        if typeKey == "icon" then
            local icon = frame.dfAD_icons and frame.dfAD_icons[auraName]
            if icon then icon:Hide() end
        elseif typeKey == "square" then
            local sq = frame.dfAD_squares and frame.dfAD_squares[auraName]
            if sq then sq:Hide() end
        elseif typeKey == "border" then
            local ch = frame.dfAD_border
            if config.borderMode == "custom" and frame.dfAD_customBorders then
                ch = frame.dfAD_customBorders[auraName]
            end
            if ch then
                DF.Border:Apply(ch, { enabled = false })  -- hide edges + stop animation
                ch.dfAD_sig = nil
            end
        elseif typeKey == "framealpha" then
            -- Revert to normal alpha — don't make the frame transparent
            local state = frame.dfAD
            local savedAlpha = state and state.savedAlpha or 1.0
            frame:SetAlpha(savedAlpha)
        end
    end
end

-- ============================================================
-- APPLY (TEST MODE)
-- Skips aura validation — mock data has no real auraInstanceID
-- ============================================================

function Indicators:ApplyTest(frame, typeKey, config, auraData, defaults, auraName, priority)
    if typeKey == "border" then
        self:ApplyBorder(frame, config, auraData, auraName)
    elseif typeKey == "healthbar" then
        self:ApplyHealthBar(frame, config, auraData)
    elseif typeKey == "background" then
        self:ApplyBackground(frame, config, auraData)
    elseif typeKey == "nametext" then
        self:ApplyNameText(frame, config, auraData)
    elseif typeKey == "healthtext" then
        self:ApplyHealthText(frame, config, auraData)
    elseif typeKey == "framealpha" then
        self:ApplyFrameAlpha(frame, config, auraData)
    elseif typeKey == "icon" then
        self:ConfigureIcon(frame, config, defaults, auraName, priority)
        self:UpdateIcon(frame, config, auraData, defaults, auraName, priority)
    elseif typeKey == "square" then
        self:ConfigureSquare(frame, config, defaults, auraName, priority)
        self:UpdateSquare(frame, config, auraData, defaults, auraName, priority)
    elseif typeKey == "bar" then
        self:ConfigureBar(frame, config, defaults, auraName, priority)
        self:UpdateBar(frame, config, auraData, defaults, auraName, priority)
    end
end

-- ============================================================
-- END FRAME
-- Revert anything not claimed during this frame's Apply calls
-- ============================================================

function Indicators:EndFrame(frame)
    local state = frame.dfAD
    if not state then return end

    -- Revert shared border
    if not state.border then
        self:RevertBorder(frame)
    end

    -- Hide custom borders not active this frame
    if frame.dfAD_customBorders then
        for key, ch in pairs(frame.dfAD_customBorders) do
            if not state.activeCustomBorders[key] then
                UnregisterExpiring(ch)
                DF.Border:Apply(ch, { enabled = false })
                ch.dfAD_sig = nil
            end
        end
    end

    -- Revert health bar color
    if not state.healthbar then
        self:RevertHealthBar(frame)
    end

    -- Revert background colour
    if not state.background then
        self:RevertBackground(frame)
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

    -- Re-apply OOR alpha after AD has set config alphas on all indicators
    if DF.UpdateAuraDesignerAppearance then
        DF:UpdateAuraDesignerAppearance(frame)
    end
end

-- ============================================================
-- HIDE ALL -- Clear everything (used when AD disabled or no unit)
-- ============================================================

function Indicators:HideAll(frame)
    self:RevertBorder(frame)
    self:RevertCustomBorders(frame)
    self:RevertHealthBar(frame)
    self:RevertBackground(frame)
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

-- Map old border style names to the current uppercase keys
local BORDER_STYLE_MIGRATION = { Solid = "SOLID", Glow = "GLOW", Pulse = "SOLID" }

-- Stage 5.4: the border-type indicator now renders through DF.Border (a 4-edge
-- widget covering the whole unit frame) instead of the highlight overlay.  The
-- legacy `style` enum maps onto a DF.Border style + animation:
--   SOLID    → solid edges
--   GLOW     → TEXTURE style + the bundled "DF Glow" edgeFile
--   DASHED   → base hidden + DF_DASH @ freq 0 (static dashes)
--   ANIMATED → base hidden + DF_DASH @ freq 1 (marching ants)
--   CORNERS  → base hidden + CORNERS_ONLY
-- (Inset is positive-INWARD here, matching the highlight system's convention.)
local function BuildBorderTypeSpec(config)
    local thickness = config.thickness or 2
    local inset     = config.inset or 0
    local color     = config.color or { r = 0, g = 0, b = 0, a = 1 }
    local style     = BORDER_STYLE_MIGRATION[config.style] or config.style or "SOLID"
    local spec = {
        enabled = true, style = "SOLID",
        size = thickness, inset = inset, color = color,
    }
    if style == "GLOW" then
        spec.style   = "TEXTURE"
        spec.texture = "DF Glow"
    elseif style == "DASHED" or style == "ANIMATED" then
        spec.size = 0  -- hide the solid base; the dashes ARE the border
        spec.animation = { type = "DF_DASH",
            frequency = (style == "ANIMATED") and 1 or 0,
            thickness = thickness, inset = inset, color = color }
    elseif style == "CORNERS" then
        spec.size = 0
        spec.animation = { type = "CORNERS_ONLY", thickness = thickness, color = color }
    end
    return spec
end

-- Whole-frame DF.Border widget.  SetAllPoints tracks the frame automatically,
-- and being a child of the frame it hides when the frame does.
local function NewADBorderWidget(frame, levelOffset)
    local w = DF.Border:New(frame, { frameLevelOffset = levelOffset, layer = "OVERLAY" })
    -- Remember the creation offset so ApplyBorderToOverlay can re-derive the
    -- frame level from it when the "Draw above frame border" toggle changes.
    w.dfAD_baseLevelOffset = levelOffset
    return w
end

local function GetOrCreateADBorder(frame)
    if frame.dfAD_border then return frame.dfAD_border end
    frame.dfAD_border = NewADBorderWidget(frame, 8)  -- below aggro(+9)
    return frame.dfAD_border
end

local function GetOrCreateCustomBorder(frame, key)
    if not frame.dfAD_customBorders then frame.dfAD_customBorders = {} end
    local pool = frame.dfAD_customBorders
    if pool[key] then return pool[key] end
    pool[key] = NewADBorderWidget(frame, 7)  -- below shared border(+8)
    return pool[key]
end

-- Comprehensive change-detection signature for the border-type spec.  MUST
-- cover every render-affecting field, or a GUI edit to an uncovered field
-- won't reach live frames until /reload (the preview rebuilds every refresh so
-- it always reflects edits, masking the gap).
local function colorSig(c)
    if not c then return "_" end
    return tostring(c.r or c[1]) .. "," .. tostring(c.g or c[2]) .. ","
        .. tostring(c.b or c[3]) .. "," .. tostring(c.a or c[4])
end
local function BorderTypeSpecSig(spec, auraID, config)
    local an, gr, sh = spec.animation, spec.gradient, spec.shadow
    return table.concat({
        tostring(spec.style), tostring(spec.size), tostring(spec.inset),
        tostring(spec.offsetX), tostring(spec.offsetY), tostring(spec.texture),
        tostring(spec.blendMode), colorSig(spec.color),
        gr and ("G" .. colorSig(gr.startColor) .. colorSig(gr.endColor) .. tostring(gr.direction)) or "_",
        sh and ("S" .. tostring(sh.enabled) .. colorSig(sh.color) .. tostring(sh.size)
                .. tostring(sh.offsetX) .. tostring(sh.offsetY)) or "_",
        an and ("A" .. tostring(an.type) .. tostring(an.frequency) .. tostring(an.particles)
                .. tostring(an.length) .. tostring(an.thickness) .. tostring(an.scale)
                .. tostring(an.inset) .. tostring(an.offsetX) .. tostring(an.offsetY)
                .. tostring(an.mask) .. tostring(an.sidesAxis) .. tostring(an.cornerLength)
                .. colorSig(an.color)) or "_",
        tostring(auraID),
        tostring(config.drawAboveFrameBorder),
        tostring(config.expiringFeatureEnabled),
        tostring(config.expiringEnabled), tostring(config.expiringPulsate),
        tostring(config.expiringThreshold), tostring(config.expiringThresholdMode),
        colorSig(config.expiringColor), tostring(config.expiringAlpha),
        -- Expiring-border overrides — included so editing them rebuilds the
        -- base + expiring spec pair.
        tostring(config.ExpiringBorderSize), tostring(config.ExpiringBorderAlpha),
        tostring(config.ExpiringAnimationType), tostring(config.ExpiringAnimationFrequency),
        tostring(config.ExpiringAnimationThickness),
        colorSig(config.ExpiringAnimationColor),
        tostring(config.ExpiringAnimationParticles), tostring(config.ExpiringAnimationLength),
        tostring(config.ExpiringAnimationScale), tostring(config.ExpiringAnimationInset),
        tostring(config.ExpiringAnimationOffsetX), tostring(config.ExpiringAnimationOffsetY),
        tostring(config.ExpiringAnimationMask), tostring(config.ExpiringAnimationSidesAxis),
        tostring(config.ExpiringAnimationCornerLength),
    }, "|")
end

-- Build the EXPIRING-state spec for the border-type: clone the base spec, then
-- apply the expiring overrides (thickness / alpha / colour / animation swap).
-- `applyColor` true recolours to the expiring colour (with its own alpha);
-- else keep the base colour and alpha.  The ticker swaps base ↔ expiring on the
-- threshold crossing; RecolorActive applies the colour between.
local function buildBorderExpiringSpec(baseSpec, config, ec, applyColor)
    local s = {}
    for k, v in pairs(baseSpec) do s[k] = v end
    -- Alpha rides with the colour (no separate multiplier): the expiring colour
    -- carries its own alpha; the base colour keeps the base alpha.
    local base = baseSpec.color or { r = 1, g = 1, b = 1, a = 1 }
    if applyColor then
        s.color = { r = ec.r or 1, g = ec.g or 0.2, b = ec.b or 0.2, a = ec.a or ec[4] or 1 }
    else
        s.color = { r = base.r or base[1] or 1, g = base.g or base[2] or 1,
                    b = base.b or base[3] or 1, a = (base.a or base[4]) or 1 }
    end
    local expThick = config.ExpiringBorderSize
    local expAnim  = config.ExpiringAnimationType
    if expAnim and expAnim ~= "NONE" then
        s.animation = {
            type         = expAnim,
            color        = config.ExpiringAnimationColor or s.color,
            frequency    = config.ExpiringAnimationFrequency,
            thickness    = expThick or config.ExpiringAnimationThickness,
            particles    = config.ExpiringAnimationParticles,
            length       = config.ExpiringAnimationLength,
            scale        = config.ExpiringAnimationScale,
            inset        = config.ExpiringAnimationInset,
            offsetX      = config.ExpiringAnimationOffsetX,
            offsetY      = config.ExpiringAnimationOffsetY,
            mask         = config.ExpiringAnimationMask,
            sidesAxis    = config.ExpiringAnimationSidesAxis,
            cornerLength = config.ExpiringAnimationCornerLength,
        }
        if expAnim == "DF_DASH" or expAnim == "CORNERS_ONLY" or expAnim == "SIDES_ONLY" then
            s.size = 0  -- these effects ARE the border; hide the base edges
        end
    elseif expThick then
        if s.size and s.size > 0 then
            s.size = expThick
        elseif s.animation then
            local a = {}; for k, v in pairs(s.animation) do a[k] = v end
            a.thickness = expThick; s.animation = a
        end
    end
    return s
end

-- Shared logic for applying border style, change detection, and expiring
-- registration to a border overlay frame. Used by both shared and custom borders.
local function ApplyBorderToOverlay(ch, frame, config, auraData)
    -- Legacy configs (still carrying the old `style` enum) map via
    -- BuildBorderTypeSpec; migrated configs build the canonical spec directly.
    -- The lazy border-key fold (DF.MigrateAuraDesignerBorderKeysLazy) runs on the
    -- resolved adDB at every render/test entry BEFORE we get here, so a config
    -- reaching this line with `style` still set is genuinely un-folded — we let it
    -- use the legacy builder rather than masking the fold gap.  (A half-migrated
    -- block that carries both `style` and canonical keys can only appear if the
    -- fold failed to run; that should surface visibly, not be papered over.)
    local spec = config.style and BuildBorderTypeSpec(config) or DF.Border:BuildSpec(config, "")
    -- AD config has no pixelPerfect key of its own; inherit the frame's so the
    -- border thickness snaps. (This border SetAllPoints the frame, which is already
    -- pixel-aligned, so no position snap is needed here.)
    spec.pixelPerfect = (DF:GetFrameDB(frame) or {}).pixelPerfect
    if not spec.color then spec.color = { r = 0, g = 0, b = 0, a = 1 } end
    if spec.enabled == nil then spec.enabled = true end
    if spec.enabled == false then
        DF.Border:Apply(ch, { enabled = false })
        UnregisterExpiring(ch)
        ch.dfAD_sig = "off"
        return
    end

    local bc = spec.color
    local r = bc.r or bc[1] or 1
    local g = bc.g or bc[2] or 1
    local b = bc.b or bc[3] or 1
    local alpha = bc.a or bc[4] or 1
    local auraID = auraData and auraData.auraInstanceID
    local expiringPulsate = config.expiringPulsate or false
    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end
    local ec = config.expiringColor

    -- Change detection — ApplyBorder runs every Apply cycle (frame-level
    -- indicator), so skip the rebuild + expiring re-register when nothing the
    -- border cares about changed.  Comprehensive (covers every render-affecting
    -- spec field) so GUI edits reach live frames without /reload.  The expiring
    -- ticker recolours live via RecolorActive between rebuilds.
    local sig = BorderTypeSpecSig(spec, auraID, config)
    if ch.dfAD_sig == sig then return end
    ch.dfAD_sig = sig

    DF.Border:Apply(ch, spec)

    -- Draw order: by default lift the border-type above the frame's class border
    -- (parent+10) and aggro (parent+9) so it fully covers them instead of being
    -- rendered underneath.  +4 preserves the shared(+8)/custom(+7) relative order
    -- (→ 12 / 11).  Toggling it off restores the creation offset so it tucks back
    -- under the class border.
    local baseOff = ch.dfAD_baseLevelOffset or 8
    local lvlOff  = (config.drawAboveFrameBorder ~= false) and (baseOff + 4) or baseOff
    ch:SetFrameLevel(frame:GetFrameLevel() + lvlOff)

    -- Lazy-create pulse animation group (reused across aura changes)
    if expiringPulsate then GetOrCreatePulseAnim(ch) end
    ch.dfAD_expiringPulsate = expiringPulsate

    -- Expiring features (Stage 5.4 parity): master gate + colour override /
    -- pulsate / thickness / alpha / animation swap.  When thickness/alpha/
    -- animation differ from base, we build an EXPIRING spec the ticker swaps in
    -- on the threshold crossing; the colour override (if on) smooths the colour
    -- via RecolorActive between crossings (no per-tick tear-down).
    local masterEnabled = config.expiringFeatureEnabled ~= false
    local applyColor    = expiringEnabled
    local expAnimType   = config.ExpiringAnimationType
    local hasExpAnim    = expAnimType and expAnimType ~= "NONE"
    local baseThick     = (spec.size and spec.size > 0) and spec.size
                          or (spec.animation and spec.animation.thickness) or 0
    local hasExpThick   = config.ExpiringBorderSize and config.ExpiringBorderSize ~= baseThick
    -- Alpha is no longer a separate override: it rides with the expiring colour
    -- (expiringColor.a), applied by RecolorActive when the colour override is on
    -- — matching the base Border Alpha = BorderColor.a model.
    local anyExp = masterEnabled and (applyColor or expiringPulsate
                   or hasExpAnim or hasExpThick)

    if anyExp then
        local ecc = ec or {r = 1, g = 0.2, b = 0.2}
        local oc = {r = r, g = g, b = b}
        ch.dfAD_baseSpec = spec
        ch.dfAD_expSpec  = (hasExpAnim or hasExpThick)
                           and buildBorderExpiringSpec(spec, config, ecc, applyColor) or nil
        ch.dfAD_lastExp  = nil  -- force the ticker to (re)apply the right spec

        -- Shared state transition: swap the base/expiring spec on the threshold
        -- crossing, then SNAP the colour to the full expiring colour (the curve
        -- is a STEP curve so there's no washed-out fade).  Reached from both
        -- applyResult (live, secret-safe colour-curve path) and applyManual
        -- (preview / non-colour fallback).
        local function applyBorderExpState(el, isExp, entry)
            if el.dfAD_expSpec and isExp ~= el.dfAD_lastExp then
                el.dfAD_lastExp = isExp
                DF.Border:Apply(el, isExp and el.dfAD_expSpec or el.dfAD_baseSpec)
            end
            -- Recolour only when the colour override is on; otherwise the spec
            -- swap already carries the right colour.
            if entry.applyColor then
                if isExp then
                    local c = entry.color
                    DF.Border:RecolorActive(el, c.r or 1, c.g or 0.2, c.b or 0.2, entry.expiringAlpha)
                else
                    local c = entry.originalColor
                    DF.Border:RecolorActive(el, c.r, c.g, c.b, entry.originalAlpha)
                end
            end
            UpdatePulseState(el, isExp)
        end

        RegisterExpiring(ch, {
            unit = frame.unit,
            auraInstanceID = auraID,
            threshold = config.expiringThreshold or 30,
            duration = auraData and auraData.duration,
            expirationTime = auraData and auraData.expirationTime,
            -- Colour curve drives the secret-safe live detection path: live aura
            -- durations are tainted, so the manual fallback can't read them and
            -- the curve's EvaluateRemainingPercent is the only way to detect the
            -- threshold crossing on real frames.  It's a STEP curve, so the
            -- colour SNAPS to the full expiring colour (no washed-out blend).
            colorCurve = applyColor and BuildExpiringColorCurve(config.expiringThreshold or 30, ecc, oc, config.expiringThresholdMode) or nil,
            thresholdMode = config.expiringThresholdMode,
            color = ecc, originalColor = oc,
            originalAlpha = alpha,
            -- Expiring alpha = the expiring colour's own alpha (in sync with its
            -- picker), not a separate slider.
            expiringAlpha = ecc.a or ecc[4] or 1,
            applyColor = applyColor,
            applyResult = function(el, result, entry)
                -- Fires only when colorCurve is set (colour override on).  The
                -- stepped result is either the base or full expiring colour.
                applyBorderExpState(el, IsColorExpiring(result, entry.originalColor), entry)
            end,
            applyManual = function(el, isExp, entry)
                applyBorderExpState(el, isExp, entry)
            end,
        })
    else
        UnregisterExpiring(ch)
        ch.dfAD_baseSpec, ch.dfAD_expSpec, ch.dfAD_lastExp = nil, nil, nil
        -- Stop pulsation when expiring is disabled
        if ch.dfAD_pulse and ch.dfAD_pulse:IsPlaying() then
            ch.dfAD_pulse:Stop()
            ch:SetAlpha(1)
        end
    end
end

function Indicators:ApplyBorder(frame, config, auraData, auraName)
    local state = EnsureFrameState(frame)

    if config.borderMode == "custom" and auraName then
        -- Custom border: independent overlay, bypasses shared claim system
        local ch = GetOrCreateCustomBorder(frame, auraName)
        state.activeCustomBorders[auraName] = true
        ApplyBorderToOverlay(ch, frame, config, auraData)
        return
    end

    -- Shared border (default): priority-based, first claim wins
    if state.border then return end
    state.border = true
    local ch = GetOrCreateADBorder(frame)
    ApplyBorderToOverlay(ch, frame, config, auraData)
end

function Indicators:RevertBorder(frame)
    if frame and frame.dfAD_border then
        UnregisterExpiring(frame.dfAD_border)
        -- enabled=false hides the edges AND stops any animation (dashes/corners).
        DF.Border:Apply(frame.dfAD_border, { enabled = false })
        -- Clear the change-detection signature so the next ApplyBorder rebuilds.
        frame.dfAD_border.dfAD_sig = nil
    end
end

function Indicators:RevertCustomBorders(frame)
    if frame and frame.dfAD_customBorders then
        for _, ch in pairs(frame.dfAD_customBorders) do
            UnregisterExpiring(ch)
            DF.Border:Apply(ch, { enabled = false })
            ch.dfAD_sig = nil
        end
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
    local tex = healthBar:GetStatusBarTexture()
    overlay:SetStatusBarTexture(tex and tex:GetTexture() or "Interface\\Buttons\\WHITE8x8")
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
    local a = color[4] or color.a or 1
    local mode = string.lower(config.mode or "replace")
    -- Replace: colour picker alpha controls overlay (and underlying bar) opacity.
    -- Tint:    overlay opacity = blend slider × colour picker alpha (alpha scales
    --          tint intensity so the class colour shows through more at low alpha).
    local blend = (mode == "replace") and a or ((config.blend or 0.5) * a)

    -- Store on state so UpdateAuraDesignerAppearance / UpdateHealthBarAppearance
    -- can access these for OOR handling and the replace/tint mode gate.
    state.healthbarMode     = mode
    -- Tint mode only: when set, the tint overlay covers the WHOLE bar (including
    -- the missing-health portion) instead of tracking current health. Read by
    -- UpdateADTintHealth. Meaningless in replace mode (the real bar IS the
    -- indicator, so tinting "missing health" would just hide health loss).
    state.healthbarTintWholeBar = (mode == "tint") and (config.tintWholeBar and true or false) or false
    state.healthbarR        = r
    state.healthbarG        = g
    state.healthbarB        = b
    state.healthbarBlend    = blend
    -- Alpha for the currently displayed colour. The expiring ticker swaps this to
    -- the expiring colour's own blend so its alpha is respected rather than the
    -- base colour's. healthbarOOR lets the ticker preserve the OOR fade.
    state.healthbarCurrentBlend = blend
    state.healthbarOOR      = false
    -- Track the currently displayed color (may differ from healthbarR/G/B when
    -- the expiring ticker has switched the overlay to the expiring color).
    -- UpdateAuraDesignerAppearance reads this so it doesn't reset the expiring
    -- color back to the active color on every UNIT_AURA event.
    state.healthbarCurrentR = r
    state.healthbarCurrentG = g
    state.healthbarCurrentB = b
    -- healthbarEffectiveBlend: the alpha last written to the overlay by
    -- UpdateAuraDesignerAppearance (blend in-range, oorAlpha OOR). Expiring
    -- callbacks read this so they don't override the OOR fade back to full
    -- blend between UpdateAuraDesignerAppearance calls. Not reset here so
    -- OOR state is preserved across UNIT_AURA events; nil on first use falls
    -- back to entry.blend in the callbacks.

    -- The element the expiring ticker + pulse drive, and the layer that carries
    -- the AD colour. Set per mode below.
    local expiringEl

    if mode == "replace" then
        -- ============================================================
        -- REPLACE MODE — SINGLE LAYER
        -- AD owns the real health bar directly. No overlay: the bar IS the
        -- indicator. Colour goes through the fill texture's vertex RGB; opacity
        -- through its FRAME alpha (SetAlpha), NOT vertex alpha — StatusBar:SetValue
        -- resets the fill texture's vertex alpha to full on every health update
        -- (smooth or not), which was the "alpha flickers to 100%" bug. Frame alpha
        -- survives SetValue, and UpdateHealthBarAppearance re-asserts colour+alpha
        -- on every health event (see ElementAppearance.lua). DF's colour system
        -- yields to AD while state.healthbar is set (Core.lua
        -- LightweightUpdateHealthColor early-returns when the frame is in AD replace
        -- mode; UpdateHealthBarAppearance gates on healthbarMode == "replace").
        -- ============================================================
        -- Drop any overlay left over from a previous tint apply on this frame.
        if state.tintOverlay then
            UnregisterExpiring(state.tintOverlay)
            if state.tintOverlay.dfAD_pulse and state.tintOverlay.dfAD_pulse:IsPlaying() then
                state.tintOverlay.dfAD_pulse:Stop()
            end
            state.tintOverlay:SetAlpha(1)
            state.tintOverlay:Hide()
        end

        local hbTex = healthBar:GetStatusBarTexture()
        if hbTex then
            -- OOR-aware effective blend if already established (preserves the OOR
            -- fade across UNIT_AURA re-applies), else the configured alpha. While the
            -- pulse is running the ticker owns the frame alpha, so only set the colour.
            hbTex:SetVertexColor(r, g, b)
            if not state.healthbarPulseOn then hbTex:SetAlpha(state.healthbarEffectiveBlend or a) end
        end
        expiringEl = healthBar
    else
        -- ============================================================
        -- TINT MODE — translucent colour overlay over the class-coloured bar.
        -- The overlay's fill tracks current health (UpdateADTintHealth); its
        -- alpha = blend × colour alpha so the class colour shows through.
        -- ============================================================
        local overlay = GetOrCreateTintOverlay(frame)
        if overlay then
            -- Full-size. The frame border (frame level +10) draws inward over the health
            -- bar's edge and sits ABOVE the overlay, so it covers the overlay's outer ring
            -- and the tint fills the whole visible bar — no missing edge pixels, matching
            -- replace mode. (Out of range the faded border can let a faint tint show
            -- through it; gating an inset on the OOR flag proved unreliable — UnitInRange
            -- returns secret/stale values in instances, sticking the flag and insetting in
            -- range — so we keep it simple and full-size.)
            overlay:ClearAllPoints()
            overlay:SetAllPoints(healthBar)

            -- Re-sync texture in case the health bar's texture changed since the overlay
            -- was first created (frame recycled to a different unit can swap textures).
            local currentTex = healthBar:GetStatusBarTexture()
            overlay:SetStatusBarTexture(currentTex and currentTex:GetTexture() or "Interface\\Buttons\\WHITE8x8")
            -- Use OOR-aware blend if already established (preserves OOR fade on UNIT_AURA).
            local initialBlend = state.healthbarEffectiveBlend or blend
            overlay:SetStatusBarColor(r, g, b, initialBlend)

            -- The underlying bar must show its normal colour through the overlay.
            -- A previous replace-mode apply may have left a stale AD vertex colour /
            -- frame alpha on hbTex. Briefly release the AD lock so
            -- UpdateHealthBarAppearance restores the normal class/custom colour and
            -- the configured alpha before we re-claim the bar.
            state.healthbar = false
            if DF.UpdateHealthBarAppearance then
                DF:UpdateHealthBarAppearance(frame)
            end
            state.healthbar = true

            -- Snap fill to current health before showing so the bar doesn't animate
            -- from near-empty to the correct position (ExponentialEaseOut + the
            -- min/max changing from the creation default of 0-1 to 0-maxHealth
            -- makes the stored value of 1 render as ~0% until the smooth completes).
            if DF.UpdateADTintHealth then
                DF:UpdateADTintHealth(frame, true)  -- true = skip smooth interpolation
            end
            overlay:Show()
        end
        expiringEl = state.tintOverlay
    end

    if not expiringEl then return end

    -- ========================================
    -- EXPIRING: register overlay with ticker
    -- ========================================
    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end

    local expiringPulsate = config.expiringPulsate or false
    -- The pulse is driven by the shared global ticker (SetHealthBarPulse) for BOTH
    -- modes, so every expiring bar breathes in unison. Just record whether it's
    -- enabled; the expiring callbacks toggle it on/off via UpdateHealthBarPulse.
    state.healthbarExpiringPulsate = expiringPulsate
    if not expiringPulsate then
        SetHealthBarPulse(frame, false)
    end

    if expiringEnabled then
        local ec = config.expiringColor or {r = 1, g = 0.2, b = 0.2}
        local oc = {r = r, g = g, b = b}
        -- Expiring colour's own alpha, run through the same mode formula as the
        -- base blend (replace = alpha; tint = blend slider × alpha).
        local ea = ec.a or ec[4] or 1
        local expiringBlend = (mode == "replace") and ea or ((config.blend or 0.5) * ea)
        RegisterExpiring(expiringEl, {
            unit = frame.unit,
            auraInstanceID = auraData and auraData.auraInstanceID,
            threshold = config.expiringThreshold or 30,
            duration = auraData and auraData.duration,
            expirationTime = auraData and auraData.expirationTime,
            blend = blend,
            expiringBlend = expiringBlend,
            colorCurve = BuildExpiringColorCurve(config.expiringThreshold or 30, ec, oc, config.expiringThresholdMode),
            thresholdMode = config.expiringThresholdMode,
            color = ec, originalColor = oc,
            applyResult = function(el, result, entry)
                local adState = frame.dfAD
                local oc2 = entry.originalColor
                local isExp = IsColorExpiring(result, oc2)
                -- Alpha follows the displayed colour: expiring colour uses its own
                -- blend, active colour uses the base blend.
                local curBlend = (isExp and entry.expiringBlend) or entry.blend
                -- Out of range, keep the OOR fade; in range use the colour's blend.
                local effectiveBlend = (adState and adState.healthbarOOR
                    and (adState.healthbarEffectiveBlend or curBlend)) or curBlend
                -- Keep current-color/blend in sync so UpdateAuraDesignerAppearance
                -- (OOR handler) uses the expiring color/alpha rather than the active one.
                if adState then
                    adState.healthbarCurrentR = result.r
                    adState.healthbarCurrentG = result.g
                    adState.healthbarCurrentB = result.b
                    adState.healthbarCurrentBlend = curBlend
                end
                if adState and adState.healthbarMode == "replace" then
                    -- Single layer: paint the real bar texture. Colour via vertex RGB,
                    -- opacity via FRAME alpha (SetValue-proof — see ApplyHealthBar).
                    local hbTex = frame.healthBar and frame.healthBar:GetStatusBarTexture()
                    if hbTex then
                        hbTex:SetVertexColor(result.r, result.g, result.b)
                        -- While pulsing, the ticker owns the frame alpha; just update colour.
                        if not adState.healthbarPulseOn then hbTex:SetAlpha(effectiveBlend) end
                    end
                else
                    el:SetStatusBarColor(result.r, result.g, result.b, effectiveBlend)
                end
                UpdateHealthBarPulse(frame, isExp)
            end,
            applyManual = function(el, isExp, entry)
                local c = isExp and entry.color or entry.originalColor
                local cr, cg, cb = c.r or 1, c.g or 1, c.b or 1
                local adState = frame.dfAD
                -- Alpha follows the displayed colour: expiring colour uses its own
                -- blend, active colour uses the base blend.
                local curBlend = (isExp and entry.expiringBlend) or entry.blend
                -- Out of range, keep the OOR fade; in range use the colour's blend.
                local effectiveBlend = (adState and adState.healthbarOOR
                    and (adState.healthbarEffectiveBlend or curBlend)) or curBlend
                -- Keep current-color/blend in sync so UpdateAuraDesignerAppearance
                -- (OOR handler) uses the expiring color/alpha rather than the active one.
                if adState then
                    adState.healthbarCurrentR = cr
                    adState.healthbarCurrentG = cg
                    adState.healthbarCurrentB = cb
                    adState.healthbarCurrentBlend = curBlend
                end
                if adState and adState.healthbarMode == "replace" then
                    local hbTex = frame.healthBar and frame.healthBar:GetStatusBarTexture()
                    if hbTex then
                        hbTex:SetVertexColor(cr, cg, cb)
                        -- While pulsing, the ticker owns the frame alpha; just update colour.
                        if not adState.healthbarPulseOn then hbTex:SetAlpha(effectiveBlend) end
                    end
                else
                    el:SetStatusBarColor(cr, cg, cb, effectiveBlend)
                end
                UpdateHealthBarPulse(frame, isExp)
            end,
        })
    elseif expiringEl then
        UnregisterExpiring(expiringEl)
        SetHealthBarPulse(frame, false)
    end
end

function Indicators:RevertHealthBar(frame)
    local state = frame and frame.dfAD
    if not state then return end

    -- Stop the shared pulse first (it reads healthbarMode / blend, cleared below)
    -- and restore the steady alpha.
    SetHealthBarPulse(frame, false)

    -- TINT mode: hide the overlay and unregister its expiring ticker.
    if state.tintOverlay then
        UnregisterExpiring(state.tintOverlay)
        state.tintOverlay:SetAlpha(1)
        state.tintOverlay:Hide()
        state.tintOverlay:SetStatusBarColor(1, 1, 1, 1)
    end

    -- REPLACE mode (single layer): the expiring ticker runs on the real health bar.
    -- Unregister it. The bar's colour and frame alpha are restored below by
    -- UpdateHealthBarAppearance (state.healthbar is now false, so it repaints the
    -- normal class/custom colour and configured alpha).
    if frame.healthBar then
        UnregisterExpiring(frame.healthBar)
    end

    -- Clear tracked color and blend so stale values don't affect the next
    -- aura that claims this frame's health bar indicator.
    state.healthbarMode          = nil
    state.healthbarTintWholeBar  = nil
    state.healthbarCurrentR      = nil
    state.healthbarCurrentG      = nil
    state.healthbarCurrentB      = nil
    state.healthbarCurrentBlend  = nil
    state.healthbarOOR           = nil
    state.healthbarEffectiveBlend = nil

    -- Refresh health bar color so the bar shows the correct color
    -- (class color, custom color, etc.) after the overlay is removed.
    -- This also handles the login edge case where the bar may not
    -- have been fully colored before the overlay was first applied.
    if DF.UpdateHealthBarAppearance then
        DF:UpdateHealthBarAppearance(frame)
    end
end

-- ============================================================
-- BACKGROUND COLOUR INDICATOR
-- A solid colour overlay laid over the frame background, BELOW the health/
-- missing bars, so the colour shows through wherever the background shows
-- (the missing-health area + padding) and the health fill naturally covers it.
-- Mirrors the health-bar TINT overlay: colour + blend ride SetStatusBarColor's
-- alpha; OOR fade rides the same channel; the per-element AnimationGroup pulse
-- (shared with icons/squares) rides the overlay's frame alpha — a separate
-- channel, so the two multiply cleanly. No UpdateBackgroundAppearance yield is
-- needed (this is an independent layer above the real background).
-- ============================================================

local function GetOrCreateADBgOverlay(frame)
    local state = frame.dfAD
    if state and state.bgOverlay then return state.bgOverlay end
    if not frame.background then return nil end

    -- Frame level == frame's own level: above the BACKGROUND-layer background
    -- texture, below the +1 health/missing bars. SetValue(1) keeps it full.
    local overlay = CreateFrame("StatusBar", nil, frame)
    overlay:SetAllPoints(frame.background)
    overlay:SetFrameLevel(frame:GetFrameLevel())
    overlay:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    overlay:SetMinMaxValues(0, 1)
    overlay:SetValue(1)
    overlay:Hide()

    if state then state.bgOverlay = overlay end
    return overlay
end

function Indicators:ApplyBackground(frame, config, auraData)
    local state = EnsureFrameState(frame)
    if state.background then return end
    state.background = true

    if not frame.background then return end
    local color = config.color
    if not color then return end

    local r, g, b = color[1] or color.r or 1, color[2] or color.g or 1, color[3] or color.b or 1
    local a = color[4] or color.a or 1
    local mode = string.lower(config.mode or "tint")
    -- Replace: the colour-picker alpha IS the overlay opacity (covers the bg).
    -- Tint:    overlay opacity = blend slider × colour alpha (bg shows through).
    local blend = (mode == "replace") and a or ((config.blend or 0.5) * a)

    state.bgMode         = mode
    state.bgR, state.bgG, state.bgB = r, g, b
    state.bgBlend        = blend
    state.bgCurrentR, state.bgCurrentG, state.bgCurrentB = r, g, b
    state.bgCurrentBlend = blend
    state.bgOOR          = false
    -- bgEffectiveBlend is NOT reset here so the OOR fade survives UNIT_AURA re-applies.

    local overlay = GetOrCreateADBgOverlay(frame)
    if not overlay then return end

    -- Use OOR-aware blend if already established (preserves OOR fade on re-apply).
    local initialBlend = state.bgEffectiveBlend or blend
    overlay:SetStatusBarColor(r, g, b, initialBlend)
    overlay:SetAlpha(1)
    overlay:Show()

    -- ===== Expiring + pulse =====
    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end
    local expiringPulsate = config.expiringPulsate or false
    overlay.dfAD_expiringPulsate = expiringPulsate
    if expiringPulsate then
        GetOrCreatePulseAnim(overlay)
    elseif overlay.dfAD_pulse and overlay.dfAD_pulse:IsPlaying() then
        overlay.dfAD_pulse:Stop()
        overlay:SetAlpha(1)
    end

    if expiringEnabled then
        local ec = config.expiringColor or {r = 1, g = 0.2, b = 0.2}
        local oc = {r = r, g = g, b = b}
        local ea = ec.a or ec[4] or 1
        local expiringBlend = (mode == "replace") and ea or ((config.blend or 0.5) * ea)
        RegisterExpiring(overlay, {
            unit = frame.unit,
            auraInstanceID = auraData and auraData.auraInstanceID,
            threshold = config.expiringThreshold or 30,
            duration = auraData and auraData.duration,
            expirationTime = auraData and auraData.expirationTime,
            blend = blend,
            expiringBlend = expiringBlend,
            colorCurve = BuildExpiringColorCurve(config.expiringThreshold or 30, ec, oc, config.expiringThresholdMode),
            thresholdMode = config.expiringThresholdMode,
            color = ec, originalColor = oc,
            applyResult = function(el, result, entry)
                local adState = frame.dfAD
                local isExp = IsColorExpiring(result, entry.originalColor)
                local curBlend = (isExp and entry.expiringBlend) or entry.blend
                local effectiveBlend = (adState and adState.bgOOR
                    and (adState.bgEffectiveBlend or curBlend)) or curBlend
                if adState then
                    adState.bgCurrentR, adState.bgCurrentG, adState.bgCurrentB = result.r, result.g, result.b
                    adState.bgCurrentBlend = curBlend
                end
                el:SetStatusBarColor(result.r, result.g, result.b, effectiveBlend)
                UpdatePulseState(el, isExp)
            end,
            applyManual = function(el, isExp, entry)
                local c = isExp and entry.color or entry.originalColor
                local cr, cg, cb = c.r or 1, c.g or 1, c.b or 1
                local adState = frame.dfAD
                local curBlend = (isExp and entry.expiringBlend) or entry.blend
                local effectiveBlend = (adState and adState.bgOOR
                    and (adState.bgEffectiveBlend or curBlend)) or curBlend
                if adState then
                    adState.bgCurrentR, adState.bgCurrentG, adState.bgCurrentB = cr, cg, cb
                    adState.bgCurrentBlend = curBlend
                end
                el:SetStatusBarColor(cr, cg, cb, effectiveBlend)
                UpdatePulseState(el, isExp)
            end,
        })
    else
        UnregisterExpiring(overlay)
    end
end

function Indicators:RevertBackground(frame)
    local state = frame and frame.dfAD
    if not state then return end
    if state.bgOverlay then
        UnregisterExpiring(state.bgOverlay)
        if state.bgOverlay.dfAD_pulse and state.bgOverlay.dfAD_pulse:IsPlaying() then
            state.bgOverlay.dfAD_pulse:Stop()
        end
        state.bgOverlay:SetAlpha(1)
        state.bgOverlay:Hide()
        state.bgOverlay:SetStatusBarColor(1, 1, 1, 1)
    end
    state.bgMode          = nil
    state.bgCurrentR      = nil
    state.bgCurrentG      = nil
    state.bgCurrentB      = nil
    state.bgCurrentBlend  = nil
    state.bgOOR           = nil
    state.bgEffectiveBlend = nil
end

-- Update tint overlay fill to match current health.
-- Called from UpdateUnitFrame and UpdateHealthFast (same pattern as
-- DF:UpdateDispelGradientHealth and DF:UpdateMyBuffGradientHealth).
function DF:UpdateADTintHealth(frame, skipSmooth)
    if not frame or not frame.dfAD then return end

    local overlay = frame.dfAD.tintOverlay
    -- Allow being called before Show() (skipSmooth path from ApplyHealthBar)
    if not overlay then return end
    if not skipSmooth and not overlay:IsShown() then return end

    -- Whole-bar tint: fill the overlay completely so the tint covers the missing-
    -- health portion too, rather than tracking current health. Orientation is
    -- irrelevant at 100% fill, and we don't need the unit's health, so return early.
    if frame.dfAD.healthbarTintWholeBar then
        overlay:SetMinMaxValues(0, 1)
        overlay:SetValue(1)
        return
    end

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

    -- skipSmooth: always snap when called from ApplyHealthBar before Show()
    -- so the bar doesn't animate from its default position to actual health.
    local smoothEnabled = (not skipSmooth) and db and db.smoothBars
    if smoothEnabled and Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut then
        overlay:SetValue(currentHealth, Enum.StatusBarInterpolation.ExponentialEaseOut)
    else
        overlay:SetValue(currentHealth)
    end
end

-- ============================================================
-- NAME TEXT COLOR
-- ============================================================

-- Shared driver for the "Name Text" / "Health Text" AD indicators. The legacy
-- frame.nameText/healthText are retired (DF:IsLegacyTextHidden == true), so the
-- visible text is the Text Designer's own FontStrings. We recolour those via the
-- TD override channel (per category "name"/"health"), which survives TD's own
-- re-renders. keyField is a per-frame slot holding a stable expiring-ticker key.
local function ApplyDesignerTextColor(frame, config, auraData, category, keyField)
    local Render = DF.TextDesigner and DF.TextDesigner.Render
    if not Render then return end

    local color = config.color
    if not color then return end
    local r, g, b = color[1] or color.r or 1, color[2] or color.g or 1, color[3] or color.b or 1

    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end

    if expiringEnabled then
        local ec = config.expiringColor or { r = 1, g = 0.2, b = 0.2 }
        local oc = { r = r, g = g, b = b }
        -- Stable per-(frame,category) proxy registered with the expiring ticker.
        -- The engine calls element:IsShown() each tick (and drops the entry when
        -- false) plus Show/Hide/SetAlpha for show-when-missing, so this must be a
        -- real frame, not a plain table. Kept shown; the colour is driven through
        -- SetAuraColorOverride in applyResult/applyManual, not on this proxy.
        local key = frame[keyField]
        if not key then
            key = CreateFrame("Frame", nil, UIParent)
            frame[keyField] = key
        end
        RegisterExpiring(key, {
            unit = frame.unit,
            auraInstanceID = auraData and auraData.auraInstanceID,
            threshold = config.expiringThreshold or 30,
            duration = auraData and auraData.duration,
            expirationTime = auraData and auraData.expirationTime,
            colorCurve = BuildExpiringColorCurve(config.expiringThreshold or 30, ec, oc, config.expiringThresholdMode),
            thresholdMode = config.expiringThresholdMode,
            color = ec, originalColor = oc,
            -- Drive the TD override each tick (TD does not re-render per tick).
            applyResult = function(_, result)
                Render:SetAuraColorOverride(frame, category, result)
            end,
            applyManual = function(_, isExp, entry)
                Render:SetAuraColorOverride(frame, category, isExp and entry.color or entry.originalColor)
            end,
        })
    else
        if frame[keyField] then UnregisterExpiring(frame[keyField]) end
        Render:SetAuraColorOverride(frame, category, { r = r, g = g, b = b, a = 1 })
    end
end

local function RevertDesignerTextColor(frame, category, keyField)
    if not frame then return end
    if frame[keyField] then UnregisterExpiring(frame[keyField]) end
    local Render = DF.TextDesigner and DF.TextDesigner.Render
    if Render then Render:ClearAuraColorOverride(frame, category) end
end

function Indicators:ApplyNameText(frame, config, auraData)
    local state = EnsureFrameState(frame)
    if state.nametext then return end
    state.nametext = true
    ApplyDesignerTextColor(frame, config, auraData, "name", "_tdNameColorKey")
end

function Indicators:RevertNameText(frame)
    RevertDesignerTextColor(frame, "name", "_tdNameColorKey")
end

-- ============================================================
-- HEALTH TEXT COLOR
-- ============================================================

function Indicators:ApplyHealthText(frame, config, auraData)
    local state = EnsureFrameState(frame)
    if state.healthtext then return end
    state.healthtext = true
    ApplyDesignerTextColor(frame, config, auraData, "health", "_tdHealthColorKey")
end

function Indicators:RevertHealthText(frame)
    RevertDesignerTextColor(frame, "health", "_tdHealthColorKey")
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
            colorCurve = BuildExpiringColorCurve(config.expiringThreshold or 30, ec, oc, config.expiringThresholdMode),
            thresholdMode = config.expiringThresholdMode,
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

-- Lazy-create the unified DF.Border widget that replaces the icon factory's
-- default 1px backdrop. The factory's `icon.border` (a single BACKGROUND
-- ColorTexture) is hidden once and stays hidden — AD icons render their
-- border exclusively through dfADBorder so the new feature set (style,
-- gradient, shadow, blendMode, offset) is available on every aura icon.
-- Non-AD callers of CreateAuraIcon are untouched because we don't modify
-- the factory itself.
local function GetOrCreateADIconBorder(icon)
    if icon.dfADBorder then return icon.dfADBorder end
    icon.dfADBorder = DF.Border:New(icon, { frameLevelOffset = 0, layer = "BACKGROUND" })
    if icon.border then icon.border:Hide() end
    return icon.dfADBorder
end

local function GetOrCreateADIcon(frame, auraName)
    local map = GetIconMap(frame)
    if map[auraName] then return map[auraName] end

    -- Use the same icon creation as the rest of the addon
    local icon = DF:CreateAuraIcon(frame, 0, "BUFF")
    icon.dfAD_auraName = auraName
    -- Set strata to the unit frame's strata so we don't inherit contentOverlay's
    -- higher strata and show through game panels before Configure runs.
    icon:SetFrameStrata(frame:GetFrameStrata())

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

-- ============================================================
-- ConfigureIcon: static config-driven properties (called once per config change)
-- Sets size, strata, border, fonts, propagation — anything that
-- does NOT depend on per-event aura data.
-- ============================================================
function Indicators:ConfigureIcon(frame, config, defaults, auraName, priority)
    local icon = GetOrCreateADIcon(frame, auraName)

    -- Size (clamp to 8 minimum; old configs may have sizes below the current slider floor)
    local size = math.max(8, config.size or (defaults and defaults.iconSize) or 24)
    local scale = config.scale or (defaults and defaults.iconScale) or 1.0
    -- Pixel-perfect: fold the user scale INTO the size and snap to whole physical
    -- pixels (resetting scale to 1.0) so the 1px DF.Border edges land on the pixel
    -- grid. A fractionally-sized icon put its top/bottom (or left/right) edges on
    -- different sub-pixel phases, which dropped, thickened, or side-switched a 1px
    -- border. Mirrors the defensive icon (bug 951). Stash the pre-fold user scale
    -- so the position offset below can be re-scaled to match.
    local fdb = DF:GetFrameDB(frame)
    if fdb and fdb.pixelPerfect and DF.PixelPerfectSizeAndScaleForBorder then
        icon.dfAD_userScale = scale
        size, scale = DF:PixelPerfectSizeAndScaleForBorder(size, scale, config.BorderSize or 1)
    else
        icon.dfAD_userScale = nil
    end
    icon:SetSize(size, size)
    icon:SetScale(scale)

    -- Alpha
    local iconAlpha = config.alpha or 1.0
    icon.dfBaseAlpha = iconAlpha
    icon:SetAlpha(iconAlpha)

    -- Frame level: base from frame (not contentOverlay) + per-indicator level + small priority tiebreaker
    local level = config.frameLevel or (defaults and defaults.indicatorFrameLevel) or 2
    local baseLevel = frame:GetFrameLevel()
    local priorityBoost = math.floor((9 + (priority or 5)) / 4)  -- higher priority = higher frame level
    icon:SetFrameLevel(math.max(0, baseLevel + level + priorityBoost))

    -- Frame strata: per-indicator override, falls back to global default.
    -- Fallback is "INHERIT" (not "HIGH") so that indicators without an explicit
    -- saved strata (e.g. new indicators on old profiles missing indicatorFrameStrata)
    -- correctly inherit the unit frame's strata (MEDIUM) rather than jumping to HIGH.
    local strata = config.frameStrata or (defaults and defaults.indicatorFrameStrata) or "INHERIT"
    if strata ~= "INHERIT" then
        SafeSetFrameStrata(icon, frame, strata)
    else
        icon:SetFrameStrata(frame:GetFrameStrata())
    end

    -- Hide Icon (text-only mode) flag — stored for UpdateIcon to read
    local hideIcon = config.hideIcon; if hideIcon == nil then hideIcon = defaults and defaults.hideIcon end
    icon.dfAD_hideIcon = hideIcon

    -- ========================================
    -- BORDER (unified DF.Border — replaces the icon factory's 1px backdrop)
    --
    -- Stage 5.1c: spec comes from DF.Border:BuildSpec(config, "") so the
    -- canonical Style / Texture / Color / Gradient / Shadow / BlendMode /
    -- Offset keys flow through automatically. The empty prefix is correct:
    -- AD's icon proxy is already type-scoped, so BuildSpec's key("BorderX")
    -- builder ("" .. "BorderX" = "BorderX") lands directly on config.
    --
    -- AD-specific overrides on top of BuildSpec:
    --   * BorderInset semantics — AD's slider means "extend perimeter OUTWARD
    --     by N pixels".  DF.Border's inset is positive-INWARD.  So we invert
    --     to spec.inset = -BorderInset.
    --   * Visible band combines AD's BorderSize (inner thickness, behind the
    --     icon's inset) and BorderInset (outer extension) → spec.size =
    --     BorderSize + BorderInset.  This preserves the pre-5.1a visual
    --     where the "border" straddled the icon's edge.
    --   * spec.enabled is gated by both ShowBorder AND hideIcon — hideIcon
    --     is a text-only mode where the icon TEXTURE is hidden and showing a
    --     border around nothing looks broken.
    --
    -- Legacy fallback (borderEnabled / borderThickness / borderInset) covers
    -- in-memory state that hasn't been migrated yet — e.g. a fresh import
    -- where ApplyImportedProfile doesn't trigger ADDON_LOADED.
    -- ========================================
    local borderEnabled = config.ShowBorder
    if borderEnabled == nil then borderEnabled = config.borderEnabled end
    if borderEnabled == nil then borderEnabled = true end
    local borderThickness = config.BorderSize  or config.borderThickness or 1
    local borderInset     = config.BorderInset or config.borderInset     or 0

    local adBorder = GetOrCreateADIconBorder(icon)
    -- Border geometry: BorderSize is the band THICKNESS on its own — Inset no
    -- longer adds to it (the old `size = thickness + inset` coupling made the
    -- band visibly thicker as you raised Inset).  Inset just repositions the
    -- constant-width band: spec.inset = -BorderInset moves it outward (AD's
    -- "extend outward by N" convention).  At Inset 0 the band sits flush
    -- against the icon edge; positive Inset opens a gap; negative pulls it in.
    -- The cached values feed the spec below; the expiring path recomputes the
    -- same way so the two stay consistent.
    -- Pixel-perfect: snap the thickness up front so the icon's texture inset (which
    -- uses borderThickness) matches the snapped border DF.Border:Apply renders.
    -- Otherwise inset (raw) and border (snapped) differ by a sub-pixel amount —
    -- invisible on live frames but magnified into a visible art/border gap in the
    -- scaled AD preview.
    if fdb and fdb.pixelPerfect and DF.PixelPerfect then
        borderThickness = DF:PixelPerfect(borderThickness)
    end
    adBorder.dfADIconSize  = borderThickness
    adBorder.dfADIconInset = -borderInset

    local spec = DF.Border:BuildSpec(config, "")
    -- The per-aura AD config has no pixelPerfect key of its own, so inherit the
    -- frame's. Without it the border-thickness snap AND the corner pixel-snap in
    -- Border:Apply never run on AD borders, leaving the 1px edges to straddle
    -- physical rows — which drops a side (any side, depending on the icon's x/y).
    spec.pixelPerfect = fdb and fdb.pixelPerfect
    spec.enabled = borderEnabled and not hideIcon
    spec.size    = adBorder.dfADIconSize
    spec.inset   = adBorder.dfADIconInset
    -- BuildSpec doesn't seed a default colour when the static-colour key
    -- (BorderColor) is missing — for migrated configs without an explicit
    -- BorderColor it returns nil colour, which Apply then reads as 0/0/0/1.
    -- Fall back to the pre-5.1a hardcoded translucent black so legacy
    -- profiles render identically until the user picks a colour.
    if not spec.color then
        spec.color = { r = 0, g = 0, b = 0, a = 0.8 }
    end
    DF.Border:Apply(adBorder, spec)

    -- Inset the artwork by the border thickness so the icon stays its original
    -- size and the band frames it instead of sitting on top of the art.
    if icon.texture and not hideIcon then
        icon.texture:ClearAllPoints()
        local texInset = borderEnabled and borderThickness or 0
        icon.texture:SetPoint("TOPLEFT", texInset, -texInset)
        icon.texture:SetPoint("BOTTOMRIGHT", -texInset, texInset)
        icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end

    -- ========================================
    -- STACK COUNT — font/style configuration
    -- ========================================
    local showStacks = config.showStacks
    if showStacks == nil then showStacks = true end
    local stackMin = config.stackMinimum or 2
    icon.stackMinimum = stackMin
    icon.dfAD_showStacks = showStacks

    -- Stack font/style (instance → global defaults → hardcoded)
    local stackFont = config.stackFont or (defaults and defaults.stackFont) or "Fonts\\FRIZQT__.TTF"
    local stackScale = config.stackScale or (defaults and defaults.stackScale) or 1.0
    local stackOutline = config.stackOutline or (defaults and defaults.stackOutline) or "OUTLINE"
    if stackOutline == "NONE" then stackOutline = "" end
    local stackAnchor = config.stackAnchor or (defaults and defaults.stackAnchor) or "BOTTOMRIGHT"
    local stackX = config.stackX; if stackX == nil then stackX = defaults and defaults.stackX end; if stackX == nil then stackX = 0 end
    local stackY = config.stackY; if stackY == nil then stackY = defaults and defaults.stackY end; if stackY == nil then stackY = 0 end

    if icon.count then
        local stackSize = 10 * stackScale
        DF:SafeSetFont(icon.count, stackFont, stackSize, stackOutline)
        icon.count:ClearAllPoints()
        icon.count:SetPoint(stackAnchor, icon, stackAnchor, stackX, stackY)
        local stackColor = config.stackColor or (defaults and defaults.stackColor)
        if stackColor then
            icon.count:SetTextColor(stackColor.r or 1, stackColor.g or 1, stackColor.b or 1, stackColor.a or 1)
        else
            icon.count:SetTextColor(1, 1, 1, 1)
        end
    end

    -- ========================================
    -- DURATION TEXT — font/style/flags configuration
    -- ========================================
    local showDuration = config.showDuration
    if showDuration == nil then showDuration = true end
    local durationFont = config.durationFont or (defaults and defaults.durationFont) or "Fonts\\FRIZQT__.TTF"
    local durationScale = config.durationScale or (defaults and defaults.durationScale) or 1.0
    local durationOutline = config.durationOutline or (defaults and defaults.durationOutline) or "OUTLINE"
    if durationOutline == "NONE" then durationOutline = "" end
    local durationAnchor = config.durationAnchor or (defaults and defaults.durationAnchor) or "CENTER"
    local durationX = config.durationX; if durationX == nil then durationX = defaults and defaults.durationX end; if durationX == nil then durationX = 0 end
    local durationY = config.durationY; if durationY == nil then durationY = defaults and defaults.durationY end; if durationY == nil then durationY = 0 end
    local durationColorByTime = config.durationColorByTime
    if durationColorByTime == nil then
        durationColorByTime = (defaults and defaults.durationColorByTime)
        if durationColorByTime == nil then durationColorByTime = true end
    end

    local durationHideAboveEnabled = config.durationHideAboveEnabled
    if durationHideAboveEnabled == nil then durationHideAboveEnabled = (defaults and defaults.durationHideAboveEnabled) or false end
    local durationHideAboveThreshold = config.durationHideAboveThreshold or (defaults and defaults.durationHideAboveThreshold) or 10

    -- Store duration config on icon for UpdateIcon to read
    icon.showDuration = showDuration
    icon.durationColorByTime = durationColorByTime
    icon.durationAnchor = durationAnchor
    icon.durationX = durationX
    icon.durationY = durationY
    icon.durationHideAboveEnabled = durationHideAboveEnabled
    icon.durationHideAboveThreshold = durationHideAboveThreshold
    icon.dfAD_durationFont = durationFont
    icon.dfAD_durationScale = durationScale
    icon.dfAD_durationOutline = durationOutline
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

    -- Create duration hide wrapper + reparent native text + style + position
    if icon.nativeCooldownText then
        if showDuration then
            -- Reparent to a wrapper frame so we can control visibility via the
            -- wrapper's alpha.  Blizzard's CooldownFrame resets both SetTextColor
            -- alpha AND SetAlpha on its own FontString every frame, so the only
            -- reliable way to hide the text is a parent-level alpha override.
            if not icon.durationHideWrapper and icon.textOverlay then
                icon.durationHideWrapper = CreateFrame("Frame", nil, icon.textOverlay)
                icon.durationHideWrapper:SetAllPoints(icon.textOverlay)
                icon.durationHideWrapper:SetFrameLevel(icon.textOverlay:GetFrameLevel())
                icon.durationHideWrapper:EnableMouse(false)
            end
            if not icon.nativeTextReparented and icon.durationHideWrapper then
                icon.nativeCooldownText:SetParent(icon.durationHideWrapper)
                icon.nativeTextReparented = true
            end
            -- Style
            local durationSize = 10 * durationScale
            DF:SafeSetFont(icon.nativeCooldownText, durationFont, durationSize, durationOutline)
            -- Position
            icon.nativeCooldownText:ClearAllPoints()
            icon.nativeCooldownText:SetPoint(durationAnchor, icon, durationAnchor, durationX, durationY)
            icon.nativeCooldownText:Show()
        else
            icon.nativeCooldownText:Hide()
        end
    end

    -- ========================================
    -- EXPIRING — animation frame creation + config flags
    -- ========================================
    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end
    local expiringPulsate = config.expiringPulsate or false

    -- Lazy-create a wrapper frame so we can animate the border's alpha. The
    -- DF.Border widget is a frame with 4 edge textures — reparenting the whole
    -- widget under the pulse wrapper lets the wrapper's alpha animation
    -- propagate to every edge at once (child frames inherit parent alpha).
    -- Stage 5.1a: was `icon.border` (single texture); now `icon.dfADBorder`.
    if expiringPulsate and icon.dfADBorder then
        if not icon.adBorderPulseFrame then
            icon.adBorderPulseFrame = CreateFrame("Frame", nil, icon)
            icon.adBorderPulseFrame:SetAllPoints(icon)
            icon.adBorderPulseFrame:SetFrameLevel(icon:GetFrameLevel())
            icon.adBorderPulseFrame:EnableMouse(false)
        end
        if not icon.adBorderReparented then
            icon.dfADBorder:SetParent(icon.adBorderPulseFrame)
            icon.adBorderReparented = true
        end
        GetOrCreatePulseAnim(icon.adBorderPulseFrame)
        icon.adBorderPulseFrame.dfAD_expiringPulsate = true
    elseif icon.adBorderPulseFrame then
        icon.adBorderPulseFrame.dfAD_expiringPulsate = false
        if icon.adBorderPulseFrame.dfAD_pulse and icon.adBorderPulseFrame.dfAD_pulse:IsPlaying() then
            icon.adBorderPulseFrame.dfAD_pulse:Stop()
            icon.adBorderPulseFrame:SetAlpha(1)
        end
    end

    -- Whole-alpha pulse: animates the entire icon frame's alpha
    local expiringWholeAlphaPulse = config.expiringWholeAlphaPulse or false
    if expiringWholeAlphaPulse then GetOrCreateWholeAlphaPulse(icon) end
    icon.dfAD_expiringWholeAlphaPulse = expiringWholeAlphaPulse
    if not expiringWholeAlphaPulse and icon.dfAD_wholeAlphaPulse and icon.dfAD_wholeAlphaPulse:IsPlaying() then
        icon.dfAD_wholeAlphaPulse:Stop()
        icon:SetAlpha(1)
    end

    -- Bounce: animates the icon frame position up and down
    local expiringBounce = config.expiringBounce or false
    if expiringBounce then GetOrCreateBounceAnim(icon) end
    icon.dfAD_expiringBounce = expiringBounce
    if not expiringBounce and icon.dfAD_bounceAnim and icon.dfAD_bounceAnim:IsPlaying() then
        icon.dfAD_bounceAnim:Stop()
    end

    -- Store expiring config flags for UpdateIcon to read
    icon.dfAD_expiringFeatureEnabled = config.expiringFeatureEnabled
    icon.dfAD_expiringEnabled = expiringEnabled
    icon.dfAD_expiringColor = config.expiringColor or {r = 1, g = 0.2, b = 0.2}
    icon.dfAD_expiringThreshold = config.expiringThreshold or 30
    icon.dfAD_expiringThresholdMode = config.expiringThresholdMode
    icon.dfAD_expiringTintEnabled = config.expiringTintEnabled
    icon.dfAD_expiringTintColor = config.expiringTintColor
    icon.dfAD_expiringPulsate = expiringPulsate
    -- Stage 5.1d.2: Border-Animation effect to swap into spec.animation when
    -- the aura crosses the threshold.  NONE means no animation override;
    -- the base Border Animation (if any) runs continuously.  Other values
    -- mirror Border Animation's effect set.  Frequency is per-state so
    -- "slow continuous pulse / fast expiring flash" works.
    -- Full per-state animation tunables (parity with base Border Animation).
    -- buildAnim reads these when below threshold so the expiring animation has
    -- its own colour / particles / thickness / offset / etc. independent of
    -- the base animation.
    icon.dfAD_ExpiringAnimationType         = config.ExpiringAnimationType or "NONE"
    icon.dfAD_ExpiringAnimationColor        = config.ExpiringAnimationColor
    icon.dfAD_ExpiringAnimationFrequency    = config.ExpiringAnimationFrequency or 1
    icon.dfAD_ExpiringAnimationParticles    = config.ExpiringAnimationParticles
    icon.dfAD_ExpiringAnimationLength       = config.ExpiringAnimationLength
    icon.dfAD_ExpiringAnimationThickness    = config.ExpiringAnimationThickness
    icon.dfAD_ExpiringAnimationScale        = config.ExpiringAnimationScale
    icon.dfAD_ExpiringAnimationInset        = config.ExpiringAnimationInset
    icon.dfAD_ExpiringAnimationOffsetX      = config.ExpiringAnimationOffsetX
    icon.dfAD_ExpiringAnimationOffsetY      = config.ExpiringAnimationOffsetY
    icon.dfAD_ExpiringAnimationMask         = config.ExpiringAnimationMask
    icon.dfAD_ExpiringAnimationSidesAxis    = config.ExpiringAnimationSidesAxis
    icon.dfAD_ExpiringAnimationCornerLength = config.ExpiringAnimationCornerLength

    -- Stage 5.1d.3: per-state thickness / alpha overrides.  Stored alongside
    -- the base BorderSize / BorderInset so the expiring callback can
    -- recompute the combined size + inset using the AD-specific translation
    -- (spec.size = thickness + inset, spec.inset = -inset).
    -- Also store the base BorderColor so applyState can fall back to it when
    -- thickness/alpha overrides are configured without a colour override.
    -- Base border ENABLED state for the expiring callback (ADApplyExpiringBorderState
    -- reads dfAD_baseBorderEnabled ~= false). Without this it was nil → treated as
    -- enabled, so an expiring border drew even with Show Border off OR in hide-icon
    -- (text-only) mode. Mirror the square path: gate on both ShowBorder and hideIcon
    -- so text-only icons never draw a static OR expiring border.
    icon.dfAD_baseBorderEnabled    = borderEnabled and not hideIcon
    icon.dfAD_baseBorderSize       = borderThickness
    icon.dfAD_baseBorderInset      = borderInset
    icon.dfAD_baseBorderColor      = spec.color
    -- Capture the base PRESENTATION (style + gradient / texture / shadow /
    -- blend) so the expiring callback can preserve it.  Without this, applyState
    -- hand-built a SOLID spec and dropped the gradient / texture entirely — so
    -- any icon with an expiring feature lost its gradient border.  The expiring
    -- callback flattens to SOLID only when the Expiring Colour Override is the
    -- thing actively tinting the border (a single override colour can't be
    -- expressed as a two-stop gradient); otherwise it keeps the base style.
    icon.dfAD_baseBorderStyle      = spec.style
    icon.dfAD_baseBorderGradient   = spec.gradient
    icon.dfAD_baseBorderTexture    = spec.texture
    icon.dfAD_baseBorderShadow     = spec.shadow
    icon.dfAD_baseBorderBlend      = spec.blendMode
    -- Capture the static Border Offset X/Y from the base spec (BuildSpec
    -- reads BorderOffsetX/Y).  applyState builds its Apply spec by hand and
    -- must re-supply these — otherwise the expiring callback's Apply defaults
    -- offset to 0,0 and snaps the border off the user's configured position.
    icon.dfAD_baseBorderOffsetX    = spec.offsetX
    icon.dfAD_baseBorderOffsetY    = spec.offsetY
    icon.dfAD_ExpiringBorderSize   = config.ExpiringBorderSize  or borderThickness
    -- Expiring alpha = the expiring colour's own alpha (in sync with the
    -- Expiring Color picker's alpha bar) — matches base Border Alpha = colour.a.
    -- The render forces the tint colour to a=1 then multiplies by this, so it
    -- ends up as exactly the colour's alpha.
    icon.dfAD_ExpiringBorderAlpha  = (config.expiringColor and (config.expiringColor.a or config.expiringColor[4])) or 1
    -- Capture the base animation spec from the config so the expiring
    -- callback can restore it when the aura returns above threshold.
    -- Mirrors what BuildSpec puts on spec.animation.
    icon.dfAD_baseAnimType         = config.BorderAnimationType or "NONE"
    icon.dfAD_baseAnimColor        = config.BorderAnimationColor
    icon.dfAD_baseAnimFrequency    = config.BorderAnimationFrequency
    icon.dfAD_baseAnimParticles    = config.BorderAnimationParticles
    icon.dfAD_baseAnimLength       = config.BorderAnimationLength
    icon.dfAD_baseAnimThickness    = config.BorderAnimationThickness
    icon.dfAD_baseAnimScale        = config.BorderAnimationScale
    icon.dfAD_baseAnimInset        = config.BorderAnimationInset
    icon.dfAD_baseAnimOffsetX      = config.BorderAnimationOffsetX
    icon.dfAD_baseAnimOffsetY      = config.BorderAnimationOffsetY
    icon.dfAD_baseAnimMask         = config.BorderAnimationMask
    icon.dfAD_baseAnimSidesAxis    = config.BorderAnimationSidesAxis
    icon.dfAD_baseAnimCornerLength = config.BorderAnimationCornerLength

    -- Missing-mode config
    icon.dfAD_missingDesaturate = config.missingDesaturate

    -- Mouse handling: propagate motion/clicks to parent for tooltips and click-casting
    -- Guarded because SetPropagateMouseMotion/Clicks are protected in combat.
    -- Pre-warm ensures this runs outside combat for all configured indicators.
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

    -- Stamp config version so we know when to re-configure
    icon.dfAD_configVersion = DF.adConfigVersion or 0
end

-- ============================================================
-- UpdateIcon: dynamic aura-data-driven properties (called every UNIT_AURA)
-- Sets texture, cooldown, stacks, duration text, expiring registration,
-- and position (position is dynamic because layout groups compute offsets
-- per-event based on which group members are active).
-- ============================================================
function Indicators:UpdateIcon(frame, config, auraData, defaults, auraName, priority)
    local state = EnsureFrameState(frame)
    state.activeIcons[auraName] = true

    local icon = GetOrCreateADIcon(frame, auraName)

    -- Store aura data for tooltip lookups (parent-driven via ShowDFAuraTooltip)
    if auraData then
        if not icon.auraData then
            icon.auraData = { auraInstanceID = nil }
        end
        icon.auraData.auraInstanceID = auraData.auraInstanceID
    end

    -- Position — each aura has its own anchor, no growth
    -- Position is dynamic because layout groups compute offsets per-event
    local anchor = config.anchor or "TOPLEFT"
    local offsetX = config.offsetX or 0
    local offsetY = config.offsetY or 0
    -- Pixel-perfect folded the icon scale into its size (scale -> 1.0); the offset
    -- was authored in the pre-fold scaled space, so re-scale it to match (no-op at
    -- the default scale 1.0). Keeps the icon in the same spot with PP on/off. (#951)
    local us = icon.dfAD_userScale
    if us then offsetX = offsetX * us; offsetY = offsetY * us end
    -- Position is the user's offset only.  We deliberately do NOT shift the
    -- icon by the border inset any more — the band is a constant-width ring
    -- whose Inset slider expands it outward, and tying the icon's position to
    -- Inset made the whole icon slide every time the slider moved.  The icon
    -- stays put; only the ring around it grows out / in.
    -- Only re-anchor when the position actually changed (or the frame lost its
    -- points on recycle).  The AD preview re-runs UpdateIcon every frame; re-
    -- SetPointing each frame fights an active Bounce Translation and drifts the
    -- child-frame overlays (tint / anim glow) up the screen.  Live frames rarely
    -- re-run this, which is why the bug was preview-only.
    if icon:GetNumPoints() == 0 or icon.dfAD_posAnchor ~= anchor
       or icon.dfAD_posX ~= offsetX or icon.dfAD_posY ~= offsetY then
        icon.dfAD_posAnchor, icon.dfAD_posX, icon.dfAD_posY = anchor, offsetX, offsetY
        local b = icon.dfAD_basePos or {}; icon.dfAD_basePos = b
        b.point, b.rel, b.relPoint, b.x, b.y = anchor, frame, anchor, offsetX, offsetY
        -- Pixel-perfect: snap the icon onto the grid so its 1px border doesn't
        -- drop a side (the border SetAllPoints the icon, so it follows). Runs only
        -- on a position change, so it doesn't fight the expiring Bounce translation.
        -- NOTE: if the unit FRAME itself moves, the icon rides along and can drift
        -- <=0.5px off-grid until its next position change.
        AnchorPixelSnapped(icon, anchor, frame, offsetX, offsetY, (DF:GetFrameDB(frame) or {}).pixelPerfect)
    end

    -- Read stored config flags from ConfigureIcon
    local hideIcon = icon.dfAD_hideIcon

    -- Texture
    if not hideIcon then
        if auraData.icon then
            SafeSetTexture(icon, auraData.icon)
        elseif auraData.spellId and not issecretvalue(auraData.spellId) and C_Spell and C_Spell.GetSpellTexture then
            SafeSetTexture(icon, C_Spell.GetSpellTexture(auraData.spellId))
        end
        if icon.texture then icon.texture:Show() end
    else
        if icon.texture then icon.texture:Hide() end
    end

    -- Desaturation for Show When Missing mode
    if icon.texture then
        local desaturate = icon.dfAD_missingDesaturate and auraData.isMissingAura
        icon.texture:SetDesaturated(desaturate and true or false)
    end

    -- Cooldown — uses Duration object pipeline (secret-safe)
    local hideSwipe = config.hideSwipe; if hideSwipe == nil then hideSwipe = defaults and defaults.hideSwipe end
    local hasDuration = HasAuraDuration(auraData, frame.unit)
    if hasDuration then
        SafeSetCooldown(icon.cooldown, auraData, frame.unit)
        -- Retry lazy FontString scan — SetCooldown forces Blizzard to create it
        if EnsureNativeCooldownText(icon, icon.cooldown) then
            ApplyDeferredDurationStyling(icon)
        end
        icon.cooldown:SetDrawSwipe(not hideSwipe and not hideIcon)
        icon.cooldown:Show()
    else
        icon.cooldown:SetDrawSwipe(false)
        icon.cooldown:Hide()
        -- Clear stale countdown text (may persist if reparented to durationHideWrapper)
        if icon.nativeCooldownText then
            icon.nativeCooldownText:SetText("")
            icon.nativeCooldownText:Hide()
        end
    end

    -- ========================================
    -- STACK COUNT — dynamic display
    -- ========================================
    if icon.count then
        icon.count:SetText("")
        icon.count:Hide()
        if icon.dfAD_showStacks then
            local unit = frame.unit
            local auraInstanceID = auraData.auraInstanceID
            local stackMin = icon.stackMinimum
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
    -- DURATION TEXT — dynamic visibility + color
    -- ========================================
    local showDuration = icon.showDuration
    local durationColorByTime = icon.durationColorByTime
    local durationHideAboveEnabled = icon.durationHideAboveEnabled
    local durationHideAboveThreshold = icon.durationHideAboveThreshold

    if icon.nativeCooldownText then
        if showDuration then
            icon.nativeCooldownText:Show()

            -- Compute hide-above alpha (initial evaluation)
            local hideAlpha = 1
            if durationHideAboveEnabled and hasDuration then
                local usedHideAPI = false
                if frame.unit and auraData.auraInstanceID
                   and C_UnitAuras and C_UnitAuras.GetAuraDuration then
                    local dObj = C_UnitAuras.GetAuraDuration(frame.unit, auraData.auraInstanceID)
                    if dObj and dObj.EvaluateRemainingDuration then
                        local hideCurve = BuildDurationHideCurve(durationHideAboveThreshold)
                        if hideCurve then
                            local hideResult = dObj:EvaluateRemainingDuration(hideCurve)
                            if hideResult then
                                hideAlpha = hideResult.a or (hideResult.GetAlpha and hideResult:GetAlpha()) or 1
                            end
                            usedHideAPI = true
                        end
                    end
                end
                if not usedHideAPI then
                    local exp = auraData.expirationTime
                    local dur = auraData.duration
                    if exp and dur and not issecretvalue(exp) and not issecretvalue(dur) and dur > 0 then
                        local remaining = max(0, exp - GetTime())
                        hideAlpha = remaining > durationHideAboveThreshold and 0 or 1
                    end
                end
            end

            -- Apply hide-above alpha on the wrapper frame (immune to Blizzard resets)
            if icon.durationHideWrapper then
                icon.durationHideWrapper:SetAlpha(hideAlpha)
            end

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
                            icon.nativeCooldownText:SetTextColor(result.r, result.g, result.b, 1)
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
                -- Register for ongoing per-tick gradient updates (API path only).
                -- Without this, SetTextColor above would only fire on aura events
                -- and the gradient would freeze between events. The shared ticker
                -- auto-cleans up when the text is hidden.
                if usedAPI and DF.durationColorCurve then
                    RegisterExpiring(icon.nativeCooldownText, {
                        unit = frame.unit,
                        auraInstanceID = auraData.auraInstanceID,
                        duration = auraData.duration,
                        colorCurve = DF.durationColorCurve,
                        applyResult = function(el, result)
                            if result and result.r then
                                el:SetTextColor(result.r, result.g, result.b, 1)
                            end
                        end,
                    })
                else
                    UnregisterExpiring(icon.nativeCooldownText)
                end
            else
                UnregisterExpiring(icon.nativeCooldownText)
                local durationColor = config.durationColor or (defaults and defaults.durationColor)
                if durationColor then
                    icon.nativeCooldownText:SetTextColor(durationColor.r or 1, durationColor.g or 1, durationColor.b or 1, 1)
                else
                    icon.nativeCooldownText:SetTextColor(1, 1, 1, 1)
                end
            end

            -- Register wrapper for ongoing hide-above alpha updates via the shared ticker
            -- Temporarily suppress hideWhenNotExpiring so the wrapper doesn't get it
            -- (wrapper has its own threshold logic, not the expiring threshold)
            local savedHWNE = pendingHideWhenNotExpiring
            pendingHideWhenNotExpiring = false
            if durationHideAboveEnabled and hasDuration and icon.durationHideWrapper then
                local hideCurve = BuildDurationHideCurve(durationHideAboveThreshold)
                if hideCurve then
                    RegisterExpiring(icon.durationHideWrapper, {
                        unit = frame.unit,
                        auraInstanceID = auraData and auraData.auraInstanceID,
                        threshold = durationHideAboveThreshold,
                        thresholdMode = "SECONDS",
                        duration = auraData and auraData.duration,
                        expirationTime = auraData and auraData.expirationTime,
                        colorCurve = hideCurve,
                        applyResult = function(el, result)
                            local a = result.a or (result.GetAlpha and result:GetAlpha()) or 1
                            el:SetAlpha(a)
                        end,
                        applyManual = function(el, isExp)
                            el:SetAlpha(isExp and 1 or 0)
                        end,
                    })
                end
            else
                if icon.durationHideWrapper then
                    UnregisterExpiring(icon.durationHideWrapper)
                    icon.durationHideWrapper:SetAlpha(1)
                end
            end
            pendingHideWhenNotExpiring = savedHWNE  -- Restore for main registration
        else
            icon.nativeCooldownText:Hide()
        end
    end

    -- ========================================
    -- EXPIRING — register with shared ticker (uses stored config flags)
    -- ========================================
    local expiringEnabled = icon.dfAD_expiringEnabled
    local expiringPulsate = icon.dfAD_expiringPulsate
    local expiringWholeAlphaPulse = icon.dfAD_expiringWholeAlphaPulse
    local expiringBounce = icon.dfAD_expiringBounce
    local expiringAnimType = icon.dfAD_ExpiringAnimationType

    -- Register if ANY expiring feature is active (color, pulsate, alpha pulse,
    -- bounce, animation override, OR a Stage 5.1d.3 thickness/alpha override
    -- that differs from the base — otherwise those sliders would silently
    -- do nothing when set alone).
    local hasExpiringAnim = expiringAnimType and expiringAnimType ~= "NONE"
    local hasExpiringThickness = icon.dfAD_ExpiringBorderSize
                                 and icon.dfAD_ExpiringBorderSize ~= icon.dfAD_baseBorderSize
    local hasExpiringAlpha = icon.dfAD_ExpiringBorderAlpha
                             and icon.dfAD_ExpiringBorderAlpha ~= 1
    -- Master enable gates the WHOLE feature: when off, no expiring override
    -- registers regardless of the individual settings.  nil (legacy / unset)
    -- counts as enabled so existing configs are unaffected.
    local masterEnabled = icon.dfAD_expiringFeatureEnabled ~= false
    local anyExpiringFeature = masterEnabled and (expiringEnabled or expiringPulsate
                            or expiringWholeAlphaPulse or expiringBounce
                            or hasExpiringAnim
                            or hasExpiringThickness or hasExpiringAlpha)
    if anyExpiringFeature then
        local ec = icon.dfAD_expiringColor
        local oc = {r = 0, g = 0, b = 0}  -- icon border default = black
        local applyColor = expiringEnabled

        -- Border state-swap (geometry / colour / style / animation) is the
        -- shared ADApplyExpiringBorderState — the SAME helper square and bar use,
        -- so the three placed border indicators never drift (task #46).  The
        -- icon's old inline buildAnim/applyState (with a now-dead ExpiringBorder
        -- Alpha multiplier — the GUI edits the colour's own alpha) were removed.

        RegisterExpiring(icon, {
            unit = frame.unit,
            auraInstanceID = auraData and auraData.auraInstanceID,
            threshold = icon.dfAD_expiringThreshold,
            duration = auraData and auraData.duration,
            expirationTime = auraData and auraData.expirationTime,
            colorCurve = applyColor and BuildExpiringColorCurve(icon.dfAD_expiringThreshold, ec, oc, icon.dfAD_expiringThresholdMode) or nil,
            thresholdMode = icon.dfAD_expiringThresholdMode,
            color = ec, originalColor = oc,
            applyResult = function(el, result, entry)
                -- applyResult only fires when colorCurve is set
                -- (applyColor = true, i.e. user enabled Expiring Color Override).
                local isExp = IsColorExpiring(result, entry.originalColor)
                ADApplyExpiringBorderState(el, isExp, { r = result.r, g = result.g, b = result.b, a = result.a or 1 })
                -- Anim effects: non-secret only (force-stopped on secret auras).
                DriveExpiringEffects(el, result, isExp, el.adBorderPulseFrame)
            end,
            applyManual = function(el, isExp, entry)
                -- Fire applyState whenever ANY border-affecting expiring
                -- feature is configured.  Without this, setting only
                -- Expiring Thickness / Alpha did nothing because applyState
                -- was only reached via colour-override and animation paths.
                if applyColor or hasExpiringAnim or hasExpiringThickness or hasExpiringAlpha then
                    local color
                    if applyColor and isExp then
                        local c = entry.color
                        color = { r = c.r or 1, g = c.g or 0.2, b = c.b or 0.2, a = 1 }
                    else
                        -- No colour override active for this tick — use base
                        -- colour so thickness / alpha overrides still apply
                        -- on the user's chosen border colour.
                        color = icon.dfAD_baseBorderColor or { r = 0, g = 0, b = 0, a = 0.8 }
                    end
                    ADApplyExpiringBorderState(el, isExp, color)
                end
                if el.adBorderPulseFrame then UpdatePulseState(el.adBorderPulseFrame, isExp) end
                UpdateWholeAlphaPulseState(el, isExp)
                UpdateBounceState(el, isExp)
            end,
        })
    else
        UnregisterExpiring(icon)
        if icon.adBorderPulseFrame and icon.adBorderPulseFrame.dfAD_pulse and icon.adBorderPulseFrame.dfAD_pulse:IsPlaying() then
            icon.adBorderPulseFrame.dfAD_pulse:Stop()
            icon.adBorderPulseFrame:SetAlpha(1)
        end
        if icon.dfAD_wholeAlphaPulse and icon.dfAD_wholeAlphaPulse:IsPlaying() then
            icon.dfAD_wholeAlphaPulse:Stop()
            icon:SetAlpha(1)
        end
        if icon.dfAD_bounceAnim and icon.dfAD_bounceAnim:IsPlaying() then
            icon.dfAD_bounceAnim:Stop()
        end
    end

    -- Expiring TINT (independent of the border feature; secret-safe, on the
    -- shared engine).  Self-gates: UpdateTint registers when enabled, else
    -- unregisters.  Hosted on textOverlay so it sits above the icon art.
    SetupExpiringTint(icon.textOverlay or icon, "ARTWORK", icon, frame, auraData)

    icon:Show()
end

function Indicators:HideUnusedIcons(frame, activeMap)
    local map = frame and frame.dfAD_icons
    if not map then return end
    for auraName, icon in pairs(map) do
        if not activeMap[auraName] then
            UnregisterExpiring(icon)
            ClearExpiringTint(icon.textOverlay or icon)
            icon:Hide()
            -- Clear stale aura data (matches bar cleanup pattern)
            if icon.auraData then
                icon.auraData.auraInstanceID = nil
            end
            if icon.cooldown then
                icon.cooldown:Hide()
            end
            if icon.count then
                icon.count:SetText("")
            end
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
    -- Set strata to the unit frame's strata so we don't inherit contentOverlay's
    -- higher strata and show through game panels before Configure runs.
    sq:SetFrameStrata(frame:GetFrameStrata())
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
    sq.count:SetFontObject(GameFontNormal)
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

-- Stage 5.2a: lazily attach a unified DF.Border widget to a square and hide
-- the legacy single-texture `sq.border`.  Mirrors GetOrCreateADIconBorder.
local function GetOrCreateADSquareBorder(sq)
    if sq.dfADBorder then return sq.dfADBorder end
    sq.dfADBorder = DF.Border:New(sq, { frameLevelOffset = 0, layer = "BACKGROUND" })
    if sq.border then sq.border:Hide() end
    return sq.dfADBorder
end

-- ============================================================
-- ConfigureSquare: static config applied once per config change
-- Sets size, scale, alpha, frame level/strata, border, color,
-- stack/duration font & style, expiring animation setup, and
-- mouse propagation.  Mirrors the ConfigureIcon pattern.
-- ============================================================
function Indicators:ConfigureSquare(frame, config, defaults, auraName, priority)
    local sq = GetOrCreateADSquare(frame, auraName)
    local fdb = DF:GetFrameDB(frame)

    -- Size & scale (fall back to global defaults, same as icon)
    local size = config.size or (defaults and defaults.iconSize) or 24
    local scale = config.scale or (defaults and defaults.iconScale) or 1.0
    -- Pixel-perfect: fold scale into size + snap to whole pixels (see ConfigureIcon);
    -- stash the user scale so UpdateSquare can re-scale the layout offset to match.
    if fdb and fdb.pixelPerfect and DF.PixelPerfectSizeAndScaleForBorder then
        sq.dfAD_userScale = scale
        size, scale = DF:PixelPerfectSizeAndScaleForBorder(size, scale, config.BorderSize or 1)
    else
        sq.dfAD_userScale = nil
    end
    sq:SetSize(size, size)
    sq:SetScale(scale)

    -- Alpha
    local sqAlpha = config.alpha or 1.0
    sq.dfBaseAlpha = sqAlpha
    sq:SetAlpha(sqAlpha)

    -- Frame level: base from frame (not contentOverlay) + per-indicator level + small priority tiebreaker
    local level = config.frameLevel or (defaults and defaults.indicatorFrameLevel) or 2
    local baseLevel = frame:GetFrameLevel()
    local priorityBoost = math.floor((9 + (priority or 5)) / 4)  -- higher priority = higher frame level
    sq:SetFrameLevel(math.max(0, baseLevel + level + priorityBoost))

    -- Frame strata: per-indicator override, falls back to global default.
    -- Fallback is "INHERIT" (not "HIGH") — see ConfigureIcon comment.
    local strata = config.frameStrata or (defaults and defaults.indicatorFrameStrata) or "INHERIT"
    if strata ~= "INHERIT" then
        SafeSetFrameStrata(sq, frame, strata)
    else
        sq:SetFrameStrata(frame:GetFrameStrata())
    end

    -- Hide Icon (text-only mode) — stored for UpdateSquare to read
    local hideIcon = config.hideIcon; if hideIcon == nil then hideIcon = defaults and defaults.hideIcon end
    sq.dfAD_hideIcon = hideIcon

    -- ========================================
    -- BORDER (Stage 5.2 — unified DF.Border backend)
    -- Canonical keys (ShowBorder / BorderSize / BorderInset) with legacy
    -- fallback (showBorder / borderThickness / borderInset) for configs that
    -- haven't run the migration shim yet.  Same geometry model as the icon
    -- (Stage 5.1): BorderSize is the band thickness alone; Inset repositions a
    -- constant-width band outward (spec.inset = -BorderInset).  BuildSpec also
    -- carries Style / Texture / Colour / Gradient / Shadow / Blend / Offset /
    -- Animation through, so Apply renders + animates the border in one call.
    -- ========================================
    local borderEnabled = config.ShowBorder
    if borderEnabled == nil then borderEnabled = config.showBorder end
    if borderEnabled == nil then borderEnabled = true end
    local borderThickness = config.BorderSize  or config.borderThickness or 1
    local borderInset     = config.BorderInset or config.borderInset     or 0
    -- Pixel-perfect: snap thickness so the fill inset matches the snapped border
    -- (see ConfigureIcon) — else a sub-pixel art/border gap shows in the preview.
    if fdb and fdb.pixelPerfect and DF.PixelPerfect then
        borderThickness = DF:PixelPerfect(borderThickness)
    end

    local adBorder = GetOrCreateADSquareBorder(sq)
    adBorder.dfADIconSize  = borderThickness
    adBorder.dfADIconInset = -borderInset

    local spec = DF.Border:BuildSpec(config, "")
    -- The per-aura AD config has no pixelPerfect key of its own, so inherit the
    -- frame's. Without it the border-thickness snap AND the corner pixel-snap in
    -- Border:Apply never run on AD borders, leaving the 1px edges to straddle
    -- physical rows — which drops a side (any side, depending on the icon's x/y).
    spec.pixelPerfect = fdb and fdb.pixelPerfect
    spec.enabled = borderEnabled and not hideIcon
    spec.size    = adBorder.dfADIconSize
    spec.inset   = adBorder.dfADIconInset
    -- Legacy square border was opaque black; fall back to it when no explicit
    -- BorderColor (BuildSpec returns nil colour for unmigrated configs).
    if not spec.color then
        spec.color = { r = 0, g = 0, b = 0, a = 1 }
    end
    DF.Border:Apply(adBorder, spec)

    -- Inset the fill texture by the border thickness so the band frames the
    -- square instead of sitting over it (same as the icon).
    if not hideIcon then
        sq.texture:ClearAllPoints()
        local texInset = borderEnabled and borderThickness or 0
        sq.texture:SetPoint("TOPLEFT", texInset, -texInset)
        sq.texture:SetPoint("BOTTOMRIGHT", -texInset, texInset)
    end

    -- Stage 5.2 expiring-border parity: store the base presentation + expiring
    -- overrides so UpdateSquare's expiring callback can recolour / thicken /
    -- animate the BORDER below threshold via ADApplyExpiringBorderState (shared
    -- with the fill's expiring colour).  Mirrors what ConfigureIcon stores.
    sq.dfAD_baseBorderEnabled  = borderEnabled and not hideIcon
    sq.dfAD_baseBorderSize     = borderThickness
    sq.dfAD_baseBorderInset    = borderInset
    sq.dfAD_baseBorderColor    = spec.color
    sq.dfAD_baseBorderStyle    = spec.style
    sq.dfAD_baseBorderGradient = spec.gradient
    sq.dfAD_baseBorderTexture  = spec.texture
    sq.dfAD_baseBorderShadow   = spec.shadow
    sq.dfAD_baseBorderBlend    = spec.blendMode
    sq.dfAD_baseBorderOffsetX  = spec.offsetX
    sq.dfAD_baseBorderOffsetY  = spec.offsetY
    sq.dfAD_baseAnimType         = config.BorderAnimationType or "NONE"
    sq.dfAD_baseAnimColor        = config.BorderAnimationColor
    sq.dfAD_baseAnimFrequency    = config.BorderAnimationFrequency
    sq.dfAD_baseAnimParticles    = config.BorderAnimationParticles
    sq.dfAD_baseAnimLength       = config.BorderAnimationLength
    sq.dfAD_baseAnimThickness    = config.BorderAnimationThickness
    sq.dfAD_baseAnimScale        = config.BorderAnimationScale
    sq.dfAD_baseAnimInset        = config.BorderAnimationInset
    sq.dfAD_baseAnimOffsetX      = config.BorderAnimationOffsetX
    sq.dfAD_baseAnimOffsetY      = config.BorderAnimationOffsetY
    sq.dfAD_baseAnimMask         = config.BorderAnimationMask
    sq.dfAD_baseAnimSidesAxis    = config.BorderAnimationSidesAxis
    sq.dfAD_baseAnimCornerLength = config.BorderAnimationCornerLength
    sq.dfAD_ExpiringBorderColor  = config.ExpiringBorderColor or {r = 1, g = 0.2, b = 0.2, a = 1}
    sq.dfAD_ExpiringBorderSize   = config.ExpiringBorderSize  or borderThickness
    sq.dfAD_ExpiringBorderAlpha  = config.ExpiringBorderAlpha or 1
    sq.dfAD_ExpiringAnimationType         = config.ExpiringAnimationType or "NONE"
    sq.dfAD_ExpiringAnimationColor        = config.ExpiringAnimationColor
    sq.dfAD_ExpiringAnimationFrequency    = config.ExpiringAnimationFrequency or 1
    sq.dfAD_ExpiringAnimationParticles    = config.ExpiringAnimationParticles
    sq.dfAD_ExpiringAnimationLength       = config.ExpiringAnimationLength
    sq.dfAD_ExpiringAnimationThickness    = config.ExpiringAnimationThickness
    sq.dfAD_ExpiringAnimationScale        = config.ExpiringAnimationScale
    sq.dfAD_ExpiringAnimationInset        = config.ExpiringAnimationInset
    sq.dfAD_ExpiringAnimationOffsetX      = config.ExpiringAnimationOffsetX
    sq.dfAD_ExpiringAnimationOffsetY      = config.ExpiringAnimationOffsetY
    sq.dfAD_ExpiringAnimationMask         = config.ExpiringAnimationMask
    sq.dfAD_ExpiringAnimationSidesAxis    = config.ExpiringAnimationSidesAxis
    sq.dfAD_ExpiringAnimationCornerLength = config.ExpiringAnimationCornerLength
    sq.dfAD_expiringFeatureEnabled = config.expiringFeatureEnabled

    -- Color (static config)
    local color = config.color
    if not hideIcon then
        if color then
            sq.texture:SetColorTexture(color[1] or color.r or 1, color[2] or color.g or 1, color[3] or color.b or 1, 1)
        else
            sq.texture:SetColorTexture(1, 1, 1, 1)
        end
        sq.texture:Show()
    else
        sq.texture:Hide()
    end

    -- ========================================
    -- STACK COUNT — font/style configuration
    -- ========================================
    local showStacks = config.showStacks
    if showStacks == nil then showStacks = true end
    local stackMin = config.stackMinimum or 2
    sq.stackMinimum = stackMin
    sq.dfAD_showStacks = showStacks

    local stackFont = config.stackFont or (defaults and defaults.stackFont) or "Fonts\\FRIZQT__.TTF"
    local stackScale = config.stackScale or (defaults and defaults.stackScale) or 1.0
    local stackOutline = config.stackOutline or (defaults and defaults.stackOutline) or "OUTLINE"
    if stackOutline == "NONE" then stackOutline = "" end
    local stackAnchor = config.stackAnchor or (defaults and defaults.stackAnchor) or "BOTTOMRIGHT"
    local stackX = config.stackX; if stackX == nil then stackX = defaults and defaults.stackX end; if stackX == nil then stackX = 0 end
    local stackY = config.stackY; if stackY == nil then stackY = defaults and defaults.stackY end; if stackY == nil then stackY = 0 end

    if sq.count then
        local stackSize = 10 * stackScale
        DF:SafeSetFont(sq.count, stackFont, stackSize, stackOutline)
        sq.count:ClearAllPoints()
        sq.count:SetPoint(stackAnchor, sq, stackAnchor, stackX, stackY)
        local stackColor = config.stackColor or (defaults and defaults.stackColor)
        if stackColor then
            sq.count:SetTextColor(stackColor.r or 1, stackColor.g or 1, stackColor.b or 1, stackColor.a or 1)
        else
            sq.count:SetTextColor(1, 1, 1, 1)
        end
    end

    -- ========================================
    -- DURATION TEXT — font/style/flags configuration
    -- ========================================
    local showDuration = config.showDuration
    if showDuration == nil then showDuration = true end
    local durationFont = config.durationFont or (defaults and defaults.durationFont) or "Fonts\\FRIZQT__.TTF"
    local durationScale = config.durationScale or (defaults and defaults.durationScale) or 1.0
    local durationOutline = config.durationOutline or (defaults and defaults.durationOutline) or "OUTLINE"
    if durationOutline == "NONE" then durationOutline = "" end
    local durationAnchor = config.durationAnchor or (defaults and defaults.durationAnchor) or "CENTER"
    local durationX = config.durationX; if durationX == nil then durationX = defaults and defaults.durationX end; if durationX == nil then durationX = 0 end
    local durationY = config.durationY; if durationY == nil then durationY = defaults and defaults.durationY end; if durationY == nil then durationY = 0 end
    local durationColorByTime = config.durationColorByTime
    if durationColorByTime == nil then
        durationColorByTime = (defaults and defaults.durationColorByTime)
        if durationColorByTime == nil then durationColorByTime = true end
    end

    local durationHideAboveEnabled = config.durationHideAboveEnabled
    if durationHideAboveEnabled == nil then durationHideAboveEnabled = (defaults and defaults.durationHideAboveEnabled) or false end
    local durationHideAboveThreshold = config.durationHideAboveThreshold or (defaults and defaults.durationHideAboveThreshold) or 10

    -- Store duration config on square for UpdateSquare to read
    sq.showDuration = showDuration
    sq.durationColorByTime = durationColorByTime
    sq.durationAnchor = durationAnchor
    sq.durationX = durationX
    sq.durationY = durationY
    sq.durationHideAboveEnabled = durationHideAboveEnabled
    sq.durationHideAboveThreshold = durationHideAboveThreshold
    sq.dfAD_durationFont = durationFont
    sq.dfAD_durationScale = durationScale
    sq.dfAD_durationOutline = durationOutline

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

    -- Create duration hide wrapper + reparent native text + style + position
    if sq.nativeCooldownText then
        if showDuration then
            if not sq.durationHideWrapper and sq.textOverlay then
                sq.durationHideWrapper = CreateFrame("Frame", nil, sq.textOverlay)
                sq.durationHideWrapper:SetAllPoints(sq.textOverlay)
                sq.durationHideWrapper:SetFrameLevel(sq.textOverlay:GetFrameLevel())
                sq.durationHideWrapper:EnableMouse(false)
            end
            if not sq.nativeTextReparented and sq.durationHideWrapper then
                sq.nativeCooldownText:SetParent(sq.durationHideWrapper)
                sq.nativeTextReparented = true
            end
            -- Style
            local durationSize = 10 * durationScale
            DF:SafeSetFont(sq.nativeCooldownText, durationFont, durationSize, durationOutline)
            -- Position
            sq.nativeCooldownText:ClearAllPoints()
            sq.nativeCooldownText:SetPoint(durationAnchor, sq, durationAnchor, durationX, durationY)
            sq.nativeCooldownText:Show()
        else
            sq.nativeCooldownText:Hide()
        end
    end

    -- ========================================
    -- EXPIRING — animation frame creation + config flags
    -- ========================================
    local expiringEnabled = config.expiringEnabled
    if expiringEnabled == nil then expiringEnabled = false end
    local expiringPulsate = config.expiringPulsate or false

    -- Lazy-create a wrapper frame for the fill texture so we can animate its alpha
    if expiringPulsate and sq.texture then
        if not sq.adFillPulseFrame then
            sq.adFillPulseFrame = CreateFrame("Frame", nil, sq)
            sq.adFillPulseFrame:SetAllPoints(sq)
            sq.adFillPulseFrame:SetFrameLevel(sq:GetFrameLevel())
            sq.adFillPulseFrame:EnableMouse(false)
        end
        if not sq.adFillReparented then
            sq.texture:SetParent(sq.adFillPulseFrame)
            sq.adFillReparented = true
        end
        GetOrCreatePulseAnim(sq.adFillPulseFrame)
        sq.adFillPulseFrame.dfAD_expiringPulsate = true
    elseif sq.adFillPulseFrame then
        sq.adFillPulseFrame.dfAD_expiringPulsate = false
        if sq.adFillPulseFrame.dfAD_pulse and sq.adFillPulseFrame.dfAD_pulse:IsPlaying() then
            sq.adFillPulseFrame.dfAD_pulse:Stop()
            sq.adFillPulseFrame:SetAlpha(1)
        end
    end

    -- Whole-alpha pulse: animates the entire square frame's alpha
    local expiringWholeAlphaPulse = config.expiringWholeAlphaPulse or false
    if expiringWholeAlphaPulse then GetOrCreateWholeAlphaPulse(sq) end
    sq.dfAD_expiringWholeAlphaPulse = expiringWholeAlphaPulse
    if not expiringWholeAlphaPulse and sq.dfAD_wholeAlphaPulse and sq.dfAD_wholeAlphaPulse:IsPlaying() then
        sq.dfAD_wholeAlphaPulse:Stop()
        sq:SetAlpha(1)
    end

    -- Bounce: Translation animation directly on the square
    local expiringBounce = config.expiringBounce or false
    if expiringBounce then GetOrCreateBounceAnim(sq) end
    sq.dfAD_expiringBounce = expiringBounce
    if not expiringBounce and sq.dfAD_bounceAnim and sq.dfAD_bounceAnim:IsPlaying() then
        sq.dfAD_bounceAnim:Stop()
    end

    -- Store expiring config flags for UpdateSquare to read
    sq.dfAD_expiringEnabled = expiringEnabled
    sq.dfAD_expiringColor = config.expiringColor or {r = 1, g = 0.2, b = 0.2}
    sq.dfAD_expiringThreshold = config.expiringThreshold or 30
    sq.dfAD_expiringThresholdMode = config.expiringThresholdMode
    sq.dfAD_expiringTintEnabled = config.expiringTintEnabled
    sq.dfAD_expiringTintColor = config.expiringTintColor
    sq.dfAD_expiringPulsate = expiringPulsate

    -- Missing-mode config
    sq.dfAD_missingDesaturate = config.missingDesaturate

    -- Mouse handling: propagate motion/clicks to parent for tooltips and click-casting
    -- Mouse handling: guarded because SetPropagateMouseMotion/Clicks are protected in combat
    if not InCombatLockdown() then
        if sq.SetPropagateMouseMotion then
            sq:SetPropagateMouseMotion(true)
        end
        if sq.SetPropagateMouseClicks then
            sq:SetPropagateMouseClicks(true)
        end
        if sq.SetMouseClickEnabled then
            sq:SetMouseClickEnabled(false)
        end
    end

    -- Stamp config version so we know when to re-configure
    sq.dfAD_configVersion = DF.adConfigVersion or 0
end

-- ============================================================
-- UpdateSquare: dynamic aura-data-driven properties (called every UNIT_AURA)
-- Sets position, cooldown, desaturation, stacks, duration text,
-- expiring registration, and shows the square.  Mirrors UpdateIcon.
-- ============================================================
function Indicators:UpdateSquare(frame, config, auraData, defaults, auraName, priority)
    local state = EnsureFrameState(frame)
    state.activeSquares[auraName] = true

    local sq = GetOrCreateADSquare(frame, auraName)

    -- Store aura data for tooltip lookups (parent-driven via ShowDFAuraTooltip)
    if auraData then
        if not sq.auraData then
            sq.auraData = { auraInstanceID = nil }
        end
        sq.auraData.auraInstanceID = auraData.auraInstanceID
    end

    -- Position — each aura has its own anchor, no growth
    -- Position is dynamic because layout groups compute offsets per-event.
    -- Position is the user's offset only — like the icon (Stage 5.2), we no
    -- longer shift the square by the border inset, so dragging Inset expands
    -- the ring without sliding the whole square.
    local anchor = config.anchor or "TOPLEFT"
    local offsetX = config.offsetX or 0
    local offsetY = config.offsetY or 0
    -- Pixel-perfect folds the square's scale into its size; re-scale the offset to
    -- match (no-op at scale 1.0). See UpdateIcon.
    local us = sq.dfAD_userScale
    if us then offsetX = offsetX * us; offsetY = offsetY * us end
    -- Only re-anchor when the position changed (see UpdateIcon) so the preview's
    -- per-frame refresh doesn't fight an active Bounce Translation.
    if sq:GetNumPoints() == 0 or sq.dfAD_posAnchor ~= anchor
       or sq.dfAD_posX ~= offsetX or sq.dfAD_posY ~= offsetY then
        sq.dfAD_posAnchor, sq.dfAD_posX, sq.dfAD_posY = anchor, offsetX, offsetY
        local b = sq.dfAD_basePos or {}; sq.dfAD_basePos = b
        b.point, b.rel, b.relPoint, b.x, b.y = anchor, frame, anchor, offsetX, offsetY
        AnchorPixelSnapped(sq, anchor, frame, offsetX, offsetY, (DF:GetFrameDB(frame) or {}).pixelPerfect)
    end

    -- Read stored config flags from ConfigureSquare
    local hideIcon = sq.dfAD_hideIcon

    -- Desaturation for Show When Missing mode
    if sq.texture then
        local desaturate = sq.dfAD_missingDesaturate and auraData.isMissingAura
        sq.texture:SetDesaturated(desaturate and true or false)
    end

    -- ========================================
    -- COOLDOWN SWIPE (Duration object pipeline)
    -- ========================================
    local hideSwipe = config.hideSwipe; if hideSwipe == nil then hideSwipe = defaults and defaults.hideSwipe end
    local hasDuration = HasAuraDuration(auraData, frame.unit)
    if sq.cooldown then
        if hasDuration then
            SafeSetCooldown(sq.cooldown, auraData, frame.unit)
            -- Retry lazy FontString scan — SetCooldown forces Blizzard to create it
            if EnsureNativeCooldownText(sq, sq.cooldown) then
                ApplyDeferredDurationStyling(sq)
            end
            sq.cooldown:SetDrawSwipe(not hideSwipe and not hideIcon)
            sq.cooldown:Show()
        else
            sq.cooldown:SetDrawSwipe(false)
            sq.cooldown:Hide()
        end
    end

    -- ========================================
    -- STACK COUNT — dynamic display
    -- ========================================
    if sq.count then
        sq.count:SetText("")
        sq.count:Hide()
        if sq.dfAD_showStacks then
            local unit = frame.unit
            local auraInstanceID = auraData.auraInstanceID
            local stackMin = sq.stackMinimum
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
    -- DURATION TEXT — dynamic visibility + color
    -- ========================================
    local showDuration = sq.showDuration
    local durationColorByTime = sq.durationColorByTime
    local durationHideAboveEnabled = sq.durationHideAboveEnabled
    local durationHideAboveThreshold = sq.durationHideAboveThreshold

    if sq.nativeCooldownText then
        if showDuration then
            sq.nativeCooldownText:Show()

            -- Compute hide-above alpha (initial evaluation)
            local hideAlpha = 1
            if durationHideAboveEnabled and hasDuration then
                local usedHideAPI = false
                if frame.unit and auraData.auraInstanceID
                   and C_UnitAuras and C_UnitAuras.GetAuraDuration then
                    local dObj = C_UnitAuras.GetAuraDuration(frame.unit, auraData.auraInstanceID)
                    if dObj and dObj.EvaluateRemainingDuration then
                        local hideCurve = BuildDurationHideCurve(durationHideAboveThreshold)
                        if hideCurve then
                            local hideResult = dObj:EvaluateRemainingDuration(hideCurve)
                            if hideResult then
                                hideAlpha = hideResult.a or (hideResult.GetAlpha and hideResult:GetAlpha()) or 1
                            end
                            usedHideAPI = true
                        end
                    end
                end
                if not usedHideAPI then
                    local exp = auraData.expirationTime
                    local dur = auraData.duration
                    if exp and dur and not issecretvalue(exp) and not issecretvalue(dur) and dur > 0 then
                        local remaining = max(0, exp - GetTime())
                        hideAlpha = remaining > durationHideAboveThreshold and 0 or 1
                    end
                end
            end

            -- Apply hide-above alpha on the wrapper frame (immune to Blizzard resets)
            if sq.durationHideWrapper then
                sq.durationHideWrapper:SetAlpha(hideAlpha)
            end

            -- Color by remaining time (green → yellow → orange → red)
            if durationColorByTime and hasDuration then
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
                            sq.nativeCooldownText:SetTextColor(result.r, result.g, result.b, 1)
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
                -- Register for ongoing per-tick gradient updates (API path only).
                if usedAPI and DF.durationColorCurve then
                    RegisterExpiring(sq.nativeCooldownText, {
                        unit = frame.unit,
                        auraInstanceID = auraData.auraInstanceID,
                        duration = auraData.duration,
                        colorCurve = DF.durationColorCurve,
                        applyResult = function(el, result)
                            if result and result.r then
                                el:SetTextColor(result.r, result.g, result.b, 1)
                            end
                        end,
                    })
                else
                    UnregisterExpiring(sq.nativeCooldownText)
                end
            else
                UnregisterExpiring(sq.nativeCooldownText)
                local durationColor = config.durationColor or (defaults and defaults.durationColor)
                if durationColor then
                    sq.nativeCooldownText:SetTextColor(durationColor.r or 1, durationColor.g or 1, durationColor.b or 1, 1)
                else
                    sq.nativeCooldownText:SetTextColor(1, 1, 1, 1)
                end
            end

            -- Register wrapper for ongoing hide-above alpha updates via the shared ticker
            -- Temporarily suppress hideWhenNotExpiring so the wrapper doesn't get it
            local savedHWNE2 = pendingHideWhenNotExpiring
            pendingHideWhenNotExpiring = false
            if durationHideAboveEnabled and hasDuration and sq.durationHideWrapper then
                local hideCurve = BuildDurationHideCurve(durationHideAboveThreshold)
                if hideCurve then
                    RegisterExpiring(sq.durationHideWrapper, {
                        unit = frame.unit,
                        auraInstanceID = auraData and auraData.auraInstanceID,
                        threshold = durationHideAboveThreshold,
                        thresholdMode = "SECONDS",
                        duration = auraData and auraData.duration,
                        expirationTime = auraData and auraData.expirationTime,
                        colorCurve = hideCurve,
                        applyResult = function(el, result)
                            local a = result.a or (result.GetAlpha and result:GetAlpha()) or 1
                            el:SetAlpha(a)
                        end,
                        applyManual = function(el, isExp)
                            el:SetAlpha(isExp and 1 or 0)
                        end,
                    })
                end
            else
                if sq.durationHideWrapper then
                    UnregisterExpiring(sq.durationHideWrapper)
                    sq.durationHideWrapper:SetAlpha(1)
                end
            end
            pendingHideWhenNotExpiring = savedHWNE2  -- Restore for main registration
        else
            sq.nativeCooldownText:Hide()
        end
    end

    -- ========================================
    -- EXPIRING — register with shared ticker (uses stored config flags)
    -- ========================================
    local expiringEnabled = sq.dfAD_expiringEnabled
    local expiringPulsate = sq.dfAD_expiringPulsate
    local expiringWholeAlphaPulse = sq.dfAD_expiringWholeAlphaPulse
    local expiringBounce = sq.dfAD_expiringBounce

    -- Stage 5.2 expiring-border parity: the square's expiring colour now tints
    -- the BORDER too (shared "turn red" look), and the border gets its own
    -- thickness / alpha / animation overrides via ADApplyExpiringBorderState.
    -- These flags mirror the icon's so the same trigger conditions apply.
    local expiringAnimType = sq.dfAD_ExpiringAnimationType
    local hasExpiringAnim = expiringAnimType and expiringAnimType ~= "NONE"
    local hasExpiringThickness = sq.dfAD_ExpiringBorderSize
                                 and sq.dfAD_ExpiringBorderSize ~= sq.dfAD_baseBorderSize
    local hasExpiringAlpha = sq.dfAD_ExpiringBorderAlpha
                             and sq.dfAD_ExpiringBorderAlpha ~= 1
    -- Master enable gates the whole feature.
    local masterEnabled = sq.dfAD_expiringFeatureEnabled ~= false
    local anyExpiringFeature = masterEnabled and (expiringEnabled or expiringPulsate
                            or expiringWholeAlphaPulse or expiringBounce
                            or hasExpiringAnim or hasExpiringThickness or hasExpiringAlpha)
    if anyExpiringFeature then
        local ec = sq.dfAD_expiringColor
        local color = config.color
        local oc = {r = color and (color[1] or color.r) or 1, g = color and (color[2] or color.g) or 1, b = color and (color[3] or color.b) or 1}
        local applyColor = expiringEnabled
        -- Border colour SNAPS at the threshold (the fill interpolates via the
        -- curve): the border's OWN expiring colour when below + override on,
        -- else its base colour.  Separate from the fill's expiring colour so
        -- the fill and border can differ on expiring.
        local function borderTintFor(isExp)
            if applyColor and isExp then
                return sq.dfAD_ExpiringBorderColor or ec
            end
            return sq.dfAD_baseBorderColor or { r = 0, g = 0, b = 0, a = 1 }
        end
        local fireBorder = applyColor or hasExpiringAnim or hasExpiringThickness or hasExpiringAlpha
        RegisterExpiring(sq, {
            unit = frame.unit,
            auraInstanceID = auraData and auraData.auraInstanceID,
            threshold = sq.dfAD_expiringThreshold,
            duration = auraData and auraData.duration,
            expirationTime = auraData and auraData.expirationTime,
            colorCurve = applyColor and BuildExpiringColorCurve(sq.dfAD_expiringThreshold, ec, oc, sq.dfAD_expiringThresholdMode) or nil,
            thresholdMode = sq.dfAD_expiringThresholdMode,
            color = ec, originalColor = oc,
            applyResult = function(el, result, entry)
                -- applyResult only fires when colorCurve is set (applyColor true).
                if el.texture then
                    el.texture:SetColorTexture(result.r, result.g, result.b, result.a or 1)
                end
                local oc2 = entry.originalColor
                local isExp = IsColorExpiring(result, oc2)
                if fireBorder then ADApplyExpiringBorderState(el, isExp, borderTintFor(isExp)) end
                -- Anim effects: non-secret only (force-stopped on secret auras).
                DriveExpiringEffects(el, result, isExp, el.adFillPulseFrame)
            end,
            applyManual = function(el, isExp, entry)
                if applyColor and el.texture then
                    if isExp then
                        local c = entry.color
                        el.texture:SetColorTexture(c.r or 1, c.g or 0.2, c.b or 0.2, 1)
                    else
                        local c = entry.originalColor
                        el.texture:SetColorTexture(c.r or 1, c.g or 1, c.b or 1, 1)
                    end
                end
                if fireBorder then ADApplyExpiringBorderState(el, isExp, borderTintFor(isExp)) end
                if el.adFillPulseFrame then
                    UpdatePulseState(el.adFillPulseFrame, isExp)
                end
                UpdateWholeAlphaPulseState(el, isExp)
                UpdateBounceState(el, isExp)
            end,
        })
    else
        UnregisterExpiring(sq)
        if sq.adFillPulseFrame and sq.adFillPulseFrame.dfAD_pulse and sq.adFillPulseFrame.dfAD_pulse:IsPlaying() then
            sq.adFillPulseFrame.dfAD_pulse:Stop()
            sq.adFillPulseFrame:SetAlpha(1)
        end
        if sq.dfAD_wholeAlphaPulse and sq.dfAD_wholeAlphaPulse:IsPlaying() then
            sq.dfAD_wholeAlphaPulse:Stop()
            sq:SetAlpha(1)
        end
        if sq.dfAD_bounceAnim and sq.dfAD_bounceAnim:IsPlaying() then
            sq.dfAD_bounceAnim:Stop()
        end
    end

    -- Expiring TINT (secret-safe, shared engine; self-gating).
    SetupExpiringTint(sq.textOverlay or sq, "ARTWORK", sq, frame, auraData)

    sq:Show()
end

function Indicators:HideUnusedSquares(frame, activeMap)
    local map = frame and frame.dfAD_squares
    if not map then return end
    for auraName, sq in pairs(map) do
        if not activeMap[auraName] then
            UnregisterExpiring(sq)
            ClearExpiringTint(sq.textOverlay or sq)
            sq:Hide()
            -- Clear stale cooldown (matches bar cleanup pattern)
            if sq.cooldown then
                sq.cooldown:Hide()
            end
            if sq.count then
                sq.count:SetText("")
            end
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
-- Bar color curves are now pre-built per-bar in ConfigureBar (stored as bar.dfAD_colorCurve)

local function CreateADBar(frame, auraName)
    local bar = CreateFrame("StatusBar", nil, frame.contentOverlay or frame)
    bar:SetSize(60, 6)
    bar:SetStatusBarTexture(DEFAULT_BAR_TEXTURE)
    bar:SetMinMaxValues(0, 1)
    bar:SetFrameLevel((frame.contentOverlay or frame):GetFrameLevel() + 10)
    -- Set strata to the unit frame's strata so we don't inherit contentOverlay's
    -- higher strata and show through game panels before Configure runs.
    bar:SetFrameStrata(frame:GetFrameStrata())
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
    DF:SafeSetFont(bar.duration, nil, 10, "OUTLINE")
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
    -- Scratch ctx reused each frame for DF.Expiring:EvaluateManualColor (the
    -- preview fill fallback) — avoids per-frame allocation.
    local manualCtx = { base = {} }
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
                        -- Shared colour-by-time ramp (single owner: DF.Expiring)
                        self.duration:SetTextColor(DF.Expiring:GradientColorAt(pct))
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
        -- The curve is built in ConfigureBar and encodes gradient + expiring logic
        if self.dfAD_colorCurve then
            local unit = self.dfAD_unit
            local auraInstanceID = self.dfAD_auraInstanceID
            if unit and auraInstanceID
               and C_UnitAuras and C_UnitAuras.GetAuraDuration then
                local durationObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
                if durationObj then
                    local result
                    if self.dfAD_colorCurveUsesSeconds and durationObj.EvaluateRemainingDuration then
                        result = durationObj:EvaluateRemainingDuration(self.dfAD_colorCurve)
                    elseif durationObj.EvaluateRemainingPercent then
                        result = durationObj:EvaluateRemainingPercent(self.dfAD_colorCurve)
                    end
                    if result and result.r then
                        self:SetStatusBarColor(result.r, result.g, result.b)
                        return
                    end
                end
            end
        end

        -- Manual color fallback for preview — delegate the gradient + expiring
        -- maths to DF.Expiring so it isn't hand-rolled here (live frames use the
        -- secret-safe colour curve above).
        if not self.dfAD_usedTimerDuration then
            local dur = self.dfAD_duration
            local exp = self.dfAD_expirationTime
            if dur and exp and dur > 0 and exp > 0 then
                local remaining = max(0, exp - GetTime())
                local ctx = manualCtx
                ctx.base.r, ctx.base.g, ctx.base.b =
                    self.dfAD_fillR or 1, self.dfAD_fillG or 1, self.dfAD_fillB or 1
                ctx.colorByTime = self.dfAD_barColorByTime
                ctx.expiringEnabled = self.dfAD_expiringEnabled
                ctx.threshold = self.dfAD_expiringThreshold
                ctx.thresholdMode = self.dfAD_expiringThresholdMode
                ctx.expiringColor = self.dfAD_expiringColor
                local r, g, b = DF.Expiring:EvaluateManualColor(ctx, remaining, dur)
                self:SetStatusBarColor(r, g, b, self.dfAD_fillA or 1)
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

-- Stage 5.3a: lazily attach a unified DF.Border widget to a bar and hide the
-- legacy BackdropTemplate `bar.borderFrame`.  Mirrors the icon/square helpers.
local function GetOrCreateADBarBorder(bar)
    if bar.dfADBorder then return bar.dfADBorder end
    bar.dfADBorder = DF.Border:New(bar, { frameLevelOffset = 0, layer = "BACKGROUND" })
    if bar.borderFrame then bar.borderFrame:Hide() end
    return bar.dfADBorder
end

-- ============================================================
-- ConfigureBar: static config applied once per config change
-- Sets size, orientation, texture, colors, color curve, border,
-- frame level/strata, duration font & style, expiring config
-- flags, and mouse propagation.  Mirrors ConfigureIcon/ConfigureSquare.
-- ============================================================
function Indicators:ConfigureBar(frame, config, defaults, auraName, priority)
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
    -- Pixel-perfect: snap the bar's dimensions to whole physical pixels so its 1px
    -- border edges don't straddle two rows. (The bar has no per-indicator scale to
    -- fold, so a plain snap is enough; the position snap is in UpdateBar.)
    local fdb = DF:GetFrameDB(frame)
    if fdb and fdb.pixelPerfect then
        width  = DF:PixelPerfect(width)
        height = DF:PixelPerfect(height)
    end
    bar:SetSize(width, height)

    local barAlpha = config.alpha or 1.0
    bar.dfBaseAlpha = barAlpha
    bar:SetAlpha(barAlpha)

    local orientation = config.orientation or "HORIZONTAL"
    bar:SetOrientation(orientation)

    -- Fill direction
    local reverseFill = config.reverseFill
    if reverseFill ~= nil and bar.SetReverseFill then
        bar:SetReverseFill(reverseFill)
    end

    -- ========================================
    -- TEXTURE
    -- ========================================
    local texture = config.texture or DEFAULT_BAR_TEXTURE
    bar:SetStatusBarTexture(texture)
    if bar.bg then
        bar.bg:SetTexture(texture)
    end

    -- ========================================
    -- COLORS (stored for OnUpdate to read)
    -- ========================================
    local fillColor = config.fillColor
    local fillR = fillColor and (fillColor[1] or fillColor.r) or 1
    local fillG = fillColor and (fillColor[2] or fillColor.g) or 1
    local fillB = fillColor and (fillColor[3] or fillColor.b) or 1
    local fillA = fillColor and (fillColor[4] or fillColor.a) or 1

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
    bar.dfAD_expiringThresholdMode = config.expiringThresholdMode
    bar.dfAD_expiringTintEnabled = config.expiringTintEnabled
    bar.dfAD_expiringTintColor = config.expiringTintColor
    bar.dfAD_expiringColor = config.expiringColor or { r = 1, g = 0.2, b = 0.2 }

    -- Store base fill color for OnUpdate fallback
    bar.dfAD_fillR = fillR
    bar.dfAD_fillG = fillG
    bar.dfAD_fillB = fillB
    bar.dfAD_fillA = fillA

    -- Hide Icon flag (bars don't have icons but stored for consistency)
    local hideIcon = config.hideIcon; if hideIcon == nil then hideIcon = defaults and defaults.hideIcon end
    bar.dfAD_hideIcon = hideIcon

    -- ========================================
    -- COLOR CURVE (pre-built for OnUpdate)
    -- Single curve handles gradient + expiring without secret comparisons.
    -- OnUpdate evaluates: durationObj:EvaluateRemainingPercent/Duration(curve) → SetStatusBarColor
    -- ========================================
    local useSeconds = config.expiringThresholdMode == "SECONDS"
    local needsColorCurve = barColorByTime or expiringEnabled
    if needsColorCurve and C_CurveUtil and C_CurveUtil.CreateColorCurve then
        local curve = C_CurveUtil.CreateColorCurve()
        local expiringColor = config.expiringColor or { r = 1, g = 0.2, b = 0.2 }
        local expiringThresholdRaw = config.expiringThreshold or 30
        -- For curve building, convert to the appropriate scale
        local expiringThreshold = useSeconds and expiringThresholdRaw or (expiringThresholdRaw / 100)

        if expiringEnabled and barColorByTime then
            -- Composite: when using seconds mode with gradient, fall back to
            -- percentage curve (gradient is inherently percentage-based).
            -- The manual fallback path handles seconds expiring separately.
            local pctThreshold = useSeconds and 0.3 or expiringThreshold
            curve:SetType(Enum.LuaCurveType.Linear)
            local ecR = expiringColor.r or 1
            local ecG = expiringColor.g or 0.2
            local ecB = expiringColor.b or 0.2
            -- Expiring zone (flat color up to threshold)
            curve:AddPoint(0, CreateColor(ecR, ecG, ecB, 1))
            if pctThreshold > 0.002 then
                curve:AddPoint(pctThreshold - 0.001, CreateColor(ecR, ecG, ecB, 1))
            end
            -- Compute gradient color at threshold for smooth transition
            local gR, gG, gB
            if pctThreshold < 0.3 then
                local t = pctThreshold / 0.3
                gR, gG, gB = 1, 0.5 * t, 0
            elseif pctThreshold < 0.5 then
                local t = (pctThreshold - 0.3) / 0.2
                gR, gG, gB = 1, 0.5 + 0.5 * t, 0
            else
                local t = (pctThreshold - 0.5) / 0.5
                gR, gG, gB = 1 - t, 1, 0
            end
            curve:AddPoint(pctThreshold, CreateColor(gR, gG, gB, 1))
            -- Add gradient key points above threshold
            if pctThreshold < 0.3 then
                curve:AddPoint(0.3, CreateColor(1, 0.5, 0, 1))
            end
            if pctThreshold < 0.5 then
                curve:AddPoint(0.5, CreateColor(1, 1, 0, 1))
            end
            curve:AddPoint(1, CreateColor(0, 1, 0, 1))
            -- Composite always uses percent evaluation (gradient needs it)
            bar.dfAD_colorCurveUsesSeconds = false

        elseif expiringEnabled then
            -- Expiring only: step from expiring color to fill color
            curve:SetType(Enum.LuaCurveType.Step)
            local ecR = expiringColor.r or 1
            local ecG = expiringColor.g or 0.2
            local ecB = expiringColor.b or 0.2
            curve:AddPoint(0, CreateColor(ecR, ecG, ecB, 1))
            if useSeconds then
                curve:AddPoint(expiringThreshold, CreateColor(fillR, fillG, fillB, 1))
                curve:AddPoint(600, CreateColor(fillR, fillG, fillB, 1))  -- 10min cap
            else
                curve:AddPoint(expiringThreshold, CreateColor(fillR, fillG, fillB, 1))
                curve:AddPoint(1, CreateColor(fillR, fillG, fillB, 1))
            end
            bar.dfAD_colorCurveUsesSeconds = useSeconds

        elseif barColorByTime then
            -- Gradient only: red → orange → yellow → green (always percent)
            curve:SetType(Enum.LuaCurveType.Linear)
            curve:AddPoint(0, CreateColor(1, 0, 0, 1))
            curve:AddPoint(0.3, CreateColor(1, 0.5, 0, 1))
            curve:AddPoint(0.5, CreateColor(1, 1, 0, 1))
            curve:AddPoint(1, CreateColor(0, 1, 0, 1))
            bar.dfAD_colorCurveUsesSeconds = false
        end

        bar.dfAD_colorCurve = curve
    else
        bar.dfAD_colorCurve = nil
    end

    -- ========================================
    -- BORDER (Stage 5.3 — unified DF.Border backend)
    -- Canonical keys (ShowBorder / BorderSize / BorderInset) with legacy
    -- fallback (showBorder / borderThickness / borderColor).  The bar's border
    -- sits OUTSIDE the StatusBar (the fill is never inset), so the band is
    -- placed fully outward: spec.size = thickness, spec.inset = -(inset +
    -- thickness) puts the ring's inner edge at the bar edge (Inset 0 = flush,
    -- as before) and grows outward.  BuildSpec carries Style / Texture / Colour
    -- / Gradient / Shadow / Blend / Animation through, so Apply renders +
    -- animates in one call.
    -- ========================================
    local borderEnabled = config.ShowBorder
    if borderEnabled == nil then borderEnabled = config.showBorder end
    if borderEnabled == nil then borderEnabled = true end
    local borderThickness = config.BorderSize  or config.borderThickness or 1
    local borderInset     = config.BorderInset or config.borderInset     or 0
    -- Pixel-perfect: snap thickness so spec.size and spec.inset (which both use it)
    -- match the snapped border the render produces (consistency, see ConfigureIcon).
    if fdb and fdb.pixelPerfect and DF.PixelPerfect then
        borderThickness = DF:PixelPerfect(borderThickness)
    end

    local adBorder = GetOrCreateADBarBorder(bar)
    local spec = DF.Border:BuildSpec(config, "")
    spec.pixelPerfect = fdb and fdb.pixelPerfect  -- AD config has no key of its own; inherit the frame's
    spec.enabled = borderEnabled
    spec.size    = borderThickness
    spec.inset   = -(borderInset + borderThickness)
    -- Legacy bar border was opaque black; fall back to it when no explicit
    -- BorderColor (BuildSpec returns nil colour for unmigrated configs).
    if not spec.color then
        spec.color = { r = 0, g = 0, b = 0, a = 1 }
    end
    DF.Border:Apply(adBorder, spec)

    -- Frame level: base from frame (not contentOverlay) + per-indicator level + small priority tiebreaker
    local level = config.frameLevel or (defaults and defaults.indicatorFrameLevel) or 2
    local baseLevel = frame:GetFrameLevel()
    local priorityBoost = math.floor((9 + (priority or 5)) / 4)  -- higher priority = higher frame level
    bar:SetFrameLevel(math.max(0, baseLevel + level + priorityBoost))

    -- Frame strata: per-indicator override, falls back to global default.
    -- Fallback is "INHERIT" (not "HIGH") — see ConfigureIcon comment.
    local strata = config.frameStrata or (defaults and defaults.indicatorFrameStrata) or "INHERIT"
    if strata ~= "INHERIT" then
        SafeSetFrameStrata(bar, frame, strata)
    else
        bar:SetFrameStrata(frame:GetFrameStrata())
    end

    -- ========================================
    -- DURATION TEXT — font/style/flags configuration
    -- ========================================
    local showDuration = config.showDuration
    if showDuration == nil then showDuration = false end
    local durationFont = config.durationFont or (defaults and defaults.durationFont) or "Fonts\\FRIZQT__.TTF"
    local durationScale = config.durationScale or (defaults and defaults.durationScale) or 1.0
    local durationOutline = config.durationOutline or (defaults and defaults.durationOutline) or "OUTLINE"
    if durationOutline == "NONE" then durationOutline = "" end
    local durationAnchor = config.durationAnchor or (defaults and defaults.durationAnchor) or "CENTER"
    local durationX = config.durationX; if durationX == nil then durationX = defaults and defaults.durationX end; if durationX == nil then durationX = 0 end
    local durationY = config.durationY; if durationY == nil then durationY = defaults and defaults.durationY end; if durationY == nil then durationY = 0 end
    local durationColorByTime = config.durationColorByTime
    if durationColorByTime == nil then
        durationColorByTime = (defaults and defaults.durationColorByTime)
        if durationColorByTime == nil then durationColorByTime = true end
    end

    local durationHideAboveEnabled = config.durationHideAboveEnabled
    if durationHideAboveEnabled == nil then durationHideAboveEnabled = (defaults and defaults.durationHideAboveEnabled) or false end
    local durationHideAboveThreshold = config.durationHideAboveThreshold or (defaults and defaults.durationHideAboveThreshold) or 10

    -- Store duration config on bar for UpdateBar and OnUpdate to read
    bar.dfAD_showDuration = showDuration
    bar.dfAD_durationColorByTime = durationColorByTime
    bar.dfAD_durationAnchor = durationAnchor
    bar.dfAD_durationX = durationX
    bar.dfAD_durationY = durationY
    bar.dfAD_durationHideAboveEnabled = durationHideAboveEnabled
    bar.dfAD_durationHideAboveThreshold = durationHideAboveThreshold
    bar.dfAD_durationFont = durationFont
    bar.dfAD_durationScale = durationScale
    bar.dfAD_durationOutline = durationOutline

    -- Find native cooldown text if not yet cached
    if not bar.nativeCooldownText and bar.durationCooldown then
        local regions = { bar.durationCooldown:GetRegions() }
        for _, region in pairs(regions) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                bar.nativeCooldownText = region
                bar.nativeTextReparented = false
                break
            end
        end
    end

    -- Create duration hide wrapper + reparent native text + style + position
    if bar.nativeCooldownText then
        if showDuration then
            if not bar.durationHideWrapper and bar.textOverlay then
                bar.durationHideWrapper = CreateFrame("Frame", nil, bar.textOverlay)
                bar.durationHideWrapper:SetAllPoints(bar.textOverlay)
                bar.durationHideWrapper:SetFrameLevel(bar.textOverlay:GetFrameLevel())
                bar.durationHideWrapper:EnableMouse(false)
            end
            if not bar.nativeTextReparented and bar.durationHideWrapper then
                bar.nativeCooldownText:SetParent(bar.durationHideWrapper)
                bar.nativeTextReparented = true
            end
            local durationSize = 10 * durationScale
            DF:SafeSetFont(bar.nativeCooldownText, durationFont, durationSize, durationOutline)
            bar.nativeCooldownText:ClearAllPoints()
            bar.nativeCooldownText:SetPoint(durationAnchor, bar, durationAnchor, durationX, durationY)
            bar.nativeCooldownText:Show()
        else
            bar.nativeCooldownText:Hide()
        end
    end

    -- Style manual duration FontString (preview path)
    if bar.duration then
        local durationSize = 10 * durationScale
        DF:SafeSetFont(bar.duration, durationFont, durationSize, durationOutline)
        bar.duration:ClearAllPoints()
        bar.duration:SetPoint(durationAnchor, bar, durationAnchor, durationX, durationY)
    end

    -- ========================================
    -- EXPIRING — animation setup + config flags
    -- ========================================
    -- Whole-alpha pulse: animates the entire bar frame's alpha
    local expiringWholeAlphaPulse = config.expiringWholeAlphaPulse or false
    if expiringWholeAlphaPulse then GetOrCreateWholeAlphaPulse(bar) end
    bar.dfAD_expiringWholeAlphaPulse = expiringWholeAlphaPulse
    if not expiringWholeAlphaPulse and bar.dfAD_wholeAlphaPulse and bar.dfAD_wholeAlphaPulse:IsPlaying() then
        bar.dfAD_wholeAlphaPulse:Stop()
        bar:SetAlpha(1)
    end

    -- Bounce: Translation animation directly on the bar
    local expiringBounce = config.expiringBounce or false
    if expiringBounce then GetOrCreateBounceAnim(bar) end
    bar.dfAD_expiringBounce = expiringBounce
    if not expiringBounce and bar.dfAD_bounceAnim and bar.dfAD_bounceAnim:IsPlaying() then
        bar.dfAD_bounceAnim:Stop()
    end

    -- Mouse handling: propagate motion/clicks to parent for tooltips and click-casting
    -- Mouse handling: guarded because SetPropagateMouseMotion/Clicks are protected in combat
    if not InCombatLockdown() then
        if bar.SetPropagateMouseMotion then
            bar:SetPropagateMouseMotion(true)
        end
        if bar.SetPropagateMouseClicks then
            bar:SetPropagateMouseClicks(true)
        end
        if bar.SetMouseClickEnabled then
            bar:SetMouseClickEnabled(false)
        end
    end

    -- Stamp config version so we know when to re-configure
    bar.dfAD_configVersion = DF.adConfigVersion or 0
end

-- ============================================================
-- UpdateBar: dynamic aura-data-driven properties (called every UNIT_AURA)
-- Sets position, fill, initial color, duration text + cooldown,
-- hide-above alpha, and shows the bar.  Mirrors UpdateIcon/UpdateSquare.
-- ============================================================
function Indicators:UpdateBar(frame, config, auraData, defaults, auraName, priority)
    local state = EnsureFrameState(frame)
    state.activeBars[auraName] = true

    local bar = GetOrCreateADBar(frame, auraName)

    -- Store unit + auraInstanceID for API-based color evaluation in OnUpdate
    bar.dfAD_unit = frame.unit
    bar.dfAD_auraInstanceID = auraData.auraInstanceID

    -- ========================================
    -- POSITION (dynamic because layout groups compute offsets per-event)
    -- ========================================
    local anchor = config.anchor or "BOTTOM"
    local offsetX = config.offsetX or 0
    local offsetY = config.offsetY or 0
    -- Position is the user's offset only — like the icon/square (Stage 5.3),
    -- we no longer shift the bar by the border thickness, so changing the
    -- border doesn't slide the whole bar.
    -- Only re-anchor when the position changed (see UpdateIcon) so the preview's
    -- per-frame refresh doesn't fight an active Bounce Translation.
    if bar:GetNumPoints() == 0 or bar.dfAD_posAnchor ~= anchor
       or bar.dfAD_posX ~= offsetX or bar.dfAD_posY ~= offsetY then
        bar.dfAD_posAnchor, bar.dfAD_posX, bar.dfAD_posY = anchor, offsetX, offsetY
        local b = bar.dfAD_basePos or {}; bar.dfAD_basePos = b
        b.point, b.rel, b.relPoint, b.x, b.y = anchor, frame, anchor, offsetX, offsetY
        AnchorPixelSnapped(bar, anchor, frame, offsetX, offsetY, (DF:GetFrameDB(frame) or {}).pixelPerfect)
    end

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
    -- INITIAL BAR COLOR
    -- When a color curve exists, evaluate it immediately to avoid flicker
    -- (UpdateBar runs on every aura update; without this, the fill color
    -- would flash briefly until the throttled OnUpdate re-evaluates the curve)
    -- ========================================
    local fillR = bar.dfAD_fillR or 1
    local fillG = bar.dfAD_fillG or 1
    local fillB = bar.dfAD_fillB or 1
    local fillA = bar.dfAD_fillA or 1

    if bar.dfAD_colorCurve and frame.unit and auraData.auraInstanceID
       and C_UnitAuras and C_UnitAuras.GetAuraDuration then
        local durationObj = C_UnitAuras.GetAuraDuration(frame.unit, auraData.auraInstanceID)
        if durationObj then
            local result
            if bar.dfAD_colorCurveUsesSeconds and durationObj.EvaluateRemainingDuration then
                result = durationObj:EvaluateRemainingDuration(bar.dfAD_colorCurve)
            elseif durationObj.EvaluateRemainingPercent then
                result = durationObj:EvaluateRemainingPercent(bar.dfAD_colorCurve)
            end
            if result and result.r then
                bar:SetStatusBarColor(result.r, result.g, result.b)
            else
                bar:SetStatusBarColor(fillR, fillG, fillB, fillA)
            end
        else
            bar:SetStatusBarColor(fillR, fillG, fillB, fillA)
        end
    else
        bar:SetStatusBarColor(fillR, fillG, fillB, fillA)
    end

    -- ========================================
    -- DURATION TEXT
    -- ========================================
    local showDuration = bar.dfAD_showDuration
    local durationColorByTime = bar.dfAD_durationColorByTime
    local durationHideAboveEnabled = bar.dfAD_durationHideAboveEnabled
    local durationHideAboveThreshold = bar.dfAD_durationHideAboveThreshold
    local durationAnchor = bar.dfAD_durationAnchor or "CENTER"
    local durationX = bar.dfAD_durationX or 0
    local durationY = bar.dfAD_durationY or 0

    if showDuration and hasDuration then
        local durationSize = 10 * (bar.dfAD_durationScale or 1.0)
        local durationFont = bar.dfAD_durationFont or "Fonts\\FRIZQT__.TTF"

        -- Compute hide-above alpha (initial evaluation)
        local hideAlpha = 1
        if durationHideAboveEnabled then
            local usedHideAPI = false
            if frame.unit and auraData.auraInstanceID
               and C_UnitAuras and C_UnitAuras.GetAuraDuration then
                local dObj = C_UnitAuras.GetAuraDuration(frame.unit, auraData.auraInstanceID)
                if dObj and dObj.EvaluateRemainingDuration then
                    local hideCurve = BuildDurationHideCurve(durationHideAboveThreshold)
                    if hideCurve then
                        local hideResult = dObj:EvaluateRemainingDuration(hideCurve)
                        if hideResult then
                            hideAlpha = hideResult.a or (hideResult.GetAlpha and hideResult:GetAlpha()) or 1
                        end
                        usedHideAPI = true
                    end
                end
            end
            if not usedHideAPI then
                local exp = auraData.expirationTime
                local dur = auraData.duration
                if exp and dur and not issecretvalue(exp) and not issecretvalue(dur) and dur > 0 then
                    local remaining = max(0, exp - GetTime())
                    hideAlpha = remaining > durationHideAboveThreshold and 0 or 1
                end
            end
        end

        if usedTimerDuration and bar.durationCooldown then
            -- COMBAT PATH: Use native cooldown countdown text (secret-safe)
            -- The cooldown frame handles formatting and updating automatically
            bar.duration:Hide()

            -- Set the cooldown with the same Duration object
            local durationObj = C_UnitAuras.GetAuraDuration(frame.unit, auraData.auraInstanceID)
            if durationObj then
                bar.durationCooldown:SetCooldownFromDurationObject(durationObj)
                bar.durationCooldown:Show()
                -- Retry lazy FontString scan — SetCooldownFromDurationObject forces creation
                if EnsureNativeCooldownText(bar, bar.durationCooldown) then
                    ApplyDeferredDurationStyling(bar)
                end
            end

            -- Style and position the native countdown text
            if bar.nativeCooldownText then
                -- Apply hide-above alpha on the wrapper frame (immune to Blizzard resets)
                if bar.durationHideWrapper then
                    bar.durationHideWrapper:SetAlpha(hideAlpha)
                end

                if not durationColorByTime then
                    UnregisterExpiring(bar.nativeCooldownText)
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
                        bar.nativeCooldownText:SetTextColor(result.r, result.g, result.b, 1)
                    end
                    -- Register for ongoing per-tick gradient updates so the colour
                    -- transitions live as the buff ticks down, not just on aura events.
                    if frame.unit and auraData and auraData.auraInstanceID then
                        RegisterExpiring(bar.nativeCooldownText, {
                            unit = frame.unit,
                            auraInstanceID = auraData.auraInstanceID,
                            duration = auraData.duration,
                            colorCurve = DF.durationColorCurve,
                            applyResult = function(el, result)
                                if result and result.r then
                                    el:SetTextColor(result.r, result.g, result.b, 1)
                                end
                            end,
                        })
                    end
                else
                    UnregisterExpiring(bar.nativeCooldownText)
                end

                -- Register wrapper for ongoing hide-above alpha updates
                -- Temporarily suppress hideWhenNotExpiring so the wrapper doesn't get it
                local savedHWNE = pendingHideWhenNotExpiring
                pendingHideWhenNotExpiring = false
                if durationHideAboveEnabled and bar.durationHideWrapper then
                    local hideCurve = BuildDurationHideCurve(durationHideAboveThreshold)
                    if hideCurve then
                        RegisterExpiring(bar.durationHideWrapper, {
                            unit = frame.unit,
                            auraInstanceID = auraData and auraData.auraInstanceID,
                            threshold = durationHideAboveThreshold,
                            thresholdMode = "SECONDS",
                            duration = auraData and auraData.duration,
                            expirationTime = auraData and auraData.expirationTime,
                            colorCurve = hideCurve,
                            applyResult = function(el, result)
                                local a = result.a or (result.GetAlpha and result:GetAlpha()) or 1
                                el:SetAlpha(a)
                            end,
                            applyManual = function(el, isExp)
                                el:SetAlpha(isExp and 1 or 0)
                            end,
                        })
                    end
                else
                    if bar.durationHideWrapper then
                        UnregisterExpiring(bar.durationHideWrapper)
                        bar.durationHideWrapper:SetAlpha(1)
                    end
                end
                pendingHideWhenNotExpiring = savedHWNE  -- Restore for main registration
            end

        elseif bar.duration then
            -- PREVIEW PATH: Manual FontString (non-secret values)
            if bar.durationCooldown then
                bar.durationCooldown:Hide()
            end
            if bar.nativeCooldownText then
                bar.nativeCooldownText:Hide()
            end
            if bar.durationHideWrapper then
                UnregisterExpiring(bar.durationHideWrapper)
                bar.durationHideWrapper:SetAlpha(1)
            end

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

            bar.duration:SetAlpha(hideAlpha)
            bar.duration:SetTextColor(1, 1, 1, 1)
            bar.duration:Show()
        end
    else
        if bar.duration then bar.duration:Hide() end
        if bar.durationCooldown then bar.durationCooldown:Hide() end
        if bar.nativeCooldownText then
            bar.nativeCooldownText:Hide()
        end
        if bar.durationHideWrapper then
            UnregisterExpiring(bar.durationHideWrapper)
            bar.durationHideWrapper:SetAlpha(1)
        end
    end

    -- Expiring TINT (secret-safe, shared engine; self-gating).  Hosted on the
    -- bar itself at OVERLAY so it sits above the fill.
    SetupExpiringTint(bar, "OVERLAY", bar, frame, auraData)

    bar:Show()
end

function Indicators:HideUnusedBars(frame, activeMap)
    local map = frame and frame.dfAD_bars
    if not map then return end
    for auraName, bar in pairs(map) do
        if not activeMap[auraName] then
            ClearExpiringTint(bar)
            bar:Hide()
            -- Clear stale metadata so OnUpdate doesn't run with expired
            -- auraInstanceIDs causing stuck/corrupted bar state (#406)
            bar:SetValue(0)
            bar.dfAD_auraInstanceID = nil
            bar.dfAD_unit = nil
            bar.dfAD_duration = 0
            bar.dfAD_expirationTime = 0
            -- dfAD_colorCurve intentionally NOT cleared — it is static config set by
            -- ConfigureBar and reused across aura applications. Clearing it here caused
            -- colour-by-time and expiring colour overrides to stop working after the
            -- first cast because ConfigureBar doesn't re-run when adConfigVersion is
            -- unchanged. dfAD_auraInstanceID = nil is sufficient to guard the OnUpdate.
            bar.dfAD_usedTimerDuration = false
            if bar.durationCooldown then
                bar.durationCooldown:Hide()
            end
        end
    end
end
