local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- POPOUT
-- A small panel that DOCKS BESIDE A THING: it picks the side that fits, follows
-- the thing while it moves, and can be pinned loose.
--
-- CONNECTED, then DETACHED. While it FOLLOWS, the popout, the thing and the gap
-- between them are drawn as one object: a 1px accent border on the popout, the
-- same border laid over the source, a small accent diamond -- the connection
-- point -- on the edge the popout docked against, and a short beam across the
-- gap joining the two. PIN it and every one of those goes: pinning is the
-- gesture that says "this is its own window now", and it should look like it.
--
-- Host-bound, like every factory here: `host:CreatePopout(opts)`. The shell
-- knows nothing about what it contains or what closing it MEANS -- the consumer
-- mounts widgets in `build` and decides in `onClose`. Nothing in this file may
-- name a consumer, and it owns no saved state of its own.
--
-- POOLING. Per host+key there is ONE unpinned popout. Asking for a key that
-- already has one hands the same object back, re-targeted, WITHOUT re-running
-- build -- so a popout that opens on every selection costs one frame, not one
-- per selection. Pin() promotes an instance out of the pool (it keeps the
-- content it was built with) and the next request for that key builds a fresh
-- one. `build` is therefore re-runnable by construction: per-instance state
-- belongs on the popout object, never in a file-scope local.
--
-- ⚠ A popout is built HIDDEN. Placement is what presents it -- Follow(region)
-- or PlaceFree(x, y) -- because the entrance pops out of the edge it docks
-- against, and that edge is not known until it has something to dock to.
-- ============================================================
local CreateFrame, UIParent, C_Timer = CreateFrame, UIParent, C_Timer
local setmetatable, rawget, rawset, type, error = setmetatable, rawget, rawset, type, error
local ipairs, pairs, xpcall, geterrorhandler = ipairs, pairs, xpcall, geterrorhandler
local tinsert, tremove = table.insert, table.remove
local min, max, abs = math.min, math.max, math.abs

local Fx = UI.Fx

local PAD        = 10        -- outer inset around the content
local TITLE_H    = 22        -- the title bar strip
local DOCK_GAP   = 12        -- popout <-> source distance when docked
local ADJ_GAP    = 16        -- "still beside it" slack, for UI.PopoutIsAdjacent
local POP_DUR    = 0.22      -- entrance
local OUT_DUR    = 0.18      -- exit, the entrance run backwards
-- The retarget glide: long enough that the eye follows the SAME panel across to
-- the new thing, short enough that a run of selections never queues up. Below
-- ~0.12 it reads as a teleport again; above ~0.25 clicking down a list feels
-- like waiting for the panel.
local GLIDE_DUR  = 0.18
local PIN_DUR    = 0.12      -- the little confirm pop when pinning by hand
local BEAM_DUR   = 0.15      -- beam fade in / out
local CLOSE_SIZE = 18
local PIN_SIZE   = 14
local ICON_SIZE  = 14
-- The connection point: a small accent diamond centred on the edge the popout
-- docked against, half of it proud of the border. 10 is the size at which the
-- tip still reads as a POINT against a 2-device-pixel border without becoming a
-- shape in its own right. Square corners everywhere -- the popout's border, the
-- source outline and this notch are all straight lines, so the three read as one
-- piece of chrome rather than three decorations.
local NOTCH_SIZE = 10
-- Two layered lines, not one: a wide soft under-glow so the beam reads over
-- busy art, and a thin bright core so it still reads as a LINE.
local BEAM_GLOW_W, BEAM_GLOW_A = 5, 0.15
local BEAM_CORE_W, BEAM_CORE_A = 3, 0.55

-- ============================================================
-- PURE GEOMETRY
-- Deliberately free of frames and of host state so the docking and beam rules
-- can be tested head-on rather than inferred from where a frame ended up.
-- Rects are CENTRE-BASED and in UIParent-centre units: { x, y, w, h }.
-- ============================================================

-- Candidate positions beside a source rect, in tie-break priority order.
-- right/left hang from the source's TOP edge (a popout reads as a continuation
-- of the thing's header); above/below centre on it.
local function dockCandidates(src, w, h, gap)
    local top = src.y + src.h / 2
    return {
        { side = "right", x = src.x + src.w / 2 + gap + w / 2, y = top - h / 2 },
        { side = "left",  x = src.x - src.w / 2 - gap - w / 2, y = top - h / 2 },
        { side = "below", x = src.x, y = src.y - src.h / 2 - gap - h / 2 },
        { side = "above", x = src.x, y = src.y + src.h / 2 + gap + h / 2 },
    }
end

-- The side to dock on: the first candidate that fits FULLY on screen, in
-- priority order. Obstacle awareness is deliberately not modelled -- the shell
-- has no idea what else is on screen, and a consumer that does can force a side
-- through Follow's opts. nil when nothing fits; the caller flips on the screen
-- edge instead.
--
-- Exposed on the library (not on a host) because it is a pure function of its
-- arguments and both the popout and its tests want it.
function UI.PopoutPickSide(src, w, h, gap, screenW, screenH)
    local halfW, halfH = screenW / 2, screenH / 2
    for _, c in ipairs(dockCandidates(src, w, h, gap or DOCK_GAP)) do
        if c.x - w / 2 >= -halfW and c.x + w / 2 <= halfW
        and c.y - h / 2 >= -halfH and c.y + h / 2 <= halfH then
            return c.side
        end
    end
    return nil
end

-- Where a popout of (w, h) sits when docked on `side` of `src`, in the same
-- units -- i.e. the centre the SetPoint in _Dock resolves to. Its own function
-- because the retarget glide has to know the destination BEFORE it gets there,
-- and re-deriving it from the anchor would be re-deriving it from the answer.
-- nil for an unknown side.
function UI.PopoutDockPos(src, side, w, h, gap)
    if not (src and side) then return nil end
    for _, c in ipairs(dockCandidates(src, w, h, gap or DOCK_GAP)) do
        if c.side == side then return c.x, c.y end
    end
    return nil
end

-- "Still beside it": the two rects are within `gap` of touching on BOTH axes.
-- A docked popout sits DOCK_GAP from its source and overlaps it on the other
-- axis, so it passes; drag it away and it stops passing.
--
-- ⚠ NOTHING IN THE SHELL ASKS THIS ANY MORE. It was the beam's gate while the
-- beam meant "strayed"; now the beam means "joined" and is a function of
-- `following` alone (see _UpdateBeam). Kept because it is published geometry a
-- consumer can reasonably want -- but it is not load-bearing here, so do not
-- reason about the beam from it.
function UI.PopoutIsAdjacent(a, b, gap)
    if not a or not b then return false end
    gap = gap or ADJ_GAP
    local dx = max(abs(a.x - b.x) - (a.w + b.w) / 2, 0)
    local dy = max(abs(a.y - b.y) - (a.h + b.h) / 2, 0)
    return dx <= gap and dy <= gap
end

-- Rect of a region in UIParent-centre units; nil while it has no geometry yet.
local function rectOf(region)
    if not region or not region.GetCenter then return nil end
    local cx, cy = region:GetCenter()
    if not cx then return nil end
    local ux, uy = UIParent:GetCenter()
    return { x = cx - ux, y = cy - uy, w = region:GetWidth() or 0, h = region:GetHeight() or 0 }
end

-- Per dock side: the popout's OWN edge that faces the source, and the outward
-- unit direction from it. The connection point is centred on that edge and the
-- beam leaves from its tip, so both re-side for free when the dock flips.
local NOTCH_SIDE = {
    right = { "LEFT",   -1,  0 },
    left  = { "RIGHT",   1,  0 },
    below = { "TOP",     0,  1 },
    above = { "BOTTOM",  0, -1 },
}

-- The tip of the connection point, in UIParent-centre units: the outer vertex of
-- the diamond sitting half-proud of the popout's source-facing edge. nil for a
-- popout with no dock side (PlaceFree), which has nothing to point at.
--
-- Exposed on the library for the same reason PopoutPickSide is: it is a pure
-- function of its arguments and both the beam and its tests want it.
function UI.PopoutNotchTip(pr, side, size)
    local spec = pr and side and NOTCH_SIDE[side]
    if not spec then return nil end
    size = size or NOTCH_SIZE
    return pr.x + spec[2] * (pr.w / 2 + size / 2),
           pr.y + spec[3] * (pr.h / 2 + size / 2)
end

-- The point on `r`'s outline closest to (px, py). For a point OUTSIDE the rect
-- -- which the connection point's tip always is, sitting across the dock gap --
-- clamping onto the rect lands on its perimeter, which is where the beam wants
-- to arrive: the face that is actually looking back at it.
function UI.PopoutNearestOnRect(r, px, py)
    if not r then return nil end
    return min(max(px, r.x - r.w / 2), r.x + r.w / 2),
           min(max(py, r.y - r.h / 2), r.y + r.h / 2)
end

-- {r,g,b[,a]} or {[1],[2],[3][,4]} -> a plain {r,g,b,a}; nil for anything else.
local function normColor(c)
    if type(c) ~= "table" then return nil end
    local r, g, b = c.r or c[1], c.g or c[2], c.b or c[3]
    if not (r and g and b) then return nil end
    return { r = r, g = g, b = b, a = c.a or c[4] or 1 }
end

-- The entrance drift and scale origin for a dock side: the popout pops out of
-- (and back into) the edge it is docked against. Shared by the entrance and the
-- exit so closing is the opening run backwards.
local function dockFx(side)
    if side == "right" then return -8, 0, "LEFT"
    elseif side == "left" then return 8, 0, "RIGHT"
    elseif side == "below" then return 0, 8, "TOP"
    elseif side == "above" then return 0, -8, "BOTTOM" end
    return 0, 0, "CENTER"
end

-- C_Timer with a synchronous fallback. Headless (and any client without the
-- timer API) still gets the SEQUENCE right -- beam out, then pop out -- it just
-- gets it all in one frame.
local function after(delay, fn)
    if C_Timer and C_Timer.After then return C_Timer.After(delay, fn) end
    fn()
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return end
    local a, b = ...
    xpcall(function() return fn(a, b) end, geterrorhandler())
end

-- ============================================================
-- PER-HOST STORE
-- The pool and the family registry are HOST state, not library state: two
-- consumers may both use the key "aura" and must not collide. rawget/rawset,
-- because a host's __index is the library and a plain read would find the
-- library's field (or another host's) instead of the host's own.
-- ============================================================
local function storeFor(host)
    local s = rawget(host, "_popouts")
    if not s then
        s = { pooled = {}, live = {} }
        rawset(host, "_popouts", s)
    end
    return s
end

-- ============================================================
-- THE POPOUT OBJECT
-- ============================================================
local Popout = {}
local popoutMeta = { __index = Popout }

-- ---- placement ---------------------------------------------------

-- Dock beside `region`. opts.side forces a side ("left"/"right"/"above"/
-- "below"); without it the side is picked by what fits. Re-docks for free
-- whenever the region moves -- see _Tick.
--
-- RETARGETING a popout that is already up (a different region while it is
-- following) GLIDES it across instead of teleporting: see _StartGlide.
function Popout:Follow(region, opts)
    if not region then return end
    local prev = self.source
    self.source = region
    self.forcedSide = opts and opts.side or nil
    self.free = false
    -- A pinned popout has been taken off its leash by hand; re-pointing its
    -- SOURCE (so the beam knows where to land) must not drag it back to it.
    if self.pinned then
        self:_UpdateBeam()
        return self
    end
    -- Already up and being pointed at something ELSE. _StartGlide answers false
    -- if it cannot work out where it is or where it is going, and then this
    -- falls through to the plain dock rather than refusing to move.
    if self.following and prev and prev ~= region and self.frame:IsShown()
       and self:_StartGlide() then
        return self
    end
    self.following = true
    self:_Dock()
    return self
end

-- Absolute placement, for consumers that own their own layout. No source, so
-- nothing to follow and nothing to tether to.
function Popout:PlaceFree(x, y)
    self.free = true
    self.following = false
    self.gliding = false
    local f = self.frame
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", x or 0, y or 0)
    self:_Present("CENTER")
    return self
end

-- The side this popout would dock on for a source rect of `sr`: the consumer's
-- forced side, else whatever fits, else the screen-edge flip. Shared by the dock
-- and the glide so the two cannot disagree about where the panel belongs.
function Popout:_PickSide(sr, w, h)
    local side = self.forcedSide
    if not side then
        side = UI.PopoutPickSide(sr, w, h, DOCK_GAP,
                                 UIParent:GetWidth() or 0, UIParent:GetHeight() or 0)
        -- Nothing fits: flip onto whichever side of the screen has more room,
        -- and let SetClampedToScreen deal with the overhang.
        if not side then side = (sr.x > 0) and "left" or "right" end
    end
    return side
end

function Popout:_Dock()
    local f, src = self.frame, self.source
    local sr = rectOf(src)
    if not sr then return end
    -- Anchoring to the source is the END of a glide by definition: from here the
    -- frame moves because the source does, not because we are driving it.
    self.gliding = false
    self._gX, self._gY = nil, nil
    -- The ticker's baseline is taken HERE, not on the first tick: without it the
    -- very next frame would read "the source moved" and re-dock for nothing.
    self._srcX, self._srcY, self._srcW, self._srcH = sr.x, sr.y, sr.w, sr.h
    local side = self:_PickSide(sr, f:GetWidth() or 0, f:GetHeight() or 0)
    f:ClearAllPoints()
    if side == "left" then f:SetPoint("TOPRIGHT", src, "TOPLEFT", -DOCK_GAP, 0)
    elseif side == "below" then f:SetPoint("TOP", src, "BOTTOM", 0, -DOCK_GAP)
    elseif side == "above" then f:SetPoint("BOTTOM", src, "TOP", 0, DOCK_GAP)
    else f:SetPoint("TOPLEFT", src, "TOPRIGHT", DOCK_GAP, 0) end
    self.side = side
    self:_Present(side)
end

-- Show it if it is not already up. The entrance is only ever played ONCE per
-- open: _Dock runs on every source move and a pop per move would be a strobe.
function Popout:_Present(side)
    local f = self.frame
    self:_Resize()
    -- A pooled popout can be revived DURING its own close fade (cross, then
    -- reselect inside OUT_DUR). The frame is still shown then, but the pop-out's
    -- deferred "hide when done" is live -- without a fresh entrance it would
    -- land on the reopened popout and swallow it. PopIn stops the pop-out group,
    -- whose OnStop clears that callback. In-game-only path: the headless stub
    -- has no animation groups, so the flag below is never set there.
    local closing = f.fxPopOut and f.fxPopOut.IsPlaying and f.fxPopOut:IsPlaying()
    if not f:IsShown() or closing then
        local ox, oy, origin = dockFx(side)
        if Fx then Fx.PopIn(f, POP_DUR, ox, oy, 0.92, origin) end
        f:Show()
        self._popDur = POP_DUR      -- the beam waits this long before fading in
    end
    self:_StartTick()
    self:_UpdateNotch()
    self:_UpdateBeam()
    self:_UpdateSourceOutline()
end

-- Height follows the content the consumer mounted; width was fixed at build.
function Popout:_Resize()
    local h = self.content:GetHeight() or 0
    self.frame:SetHeight(TITLE_H + PAD + h + PAD)
    return self
end
Popout.Resize = Popout._Resize      -- public: call after changing content height

-- ---- the retarget glide ------------------------------------------

-- Pointing an OPEN popout at a different thing used to teleport it, and a panel
-- that vanishes here and reappears there reads as a NEW panel rather than as the
-- same one now about something else -- which is exactly the wrong story when the
-- whole point of a single following panel is that there is only ever one of it.
--
-- So it slides. Automatic in Follow whenever a SHOWN, FOLLOWING popout is handed
-- a new region; PlaceFree and a pinned popout are untouched.
--
-- ☠ THE RE-DOCK IS SUSPENDED FOR THE DURATION. A following popout is anchored to
-- its source, so it cannot be driven independently while that anchor holds --
-- the glide takes an EXPLICIT screen anchor, and _Tick's "the source moved,
-- re-dock" arm must not fire underneath it or the frame would be yanked onto the
-- destination on the first frame of the slide. Landing hands the anchor back.
function Popout:_StartGlide()
    local f = self.frame
    local sr = rectOf(self.source)
    local from = rectOf(f)
    if not (sr and from) then return false end
    local w, h = f:GetWidth() or 0, f:GetHeight() or 0
    local side = self:_PickSide(sr, w, h)
    local tx, ty = UI.PopoutDockPos(sr, side, w, h, DOCK_GAP)
    if not tx then return false end

    -- The ticker's baseline moves to the NEW source now, so the first tick of
    -- the glide does not read the retarget itself as "the source moved".
    self._srcX, self._srcY, self._srcW, self._srcH = sr.x, sr.y, sr.w, sr.h
    self.side = side
    self.gliding = true
    self._gT = 0
    self._gFromX, self._gFromY = from.x, from.y
    self._gToX, self._gToY = tx, ty
    self._gX, self._gY = from.x, from.y
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", from.x, from.y)
    self:_StartTick()
    -- The connected chrome commits to the NEW source at once -- beam and outline
    -- both -- so the slide is the panel travelling TOWARDS something already
    -- marked, rather than dragging the old relationship along with it.
    self:_UpdateNotch()
    self:_UpdateBeam()
    self:_UpdateSourceOutline()
    return true
end

function Popout:_AdvanceGlide(elapsed)
    local t = (self._gT or 0) + (elapsed or 0)
    self._gT = t
    local k = min(t / GLIDE_DUR, 1)
    -- Cubic ease-out: away quickly, settling onto the dock point. The entrance
    -- and exit are eased the same way, so the panel always decelerates into
    -- wherever it is going.
    local e = 1 - (1 - k) ^ 3
    local x = self._gFromX + (self._gToX - self._gFromX) * e
    local y = self._gFromY + (self._gToY - self._gFromY) * e
    self._gX, self._gY = x, y
    local f = self.frame
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", x, y)
    -- The beam's near end is on the moving frame, so it is redrawn per frame;
    -- the source outline is anchored to the source and does not move at all.
    self:_UpdateBeam()
    if k >= 1 then self:_EndGlide() end
end

-- Land, and hand the anchor back to the source so the follow works for free
-- again. With nothing else moved _Dock resolves to exactly the point the glide
-- was aimed at, which is what makes the landing exact rather than approximately
-- exact.
function Popout:_EndGlide()
    if not self.gliding then return end
    self.gliding = false
    self._gX, self._gY = nil, nil
    if self.following and not self.closed then self:_Dock() end
end

-- ---- accent chrome -----------------------------------------------

-- The colour every piece of this popout's chrome is drawn in: the border, the
-- connection point and the source outline. `opts.accent` overrides the host's,
-- so a consumer whose surface carries its own theme colour can hand that in per
-- popout. Without one it is the HOST accent -- and that table is mutated in
-- place by SetAccent, so re-reading it here is all it takes to track a change.
function Popout:GetAccent()
    return self.accent or self.host:GetAccent()
end

-- Repaint everything the accent colours. Called on every adopt, so a pooled
-- popout re-opened after a theme change comes up in the current colour rather
-- than in whatever it was built in.
function Popout:_ApplyAccent()
    local c = self:GetAccent()
    -- The accent goes on as the panel's own 1px BORDER, which is the whole
    -- "the popout and the thing it is about share an edge" idea -- and it runs
    -- through the pixel-border machinery, so it lands on the device grid like
    -- every other outlined surface in the kit, with square corners.
    self.host:CreatePanelBackdrop(self.frame, { borderColor = c })
    if self.notch then self.notch:SetVertexColor(c.r, c.g, c.b, c.a or 1) end
    if self.srcOutline then
        self.host:ApplyPixelBorder(self.srcOutline, { c.r, c.g, c.b, c.a or 1 })
    end
end

-- ---- the connection point ----------------------------------------

-- The accent diamond centred on the source-facing edge. Shown only while the
-- popout is FOLLOWING: a pinned popout has been taken off its leash by hand and
-- is docked to nothing, so a point aimed at the source would be pointing at a
-- relationship that no longer holds.
function Popout:_UpdateNotch()
    local n = self.notch
    if not n then return end
    local spec = (not self.closed) and self.following and not self.pinned
                 and NOTCH_SIDE[self.side] or nil
    if not spec then n:Hide() return end
    n:ClearAllPoints()
    -- CENTRE on the edge, so exactly half the diamond stands proud of the
    -- border and the other half sits over it -- one shape crossing the line
    -- rather than a marker parked beside it.
    n:SetPoint("CENTER", self.frame, spec[1], 0, 0)
    n:Show()
end

-- ---- the source outline ------------------------------------------

-- A 1px accent outline laid over the tether source, so the popout and the thing
-- it is about wear the SAME border and the beam reads as a join between two
-- pieces of one object rather than a line to something unrelated.
--
-- Its own frame, parented to the popout's PARENT for the same reason the beam
-- is: a consumer that parents its popouts to a session overlay (so hiding the
-- overlay suspends everything) must get this in that bargain too.
function Popout:_EnsureSourceOutline()
    if self.srcOutline ~= nil then return self.srcOutline end
    local o = CreateFrame("Frame", nil, self.frame:GetParent() or UIParent)
    o:SetFrameStrata("DIALOG")
    o:Hide()
    self.srcOutline = o
    return o
end

-- The outline is ANCHORED to the region, so it tracks a moving source for free;
-- this only has to run when the state or the target changes.
function Popout:_UpdateSourceOutline()
    local want = self.following and not self.pinned and not self.closed
                 and self.frame:IsShown()
    local region = want and self:_TetherRegion() or nil
    if region and not rectOf(region) then region = nil end
    if not region then
        self:_HideSourceOutline()
        return
    end
    local o = self:_EnsureSourceOutline()
    o:ClearAllPoints()
    o:SetPoint("TOPLEFT", region, "TOPLEFT", 0, 0)
    o:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", 0, 0)
    local c = self:GetAccent()
    self.host:ApplyPixelBorder(o, { c.r, c.g, c.b, c.a or 1 })
    if o:IsShown() then return end
    if Fx then Fx.FadeIn(o, BEAM_DUR) else o:Show() end
end

function Popout:_HideSourceOutline()
    local o = self.srcOutline
    if not o or not o:IsShown() then return end
    if Fx then Fx.FadeOut(o, BEAM_DUR, function() o:Hide() end) else o:Hide() end
end

-- Take every piece of connected chrome down AT ONCE, animations cancelled. For
-- the paths that must be instant -- a consumer hiding the popout by hand for a
-- combat suspend or a drag -- where a fading beam left behind would be the one
-- thing that failed to suspend.
function Popout:HideChrome()
    if self.beam then
        if Fx then Fx.Cancel(self.beam) end
        self.beam:Hide()
    end
    if self.srcOutline then
        if Fx then Fx.Cancel(self.srcOutline) end
        self.srcOutline:Hide()
    end
end

-- ---- the follow ticker -------------------------------------------

-- ONE OnUpdate drives everything that has to react to movement: the re-dock
-- when the source moves, the source-death close, and the retarget glide.
--
-- It early-outs the moment nothing has moved, which is the overwhelmingly
-- common case, and it is a plain script so a headless test can drive one tick
-- by hand: popout.frame:GetScript("OnUpdate")(popout.frame, elapsed).
local function onUpdate(frame, elapsed)
    local po = frame._popout
    if po then po:_Tick(elapsed) end
end

function Popout:_StartTick()
    self.frame:SetScript("OnUpdate", onUpdate)
end

function Popout:_StopTick()
    self.frame:SetScript("OnUpdate", nil)
end

function Popout:_Tick(elapsed)
    if self.closed then return end
    local f = self.frame
    if not f:IsShown() then return end

    -- Source death. Only meaningful for a popout that CANNOT be pinned: a
    -- pinnable one may legitimately outlive what it was opened from, and
    -- deciding what that means is the consumer's call, not the shell's.
    if not self.pinnable and self.source and not self:_SourceAlive() then
        self:Close("source")
        return
    end

    -- A glide OWNS the position while it runs, so the re-dock below is
    -- suspended: see _StartGlide.
    if self.gliding then
        self:_AdvanceGlide(elapsed)
        return
    end

    local sr = rectOf(self.source)
    local moved = sr and (sr.x ~= self._srcX or sr.y ~= self._srcY
                          or sr.w ~= self._srcW or sr.h ~= self._srcH)
    if moved then self._srcX, self._srcY, self._srcW, self._srcH = sr.x, sr.y, sr.w, sr.h end

    -- A re-dock redraws the chrome on the way through (_Dock -> _Present), so
    -- there is nothing else to do for a source move. A PINNED popout wears no
    -- connected chrome at all, so a move it is not following costs one compare.
    if moved and self.following then self:_Dock() end
end

function Popout:_SourceAlive()
    local src = self.source
    if not src then return false end
    if src.IsShown and not src:IsShown() then return false end
    return true
end

-- ---- the tether beam ---------------------------------------------

-- The far end of the beam: an explicit tetherSource when the consumer gave one
-- (the thing the popout is ABOUT may not be the thing it docked to), otherwise
-- whatever it is following.
function Popout:_TetherRegion()
    local t = self.tetherSource
    if type(t) == "function" then t = t(self) end
    return t or self.source
end

-- The popout's own rect, in the same UIParent-centre units as everything else
-- here. Its own method rather than a bare rectOf(self.frame) because a GLIDING
-- popout is authoritative about where it is: the anchor it was just handed will
-- not be reflected by GetCenter until the frame is next laid out, and a beam
-- drawn from last frame's position lags visibly behind the panel it leaves.
function Popout:_FrameRect()
    if self.gliding and self._gX then
        local f = self.frame
        return { x = self._gX, y = self._gY, w = f:GetWidth() or 0, h = f:GetHeight() or 0 }
    end
    return rectOf(self.frame)
end

function Popout:_EnsureBeam()
    if self.beam then return self.beam end
    -- Its own frame so it fades as a UNIT -- animating a Frame's alpha carries
    -- both its lines, which is the whole reason the beam is not two loose lines
    -- on the popout. Parented to the popout's PARENT, not to UIParent: a
    -- consumer that parents its popouts to a session overlay (so hiding the
    -- overlay hides everything, e.g. for a combat suspend) must get the beam in
    -- that bargain too -- a beam left glowing over a hidden UI would be the one
    -- piece that failed to suspend. Regions are not clipped to their parent's
    -- rect, so the lines still span the gap.
    local b = CreateFrame("Frame", nil, self.frame:GetParent() or UIParent)
    b:SetAllPoints(UIParent)
    b:SetFrameStrata("BACKGROUND")
    b:Hide()
    -- Guarded, and cached as FALSE rather than nil so the guard is asked once:
    -- a headless stub (or any surface without Line objects) simply never gets a
    -- beam, and every beam call after this no-ops instead of erroring.
    b.glow = b.CreateLine and b:CreateLine(nil, "ARTWORK", nil, -1) or false
    b.core = b.CreateLine and b:CreateLine(nil, "ARTWORK", nil, 0) or false
    self.beam = b
    return b
end

-- Draw / show / hide the beam for the current state.
--
-- ⚠ THE BEAM MEANS "JOINED", NOT "STRAYED". It was the other way round to begin
-- with -- drawn only once a PINNED popout had been dragged away from its source
-- -- and that is what made the docked state read as a floating box: at the one
-- moment the two things genuinely belong together, nothing said so. Now:
--
--   FOLLOWING   the beam is always up, and SHORT: from the connection point's
--               tip to the nearest point on the source's outline, i.e. straight
--               across the dock gap. Popout border, beam and source outline are
--               one continuous accent line.
--   PINNED      no beam, no connection point, no source outline. Pinning is
--               visually detached, full stop.
function Popout:_UpdateBeam()
    local want = self.following and not self.pinned and not self.closed
                 and self.frame:IsShown()
    local target = want and self:_TetherRegion() or nil
    local tr = target and rectOf(target) or nil
    local pr = tr and self:_FrameRect() or nil
    -- The beam LEAVES THE TIP, not the frame edge: the connection point is the
    -- thing pointing at the source, so a beam starting behind it would read as
    -- a line passing through a decoration.
    -- ⚠ Not `local ax, ay = pr and PopoutNotchTip(...)` -- `and` truncates to ONE
    -- value, so ay would silently be nil and the clamp below would error.
    local ax, ay
    if pr then ax, ay = UI.PopoutNotchTip(pr, self.side, NOTCH_SIZE) end
    if not (tr and pr and ax) then
        self:_HideBeam()
        return
    end
    local bx, by = UI.PopoutNearestOnRect(tr, ax, ay)

    local b = self:_EnsureBeam()
    local c = self:GetAccent()
    for _, line in ipairs({ b.glow, b.core }) do
        if line then
            line:SetStartPoint("CENTER", UIParent, ax, ay)
            line:SetEndPoint("CENTER", UIParent, bx, by)
        end
    end
    if b.glow then
        b.glow:SetThickness(BEAM_GLOW_W)
        b.glow:SetColorTexture(c.r, c.g, c.b, BEAM_GLOW_A)
        b.glow:Show()
    end
    if b.core then
        b.core:SetThickness(BEAM_CORE_W)
        b.core:SetColorTexture(c.r, c.g, c.b, BEAM_CORE_A)
        b.core:Show()
    end
    if b:IsShown() then return end
    -- Fx sequencing: the beam lands AFTER the popout has finished popping in,
    -- so the two read as one gesture rather than as two things happening at
    -- once. _popDur is consumed, so only the first beam after an entrance waits.
    local wait = self._popDur
    self._popDur = nil
    local function reveal()
        if self.closed or not self.following or self.pinned then return end
        if Fx then Fx.FadeIn(b, BEAM_DUR) else b:Show() end
    end
    if wait then after(wait, reveal) else reveal() end
end

function Popout:_HideBeam()
    local b = self.beam
    if not b or not b:IsShown() then return end
    if Fx then Fx.FadeOut(b, BEAM_DUR, function() b:Hide() end) else b:Hide() end
end

-- ---- pinning -----------------------------------------------------

-- Take the popout off its leash: it stops following, becomes draggable by the
-- title bar, and from here on the only way out is the cross.
--
-- `silent` is AutoPin's path -- the confirm pop is feedback for a click, and
-- playing it for something the consumer decided would look like a glitch.
function Popout:Pin(silent)
    if self.pinned or not self.pinnable or self.closed then return self end
    self.pinned = true
    self.following = false
    -- Pinned mid-glide: it stops dead WHERE IT IS. Carrying on to a dock point
    -- it is no longer docked to would be the panel finishing a journey the user
    -- just cancelled. The position is taken BEFORE the glide is cleared, because
    -- mid-glide the frame's own GetCenter lags the anchor it was just handed.
    local at = self:_FrameRect()
    self.gliding = false
    self._gX, self._gY = nil, nil

    -- Out of the pool: this instance keeps the content it was built with, and
    -- the next request for the key gets a fresh one.
    local store = storeFor(self.host)
    if store.pooled[self.key] == self then store.pooled[self.key] = nil end

    -- Re-anchor to the screen at the position it currently occupies. Left
    -- anchored to the source it would keep travelling with it, which is the one
    -- thing pinning is supposed to stop.
    local f = self.frame
    if at then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", at.x, at.y)
    end

    -- Draggable ONLY now: a docked popout that could be dragged would fight the
    -- follow, so none of this is wired until pinning.
    f:SetMovable(true)
    local bar = self.titleBar
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    -- Nothing to redraw on either end of the drag: a pinned popout carries no
    -- connected chrome, which is the whole point of pinning it.
    bar:SetScript("OnDragStart", function() f:StartMoving() end)
    bar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    -- v1 does not unpin, so the button would be a lie about what it does.
    if self.pinBtn then self.pinBtn:Hide() end

    if not silent and Fx then Fx.PopIn(f, PIN_DUR, 0, 0, 0.96, "CENTER") end
    -- Pin is VISUALLY DETACHED, full stop: the connection point and the source
    -- outline both go, because the thing they describe -- "this panel is docked
    -- to that" -- has just stopped being true.
    self:_UpdateNotch()
    self:_HideSourceOutline()
    self:_UpdateBeam()
    safeCall(self.onPin, self)
    return self
end

-- Pin without being asked: the consumer's own rule decided this popout has
-- earned staying. Gated on `canAutoPin`, which may be a value or a function
-- evaluated PER CALL -- the answer can change between two opens of the same key.
function Popout:AutoPin()
    if self.pinned or not self.pinnable or self.closed then return self end
    local gate = self.canAutoPin
    if type(gate) == "function" then
        if not gate(self) then return self end
    elseif gate ~= nil and not gate then
        return self
    end
    return self:Pin(true)
end

function Popout:IsPinned() return self.pinned == true end

-- ---- header ------------------------------------------------------

function Popout:SetHeader(title, icon)
    self.headerTitle, self.headerIcon = title, icon
    self.titleFS:SetText(title or "")
    if self.iconTex then
        self.iconTex:SetShown(icon ~= nil)
        if icon then self.iconTex:SetTexture(icon) end
    end
    return self
end

function Popout:GetTitle() return self.headerTitle end

-- ---- closing -----------------------------------------------------

-- reason: "cross" | "family" | "source" | "api". The shell never decides what
-- closing MEANS -- it reports why it happened and the consumer acts on it.
--
-- The exit is the entrance backwards, and the beam goes FIRST: a beam still
-- hanging in the air while its popout shrinks away reads as two events.
function Popout:Close(reason)
    if self.closed then return self end
    self.closed = true
    self.following = false
    self.gliding = false
    self:_StopTick()

    local store = storeFor(self.host)
    for i = #store.live, 1, -1 do
        if store.live[i] == self then tremove(store.live, i) end
    end
    -- A PINNED instance is discarded: it left the pool when it was pinned and
    -- its frame is not offered back. An unpinned one stays pooled and is
    -- revived by the next request for its key -- that is what the pool is for.

    local f = self.frame
    local ox, oy, origin = dockFx(self.side)
    local function popOut()
        if Fx then
            Fx.PopOut(f, OUT_DUR, ox, oy, 0.92, origin, function() f:Hide() end)
        else
            f:Hide()
        end
    end
    -- The connection point is part of the FRAME, so it leaves with it; the beam
    -- and the source outline are not, and both go first.
    if self.notch then self.notch:Hide() end
    local b, o = self.beam, self.srcOutline
    local hadChrome = (b and b:IsShown()) or (o and o:IsShown())
    self:_HideBeam()
    self:_HideSourceOutline()
    if hadChrome then after(BEAM_DUR, popOut) else popOut() end

    safeCall(self.onClose, self, reason or "api")
    return self
end

function Popout:IsShown() return self.frame:IsShown() end

-- ============================================================
-- FACTORY
-- ============================================================

-- Everything a re-used instance is allowed to change. build is NOT among them:
-- the content was mounted once and is what makes the pooled frame worth keeping.
local function adopt(po, opts)
    po.family      = opts.family
    po.accent      = normColor(opts.accent)
    po.onClose     = opts.onClose
    po.onPin       = opts.onPin
    po.onUnpin     = opts.onUnpin          -- accepted; v1 never unpins
    po.canAutoPin  = opts.canAutoPin
    po.tetherSource = opts.tetherSource
    -- Reserved. Accepted and ignored so the call sites that will want a header
    -- action row or a count badge can be written before the shell grows them.
    po.actions     = opts.actions
    po.badge       = opts.badge
    po:SetHeader(opts.title, opts.icon)
    po:_ApplyAccent()
end

-- Opening a popout in a family closes every OTHER popout in that family --
-- pinned ones included, because a family is an exclusivity claim, not a
-- politeness. A nil family coexists with everything.
local function sweepFamily(host, po)
    if not po.family then return end
    local store = storeFor(host)
    for i = #store.live, 1, -1 do
        local other = store.live[i]
        if other ~= po and not other.closed and other.family == po.family then
            other:Close("family")
        end
    end
end

-- opts:
--   key           REQUIRED identity string. The pool is per host+key.
--   family        exclusivity group; opening one closes the rest of its family
--   pinnable      default true. false: no pin button, AutoPin no-ops, and the
--                 popout dies with its source
--   title / icon  title bar; changeable later with :SetHeader
--   parent        frame to parent to (default UIParent)
--   width         CONTENT width; the height follows what build mounted
--   build(popout, content)   called ONCE per instance
--   onClose(popout, reason)  reason: "cross"|"family"|"source"|"api"
--   onPin(popout) / onUnpin(popout)
--   canAutoPin    boolean or function(popout); false makes AutoPin a no-op
--   tetherSource  region or function -> region; the beam's far end
--   accent        {r,g,b[,a]} overriding the HOST accent for this popout's
--                 border, connection point, beam and source outline
--   actions / badge          reserved, accepted and ignored
function UI:CreatePopout(opts)
    local host = self
    if type(opts) ~= "table" or type(opts.key) ~= "string" or opts.key == "" then
        error("DandersUI: CreatePopout needs opts.key", 2)
    end
    local L = host.hooks and host.hooks.L
    local store = storeFor(host)

    -- Pooled hit: same object, re-targeted, build untouched.
    local pooled = store.pooled[opts.key]
    if pooled then
        pooled.closed = false
        adopt(pooled, opts)
        local found = false
        for _, p in ipairs(store.live) do if p == pooled then found = true end end
        if not found then tinsert(store.live, pooled) end
        sweepFamily(host, pooled)
        return pooled
    end

    local po = setmetatable({
        host = host,
        key = opts.key,
        pinnable = opts.pinnable ~= false,
        width = opts.width or 220,
    }, popoutMeta)

    local f = CreateFrame("Frame", nil, opts.parent or UIParent, "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetWidth(po.width + PAD * 2)
    f:EnableMouse(true)                       -- a panel must not leak clicks through
    f:Hide()
    f._popout = po                            -- the OnUpdate script's way back
    po.frame = f
    -- Hiding the frame by hand (a consumer's combat suspend, or the tail of the
    -- exit) must take the beam and the source outline with it: they are not
    -- children of this frame, so nothing else would.
    if f.HookScript then
        f:HookScript("OnHide", function() po:HideChrome() end)
    end

    -- The connection point. OVERLAY, so it draws over the pixel border it
    -- straddles (which is ARTWORK sublevel 7). A diamond, so ONE piece of art
    -- serves all four dock sides -- it is symmetric under a quarter turn.
    local notch = f:CreateTexture(nil, "OVERLAY", nil, 2)
    notch:SetTexture(UI.MEDIA .. "Icons\\notch")
    notch:SetSize(NOTCH_SIZE, NOTCH_SIZE)
    notch:Hide()
    po.notch = notch

    -- ---- title bar ------------------------------------------------
    -- Its own frame because it is the DRAG surface once pinned; mouse is only
    -- enabled on it at that point.
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetHeight(TITLE_H)
    po.titleBar = bar

    local iconTex = f:CreateTexture(nil, "OVERLAY")
    iconTex:SetSize(ICON_SIZE, ICON_SIZE)
    iconTex:SetPoint("LEFT", bar, "LEFT", PAD, 0)
    iconTex:Hide()
    po.iconTex = iconTex

    po.closeBtn = host:CreateCloseButton(f, {
        size = CLOSE_SIZE,
        onClick = function() po:Close("cross") end,
    })
    po.closeBtn:SetPoint("RIGHT", bar, "RIGHT", -4, 0)

    if po.pinnable then
        po.pinBtn = host:CreateGlyphButton(f, {
            texture = UI.MEDIA .. "Icons\\pin",
            size = PIN_SIZE,
            tooltip = { title = L and L["Pin"] or "Pin" },
            onClick = function() po:Pin() end,
        })
        po.pinBtn:SetPoint("RIGHT", po.closeBtn, "LEFT", -2, 0)
    end

    -- The title takes whatever the buttons left. Anchored to the pin (or the
    -- cross when there is none) rather than to a measured width, so the two
    -- layouts need no arithmetic between them.
    po.titleFS = host:CreateLabel(f, { size = 11, color = UI.Colors and UI.Colors.text })
    po.titleFS:SetPoint("LEFT", iconTex, "RIGHT", 4, 0)
    po.titleFS:SetPoint("RIGHT", po.pinBtn or po.closeBtn, "LEFT", -4, 0)
    if po.titleFS.SetWordWrap then po.titleFS:SetWordWrap(false) end

    -- ---- content --------------------------------------------------
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", PAD, -TITLE_H)
    content:SetWidth(po.width)
    content:SetHeight(1)
    po.content = content

    adopt(po, opts)
    store.pooled[opts.key] = po
    tinsert(store.live, po)

    safeCall(opts.build, po, content)
    po:_Resize()
    sweepFamily(host, po)
    return po
end
