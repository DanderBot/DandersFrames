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
local FILL_SUBLEVEL   = -4
local BORDER_SUBLEVEL = -2

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
    local f, r, bw = s.frame, s.radius, s.borderWidth

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
    top:SetPoint("TOPLEFT", f, "TOPLEFT", r, 0)
    top:SetPoint("TOPRIGHT", f, "TOPRIGHT", -r, 0)
    top:SetHeight(r)

    local mid = s.fillMid
    mid:ClearAllPoints()
    mid:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -r)
    mid:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, r)

    local bot = s.fillBottom
    bot:ClearAllPoints()
    bot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", r, 0)
    bot:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -r, 0)
    bot:SetHeight(r)

    -- ring: the four straight runs between the arcs. Each one starts and ends
    -- exactly where its two arcs stop being `bw` thick (see the generator's
    -- note on why the shapes line up), so the join is flush at every radius.
    local bt = s.borderTop
    bt:ClearAllPoints()
    bt:SetPoint("TOPLEFT", f, "TOPLEFT", r, 0)
    bt:SetPoint("TOPRIGHT", f, "TOPRIGHT", -r, 0)
    bt:SetHeight(bw)

    local bb = s.borderBottom
    bb:ClearAllPoints()
    bb:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", r, 0)
    bb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -r, 0)
    bb:SetHeight(bw)

    local bl = s.borderLeft
    bl:ClearAllPoints()
    bl:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -r)
    bl:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, r)
    bl:SetWidth(bw)

    local br = s.borderRight
    br:ClearAllPoints()
    br:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -r)
    br:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, r)
    br:SetWidth(bw)
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

-- Show/Hide are the whole surface. `Hide` is what a caller switching BACK to a
-- square backdrop uses -- the textures are ours and nothing else will take them
-- down, exactly like the pixel border's own HidePixelBorder.
function Surface:Hide()
    for _, t in ipairs(self.textures) do t:Hide() end
    self.hidden = true
    return self
end

function Surface:Show()
    for _, t in ipairs(self.textures) do t:Show() end
    self.hidden = false
    -- The ring is a separate question from the surface being shown: a fill-only
    -- surface re-shown must not sprout a border it never had. Hidden directly
    -- rather than through SetBorderShown, which would WRITE hasBorder -- this
    -- path only ever reads it.
    if not self.hasBorder then
        for _, t in ipairs(self.borderTextures) do t:Hide() end
    end
    return self
end

function Surface:IsShown() return not self.hidden end

-- The ring alone. opts.border = false starts here; a later SetBorderColor does
-- NOT bring it back on its own, because a caller repainting every state's
-- colours in one sweep must not accidentally give a fill-only surface an edge.
function Surface:SetBorderShown(shown)
    self.hasBorder = shown and true or false
    for _, t in ipairs(self.borderTextures) do t:SetShown(self.hasBorder) end
    return self
end

-- ============================================================
-- THE FACTORY
--
-- frame  any Frame. The surface parents its textures to it and anchors
--        everything to its edges, so it tracks size and position for free.
-- opts   radius       4 | 6 | 8       (default 6; anything else snaps to the
--                                      nearest that has art)
--        fill         {r,g,b,a}       (default UI.Colors.element)
--        border       {r,g,b,a}       (default UI.Colors.border)
--                     false           no ring at all
--        borderWidth  1 | 2           (default 1)
--
-- Returns the handle. Idempotent per frame: a second call on the same frame
-- re-uses the surface already there rather than stacking a second set of 15
-- textures on it.
-- ============================================================
function UI:CreateRoundedSurface(frame, opts)
    if type(frame) ~= "table" or type(frame.CreateTexture) ~= "function" then
        UI:Error("DandersUI: CreateRoundedSurface needs a frame")
        return nil
    end
    opts = opts or {}

    local s = rawget(frame, "_dfRoundSurface")
    if not s then
        s = setmetatable({ frame = frame }, surfaceMeta)
        s.cornerFill, s.cornerEdge = {}, {}
        s.textures, s.borderTextures = {}, {}

        local function keep(t, isBorder)
            s.textures[#s.textures + 1] = t
            if isBorder then s.borderTextures[#s.borderTextures + 1] = t end
            return t
        end

        for _, k in ipairs(CORNER_ORDER) do
            s.cornerFill[k] = keep(newTexture(frame, FILL_SUBLEVEL))
        end
        s.fillTop    = keep(newTexture(frame, FILL_SUBLEVEL))
        s.fillMid    = keep(newTexture(frame, FILL_SUBLEVEL))
        s.fillBottom = keep(newTexture(frame, FILL_SUBLEVEL))
        for _, k in ipairs(CORNER_ORDER) do
            s.cornerEdge[k] = keep(newTexture(frame, BORDER_SUBLEVEL), true)
        end
        s.borderTop    = keep(newTexture(frame, BORDER_SUBLEVEL), true)
        s.borderBottom = keep(newTexture(frame, BORDER_SUBLEVEL), true)
        s.borderLeft   = keep(newTexture(frame, BORDER_SUBLEVEL), true)
        s.borderRight  = keep(newTexture(frame, BORDER_SUBLEVEL), true)

        frame._dfRoundSurface = s
    end

    s.radius      = nearest(RADII, opts.radius or s.radius or DEFAULT_RADIUS)
    s.borderWidth = nearest(WIDTHS, opts.borderWidth or s.borderWidth or DEFAULT_WIDTH)

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
    s:Show()
    s:SetBorderShown(hasBorder)
    return s
end

-- The surface already on a frame, or nil. Saves a consumer keeping its own
-- side table just to answer "have I rounded this one yet".
function UI:GetRoundedSurface(frame)
    return type(frame) == "table" and rawget(frame, "_dfRoundSurface") or nil
end
