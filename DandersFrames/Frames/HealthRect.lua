local addonName, DF = ...

-- ============================================================
-- HEALTH BAR RECT
-- The ONE place that decides where the health bar sits inside its frame.
-- Every site that anchors the health bar asks this file: frame creation
-- (Frames/Create.lua), every layout pass (DF:AnchorHealthBarsToPadding, called
-- by the live update, the test-mode update and the resize path), the reduced
-- max health strip (Frames/ReducedMaxHealth.lua) and the power bar's own
-- show/hide watch (Frames/Bars.lua).
--
-- The rect is the frame minus framePadding on every side, except that with
-- "Shrink Health Bar" (resourceBarShrinkHealth) on, the side the power bar is
-- attached to stops at the power bar's inner edge instead of running under it.
--
-- Only plain (non-secure) regions are anchored here -- the health bar, the
-- missing-health bar and the reduced-max strip -- so none of it is blocked in
-- combat and none of it needs an InCombatLockdown() guard. Keep it that way:
-- anything secure added here has to be guarded.
-- ============================================================

local math_max = math.max

-- Which edge a matched power bar hugs, or nil when it does not hug one.
-- Horizontal bars attach to TOP / BOTTOM, vertical bars to LEFT / RIGHT. A
-- centred bar, a corner anchor or the "wrong" axis for the orientation floats
-- over the bar rather than owning an edge, so there is nothing to make room for.
function DF:GetPowerBarShrinkSide(db)
    if not db then return nil end
    local anchor = db.resourceBarAnchor or "CENTER"
    if db.resourceBarOrientation == "VERTICAL" then
        if anchor == "LEFT" or anchor == "RIGHT" then return anchor end
    else
        if anchor == "TOP" or anchor == "BOTTOM" then return anchor end
    end
    return nil
end

-- Settings-only half of the gate: can the option do anything with this layout?
-- The settings page greys the checkbox on this. Party, raid AND the unit frames
-- companion (standalone frames read the same keys off frame.dfDB); a DETACHED bar
-- (unit frames only) owns no edge and is refused per frame in GetHealthBarInsets.
function DF:CanShrinkHealthForPowerBar(db)
    if not db then return false end
    if not db.resourceBarEnabled then return false end
    if not db.resourceBarMatchWidth then return false end
    -- Only a unit frame's table carries this key (the Detach card); a party / raid
    -- table never does, so this greys the checkbox on a unit page alone.
    if db.resourceBarDetached then return false end
    return DF:GetPowerBarShrinkSide(db) ~= nil
end

-- Settings + frame half of the gate, WITHOUT the bar's shown state: would this
-- frame's health bar stop at its power bar while the bar is up? Bars.lua asks this
-- while laying the bar out (the bar is being shown at that moment), to keep the
-- bar's ends inside the frame border band -- see LayoutResourceBar's edgeInset.
function DF:IsHealthShrinkWanted(frame, db)
    if not (db and db.resourceBarShrinkHealth) then return false end
    if not frame or not DF:CanShrinkHealthForPowerBar(db) then return false end
    if DF.IsResourceBarDetached and DF:IsResourceBarDetached(frame, db) then return false end
    return true
end

-- How far the power bar's INNER edge sits from the frame edge it is attached to.
-- Thickness plus the offset that pushes it inward (a positive Y for a bottom bar,
-- a negative Y for a top bar, and the same with X for left / right). An outward
-- offset is negative and reduces it.
-- ☠ SNAP EXACTLY WHAT Bars.lua SNAPS, NO MORE: the bar is ppThickness tall, placed
-- at the RAW offset from the frame edge. Snapping the total as well put the health
-- bar's edge one pixel off the bar's whenever the offset was not a whole pixel.
local function PowerBarInnerEdge(db, side)
    local thickness = tonumber(db.resourceBarHeight) or 4
    if db.pixelPerfect and DF.PixelPerfect then thickness = DF:PixelPerfect(thickness) end
    local inward
    if side == "BOTTOM" then inward = tonumber(db.resourceBarY) or 0
    elseif side == "TOP" then inward = -(tonumber(db.resourceBarY) or 0)
    elseif side == "LEFT" then inward = tonumber(db.resourceBarX) or 0
    else inward = -(tonumber(db.resourceBarX) or 0) end
    return thickness + inward
end

-- The health bar's insets from the frame's LEFT, RIGHT, TOP and BOTTOM edges.
-- ★ THE SHRINK RULE: on the power bar's side the inset is
--     max(framePadding, thickness + inward offset)
-- i.e. the health bar ends exactly where the power bar ends, with no gap and no
-- overlap, wherever the bar is pushed. max() keeps the padding when the bar is
-- pushed OUT past the frame far enough that it no longer reaches the padding.
-- The health bar always keeps at least 1 unit of height / width.
--
-- PER FRAME: only while THIS frame's power bar is actually shown (its own
-- IsShown flag, so a hidden parent does not count as a hidden bar). Role and
-- class filters, solo mode and the enable switch all decide that upstream.
--
-- ☠ HOT PATH: ReducedMaxHealth calls this on every health tick. No allocation.
function DF:GetHealthBarInsets(frame, db)
    local padding = (db and db.framePadding) or 0
    local l, r, t, b = padding, padding, padding, padding
    if not (db and db.resourceBarShrinkHealth) then return l, r, t, b end
    if not frame then return l, r, t, b end
    if not db.resourceBarMatchWidth then return l, r, t, b end
    if DF.IsResourceBarDetached and DF:IsResourceBarDetached(frame, db) then return l, r, t, b end
    local bar = frame.dfPowerBar
    if not (bar and bar:IsShown()) then return l, r, t, b end
    local side = DF:GetPowerBarShrinkSide(db)
    if not side then return l, r, t, b end

    local edge = math_max(padding, PowerBarInnerEdge(db, side))
    -- Never collapse the health bar: leave it at least 1 unit across.
    if side == "TOP" or side == "BOTTOM" then
        local h = frame.dfPinnedHeight or db.frameHeight or 50
        local limit = h - padding - 1
        if edge > limit then edge = math_max(padding, limit) end
        if side == "TOP" then t = edge else b = edge end
    else
        local w = frame.dfPinnedWidth or db.frameWidth or 120
        local limit = w - padding - 1
        if edge > limit then edge = math_max(padding, limit) end
        if side == "LEFT" then l = edge else r = edge end
    end
    return l, r, t, b
end

-- Anchor a region to the health rect.
function DF:AnchorToHealthRect(region, frame, l, r, t, b)
    region:ClearAllPoints()
    region:SetPoint("TOPLEFT", frame, "TOPLEFT", l, -t)
    region:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -r, b)
end

-- ★ THE LAYOUT PASS. Puts the health bar (and the missing-health overlay, which
-- covers the same area) on the current rect, and remembers the rect so the power
-- bar watch can tell when it has to move.
-- ☠ THIS UN-CLIPS A REDUCED-MAX-HEALTH CLIP, so it forgets that clip. The clip only
-- re-runs when its geometry changes (ReducedMaxHealth.lua's needClip); left set, the
-- flag said "still clipped" and the health fill ran under the reduced band until
-- orientation, padding or texture next changed. Cleared, the next reduced-max pass
-- (right after this in the live and test updates) clips again.
function DF:AnchorHealthBarsToPadding(frame, db)
    if not (frame and frame.healthBar) then return end
    db = db or DF:GetFrameDB(frame)
    local l, r, t, b = DF:GetHealthBarInsets(frame, db)
    DF:AnchorToHealthRect(frame.healthBar, frame, l, r, t, b)
    frame.dfHealthRectL, frame.dfHealthRectR, frame.dfHealthRectT, frame.dfHealthRectB = l, r, t, b
    frame.dfReducedMaxHealthClipping = nil
    frame.dfRMClipOrient, frame.dfRMClipTex = nil, nil
    frame.dfRMClipL, frame.dfRMClipR, frame.dfRMClipT, frame.dfRMClipB = nil, nil, nil, nil
    if frame.missingHealthBar then
        DF:AnchorToHealthRect(frame.missingHealthBar, frame, l, r, t, b)
    end
end

-- Re-run the bars that measure the health bar's size, one frame later. A moved
-- anchor does not change GetWidth/GetHeight until the next draw, so re-running
-- them in the same tick would measure the old rect.
local pendingRefresh = {}
local function RefreshMeasuredBars()
    for frame in pairs(pendingRefresh) do
        pendingRefresh[frame] = nil
        frame.dfAbsorbState = nil
        if frame.dfIsTestFrame then
            -- Group test frames carry dfTestIndex; a unit frames preview (dfUFPreview)
            -- repaints with its own f.index, as Preview.lua's own health pass does.
            if DF.UpdateTestFrameHealthOnly and frame:IsShown()
                and (frame.dfTestIndex or frame.dfUFPreview) then
                DF:UpdateTestFrameHealthOnly(frame, frame.dfTestIndex or frame.index)
            end
        elseif frame.unit then
            if DF.UpdateAbsorb then DF:UpdateAbsorb(frame) end
            if DF.UpdateHealAbsorb then DF:UpdateHealAbsorb(frame) end
            if DF.UpdateHealPrediction then DF:UpdateHealPrediction(frame) end
        end
    end
end

-- ★ CALLED WHEN THE POWER BAR SHOWS, HIDES OR IS RE-LAID OUT (Frames/Bars.lua).
-- Cheap when nothing changed: four number compares and out. Only when this
-- frame's rect actually moves does it re-anchor, re-clip reduced max health
-- inside the new rect, and queue the measured bars (absorbs, heal prediction).
function DF:SyncHealthBarRect(frame, db)
    if not (frame and frame.healthBar) then return end
    db = db or DF:GetFrameDB(frame)
    if not db then return end
    local l, r, t, b = DF:GetHealthBarInsets(frame, db)
    if l == frame.dfHealthRectL and r == frame.dfHealthRectR
        and t == frame.dfHealthRectT and b == frame.dfHealthRectB then
        return
    end
    DF:AnchorHealthBarsToPadding(frame, db)
    -- The reduced-max strip nests inside the health rect: re-run it so its band and
    -- the clipped health edge follow the new rect.
    if frame.dfReducedMaxHealthBar and DF.UpdateReducedMaxHealth then
        DF:UpdateReducedMaxHealth(frame)
    end
    frame.dfAbsorbState = nil
    if C_Timer and C_Timer.After then
        local first = next(pendingRefresh) == nil
        pendingRefresh[frame] = true
        if first then C_Timer.After(0, RefreshMeasuredBars) end
    end
end
