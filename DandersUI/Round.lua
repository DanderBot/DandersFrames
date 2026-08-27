local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- ROUNDED SURFACE -- a rounded-corner backdrop, from TWO nine-sliced textures.
--
-- A PARALLEL primitive to CreateElementBackdrop / CreatePanelBackdrop, not a
-- replacement for either. Which of the two a surface wears is the SURFACE STYLE
-- (Theme.lua's UI.SurfaceStyle, and the host opt-in beside it): a consumer that
-- declares one gets the rounded paint through the shells that read it -- the
-- popout, the popout row, the settings group -- and a consumer that declares
-- nothing keeps the square backdrop it has always had. The library names no
-- consumer; see Core.lua.
--
-- ⚠ THE TRIAL IS OVER, and the header used to say the opposite ("no real
-- settings page goes through it"). The nine-slice was judged in-game at every
-- baked radius and at four UI scales through the chrome workbench's Corners
-- button, came out gap-free through the popout's open/close animation, and the
-- settings shell now ships rounded at R8. The workbench remains -- it is still
-- the only place several radii can be compared side by side -- but it drives the
-- same first-class options every real surface does, not shadows of its own.
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
local abs, floor = math.abs, math.floor

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
    s.fill:SetShown((drawn and s.hasFill) and true or false)
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

-- The FILL alone, and the mirror of the above: opts.fill = false starts here.
--
-- ☠ RING-ONLY IS NOT "a fill at alpha zero". A surface laid OVER something the
-- caller wants to keep seeing -- the popout shell's source outline, which is a
-- ring traced round a row plate that is already painted -- must not draw an
-- interior at all. A transparent quad happens to look the same and is not: it is
-- still a texture in the stack, still rasterised, and one SetFillColor from a
-- caller repainting every state's colours in one sweep away from covering the
-- thing it was supposed to outline. So the fill is SWITCHED OFF, exactly the way
-- the ring is, and a later SetFillColor does not bring it back.
function Surface:SetFillShown(shown)
    self.hasFill = shown and true or false
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
--                     false           no interior at all -- a RING-ONLY surface,
--                                      for an outline traced over something that
--                                      has to stay visible under it
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
    local hasFill = opts.fill ~= false
    local fr, fg, fb, fa = unpackColor(hasFill and opts.fill or nil, Colors.element)
    s.fillR, s.fillG, s.fillB, s.fillA = fr, fg, fb, fa

    local hasBorder = opts.border ~= false
    local br, bg, bb, ba = unpackColor(hasBorder and opts.border or nil, Colors.border)
    s.borderR, s.borderG, s.borderB, s.borderA = br, bg, bb, ba

    layout(s)
    retexture(s)
    paintFill(s)
    paintBorder(s)
    s.hidden, s.hasFill, s.hasBorder = false, hasFill, hasBorder
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

-- ============================================================
-- THE CHROME MOVES
--
-- Three things every rounded surface in the pack has to do, gathered here rather
-- than repeated at each site -- because each of the three is a TRAP that reads as
-- a one-liner and was got wrong at least once during the trial.
-- ============================================================

-- ---- 1. the square backdrop has to come DOWN ------------------------
--
-- ☠ AND IT DOES NOT COME DOWN ON ITS OWN. The rounded fill sits at a NEGATIVE
-- BACKGROUND sublevel, UNDER a backdrop's bgFile at BACKGROUND 0 -- so a frame
-- that keeps its square backdrop renders the SQUARE, in front of a rounded
-- surface that is drawing perfectly. The failure looks like "the rounded surface
-- did not work" and is nothing of the kind, which is why this is one call.
--
-- The pixel border goes too: it lives at ARTWORK 7, ABOVE everything the surface
-- draws, so a frame that keeps it wears a hard rectangle over its own arc.
--
-- opts is CreateRoundedSurface's, verbatim. Returns the surface.
function UI:ApplyRoundedChrome(frame, opts)
    if type(frame) ~= "table" then return nil end
    if type(frame.SetBackdrop) == "function" then frame:SetBackdrop(nil) end
    UI:HidePixelBorder(frame)
    return UI:CreateRoundedSurface(frame, opts)
end

-- The way back. HIDDEN, not discarded: the textures are ours and nothing else
-- takes them down, which is the same bargain HidePixelBorder makes. The caller
-- re-issues whichever square backdrop it built with -- the pack cannot know
-- whether that was a panel or an element.
function UI:RemoveRoundedChrome(frame, sublevel)
    local s = UI:GetRoundedSurface(frame, sublevel)
    if s then s:Hide() end
    return frame
end

-- ---- 2. the title strip ---------------------------------------------
--
-- ☠ A SQUARE TITLE STRIP PAINTS OVER THE ROUNDED CORNERS, and that is the whole
-- of what "the title bar isn't rounded" turned out to be during the trial. A
-- title strip is normally a flat texture on the frame at ARTWORK 1, and ARTWORK
-- is above the whole of BACKGROUND -- where the rounded surface lives. With a
-- square backdrop that is harmless, because the pixel border sits higher again
-- (ARTWORK 7) and wins the edges. Rounded, there is no pixel border to win them:
-- the strip simply covers the two upper arcs with a square block.
--
-- So a rounded strip is a SURFACE with tl/tr round and bl/br square, at the same
-- radius as the panel, and it has to interleave with the panel's own two layers:
--
--     BACKGROUND -4   the panel's fill
--     BACKGROUND -3   THIS -- the strip, over the fill...
--     BACKGROUND -2   the panel's ring, over the strip
--
-- Under the ring or it eats the border along the top exactly the way the square
-- texture did; and a texture is only under the ring if it is on the SAME FRAME (a
-- child frame's regions draw above all of its parent's layers). Hence the split
-- between whose textures (`frame`) and whose rect (`bar`).
UI.RoundStripSublevel = -3

-- fill is {r,g,b,a} -- the caller's own strip colour, so the two modes differ by
-- their corners and by nothing else.
function UI:ApplyRoundedStrip(frame, bar, radius, fill)
    if type(frame) ~= "table" or type(bar) ~= "table" then return nil end
    return UI:CreateRoundedSurface(frame, {
        radius   = radius,
        corners  = { tl = true, tr = true },
        border   = false,
        fill     = fill,
        sublevel = UI.RoundStripSublevel,
        anchorTo = bar,
    })
end

function UI:RemoveRoundedStrip(frame)
    local s = UI:GetRoundedSurface(frame, UI.RoundStripSublevel)
    if s then s:Hide() end
    return frame
end

-- ---- 3. the title bar's buttons stand in the corner box -------------
--
-- A cross parked a fixed distance in from a bar's right edge was chosen against a
-- SQUARE panel, where "in from the edge" is the same distance whatever height you
-- read it at. Against an arc it is not: the last few units of the top band belong
-- to the curve, and a square hover box sitting in them reads as a corner laid
-- over a corner.
--
-- The fix is CLEARANCE, not a second rounded surface on the button. A tr-only
-- backdrop there would only be right if the button were flush INTO the corner,
-- which it is not (it is inset on both axes and it is a different size from the
-- corner box) -- so it would put a curve of the wrong radius beside a curve of
-- the right one, which is the same complaint again. Half the radius takes it out
-- of the corner box at every radius that has art, and costs one anchor.
function UI.SurfaceEdgeInset(radius)
    if type(radius) ~= "number" then return 0 end
    return floor(radius / 2 + 0.5)
end

-- ⚠ THE ORIGINAL OFFSET IS REMEMBERED, NOT RECOMPUTED, and it is remembered on
-- the FIRST shift only. Reading the anchor back means this stays correct if the
-- shell ever retunes its own edge inset, and means the square restore is the
-- ORIGINAL number rather than an equal-looking literal copied to a second place.
-- Storing it once is what keeps a second radius shifting from the original
-- rather than from the last shift -- compounding is the failure that looks fine
-- for three presses and walks the button across the bar in ten.
function UI:InsetTitleButton(btn, radius)
    if type(btn) ~= "table" or type(btn.GetPoint) ~= "function" then return btn end
    local point, rel, relPoint, x, y = btn:GetPoint(1)
    -- The 5-value shape or nothing. GetPoint always answers that in-game, so this
    -- is really a guard against being handed a button anchored some other way --
    -- and refusing is right there, because re-issuing a point from values that do
    -- not mean what this thinks they mean would MOVE the button somewhere
    -- arbitrary rather than leave it where it was.
    if not point or type(rel) ~= "table" then return btn end
    if rawget(btn, "_dfSquareX") == nil then btn._dfSquareX = x or 0 end
    btn:ClearAllPoints()
    -- Inboard is NEGATIVE x: every title-bar button in the pack hangs off a
    -- RIGHT anchor.
    btn:SetPoint(point, rel, relPoint, btn._dfSquareX - UI.SurfaceEdgeInset(radius), y or 0)
    return btn
end
