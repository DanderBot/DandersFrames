local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- ROUNDED SURFACE -- a rounded-corner backdrop, assembled from parts.
--
-- ⚠ PROTOTYPE. This is a PARALLEL primitive to CreateElementBackdrop /
-- CreatePanelBackdrop, not a replacement for either, and no real settings page
-- goes through it. It exists so the rounded look can be judged in-game -- a
-- consumer's chrome workbench drives it behind a cycle button -- before anyone
-- decides whether the GUI wants it. The library names no consumer; see Core.lua.
--
-- ------------------------------------------------------------
-- WHY IT IS BUILT THIS WAY
--
-- WoW gives a frame no rounded rectangle. The options are:
--
--   * a 9-slice / edgeFile backdrop -- one authored texture stretched over the
--     whole surface. The corner radius is then a fraction of the ART, so it
--     grows and shrinks with the frame: a 400px panel and a 26px row plate
--     drawn from the same file do not share a radius, which is the one thing a
--     corner treatment has to get right to read as a system.
--   * ONE texture per surface, regenerated at its size. Off the table -- the
--     art would have to be produced at runtime.
--   * corners as art, everything else as flat colour. That is this.
--
-- So a surface is 15 textures: 4 corner quarter-discs, 3 flat rectangles that
-- tile the interior between them, 4 corner quarter-arcs, and 4 flat strips that
-- join the arcs into a ring. The radius is then in UI UNITS and identical on
-- every surface that asks for the same number, whatever size it is.
--
-- THE 3-RECT TILING, and why it is these three. The interior splits as a
-- full-width CENTRE band inset by `radius` top and bottom, plus a TOP and a
-- BOTTOM strip that run between the corner boxes:
--
--       +--r--+---------------+--r--+
--       | TL  |      top      |  TR |   r
--       +-----+---------------+-----+
--       |          centre           |   h - 2r
--       +-----+---------------+-----+
--       | BL  |     bottom    |  BR |   r
--       +--r--+---------------+--r--+
--
-- Every edge in that diagram is an ANCHOR to the frame at a whole-number offset
-- of `radius`, never a width computed from the frame's size -- so there is
-- nothing to round badly and no seam or overlap at a fractional width or
-- height. (The alternative tiling -- a full-height centre column with side
-- strips -- is equally seamless; this one is picked because a settings surface
-- is usually much wider than it is tall, which makes the centre band the one
-- big rectangle rather than one of three tall ones.)
--
-- NOT EVERY CORNER HAS TO BE ROUND. `opts.corners` turns each of the four on or
-- off independently, and a surface that is round at the top and square at the
-- bottom is the shape a TITLE STRIP wants -- it sits against the top of a rounded
-- panel, so its upper corners have to follow that curve while its lower edge is a
-- straight join into the body. A footer strip is the same thing upside down.
--
-- A square corner is not a different texture, it is the ABSENCE of one: the arc
-- and its quarter-disc are hidden, and the flat parts that used to stop `radius`
-- short of them run all the way to the edge instead. So the corner is drawn by
-- the same strips that draw the edges, and the count of textures on screen falls
-- rather than rises:
--
--       tl round, tr square
--       ,-----+-----------------+
--      /  TL  |       top       |   <- the top strip now reaches the right edge
--     +-------+-----------------+
--
-- ☠ WHERE THE TWO RING RUNS MEET AT A SQUARE CORNER, one of them has to give
-- way. The horizontal run takes the corner (it extends to the very edge) and the
-- vertical one stops `borderWidth` short of it. A BUTT JOINT, not an overlap --
-- two translucent strips crossing would double-blend into a darker bw x bw square
-- at exactly the corner the eye is drawn to, which is a worse artefact than the
-- seam it was trying to avoid.
--
-- ONE ORIENTATION OF ART, four corners. The baked file is the TOP-LEFT corner;
-- the other three are mirrored with SetTexCoord's 8-argument form. Safe for
-- THESE textures specifically -- they are static, never tiled or wrapped, and
-- both shapes are symmetric about the diagonal so a mirror and a quarter turn
-- are the same picture. It would NOT be safe for a repeating tile.
--
-- ------------------------------------------------------------
-- ☠ THE SHIMMER CAVEAT -- read this before judging the look.
--
-- A corner box is `radius` UI units square, and UI units are only whole device
-- pixels when the frame's effective scale puts them there. At the scales people
-- actually play at (a UI scale slider times the settings window's OWN scale
-- slider) it usually does not, so the arc is resampled onto a fractional grid
-- and the corner reads slightly SOFT -- and, worse, it re-lands on a different
-- fraction every time a scrolling parent moves it, which the eye picks up as a
-- faint shimmer along the curve.
--
-- This is the same problem the pixel border was built to escape (see
-- ApplyPixelBorder in Theme.lua) and the escape route there does not transfer:
-- that one works by drawing a line THICK enough that where it lands stops
-- mattering, and a curve has no equivalent -- thickening it changes the shape.
--
-- The art is baked at ~4x the drawn size to give the resampler something to
-- work with, which is as far as the generator can help. What is left is a
-- judgement call about whether it reads acceptably at the scale the user
-- actually runs, which is exactly what the demo exists to answer. Snapping is
-- turned OFF on every texture below for the pixel border's reason: rounding a
-- quad's edges independently changes its SIZE, and a corner whose box is 5px on
-- one side of the panel and 6px on the other is worse than a soft one.
-- ============================================================

local rawget, type, ipairs, setmetatable = rawget, type, ipairs, setmetatable
local abs = math.abs

-- Resolved at file scope like every other media path in the pack (see
-- PopoutRow's ICON_PATH). UI.MEDIA is stamped by Core.lua, which loads first.
local ROUND_PATH = (UI.MEDIA or "") .. "Round\\"

-- What the generator actually produced. A radius or width outside these snaps
-- to the nearest one that exists rather than asking for a texture that does
-- not -- a missing file is an invisible corner, and the caller would have no
-- way to tell that apart from the surface simply not working.
local RADII  = { 4, 6, 8 }
local WIDTHS = { 1, 2 }

local DEFAULT_RADIUS = 6
local DEFAULT_WIDTH  = 1

-- Published so a consumer (the demo's Corners button) can cycle exactly the set
-- that has art, rather than carrying its own copy of the list.
UI.Round = {
    radii  = RADII,
    widths = WIDTHS,
    defaultRadius = DEFAULT_RADIUS,
    defaultWidth  = DEFAULT_WIDTH,
}

-- ---- the four corner orientations, as texcoords -------------------
--
-- SetTexCoord's 8-argument form assigns a texture coordinate to each of the
-- quad's four SCREEN corners, in the order (UL, LL, UR, LR). The baked art is
-- the top-left corner, so:
--
--   tl  identity          tr  mirrored in x
--   bl  mirrored in y     br  mirrored in both
--
-- Written out rather than computed: four constant tables allocated once at load
-- beat eight arithmetic expressions per texture per rebuild, and the values are
-- easier to check by eye than the flip that would produce them.
local TEXCOORD = {
    --      ULx ULy  LLx LLy  URx URy  LRx LRy
    tl = {   0,  0,   0,  1,   1,  0,   1,  1 },
    tr = {   1,  0,   1,  1,   0,  0,   0,  1 },
    bl = {   0,  1,   0,  0,   1,  1,   1,  0 },
    br = {   1,  1,   1,  0,   0,  1,   0,  0 },
}

-- Corner box anchors: which point of the frame each r x r box hangs off.
local CORNER_POINT = { tl = "TOPLEFT", tr = "TOPRIGHT", bl = "BOTTOMLEFT", br = "BOTTOMRIGHT" }
local CORNER_ORDER = { "tl", "tr", "bl", "br" }

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
-- Sublevels, and why they are negative. The fills sit at BACKGROUND -4 and the
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
    -- OFF, for the pixel border's reason (Theme.lua): vertex snapping rounds a
    -- quad's two edges independently, so a snapped r x r corner box can come out
    -- r-1 or r+1 px depending on where it lands -- and four corners of a surface
    -- disagreeing about the radius is a far worse artefact than a soft curve.
    if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
    if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
    return t
end

-- ---- layout --------------------------------------------------------
-- Everything is anchored to the FRAME at a constant offset. Nothing here reads
-- the frame's width or height, so the surface tracks a resize on its own and
-- there is no size to round badly. See THE 3-RECT TILING above.
local function layout(s)
    -- WHOSE TEXTURES and WHOSE RECT are two questions. Normally one frame answers
    -- both. A title strip separates them: its textures have to be on the PANEL's
    -- frame (that is the only way to land between the panel's fill and its ring --
    -- a child frame's textures draw above every layer of its parent, so a strip
    -- parented to the title bar would paint straight over the ring it is supposed
    -- to sit under), while its rect is the BAR's. So `anchorTo` is what everything
    -- below is measured against, and `s.frame` stays the owner of the textures.
    local f, r, bw, co = s.anchorTo or s.frame, s.radius, s.borderWidth, s.corners

    -- How far in from each corner the flat parts stop. A ROUND corner keeps its
    -- r x r box for the arc, so everything stops `r` short of it. A SQUARE one has
    -- no box, so the fills run to the very edge (0) -- and of the ring's two runs
    -- the HORIZONTAL one takes the corner while the VERTICAL one stops `bw` short,
    -- which is the butt joint the header argues for.
    local ftl = co.tl and r or 0
    local ftr = co.tr and r or 0
    local fbl = co.bl and r or 0
    local fbr = co.br and r or 0
    local vtl = co.tl and r or bw
    local vtr = co.tr and r or bw
    local vbl = co.bl and r or bw
    local vbr = co.br and r or bw

    for _, k in ipairs(CORNER_ORDER) do
        local pt = CORNER_POINT[k]
        local fillTex, edgeTex = s.cornerFill[k], s.cornerEdge[k]
        fillTex:ClearAllPoints()
        fillTex:SetPoint(pt, f, pt, 0, 0)
        fillTex:SetSize(r, r)
        edgeTex:ClearAllPoints()
        edgeTex:SetPoint(pt, f, pt, 0, 0)
        edgeTex:SetSize(r, r)
    end

    -- interior: top strip, centre band, bottom strip
    local top = s.fillTop
    top:ClearAllPoints()
    top:SetPoint("TOPLEFT", f, "TOPLEFT", ftl, 0)
    top:SetPoint("TOPRIGHT", f, "TOPRIGHT", -ftr, 0)
    top:SetHeight(r)

    -- The centre band is the one part no corner can move: it is inset by `r` top
    -- and bottom because that is where the top and bottom STRIPS stop, and those
    -- are `r` tall whether the corners beside them are round or square.
    local mid = s.fillMid
    mid:ClearAllPoints()
    mid:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -r)
    mid:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, r)

    local bot = s.fillBottom
    bot:ClearAllPoints()
    bot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", fbl, 0)
    bot:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -fbr, 0)
    bot:SetHeight(r)

    -- ring: the four straight runs between the arcs. Each one starts and ends
    -- exactly where its two arcs stop being `bw` thick (see the generator's
    -- note on why the shapes line up), so the join is flush at every radius.
    local bt = s.borderTop
    bt:ClearAllPoints()
    bt:SetPoint("TOPLEFT", f, "TOPLEFT", ftl, 0)
    bt:SetPoint("TOPRIGHT", f, "TOPRIGHT", -ftr, 0)
    bt:SetHeight(bw)

    local bb = s.borderBottom
    bb:ClearAllPoints()
    bb:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", fbl, 0)
    bb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -fbr, 0)
    bb:SetHeight(bw)

    local bl = s.borderLeft
    bl:ClearAllPoints()
    bl:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -vtl)
    bl:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, vbl)
    bl:SetWidth(bw)

    local br = s.borderRight
    br:ClearAllPoints()
    br:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -vtr)
    br:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, vbr)
    br:SetWidth(bw)
end

-- ---- what is on screen ---------------------------------------------
-- THE ONE PLACE that decides whether each of the 15 is drawn, from the three
-- things that can suppress it: the whole surface being hidden, the ring being
-- switched off, and a corner being square. Three independent switches over one
-- set of textures is exactly the shape that grows contradictory call sites if
-- each setter does its own hiding -- SetBorderShown(true) on a surface with two
-- square corners must not light their arcs -- so every setter writes its flag and
-- calls this.
local function updateShown(s)
    local drawn, ring, co = not s.hidden, s.hasBorder, s.corners
    for _, k in ipairs(CORNER_ORDER) do
        local round = drawn and co[k]
        s.cornerFill[k]:SetShown(round and true or false)
        s.cornerEdge[k]:SetShown((round and ring) and true or false)
    end
    s.fillTop:SetShown(drawn)
    s.fillMid:SetShown(drawn)
    s.fillBottom:SetShown(drawn)
    local runs = (drawn and ring) and true or false
    s.borderTop:SetShown(runs)
    s.borderBottom:SetShown(runs)
    s.borderLeft:SetShown(runs)
    s.borderRight:SetShown(runs)
end

-- Point the eight corner textures at the art for the current radius/width, and
-- turn each one to face its corner.
local function retexture(s)
    local fillFile = ROUND_PATH .. "corner_fill_r" .. s.radius
    local edgeFile = ROUND_PATH .. "corner_edge_r" .. s.radius .. "_w" .. s.borderWidth
    for _, k in ipairs(CORNER_ORDER) do
        local tc = TEXCOORD[k]
        local ft = s.cornerFill[k]
        ft:SetTexture(fillFile)
        ft:SetTexCoord(tc[1], tc[2], tc[3], tc[4], tc[5], tc[6], tc[7], tc[8])
        local et = s.cornerEdge[k]
        et:SetTexture(edgeFile)
        et:SetTexCoord(tc[1], tc[2], tc[3], tc[4], tc[5], tc[6], tc[7], tc[8])
    end
end

-- ---- paint ----------------------------------------------------------
-- The corner art is flat white with the shape in its alpha, so SetVertexColor
-- tints it; the flat parts are SetColorTexture. Two different calls for the same
-- colour, which is why repainting goes through one function rather than being
-- open-coded at the two call sites that drive hover and active states.
local function paintFill(s)
    local r, g, b, a = s.fillR, s.fillG, s.fillB, s.fillA
    s.fillTop:SetColorTexture(r, g, b, a)
    s.fillMid:SetColorTexture(r, g, b, a)
    s.fillBottom:SetColorTexture(r, g, b, a)
    for _, k in ipairs(CORNER_ORDER) do
        s.cornerFill[k]:SetVertexColor(r, g, b, a)
    end
end

local function paintBorder(s)
    local r, g, b, a = s.borderR, s.borderG, s.borderB, s.borderA
    s.borderTop:SetColorTexture(r, g, b, a)
    s.borderBottom:SetColorTexture(r, g, b, a)
    s.borderLeft:SetColorTexture(r, g, b, a)
    s.borderRight:SetColorTexture(r, g, b, a)
    for _, k in ipairs(CORNER_ORDER) do
        s.cornerEdge[k]:SetVertexColor(r, g, b, a)
    end
end

-- ---- the handle -----------------------------------------------------

local Surface = {}
local surfaceMeta = { __index = Surface }

-- Repaint the interior. This is the hover/active path -- a plate that lights up
-- under the cursor drives it on every OnEnter and OnLeave -- so it does the
-- minimum: seven writes, no allocation, no relayout.
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

-- A different radius is a different set of art AND a different set of anchors,
-- so this is a rebuild -- but of the SAME 15 textures. Nothing is created or
-- discarded, which is what makes it cheap enough for a demo's cycle button to
-- drive on every click.
function Surface:SetRadius(radius, borderWidth)
    local r = nearest(RADII, radius or self.radius)
    local w = nearest(WIDTHS, borderWidth or self.borderWidth)
    if r == self.radius and w == self.borderWidth then return self end
    self.radius, self.borderWidth = r, w
    layout(self)
    retexture(self)
    return self
end

function Surface:GetRadius() return self.radius, self.borderWidth end

-- Which of the four are round. A COPY, not the surface's own table: the layout
-- reads that table on every rebuild, so handing it out would let a caller who
-- pokes a field change the shape without a relayout and get a surface whose
-- anchors and whose visible textures disagree.
function Surface:GetCorners()
    local c = self.corners
    return { tl = c.tl, tr = c.tr, bl = c.bl, br = c.br }
end

-- Re-shape, which is a relayout (the strips move) plus a re-show (the arcs at
-- the corners that changed appear or go). Same 15 textures, like SetRadius.
function Surface:SetCorners(corners)
    normCorners(corners, self.corners)
    layout(self)
    updateShown(self)
    return self
end

-- Show/Hide are the whole surface. `Hide` is what a caller switching BACK to a
-- square backdrop uses -- the textures are ours and nothing else will take them
-- down, exactly like the pixel border's own HidePixelBorder.
--
-- Both go through updateShown rather than sweeping `textures` themselves: a
-- surface with square corners has arcs that must STAY down through a Hide/Show
-- round trip, the same way a fill-only surface's ring does.
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
-- frame  any Frame. The surface parents its textures to it and anchors
--        everything to its edges, so it tracks size and position for free.
-- opts   radius       4 | 6 | 8       (default 6; anything else snaps to the
--                                      nearest that has art)
--        corners      {tl=,tr=,bl=,br=}  which of the four are round. OMIT for all
--                                      four; pass a table and an ABSENT key means
--                                      SQUARE, so {tl=true,tr=true} is a
--                                      top-corners-only strip. See normCorners.
--        fill         {r,g,b,a}       (default UI.Colors.element)
--        border       {r,g,b,a}       (default UI.Colors.border)
--                     false           no ring at all
--        borderWidth  1 | 2           (default 1)
--        sublevel     number          (default -4) where the fill sits, and the
--                                      surface's identity on the frame -- see the
--                                      sublevel note above. The ring lands 2 higher.
--        anchorTo     Frame/Region    (default `frame`) the rect the surface is
--                                      measured against, when that is not the frame
--                                      its textures live on -- see layout().
--
-- Returns the handle. Idempotent per (frame, sublevel): a second call at the same
-- sublevel re-uses the surface already there rather than stacking a second set of
-- 15 textures on it. A DIFFERENT sublevel is a different surface, which is how a
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
        s.cornerFill, s.cornerEdge = {}, {}
        s.textures, s.borderTextures = {}, {}

        local function keep(t, isBorder)
            s.textures[#s.textures + 1] = t
            if isBorder then s.borderTextures[#s.borderTextures + 1] = t end
            return t
        end

        for _, k in ipairs(CORNER_ORDER) do
            s.cornerFill[k] = keep(newTexture(frame, fillSub))
        end
        s.fillTop    = keep(newTexture(frame, fillSub))
        s.fillMid    = keep(newTexture(frame, fillSub))
        s.fillBottom = keep(newTexture(frame, fillSub))
        for _, k in ipairs(CORNER_ORDER) do
            s.cornerEdge[k] = keep(newTexture(frame, edgeSub), true)
        end
        s.borderTop    = keep(newTexture(frame, edgeSub), true)
        s.borderBottom = keep(newTexture(frame, edgeSub), true)
        s.borderLeft   = keep(newTexture(frame, edgeSub), true)
        s.borderRight  = keep(newTexture(frame, edgeSub), true)

        store[fillSub] = s
    end

    s.radius      = nearest(RADII, opts.radius or s.radius or DEFAULT_RADIUS)
    s.borderWidth = nearest(WIDTHS, opts.borderWidth or s.borderWidth or DEFAULT_WIDTH)
    s.corners     = normCorners(opts.corners, s.corners)
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
