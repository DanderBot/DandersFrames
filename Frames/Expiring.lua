local addonName, DF = ...

-- ============================================================
-- DF.Expiring — SHARED EXPIRING ENGINE
--
-- One registry + one ~3 FPS ticker that drives ANY element (border, text,
-- frame alpha, …) toward an "expiring" state below a duration threshold.  The
-- engine is element-agnostic: each consumer supplies applyResult / applyManual
-- callbacks and (optionally) a Step colour curve, and the engine evaluates the
-- secret-safe Duration API on the consumer's behalf.
--
-- This was originally AuraDesigner/Indicators.lua-local (RegisterExpiring /
-- BuildExpiringColorCurve / the OnUpdate ticker).  Lifted here so AD's
-- indicators AND the standard buff expiring border share ONE engine instead of
-- each hand-rolling a ticker.  The engine reads ONLY fields on the entryData
-- table passed to Register — no hidden module state — so consumers stay
-- decoupled (AD's "Show When Missing" pending-flag mechanism lives in
-- Indicators.lua and injects its fields into entryData before delegating here).
--
-- entryData contract:
--   unit, auraInstanceID         secret-safe duration source (real units)
--   duration, expirationTime     preview/mock fallback (non-secret)
--   threshold, thresholdMode     "PERCENT" (0-100) | "SECONDS" (1-60)
--   colorCurve                   optional Step curve → applyResult fires (API path)
--   applyResult(el, result, e)   fires when colorCurve set; result is a ColorMixin
--                                (result.r/g/b may be SECRET — use IsColorExpiring)
--   applyManual(el, isExp, e)    fires on the preview path / when no colorCurve;
--                                isExp is a plain bool
--   hideWhenNotExpiring          opt: drive element visibility by expiring state
--   useShowHide                  opt: Show/Hide instead of SetAlpha
--   visibleAlpha, hiddenAlpha    opt: alphas for the SetAlpha visibility path
-- ============================================================

local pairs = pairs
local GetTime = GetTime
local max = math.max
local issecretvalue = issecretvalue or function() return false end

DF.Expiring = DF.Expiring or {}
local Expiring = DF.Expiring

local expiringRegistry = {}

-- Check if an interpolated colour result differs from the original colour.
-- result.r/g/b may be secret (tainted) values from EvaluateRemainingDuration/
-- Percent; arithmetic on secret values throws.  If tainted, the engine IS
-- interpolating → expiring.
function Expiring.IsColorExpiring(result, oc)
    if issecretvalue(result.r) then return true end
    return (math.abs(result.r - oc.r) > 0.01
         or math.abs(result.g - oc.g) > 0.01
         or math.abs(result.b - oc.b) > 0.01)
end

-- Build a Step colour curve encoding two states:
--   Below threshold → expiringColor
--   At/above threshold → originalColor
-- thresholdMode: nil/"PERCENT" = percentage (0-100), "SECONDS" = seconds (1-60)
function Expiring:BuildColorCurve(threshold, expiringColor, originalColor, thresholdMode)
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
    if thresholdMode == "SECONDS" then
        -- Curve points in seconds for EvaluateRemainingDuration
        curve:AddPoint(threshold, CreateColor(ocR, ocG, ocB, 1))
        curve:AddPoint(600, CreateColor(ocR, ocG, ocB, 1))  -- 10min cap
    else
        -- Curve points as decimal percentage for EvaluateRemainingPercent
        curve:AddPoint(threshold / 100, CreateColor(ocR, ocG, ocB, 1))
        curve:AddPoint(1, CreateColor(ocR, ocG, ocB, 1))
    end
    return curve
end

-- Canonical "colour by time remaining" ramp: red → orange → yellow → green as
-- the remaining fraction climbs 0 → 1.  Matches the Linear colour-curve points
-- (0,red)(0.3,orange)(0.5,yellow)(1,green) evaluated on the secret-safe live
-- path, so the manual (preview) result agrees with the curve result.
-- pct is a NON-secret 0-1 fraction.  Returns r, g, b.
function Expiring:GradientColorAt(pct)
    pct = pct or 0
    if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
    if pct < 0.3 then
        return 1, 0.5 * (pct / 0.3), 0
    elseif pct < 0.5 then
        return 1, 0.5 + 0.5 * ((pct - 0.3) / 0.2), 0
    else
        return 1 - ((pct - 0.5) / 0.5), 1, 0
    end
end

-- Manual (non-secret) evaluation of a fill colour that may combine the
-- colour-by-time gradient with an expiring-threshold override.  This is the
-- preview/fallback twin of the C_CurveUtil colour curve built for the live
-- secret-safe path, keeping the gradient + threshold maths in ONE place so
-- consumers (e.g. the AD bar preview) don't hand-roll it.  remaining/duration
-- must be NON-secret (preview auras only).
--   ctx: { base = {r,g,b}, colorByTime, expiringEnabled, threshold,
--          thresholdMode ("SECONDS"|nil/percent), expiringColor = {r,g,b} }
-- Returns r, g, b.
function Expiring:EvaluateManualColor(ctx, remaining, duration)
    local base = ctx.base or ctx
    local r, g, b = base.r or 1, base.g or 1, base.b or 1
    local pct = 0
    if duration and duration > 0 then
        pct = remaining / duration
        if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
    end
    if ctx.colorByTime then
        r, g, b = self:GradientColorAt(pct)
    end
    if ctx.expiringEnabled and ctx.threshold then
        local isExp
        if ctx.thresholdMode == "SECONDS" then
            isExp = remaining <= ctx.threshold
        else
            isExp = pct <= (ctx.threshold / 100)
        end
        if isExp then
            local ec = ctx.expiringColor
            if ec then
                r = ec.r or 1
                g = ec.g or 0.2
                b = ec.b or 0.2
            end
        end
    end
    return r, g, b
end

-- Build a Step VISIBILITY curve: alpha 1 below threshold, alpha 0 at/above.
-- Used to secret-safely gate an alpha-based element (a tint overlay) — the
-- result's alpha is fed straight to SetAlphaFromBoolean.  Cached by mode+threshold.
local visibilityCurveCache = {}
function Expiring:BuildVisibilityCurve(threshold, thresholdMode)
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then return nil end
    threshold = threshold or 30
    local seconds = thresholdMode == "SECONDS"
    local key = (seconds and "s" or "p") .. threshold
    if visibilityCurveCache[key] then return visibilityCurveCache[key] end
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(0, CreateColor(1, 1, 1, 1))            -- below threshold: visible
    if seconds then
        curve:AddPoint(threshold, CreateColor(0, 0, 0, 0))  -- at/above: hidden
        curve:AddPoint(600, CreateColor(0, 0, 0, 0))
    else
        curve:AddPoint(threshold / 100, CreateColor(0, 0, 0, 0))
        curve:AddPoint(1, CreateColor(0, 0, 0, 0))
    end
    visibilityCurveCache[key] = curve
    return curve
end

-- Secret-safe expiring TINT: a colour overlay that fades in below threshold.
-- The tint texture carries its colour+max-alpha via SetColorTexture, and the
-- engine gates its visibility via SetAlphaFromBoolean on a visibility curve —
-- so it works on SECRET buff/debuff auras (alpha-based, never branches on the
-- secret remaining-time).  applyManual handles the non-secret preview path.
local function tintApplyResult(tex, result, entry)
    if not result.GetRGBA then return end
    local hasExp
    if entry.unit and entry.auraInstanceID and C_UnitAuras and C_UnitAuras.DoesAuraHaveExpirationTime then
        hasExp = C_UnitAuras.DoesAuraHaveExpirationTime(entry.unit, entry.auraInstanceID)
    end
    if tex.SetAlphaFromBoolean then
        tex:SetAlphaFromBoolean(hasExp, select(4, result:GetRGBA()), 0)
    else
        tex:SetAlpha(select(4, result:GetRGBA()))
    end
end

local function tintApplyManual(tex, isExp, entry)
    tex:SetAlpha(isExp and 1 or 0)
end

-- Register / refresh / unregister a tint overlay texture for an element.
-- ctx: { unit, auraInstanceID, threshold, thresholdMode, duration,
--        expirationTime, enabled, color = {r,g,b,a} }.  The texture's own alpha
-- (color.a) is the max tint strength; the curve gates 0↔1 on top of it.
function Expiring:UpdateTint(tex, ctx)
    if not tex then return end
    if not ctx or not ctx.enabled then
        self:Unregister(tex)
        tex:Hide()
        return
    end
    local c = ctx.color or {}
    local r = c.r or c[1] or 1
    local g = c.g or c[2] or 0
    local b = c.b or c[3] or 0
    local a = c.a or c[4] or 0.3
    tex:SetColorTexture(r, g, b, a)
    tex:Show()
    self:Register(tex, {
        unit = ctx.unit,
        auraInstanceID = ctx.auraInstanceID,
        threshold = ctx.threshold,
        thresholdMode = ctx.thresholdMode,
        duration = ctx.duration,
        expirationTime = ctx.expirationTime,
        colorCurve = self:BuildVisibilityCurve(ctx.threshold, ctx.thresholdMode),
        applyResult = tintApplyResult,
        applyManual = tintApplyManual,
    })
end

-- Evaluate one registry entry: API path (colour curve via the secret-safe
-- Duration API) with a preview fallback (manual pct), plus the optional
-- Show-When-Missing visibility toggle.  Shared by Register (immediate eval) and
-- the ticker so they never drift.
local function EvaluateEntry(element, entry)
    local applied = false

    -- API path: evaluate the colour curve on the real unit's Duration object.
    if entry.colorCurve and entry.unit and entry.auraInstanceID
       and C_UnitAuras and C_UnitAuras.GetAuraDuration then
        local durationObj = C_UnitAuras.GetAuraDuration(entry.unit, entry.auraInstanceID)
        if durationObj then
            local result
            if entry.thresholdMode == "SECONDS" and durationObj.EvaluateRemainingDuration then
                result = durationObj:EvaluateRemainingDuration(entry.colorCurve)
            elseif durationObj.EvaluateRemainingPercent then
                result = durationObj:EvaluateRemainingPercent(entry.colorCurve)
            end
            if result and entry.applyResult then
                entry.applyResult(element, result, entry)
                applied = true
            end
        end
    end

    -- Preview fallback: manual comparison against the threshold (non-secret).
    if not applied then
        local dur = entry.duration
        local exp = entry.expirationTime
        if dur and exp and not issecretvalue(dur) and not issecretvalue(exp) and dur > 0 then
            local remaining = max(0, exp - GetTime())
            local isExpiring
            if entry.thresholdMode == "SECONDS" then
                isExpiring = remaining <= (entry.threshold or 10)
            else
                isExpiring = (remaining / dur) <= ((entry.threshold or 30) / 100)
            end
            if entry.applyManual then
                entry.applyManual(element, isExpiring, entry)
            end
        elseif entry.applyManual then
            -- duration=0 means permanent or synthetic (missing) aura — not expiring
            entry.applyManual(element, false, entry)
        end
    end

    -- Show When Missing: toggle visibility based on expiring state.
    -- Icons/squares use Hide()/Show() so OOR alpha restore won't undo us.
    -- Borders use SetAlpha() since they're not in the OOR icon/square loop.
    if entry.hideWhenNotExpiring then
        local dur = entry.duration
        local exp = entry.expirationTime
        local isExp = false
        if dur and exp and not issecretvalue(dur) and not issecretvalue(exp) and dur > 0 then
            local rem = max(0, exp - GetTime())
            if entry.thresholdMode == "SECONDS" then
                isExp = rem <= (entry.threshold or 10)
            else
                isExp = (rem / dur) <= ((entry.threshold or 30) / 100)
            end
        end
        if entry.useShowHide then
            if isExp then
                element:Show()
                element:SetAlpha(entry.visibleAlpha or 1)
            else
                element:Hide()
            end
        else
            local notExpAlpha = entry.hiddenAlpha or 0
            element:SetAlpha(isExp and (entry.visibleAlpha or 1) or notExpAlpha)
        end
    end
end

-- Per-entry re-evaluation cadence.  1.0s matches alpha2's effective 1 FPS-per-
-- icon rate (CPU-neutral vs the old aura timer); lower = snappier colour
-- response at more cost.  The base ticker still wakes ~3 FPS, but each entry
-- only runs the (relatively expensive) Duration-curve evaluation when its own
-- interval has elapsed — so total evals/sec ≈ entries × (1/EVAL_INTERVAL).
local EVAL_INTERVAL = 1.0
local staggerCounter = 0

-- Register an element for expiring updates.  Evaluates immediately so the
-- caller's Apply ends with the correct colour/state (without this, Apply paints
-- the ORIGINAL colour and the ~3 FPS ticker overrides it later → visible
-- flicker on the first frame).
function Expiring:Register(element, entryData)
    expiringRegistry[element] = entryData
    EvaluateEntry(element, entryData)
    -- Stagger the first throttled re-eval across [0.1, 1.0]×interval so a burst
    -- of registrations (all auras appearing on combat start) doesn't land every
    -- entry's evaluations on the same tick.  Re-registration (aura refresh)
    -- re-runs the immediate eval above, so freshness on change is preserved.
    staggerCounter = (staggerCounter + 1) % 10
    entryData._nextEval = GetTime() + EVAL_INTERVAL * (0.1 + 0.1 * staggerCounter)
end

function Expiring:Unregister(element)
    if element then
        expiringRegistry[element] = nil
    end
end

-- Refresh a registered entry's aura-time fields without a full re-register.
-- Change-detection callers (the AD border path) skip their rebuild — and with
-- it the RegisterExpiring call — when nothing VISUAL changed. An aura REFRESH
-- keeps the same auraInstanceID, so it takes that skip and the entry's cached
-- duration/expirationTime go stale; the manual threshold fallback then
-- computes remaining time from the stale expiration, which decays to zero and
-- parks the entry permanently "expiring" (stuck pulse, stuck Show-When-Missing
-- visibility). Callers pass the CURRENT aura data every apply cycle; this is a
-- no-op when the element has no registered entry.
--
-- The new values are assigned unconditionally (no equality short-circuit:
-- duration/expirationTime may be secret values, and comparing secrets taints)
-- and the entry re-evaluates immediately, mirroring Register, so a refresh
-- that climbs back above the threshold un-expires on this same update instead
-- of a tick later.
function Expiring:UpdateEntryTimes(element, duration, expirationTime, auraInstanceID)
    local entry = element and expiringRegistry[element]
    if not entry then return end
    entry.duration = duration
    entry.expirationTime = expirationTime
    entry.auraInstanceID = auraInstanceID
    EvaluateEntry(element, entry)
end

-- ~3 FPS shared ticker.  One OnUpdate for every registered element across the
-- whole addon (AD indicators + buff expiring borders).
local expiringFrame = CreateFrame("Frame")
local expiringElapsed = 0
expiringFrame:Show()  -- CRITICAL: OnUpdate only fires on visible frames

expiringFrame:SetScript("OnUpdate", function(_, elapsed)
    expiringElapsed = expiringElapsed + elapsed
    if expiringElapsed < 0.33 then return end  -- base wake ~3 FPS
    expiringElapsed = 0

    local now = GetTime()
    for element, entry in pairs(expiringRegistry) do
        if not element:IsShown() then
            expiringRegistry[element] = nil
        elseif now >= (entry._nextEval or 0) then
            EvaluateEntry(element, entry)
            entry._nextEval = now + EVAL_INTERVAL
        end
    end
end)
