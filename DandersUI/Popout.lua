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

-- ============================================================
-- PERF MARKS
-- ------------------------------------------------------------
-- Core.lua's hook counters, written from INSIDE the library rather than from a
-- consumer's hook -- same `host.perf` buckets, same `UI:PerfStart` switch, same
-- `UI:PerfReport` printout, which walks whatever names it finds there and so
-- picks these up without knowing they exist.
--
-- WHY THE LIBRARY NEEDS ANY. UI:Call can only count what crosses back into the
-- consumer, and the open path's real cost was never there: it was the shell's
-- own accent cascade, and a hook counter watched it happen without seeing it.
--
-- OFF BY DEFAULT AND FREE. One rawget when nothing is recording -- the same gate
-- UI:Call itself takes -- and no timer starts and nothing is allocated until a
-- consumer calls PerfStart. The names are prefixed so a report reads the
-- library's own work apart from the consumer's hooks at a glance.
local debugprofilestop = debugprofilestop or function() return 0 end

local function perfStart(host)
    if type(host) ~= "table" or not rawget(host, "_perfActive") then return nil end
    return debugprofilestop()
end

-- t0 nil = recording was off when the work started, so nothing is recorded now:
-- a PerfStart mid-open must not book a partial call at a wild duration.
local function perfStop(host, name, t0)
    if not t0 then return end
    local p = rawget(host, "perf")
    if not p then return end
    p.counts[name] = (p.counts[name] or 0) + 1
    p.ms[name] = (p.ms[name] or 0) + (debugprofilestop() - t0)
end

-- The box model comes from the theme (see Theme.lua's note on both): the frame's
-- height is TITLE_H + PAD + content + PAD, and a consumer sizing a fixed panel
-- has to be able to work that out without reading this file.
local PAD        = UI.PopoutPad          -- outer inset around the content
local TITLE_H    = UI.PopoutTitleHeight  -- the title bar strip, top pad included
local TITLE      = UI.PopoutTitle        -- topPad / row / fill / sepAlpha
local FOOTER     = UI.PopoutFooter       -- height / btnHeight / gap / sepAlpha
-- The strip is TALLER than the row it holds: the top pad is margin, not part of
-- the row. Everything in the row therefore hangs half a top-pad BELOW the bar's
-- own centre, which is what puts it centred in the region under that margin.
-- One number, applied to the two anchors that actually reach the bar (the icon
-- on the left, the cross on the right); everything else chains off those.
local TITLE_DY   = -TITLE.topPad / 2
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
-- shape in its own right.
--
-- ⚠ THE NOTCH IS NOT RESTYLED BY opts.surface, and it does not need to be: it is
-- a POINTER, not a panel edge -- one small diamond crossing the border, which
-- reads the same whether the line it crosses is straight or curved. The beam is
-- the same case. What the rounded style DOES have to reach is everything that
-- draws a CORNER: the panel's own ring, the title strip over it, the source
-- outline, and the cross that stands in the corner box.
local NOTCH_SIZE = 10
-- Two layered lines, not one: a wide soft under-glow so the beam reads over
-- busy art, and a thin bright core so it still reads as a LINE.
local BEAM_GLOW_W, BEAM_GLOW_A = 5, 0.15
local BEAM_CORE_W, BEAM_CORE_A = 3, 0.55

-- ---- where the connected chrome sits in the frame stack ----------

-- The floor for the popout, the beam and the source outline: above the ordinary
-- UI, below the tooltip. The outsideOf placement raises all three ONE STRATA
-- ABOVE the window's instead -- see _SyncWindowLevel.
local BASE_STRATA = "DIALOG"

-- ☠ ONE STRATA ABOVE THE WINDOW, NOT A HIGH LEVEL WITHIN IT.
--
-- In outsideOf mode the beam's crossing segment is drawn over the window's body
-- on the way to the row, so it has to outrank everything the window CONTAINS and
-- not merely the window. Two attempts at that stayed inside the window's own
-- strata, and both failed in-game:
--
--   window level + 10  under the ROW itself (window -> content -> page -> scroll
--                      child -> row -> plate is already +5), and far under the
--                      widgets, which bump their own level off their container
--                      freely -- +10 for a control that has to draw over its
--                      neighbours, +50 for a disabled overlay laid across a group.
--   window level + 60  clears the deepest bump a window is known to make, with
--                      room to spare -- and STILL did not draw. Reported in-game
--                      2026-08-27 with the window at 100% scale, i.e. with the
--                      scale conversion of _SyncWindowScale already ruled out.
--
-- Danders' decisive experiment settled it. With the geometry proven correct (see
-- test_popout's section 16) and the level maths proven correct, the crossing
-- segment never rendered at DIALOG at ANY level -- and beam:SetFrameStrata
-- ("TOOLTIP") rendered it fully and correctly. The occluder was never identified;
-- what is certain is that something within DIALOG outranks any level we can set,
-- and so no arithmetic inside that strata can win. The chrome leaves the strata.
--
-- With the strata boundary doing the work the LEVEL carries none of it -- a
-- boundary is absolute, so nothing in the window's subtree reaches us whatever
-- its level -- and it goes back to being a small constant. Which it must be:
--
-- ⚠ THE WINDOW'S OWN TITLE BAR IS NOT IN THE WINDOW'S STRATA. DandersFrames'
-- settings window is DIALOG, but its title bar sits at FULLSCREEN_DIALOG 200 and
-- its close and info buttons at 210 -- in the very strata the chrome moves up to.
-- The popout must not cover those if the two ever overlap, so the chrome's level
-- has to stay well below 200. 10 leaves that whole gap spare, and still leaves the
-- beam somewhere to sit one level under the popout.
local STACK_BASE = 10

-- ---- the stacking order ------------------------------------------
--
-- ☠ ONE CONSTANT FOR EVERY DOCKED POPOUT WAS THE BUG. Every panel took
-- STACK_BASE, so two overlapping panels were peers -- one strata, one level --
-- and the client was free to interleave THEIR CONTENTS. Reported in-game as
-- "they seem to fight for order and all the settings overlap each other", which
-- is exactly what a tie between two frame subtrees looks like.
--
-- Ordering panels needs an ORDER, so the host keeps one: a list of the popouts
-- currently docked outside a window, oldest first. A popout's level is its PLACE
-- in that list:
--
--     level = STACK_BASE + (slot - 1) * STACK_STRIDE
--
-- A STRIDE, NOT +1, and that is the half that actually stops the interleave. A
-- panel is not one frame: its beam sits one level UNDER it (see
-- _SyncChromeLevel) and everything mounted IN it sits above -- the kit's widgets
-- bump themselves +5 for a hit area or a selection marker and +10 for a tooltip
-- bubble. So each panel owns a BAND, [level - 1 .. level + STACK_STRIDE - 2],
-- and the bands butt up against each other with nothing shared. 16 leaves the
-- deepest of those bumps five levels of air before the next panel's beam.
--
-- RENUMBERED, NOT COUNTED UP. The list is re-walked on every push, raise and
-- close (see reflowStack), so the live set is always slots 1..n and no counter
-- can ratchet: one panel on its own is at exactly STACK_BASE, which is the level
-- a single docked popout has always had.
--
-- STACK_SLOTS is the ceiling, and it is set by the two things above the stack.
-- The top band must stay under the window's own title bar at 200 AND still leave
-- the 50 levels of room a panel's subtree is promised (see the HEADROOM section
-- of test_popout): 10 + 7 * 16 = 122, and 122 + 50 is comfortably clear of 200.
-- Eight simultaneous docked panels means SEVEN PINNED ones, since only ever one
-- is unpinned; past that the newest share the top band rather than climbing into
-- the window's chrome.
local STACK_STRIDE = 16
local STACK_SLOTS  = 8

-- The level a slot draws at, and the whole of the arithmetic. Slots are 1-based
-- and clamp at the ceiling rather than running off the end of it.
local function stackLevel(slot)
    if not slot or slot < 1 then slot = 1 end
    if slot > STACK_SLOTS then slot = STACK_SLOTS end
    return STACK_BASE + (slot - 1) * STACK_STRIDE
end

-- The client's strata ladder, lowest first. File-local rather than published on
-- UI: this file is loaded STANDALONE by the headless tests (see
-- Tools/mover-tests/run.py, which never loads Core.lua or builds a host), so
-- anything it needs at load time has to be its own.
local STRATA_ORDER = {
    "BACKGROUND", "LOW", "MEDIUM", "HIGH",
    "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP",
}
local STRATA_RANK = {}
for i = 1, #STRATA_ORDER do STRATA_RANK[STRATA_ORDER[i]] = i end

-- A LITERAL single step, FULLSCREEN included (decided 2026-08-27). Landing the
-- DIALOG window's chrome on FULLSCREEN rather than FULLSCREEN_DIALOG is what
-- keeps the ordering sane around MENUS: the kit's dropdown menus live on
-- FULLSCREEN_DIALOG, so with the chrome one strata BELOW them, a menu opened on
-- the settings page can never land underneath a docked popout, and a menu
-- opened inside the popout beats it by strata alone (RaiseMenuOverOpener then
-- only matters for windows already on FULLSCREEN_DIALOG or above). "FULLSCREEN
-- is for full-screen effects" is idiom, not law -- nothing in the client
-- misbehaves for a small frame parked there, and the safety it buys is real.
local NEVER_LAND = {}

-- The next strata UP that we are willing to stand on, CAPPED at the top: a window
-- already on TOOLTIP has nothing above it, and answering nil there would send the
-- chrome back to the base strata -- i.e. UNDER that window -- which is worse than
-- sharing one with it. nil only for a name that is not a strata at all, so the
-- caller can fall back.
local function strataAbove(s)
    local i = STRATA_RANK[s]
    if not i then return nil end
    for j = i + 1, #STRATA_ORDER do
        if not NEVER_LAND[STRATA_ORDER[j]] then return STRATA_ORDER[j] end
    end
    return STRATA_ORDER[#STRATA_ORDER]
end

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

-- ---- the one coordinate space ------------------------------------

-- ☠ A FRAME'S OWN GEOMETRY IS NOT IN UIPARENT UNITS, and every rect in this file
-- is declared to be. GetCenter / GetWidth / GetHeight answer in the frame's OWN
-- coordinate space -- the screen divided by its EFFECTIVE scale -- and a SetPoint
-- offset is read back in that same space. So a region living under a SCALED
-- window and a popout on a scale of its own are measured with two different
-- rulers, and this file compares them constantly: the dock, the beam, the clip
-- gate and the connection point are all differences between the two.
--
-- ⚠ AND THE POPOUT IS ONE OF THE SCALED THINGS NOW. In outsideOf mode it takes
-- the window's scale as its own (see _SyncWindowScale) so its controls match the
-- page's -- so "the popout is at UIParent scale" is no longer the safe reading it
-- once was, and nothing below may assume it. Every one of these three functions
-- already converts, which is exactly why that change needed nothing else.
--
-- The error is not a rounding wobble. It is (distance from UIParent's centre) x
-- (1/scale - 1) on BOTH axes, so out at the edge of a settings window scaled to
-- 85% it is well over a hundred pixels -- which is what the beam's far end
-- stopping dead in the gutter beside its row, and the panel docking a long way
-- clear of the window, both were (in-game, 2026-08-26). DandersFrames' settings
-- window carries a user scale slider; /df popoutdemo's window carries none,
-- which is the whole reason the demo never showed this.
--
-- Note which half was NOT wrong: the source outline is ANCHORED to the region
-- rather than computed from it, so it stayed on the plate throughout. That is
-- exactly the asymmetry the report describes -- the outline lighting the row
-- while the beam pointed at empty space beside it.
--
-- This ratio converts a region's own units to UIParent's. Everything that reads
-- geometry off a frame multiplies by it; everything that hands a number BACK to
-- a frame (a SetPoint offset, a line endpoint) divides by that frame's own.
--
-- ⚠ TEXTURES AND FONTSTRINGS HAVE NO GetEffectiveScale. They are regions, so
-- they answer GetCenter/GetWidth perfectly well -- in their PARENT's space --
-- and `tetherSource` is documented as a region, not as a frame. So walk up to
-- the nearest thing that has one rather than quietly falling back to 1, which
-- would be the whole bug again for a consumer that tethers to a texture.
local function scaleRatio(region)
    local us = UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()
    if type(us) ~= "number" or us <= 0 then return 1 end
    local node, hops = region, 0
    while node and hops < 8 do
        local es = node.GetEffectiveScale and node:GetEffectiveScale()
        if type(es) == "number" and es > 0 then return es / us end
        node = node.GetParent and node:GetParent() or nil
        hops = hops + 1
    end
    return 1
end

-- Rect of a region in UIParent-centre units, inset to its ink; nil while it has
-- no geometry yet.
local function rectOf(region)
    if not region or not region.GetCenter then return nil end
    local cx, cy = region:GetCenter()
    if not cx then return nil end
    local ux, uy = UIParent:GetCenter()
    local w, h = region:GetWidth() or 0, region:GetHeight() or 0
    local l, r, t, b = insetOf(region)
    if l ~= 0 or r ~= 0 or t ~= 0 or b ~= 0 then
        -- Trimming the left edge moves the centre right by half of it, and so on
        -- round the four; the size loses both edges of each axis.
        -- ⚠ IN THE REGION'S OWN UNITS, before the conversion below. popoutInset
        -- is declared by the region in the units it lays ITSELF out in -- a row's
        -- 6px gap is 6 design pixels, not 6 screen ones -- so trimming after the
        -- scaling would take a scaled edge off an unscaled number.
        cx, cy = cx + (l - r) / 2, cy + (b - t) / 2
        w, h = max(w - l - r, 0), max(h - t - b, 0)
    end
    -- ...and into UIParent-centre units, which is what every caller believes it
    -- has been handed. Exactly a no-op at scale 1, which is most of them.
    local k = scaleRatio(region)
    return { x = cx * k - ux, y = cy * k - uy, w = w * k, h = h * k }
end

-- A frame's own size in UIParent units -- rectOf's pair, for the callers that
-- want a size without a position (the dock and the glide both have to size the
-- popout before they know where it is going).
local function sizeOf(frame)
    if not frame then return 0, 0 end
    local k = scaleRatio(frame)
    return (frame:GetWidth() or 0) * k, (frame:GetHeight() or 0) * k
end

-- Place a frame at a UIParent-centre position. The offset goes back into the
-- FRAME's own units on the way out -- the return leg of rectOf, and the reason
-- this is one function rather than four copies of the same SetPoint.
local function placeAt(frame, x, y)
    local k = scaleRatio(frame)
    frame:SetPoint("CENTER", UIParent, "CENTER", x / k, y / k)
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

-- ...and the same guard for a predicate, whose ANSWER is the point. A consumer's
-- `enabled` may read the client (combat lockdown, an addon that is not loaded),
-- so it must not be able to take the repaint down with it -- and a predicate that
-- errored is taken as ENABLED, because greying a button on the strength of a bug
-- would leave the user with no way in and nothing on screen to explain it.
local function safeEval(fn)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = xpcall(fn, geterrorhandler())
    if not ok then return nil end
    return a, b
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
        -- `stack` is the DOCKED set in z-order, oldest first -- see THE STACKING
        -- ORDER. A popout only joins it while it is docked outside a window; the
        -- mover's placement has no window to stand over and so keeps no order.
        s = { pooled = {}, live = {}, stack = {} }
        rawset(host, "_popouts", s)
    end
    -- A host whose store predates the stacking order (nothing does in one
    -- session, but the store is built lazily and read from several files) still
    -- has to answer a list here rather than nil.
    if not s.stack then s.stack = {} end
    return s
end

-- ---- the stacking order, per host --------------------------------

-- Re-walk the docked stack, oldest first, and hand every member the level its
-- PLACE says. Cheap enough to run on every push and every close: the list holds
-- the panels docked outside a window RIGHT NOW, which is one plus however many
-- the user has pinned.
local function reflowStack(host)
    local st = storeFor(host).stack
    for i = 1, #st do
        local po = st[i]
        po._stackSlot = i
        po:_ApplyStackLevel()
    end
end

-- Put `po` on TOP: the newest open, and every raise, goes in front of everything
-- already up. Removed first, so a raise MOVES it rather than listing it twice.
local function pushStack(po)
    local st = storeFor(po.host).stack
    for i = #st, 1, -1 do
        if st[i] == po then tremove(st, i) end
    end
    st[#st + 1] = po
    reflowStack(po.host)
end

-- ...and out of it, for a popout that closed or that left the docked placement.
-- The slot is forgotten with it, so the next push earns a fresh one from the top
-- rather than reclaiming the place it used to hold.
local function popStack(po)
    local st = storeFor(po.host).stack
    local found = false
    for i = #st, 1, -1 do
        if st[i] == po then tremove(st, i); found = true end
    end
    po._stackSlot = nil
    if found then reflowStack(po.host) end
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
-- The mode also binds the popout to the window's SCALE and to its place in the
-- frame stack: the panel renders at the window's scale so its controls match the
-- page's, and the panel, the beam and the source outline are all raised clear of
-- the window and everything in it. See _SyncWindowScale and _SyncWindowLevel.
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
    -- Docking against a window: the popout (and the beam and outline synced just
    -- under it) must render ABOVE that window AND EVERYTHING IN IT -- a scrollbar,
    -- a page, a group overlay sitting on top of the beam reads as the link being
    -- cut. Strata, level and scale all key off the window, so all three are
    -- re-derived here rather than only on the tick: a popout handed a new window
    -- (or handed none) must not spend a frame in the old one's stack.
    self:_SyncWindowLevel()
    if self.outsideOf then
        self:_SyncWindowScale()
    elseif not self.pinned then
        -- Pinning is the one thing that keeps a scale it was given: a pinned
        -- panel has visually detached from the window, and shrinking it back to
        -- 1.0 under the user's hand would read as the panel jumping.
        self:_ClearWindowScale()
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
--
-- ⚠ NOT run through placeAt, deliberately: x/y come from the CONSUMER's own
-- layout, not from this file's rect maths, so they are already an offset in the
-- popout frame's own units -- which is what a consumer computing a position for
-- its own panel has. The conversion belongs to numbers that came out of rectOf.
function Popout:PlaceFree(x, y)
    self.free = true
    self.following = false
    self.gliding = false
    self.outsideOf = nil        -- absolute placement is not docked to anything
    self.clipTo = nil           -- ...and nothing is clipping what it is not about
    -- ...and it is not standing on a window's scale or in a window's part of the
    -- frame stack either. Both BEFORE the anchor below, because x/y are read in
    -- the frame's OWN units and the scale is what those units are.
    self:_ClearWindowScale()
    self:_SyncWindowLevel()
    local f = self.frame
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", x or 0, y or 0)
    self:_Present("CENTER")
    return self
end

-- ---- the docked popout's place in the frame stack ----------------

-- Put the beam in the sliver just under the popout: above whatever the popout is
-- standing over, below the popout itself, because the connection point has to
-- cover the root the beam emerges from.
--
-- Relative to the POPOUT, never to a window, so it is also the whole answer in
-- the mover's context -- there is no window there, and the popout's own level
-- (its parent is the unlock overlay) is the only thing the beam can be placed
-- against.
--
-- ☠ THE OUTLINE ONLY JOINS IT WHEN THERE IS A WINDOW, and the asymmetry is not
-- an oversight. Outside a window the outline is drawn OVER the window's body, so
-- it has to be lifted with everything else or it is under the very plate it is
-- outlining. WITHOUT one -- the mover -- it is a SIBLING of the thing it
-- outlines: both hang off the unlock overlay, and the default level it is built
-- with is already the one that puts it over a proxy slab at the same level.
-- Dropping it to popout-1 there would push it a level BELOW that slab and the
-- outline would simply stop being visible.
function Popout:_SyncChromeLevel()
    local f = self.frame
    if not f.GetFrameLevel then return end
    local pl = f:GetFrameLevel() or 2
    local want = pl > 1 and pl - 1 or 1
    -- Written out rather than looped: a nil beam in an ipairs list would stop the
    -- walk at index 1 and silently skip the outline behind it.
    local b, o = self.beam, self.srcOutline
    if b and b.SetFrameLevel and (b:GetFrameLevel() or 0) ~= want then b:SetFrameLevel(want) end
    if self.outsideOf and o and o.SetFrameLevel and (o:GetFrameLevel() or 0) ~= want then
        o:SetFrameLevel(want)
    end
end

-- Every piece of the connected chrome into one strata. The three are drawn as one
-- object, so they cannot be split across two strata -- a level only orders frames
-- WITHIN a strata, and a beam one strata below the window it crosses is under it
-- whatever its level says. (The notch is a TEXTURE on the popout frame, so it
-- comes along with it and is not named here.)
function Popout:_SetChromeStrata(strata)
    local f = self.frame
    if f.SetFrameStrata then f:SetFrameStrata(strata) end
    if self.beam and self.beam.SetFrameStrata then self.beam:SetFrameStrata(strata) end
    if self.srcOutline and self.srcOutline.SetFrameStrata then
        self.srcOutline:SetFrameStrata(strata)
    end
end

-- Keep the popout -- and with it the beam and the outline -- clear of the WINDOW
-- it is docked outside of: ONE STRATA ABOVE it, at the level its slot in the
-- host's stack names. See STACK_BASE for why the clearance is a strata boundary
-- and not a big number, and THE STACKING ORDER for what the level is now for.
--
-- ⚠ RE-RUN, NOT SET ONCE -- but no longer for the reason it used to be. The old
-- level was measured off the WINDOW's, and DandersFrames' settings window is
-- SetToplevel(true): it raises itself to the top of its strata the moment it is
-- clicked, WITHOUT MOVING A PIXEL, so a level taken once at Follow went stale from
-- the first click onwards. A level that is a function of the STACK is immune to
-- that -- nothing the window does can move a popout's place among its peers. What
-- the re-run still buys is a window that changes STRATA under a popout that is
-- already up, and re-asserting both against anything else that moved them. It
-- costs two getter calls on a tick that is already reading two rects, so it stays.
--
-- With no window it puts everything back on the base strata: a POOLED popout is
-- re-used for whatever the next consumer asks of it, and one that was raised for a
-- window must not carry that into a placement that has no window.
-- The level this popout's SLOT names, on the frame and on the chrome that goes
-- with it. The beam and the source outline are separate frames and are re-seated
-- through _SyncChromeLevel, which measures off the popout -- so they travel with
-- their own panel's band and never with another's.
-- ☠ THE TITLE BAR AND ITS BUTTONS RIDE THE FRAME'S LEVEL, AND MUST BE TOLD.
-- The frame itself is mouse-enabled and raises on mouse-down (see the OnMouseDown
-- wiring below), so anything in the header that is not ABOVE it is not clickable:
-- the click lands on the raise instead and the button appears dead.
--
-- That was invisible while every docked popout took one constant level, because
-- the header was built at that level and nothing moved. Once a panel's level
-- became its slot in the stack, the frame started jumping to STACK_BASE and up --
-- and the PANE keeps up because its widgets bump themselves off their container,
-- while the header is built ONCE at construction and had nothing re-seating it.
-- Body clickable, header dead, on every popout at once.
--
-- Re-asserted here rather than set at creation, because the level this has to
-- beat changes on every push, raise and close.
--
-- ⚠ TWO STEPS, NOT ONE. The bar is the DRAG surface and takes the mouse itself
-- once pinned; the buttons sit ON it. Putting both at one level makes them peers
-- and which one gets a click is then down to sibling order -- the ambiguity this
-- is fixing, moved rather than removed. The bar clears the frame, the controls
-- clear the bar.
--
-- ⚠ +1 and +2 are INSIDE the panel's own band. STACK_STRIDE is 16 and the pane
-- bumps to +10, so neither can reach the next slot's beam whatever the stack does.
local BAR_LIFT, HEADER_LIFT = 1, 2

function Popout:_SyncHeaderLevel()
    local f = self.frame
    if not f.GetFrameLevel then return end
    local base = f:GetFrameLevel() or 2
    local bar  = self.titleBar
    if bar and bar.SetFrameLevel and (bar:GetFrameLevel() or 0) ~= base + BAR_LIFT then
        bar:SetFrameLevel(base + BAR_LIFT)
    end
    -- Named one by one rather than walked: several are optional (no pin on an
    -- unpinnable popout, no header controls on most), and a nil in an ipairs
    -- list stops the walk at index 1 and silently skips everything after it --
    -- which is the same class of bug this function exists to fix.
    local want = base + HEADER_LIFT
    local parts = { self.closeBtn, self.pinBtn, self.headerLeft, self.headerRight }
    for i = 1, 4 do
        local w = parts[i]
        if w and w.SetFrameLevel and (w:GetFrameLevel() or 0) ~= want then
            w:SetFrameLevel(want)
        end
    end
end

function Popout:_ApplyStackLevel()
    local f = self.frame
    local want = stackLevel(self._stackSlot)
    if f.SetFrameLevel and (f:GetFrameLevel() or 0) ~= want then
        f:SetFrameLevel(want)
    end
    self:_SyncChromeLevel()
    self:_SyncHeaderLevel()
end

function Popout:_SyncWindowLevel()
    local win, f = self.outsideOf, self.frame
    if not win then
        if self._chromeStrata then
            self._chromeStrata = nil
            self:_SetChromeStrata(BASE_STRATA)
        end
        -- Out of the docked placement is out of the stacking order. A slot means
        -- nothing where there is no window to stand over, and a POOLED popout
        -- must not carry one into whatever its next consumer asks of it. The
        -- LEVEL is left where it is, exactly as it always has been: the mover's
        -- context places the popout under an unlock overlay and the beam is
        -- synced relative to it, so there is nothing here to assert.
        if self._stackSlot then popStack(self) end
        self:_SyncChromeLevel()
        return
    end
    -- Only when the window can actually name a strata. A surface that cannot is
    -- left alone rather than forced onto a guess.
    local ws = win.GetFrameStrata and win:GetFrameStrata()
    if type(ws) == "string" and ws ~= "" then
        local want = strataAbove(ws) or BASE_STRATA
        if self._chromeStrata ~= want then
            self._chromeStrata = want
            self:_SetChromeStrata(want)
        end
    end
    -- A SLOT IN THE HOST'S STACK, not the constant this used to be -- see THE
    -- STACKING ORDER for why one constant across every docked panel is what let
    -- two of them interleave. The strata boundary still does the work of getting
    -- the chrome over the window's whole subtree; the level now only orders the
    -- panels against EACH OTHER, and it still leaves room above the popout for
    -- its own children (which is what a dropdown menu derives its level from).
    --
    -- Claimed once, on the first sync after the popout enters the docked
    -- placement; every tick after that only re-asserts it, because this runs on
    -- the follow ticker and a fresh slot per frame would be a strobe.
    if not self._stackSlot then
        pushStack(self)         -- claims the top slot AND applies the level
    else
        self:_ApplyStackLevel()
    end
end

-- BRING IT TO THE FRONT. The newest open is on top by construction (see THE
-- STACKING ORDER); this is the other half of the same rule -- the panel the user
-- just reached for goes in front of the ones they did not.
--
-- Only meaningful for a DOCKED popout, because the stacking order IS the docked
-- set: a no-op in the mover's context, which has no window and keeps no order.
--
-- `pop` plays the little confirm pop the pin uses. It is feedback for a click
-- that would otherwise look like it did nothing -- clicking the row of a panel
-- that is already up -- and is left off for the raise a mouse-down does, where
-- the click has a consequence of its own.
function Popout:Raise(pop)
    if self.closed then return self end
    if self.outsideOf then pushStack(self) end
    if pop and Fx then Fx.PopIn(self.frame, PIN_DUR, 0, 0, 0.98, "CENTER") end
    return self
end

-- ---- the docked popout's scale -----------------------------------

-- MATCH THE WINDOW'S SCALE. A settings window carries a user scale slider, and a
-- popout parented to UIParent renders at 1.0 whatever that slider says -- so a
-- slider inside the panel came up visibly bigger than the identical slider on the
-- page it was opened from, and the two stopped reading as one surface.
--
-- SetScale is relative to the PARENT, so the value is the window's effective
-- scale over the popout parent's. Everything downstream keeps working unchanged:
-- every rect in this file is in UIParent units and every one of them converts
-- through the frame's own ratio already (see rectOf / sizeOf / placeAt), so the
-- dock, the beam endpoints, the notch slide and the glide landing all follow.
--
-- ⚠ ONLY IN outsideOf MODE, and only ever undone by _ClearWindowScale. A consumer
-- that scaled a popout it placed itself is never touched.
function Popout:_SyncWindowScale()
    local win, f = self.outsideOf, self.frame
    if not (win and f.SetScale) then return end
    local we = win.GetEffectiveScale and win:GetEffectiveScale()
    if type(we) ~= "number" or we <= 0 then return end
    local parent = f.GetParent and f:GetParent() or nil
    local pe = parent and parent.GetEffectiveScale and parent:GetEffectiveScale()
    if type(pe) ~= "number" or pe <= 0 then
        pe = UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()
    end
    if type(pe) ~= "number" or pe <= 0 then pe = 1 end
    local want = we / pe
    if self._winScale == want then return end
    self._winScale = want
    f:SetScale(want)
end

function Popout:_ClearWindowScale()
    if not self._winScale then return end
    self._winScale = nil
    if self.frame.SetScale then self.frame:SetScale(1) end
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
        -- BEFORE the frame is measured. The popout wears the window's scale, and
        -- its size in UIParent units is a function of that scale -- measuring
        -- first would dock a panel at the previous scale's height. The level goes
        -- with it so a re-dock after a window raise lands back on top.
        self:_SyncWindowScale()
        self:_SyncWindowLevel()
    end
    local fw, fh = sizeOf(f)
    if wr then
        -- Its own baseline, alongside the source's: a pure width-resize moves the
        -- window's edge without moving the row at all (see _Tick).
        self._winX, self._winY, self._winW, self._winH = wr.x, wr.y, wr.w, wr.h
        local side, x, y = UI.PopoutOutsidePos(wr, sr, fw, fh,
                                               DOCK_GAP, UIParent:GetWidth() or 0,
                                               UIParent:GetHeight() or 0, self.forcedSide)
        f:ClearAllPoints()
        placeAt(f, x, y)
        self.side = side
        self:_Present(side)
        return
    end
    self._winX, self._winY, self._winW, self._winH = nil, nil, nil, nil

    local side = self:_PickSide(sr, fw, fh)
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
--
-- The footer is the one thing added to that sum, and ONLY when there is one: a
-- popout whose consumer declared no actions never builds the strip, `_footerOn`
-- is nil, and the arithmetic is the number it has always been. That is the whole
-- of the "existing consumers are untouched" promise, stated once, here.
function Popout:_Resize()
    local h = self.content:GetHeight() or 0
    self.frame:SetHeight(TITLE_H + PAD + h + PAD + (self._footerOn and FOOTER.height or 0))
    return self
end
Popout.Resize = Popout._Resize      -- public: call after changing content height

-- ============================================================
-- THE FOOTER
-- A strip along the bottom carrying the consumer's `actions` -- verbs about the
-- panel AS A WHOLE, which is why they are not in the content: a control in the
-- column reads as one more setting, and "reset every setting behind this row" is
-- not one of them.
--
-- ☠ THE CONTENT IS PER-ADOPT, NOT PER-BUILD, and that is forced by the pool. One
-- popout instance serves EVERY row on its host (PopoutRow's swapTo re-targets the
-- same object), so the actions belong to whichever row currently has the panel --
-- exactly like the title, the accent and the header toggle. Rendered once at
-- build, row two would be looking at row one's buttons and pressing them would
-- reset row one's settings. So the render runs on every adopt and on every bind,
-- and the BUTTONS are pooled on the instance so re-rendering costs no frames.
--
-- The strip is TRANSPARENT: a 1px rule at its top and nothing else. The rounded
-- surface paints the panel's bottom corners on the FRAME, and a filled strip laid
-- over them -- a child's textures draw above every layer of its parent -- would
-- square them off. A transparent one cannot.
--
-- GREYING. The footer joins the row's OFF GATE (PopoutRow.lua): a row whose
-- toggle is off greys its whole pane, and the footer greys with it. The
-- alternative was to leave it live, and that reads as "this button still does
-- something to a feature that is switched off" -- the same lie the gate exists to
-- stop the pane telling. The popout's own header toggle, pin and cross stay live
-- either way; the footer is body, not chrome.
-- ============================================================

-- One press's worth of state lives on the POPOUT, not on the button, because
-- every way a press can END is something that happens to the panel: it closes,
-- it is swept by its family, its source goes away. See _CancelHold.
local function footerButton(po, i)
    local pool = po._footerBtns
    local btn = pool[i]
    if btn then return btn end

    -- ☠ CreateButtonNative: on the DandersFrames host the bare name is
    -- shadowed by a POSITIONAL shim (the opts table would land in its `text`
    -- argument and SetText a table). Same rule as the title label above.
    btn = po.host:CreateButtonNative(po._footer, {
        -- fitText = false, and the width comes from the SHARE below. Two rows
        -- share this instance and their labels differ, so a button that grew to
        -- its first label would be the wrong width for its second -- and the
        -- factory's fit is grow-only, so it could never shrink back. Equal
        -- widths are the point here anyway, which is the case fitText = false
        -- documents itself for.
        text = "", height = FOOTER.btnHeight, fitText = false,
        onClick = function(self)
            -- The CURRENT descriptor, read at press time off the button. A
            -- closure over the descriptor this button was BUILT for would fire
            -- the previous row's action after a swap.
            local act = self._dfAct
            -- A hold button's press is not a click: the down and the up are the
            -- gesture, and the click that follows the up must not run it again.
            if act and not act.hold then safeCall(act.onClick, po) end
        end,
    })
    -- ---- the press-and-hold contract ------------------------------
    -- ☠ onHoldEnd FIRES EXACTLY ONCE PER onHoldStart, and never without one.
    -- It is the RESTORE half of a preview: miss it and the user is left looking
    -- at defaults with their own settings gone; run it twice and the second
    -- restore replays a snapshot that was already spent. So the three scripts
    -- below and the panel's own Close all funnel into ONE door, _CancelHold,
    -- and the flag it clears is what makes the second caller a no-op.
    btn:SetScript("OnMouseDown", function(self)
        if self.dfDisabled then return end
        local act = self._dfAct
        if not (act and act.hold) then return end
        po:_CancelHold("restart")           -- a hold already up cannot outlive this one
        po._holdBtn = self
        safeCall(act.onHoldStart, po)
    end)
    -- The client delivers OnMouseUp to the button that was PRESSED even when the
    -- cursor has since left it, which is the case that matters: a user who holds
    -- and drifts off the button still expects their settings back.
    btn:SetScript("OnMouseUp", function(self)
        if po._holdBtn == self then po:_CancelHold("mouseup") end
    end)
    -- The strip going down under a live press -- the footer re-rendered with
    -- fewer buttons, the panel hidden by hand. In game a hidden parent fires
    -- OnHide on its children, so this catches the panel too; Close catches it
    -- again, and the flag makes the pair one call.
    btn:SetScript("OnHide", function(self)
        if po._holdBtn == self then po:_CancelHold("hide") end
    end)
    -- The tooltip is REBUILT on every refresh (the disabled reason is part of
    -- it), so the script reads a spec off the button rather than closing over
    -- one. ShowTooltip is optional on a host -- DandersMover has no tooltips --
    -- and an absent one is silence.
    btn:SetScript("OnEnter", function(self)
        local spec = self._dfTooltip
        if spec and po.host.ShowTooltip then po.host:ShowTooltip(self, spec) end
    end)
    btn:SetScript("OnLeave", function()
        if po.host.HideTooltip then po.host:HideTooltip() end
    end)

    pool[i] = btn
    return btn
end

-- The strip itself, built on FIRST USE and kept. A consumer that never declares
-- actions never reaches this, which is what keeps its popout byte-for-byte the
-- one it had before this existed.
function Popout:_EnsureFooter()
    if self._footer then return self._footer end
    local f = self.frame

    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("BOTTOMLEFT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 0)
    bar:SetHeight(FOOTER.height)
    self._footer = bar

    -- ...and the rule above it, drawn on the FRAME rather than on the strip, for
    -- the reason the title bar's separator is: a child's textures draw above
    -- every layer of its parent, so a line on the strip would cross the panel's
    -- accent border at both ends. On the frame under the border (ARTWORK 7) the
    -- border wins the edges and the line runs the full width beneath it.
    local sep = f:CreateTexture(nil, "ARTWORK", nil, 2)
    sep:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    sep:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
    sep:SetHeight(1)
    local c = UI.Colors and UI.Colors.border
    if c then sep:SetColorTexture(c.r, c.g, c.b, FOOTER.sepAlpha) end
    self._footerSep = sep

    self._footerBtns = {}
    return bar
end

-- Fire the RESTORE half of a live hold, at most once. Every ending goes through
-- here; the nil flag is what makes the second caller free.
function Popout:_CancelHold(reason)
    local btn = self._holdBtn
    if not btn then return self end
    self._holdBtn = nil                     -- cleared FIRST: onHoldEnd may close us
    local act = btn._dfAct
    if act and act.hold then safeCall(act.onHoldEnd, self) end
    return self
end

-- Re-evaluate what each button is allowed to do, and rebuild its tooltip. Cheap
-- and idempotent by design: it runs on every adopt, every row bind and every
-- pass of the row's own refresh, because "can this be pressed" is answered by
-- things the panel is never told about (combat, an auto layout going live).
function Popout:_RefreshFooter()
    local btns = self._footerBtns
    if not (self._footerOn and btns) then return self end
    local gated = self._footerShut and true or false

    for i = 1, #btns do
        local btn = btns[i]
        local act = btn._dfAct
        if act then
            local allowed, reason = true, nil
            local e = act.enabled
            if type(e) == "function" then
                local ok, why = safeEval(e)
                -- nil = the predicate errored (safeEval swallowed it); allowed.
                if ok ~= nil then allowed = ok and true or false end
                if not allowed then reason = why end
            elseif e ~= nil then
                allowed = e and true or false
            end
            -- The row's gate is the last word, and it carries no reason of its
            -- own: the row's OWN tick is right there saying the feature is off.
            if gated then allowed = false end

            local lines
            if act.tooltipDesc or reason then
                lines = {}
                if act.tooltipDesc then lines[#lines + 1] = act.tooltipDesc end
                if reason then
                    if #lines > 0 then lines[#lines + 1] = " " end
                    lines[#lines + 1] = { text = reason, hint = true }
                end
            end
            btn._dfTooltip = { title = act.tooltip or act.text, lines = lines }

            -- SetDisabled, NOT SetEnabled: a disabled button here still has to
            -- take the mouse, because the tooltip is the only thing that says
            -- WHY it cannot be pressed. That is exactly the bargain SetDisabled
            -- documents (it stays natively clickable and relies on the owner's
            -- dfDisabled early-out, which CreateButton's OnClick and the
            -- OnMouseDown above both make).
            if btn.SetDisabled then btn:SetDisabled(not allowed) end
            -- ...and a press that was live when the answer changed ends now
            -- rather than hanging on a button nobody can release.
            if not allowed and self._holdBtn == btn then self:_CancelHold("disabled") end
        end
    end
    return self
end

-- Is the strip already showing EXACTLY this list? The layout is a function of
-- the descriptors and of nothing else -- which buttons, in which order, with
-- which labels -- so when all three match, re-running it re-anchors and
-- re-labels pooled buttons into the positions they are already in.
--
-- ⚠ Worth asking because the answer is normally YES. Opening a row's panel
-- renders the footer TWICE: adopt() puts the row's actions up, and the row's
-- bind then re-states the same table through SetActions -- see bindRow in
-- PopoutRow.lua, which does it so a PINNED instance (which never re-adopts)
-- gets the verbs of whichever row it was re-bound to.
--
-- The DESCRIPTOR is compared by identity and its TEXT by value, because those
-- are the two ways the strip can be wrong: a different action in the slot, or
-- the same action relabelled in place. `enabled` is deliberately not among them
-- -- that answer is re-asked by _RefreshFooter on every pass, which is what the
-- caller below still gets.
function Popout:_FooterMatches(list, n)
    local btns = self._footerBtns
    if not (self._footerOn and btns) then return false end
    for i = 1, n do
        local btn, act = btns[i], list[i]
        if not btn or btn._dfAct ~= act then return false end
        if btn._dfText ~= (act.text or "") then return false end
    end
    -- ...and nothing beyond them is still up. A shorter list must hide its
    -- surplus, which is layout the early-out would skip.
    for i = n + 1, #btns do
        if btns[i]._dfAct ~= nil then return false end
    end
    return true
end

-- Put `self.actions` on screen. The whole of the per-adopt story: N descriptors
-- in, N pooled buttons shown with their labels and widths, the surplus hidden,
-- and the panel re-measured only when the STRIP's presence changed.
function Popout:_RenderFooter()
    local list = self.actions
    local n = (type(list) == "table") and #list or 0

    -- Already exactly this strip: nothing to lay out, and the hold stands (it is
    -- a press on a descriptor that has not changed). The refresh below is NOT
    -- skipped with it -- "can this be pressed" is answered by things the panel is
    -- never told about, and it is the reason a second render was worth anything.
    if n > 0 and self:_FooterMatches(list, n) then
        return self:_RefreshFooter()
    end

    if n == 0 then
        -- Withdrawn (or never declared). A pooled instance re-adopted by a
        -- consumer that passes none must lose the strip entirely, not keep an
        -- empty one holding 26px of the panel open.
        if self._footer then
            self:_CancelHold("actions")
            for _, btn in ipairs(self._footerBtns) do btn:Hide(); btn._dfAct = nil end
            self._footer:Hide()
            if self._footerSep then self._footerSep:Hide() end
            if self._footerOn then
                self._footerOn = false
                self:_Resize()
            end
        end
        return self
    end

    -- From here down is the LAYOUT, which is the half worth timing: the two
    -- returns above are the strip standing still and the strip going away.
    local t0 = perfStart(self.host)
    local bar = self:_EnsureFooter()
    -- ☠ Any button whose descriptor is about to change must not still be held.
    -- Cheaper than working out whether THIS button's action survived the swap,
    -- and a hold that spans two different actions is not a thing that can mean
    -- anything.
    self:_CancelHold("render")

    -- Equal shares of the content width. Deterministic (the same two buttons are
    -- the same size on every row that opens this panel) and localisation-safe by
    -- construction: a longer translation eats its own share instead of shoving
    -- its neighbour off the strip.
    local avail = self.width or 0
    local share = (avail - FOOTER.gap * (n - 1)) / n
    if share < 1 then share = 1 end

    local btns = self._footerBtns
    for i = 1, n do
        local act = list[i]
        local btn = footerButton(self, i)
        btn._dfAct = act
        btn:SetWidth(share)
        btn:SetHeight(FOOTER.btnHeight)
        -- Remembered as well as set: it is half of what _FooterMatches compares,
        -- and reading it back off the button would mean trusting every surface a
        -- button might be (the headless stub answers a function for an unset key).
        btn._dfText = act.text or ""
        if btn.SetText then btn:SetText(btn._dfText) end
        btn:ClearAllPoints()
        if i == 1 then
            btn:SetPoint("LEFT", bar, "LEFT", PAD, 0)
        else
            btn:SetPoint("LEFT", btns[i - 1], "RIGHT", FOOTER.gap, 0)
        end
        btn:Show()
    end
    for i = n + 1, #btns do
        btns[i]:Hide()
        btns[i]._dfAct = nil
    end

    bar:Show()
    if self._footerSep then self._footerSep:Show() end
    if not self._footerOn then
        self._footerOn = true
        self:_Resize()
    end
    self:_RefreshFooter()
    perfStop(self.host, "popout:footer", t0)
    return self
end

-- Declare (or withdraw) the footer's actions on a LIVE panel. The public door:
-- a consumer that only learns its actions after the popout is up (a group reset
-- whose key set is derived by walking the pane it just built) has nothing to
-- hand CreatePopout at the moment it calls it.
function Popout:SetActions(list)
    self.actions = (type(list) == "table") and list or nil
    self:_RenderFooter()
    return self
end

-- Grey the footer WITH the pane. Called by whatever owns the pane's gate --
-- PopoutRow's toggle is the only one today -- and idempotent, so the gate can
-- state it on every refresh without checking.
function Popout:SetFooterGated(shut)
    self._footerShut = (shut and true) or nil
    return self:_RefreshFooter()
end

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
    -- Same order as the dock, and for the same reason: the size the destination is
    -- computed from is the size at the WINDOW's scale. `from` above is a position,
    -- not a size, so it is read before this and stays the honest start point.
    if self.outsideOf then
        self:_SyncWindowScale()
        self:_SyncWindowLevel()
    end
    local w, h = sizeOf(f)
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
    placeAt(f, from.x, from.y)
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
    placeAt(f, x, y)
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
-- _ApplyAccent, which re-runs ApplyPixelBorder on it whenever the COLOUR has
-- actually moved -- _UpdateSourceOutline itself only repaints on a TARGET
-- change, so it would not have noticed a colour change on a shown outline, and
-- a colour that has NOT changed leaves an outline already painted in it.
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
--
-- ☠ A SUBTREE MAY OWN ITS OWN REPAINT -- `frame.dfCascadeInto = fn(c)`, and the
-- walk hands that frame the colour and goes no further down it.
--
-- The reason is the pool, and it is a cost that GROWS. One panel serves every
-- row on a host, and each row's pane is built ONCE and then KEPT under the same
-- mount -- shown or hidden -- for the rest of the session. So the mount's
-- children are every group the user has ever opened, on every page, and a walk
-- rooted above it re-tints all of them on every open. Measured on a 14-row page
-- at 8 controls a row: 226 ApplyThemeColor calls and 292 nodes per open of ONE
-- row, still climbing. That is the stutter.
--
-- A hidden pane does not need the colour AT the moment it changes -- it needs it
-- before it is next SHOWN. So the owner takes the call, repaints the pane that is
-- actually up, and catches the rest up as they come round. The shell keeps the
-- rule (this colour, through ApplyThemeColor) and stops keeping the inventory.
local function cascadeInto(frame, c, depth)
    if type(frame) ~= "table" or depth > CASCADE_DEPTH then return end
    local own = rawget(frame, "dfCascadeInto")
    if type(own) == "function" then return own(c) end
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

-- The walk, from a root of the caller's choosing and in a colour of its choosing
-- -- the other half of the dfCascadeInto bargain above. An owner that took the
-- call for its subtree hands back the one branch it decided is worth painting,
-- and gets the shell's rules applied to it rather than a second copy of them.
--
-- ⚠ The root handed in must be BELOW the frame that carries dfCascadeInto, or
-- this re-enters that hand-off and recurses.
function Popout:CascadeInto(frame, c)
    cascadeInto(frame, c or self:GetAccent(), 0)
    return self
end

-- Rooted at the FRAME, not at the content: the title bar is not a child of the
-- content, and a consumer's header controls (a popout row's own toggle) live
-- there. A cascade that missed them would leave the one control at the top of
-- the panel in the colour everything else had just left.
function Popout:_CascadeAccent()
    local t0 = perfStart(self.host)
    cascadeInto(self.frame, self:GetAccent(), 0)
    perfStop(self.host, "popout:cascade", t0)
end

-- ---- the panel's own chrome, in whichever style it wears ----------
--
-- ONE function, two paints, because the two have to be each other's exact
-- opposite: switching a live popout between them (the chrome workbench does it
-- on a button, and a consumer that re-themes could) must leave nothing of the
-- other behind. Square leaves rounded TEXTURES on the frame (they are ours;
-- nothing else takes them down) and rounded leaves a square BACKDROP under it
-- (which would render straight over the rounded fill -- see ApplyRoundedChrome).
-- So each arm takes the other down before it paints.
function Popout:_PaintChrome(c)
    local f, s = self.frame, self.surface
    if not s then
        UI:RemoveRoundedChrome(f)
        UI:RemoveRoundedStrip(f)
        if self.titleFill then self.titleFill:Show() end
        -- The accent goes on as the panel's own 1px BORDER, which is the whole
        -- "the popout and the thing it is about share an edge" idea -- and it
        -- runs through the pixel-border machinery, so it lands on the device
        -- grid like every other outlined surface in the kit, with square
        -- corners.
        self.host:CreatePanelBackdrop(f, { borderColor = c })
        return
    end
    -- ...and rounded, the accent is the RING. Same story, same colour, same
    -- weight relationship to the row's own ring -- a curve instead of a corner.
    local panel = UI.Colors and UI.Colors.panel
    UI:ApplyRoundedChrome(f, {
        radius      = s.radius,
        borderWidth = s.borderWidth,
        fill        = panel and { panel.r, panel.g, panel.b, 1 } or nil,
        border      = { c.r, c.g, c.b, c.a or 1 },
    })
    -- The strip stops being the flat ARTWORK texture and becomes a top-corners
    -- surface under the ring, so it follows the panel's curve instead of
    -- squaring it off. See ApplyRoundedStrip for why it cannot stay a texture.
    if self.titleFill and self.titleBar then
        self.titleFill:Hide()
        -- The strip's own tokens, verbatim from the flat texture it replaces
        -- (C_PANEL at PopoutTitle's alpha) -- so the two shapes differ by their
        -- corners and by nothing else.
        UI:ApplyRoundedStrip(f, self.titleBar, s.radius,
            panel and { panel.r, panel.g, panel.b, TITLE.fill } or nil)
    end
end

-- Repaint everything the accent colours, AND everything the surface style
-- shapes. Called on every adopt, so a pooled popout re-opened after a theme
-- change comes up in the current colour rather than in whatever it was built in
-- -- and, since adopt re-resolves the style too, in the current SHAPE rather
-- than in whichever caller happened to build it.
--
-- ☠ COMPARE BEFORE PAINT. This runs TWICE on every open of a row's panel --
-- once from adopt() and again from the row's bind, which re-states the accent it
-- has just been adopted with -- and the second paint is a full re-issue of the
-- panel's backdrop (or of its rounded fill and ring) for a colour and a shape
-- that did not move. Same discipline the slider's bubble needed: nothing is
-- re-anchored, re-issued or re-textured while the answer is the one already on
-- screen.
--
-- The two things the paint is a function of are the COLOUR and the STYLE, so
-- those are what is remembered. The style by IDENTITY, which is sound because
-- ResolveSurfaceStyle hands back the very table it was given (or the host's)
-- rather than a copy of it; the colour by VALUE, because the host's accent table
-- is MUTATED IN PLACE by SetAccent -- an identity check there would sleep
-- through every theme change on the host.
function Popout:_ApplyAccent()
    local c = self:GetAccent()
    local r, g, b, a = c.r, c.g, c.b, c.a or 1
    if self._paintR ~= r or self._paintG ~= g or self._paintB ~= b
       or self._paintA ~= a or self._paintSurface ~= (self.surface or false) then
        self._paintR, self._paintG, self._paintB, self._paintA = r, g, b, a
        self._paintSurface = self.surface or false
        -- Marked at the CALL rather than inside _PaintChrome: that function has
        -- an early return in its square arm, and the mark belongs to "a paint
        -- happened" rather than to either of the two shapes.
        local t0 = perfStart(self.host)
        self:_PaintChrome(c)
        perfStop(self.host, "popout:chrome", t0)
        -- The title bar's cross, and the corner it would otherwise be standing
        -- in. BOTH modes, unconditionally: the cross has to come back to the
        -- shell's own offset on square as reliably as it moves off it when
        -- rounded, and putting the call before any branch is what makes that one
        -- statement instead of two.
        UI:InsetTitleButton(self.closeBtn, self.surface and self.surface.radius or nil)
        if self.notch then self.notch:SetVertexColor(r, g, b, a) end
        if self.srcOutline then self:_PaintSourceOutline(c) end
    end
    -- ...and the widgets INSIDE it, which are not chrome and do not read this
    -- popout's colour on their own.
    --
    -- OUTSIDE the compare, and deliberately: the CONTENT is not settled the way
    -- the chrome is. A consumer mounts more of it after the fact (the build-time
    -- cascade in the factory is exactly that case), and a pooled panel is handed
    -- a pane it has never tinted. The walk is cheap once a subtree owner has
    -- taken its own branch -- see cascadeInto.
    self:_CascadeAccent()
end

-- ---- the surface style -------------------------------------------

-- Change the style this instance wears and repaint everything that carries it.
-- The live path, for the same reason SetAccent has one: a consumer that switches
-- style under an open panel has nothing else to call.
--
-- The source OUTLINE is re-committed rather than merely repainted: which of the
-- two outlines it wears depends on the style AND on the source's declared
-- radius, and that decision is only taken when the outline (re-)anchors -- so
-- the target is forgotten first, and the next update re-decides from scratch.
function Popout:SetSurface(style)
    self.surface = UI.ResolveSurfaceStyle(self.host, style)
    self._outlineOn, self._outlineRadius = nil, nil
    self:_ApplyAccent()
    self:_UpdateSourceOutline()
    return self
end

function Popout:GetSurface() return self.surface end

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
    -- The slide is a UIParent-unit difference and the offset is read in the
    -- popout frame's own units, so it comes back through that frame's ratio.
    local nk = scaleRatio(self.frame)
    n:SetPoint("CENTER", self.frame, spec[1], ox / nk, oy / nk)
    n:Show()
end

-- ---- the source outline ------------------------------------------

-- A 1px accent outline laid over the tether source, so the popout and the thing
-- it is about wear the SAME border and the beam reads as a join between two
-- pieces of one object rather than a line to something unrelated.
--
-- ☠ AND "THE SAME BORDER" IS WHY IT HAS TWO PAINTS. The outline used to be
-- ApplyPixelBorder and nothing else, which is square by construction. Lay that
-- over a ROUNDED row plate and you get the complaint the trial actually
-- produced: a second corner around a selected object -- a hard rectangle traced
-- round a plate that had just been given a curve. The trial's answer was to
-- suppress the outline entirely in rounded mode and let the row's own active
-- ring stand for it; that only worked because the row happened to have one, and
-- it silently dropped the shell's half of the shared-edge story for every other
-- kind of source.
--
-- So the outline follows the SOURCE'S shape instead. A source declares its curve
-- on the tether contract (`region.popoutRadius`, beside the popoutInset it
-- already declares) and a rounded popout tracing a source that declares one
-- draws a rounded RING at that radius; a square source, or a square popout,
-- keeps the pixel border exactly as it shipped. The two are mutually exclusive
-- and each paint takes the other down -- see _PaintSourceOutline.
--
-- Its own frame, parented to the popout's PARENT for the same reason the beam
-- is: a consumer that parents its popouts to a session overlay (so hiding the
-- overlay suspends everything) must get this in that bargain too.
function Popout:_EnsureSourceOutline()
    if self.srcOutline ~= nil then return self.srcOutline end
    local o = CreateFrame("Frame", nil, self.frame:GetParent() or UIParent)
    -- The popout's strata, whatever that currently is: in outsideOf mode the
    -- outline is drawn OVER the window's body (it lies on a row inside it), so a
    -- frame left on the base strata with no level of its own would be under the
    -- very plate it is supposed to be outlining.
    o:SetFrameStrata(self._chromeStrata or BASE_STRATA)
    o:Hide()
    self.srcOutline = o
    self:_SyncChromeLevel()
    return o
end

-- Which curve, if any, the outline is currently wearing -- decided when it
-- anchors (that is the only moment the source, and so its declared radius, is in
-- hand) and read back by every later repaint. A rounded popout over a square
-- source answers nil and gets the pixel border, which is right: the outline is a
-- statement about the SOURCE'S edge, not about the panel's.
function Popout:_OutlineRadius(region)
    if not self.surface or type(region) ~= "table" then return nil end
    local r = rawget(region, "popoutRadius")
    return (type(r) == "number") and r or nil
end

-- Paint the outline in whichever of the two it is wearing, and take the other
-- one down. Both halves matter: a style switch under an open panel walks from
-- one to the other, and a frame left carrying both draws a square box and a
-- rounded ring at once -- which is the exact defect this whole branch exists to
-- remove, arrived at from the other direction.
function Popout:_PaintSourceOutline(c)
    local o = self.srcOutline
    if not o then return end
    c = c or self:GetAccent()
    local radius = self._outlineRadius
    if not radius then
        UI:RemoveRoundedChrome(o)
        self.host:ApplyPixelBorder(o, { c.r, c.g, c.b, c.a or 1 })
        return
    end
    UI:HidePixelBorder(o)
    -- RING ONLY. The outline lies ON TOP of the thing it is outlining, so a fill
    -- of any alpha is a pane of glass over the row -- see Round's SetFillShown.
    --
    -- The ROW weight, not the panel's. This ring has to land exactly on the
    -- source's own edge, and a source in this pack is a row plate, which the
    -- style draws at rowBorderWidth. The panel's heavier ring is the accent
    -- making a statement about itself; this one is agreeing with something.
    local s = self.surface
    UI:CreateRoundedSurface(o, {
        radius      = radius,
        borderWidth = (s and (s.rowBorderWidth or s.borderWidth)) or 1,
        fill        = false,
        border      = { c.r, c.g, c.b, c.a or 1 },
    })
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
        -- popoutInset is in the REGION's units and this frame is not the region:
        -- it hangs off the popout's parent (see _EnsureSourceOutline), so the
        -- trim is read back in THAT frame's units. Same conversion the beam makes
        -- -- which is the point, since the two have to describe one rect.
        local ik = scaleRatio(region) / scaleRatio(o)
        o:SetPoint("TOPLEFT", region, "TOPLEFT", l * ik, -t * ik)
        o:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", -r * ik, b * ik)
        -- Decided HERE and remembered, because this is the one call that has the
        -- region in hand. Every later repaint (an accent change, a style change)
        -- reads it back rather than re-deriving it from a source it would have
        -- to go and fetch again.
        self._outlineRadius = self:_OutlineRadius(region)
        self:_PaintSourceOutline()
    end
    if o:IsShown() then return end
    if Fx then Fx.FadeIn(o, BEAM_DUR) else o:Show() end
end

function Popout:_HideSourceOutline()
    -- Forgotten, so the next show re-anchors: the target it comes back on may
    -- not be the one it went down against -- and, since the shape follows the
    -- SOURCE, may not be the same shape either.
    self._outlineOn = nil
    self._outlineRadius = nil
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
        self._outlineOn, self._outlineRadius = nil, nil
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
        -- ...AND THE STACK, which is not a rect and so is not covered by the
        -- compare above. A SetToplevel window raises itself above everything in
        -- its strata when it is clicked, without moving a pixel -- and from that
        -- moment the beam's crossing segment is under the window's body. Two
        -- getter calls and a compare, on a tick that is already reading two rects.
        self:_SyncWindowLevel()
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
        -- _gX/_gY are already UIParent-centre (they came out of the same dock
        -- maths), so only the SIZE needs converting -- see sizeOf.
        local w, h = sizeOf(self.frame)
        return { x = self._gX, y = self._gY, w = w, h = h }
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
    -- The popout's own strata, which in outsideOf mode is one ABOVE the window's:
    -- on BACKGROUND the beam ran UNDER whatever window it crossed, so a settings
    -- window's scrollbar cut the link in half -- and sharing the window's strata
    -- turned out to be the same thing said a different way (see STACK_BASE).
    -- The LEVEL is synced to sit just under the popout on every beam update (see
    -- _SyncChromeLevel) -- the "beam emerges from under the notch" trick needs it
    -- beneath the popout, and both are clear of the window by the strata alone.
    b:SetFrameStrata(self._chromeStrata or BASE_STRATA)
    b:Hide()
    -- Guarded, and cached as FALSE rather than nil so the guard is asked once:
    -- a headless stub (or any surface without Line objects) simply never gets a
    -- beam, and every beam call after this no-ops instead of erroring.
    b.glow = b.CreateLine and b:CreateLine(nil, "ARTWORK", nil, -1) or false
    b.core = b.CreateLine and b:CreateLine(nil, "ARTWORK", nil, 0) or false
    self.beam = b
    self:_SyncChromeLevel()
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
    -- raised clear of whatever window it docks against, and re-raised when that
    -- window raises itself), and the beam must stay in the sliver between that
    -- window's children and the popout so the notch still covers its root.
    self:_SyncChromeLevel()
    local c = self:GetAccent()
    -- Both endpoints are UIParent-centre; a line's offsets are read in the units
    -- of the frame it belongs to, so they go back through that frame's ratio.
    local bk = scaleRatio(b)
    -- Each line stated in ONE block rather than a placement loop over
    -- `{ b.glow, b.core }` and a paint block each. This runs on every frame of a
    -- glide and on every tick that finds the source has moved, and that table
    -- was two words of garbage per frame for a pair whose membership is fixed at
    -- build.
    if b.glow then
        b.glow:SetStartPoint("CENTER", UIParent, ax / bk, ay / bk)
        b.glow:SetEndPoint("CENTER", UIParent, bx / bk, by / bk)
        b.glow:SetThickness(BEAM_GLOW_W)
        b.glow:SetColorTexture(c.r, c.g, c.b, BEAM_GLOW_A)
        b.glow:Show()
    end
    if b.core then
        b.core:SetStartPoint("CENTER", UIParent, ax / bk, ay / bk)
        b.core:SetEndPoint("CENTER", UIParent, bx / bk, by / bk)
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
        placeAt(f, at.x, at.y)
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
    -- After the re-entry guard, so a second Close books nothing: the report is
    -- about what closing COSTS, and the calls that turn straight round again are
    -- not that.
    local t0 = perfStart(self.host)
    self.closed = true
    -- ☠ FIRST, and before onClose. A hold whose panel is closing (the cross, a
    -- family sweep, the source going away) still owes its consumer the restore,
    -- and the consumer's onClose may be the thing that tears down what the
    -- restore writes into.
    self:_CancelHold("close")
    self.following = false
    self.gliding = false
    self:_StopTick()

    local store = storeFor(self.host)
    for i = #store.live, 1, -1 do
        if store.live[i] == self then tremove(store.live, i) end
    end
    -- ...and out of the stacking order, which closes the gap it leaves: the
    -- panels above it come down a slot each rather than the live set keeping a
    -- hole in it. A pooled instance re-opened later earns a fresh slot from the
    -- top, which is what "newest open is on top" means for a re-used frame.
    if self._stackSlot then popStack(self) end
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
    perfStop(self.host, "popout:close", t0)
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
    -- ☠ RE-RESOLVED ON EVERY ADOPT, and that is what keeps the style alive
    -- through the pool. A popout is handed back to whichever row asks for its
    -- key next, and a style resolved once at build would be the FIRST caller's
    -- -- so a rounded consumer that reopened a panel first opened from
    -- somewhere square would get the square one back, with no way to see why.
    -- The outline's remembered shape goes with it: which of the two paints it
    -- wears depends on this, and the next _UpdateSourceOutline re-decides.
    po.surface     = UI.ResolveSurfaceStyle(po.host, opts.surface)
    po._outlineOn, po._outlineRadius = nil, nil
    po.onClose     = opts.onClose
    po.onPin       = opts.onPin
    po.onUnpin     = opts.onUnpin          -- accepted; v1 never unpins
    po.canAutoPin  = opts.canAutoPin
    po.tetherSource = opts.tetherSource
    -- Reserved. Accepted and ignored so the call sites that will want a count
    -- badge can be written before the shell grows one.
    po.badge       = opts.badge
    po:SetHeader(opts.title, opts.icon)
    po:_ApplyAccent()
    -- ☠ ON EVERY ADOPT, not at build, and that is what makes the pool safe. The
    -- footer's CONTENT belongs to whoever has the panel now -- see THE FOOTER.
    -- The gate is cleared with it: the previous row's toggle has no say over the
    -- next row's buttons, and the row that takes the panel re-states its own.
    po._footerShut = nil
    po.actions     = (type(opts.actions) == "table") and opts.actions or nil
    po:_RenderFooter()
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
--   surface       the SURFACE STYLE this panel wears (Theme.lua's
--                 UI.SurfaceStyle). A table rounds it at that radius and border
--                 weight -- panel fill and accent ring, a top-corners title
--                 strip, the cross nudged clear of the arc, and a rounded source
--                 outline over any source that declares a radius. `false` forces
--                 SQUARE even on a host that has opted in. OMIT and the popout
--                 takes whatever the host declared, which is nothing unless the
--                 consumer called host:SetSurfaceStyle -- so an existing caller
--                 that says nothing keeps the square panel it has always had,
--                 and DandersMover is untouched
--   actions       an ARRAY of verbs about the panel as a whole, rendered as a
--                 strip along its bottom. Absent = no footer and the height the
--                 popout has always had. Re-read on EVERY adopt (the pool hands
--                 one instance to many consumers), and settable live with
--                 popout:SetActions(list). Each descriptor:
--                   text          the button's label (a display string; the
--                                 consumer localises it)
--                   tooltip       tooltip title (defaults to `text`)
--                   tooltipDesc   an optional line under it
--                   onClick(popout)             a plain action, OR
--                   hold = true with onHoldStart(popout) / onHoldEnd(popout)
--                                 press-and-hold. ☠ onHoldEnd fires EXACTLY
--                                 ONCE per onHoldStart and never without one --
--                                 on the release, on the panel closing or
--                                 hiding mid-press, and on the button being
--                                 disabled under the press
--                   enabled       boolean, or fn() -> enabled, reasonText.
--                                 Re-evaluated on every adopt, every bind and
--                                 every pass of the owner's refresh; false
--                                 greys the button and puts reasonText in its
--                                 tooltip
--   badge         reserved, accepted and ignored
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
        local t0 = perfStart(host)
        adopt(pooled, opts)
        perfStop(host, "popout:adopt", t0)
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
    f:SetFrameStrata(BASE_STRATA)
    f:SetClampedToScreen(true)
    f:SetWidth(po.width + PAD * 2)
    f:EnableMouse(true)                       -- a panel must not leak clicks through
    -- CLICK TO RAISE, and ONLY from the panel's own background. The frame already
    -- takes the mouse so it cannot leak clicks through; this is the one thing it
    -- does with them.
    --
    -- ☠ IT MUST NOT STEAL A CLICK FROM A CONTROL, and the split that guarantees
    -- that is the client's own: a widget inside the panel takes the mouse itself,
    -- so a mouse-down on a slider or a checkbox is consumed there and never
    -- reaches this handler at all. What is left over -- the padding, the body
    -- between controls, the strip under the last row -- is exactly the surface
    -- that means "this panel" rather than "this setting", and that is what raises.
    f:SetScript("OnMouseDown", function() po:Raise() end)
    f:Hide()
    f._popout = po                            -- the OnUpdate script's way back
    po.frame = f
    -- Hiding the frame by hand (a consumer's combat suspend, or the tail of the
    -- exit) must take the beam and the source outline with it: they are not
    -- children of this frame, so nothing else would.
    --
    -- ...and it must end a live footer hold, for the same reason Close does: the
    -- panel leaving the screen under a press is a press that is over. ONE hook
    -- doing both jobs rather than two -- a second HookScript on the same handler
    -- is a hook the headless stub cannot model (its HookScript REPLACES), and the
    -- two things this frame owes on hide are not worth two of them.
    if f.HookScript then
        f:HookScript("OnHide", function()
            po:HideChrome()
            po:_CancelHold("hide")
        end)
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
    -- The bar is a CHILD, and once pinned it takes the mouse itself (it is the
    -- drag surface), so the frame's own raise above stops seeing clicks on it
    -- from that moment. Same raise, wired here. It runs ALONGSIDE the drag rather
    -- than instead of it: the client fires OnMouseDown before OnDragStart, so
    -- picking a buried panel up by its bar brings it forward on the way.
    bar:SetScript("OnMouseDown", function() po:Raise() end)

    -- WHERE THE CHROME STOPS AND THE BODY STARTS, said out loud rather than left
    -- to the spacing: a slightly raised fill over the strip, and a hairline under
    -- it. Both are drawn on the FRAME, not on the bar -- the bar is a CHILD, and
    -- a child's textures draw above every layer of its parent, so a fill anchored
    -- to the bar would paint straight over the popout's accent border along the
    -- top and the two upper corners. On the frame at a sublevel BELOW the border
    -- (which lives at ARTWORK 7, see ApplyPixelBorder) the border wins the edges
    -- and the strip runs the full width underneath it, which is what makes the
    -- separator meet both side borders instead of stopping short of them.
    local titleFill = f:CreateTexture(nil, "ARTWORK", nil, 1)
    titleFill:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    titleFill:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    local fillC = UI.Colors and UI.Colors.panel
    if fillC then titleFill:SetColorTexture(fillC.r, fillC.g, fillC.b, TITLE.fill) end
    po.titleFill = titleFill

    -- ONE unit tall, not the pixel border's two device pixels. That doctrine
    -- (see Theme.lua's PIXEL BORDER) is about an edge crossing the device grid
    -- while its content SCROLLS -- this line is static inside a panel that never
    -- scrolls, and the kit's other in-surface separator (the dropdown menu's
    -- group rule) is drawn exactly this way. Matching it keeps the two one idiom.
    local titleSep = f:CreateTexture(nil, "ARTWORK", nil, 2)
    titleSep:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    titleSep:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    titleSep:SetHeight(1)
    local sepC = UI.Colors and UI.Colors.border
    if sepC then titleSep:SetColorTexture(sepC.r, sepC.g, sepC.b, TITLE.sepAlpha) end
    po.titleSep = titleSep

    local iconTex = f:CreateTexture(nil, "OVERLAY")
    iconTex:SetSize(ICON_SIZE, ICON_SIZE)
    iconTex:SetPoint("LEFT", bar, "LEFT", PAD, TITLE_DY)
    iconTex:Hide()
    po.iconTex = iconTex

    po.closeBtn = host:CreateCloseButton(f, {
        size = CLOSE_SIZE,
        onClick = function() po:Close("cross") end,
    })
    po.closeBtn:SetPoint("RIGHT", bar, "RIGHT", -HDR_EDGE, TITLE_DY)

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

    -- Once, here, for the popouts that never enter the docked stack: they keep the
    -- frame's construction level forever, so nothing else would ever call this.
    -- The docked ones are re-asserted on every push, raise and close as well.
    po:_SyncHeaderLevel()

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
