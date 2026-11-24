local addonName, DF = ...

-- ============================================================
-- HEALTH BAR RECT
-- The ONE place that decides where the health bar sits inside its frame.
-- Every site that anchors the health bar asks this file: frame creation
-- (Frames/Create.lua), every layout pass (DF:AnchorHealthBarsToPadding, called
-- by the live update, the test-mode update and the resize path), the reduced
-- max health strip (Frames/ReducedMaxHealth.lua), the dispel gradient
-- (Features/Dispel.lua) and the resource bar layout (Frames/Bars.lua).
--
-- The rect is the frame minus framePadding on every side (or minus the frame
-- border band with Keep Health Bar Inside Border). A resource bar Placement strip
-- (Below / Above / Left of / Right of Health Bar) running ALONG the fill leaves the
-- rect whole and is cut out of the health bar instead (DF:SyncResourceBarHole,
-- Frames/Bars.lua); one ACROSS the fill takes its side, the health bar stopping at
-- the strip's inner edge (DF:GetResourceBarCutEdge says why). On Top of Health Bar
-- (the default) draws the bar over a full-size health bar.
-- Two rects come out of here: where the health bar SITS (DF:GetHealthBarInsets) and
-- where health is SEEN (DF:GetHealthVisibleInsets, the strip's side always taken),
-- which is what the dispel wash keeps to.
--
-- Only plain (non-secure) regions are anchored here -- the health bar, the
-- missing-health bar and the reduced-max strip -- so none of it is blocked in
-- combat and none of it needs an InCombatLockdown() guard. Keep it that way:
-- anything secure added here has to be guarded.
-- ============================================================

local math_max = math.max

-- The frame edge the resource bar's Placement gives it a strip along, or nil while it is
-- drawn on top of the health bar. A detached bar (unit frames) sits outside the frame and
-- has no strip. Without a frame it answers for the settings alone, which is what the
-- options page greys its controls by. The one test the health rect, the resource bar
-- layout and its frame level all ask, so they can never disagree about whether the strip
-- exists. The edge is the Placement itself, whatever the bar's Orientation: the strip's
-- shape comes from its side, the fill direction from the Orientation.
function DF:GetResourceBarRoomEdge(db, frame)
    if not (db and db.resourceBarEnabled) then return nil end
    local p = db.resourceBarPlacement
    if p ~= "BOTTOM" and p ~= "TOP" and p ~= "LEFT" and p ~= "RIGHT" then return nil end
    if frame then
        if DF.IsResourceBarDetached and DF:IsResourceBarDetached(frame, db) then return nil end
    elseif db.resourceBarDetached then
        -- Settings alone: only a unit frame's table carries this key (its Detach card), so
        -- this greys the Placement controls on a unit page with the bar detached.
        return nil
    end
    return p
end

-- Whether a strip on `side` runs along the health fill rather than across it.
local function RunsAlongFill(db, side)
    local o = db.healthOrientation
    if o == "VERTICAL" or o == "VERTICAL_INV" then return side == "LEFT" or side == "RIGHT" end
    return side == "TOP" or side == "BOTTOM"
end

-- The Placement side whose strip is CUT out of the health bar, or nil.
-- ★ ALONG THE FILL (Below / Above a horizontal bar, Left / Right of a vertical one) THE
-- STRIP IS CUT, NOT MADE ROOM FOR. The health bar keeps its full rect, so a see-through
-- frame border lies over health on every side and tints it evenly; made room for, the
-- border beside the strip lies over the frame background and reads as a different colour.
-- The fill still reads end to end beside the strip.
-- ☠ ACROSS THE FILL THE STRIP SITS AT ONE OF ITS ENDS, so a cut would hide that end of the
-- health range: a unit at 90% would read full, or low health would vanish under the strip.
-- That side takes the strip's room instead (DF:GetHealthBarInsets).
function DF:GetResourceBarCutEdge(db, frame)
    local side = DF:GetResourceBarRoomEdge(db, frame)
    if side and RunsAlongFill(db, side) then return side end
    return nil
end

-- "Keep Health Bar Inside Border": the health bar stops at the frame border's inner edge
-- on every side instead of running under it, so a see-through border -- which has no
-- colour of its own and tints whatever is under it -- sits over the frame background
-- rather than over health. The resource bar follows (strip and matched ends), since a
-- bar inside a border the health bar sits inside of would otherwise poke under it.
function DF:BarsInsideFrameBorder(db)
    return (db and db.healthInsideFrameBorder and db.frameShowBorder ~= false) and true or false
end

-- The frame border band's depth, max'd with the padding -- max, not sum, as for a matched
-- bar's ends (the sliver note in DF:LayoutResourceBar) -- pixel-perfect snapped like the border.
function DF:GetFrameBorderBandInset(db)
    local pad = db.framePadding or 0
    local border = db.frameBorderSize or 1
    if db.pixelPerfect and DF.PixelPerfect then
        pad = DF:PixelPerfect(pad)
        border = DF:PixelPerfect(border)
    end
    return math_max(pad, border)
end

-- How far a Placement strip sits in from its frame edge: the frame padding, or the frame
-- border band when the bar is kept inside the border (Adjust For Frame Border, or the
-- health bar's Keep Inside Border). Pixel-perfect snapped, the numbers the bar is placed with.
function DF:GetResourceBarStripInset(db)
    local showBorder = db.frameShowBorder ~= false
    if showBorder and (db.resourceBarMatchAdjustFrameBorder or DF:BarsInsideFrameBorder(db)) then
        return DF:GetFrameBorderBandInset(db)
    end
    local pad = db.framePadding or 0
    if db.pixelPerfect and DF.PixelPerfect then pad = DF:PixelPerfect(pad) end
    return pad
end

-- Whether the frame is MEANT to carry a resource bar (enabled, unit, role / class / solo
-- gates), recorded wherever DF decides it: the live update, UpdatePower, the resource bar
-- layout and the test / preview update.
-- ★ THE RECT KEYS ON THIS, NOT ON THE BAR BEING SHOWN. Death, disconnects and secret power
-- hide the bar for a moment; following those would flash the health bar into the strip
-- and back on every death and rez.
function DF:NoteResourceBarWanted(frame, wanted)
    if frame then frame.dfResourceBarWanted = wanted and true or false end
end

-- How far a Placement strip's INNER edge sits from the frame edge it runs along: its seat
-- inset, plus thickness, plus the strip offset that pushes it inward (a positive Y for a
-- bottom strip, a negative Y for a top strip, the same with X for left / right). An
-- outward offset is negative and reduces it. The offset ALONG the side does not move it.
-- ☠ SNAP EXACTLY WHAT Bars.lua SNAPS, NO MORE: the strip is ppThickness deep, seated at
-- the snapped strip inset plus the RAW offset. Snapping the total as well put the health
-- bar's edge one pixel off the bar's whenever the offset was not a whole pixel.
local function StripInnerEdge(db, side)
    local thickness = tonumber(db.resourceBarHeight) or 4
    if db.pixelPerfect and DF.PixelPerfect then thickness = DF:PixelPerfect(thickness) end
    local inward
    if side == "BOTTOM" then inward = tonumber(db.resourceBarStripY) or 0
    elseif side == "TOP" then inward = -(tonumber(db.resourceBarStripY) or 0)
    elseif side == "LEFT" then inward = tonumber(db.resourceBarStripX) or 0
    else inward = -(tonumber(db.resourceBarStripX) or 0) end
    return DF:GetResourceBarStripInset(db) + thickness + inward
end

-- Insets from the frame's LEFT, RIGHT, TOP and BOTTOM edges, in that order (every caller
-- unpacks l, r, t, b).
-- Base: framePadding on every side, or the border band with Keep Health Bar Inside Border.
-- ★ THE STRIP RULE: on the side of a strip ACROSS the fill (and of any strip, for
-- `visible`) the inset is
--     max(base, strip inset + thickness + inward offset)
-- i.e. the health bar ends exactly where the strip ends, with no gap and no overlap,
-- wherever the strip is pushed. max() keeps the base when the strip is pushed OUT past
-- the frame far enough that it no longer reaches it. A shorter strip (Match off) still
-- takes the WHOLE side: the gap beside it shows the frame background, never health that
-- the strip would half-cover. The health bar always keeps at least 1 unit across.
-- A strip ALONG the fill leaves the side at base: it is cut out of the bar instead.
--
-- PER FRAME: only while THIS frame wants a bar (DF:NoteResourceBarWanted) -- role and
-- class filters and solo mode decide that; a frame that never shows one keeps the whole
-- health bar.
--
-- ☠ HOT PATH: ReducedMaxHealth calls this on every health tick. No allocation.
local function Insets(frame, db, visible)
    local base = (db and db.framePadding) or 0
    if DF:BarsInsideFrameBorder(db) then base = DF:GetFrameBorderBandInset(db) end
    local l, r, t, b = base, base, base, base
    if not (frame and frame.dfResourceBarWanted) then return l, r, t, b end
    local side = DF:GetResourceBarRoomEdge(db, frame)
    if not side then return l, r, t, b end
    if not visible and RunsAlongFill(db, side) then return l, r, t, b end

    local edge = math_max(base, StripInnerEdge(db, side))
    -- Never collapse the health bar: leave it at least 1 unit across.
    if side == "TOP" or side == "BOTTOM" then
        local h = frame.dfPinnedHeight or db.frameHeight or 50
        local limit = h - base - 1
        if edge > limit then edge = math_max(base, limit) end
        if side == "TOP" then t = edge else b = edge end
    else
        local w = frame.dfPinnedWidth or db.frameWidth or 120
        local limit = w - base - 1
        if edge > limit then edge = math_max(base, limit) end
        if side == "LEFT" then l = edge else r = edge end
    end
    return l, r, t, b
end

-- Where the health bar sits.
function DF:GetHealthBarInsets(frame, db)
    return Insets(frame, db, false)
end

-- Where health is seen: the strip's side taken even where the strip is cut out of the bar.
function DF:GetHealthVisibleInsets(frame, db)
    return Insets(frame, db, true)
end

-- How far past the health bar's `side` edge a Placement strip reaches: from the health
-- bar's edge out to the strip's OUTER edge, or 0 when no strip sits on that side.
-- ★ FOR OVERFLOW (Frames/Bars.lua MaskBarToBreakoutStrip). The absorb / heal "breakout"
-- runs past the health bar's max-health end. With the strip at that end (Right of Health
-- Bar with left-to-right fill, Above with bottom-to-top, ...) its first stretch would lie
-- under -- or, with a low strip Frame Level, over -- the resource bar. The breakout skips
-- this much, so it reads on the same ruler and simply starts again past the strip.
function DF:GetResourceStripReachPast(frame, db, side)
    if not (frame and frame.dfResourceBarWanted) then return 0 end
    if DF:GetResourceBarRoomEdge(db, frame) ~= side then return 0 end
    local healthEdge
    if side == "LEFT" then healthEdge = frame.dfHealthRectL
    elseif side == "RIGHT" then healthEdge = frame.dfHealthRectR
    elseif side == "TOP" then healthEdge = frame.dfHealthRectT
    else healthEdge = frame.dfHealthRectB end
    if not healthEdge then return 0 end
    local thickness = tonumber(db.resourceBarHeight) or 4
    if db.pixelPerfect and DF.PixelPerfect then thickness = DF:PixelPerfect(thickness) end
    local outer = StripInnerEdge(db, side) - thickness
    local reach = healthEdge - outer
    return reach > 0 and reach or 0
end

-- Anchor a region to the health rect.
function DF:AnchorToHealthRect(region, frame, l, r, t, b)
    region:ClearAllPoints()
    region:SetPoint("TOPLEFT", frame, "TOPLEFT", l, -t)
    region:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -r, b)
end

-- ★ THE LAYOUT PASS. Puts the health bar (and the missing-health overlay, which
-- covers the same area) on the current rect, and remembers the rect so
-- DF:SyncHealthBarRect can tell when it has to move.
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
    frame.dfHealthVisL, frame.dfHealthVisR, frame.dfHealthVisT, frame.dfHealthVisB =
        DF:GetHealthVisibleInsets(frame, db)
    if DF.SyncResourceBarHole then DF:SyncResourceBarHole(frame, db) end
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

-- ★ CALLED WHEN THE RESOURCE BAR IS RE-LAID OUT OR ITS "WANTED" ANSWER FLIPS
-- (Frames/Bars.lua, UpdatePower, the border drag). Cheap when nothing changed: a compare
-- per cut bar and four number compares, and out. Only when this
-- frame's rect actually moves does it re-anchor, re-clip reduced max health
-- inside the new rect, and queue the measured bars (absorbs, heal prediction).
function DF:SyncHealthBarRect(frame, db)
    if not (frame and frame.healthBar) then return end
    db = db or DF:GetFrameDB(frame)
    if not db then return end
    -- A cut strip leaves the rect where it is, so the cut is synced before the early out.
    if DF.SyncResourceBarHole then DF:SyncResourceBarHole(frame, db) end
    -- ☠ THE SEEN RECT TOO, before the early out. A cut strip never moves the rect, so a
    -- strip slider drag or a "wanted" flip would return below with the seen rect stale,
    -- and the dispel wash (which keys its layout cache on it) would keep the old shape.
    frame.dfHealthVisL, frame.dfHealthVisR, frame.dfHealthVisT, frame.dfHealthVisB =
        DF:GetHealthVisibleInsets(frame, db)
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
