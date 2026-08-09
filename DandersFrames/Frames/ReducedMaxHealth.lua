local addonName, DF = ...

-- ==========================================================
-- REDUCED MAX HEALTH BAR
-- Visualises the fraction of a unit's max health that has been
-- temporarily reduced (M+ affixes, boss debuffs, etc.) using
-- GetUnitTotalModifiedMaxHealthPercent and the
-- UNIT_MAX_HEALTH_MODIFIERS_CHANGED event.
-- ==========================================================

local pairs, ipairs = pairs, ipairs
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

    if db.reducedMaxHealthClipHealthBar and frame.healthBar and tex and not pctIsSecret then
        -- Clip the health bar to the portion NOT covered by the reduced-max
        -- overlay: pin the three frame-side edges and anchor the full-health
        -- edge to the reduced texture's inner edge. Mirrors the orientation above.
        -- SKIPPED on the secret path: clipping re-anchors the health bar to the
        -- reduced bar's fill-texture geometry, which is driven by the secret value.
        -- The overlay itself renders fine from the secret (above), but we don't clip
        -- against secret-derived geometry unless it's proven taint-safe in-game.
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
        frame.dfReducedMaxHealthClipping = true
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
