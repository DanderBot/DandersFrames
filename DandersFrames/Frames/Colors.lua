local addonName, DF = ...

-- ============================================================
-- FRAMES COLORS MODULE
-- Contains health color system, gradients, and dead fade
-- ============================================================

-- Apply out of range effect to test frame
-- Style the status text element based on settings
function DF:StyleStatusText(frame)
    if not frame or not frame.statusText then return end
    
    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    
    -- Apply font
    local font = db.statusTextFont or "Fonts\\FRIZQT__.TTF"
    local fontSize = db.statusTextFontSize or 10
    local outline = db.statusTextOutline or "OUTLINE"
    if outline == "NONE" then outline = "" end
    
    DF:SafeSetFont(frame.statusText, font, fontSize, outline)
    
    -- Apply position
    frame.statusText:ClearAllPoints()
    local anchor = db.statusTextAnchor or "CENTER"
    frame.statusText:SetPoint(anchor, frame, anchor, db.statusTextX or 0, db.statusTextY or 0)
    
    -- Apply color
    local color = db.statusTextColor or {r = 1, g = 1, b = 1}
    frame.statusText:SetTextColor(color.r, color.g, color.b, 1)
    
    -- Ensure it's on top
    frame.statusText:SetDrawLayer("OVERLAY", 7)
end

-- Apply dead/offline fade to frame elements
-- statusType: "Dead" or "Offline" - used for dead-specific styling
function DF:ApplyDeadFade(frame, statusType, forceApply)
    if not frame then return end
    
    -- ☠ THIS BAIL WAS CIRCULAR. It skipped test frames "because they handle their own
    -- dead fade in TestMode.lua" -- and TestMode's only dead-fade code is the call INTO
    -- this function (with forceApply set, at UpdateTestFrame). Its own handler moved to
    -- ElementAppearance in the 2026-08-07 audit and this comment was not updated, so each
    -- side deferred to the other and the work happened nowhere: a preview frame never got
    -- the fade, dfDeadFadeApplied never became true on one, and every later branch reading
    -- that flag for a test frame was dead.
    --
    -- Gated on forceApply rather than removed, so the AUTOMATIC path -- driven by real
    -- unit state, which a test frame does not have -- still skips previews as intended.
    -- The body below delegates to UpdateAllElementAppearances, which is what the preview
    -- already runs, so the two now agree instead of cancelling.
    if frame.dfIsTestFrame and not forceApply then return end
    
    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    if not db.fadeDeadFrames then return end
    
    -- Mark the frame as having dead fade applied
    frame.dfDeadFadeApplied = true
    
    -- Delegate to ElementAppearance for centralized handling
    -- This ensures consistent appearance across all code paths
    if DF.UpdateAllElementAppearances then
        DF:UpdateAllElementAppearances(frame)
        return
    end
    
end

-- Reset dead fade (restore normal alpha)
function DF:ResetDeadFade(frame)
    if not frame then return end
    if not frame.dfDeadFadeApplied then return end
    
    -- Clear the flag FIRST so ElementAppearance knows we're not in dead state
    frame.dfDeadFadeApplied = false
    
    -- Delegate to ElementAppearance for centralized handling
    -- This ensures consistent appearance across all code paths
    if DF.UpdateAllElementAppearances then
        DF:UpdateAllElementAppearances(frame)
        return
    end
end
-- ============================================================
-- SMOOTH BAR HELPER
-- ============================================================
-- Uses the new 12.0.5 StatusBar:SetValue interpolation when smoothBars is enabled

local function SetBarValue(bar, value, frame, smoothOverride)
    if not bar or not bar.SetValue then return end

    -- Get the appropriate db for this frame
    local db
    if frame and frame.isRaidFrame then
        db = DF.GetRaidDB and DF:GetRaidDB()
    else
        db = DF.GetDB and DF:GetDB()
    end
    -- smoothOverride lets a specific bar gate on its own key (e.g. resourceBarSmooth)
    -- instead of the global health-bar smoothBars toggle.
    local smoothEnabled
    if smoothOverride ~= nil then
        smoothEnabled = smoothOverride
    else
        smoothEnabled = db and db.smoothBars
    end
    
    if smoothEnabled and Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut then
        bar:SetValue(value, Enum.StatusBarInterpolation.ExponentialEaseOut)
    else
        bar:SetValue(value)
    end
end

-- Export for use in other files
DF.SetBarValue = SetBarValue

-- ============================================================
-- HEALTH COLOR SYSTEM
-- ============================================================

function DF:UpdateColorCurve()
    DF.CurveCache = {}
    DF.MissingHealthCurveCache = {}
end

-- ★ THE ONE PLACE THE GRADIENT'S SHAPE IS DECIDED. Returns an ordered list of
-- { pos = 0..1, r, g, b, a }, low health first, for both consumers below: the live
-- C_CurveUtil curve and the by-hand interpolation the previews use.
--
-- ☠ IT USED TO BE TWO COPIES. GetCurveForUnit and GetHealthGradientColor each had
-- their own GetStageColor and their own weighted point-array build -- the second
-- literally commented "same logic as GetCurveForUnit" -- and they had ALREADY drifted:
-- one nil-guard returned an alpha and the other did not, so a profile missing a colour
-- key rendered opaque grey live and alpha-nil grey in the preview.
--
-- TWO SHAPES ARE READ, deliberately:
--   * <prefix>Stops -- the list. Each entry { threshold = 0..100, color, useClass }.
--     threshold is HEALTH PERCENT, so 0 is the low end and 100 the full end.
--   * the legacy Low/Medium/High + <stage>Weight stages, when no list is present.
--     A weight of N repeats that stage N times in the array, and the array is spaced
--     evenly -- which is exactly a stop list with evenly spaced thresholds, and is how
--     the migration converts one to the other without changing a pixel.
-- The fallback is not dead code for old profiles only: it is what makes a profile
-- readable BEFORE the lazy migration has run on it.
local function BuildColorStops(db, prefix, class)
    local function stageColor(c, useClass)
        if useClass and class and class ~= "DEFAULT" then
            local cc = DF:GetClassColor(class)
            if cc then return cc.r, cc.g, cc.b, 1.0 end
            return 0.5, 0.5, 0.5, 1.0
        end
        -- ⚠ Nil-guarded WITH an alpha. An imported or partially-migrated profile can be
        -- missing any colour key; unguarded this threw on every health tick.
        c = c or { r = 0.5, g = 0.5, b = 0.5, a = 1 }
        return c.r or 0.5, c.g or 0.5, c.b or 0.5, c.a or 1
    end

    local out = {}
    local stops = db[prefix .. "Stops"]
    if type(stops) == "table" and #stops >= 2 then
        for _, s in ipairs(stops) do
            local r, g, b, a = stageColor(s.color, s.useClass)
            out[#out + 1] = { pos = math.max(0, math.min(100, tonumber(s.threshold) or 0)) / 100,
                              r = r, g = g, b = b, a = a }
        end
        table.sort(out, function(x, y) return x.pos < y.pos end)
        return out
    end

    -- Legacy stages. Expand by weight, then space evenly -- the original behaviour.
    local pts = {}
    for _, stage in ipairs({ "Low", "Medium", "High" }) do
        local w = math.max(1, math.floor(db[prefix .. stage .. "Weight"] or 1))
        local r, g, b, a = stageColor(db[prefix .. stage], db[prefix .. stage .. "UseClass"])
        for _ = 1, w do pts[#pts + 1] = { r = r, g = g, b = b, a = a } end
    end
    if #pts < 2 then
        local r1, g1, b1, a1 = stageColor(db[prefix .. "Low"], db[prefix .. "LowUseClass"])
        local r2, g2, b2, a2 = stageColor(db[prefix .. "High"], db[prefix .. "HighUseClass"])
        pts = { { r = r1, g = g1, b = b1, a = a1 }, { r = r2, g = g2, b = b2, a = a2 } }
    end
    for i, p in ipairs(pts) do
        p.pos = (i - 1) / (#pts - 1)
        out[#out + 1] = p
    end
    return out
end
DF.BuildColorStops = BuildColorStops   -- the options page previews the same list

-- Get a color curve for gradient mode
-- prefix: db key prefix ("healthColor" or "missingHealthColor")
-- cache: cache table to use (DF.CurveCache or DF.MissingHealthCurveCache)
function DF:GetCurveForUnit(unit, db, prefix, cache)
    if not unit then return nil end
    prefix = prefix or "healthColor"
    cache = cache or DF.CurveCache
    
    -- ⚠ The cache is keyed by CLASS, so the "does anything here want a class colour"
    -- test has to cover both shapes: any stop in the list, or any of the three legacy
    -- stage flags. Miss the list half and a class-coloured stop would be resolved once
    -- against DEFAULT and then served from cache to every class in the group.
    local useClass = db[prefix .. "LowUseClass"] or db[prefix .. "MediumUseClass"] or db[prefix .. "HighUseClass"]
    if not useClass then
        local stops = db[prefix .. "Stops"]
        if type(stops) == "table" then
            for _, s in ipairs(stops) do
                if s.useClass then useClass = true break end
            end
        end
    end

    local class = "DEFAULT"
    if useClass then
        _, class = UnitClass(unit)
        if not class then class = "DEFAULT" end
    end

    if cache[class] then return cache[class] end

    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then return nil end

    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Linear)

    for _, s in ipairs(BuildColorStops(db, prefix, class)) do
        curve:AddPoint(s.pos, CreateColor(s.r, s.g, s.b, s.a))
    end

    cache[class] = curve
    return curve
end

-- Get gradient color for a health percentage using actual db settings
-- This replicates the curve logic for test mode where we don't have a real unit
-- prefix: db key prefix ("healthColor" or "missingHealthColor")
function DF:GetHealthGradientColor(percent, db, testClass, prefix)
    prefix = prefix or "healthColor"

    local stops = BuildColorStops(db, prefix, testClass)
    percent = math.max(0, math.min(1, tonumber(percent) or 0))

    -- ⚠ BRACKET BY POSITION, NOT BY INDEX. The old code walked an evenly spaced array
    -- (`percent * (numPoints - 1)`), which was only correct because weights produced
    -- even spacing by construction. Stops carry their own thresholds, so the segment
    -- has to be found by comparing positions -- index arithmetic would silently place
    -- an unevenly spaced ramp wrong, and it would still LOOK like a gradient.
    local lower, upper = stops[1], stops[#stops]
    for i = 1, #stops - 1 do
        if percent >= stops[i].pos and percent <= stops[i + 1].pos then
            lower, upper = stops[i], stops[i + 1]
            break
        end
    end
    -- Outside the outermost stops (a ramp that does not start at 0 or reach 100), hold
    -- the end colour rather than extrapolating off the end of the ramp.
    if percent <= stops[1].pos then lower, upper = stops[1], stops[1] end
    if percent >= stops[#stops].pos then lower, upper = stops[#stops], stops[#stops] end

    local span = upper.pos - lower.pos
    local t = (span > 0) and ((percent - lower.pos) / span) or 0

    return {
        r = lower.r + (upper.r - lower.r) * t,
        g = lower.g + (upper.g - lower.g) * t,
        b = lower.b + (upper.b - lower.b) * t,
    }
end

-- Apply health bar colors based on settings
function DF:ApplyHealthColors(frame)
    if not frame or not frame.healthBar then return end

    -- Skip if Aura Designer health bar color indicator is active
    local adState = frame.dfAD
    if adState and adState.healthbar then return end

    local unit = frame.unit
    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    local mode = db.healthColorMode
    local classColorAlpha = db.classColorAlpha or 1.0
    
    -- Check if dead fade is currently applied to this frame
    -- Only use the flag - don't re-check dead status here
    local deadFadeActive = frame.dfDeadFadeApplied
    
    -- Check if aggro color override is active
    if frame.dfAggroActive and frame.dfAggroColor then
        local c = frame.dfAggroColor
        frame.healthBar:SetStatusBarColor(c.r, c.g, c.b)
        -- Also set vertex color to override gradient mode
        local tex = frame.healthBar:GetStatusBarTexture()
        if tex then
            tex:SetVertexColor(c.r, c.g, c.b)
            if not deadFadeActive then
                tex:SetAlpha(classColorAlpha)
            end
        end
        return  -- Skip normal color logic
    end
    
    if mode == "PERCENT" then
        -- Gradient mode - use color curve
        local curve = DF:GetCurveForUnit(unit, db)
        if curve and unit and UnitHealthPercent then
            local color = UnitHealthPercent(unit, true, curve)
            local tex = frame.healthBar:GetStatusBarTexture()
            if color and tex then
                tex:SetVertexColor(color:GetRGB())
                -- Don't override alpha if dead fade is applied
                if not deadFadeActive then
                    tex:SetAlpha(classColorAlpha)
                end
            end
        end
    elseif mode == "CLASS" then
        -- Class color mode - use RGB only, alpha controlled separately
        local r, g, b = 0, 1, 0
        if unit then
            local _, class = UnitClass(unit)
            local classColor = class and DF:GetClassColor(class)
            if classColor then
                r, g, b = classColor.r, classColor.g, classColor.b
            end
        end
        frame.healthBar:SetStatusBarColor(r, g, b)
        local tex = frame.healthBar:GetStatusBarTexture()
        if tex then
            -- ALSO write the colour to the texture's vertex directly (the same
            -- channel PERCENT mode and ElementAppearance use). Without this,
            -- switching from Percent to Class can leave the last gradient
            -- colour visible: PERCENT painted the texture directly, so the
            -- StatusBar's own cached colour may already equal the class colour
            -- and SetStatusBarColor above no-ops, leaving the gradient stain
            -- (typically green at full health) until /reload. Writing the same
            -- rgb through the vertex guarantees the visible state either way,
            -- and matches UpdateHealthBarAppearance's channel so the two
            -- appliers can't fight.
            tex:SetVertexColor(r, g, b)
            -- Apply alpha separately so range/dead fade can control it
            if not deadFadeActive then
                tex:SetAlpha(classColorAlpha)
            end
        end
    else
        -- Custom color mode - use RGBA
        local c = db.healthColor
        frame.healthBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        -- Same direct vertex write as the CLASS branch above (gradient-stain fix).
        local tex = frame.healthBar:GetStatusBarTexture()
        if tex then tex:SetVertexColor(c.r, c.g, c.b) end
    end
    
    -- Skip background color if dead fade with custom color is active
    if deadFadeActive and db.fadeDeadUseCustomColor then
        -- Dead fade custom color takes priority, don't override
        return
    end
    
    -- Also skip if dead fade is active (preserve the alpha)
    if deadFadeActive then
        return
    end
    
    -- Background color is handled by ElementAppearance.lua (UpdateBackgroundAppearance)
    -- which is called from UpdateUnitFrame. No need to duplicate it here.
end

-- ☠ (Removed) DF:ApplyBarOrientation. Zero callers in either addon -- its only other
-- mention was a string in Profiler's PROFILED_FUNCTIONS, which WRAPS DF[name] and
-- never calls it, so wrapping this measured nothing. It duplicated the orientation
-- mapping Frames/Update.lua does inside ApplyFrameLayout, for both the health bar and
-- the missing-health bar, including the "missing health fills the opposite way" rule.
--
-- ⚠ ITS SAFETY ARM WAS THE ONE THING WORTH KEEPING, so that reasoning moved to the
-- live site rather than dying here -- see the note by the orientation chain in
-- Frames/Update.lua. Two claims in the comment it carried were wrong and are not
-- reproduced there: on the live path an unrecognised mode does NOT throw (it leaves
-- the bar untouched instead), and it cited "UpdateReducedMaxHealth in this same
-- file", which lives in Frames/ReducedMaxHealth.lua.

