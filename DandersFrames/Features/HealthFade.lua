local addonName, DF = ...

-- ============================================================
-- HEALTH THRESHOLD FADE SYSTEM (Curve-Based)
-- Fades frames when a unit's health is above a configurable threshold.
-- Uses C_CurveUtil.CreateColorCurve() to encode the fade alpha in the
-- curve's alpha channel, then passes UnitHealthPercent(unit, true, curve)
-- to get a ColorMixin whose GetRGBA() alpha is the resolved fade value.
-- The result goes straight to frame:SetAlpha() — NO Lua-side comparison
-- ever touches the secret number.
-- Frame-level fade only — element-specific removed for performance.
-- ============================================================

-- Upvalue frequently used globals
local UnitExists = UnitExists
local UnitHealthPercent = UnitHealthPercent
local CreateColor = CreateColor
local wipe = wipe
local issecretvalue = issecretvalue

-- ============================================================
-- CURVE CACHE
-- Curves keyed by (threshold, belowAlpha, aboveAlpha).
-- Typically only 1-2 unique curves at any time.
-- ============================================================

-- ☠ Nested by the three numbers rather than one concatenated string key. This
-- is reached from SetHealthBarValue on EVERY health update of every frame, and
-- building "threshold_below_above" cost two number->string conversions plus two
-- concatenations per tick purely to look up a cache HIT. Nesting is three hash
-- lookups and allocates only on a genuine miss.
local healthFadeCurveCache = {}

local function BuildHealthFadeCurve(threshold, belowAlpha, aboveAlpha)
    local byThreshold = healthFadeCurveCache[threshold]
    if byThreshold then
        local byBelow = byThreshold[belowAlpha]
        local hit = byBelow and byBelow[aboveAlpha]
        if hit then return hit end
    end

    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Linear)

    local pos = threshold / 100  -- 0-1 range
    local belowColor = CreateColor(1, 1, 1, belowAlpha)
    local aboveColor = CreateColor(1, 1, 1, aboveAlpha)

    -- Step function at threshold boundary
    curve:AddPoint(0, belowColor)
    if pos > 0.001 then curve:AddPoint(pos - 0.001, belowColor) end
    if pos < 0.999 then curve:AddPoint(pos + 0.001, aboveColor) end
    curve:AddPoint(1, aboveColor)

    byThreshold = healthFadeCurveCache[threshold]
    if not byThreshold then
        byThreshold = {}
        healthFadeCurveCache[threshold] = byThreshold
    end
    local byBelow = byThreshold[belowAlpha]
    if not byBelow then
        byBelow = {}
        byThreshold[belowAlpha] = byBelow
    end
    byBelow[aboveAlpha] = curve
    return curve
end

-- Invalidate curve cache when options change (called from Options.lua)
function DF:InvalidateHealthFadeCurve()
    wipe(healthFadeCurveCache)
end

-- ============================================================
-- APPLY HEALTH FADE ALPHA
-- Builds a curve encoding the fade, evaluates it via UnitHealthPercent,
-- and applies the result directly to frame:SetAlpha().
-- Returns true if health fade alpha was applied.
-- NO secret number comparisons — the curve result goes straight to SetAlpha.
-- ============================================================

function DF:ApplyHealthFadeAlpha(frame)
    if not frame or not frame.unit then return false end

    local db = DF:GetFrameDB(frame)
    if not db or not db.healthFadeEnabled then return false end

    -- ★ Test frames pass through; see the dfHealthPct branch below for how the
    -- threshold is resolved without a real unit.
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return false end

    -- Dispel cancel: if dispel overlay is showing, cancel fade
    -- (IsShown is a non-tainted boolean)
    if db.hfCancelOnDispel then
        if frame.dfDispelOverlay and frame.dfDispelOverlay:IsShown() then
            return false
        end
    end

    -- Determine below-threshold alpha based on range state
    -- frame.dfInRange may be a secret boolean from UnitInRange fallback
    local belowAlpha = 1.0
    if not db.oorEnabled then
        local inRange = frame.dfInRange
        if not (issecretvalue and issecretvalue(inRange)) and inRange == false then
            belowAlpha = db.rangeFadeAlpha or 0.4
        end
        -- Secret values: can't compare, leave belowAlpha at 1 (OOR handled by frame-level SetAlphaFromBoolean)
    end

    local aboveAlpha = db.healthFadeAlpha or 0.5
    local threshold = db.healthFadeThreshold or 100

    -- ☠ DATA FORK, NOT A RENDER FORK. Live must resolve the threshold through the
    -- ENGINE -- UnitHealthPercent(unit, true, curve) -- because the health value is
    -- secret and Lua may never compare it. A test frame's health is a plain number
    -- DF wrote itself, so the same threshold is a plain comparison, and the same two
    -- alphas come out. Everything after this point is shared.
    -- ⚠ The comparison is `>` to match the curve, whose points sit at
    -- threshold/100 -/+ 0.001: at exactly the threshold the curve returns belowAlpha.
    local alpha
    if frame.dfHealthPct then
        alpha = (frame.dfHealthPct > (threshold / 100)) and aboveAlpha or belowAlpha
    else
        -- Build curve and resolve via WoW engine (no secret number comparison)
        local curve = BuildHealthFadeCurve(threshold, belowAlpha, aboveAlpha)
        local color = UnitHealthPercent(frame.unit, true, curve)
        if not color then return false end

        -- Extract alpha and apply directly — never compare, never store
        local _, _, _, a = color:GetRGBA()
        alpha = a
    end
    if not alpha then return false end

    frame:SetAlpha(alpha)
    return true
end

-- ============================================================
-- UPDATE HEALTH FADE STATE FOR A FRAME
-- Called from SetHealthBarValue on every health update.
-- ============================================================

function DF:UpdateHealthFade(frame)
    if not frame or not frame.unit then return end

    if frame.isPetFrame then
        DF:UpdatePetHealthFade(frame)
        return
    end

    if DF:MemTestDisabled("enableHealthFade") then return end
    -- ☠ TEST FRAMES PASS THROUGH — the same gate shape DF:ApplyHealthFadeAlpha uses.
    -- This was a flat `if DF.testMode or DF.raidTestMode then return end`, which left the
    -- feature HALF-MIGRATED: the applier was taught to fade a preview (it carries a
    -- dfHealthPct data fork) but the driver that sets dfHealthFadeActive still bailed —
    -- and UpdateFrameAppearance gates its fade branch on exactly that flag. So the shared
    -- appearance pass always took the else-branch and reset the frame to alpha 1.0, and
    -- previews stayed opaque (Krathe, 2026-08-08). The applier's preview support existed
    -- but was unreachable through the live path.
    -- ⚠ Animate Health MASKED it: UpdateTestFrameHealthOnly calls ApplyHealthFadeAlpha
    -- directly from the ticker, AFTER the appearance pass, so it won by running last.
    -- Fixing the driver is what makes the STATIC path work.
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local db = DF:GetFrameDB(frame)
    if not db or not db.healthFadeEnabled then
        if frame.dfHealthFadeActive then
            frame.dfHealthFadeActive = false
            if DF.UpdateAllElementAppearances then
                DF:UpdateAllElementAppearances(frame)
            end
        end
        return
    end

    local applied = DF:ApplyHealthFadeAlpha(frame)
    local wasActive = frame.dfHealthFadeActive

    frame.dfHealthFadeActive = applied

    -- On transition off (dispel cancel etc), restore normal appearance
    if wasActive and not applied then
        if DF.UpdateAllElementAppearances then
            DF:UpdateAllElementAppearances(frame)
        end
    end
end

-- ============================================================
-- UPDATE HEALTH FADE FOR PET FRAMES
-- Same curve approach — only set frame:SetAlpha (cascades to children).
-- Do NOT also set healthBar:SetAlpha or the alpha double-stacks.
-- ============================================================

function DF:UpdatePetHealthFade(frame)
    if not frame or not frame.unit then return end
    if not UnitExists(frame.unit) then return end

    local db = DF:GetFrameDB(frame)
    if not db or not db.healthFadeEnabled then
        frame.dfHealthFadeActive = false
        -- ☠ DO NOT STAMP 1.0 OVER THE RANGE FADE. healthFadeEnabled is FALSE by default,
        -- and Range.lua's OnLoop calls DF:UpdatePetRange(frame) and then
        -- DF:UpdatePetHealthFade(frame) on the same frame in the same pass -- so this
        -- unconditional reset erased the range fade the line before had just applied.
        -- UpdatePetRange early-returns on a cache hit, so it never re-applied it: at stock
        -- settings an out-of-range pet's frame sat at full opacity indefinitely.
        --
        -- With health fade off this function has no opinion about alpha, so leaving it alone
        -- is correct. The range path is the only other writer of pet frame alpha and always
        -- sets an explicit value (1.0 when in range), so nothing here needs to reset it.
        return
    end

    local threshold = db.healthFadeThreshold or 100
    local aboveAlpha = db.healthFadeAlpha or 0.5

    local curve = BuildHealthFadeCurve(threshold, 1.0, aboveAlpha)
    local color = UnitHealthPercent(frame.unit, true, curve)
    if not color then return end

    local _, _, _, alpha = color:GetRGBA()
    if not alpha then return end

    frame:SetAlpha(alpha)
end

-- ============================================================
-- HELPER: Check if a frame is currently health-faded
-- ============================================================
