local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- ROUNDED SURFACE -- a rounded-corner backdrop, from TWO nine-sliced textures.
--
-- ⚠ PROTOTYPE. This is a PARALLEL primitive to CreateElementBackdrop /
-- CreatePanelBackdrop, not a replacement for either, and no real settings page
-- goes through it. It exists so the rounded look can be judged in-game -- a
-- consumer's chrome workbench drives it behind a cycle button -- before anyone
-- decides whether the GUI wants it. The library names no consumer; see Core.lua.
--
-- ------------------------------------------------------------
-- ☠ WHY THIS IS NOT FIFTEEN TEXTURES ANY MORE -- read this first.
--
-- It used to be. A surface was four quarter-disc corners, four quarter-arc
-- corners and seven flat SetColorTexture strips, each one anchored to butt
-- exactly against its neighbours at a whole-number offset from the frame. The
-- arithmetic was right. The joints still opened up:
--
--     "I can see gaps when the popout animates in and out"
--
-- A butt joint between two quads is seamless only when both quads land on the
-- same DEVICE-pixel grid. Fx drives the popout's scale through a continuum of
-- fractional values, every quad is rasterised independently at each one, and two
-- neighbours whose shared edge falls near x.5 can round APART for a frame. Fifteen
-- quads is fourteen chances per frame to flicker a hairline of the world through
-- the middle of a panel. Nothing anchor-side fixes that, because nothing
-- anchor-side was wrong.
--
-- THE ENGINE HAS THE PRIMITIVE. Texture:SetTextureSliceMargins(l, t, r, b) plus
-- SetTextureSliceMode(Enum.UITextureSliceMode.Stretched) cuts ONE texture into a
-- 3 x 3: the four corner cells are held at their baked pixel size and only the
-- edge and centre cells stretch. One texture, one quad, one draw call -- there is
-- no joint to open, by construction, at any scale.
--
-- So a surface is now TWO textures:
--
--     fill   rect_rN.tga      the whole rounded rectangle
--     ring   ring_rN_wW.tga   the matching border, stroke W inside the same
--                             outline, on the sublevel above
--
-- and that is the entire object. The gaps are gone because the things that could
-- gap are gone.
--
-- ------------------------------------------------------------
-- THE SLICE CONTRACT -- margins are TEXTURE PIXELS, radius is UI UNITS.
--
-- SetTextureSliceMargins is measured in the texture's own pixels. The art is
-- baked at ONE TEXEL PER UI UNIT -- a radius-6 shape has a 6px corner band -- so
-- passing `radius` as all four margins is what is INTENDED to make `radius = 6`
-- mean "6 UI units of curve" at the far end.
--
-- That density is a contract between this file and Tools/generate_rounded.py, not
-- a quality setting: rebake at 2 texels per unit and every consumer's radius
-- changes meaning with nothing here to notice it. The generator's CANVAS note is
-- the other half of it, and test_round.lua pins the margins.
--
-- ☠ WHETHER THE ENGINE HONOURS THAT 1:1 IS NOT VERIFIED, AND THERE IS EVIDENCE
-- AGAINST IT. This has to be checked in the demo before the trial is judged.
--
-- BuzzardFrames -- which ships sliced rounded borders and has clearly fought this
-- -- states the opposite rule from live observation:
--
--     "THE ENGINE'S SLICING RULE (fit-short): a nine-sliced texture renders its
--      texels scaled by regionShort/artSize -- corners are NOT drawn at a fixed
--      art scale."
--                      (_retail_/Interface/AddOns/BuzzardFrames/UnitFrames/
--                       oUF_Shared.lua, the v90.8 header ~line 135, with four
--                       corroborating observations; and again at ~4267, "sliced
--                       masks scaled their corner with the region")
--
-- Under that rule the corner is `margin * regionShortInPhysicalPixels / artSize`,
-- so a 300-unit panel and a 26-unit row plate asked for the same radius would NOT
-- get the same curve -- which is the exact failure the old 15-piece assembly was
-- built to avoid, and which its header called out as the reason not to nine-slice.
-- Their fix is to host the texture on a frame scaled so one texel is one physical
-- pixel; that is a bigger change than this one and is not made here.
--
-- ⚠ THE SAME FILE ALSO SAYS THE OPPOSITE ("Slicing keeps thickness/radius
-- constant at any frame size", Indicators/Container.lua ~line 35), so the two
-- readings cannot both be right and neither can be settled from source comments.
--
-- HOW TO SETTLE IT, in one look: the demo puts a whole WINDOW, a POPOUT and
-- several small ROW PLATES on screen at one radius. If every corner reads the
-- same size, the 1:1 contract holds and this note can be cut down to its first
-- paragraph. If the window's corner is a great sweep while a row plate's is a
-- nick, fit-short is real and the surface needs the pixel-host treatment before
-- it can be a system.
--
-- A second, sharper tell if it IS fit-short: r4 and r6 are baked on a 16px canvas
-- and r8 on a 32px one, so under that rule R8 would render a SMALLER corner than
-- R6. Cycling the radii out of order is the giveaway, and the fix for it alone
-- would be to bake every radius on one canvas size.
--
-- ------------------------------------------------------------
-- WHICH CORNERS ARE ROUND -- and why the answer is a SHAPE, not four flags.
--
-- The old assembly could round any subset of the four, because a square corner
-- was simply an arc it did not draw. A single sliced texture cannot: the shape is
-- baked in, so every combination anyone wants is a FILE.
--
-- v1 bakes the two the trial actually uses:
--
--     all four round     panels, popouts, row plates
--     tl + tr only       a TITLE STRIP -- it sits against the top of a rounded
--                        panel, so its upper corners follow that curve while its
--                        lower edge is a straight join into the body
--
-- `opts.corners` keeps its old shape and its old reading (see normCorners), and
-- anything that is not one of those two is REFUSED with a message naming the
-- generator, rather than silently drawing the nearest thing. Adding a combination
-- means adding it to that script's SHAPES table and to SHAPE_OF below -- both, or
-- the module asks for a file that does not exist and the surface is invisible.
--
-- ------------------------------------------------------------
-- ⚠ NO SLICE SUPPORT, NO CURVE. SetTextureSliceMargins arrived around 10.0. If it
-- is missing -- an ancient client, or the headless harness -- the surface falls
-- back to a plain SetColorTexture rectangle with NO ring and flags itself
-- (`s.sliced == false`). Deliberately visibly square rather than clever: a
-- degraded surface that still looks rounded would hide the fact that the art is
-- not drawing at all.
--
-- ------------------------------------------------------------
-- Snapping is turned OFF on both textures for the pixel border's reason
-- (Theme.lua): vertex snapping rounds a quad's edges independently, so a snapped
-- surface changes SIZE by a pixel depending where it lands -- and during the very
-- animation this file exists to fix, that is a corner that visibly breathes.
-- ============================================================

local rawget, type, ipairs = rawget, type, ipairs
local setmetatable, format = setmetatable, string.format
local abs = math.abs

-- Resolved at file scope like every other media path in the pack (see
-- PopoutRow's ICON_PATH). UI.MEDIA is stamped by Core.lua, which loads first.
local ROUND_PATH = (UI.MEDIA or "") .. "Round\\"

-- What the generator actually produced. A radius or width outside these snaps
-- to the nearest one that exists rather than asking for a texture that does
-- not -- a missing file is an invisible surface, and the caller would have no
-- way to tell that apart from the surface simply not working.
local RADII  = { 4, 6, 8 }
local WIDTHS = { 1, 2 }

local DEFAULT_RADIUS = 6
local DEFAULT_WIDTH  = 1

-- The baked shapes, as the filename infix each one carries. Keep in step with
-- Tools/generate_rounded.py's SHAPES.
local SHAPE_TAG = { all = "", top = "top_" }

-- Published so a consumer (the demo's Corners button) can cycle exactly the set
-- that has art, rather than carrying its own copy of the list.
UI.Round = {
    radii  = RADII,
    widths = WIDTHS,
    shapes = { "all", "top" },
    defaultRadius = DEFAULT_RADIUS,
    defaultWidth  = DEFAULT_WIDTH,
}

-- Stretch, not tile: the edge bands are a constant run of colour, so stretching
-- them is exact and costs one quad, while tiling would repeat a 4px band across
-- 400 units for no visible difference. Resolved defensively because Enum is a
-- client global and the headless harness has to be able to stand one up; 0 is
-- Stretched's value, so the fallback is the same choice rather than a guess.
local SLICE_STRETCHED = (Enum and Enum.UITextureSliceMode and Enum.UITextureSliceMode.Stretched) or 0

-- ---- which corners are round --------------------------------------
--
-- ⚠ AN ABSENT KEY MEANS SQUARE, and only a wholly absent `opts.corners` means
-- "all four". The asymmetry is deliberate and it is the one surprising thing in
-- this file, so it is worth saying plainly: `corners = { tl = true, tr = true }`
-- has to mean TOP CORNERS ONLY, because that is what every partial table anyone
-- writes is trying to say. Reading an absent key as `true` would make that line
-- produce a fully rounded surface -- the opposite of what it looks like -- and
-- there would be no way to ask for two corners without spelling out the two you
-- do not want.
local function normCorners(c, existing)
    -- The table is ours and is re-used across a re-issue: the surface is
    -- idempotent per frame, so a second factory call must not leave the old
    -- table alive on a handle somebody is still holding.
    local t = existing or {}
    if type(c) ~= "table" then
        if existing then return existing end     -- keep what the surface had
        t.tl, t.tr, t.bl, t.br = true, true, true, true
        return t
    end
    t.tl = c.tl and true or false
    t.tr = c.tr and true or false
    t.bl = c.bl and true or false
    t.br = c.br and true or false
    return t
end

-- Which baked file a corner set asks for, or nil if nothing was baked for it.
local function shapeOf(c)
    if c.tl and c.tr and c.bl and c.br then return "all" end
    if c.tl and c.tr and not c.bl and not c.br then return "top" end
    return nil
end

-- ☠ REFUSED, NOT APPROXIMATED. A combination with no file would draw nothing at
-- all, and an invisible surface is indistinguishable from a surface that was
-- never created -- so this says exactly which combinations exist and where to add
-- another, then falls back to the fully rounded shape so the caller gets a
-- surface rather than a hole.
local function resolveShape(c)
    local shape = shapeOf(c)
    if shape then return shape end
    UI:Error(format(
        "DandersUI: CreateRoundedSurface has no art for corners tl=%s tr=%s bl=%s br=%s"
        .. " -- v1 bakes ALL FOUR round, or tl+tr only (a title strip)."
        .. " Add the combination to Tools/generate_rounded.py's SHAPES and to"
        .. " Round.lua's SHAPE_TAG, or ask for one of the two. Falling back to all four.",
        tostring(c.tl), tostring(c.tr), tostring(c.bl), tostring(c.br)))
    c.tl, c.tr, c.bl, c.br = true, true, true, true
    return "all"
end

-- ---- colour normalising -------------------------------------------
-- Takes {r,g,b,a} or {[1],[2],[3],[4]}, the two shapes every other factory in
-- the pack accepts, and answers four numbers. `fallback` is used for any
-- component the caller left out, so a partial table cannot produce a black
-- surface with no clue why.
local function unpackColor(c, fallback)
    if type(c) ~= "table" then
        if not fallback then return 1, 1, 1, 1 end
        return fallback.r or fallback[1] or 1, fallback.g or fallback[2] or 1,
               fallback.b or fallback[3] or 1, fallback.a or fallback[4] or 1
    end
    local r = c.r or c[1]
    local g = c.g or c[2]
    local b = c.b or c[3]
    local a = c.a or c[4]
    if fallback then
        r = r or fallback.r or fallback[1]
        g = g or fallback.g or fallback[2]
        b = b or fallback.b or fallback[3]
        a = a or fallback.a or fallback[4]
    end
    return r or 1, g or 1, b or 1, a or 1
end

-- Nearest value in `list`. Not a clamp: a caller asking for radius 5 wants the
-- closest thing that exists (4), not the bottom of the range.
local function nearest(list, v)
    if type(v) ~= "number" then return list[1] end
    local best, bestD = list[1], abs(v - list[1])
    for i = 2, #list do
        local d = abs(v - list[i])
        if d < bestD then best, bestD = list[i], d end
    end
    return best
end

-- ---- texture construction -----------------------------------------
--
-- Sublevels, and why they are negative. The fill sits at BACKGROUND -4 and the
-- ring at BACKGROUND -2: below one another in the order they have to paint, and
-- both below BACKGROUND 0, which is where a stock backdrop's bgFile lands. So a
-- surface that still has a square backdrop on it renders the SQUARE -- visibly
-- wrong, and wrong in a way that points straight at the missing SetBackdrop(nil)
-- rather than at this file. Everything a widget draws is ARTWORK or OVERLAY and
-- is untouched either way.
--
-- ---- and why the fill's sublevel is also the surface's NAME -------
--
-- A frame can carry MORE THAN ONE surface -- a panel and, laid over its top
-- band, the title strip that has to follow the panel's upper corners without
-- covering the ring that runs round them. Those two have to interleave: panel
-- fill, strip fill, ring. So the strip is a surface whose fill sits one sublevel
-- ABOVE the panel's and still below the panel's ring.
--
-- Two surfaces on one frame therefore CANNOT share a sublevel -- if they did,
-- which one paints first is undefined, and the whole point of having two is the
-- order. So the sublevel is what tells them apart, and there is no second
-- `opts.key` to keep in sync with it: `opts.sublevel` both places the surface and
-- names it.
local FILL_SUBLEVEL   = -4
-- How far above its own fill a surface's ring sits. The default pair is the
-- historic -4 / -2, and a surface asked for at -3 lands its (usually unwanted)
-- ring at -1 -- still below a backdrop's bgFile at 0, which is the invariant that
-- matters.
local BORDER_OFFSET   = 2

local function newTexture(frame, sublevel)
    local t = frame:CreateTexture(nil, "BACKGROUND", nil, sublevel)
    if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
    if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
    return t
end

-- Said ONCE per session, not once per surface: a client without slice support has
-- every surface fall back, and one line is the useful signal while two hundred is
-- noise that buries whatever else went wrong.
local warnedNoSlice = false

local function canSlice(t)
    return type(t.SetTextureSliceMargins) == "function"
       and type(t.SetTextureSliceMode) == "function"
end

-- ---- layout --------------------------------------------------------
-- Both textures ARE the rect. Nothing is computed from the frame's size, so the
-- surface tracks a resize for free and there is no arithmetic to round badly --
-- which was the whole of the old assembly's job and is now the engine's.
local function layout(s)
    -- WHOSE TEXTURES and WHOSE RECT are two questions. Normally one frame answers
    -- both. A title strip separates them: its textures have to be on the PANEL's
    -- frame (that is the only way to land between the panel's fill and its ring --
    -- a child frame's textures draw above every layer of its parent, so a strip
    -- parented to the title bar would paint straight over the ring it is supposed
    -- to sit under), while its rect is the BAR's. So `anchorTo` is what both
    -- textures are stretched over, and `s.frame` stays their owner.
    local f = s.anchorTo or s.frame
    s.fill:ClearAllPoints()
    s.fill:SetAllPoints(f)
    s.ring:ClearAllPoints()
    s.ring:SetAllPoints(f)
end

-- ---- what is on screen ---------------------------------------------
-- THE ONE PLACE that decides whether each texture is drawn, from the things that
-- can suppress it: the whole surface being hidden, the ring being switched off,
-- and the client having no slice support at all. Two independent switches over
-- one pair of textures is exactly the shape that grows contradictory call sites
-- if each setter does its own hiding, so every setter writes its flag and calls
-- this.
local function updateShown(s)
    local drawn = not s.hidden
    s.fill:SetShown(drawn and true or false)
    s.ring:SetShown((drawn and s.hasBorder and s.sliced) and true or false)
end

-- ---- RETEXTURE ------------------------------------------------------
-- Point both textures at the art for the current shape/radius/width and re-state
-- the slice margins, which are per RADIUS -- see THE SLICE CONTRACT above. Both
-- halves have to move together: re-pointing the file without re-stating the
-- margins draws the new art through the old radius's cut, which is the one way
-- this can be wrong that still puts a curve on screen.
local function retexture(s)
    local tag = SHAPE_TAG[s.shape]
    s.fillFile = ROUND_PATH .. "rect_" .. tag .. "r" .. s.radius
    s.ringFile = ROUND_PATH .. "ring_" .. tag .. "r" .. s.radius .. "_w" .. s.borderWidth
    if not s.sliced then return end
    local r = s.radius
    s.fill:SetTexture(s.fillFile)
    s.fill:SetTextureSliceMargins(r, r, r, r)
    s.fill:SetTextureSliceMode(SLICE_STRETCHED)
    s.ring:SetTexture(s.ringFile)
    s.ring:SetTextureSliceMargins(r, r, r, r)
    s.ring:SetTextureSliceMode(SLICE_STRETCHED)
end

-- ---- paint ----------------------------------------------------------
-- The art is flat white with the shape in its alpha, so SetVertexColor tints it.
-- On the fallback path there is no art, so the fill becomes a flat colour quad --
-- which is why painting goes through one function rather than being open-coded at
-- the two call sites that drive hover and active states.
local function paintFill(s)
    local r, g, b, a = s.fillR, s.fillG, s.fillB, s.fillA
    if s.sliced then
        s.fill:SetVertexColor(r, g, b, a)
    else
        s.fill:SetColorTexture(r, g, b, a)
    end
end

local function paintBorder(s)
    s.ring:SetVertexColor(s.borderR, s.borderG, s.borderB, s.borderA)
end

-- ---- the handle -----------------------------------------------------

local Surface = {}
local surfaceMeta = { __index = Surface }

-- Repaint the interior. This is the hover/active path -- a plate that lights up
-- under the cursor drives it on every OnEnter and OnLeave -- so it does the
-- minimum: four writes, no allocation, no relayout.
function Surface:SetFillColor(r, g, b, a)
    if type(r) == "table" then r, g, b, a = unpackColor(r) end
    self.fillR, self.fillG, self.fillB, self.fillA = r or 1, g or 1, b or 1, a or 1
    paintFill(self)
    return self
end

function Surface:SetBorderColor(r, g, b, a)
    if type(r) == "table" then r, g, b, a = unpackColor(r) end
    self.borderR, self.borderG, self.borderB, self.borderA = r or 1, g or 1, b or 1, a or 1
    paintBorder(self)
    return self
end

function Surface:GetFillColor() return self.fillR, self.fillG, self.fillB, self.fillA end
function Surface:GetBorderColor() return self.borderR, self.borderG, self.borderB, self.borderA end

-- A different radius is different art AND different margins, but the SAME two
-- textures -- nothing is created or discarded, which is what makes it cheap
-- enough for a demo's cycle button to drive on every click.
function Surface:SetRadius(radius, borderWidth)
    local r = nearest(RADII, radius or self.radius)
    local w = nearest(WIDTHS, borderWidth or self.borderWidth)
    if r == self.radius and w == self.borderWidth then return self end
    self.radius, self.borderWidth = r, w
    retexture(self)
    return self
end

function Surface:GetRadius() return self.radius, self.borderWidth end

-- Which of the four are round. A COPY, not the surface's own table: the shape is
-- resolved from that table, so handing it out would let a caller who pokes a
-- field believe they had changed the surface when nothing re-textured.
function Surface:GetCorners()
    local c = self.corners
    return { tl = c.tl, tr = c.tr, bl = c.bl, br = c.br }
end

-- Which baked shape is on screen: "all" or "top". Published because the corner
-- table no longer tells the whole story -- an unsupported combination is refused
-- and falls back, and this is where that is observable.
function Surface:GetShape() return self.shape end

-- Re-shape, which is now purely a different FILE -- no relayout (the textures
-- already are the rect) and no re-show (both are still drawn). Same two textures,
-- like SetRadius.
function Surface:SetCorners(corners)
    normCorners(corners, self.corners)
    self.shape = resolveShape(self.corners)
    retexture(self)
    return self
end

-- Show/Hide are the whole surface. `Hide` is what a caller switching BACK to a
-- square backdrop uses -- the textures are ours and nothing else will take them
-- down, exactly like the pixel border's own HidePixelBorder.
--
-- Both go through updateShown rather than touching the textures themselves: a
-- fill-only surface's ring must STAY down through a Hide/Show round trip.
function Surface:Hide()
    self.hidden = true
    updateShown(self)
    return self
end

function Surface:Show()
    self.hidden = false
    updateShown(self)
    return self
end

function Surface:IsShown() return not self.hidden end

-- The ring alone. opts.border = false starts here; a later SetBorderColor does
-- NOT bring it back on its own, because a caller repainting every state's
-- colours in one sweep must not accidentally give a fill-only surface an edge.
function Surface:SetBorderShown(shown)
    self.hasBorder = shown and true or false
    updateShown(self)
    return self
end

-- ============================================================
-- THE FACTORY
--
-- frame  any Frame. The surface parents its textures to it and stretches them
--        over its rect, so it tracks size and position for free.
-- opts   radius       4 | 6 | 8       (default 6; anything else snaps to the
--                                      nearest that has art)
--        corners      {tl=,tr=,bl=,br=}  which of the four are round. OMIT for all
--                                      four; pass a table and an ABSENT key means
--                                      SQUARE, so {tl=true,tr=true} is a
--                                      top-corners-only strip. Those TWO shapes
--                                      are what v1 bakes -- anything else is
--                                      refused with a message. See resolveShape.
--        fill         {r,g,b,a}       (default UI.Colors.element)
--        border       {r,g,b,a}       (default UI.Colors.border)
--                     false           no ring at all
--        borderWidth  1 | 2           (default 1)
--        sublevel     number          (default -4) where the fill sits, and the
--                                      surface's identity on the frame -- see the
--                                      sublevel note above. The ring lands 2 higher.
--        anchorTo     Frame/Region    (default `frame`) the rect the surface is
--                                      stretched over, when that is not the frame
--                                      its textures live on -- see layout().
--
-- Returns the handle. Idempotent per (frame, sublevel): a second call at the same
-- sublevel re-uses the surface already there rather than stacking a second pair
-- of textures on it. A DIFFERENT sublevel is a different surface, which is how a
-- panel and its title strip share one frame.
-- ============================================================
function UI:CreateRoundedSurface(frame, opts)
    if type(frame) ~= "table" or type(frame.CreateTexture) ~= "function" then
        UI:Error("DandersUI: CreateRoundedSurface needs a frame")
        return nil
    end
    opts = opts or {}
    local fillSub = opts.sublevel or FILL_SUBLEVEL
    local edgeSub = fillSub + BORDER_OFFSET

    -- rawget for the reason every private-field read in this pack uses it: on a
    -- frame that has never carried a surface the key is simply absent, and this
    -- has to see that rather than whatever an __index might invent.
    local store = rawget(frame, "_dfRoundSurfaces")
    if not store then
        store = {}
        frame._dfRoundSurfaces = store
    end

    local s = store[fillSub]
    if not s then
        s = setmetatable({ frame = frame, sublevel = fillSub }, surfaceMeta)
        s.fill = newTexture(frame, fillSub)
        s.ring = newTexture(frame, edgeSub)
        -- Kept for the same reason the 15-texture version kept them: a consumer
        -- that wants to sweep everything the surface owns should not have to know
        -- how many pieces that currently is.
        s.textures = { s.fill, s.ring }
        s.borderTextures = { s.ring }
        s.sliced = canSlice(s.fill)
        if not s.sliced and not warnedNoSlice then
            warnedNoSlice = true
            UI:Error("DandersUI: this client has no SetTextureSliceMargins --"
                     .. " rounded surfaces fall back to plain square fills with no border.")
        end
        store[fillSub] = s
    end

    s.radius      = nearest(RADII, opts.radius or s.radius or DEFAULT_RADIUS)
    s.borderWidth = nearest(WIDTHS, opts.borderWidth or s.borderWidth or DEFAULT_WIDTH)
    s.corners     = normCorners(opts.corners, s.corners)
    s.shape       = resolveShape(s.corners)
    s.anchorTo    = opts.anchorTo or s.anchorTo

    local Colors = UI.Colors or {}
    local fr, fg, fb, fa = unpackColor(opts.fill, Colors.element)
    s.fillR, s.fillG, s.fillB, s.fillA = fr, fg, fb, fa

    local hasBorder = opts.border ~= false
    local br, bg, bb, ba = unpackColor(hasBorder and opts.border or nil, Colors.border)
    s.borderR, s.borderG, s.borderB, s.borderA = br, bg, bb, ba

    layout(s)
    retexture(s)
    paintFill(s)
    paintBorder(s)
    s.hidden, s.hasBorder = false, hasBorder
    updateShown(s)
    return s
end

-- The surface already on a frame, or nil. Saves a consumer keeping its own
-- side table just to answer "have I rounded this one yet". `sublevel` picks
-- WHICH surface on a frame that carries more than one; omit it for the default.
function UI:GetRoundedSurface(frame, sublevel)
    local store = type(frame) == "table" and rawget(frame, "_dfRoundSurfaces")
    return store and store[sublevel or FILL_SUBLEVEL] or nil
end
