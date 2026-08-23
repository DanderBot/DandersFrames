local addonName, NS = ...

-- ============================================================
-- FX
-- Tiny shared fade helpers for the session chrome (the panel, the floating
-- title pills). Works on frames AND regions -- both are AnimatableObjects.
-- Nothing here is load-bearing: every entry point shows/hides the target
-- immediately and only decorates that with an animation, so a target whose
-- CreateAnimationGroup is unavailable (headless tests) or that gets Hidden
-- mid-animation ends up in the right state anyway. Combat suspension never
-- comes through here -- Suspend() hides instantly via plain Hide().
-- ============================================================
local Fx = {}
NS.Fx = Fx

-- Fade the target in, optionally sliding onto its anchor from (ox, oy).
-- Forward, the group below is a fade-OUT that drifts by (ox, oy); played in
-- REVERSE it is exactly the entrance wanted -- alpha 0 -> 1 while the rendered
-- position slides from (ox, oy) back onto the anchor -- and when it finishes
-- the animation state reverts, leaving the target at its true point and alpha.
-- The anchor itself is never touched, so mid-animation Refreshes stay correct.
function Fx.FadeIn(target, dur, ox, oy)
    if not target then return end
    if target.fxOut and target.fxOut:IsPlaying() then target.fxOut:Stop() end
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

-- Stop any running fade and restore the resting alpha. For paths that must be
-- instant (combat suspend, teardown).
function Fx.Cancel(target)
    if not target then return end
    if target.fxIn and target.fxIn:IsPlaying() then target.fxIn:Stop() end
    if target.fxPop and target.fxPop:IsPlaying() then target.fxPop:Stop() end
    if target.fxOut and target.fxOut:IsPlaying() then target.fxOut:Stop() end
    target:SetAlpha(1)
end
