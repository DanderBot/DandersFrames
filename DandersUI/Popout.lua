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

-- The box model comes from the theme (see Theme.lua's note on both): the frame's
-- height is TITLE_H + PAD + content + PAD, and a consumer sizing a fixed panel
-- has to be able to work that out without reading this file.
local PAD        = UI.PopoutPad          -- outer inset around the content
local TITLE_H    = UI.PopoutTitleHeight  -- the title bar strip
-- The title bar's INTERNAL composition, which nothing outside can use and so
-- stays here. HDR_EDGE is the cross's inset from the bar's right edge, HDR_GAP
-- the gap between two adjacent glyph buttons, and TITLE_GAP the wider air either
-- side of the title text -- wider because a caption butted up against a glyph
-- reads as a label FOR that glyph.
local HDR_EDGE   = 6
local HDR_GAP    = 6
local TITLE_GAP  = 8
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

-- ---- outside-a-window placement ----------------------------------

-- THE SETTINGS PLACEMENT. A popout about a ROW inside a scrolling WINDOW must not
-- dock beside the row: docked there it lands ON the window, covering the very
-- list the row was picked from, and every scroll drags it across that list. So it
-- docks outside the WINDOW's vertical edge instead, at the ROW's height -- the
-- window stays wholly readable, and the popout still visibly belongs to one row
-- because it is centred on that row and the beam crosses to it.
--
-- Two rects, therefore, not one: the WINDOW decides x (which edge, and how far
-- out), the ROW decides y. Which is also why this cannot be expressed as a frame
-- anchor -- see the clamps below, and _Dock's outsideOf arm.
--
-- Returns side ("right"/"left"), x, y -- the popout's CENTRE, same units as
-- PopoutDockPos, so the dock, the glide's destination and the tests all read one
-- answer. nil for a missing rect.
--
-- ⚠ CENTRED ON THE ROW, not hung from its top. Hanging from the top is the story
-- right/left docking tells, and for a SHORT popout the two readings agree -- but
-- a tall one hung by its top puts its whole body below the row, so a group with
-- a dozen controls opened from the third row of a list ends up level with the
-- twelfth. "At the row's height" is what this placement promises, and the centre
-- is what actually delivers it.
--
-- The clamps, in order (later wins, because being off-screen is worse than being
-- level with the wrong part of the window):
--   1. THE WHOLE POPOUT is clamped into the window's vertical span -- WHEN IT
--      FITS THERE. For a row in view with a popout shorter than the window this
--      is usually a no-op and "centred on the row" holds exactly; for a row
--      scrolled out of the window it is what keeps the popout beside the LIST
--      rather than trailing off after a row that is no longer drawn. A popout
--      TALLER than the window has no position that satisfies the clamp, so it
--      stands down rather than pinning the panel to an arbitrary edge -- the
--      screen clamp below takes it from there.
--   2. The whole popout is clamped fully on screen.
function UI.PopoutOutsidePos(win, row, w, h, gap, screenW, screenH, forcedSide)
    if not (win and row) then return nil end
    gap = gap or DOCK_GAP
    w, h = w or 0, h or 0
    -- Only left/right mean anything out here: above/below a window is not
    -- "outside its vertical edge", it is somewhere else entirely.
    local side = (forcedSide == "left" or forcedSide == "right") and forcedSide or nil
    local rightX = win.x + win.w / 2 + gap + w / 2
    local leftX  = win.x - win.w / 2 - gap - w / 2
    if not side then
        -- HORIZONTAL fit only. y is clamped below, so the vertical axis can never
        -- be the reason a side does not fit and must not get a vote -- letting it
        -- vote would flip the popout across the window because of a tall content
        -- block, which is not a horizontal problem.
        local halfW = (screenW or 0) / 2
        side = (rightX + w / 2 <= halfW and rightX - w / 2 >= -halfW) and "right" or "left"
        -- Neither side fits (a window wider than the screen): stay right and let
        -- SetClampedToScreen deal with the overhang, exactly as _PickSide does.
    end
    local x = (side == "left") and leftX or rightX
    -- The row sits a THIRD down the popout, not at its middle. Dead-centre made
    -- tall popouts feel like they hung off the row (half the panel below your
    -- eye line); a third matches where a reader expects the "current" item.
    -- centre = row - (h/2 - h/3) = row - h/6, then clamped like any y.
    local y = row.y - h / 6
    -- Into the window's vertical span. `slack` is how far the popout's centre may
    -- stray from the window's before an edge of it leaves the window; negative
    -- means the popout is taller than the window and no such position exists, so
    -- the clamp stands down rather than jamming the panel against an edge.
    local slack = win.h / 2 - h / 2
    if slack >= 0 then
        y = min(max(y, win.y - slack), win.y + slack)
    end
    local halfH = (screenH or 0) / 2
    y = min(max(y, -halfH + h / 2), halfH - h / 2)
    return side, x, y
end

-- Do two rects overlap at all? The out-of-view test for a row in a scroll child:
-- clipped rows stay IsShown(), so the only honest question is whether the row's
-- rect is still inside the window's.
local function rectsOverlap(a, b)
    if not (a and b) then return false end
    return abs(a.x - b.x) < (a.w + b.w) / 2 and abs(a.y - b.y) < (a.h + b.h) / 2
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

-- ---- the ink rect ------------------------------------------------

-- WHICH PART OF A REGION IS ACTUALLY DRAWN. A region's frame and its INK are not
-- always the same rect: a settings row occupies a layout slot that includes the
-- gap to the next row, so its frame is RowGap taller than anything it paints. An
-- outline laid over the frame is therefore visibly too tall, and a beam aimed at
-- the frame's centre lands below the thing it is pointing at.
--
-- So a region may declare its own inset -- `region.popoutInset = { l, r, t, b }`,
-- pixels trimmed off each edge -- and EVERY rect this file takes of a region
-- honours it. One protocol, read in one place, so the dock, the tether, the clip
-- gate, the beam and the outline cannot end up disagreeing about where a row is.
-- The shell still knows nothing about rows: the region says which part of itself
-- is ink, and the shell believes it.
--
-- ⚠ type(), not a truthiness test. A headless frame stub answers every unknown
-- key with a no-op FUNCTION, so `region.popoutInset` is truthy on frames that
-- have never declared one.
local function insetOf(region)
    local ins = region and region.popoutInset
    if type(ins) ~= "table" then return 0, 0, 0, 0 end
    return ins[1] or 0, ins[2] or 0, ins[3] or 0, ins[4] or 0
end

-- Rect of a region in UIParent-centre units, inset to its ink; nil while it has
-- no geometry yet.
local function rectOf(region)
    if not region or not region.GetCenter then return nil end
    local cx, cy = region:GetCenter()
    if not cx then return nil end
    local ux, uy = UIParent:GetCenter()
    local x, y = cx - ux, cy - uy
    local w, h = region:GetWidth() or 0, region:GetHeight() or 0
    local l, r, t, b = insetOf(region)
    if l ~= 0 or r ~= 0 or t ~= 0 or b ~= 0 then
        -- Trimming the left edge moves the centre right by half of it, and so on
        -- round the four; the size loses both edges of each axis.
        x, y = x + (l - r) / 2, y + (b - t) / 2
        w, h = max(w - l - r, 0), max(h - t - b, 0)
    end
    return { x = x, y = y, w = w, h = h }
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

-- How close to a corner the connection point may slide (centre-to-corner).
local NOTCH_EDGE_INSET = 14

-- The tip of the connection point, in UIParent-centre units: the outer vertex of
-- the diamond sitting half-proud of the popout's source-facing edge. nil for a
-- popout with no dock side (PlaceFree), which has nothing to point at.
--
-- With `src` (the source's rect), the point SLIDES along the edge to line up
-- with the source's centre, clamped clear of the corners -- a tall popout
-- beside a small mover keeps its point (and beam) level with the mover instead
-- of leaving a long accent line crawling up from the edge's midpoint.
--
-- Exposed on the library for the same reason PopoutPickSide is: it is a pure
-- function of its arguments and both the beam and its tests want it.
function UI.PopoutNotchTip(pr, side, size, src)
    local spec = pr and side and NOTCH_SIDE[side]
    if not spec then return nil end
    size = size or NOTCH_SIZE
    local x = pr.x + spec[2] * (pr.w / 2 + size / 2)
    local y = pr.y + spec[3] * (pr.h / 2 + size / 2)
    if src then
        if spec[2] ~= 0 then    -- left/right dock: slide vertically
            local half = max(pr.h / 2 - NOTCH_EDGE_INSET, 0)
            y = min(max(src.y, pr.y - half), pr.y + half)
        else                    -- above/below dock: slide horizontally
            local half = max(pr.w / 2 - NOTCH_EDGE_INSET, 0)
            x = min(max(src.x, pr.x - half), pr.x + half)
        end
    end
    return x, y
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
-- opts.outsideOf = <window frame> switches to the SETTINGS PLACEMENT: `region`
-- is then a ROW INSIDE that window, and the popout docks outside the WINDOW's
-- vertical edge at the row's height rather than beside the row itself (see
-- UI.PopoutOutsidePos). Only "left"/"right" are meaningful for opts.side there.
-- The mode lives on the instance, so a plain Follow afterwards clears it.
--
-- opts.clipTo = <region> names what actually CLIPS the source -- the scroll
-- frame, not the window around it. The connected chrome hides while the source
-- leaves that rect. Defaults to outsideOf, which is nearly always too generous
-- by the window's own title bar and padding: see _TetherClipped.
--
-- RETARGETING a popout that is already up (a different region while it is
-- following) GLIDES it across instead of teleporting: see _StartGlide.
function Popout:Follow(region, opts)
    if not region then return end
    local prev = self.source
    self.source = region
    self.forcedSide = opts and opts.side or nil
    self.outsideOf = opts and opts.outsideOf or nil
    -- The region that actually CLIPS the source (a scroll frame), which is not
    -- the window -- see _TetherClipped.
    self.clipTo = opts and opts.clipTo or nil
    -- Docking against a window: the popout (and the beam synced just under it)
    -- must render ABOVE that window and its children -- a scrollbar sitting on
    -- top of the beam reads as the link being cut.
    if self.outsideOf and self.outsideOf.GetFrameLevel and self.frame.SetFrameLevel then
        local wl = self.outsideOf:GetFrameLevel() or 1
        if (self.frame:GetFrameLevel() or 0) <= wl + 10 then
            self.frame:SetFrameLevel(wl + 10)
        end
    end
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
    self.outsideOf = nil        -- absolute placement is not docked to anything
    self.clipTo = nil           -- ...and nothing is clipping what it is not about
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

    -- THE SETTINGS PLACEMENT takes an EXPLICIT SCREEN ANCHOR, not a frame anchor,
    -- and that is not a shortcut: the y depends on the ROW *and* on two clamps
    -- (the window's vertical span, then the screen), and no SetPoint against
    -- either frame can express a value that is a function of both. The follow
    -- ticker earns the difference back -- it re-docks on a row move AND on a
    -- window move, so the pair still tracks for free.
    local wr = self.outsideOf and rectOf(self.outsideOf) or nil
    if wr then
        -- Its own baseline, alongside the source's: a pure width-resize moves the
        -- window's edge without moving the row at all (see _Tick).
        self._winX, self._winY, self._winW, self._winH = wr.x, wr.y, wr.w, wr.h
        local side, x, y = UI.PopoutOutsidePos(wr, sr, f:GetWidth() or 0, f:GetHeight() or 0,
                                               DOCK_GAP, UIParent:GetWidth() or 0,
                                               UIParent:GetHeight() or 0, self.forcedSide)
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", x, y)
        self.side = side
        self:_Present(side)
        return
    end
    self._winX, self._winY, self._winW, self._winH = nil, nil, nil, nil

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
    -- The destination comes from the SAME function the dock uses -- PopoutDockPos
    -- beside a source, PopoutOutsidePos outside a window -- so the landing is
    -- exact in either mode rather than approximately exact in one of them.
    local side, tx, ty
    local wr = self.outsideOf and rectOf(self.outsideOf) or nil
    if wr then
        side, tx, ty = UI.PopoutOutsidePos(wr, sr, w, h, DOCK_GAP,
                                           UIParent:GetWidth() or 0, UIParent:GetHeight() or 0,
                                           self.forcedSide)
        self._winX, self._winY, self._winW, self._winH = wr.x, wr.y, wr.w, wr.h
    else
        side = self:_PickSide(sr, w, h)
        tx, ty = UI.PopoutDockPos(sr, side, w, h, DOCK_GAP)
    end
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

-- Set (or clear) this instance's accent override and repaint every piece of
-- chrome that carries it, WHILE IT IS UP. adopt() already applies opts.accent at
-- open time; this is the live path -- a consumer that re-themes (a party/raid
-- mode switch, a per-row colour changing under an open panel) has nothing else
-- to call, and a popout left in the old colour while its source has changed is
-- the one thing the shared-border story cannot survive.
--
-- nil resets to the host accent. The source outline repaints through
-- _ApplyAccent, which re-runs ApplyPixelBorder on it unconditionally --
-- _UpdateSourceOutline itself only repaints on a TARGET change, so it would not
-- have noticed a colour change on a shown outline.
--
-- _ApplyAccent also CASCADES into the content, so the widgets the consumer
-- mounted follow the chrome instead of staying in whatever colour they were
-- built against -- see _CascadeAccent for what that reaches and what it does not.
function Popout:SetAccent(c)
    self.accent = normColor(c)
    self:_ApplyAccent()
    self:_UpdateNotch()
    self:_UpdateBeam()
    self:_UpdateSourceOutline()
    return self
end

-- ---- the accent cascade ------------------------------------------

-- How deep under the frame the walk below looks. A popout's tree is shallow by
-- construction (frame -> content -> the consumer's mount -> its pane -> a
-- widget's own parts), and a bound rather than an unbounded walk keeps a
-- consumer that parents something enormous into a popout from paying for it.
local CASCADE_DEPTH = 8

-- Repaint the accent-bearing widgets a consumer mounted INSIDE this popout.
--
-- ⚠ The chrome is not the whole panel. SetAccent used to repaint the border, the
-- point, the beam and the source outline and stop there -- so a popout whose
-- accent changed under an open panel ended up a purple-bordered box full of
-- orange sliders. The widgets do not read the popout's colour: they were built
-- against the HOST accent and registered themselves on their parent's
-- `ThemeListeners`, the kit's existing repaint list.
--
-- So the popout walks its own tree, finds those lists and repaints them with ITS
-- colour through `ApplyThemeColor(c)` -- the kit's published "tint to THIS
-- colour" entry point, which sliders, buttons, check boxes and collapse arrows
-- all carry.
--
-- ☠ ApplyThemeColor, NEVER UpdateTheme. UpdateTheme means "repaint to the HOST
-- accent" and takes no arguments -- and it cannot be made to take one, because
-- several call sites in the wild reach it through COLON syntax
-- (`slider:UpdateTheme()`), which would fill that parameter with the widget
-- table itself and paint every channel nil.
--
-- KNOWN LIMIT (gate one): a widget re-tints only if it registered on a
-- ThemeListeners list under this popout AND publishes ApplyThemeColor. A widget
-- built with an explicit opts.accent registers no listener at all, deliberately
-- -- that colour is the call site's choice, not an inherited one. And any
-- repaint that reads host:GetAccent() at CLICK time rather than at theme time (a
-- dropdown menu building its rows, an anchor grid cell re-activating) still
-- comes up in the host colour until it is next rebuilt.
local function cascadeInto(frame, c, depth)
    if type(frame) ~= "table" or depth > CASCADE_DEPTH then return end
    local list = rawget(frame, "ThemeListeners")
    if type(list) == "table" then
        for _, w in ipairs(list) do
            if type(w) == "table" and type(w.ApplyThemeColor) == "function" then
                w.ApplyThemeColor(c)
            end
        end
    end
    if type(frame.GetChildren) ~= "function" then return end
    local kids = { frame:GetChildren() }
    for i = 1, #kids do cascadeInto(kids[i], c, depth + 1) end
end

-- Rooted at the FRAME, not at the content: the title bar is not a child of the
-- content, and a consumer's header controls (a popout row's own toggle) live
-- there. A cascade that missed them would leave the one control at the top of
-- the panel in the colour everything else had just left.
function Popout:_CascadeAccent()
    cascadeInto(self.frame, self:GetAccent(), 0)
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
    -- ...and the widgets INSIDE it, which are not chrome and do not read this
    -- popout's colour on their own.
    self:_CascadeAccent()
end

-- ---- the connected chrome's one gate -----------------------------

-- Is the thing the chrome points at actually DRAWN?
--
-- ⚠ IsShown() CANNOT ANSWER THIS. A row scrolled out of a scroll child is still
-- shown -- it is CLIPPED by the scroll frame, and clipping leaves no flag on the
-- row. So the honest test is geometric: does the row's rect still overlap the
-- thing that clips it. With nothing declared to clip against, the answer is
-- always yes.
--
-- ☠ THE CLIPPER IS NOT THE WINDOW. This used to test against `outsideOf`, and
-- that is the wrong rect by exactly the window's own chrome: a settings window
-- has a title bar, a blurb and its padding ABOVE the viewport, so a row scrolled
-- off the top of the list stops being drawn while its rect still overlaps the
-- window by 50-60px. For that whole stretch the beam, the point and the outline
-- were drawn over the window's own title bar, pointing at a row nobody could
-- see -- chrome hanging in mid-air, which is exactly what it looked like.
--
-- `Follow`'s opts.clipTo names the region that really clips (the scroll frame),
-- and `outsideOf` remains the fallback so an existing caller keeps the old
-- behaviour rather than silently losing the gate.
--
-- Only the CHROME is gated. The popout stays up and stays docked (its y clamps
-- into the window's span, see PopoutOutsidePos) -- scrolling a list must not
-- close the panel you scrolled the list to configure. The beam, the connection
-- point and the source outline go, because all three are claims about a row that
-- is no longer on screen.
function Popout:_TetherClipped()
    local clip = self.clipTo or self.outsideOf
    if not clip then return false end
    local cr = rectOf(clip)
    if not cr then return false end
    return not rectsOverlap(cr, rectOf(self:_TetherRegion()))
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
                 and not self:_TetherClipped()
                 and NOTCH_SIDE[self.side] or nil
    if not spec then n:Hide() return end
    -- Slide along the edge to meet the source (see PopoutNotchTip): the offset
    -- is the slid tip minus the edge's own midpoint, in the same rect units.
    local ox, oy = 0, 0
    local target = self._TetherRegion and self:_TetherRegion()
    local tr = target and rectOf(target) or nil
    local pr = tr and self:_FrameRect() or nil
    if pr then
        local tx, ty = UI.PopoutNotchTip(pr, self.side, NOTCH_SIZE, tr)
        local cx, cy = UI.PopoutNotchTip(pr, self.side, NOTCH_SIZE)
        if tx then ox, oy = tx - cx, ty - cy end
    end
    n:ClearAllPoints()
    -- CENTRE on the edge, so exactly half the diamond stands proud of the
    -- border and the other half sits over it -- one shape crossing the line
    -- rather than a marker parked beside it.
    n:SetPoint("CENTER", self.frame, spec[1], ox, oy)
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
                 and self.frame:IsShown() and not self:_TetherClipped()
    local region = want and self:_TetherRegion() or nil
    if region and not rectOf(region) then region = nil end
    if not region then
        self:_HideSourceOutline()
        return
    end
    local o = self:_EnsureSourceOutline()
    -- Only when the TARGET changes. This runs off _Present, which runs off every
    -- re-dock, and re-anchoring plus a full ApplyPixelBorder relayout per source
    -- move would be real work for an outline that is already exactly right --
    -- it is anchored to the region, so it tracks a moving source for free. An
    -- accent change repaints through _ApplyAccent instead.
    if self._outlineOn ~= region then
        self._outlineOn = region
        o:ClearAllPoints()
        -- INSET TO THE REGION'S INK, not laid over its frame. A settings row's
        -- frame is its whole layout slot -- RowGap and all -- so the flush
        -- version drew a box a clear 14px taller than the plate it was supposed
        -- to be lighting, with the overhang sitting in the gap above the next
        -- row. Same rect rectOf() reports, so outline, beam and clip gate agree.
        local l, r, t, b = insetOf(region)
        o:SetPoint("TOPLEFT", region, "TOPLEFT", l, -t)
        o:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", -r, b)
        local c = self:GetAccent()
        self.host:ApplyPixelBorder(o, { c.r, c.g, c.b, c.a or 1 })
    end
    if o:IsShown() then return end
    if Fx then Fx.FadeIn(o, BEAM_DUR) else o:Show() end
end

function Popout:_HideSourceOutline()
    -- Forgotten, so the next show re-anchors: the target it comes back on may
    -- not be the one it went down against.
    self._outlineOn = nil
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
        self._outlineOn = nil
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

    -- THE SETTINGS PLACEMENT WATCHES TWO RECTS. The row alone is not enough: drag
    -- the window's right edge and the popout's whole x is wrong while the row --
    -- centred in a scroll child that just got narrower -- may not have moved at
    -- all. So the window carries its own baseline. Guarded on the mode, so the
    -- ordinary follow still pays for exactly one rect compare per tick.
    if self.outsideOf then
        local wr = rectOf(self.outsideOf)
        if wr and (wr.x ~= self._winX or wr.y ~= self._winY
                   or wr.w ~= self._winW or wr.h ~= self._winH) then
            self._winX, self._winY, self._winW, self._winH = wr.x, wr.y, wr.w, wr.h
            moved = true
        end
    end

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
    -- DIALOG, same strata as the source outline and the popout itself: on
    -- BACKGROUND the beam ran UNDER whatever window it crossed, so a settings
    -- window's scrollbar cut the link in half. The LEVEL is synced to sit just
    -- under the popout on every beam update (see _UpdateBeam) -- the "beam
    -- emerges from under the notch" trick needs it beneath the popout, and the
    -- popout is raised above the window it docks against.
    b:SetFrameStrata("DIALOG")
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
                 and self.frame:IsShown() and not self:_TetherClipped()
    local target = want and self:_TetherRegion() or nil
    local tr = target and rectOf(target) or nil
    local pr = tr and self:_FrameRect() or nil
    -- The beam starts UNDER the diamond -- at its centre, on the frame edge --
    -- and emerges through the tip. Starting AT the tip left a visible seam
    -- between the diamond's antialiased point and the line's first pixel; the
    -- beam layers below the notch, so the overlap costs nothing.
    -- (size 0 = the point ON the edge; the slide clamp only reads pr, so the
    -- slid position is identical to the notch's own.)
    -- ⚠ Not `local ax, ay = pr and PopoutNotchTip(...)` -- `and` truncates to ONE
    -- value, so ay would silently be nil and the clamp below would error.
    local ax, ay
    if pr then ax, ay = UI.PopoutNotchTip(pr, self.side, 0, tr) end
    if not (tr and pr and ax) then
        self:_HideBeam()
        return
    end
    local bx, by = UI.PopoutNearestOnRect(tr, ax, ay)
    -- The point slid with the beam: re-place it so tip and beam stay one shape
    -- while the source (or a glide) moves.
    self:_UpdateNotch()

    local b = self:_EnsureBeam()
    -- Just under the popout, every update: the popout's own level moves (it is
    -- raised over whatever window it docks against), and the beam must stay in
    -- the sliver between that window's children and the popout so the notch
    -- still covers its root.
    if b.SetFrameLevel and self.frame.GetFrameLevel then
        local pl = self.frame:GetFrameLevel() or 2
        b:SetFrameLevel(pl > 1 and pl - 1 or 1)
    end
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
--   headerControls(popout, bar) -> leftFrame, rightFrame   also ONCE per
--                 instance; either may be nil. The shell anchors them in the
--                 title bar and re-anchors the title around them
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
    po.closeBtn:SetPoint("RIGHT", bar, "RIGHT", -HDR_EDGE, 0)

    if po.pinnable then
        po.pinBtn = host:CreateGlyphButton(f, {
            texture = UI.MEDIA .. "Icons\\pin",
            size = PIN_SIZE,
            tooltip = { title = L and L["Pin"] or "Pin" },
            onClick = function() po:Pin() end,
        })
        po.pinBtn:SetPoint("RIGHT", po.closeBtn, "LEFT", -HDR_GAP, 0)
    end

    -- The title takes whatever the buttons left. Anchored to the pin (or the
    -- cross when there is none) rather than to a measured width, so the two
    -- layouts need no arithmetic between them.
    -- ☠ CreateLabelNative, not CreateLabel: on the DandersFrames host the bare
    -- name is shadowed by a POSITIONAL shim (opts lands in its `text` slot and
    -- SetText gets a table). The mover host has no shims, which is why this
    -- only ever erupts under DF. Same rule as Sections/ColorPicker.
    po.titleFS = host:CreateLabelNative(f, { size = 11, color = UI.Colors and UI.Colors.text })
    po.titleFS:SetPoint("LEFT", iconTex, "RIGHT", TITLE_GAP, 0)
    po.titleFS:SetPoint("RIGHT", po.pinBtn or po.closeBtn, "LEFT", -TITLE_GAP, 0)
    if po.titleFS.SetWordWrap then po.titleFS:SetWordWrap(false) end

    -- ---- header controls ------------------------------------------
    -- A consumer may put its own controls IN the title bar -- the shell stays
    -- ignorant of what they are and only says where they go: `left` where the
    -- icon and title start, `right` inboard of the pin/close cluster, with the
    -- title squeezed between whatever came back.
    --
    -- ONCE per instance, like build and for the same reason: these are frames,
    -- and a pooled popout re-targeted at something else re-BINDS them rather
    -- than rebuilding them. A consumer that needs them re-pointed does it from
    -- its own retarget path -- the shell has nothing to re-point them AT.
    --
    -- Nothing is touched when the consumer passes none, so the layout of every
    -- popout that has no header controls is exactly what it was.
    if type(opts.headerControls) == "function" then
        local left, right = opts.headerControls(po, bar)
        po.headerLeft, po.headerRight = left, right
        if left or right then
            -- Both points re-set together: the title's span is defined by the
            -- pair, and re-stating only the one that changed would leave it
            -- anchored to a frame the other control now sits in front of.
            po.titleFS:ClearAllPoints()
            if left then
                left:ClearAllPoints()
                left:SetPoint("LEFT", iconTex, "RIGHT", HDR_GAP, 0)
                po.titleFS:SetPoint("LEFT", left, "RIGHT", TITLE_GAP, 0)
            else
                po.titleFS:SetPoint("LEFT", iconTex, "RIGHT", TITLE_GAP, 0)
            end
            if right then
                right:ClearAllPoints()
                right:SetPoint("RIGHT", po.pinBtn or po.closeBtn, "LEFT", -HDR_GAP, 0)
                po.titleFS:SetPoint("RIGHT", right, "LEFT", -TITLE_GAP, 0)
            else
                po.titleFS:SetPoint("RIGHT", po.pinBtn or po.closeBtn, "LEFT", -TITLE_GAP, 0)
            end
        end
    end

    -- ---- content --------------------------------------------------
    -- ⚠ -(TITLE_H + PAD), not -TITLE_H. The height has always been
    -- TITLE_H + PAD + h + PAD, so anchoring the content flush against the bar put
    -- BOTH pads at the bottom: the first control sat hard against the title while
    -- 20px of nothing hung under the last one. Same height, symmetric now.
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", PAD, -(TITLE_H + PAD))
    content:SetWidth(po.width)
    content:SetHeight(1)
    po.content = content

    adopt(po, opts)
    store.pooled[opts.key] = po
    tinsert(store.live, po)

    safeCall(opts.build, po, content)
    -- ...and NOW the content exists. adopt() painted the accent a moment ago, but
    -- it ran before build, so the cascade it did had nothing to walk -- a popout
    -- with an opts.accent override would otherwise come up with chrome in its own
    -- colour and a body still in the host's. Chrome only needs painting once, so
    -- this is the cascade alone rather than a second _ApplyAccent.
    po:_CascadeAccent()
    po:_Resize()
    sweepFamily(host, po)
    return po
end
