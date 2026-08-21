local addonName, DF = ...

-- ==========================================================
-- REDUCED MAX HEALTH BAR
-- Visualises the fraction of a unit's max health that has been
-- temporarily reduced (M+ affixes, boss debuffs, etc.) using
-- GetUnitTotalModifiedMaxHealthPercent and the
-- UNIT_MAX_HEALTH_MODIFIERS_CHANGED event.
-- ==========================================================

local CreateFrame = CreateFrame
local UnitExists, UnitIsDead, UnitIsGhost, UnitIsConnected =
      UnitExists, UnitIsDead, UnitIsGhost, UnitIsConnected
local GetUnitTotalModifiedMaxHealthPercent = GetUnitTotalModifiedMaxHealthPercent
local issecretvalue = issecretvalue or function() return false end

local DEFAULT_BAR_COLOR = { r = 0.2, g = 0.2, b = 0.2, a = 0.85 }

function DF:CreateReducedMaxHealthBar(frame, db)
    if not frame or not frame.healthBar or frame.dfReducedMaxHealthBar then return end

    local padding = (db and db.framePadding) or 0

    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetPoint("TOPLEFT", padding, -padding)
    bar:SetPoint("BOTTOMRIGHT", -padding, padding)
    bar:SetReverseFill(true)
    bar:SetFrameLevel(frame.healthBar:GetFrameLevel() + 6)
    bar:Hide()

    frame.dfReducedMaxHealthBar = bar
end

function DF:RestoreHealthBarFromReducedMax(frame)
    if not frame or not frame.dfReducedMaxHealthClipping then return end
    if not frame.healthBar then
        frame.dfReducedMaxHealthClipping = nil
        return
    end
    local db = DF:GetFrameDB(frame)
    local padding = (db and db.framePadding) or 0
    frame.healthBar:ClearAllPoints()
    frame.healthBar:SetPoint("TOPLEFT", padding, -padding)
    frame.healthBar:SetPoint("BOTTOMRIGHT", -padding, padding)
    frame.dfReducedMaxHealthClipping = nil
    -- Same reason as the clip path: this restores the health bar's full rect, and the
    -- absorb layout cache detects a resize by MEASURING that rect — which will not have
    -- caught up in this tick. Drop the cache so the next absorb pass re-derives.
    frame.dfAbsorbState = nil
end

function DF:UpdateReducedMaxHealth(frame)
    if not frame or not frame.dfReducedMaxHealthBar then return end
    local bar = frame.dfReducedMaxHealthBar
    local db = DF:GetFrameDB(frame)

    if not db or not db.reducedMaxHealthEnabled then
        bar:Hide()
        DF:RestoreHealthBarFromReducedMax(frame)
        return
    end

    local unit = frame.unit
    if not frame.dfIsTestFrame then
        if not unit or not UnitExists(unit) or UnitIsDead(unit)
                or UnitIsGhost(unit) or not UnitIsConnected(unit) then
            bar:Hide()
            DF:RestoreHealthBarFromReducedMax(frame)
            return
        end
    end

    local pct
    if frame.dfIsTestFrame then
        pct = frame.dfTestReducedMaxPct or 0
    elseif GetUnitTotalModifiedMaxHealthPercent then
        pct = GetUnitTotalModifiedMaxHealthPercent(unit)
    end

    -- In restricted content (M+/raid — exactly where max-HP reductions live) the
    -- percent comes back SECRET. StatusBar:SetValue is a secret SINK
    -- (SecretArgumentsAddAspect = SecretAspect.BarValue), so instead of hiding we
    -- FORWARD the secret straight into the bar: an unmodified unit resolves to 0 ->
    -- an empty (invisible) reverse-fill; a reduced unit renders its fraction
    -- natively. Only the numeric "pct <= 0" hide-test is skipped on the secret path
    -- (comparing a secret taints; the `not pctIsSecret and` short-circuit keeps it
    -- unevaluated). issecretvalue() itself returns a plain, non-secret boolean.
    local pctIsSecret = issecretvalue(pct)
    if not pct or (not pctIsSecret and pct <= 0) then
        bar:Hide()
        DF:RestoreHealthBarFromReducedMax(frame)
        return
    end

    local texturePath = db.reducedMaxHealthTexture
    if texturePath then
        DF:SafeSetStatusBarTexture(bar, texturePath)
    end

    local c = db.reducedMaxHealthColor or DEFAULT_BAR_COLOR
    bar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)

    -- Match the health bar's orientation so the reduced-max overlay occupies the
    -- END of the fill direction (where full health reaches), lining up with the
    -- reduced maximum:
    --   HORIZONTAL      fill L->R, full end RIGHT  -> filled right  (horizontal, reverse)
    --   HORIZONTAL_INV  fill R->L, full end LEFT   -> filled left   (horizontal, normal)
    --   VERTICAL        fill B->T, full end TOP    -> filled top    (vertical, reverse)
    --   VERTICAL_INV    fill T->B, full end BOTTOM -> filled bottom (vertical, normal)
    local orientation = db.healthOrientation or "HORIZONTAL"
    local isVertical = (orientation == "VERTICAL" or orientation == "VERTICAL_INV")
    bar:SetOrientation(isVertical and "VERTICAL" or "HORIZONTAL")
    bar:SetReverseFill(orientation == "HORIZONTAL" or orientation == "VERTICAL")
    DF:ApplyBarFillOrientation(bar, isVertical)

    local tex = bar:GetStatusBarTexture()
    if tex then
        tex:SetBlendMode(db.reducedMaxHealthBlendMode or "BLEND")
    end

    -- Re-anchor the bar to the current padding. It is otherwise positioned only
    -- at creation (CreateReducedMaxHealthBar), so a padding change left it — and
    -- the clipped health bar's right edge, which anchors to this bar's texture —
    -- at the old inset, producing asymmetric padding (new on the left, old on
    -- the right).
    local padding = db.framePadding or 0
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", padding, -padding)
    bar:SetPoint("BOTTOMRIGHT", -padding, padding)

    bar:SetMinMaxValues(0, 1)
    bar:SetValue(pct)
    bar:Show()

    if db.reducedMaxHealthClipHealthBar and frame.healthBar and tex then
        -- Clip the health bar to the portion NOT covered by the reduced-max
        -- overlay: pin the three frame-side edges and anchor the full-health
        -- edge to the reduced texture's inner edge. Mirrors the orientation above.
        --
        -- ☠☠ THIS USED TO BE SKIPPED ON THE SECRET PATH, WHICH IS THE ONLY PATH THAT
        -- MATTERS. The note above says it plainly: in restricted content -- M+ and raid,
        -- "exactly where max-HP reductions live" -- the percent comes back secret. So the
        -- clip ran in test mode and nowhere else, and every consumer that reasons about
        -- "the usable bar" was reasoning about a rect that is only correct in a preview:
        --   * the dispel wash's "Show On Current Health Only" anchors to this bar
        --     precisely so the reduced region is excluded (Features/Dispel.lua's
        --     healthAnchor block, and the slot carrier's birth anchor). Unclipped, the
        --     wash spans the taken-away max and reads as though the option were off --
        --     "in game it looks like it does in test mode if you untick it" (Renegade,
        --     2026-08-19).
        --   * UpdateAbsorb's ATTACHED maths says "the bar physically ends there".
        --     In a key it did not.
        -- The original reason was caution, stated as caution: "we don't clip against
        -- secret-derived geometry unless it's proven taint-safe in-game." It is the
        -- established route -- ANCHORING derives geometry engine-side and reads nothing
        -- in Lua, which is the same doctrine DispelSlotSecureInit relies on and the same
        -- thing UpdateAbsorb already does to this very texture (Bars.lua's
        -- healthFillTexture anchors, ungated and shipping). Anchoring is not a read.
        -- ⚠ SELF-CORRECTING WHEN THE SECRET RESOLVES TO ZERO: an unmodified unit renders
        -- an empty reverse-fill, so `tex` collapses onto the full-health edge and these
        -- anchors give back the whole bar. That is why the numeric hide-test being
        -- unavailable here does not strand a clipped bar.
        -- ☠ GUARDED, AND THE FALLBACK RESTORES RATHER THAN LEAVES IT UNANCHORED. If the
        -- client ever does refuse one of these, a half-applied ClearAllPoints would leave
        -- the health bar with no points at all -- a worse outcome than the bug.
        local clipped = pcall(function()
            frame.healthBar:ClearAllPoints()
            if orientation == "HORIZONTAL_INV" then          -- reduced on left
                frame.healthBar:SetPoint("TOPRIGHT", -padding, -padding)
                frame.healthBar:SetPoint("BOTTOMRIGHT", -padding, padding)
                frame.healthBar:SetPoint("TOPLEFT", tex, "TOPRIGHT")
                frame.healthBar:SetPoint("BOTTOMLEFT", tex, "BOTTOMRIGHT")
            elseif orientation == "VERTICAL" then            -- reduced on top
                frame.healthBar:SetPoint("BOTTOMLEFT", padding, padding)
                frame.healthBar:SetPoint("BOTTOMRIGHT", -padding, padding)
                frame.healthBar:SetPoint("TOPLEFT", tex, "BOTTOMLEFT")
                frame.healthBar:SetPoint("TOPRIGHT", tex, "BOTTOMRIGHT")
            elseif orientation == "VERTICAL_INV" then        -- reduced on bottom
                frame.healthBar:SetPoint("TOPLEFT", padding, -padding)
                frame.healthBar:SetPoint("TOPRIGHT", -padding, -padding)
                frame.healthBar:SetPoint("BOTTOMLEFT", tex, "TOPLEFT")
                frame.healthBar:SetPoint("BOTTOMRIGHT", tex, "TOPRIGHT")
            else                                             -- HORIZONTAL: reduced on right
                frame.healthBar:SetPoint("TOPLEFT", padding, -padding)
                frame.healthBar:SetPoint("BOTTOMLEFT", padding, padding)
                frame.healthBar:SetPoint("TOPRIGHT", tex, "TOPLEFT")
                frame.healthBar:SetPoint("BOTTOMRIGHT", tex, "BOTTOMLEFT")
            end
        end)
        if not clipped then
            -- Re-pin the plain rect directly. RestoreHealthBarFromReducedMax is not
            -- usable here: it early-returns unless dfReducedMaxHealthClipping is already
            -- set, and this failed before setting it.
            DF:DebugWarn("HEALTH", "ReducedMaxHealth: health-bar clip refused on unit=%s; "
                .. "falling back to the unclipped rect", tostring(unit or "(test)"))
            frame.healthBar:ClearAllPoints()
            frame.healthBar:SetPoint("TOPLEFT", padding, -padding)
            frame.healthBar:SetPoint("BOTTOMRIGHT", -padding, padding)
            frame.dfReducedMaxHealthClipping = nil
            frame.dfAbsorbState = nil
            return
        end
        frame.dfReducedMaxHealthClipping = true
        -- ☠ THE ABSORB CACHE DEPENDS ON THE RECT WE JUST MOVED. UpdateAbsorb keeps a
        -- layout cache (frame.dfAbsorbState) and short-circuits when nothing changed; it
        -- detects a resize by comparing frame.healthBar:GetWidth(). Those SetPoints above
        -- do not change the measured width until the next draw, so an absorb pass in the
        -- same tick reads the PRE-CLIP width, concludes nothing moved, and takes the fast
        -- path -- leaving the absorb bar anchored to the unclipped edge, i.e. underneath
        -- the reduced-max region. Field-caught on test-mode re-entry: absorb + reduced max
        -- rendered side by side on the first entry, then the absorb vanished on a later
        -- one, and turning reduced max off revealed it sitting under there all along.
        -- Toggling absorbs off/on "fixed" it only because hiding the bar fails the fast
        -- path's IsShown() gate and forces the full rebuild.
        -- Invalidating here is causal: the thing that moved the anchor drops the cache
        -- that depends on it, so the next pass re-derives instead of measuring a rect
        -- that has not caught up.
        frame.dfAbsorbState = nil
    else
        DF:RestoreHealthBarFromReducedMax(frame)
    end

    if DF.Debug then
        -- Never pass the raw pct to Debug on the secret path — format/concat taints.
        DF:Debug("HEALTH", "ReducedMaxHealth updated: unit=%s pct=%s",
            tostring(unit or "(test)"), tostring(pctIsSecret and "<secret>" or pct))
    end
end

function DF:UpdateAllVisibleReducedMaxHealth(unit)
    local function updateFrame(frame)
        if frame and frame:IsShown() and (not unit or frame.unit == unit) then
            DF:UpdateReducedMaxHealth(frame)
            -- TD: hp_max_reduction is a "health"-hinted element. It's driven by
            -- UNIT_MAX_HEALTH_MODIFIERS_CHANGED (not UNIT_MAXHEALTH), so the
            -- dispatcher's health hook doesn't cover it — refresh here instead.
            if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "health") end
        end
    end

    -- ☠ Single-unit fast path. UNIT_MAX_HEALTH_MODIFIERS_CHANGED is PER-UNIT and
    -- storms when an affix or raid-wide debuff hits the group; the iterators
    -- below walk every party AND raid frame to find the one that matches, so a
    -- storm is O(roster^2). The roster map exists for exactly this lookup.
    -- Falls through when the map has no entry (pinned frames are deliberately
    -- excluded from it), so behaviour is unchanged -- only the common case is
    -- faster.
    if unit and DF.unitFrameMap then
        local mapped = DF.unitFrameMap[unit]
        if mapped then
            updateFrame(mapped)
            return
        end
    end

    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(updateFrame)
    end
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(updateFrame)
    end
    if DF.IterateAllFrames and not (DF.IteratePartyFrames or DF.IterateRaidFrames) then
        DF:IterateAllFrames(updateFrame)
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        self:RegisterEvent("UNIT_MAX_HEALTH_MODIFIERS_CHANGED")
    elseif event == "UNIT_MAX_HEALTH_MODIFIERS_CHANGED" then
        local unit = ...
        if DF.UpdateAllVisibleReducedMaxHealth then
            DF:UpdateAllVisibleReducedMaxHealth(unit)
        end
    end
end)
