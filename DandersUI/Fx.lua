local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- FX
-- Tiny shared fade/pop helpers for chrome that animates in and out (mover
-- session surfaces, the DF options window). Works on frames AND regions --
-- both are AnimatableObjects. Nothing here is load-bearing: every entry point
-- shows/hides the target immediately and only decorates that with an
-- animation, so a target whose CreateAnimationGroup is unavailable (headless
-- tests) or that gets Hidden mid-animation ends up in the right state anyway.
-- Instant paths (combat suspend, teardown) never come through here -- they
-- call plain Hide() and, if a fade might be running, Fx.Cancel.
--
-- Library-level, not per host: the helpers keep their state on the TARGET
-- (fxIn/fxOut/fxPop/fxPopOut/fxTo/fxScale animation groups), so there is nothing
-- host-specific to shadow.
-- ============================================================
local Fx = {}
UI.Fx = Fx

-- Fade the target in, optionally sliding onto its anchor from (ox, oy).
-- Forward, the group below is a fade-OUT that drifts by (ox, oy); played in
-- REVERSE it is exactly the entrance wanted -- alpha 0 -> 1 while the rendered
-- position slides from (ox, oy) back onto the anchor -- and when it finishes
-- the animation state reverts, leaving the target at its true point and alpha.
-- The anchor itself is never touched, so mid-animation Refreshes stay correct.
function Fx.FadeIn(target, dur, ox, oy)
    if not target then return end
    if target.fxOut and target.fxOut:IsPlaying() then target.fxOut:Stop() end
    if target.fxPopOut and target.fxPopOut:IsPlaying() then target.fxPopOut:Stop() end
    target:Show()
    target:SetAlpha(1)
    local g = target.fxIn
    if not g then
        g = target:CreateAnimationGroup()
        if not g then return end                    -- headless stub: shown, done
        g.alpha = g:CreateAnimation("Alpha")
        g.move  = g:CreateAnimation("Translation")
        target.fxIn = g
    end
    if g:IsPlaying() then g:Stop() end
    g.alpha:SetFromAlpha(1); g.alpha:SetToAlpha(0); g.alpha:SetDuration(dur or 0.12)
    g.move:SetOffset(ox or 0, oy or 0); g.move:SetDuration(dur or 0.12)
    g:Play(true)
end

-- Pop the target in from behind: alpha 0 -> 1 while the rendered position
-- slides from (ox, oy) onto its anchor AND the target scales up from
-- `fromScale` (default 0.92), the scale originating at `origin` -- the edge it
-- pops out from. Same reversed-group trick as FadeIn (the group below is a
-- fade-out that drifts and shrinks; played in REVERSE it is the entrance), so
-- the animation state reverts on finish and the target rests at its true
-- geometry. The forward smoothing is IN, which played in reverse is the
-- wanted ease-out.
function Fx.PopIn(target, dur, ox, oy, fromScale, origin)
    if not target then return end
    if target.fxOut and target.fxOut:IsPlaying() then target.fxOut:Stop() end
    if target.fxPopOut and target.fxPopOut:IsPlaying() then target.fxPopOut:Stop() end
    if target.fxIn and target.fxIn:IsPlaying() then target.fxIn:Stop() end
    target:Show()
    target:SetAlpha(1)
    local g = target.fxPop
    if not g then
        g = target:CreateAnimationGroup()
        if not g then return end                    -- headless stub: shown, done
        g.alpha = g:CreateAnimation("Alpha")
        g.move  = g:CreateAnimation("Translation")
        g.scale = g:CreateAnimation("Scale")
        target.fxPop = g
    end
    if g:IsPlaying() then g:Stop() end
    dur = dur or 0.12
    g.alpha:SetFromAlpha(1); g.alpha:SetToAlpha(0); g.alpha:SetDuration(dur)
    g.alpha:SetSmoothing("IN")
    g.move:SetOffset(ox or 0, oy or 0); g.move:SetDuration(dur)
    g.move:SetSmoothing("IN")
    local s = fromScale or 0.92
    -- Forward the group shrinks 1 -> s at the origin edge; reversed it grows
    -- s -> 1. Guarded for clients/stubs without the modern Scale setters.
    if g.scale.SetScaleFrom then g.scale:SetScaleFrom(1, 1); g.scale:SetScaleTo(s, s) end
    if g.scale.SetOrigin then g.scale:SetOrigin(origin or "CENTER", 0, 0) end
    g.scale:SetDuration(dur)
    g.scale:SetSmoothing("IN")
    g:Play(true)
end

-- The mirror of PopIn: fade out while the rendered position drifts by
-- (ox, oy) and the target scales DOWN to `toScale` (default 0.92) about
-- `origin`, then call onDone (which usually hides it). Pass PopIn's own
-- offsets and origin and the exit retraces the entrance backwards.
--
-- Played FORWARD, unlike PopIn -- a shrink-and-fade is what the group already
-- describes -- so the cancel semantics are FadeOut's, not PopIn's: a pop-out
-- that is interrupted (a PopIn/FadeIn takes over, or the target is hidden
-- mid-animation) restores alpha and SKIPS onDone, so a stale "hide it" cannot
-- land after the target was re-shown.
function Fx.PopOut(target, dur, ox, oy, toScale, origin, onDone)
    if not target or not target:IsShown() then
        if onDone then onDone() end
        return
    end
    if target.fxIn and target.fxIn:IsPlaying() then target.fxIn:Stop() end
    if target.fxPop and target.fxPop:IsPlaying() then target.fxPop:Stop() end
    if target.fxOut and target.fxOut:IsPlaying() then target.fxOut:Stop() end
    local g = target.fxPopOut
    if not g then
        g = target:CreateAnimationGroup()
        if not g then if onDone then onDone() end return end   -- headless stub: done
        g.alpha = g:CreateAnimation("Alpha")
        g.move  = g:CreateAnimation("Translation")
        g.scale = g:CreateAnimation("Scale")
        g.owner = target
        g:SetScript("OnFinished", function(s)
            s.owner:SetAlpha(1)
            local cb = s.onDone
            s.onDone = nil
            if cb then cb() end
        end)
        g:SetScript("OnStop", function(s)
            s.onDone = nil
            s.owner:SetAlpha(1)
        end)
        target.fxPopOut = g
    end
    if g:IsPlaying() then g:Stop() end
    dur = dur or 0.18
    g.onDone = onDone
    g.alpha:SetFromAlpha(1); g.alpha:SetToAlpha(0); g.alpha:SetDuration(dur)
    g.alpha:SetSmoothing("OUT")
    g.move:SetOffset(ox or 0, oy or 0); g.move:SetDuration(dur)
    g.move:SetSmoothing("OUT")
    local s = toScale or 0.92
    -- Guarded for clients/stubs without the modern Scale setters, as in PopIn.
    if g.scale.SetScaleFrom then g.scale:SetScaleFrom(1, 1); g.scale:SetScaleTo(s, s) end
    if g.scale.SetOrigin then g.scale:SetOrigin(origin or "CENTER", 0, 0) end
    g.scale:SetDuration(dur)
    g.scale:SetSmoothing("OUT")
    g:Play()
end

-- Fade the target out, then call onDone (which usually hides it). A fade that
-- is cancelled -- a FadeIn takes over, or the target is hidden mid-animation --
-- restores alpha and SKIPS onDone, so a stale "hide it" cannot fire after the
-- target was re-shown. An already-hidden target completes immediately.
function Fx.FadeOut(target, dur, onDone)
    if not target or not target:IsShown() then
        if onDone then onDone() end
        return
    end
    if target.fxIn and target.fxIn:IsPlaying() then target.fxIn:Stop() end
    if target.fxPop and target.fxPop:IsPlaying() then target.fxPop:Stop() end
    if target.fxPopOut and target.fxPopOut:IsPlaying() then target.fxPopOut:Stop() end
    local g = target.fxOut
    if not g then
        g = target:CreateAnimationGroup()
        if not g then if onDone then onDone() end return end
        g.alpha = g:CreateAnimation("Alpha")
        g.owner = target
        g:SetScript("OnFinished", function(s)
            s.owner:SetAlpha(1)
            local cb = s.onDone
            s.onDone = nil
            if cb then cb() end
        end)
        g:SetScript("OnStop", function(s)
            s.onDone = nil
            s.owner:SetAlpha(1)
        end)
        target.fxOut = g
    end
    if g:IsPlaying() then g:Stop() end
    g.onDone = onDone
    g.alpha:SetFromAlpha(1); g.alpha:SetToAlpha(0); g.alpha:SetDuration(dur or 0.1)
    g:Play()
end

-- Fade the target to a RESTING alpha and leave it there (unlike FadeIn/
-- FadeOut, which always rest at 1 / hidden). The rest value is set at once --
-- the animation only decorates the transition, so a stub without animation
-- groups still lands on the right alpha. Callers pair it with a later
-- FadeTo(target, 1) to restore; used by the mover's Alt-peek.
function Fx.FadeTo(target, alpha, dur)
    if not target then return end
    if target.fxIn and target.fxIn:IsPlaying() then target.fxIn:Stop() end
    if target.fxPop and target.fxPop:IsPlaying() then target.fxPop:Stop() end
    if target.fxOut and target.fxOut:IsPlaying() then target.fxOut:Stop() end
    if target.fxPopOut and target.fxPopOut:IsPlaying() then target.fxPopOut:Stop() end
    local from = target:GetAlpha() or 1
    target:SetAlpha(alpha)
    local g = target.fxTo
    if not g then
        g = target:CreateAnimationGroup()
        if not g then return end
        g.alpha = g:CreateAnimation("Alpha")
        target.fxTo = g
    end
    if g:IsPlaying() then g:Stop() end
    g.alpha:SetFromAlpha(from); g.alpha:SetToAlpha(alpha); g.alpha:SetDuration(dur or 0.1)
    g:Play()
end

-- Scale the target to a RESTING scale and leave it there -- the scale sibling of
-- FadeTo, and like FadeTo it rests wherever it is put rather than always coming
-- back to 1. The rest value is taken at once (SetScale), so a stub or a client
-- without the modern Scale setters still lands on the right size; the animation
-- only decorates the transition. Hover "lift" affordances pair
-- ScaleTo(btn, 1.15) on enter with ScaleTo(btn, 1) on leave.
--
-- ⚠ FRAMES ONLY. Textures have no SetScale, so a region caller is a no-op here
-- (deliberately silent -- everything else in this file works on both).
--
-- ☠ A scaled frame moves whatever is anchored TO it: anchor offsets resolve in
-- screen space, so a neighbour pinned to a lifted button's edge jitters with it.
-- Anchor the neighbours to the ROW, not to the thing that lifts.
function Fx.ScaleTo(target, scale, dur)
    if not target or not target.SetScale then return end
    local from = target:GetScale() or 1
    target:SetScale(scale)
    if from == scale then return end
    local g = target.fxScale
    if not g then
        g = target:CreateAnimationGroup()
        if not g then return end                    -- headless stub: sized, done
        g.scale = g:CreateAnimation("Scale")
        target.fxScale = g
    end
    if g:IsPlaying() then g:Stop() end
    -- A Scale animation MULTIPLIES the region's own scale and its state reverts
    -- on finish, so the ratio below runs the RENDERED scale from `from` back up
    -- to the rest value SetScale just took, and leaves it there.
    local ratio = from / scale
    if g.scale.SetScaleFrom then g.scale:SetScaleFrom(ratio, ratio); g.scale:SetScaleTo(1, 1) end
    if g.scale.SetOrigin then g.scale:SetOrigin("CENTER", 0, 0) end
    g.scale:SetDuration(dur or 0.08)
    g.scale:SetSmoothing("OUT")
    g:Play()
end

-- Move the target to a new RESTING position and leave it there -- the position
-- sibling of FadeTo and ScaleTo, and like them it rests wherever it is put
-- rather than always coming home to one value.
--
-- `place` is a function that RE-ANCHORS the target (ClearAllPoints + SetPoint);
-- it is handed the target and is called IMMEDIATELY, so a stub or a client that
-- cannot animate still lands on the right anchors and the animation only
-- decorates the trip. The rendered position is measured either side of that
-- call and a Translation runs the target from where it WAS back to zero, so the
-- glide is purely visual: the anchors are already correct the moment place()
-- returns, and a Refresh mid-glide stays correct. Same reversed-group trick as
-- FadeIn -- forward the group is a drift AWAY by the delta, played in REVERSE it
-- is the arrival -- so the animation state reverts on finish and the target
-- rests at its true point. Forward smoothing is IN, which reversed is the
-- wanted ease-out.
--
-- ⚠ FRAMES ONLY, by the same rule ScaleTo states: a region has no frame level to
-- lift it over the members it marks, and every caller so far is a frame. It does
-- not error on a region -- it simply has not been designed against one.
--
-- ⚠ NEEDS RESOLVED ANCHORS AT BOTH ENDS. A target whose parent has never laid
-- out answers nil to GetLeft, and then it simply lands instantly. That is the
-- right answer, not a failure: there is no visible "from" to glide out of.
function Fx.MoveTo(target, place, dur)
    if not target or not place then return end
    local fromX, fromY = target:GetLeft(), target:GetBottom()
    place(target)
    local g = target.fxMove
    if g and g:IsPlaying() then g:Stop() end
    if not (fromX and fromY) then return end
    local toX, toY = target:GetLeft(), target:GetBottom()
    if not (toX and toY) then return end
    local dx, dy = fromX - toX, fromY - toY
    if dx == 0 and dy == 0 then return end
    if not g then
        g = target:CreateAnimationGroup()
        if not g then return end                    -- headless stub: anchored, done
        g.move = g:CreateAnimation("Translation")
        target.fxMove = g
    end
    g.move:SetOffset(dx, dy)
    g.move:SetDuration(dur or 0.12)
    g.move:SetSmoothing("IN")
    g:Play(true)
end

-- Stop any running fade and restore the resting alpha. For paths that must be
-- instant (combat suspend, teardown). The resting SCALE and POSITION are left
-- alone: unlike alpha, both are the caller's state (ScaleTo and MoveTo rest
-- where they are put), so a Cancel that forced them back would silently undo a
-- deliberate size or a deliberate anchor.
function Fx.Cancel(target)
    if not target then return end
    if target.fxIn and target.fxIn:IsPlaying() then target.fxIn:Stop() end
    if target.fxPop and target.fxPop:IsPlaying() then target.fxPop:Stop() end
    if target.fxOut and target.fxOut:IsPlaying() then target.fxOut:Stop() end
    if target.fxPopOut and target.fxPopOut:IsPlaying() then target.fxPopOut:Stop() end
    if target.fxTo and target.fxTo:IsPlaying() then target.fxTo:Stop() end
    if target.fxScale and target.fxScale:IsPlaying() then target.fxScale:Stop() end
    if target.fxMove and target.fxMove:IsPlaying() then target.fxMove:Stop() end
    target:SetAlpha(1)
end
