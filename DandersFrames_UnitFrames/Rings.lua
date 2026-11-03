local addonName, UF = ...

-- ============================================================
-- RINGS (frameStyle = "RING")
-- A unit frame drawn as round bars round its portrait instead of a health bar
-- and a power bar. Per unit:
--   frameStyle  "BARS" (DandersFrames' bars, the default) | "RING"
--   ringSize    the frame's diameter: in RING style the frame is this square
--   rings       { { thickness, gap, sections = { section, ... } }, ... }
--               index 1 is the INNERMOST ring. `gap` is the space just inside
--               the ring (between it and the ring inside it, or the portrait).
--   section     { bar = "HEALTH"|"POWER"|"CLASSPOWER"|"SHIELD"|"HEALABSORB"|"INCOMING",
--                 coverage = "FULL"|"HALF"|"QUARTER",
--                 position = "TOP"|"BOTTOM"|"LEFT"|"RIGHT" (+ the four corners,
--                            for a quarter), the arc's middle,
--                 reverse = bool (counter-clockwise), feather = 0..1 (soft edge),
--                 trackColor = {r,g,b,a} or nil (the bar's own background colour) }
--
-- THE FRAME VIEW. In RING style the frame reads its settings through a view
-- (UF:FrameDB, Core.lua) that answers a few keys for it: the frame's width and
-- height are ringSize, DandersFrames' power bar, heal prediction, reduced max
-- health and overshield are off, absorbs sit on the (hidden) health bar, the
-- frame border is off and the portrait is round (R.FrameValue). Everything that
-- lays the frame out -- DandersFrames' own layout, aura rows, the mover, the
-- portrait, the cast bar -- then sees a square of ringSize and no bars, without
-- knowing about rings. The settings pages read the unit's table, never the view.
--
-- VALUES AND COLOURS ARE NOT WORKED OUT HERE:
--   * health: the frame's own (now see-through) health bar is still painted by
--     DandersFrames' updaters, colour curves, dead / offline grey, out-of-range
--     alpha and all; every write to it is copied onto the health fills
--     (R.HookHealth). One path, nothing forked, and a secret value is passed on
--     unread.
--   * power: fed here from the frame's existing UNIT_POWER_UPDATE / UNIT_MAXPOWER /
--     UNIT_DISPLAYPOWER (no event of its own), coloured by DandersFrames' own
--     resource-bar colour resolver (DF:GetResourceBarColor).
--   * class power: ClassPower.lua draws its pips INTO the ring when a ring has a
--     CLASSPOWER section (R.ClassPowerArc), on its own events and colours.
--
-- SEE-THROUGH RINGS. Each arc is a radial StatusBar (track and fill) whose
-- texture takes two masks: Blizzard's disc at the ring's OUTER diameter, and
-- Media/RingInnerMask (white outside a disc, black inside) at the INNER diameter
-- with wrap mode CLAMPTOWHITE, so only the hole is cut and the middle is clear.
-- ARC MATHS (seen in game; Blizzard's notes say otherwise): a radial fill starts
-- at the bottom (6 o'clock) and runs clockwise; StartOffset is where the arc
-- begins (a share of a turn, clockwise from the bottom) and EndOffset is how
-- much of the circle is CUT OFF, so the arc a..b is Start = a, End = 1 - (b - a).
--
-- SHIELDS, HEAL ABSORBS AND INCOMING HEALS (R.AMOUNTS). DandersFrames' own bars for
-- these stay off or hidden (R.FORCED). A radial fill has no moving edge to anchor to
-- and a secret can't be added to the health value, so nothing can sit at the tip of
-- the health fill. Each is its own radial bar, fed straight from a calculator:
--   * as a section, a ring (or part of one) of its own
--   * on the health ring (ringShow*OnHealth, R.ON_HEALTH): shield and incoming fill
--     back from the far end of each health section, heal absorb from its start
--
-- v1: the cast bar is never a ring; highlights keep the frame's square outline.
-- ============================================================

local DF = DandersFrames
if not DF then return end

local ipairs, type, tonumber, floor = ipairs, type, tonumber, math.floor

local R = { NAME = "Rings" }
UF.Rings = R

local E = UF.Elements
local K = E and E.Kit
if not (E and K) then return end

R.DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
R.HOLE = "Interface\\AddOns\\DandersFrames_UnitFrames\\Media\\RingInnerMask"

R.STYLES = { BARS = true, RING = true }
R.BARS = { HEALTH = true, POWER = true, CLASSPOWER = true, SHIELD = true, HEALABSORB = true, INCOMING = true }
R.BAR_ORDER = { "HEALTH", "POWER", "CLASSPOWER", "SHIELD", "HEALABSORB", "INCOMING" }
-- The settings each amount bar shares with its DandersFrames bar. Test data: the
-- share of max health in a sample, and the test panel switch that shows it.
R.AMOUNTS = {
    SHIELD = { texture = "absorbBarTexture", background = "absorbBarBackgroundColor", blend = "absorbBarBlendMode",
               testValue = "absorbPercent", testShow = "testShowAbsorbs" },
    HEALABSORB = { texture = "healAbsorbBarTexture", background = "healAbsorbBarBackgroundColor", blend = "healAbsorbBarBlendMode",
                   testValue = "healAbsorbPercent", testShow = "testShowAbsorbs" },
    INCOMING = { texture = "healPredictionTexture", background = "healPredictionBackgroundColor", blend = "healPredictionBlendMode",
                 testValue = "healPredictionPercent", testShow = "testShowHealPrediction" },
}
-- Drawn over each health section, bottom layer first. A far-end bar fills the other
-- way from the health fill, towards it.
R.ON_HEALTH = {
    { bar = "INCOMING", key = "ringShowIncomingOnHealth", farEnd = true },
    { bar = "SHIELD", key = "ringShowShieldOnHealth", farEnd = true },
    { bar = "HEALABSORB", key = "ringShowHealAbsorbOnHealth" },
}
R.COVERAGE = { FULL = 1, HALF = 0.5, QUARTER = 0.25 }
R.COVERAGE_ORDER = { "FULL", "HALF", "QUARTER" }
-- An arc's middle, as a share of a turn clockwise from the bottom.
R.POSITIONS = { BOTTOM = 0, BOTTOMLEFT = 0.125, LEFT = 0.25, TOPLEFT = 0.375,
                TOP = 0.5, TOPRIGHT = 0.625, RIGHT = 0.75, BOTTOMRIGHT = 0.875 }
R.SIDES = { "TOP", "BOTTOM", "LEFT", "RIGHT" }
R.CORNERS = { "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }

R.DEFAULT_SIZE = 64
R.SIZE_MIN, R.SIZE_MAX = 24, 256
R.THICK_MIN, R.THICK_MAX = 1, 40
R.GAP_MIN, R.GAP_MAX = 0, 20
R.MAX_RINGS, R.MAX_SECTIONS = 8, 4
-- Class power pips: this much of a turn clear each side of a pip.
R.PIP_GAP = 0.012

-- The default ring list (Defaults.lua, which loads first).
R.DEFAULT_RINGS = UF.RING_DEFAULTS or {}

-- ============================================================
-- SETTINGS (pure)
-- ============================================================
local function Clamp(v, lo, hi, default)
    v = tonumber(v)
    if not v then return default end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
R.Clamp = Clamp

function R.IsRing(db)
    return (db and db.frameStyle == "RING") and true or false
end

function R.Size(db)
    return floor(Clamp(db and db.ringSize, R.SIZE_MIN, R.SIZE_MAX, R.DEFAULT_SIZE) + 0.5)
end

-- A clean copy of one section (unknown values become the defaults).
function R.NormalizeSection(s)
    s = type(s) == "table" and s or {}
    local out = {
        bar = R.BARS[s.bar] and s.bar or "HEALTH",
        coverage = R.COVERAGE[s.coverage] and s.coverage or "FULL",
        position = R.POSITIONS[s.position] and s.position or "TOP",
        reverse = s.reverse and true or false,
        feather = Clamp(s.feather, 0, 1, 0),
    }
    if type(s.trackColor) == "table" then out.trackColor = s.trackColor end
    return out
end

-- The stored ring list, cleaned: at most MAX_RINGS rings of at most MAX_SECTIONS
-- sections each. A ring with no section keeps its place (an empty band).
function R.List(db)
    local src = db and db.rings
    if type(src) ~= "table" then src = R.DEFAULT_RINGS end
    local out = {}
    for _, ring in ipairs(src) do
        if #out >= R.MAX_RINGS then break end
        if type(ring) == "table" then
            local secs = {}
            for _, s in ipairs(type(ring.sections) == "table" and ring.sections or {}) do
                if #secs >= R.MAX_SECTIONS then break end
                secs[#secs + 1] = R.NormalizeSection(s)
            end
            out[#out + 1] = {
                thickness = floor(Clamp(ring.thickness, R.THICK_MIN, R.THICK_MAX, 6) + 0.5),
                gap = floor(Clamp(ring.gap, R.GAP_MIN, R.GAP_MAX, 2) + 0.5),
                sections = secs,
            }
        end
    end
    return out
end

-- Does any ring have a section drawing `bar`? Reads the stored list as it is
-- (no cleaned copy): the frame view asks this on class power's every read.
function R.HasBar(db, bar)
    local src = db and db.rings
    if type(src) ~= "table" then src = R.DEFAULT_RINGS end
    for i, ring in ipairs(src) do
        if i > R.MAX_RINGS then break end
        local secs = type(ring) == "table" and ring.sections
        if type(secs) == "table" then
            for j, s in ipairs(secs) do
                if j > R.MAX_SECTIONS then break end
                if type(s) == "table" and s.bar == bar then return true end
            end
        end
    end
    return false
end

-- ============================================================
-- GEOMETRY (pure)
-- Outermost ring first: its outer edge is the frame's edge. Each ring's inner
-- edge is its outer edge less its thickness; the next ring in starts `gap` further
-- in. What is left inside ring 1 (after ring 1's gap) is the portrait's room.
-- Diameters, in the frame's units.
-- ============================================================
function R.Geometry(db)
    local size = R.Size(db)
    local list = R.List(db)
    local out = { size = size, rings = {} }
    local r = size / 2
    for i = #list, 1, -1 do
        local ring = list[i]
        local outer = r
        local inner = outer - ring.thickness
        if inner < 0 then inner = 0 end
        out.rings[i] = { index = i, outer = outer * 2, inner = inner * 2,
                         thickness = ring.thickness, gap = ring.gap, sections = ring.sections }
        r = inner - ring.gap
        if r < 0 then r = 0 end
    end
    out.hole = r * 2
    return out
end

-- A section's arc: start (a share of a turn clockwise from the bottom, 0..1) and
-- length. Full: the whole circle from the bottom.
function R.Arc(sec)
    local len = R.COVERAGE[sec and sec.coverage] or 1
    if len >= 1 then return 0, 1 end
    local mid = R.POSITIONS[sec and sec.position] or 0.5
    return (mid - len / 2) % 1, len
end

-- Start / end offsets of the arc a..a+len (see ARC MATHS above).
-- REVERSED (SetRadialProgressBarReverse(true), seen in game 2026-11-01): Start is
-- still a clockwise angle from the bottom, but the fill runs COUNTER-clockwise
-- from it. So the same arc filled the other way starts at its far end, a + len;
-- starting at `a` drew the mirror arc (a bottom half came out as the top half).
function R.Offsets(a, len, reverse)
    if reverse then return (a + len) % 1, 1 - len end
    return a % 1, 1 - len
end

-- n equal pips along the arc (a, len), each `gap` clear at both ends: a list of
-- { start, len }.
function R.PipArcs(a, len, n, gap)
    gap = gap or R.PIP_GAP
    local out = {}
    if not n or n < 1 then return out end
    local each = len / n
    if each - 2 * gap <= 0 then gap = 0 end
    for i = 1, n do
        out[i] = { start = (a + each * (i - 1) + gap) % 1, len = each - 2 * gap }
    end
    return out
end

-- Do two arcs (start, length) share any of the circle? Touching ends do not.
function R.ArcsOverlap(a1, l1, a2, l2)
    local EPS = 1e-6
    if l1 >= 1 - EPS or l2 >= 1 - EPS then return true end
    return ((a2 - a1) % 1) < l1 - EPS or ((a1 - a2) % 1) < l2 - EPS
end

-- Do any two sections of a ring (a stored one: cleaned here) cover the same part of
-- it? Worked out from the arcs the ring is drawn with (R.Arc).
function R.RingOverlaps(ring)
    local secs = type(ring) == "table" and ring.sections
    if type(secs) ~= "table" then return false end
    for i = 1, #secs do
        local a1, l1 = R.Arc(R.NormalizeSection(secs[i]))
        for j = i + 1, #secs do
            local a2, l2 = R.Arc(R.NormalizeSection(secs[j]))
            if R.ArcsOverlap(a1, l1, a2, l2) then return true end
        end
    end
    return false
end

-- Where the CLASSPOWER section is: ring geometry and the section (nil when no ring
-- has one).
function R.ClassPowerArc(db)
    if not R.IsRing(db) then return nil end
    local geo = R.Geometry(db)
    for _, ring in ipairs(geo.rings) do
        for _, s in ipairs(ring.sections) do
            if s.bar == "CLASSPOWER" then return ring, s, geo end
        end
    end
    return nil
end

-- ============================================================
-- A 3D PORTRAIT IN THE MIDDLE (ringPortrait3D; Portrait.lua RING 3D)
--   FIT    the model as the largest square inside the portrait's circle
--   COVER  the model filling the circle's square, its four corners covered in the
--          portrait background colour. Only with nothing see-through round the
--          portrait (the innermost ring's Gap is 0, so the ring hides the rest of
--          the corners): with a gap it is drawn as FIT.
--   2D     Blizzard's 2D portrait, cut round
-- ============================================================
R.PORTRAIT_3D = { FIT = true, COVER = true, ["2D"] = true }

-- Can COVER be drawn? Nothing see-through between the portrait and ring 1.
function R.CoverAllowed(db)
    local first = R.List(db)[1]
    return (first and first.gap == 0) and true or false
end

-- The mode in effect (COVER falls back to FIT with a gap).
function R.Portrait3D(db)
    local m = db and db.ringPortrait3D
    if not R.PORTRAIT_3D[m] then m = "FIT" end
    if m == "COVER" and not R.CoverAllowed(db) then m = "FIT" end
    return m
end

-- Frame levels in RING style, from the frame's own: the portrait (its model and
-- corner cover just above it) UNDER the rings, so a ring hides anything of the
-- portrait's square that reaches it; class power pips over the rings.
R.LEVEL_PORTRAIT, R.LEVEL_RINGS, R.LEVEL_CLASSPOWER = 2, 5, 6

-- ============================================================
-- THE TEXT DESIGNER'S MOCK (R.DecorateMock; DandersFrames_Options/UnitFrames/Pages.lua
-- UFO.AddTextPreviewFrame -> the designer's target.decorateMock)
-- A unit's Text Designer previews on the SAME static mock as the party / raid
-- designer, sized from the unit's frame view. A Ring-style unit's mock is dressed
-- with its rings drawn STATICALLY from this file's own geometry and arc maths:
-- fixed sample fills (MOCK_FILL), class power as MOCK_PIPS pips with MOCK_PIPS_ON
-- lit, and a plain round portrait placeholder (a masked flat texture, never a
-- model). No unit, no events, no OnUpdate: nothing on it can ever be secret. The
-- mock's own bar art and square backdrop are hidden while it is a ring and come
-- back for Bars. It also answers the ring spots (dfTDAnchorSpot) and, for Show
-- Hover State, dims the placeholder when the unit's portrait dims on hover.
-- ============================================================
R.MOCK_FILL = { HEALTH = 0.75, POWER = 0.6, SHIELD = 0.35, HEALABSORB = 0.2, INCOMING = 0.3 }
R.MOCK_COLOR = { HEALTH = { 0.18, 0.80, 0.44 }, POWER = { 0.27, 0.53, 1 }, CLASSPOWER = { 1, 0.82, 0 },
                 SHIELD = { 0, 0.84, 1 }, HEALABSORB = { 1, 0.25, 0.25 }, INCOMING = { 0, 0.8, 0.2 } }
R.MOCK_TRACK = { 0, 0, 0, 0.5 }
R.MOCK_PIPS, R.MOCK_PIPS_ON = 5, 3
R.MOCK_PORTRAIT = { 0.22, 0.22, 0.26, 1 }

local function MockArc(c, i)
    local a = c.arcs[i]
    if a then return a end
    a = { track = R.NewArcBar(c), fill = R.NewArcBar(c) }
    c.arcs[i] = a
    return a
end

-- One arc of the mock: a track and a fill at a FIXED value (0..1).
local function PaintMockArc(c, i, ring, start, len, sec, value, color, db)
    local a = MockArc(c, i)
    R.SetArcTexture(a.track, R.TrackTexture(db, sec))
    R.SetFillTexture(a.fill, db, sec, ring)
    R.ShapeArcBar(a.track, c, ring.outer, ring.inner, start, len, false, 0)
    R.ShapeArcBar(a.fill, c, ring.outer, ring.inner, start, len, sec.reverse, sec.feather)
    a.fill:SetFrameLevel(a.track:GetFrameLevel() + 1)
    a.track:SetMinMaxValues(0, 1)
    a.track:SetValue(1)
    a.track:SetStatusBarColor(R.MOCK_TRACK[1], R.MOCK_TRACK[2], R.MOCK_TRACK[3], R.MOCK_TRACK[4])
    R.LayoutFillLayers(a.fill, c, ring, start, len, sec.reverse, sec.feather, db, sec.bar)
    R.PutValues({ a.fill }, 0, 1, value)
    a.fill:SetStatusBarColor(color[1], color[2], color[3], 1)
    a.track:Show()
    a.fill:Show()
end

function R.DecorateMock(mock, db, chrome)
    if not mock then return end
    local ring = R.IsRing(db)
    for _, t in ipairs(chrome and chrome.textures or {}) do
        if ring then t:Hide() else t:Show() end
    end
    if mock.SetBackdropColor and chrome and chrome.backdrop then
        local bg, border = chrome.backdrop[1], chrome.backdrop[2]
        if ring then
            mock:SetBackdropColor(0, 0, 0, 0)
            if mock.SetBackdropBorderColor then mock:SetBackdropBorderColor(0, 0, 0, 0) end
        else
            mock:SetBackdropColor(bg.r, bg.g, bg.b, bg.a)
            if mock.SetBackdropBorderColor then mock:SetBackdropBorderColor(border.r, border.g, border.b, border.a) end
        end
    end
    local c = mock.dfUFMockRings
    if not ring then
        if c then c:Hide() end
        mock.dfUFRingGeom, mock.dfTDAnchorSpot, mock.dfHoverHook = nil, nil, nil
        return
    end
    if not c then
        c = CreateFrame("Frame", nil, mock)
        c.arcs = {}
        c.portrait = c:CreateTexture(nil, "BACKGROUND")
        c.portrait:SetTexture(K.WHITE)
        c.portraitMask = c:CreateMaskTexture()
        c.portraitMask:SetTexture(R.DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        c.portraitMask:SetAllPoints(c.portrait)
        c.portrait:AddMaskTexture(c.portraitMask)
        mock.dfUFMockRings = c
    end
    local geo = R.Geometry(db)
    c:ClearAllPoints()
    c:SetPoint("CENTER", mock, "CENTER", 0, 0)
    c:SetSize(geo.size, geo.size)
    -- Over the mock, under the designer's text overlay.
    c:SetFrameLevel(mock:GetFrameLevel() + 1)

    local used = 0
    for _, rg in ipairs(geo.rings) do
        for _, sec in ipairs(rg.sections) do
            local a, len = R.Arc(sec)
            if sec.bar == "CLASSPOWER" then
                local arcs = R.PipArcs(a, len, R.MOCK_PIPS)
                for i = 1, #arcs do
                    local arc = sec.reverse and arcs[#arcs - i + 1] or arcs[i]
                    used = used + 1
                    PaintMockArc(c, used, rg, arc.start, arc.len, sec, (i <= R.MOCK_PIPS_ON) and 1 or 0,
                        R.MOCK_COLOR.CLASSPOWER, db)
                end
            else
                used = used + 1
                PaintMockArc(c, used, rg, a, len, sec, R.MOCK_FILL[sec.bar] or 1,
                    R.MOCK_COLOR[sec.bar] or R.MOCK_COLOR.HEALTH, db)
            end
        end
    end
    for i = used + 1, #c.arcs do
        c.arcs[i].track:Hide()
        c.arcs[i].fill:Hide()
    end

    -- The portrait's room, as the frame lays it out (Portrait.lua PO.RingSize).
    local PO = UF.Portrait
    local size = PO and PO.RingSize and PO.RingSize(db) or geo.hole
    local pc = R.MOCK_PORTRAIT
    if db.portraitEnabled and size and size > 0 then
        c.portrait:ClearAllPoints()
        c.portrait:SetPoint("CENTER", c, "CENTER", 0, 0)
        c.portrait:SetSize(size, size)
        c.portrait:SetVertexColor(pc[1], pc[2], pc[3], pc[4])
        c.portrait:Show()
    else
        c.portrait:Hide()
    end
    c:Show()

    mock.dfUFRingGeom = geo
    mock.dfTDAnchorSpot = R.AnchorSpot
    -- Show Hover State: dim the placeholder as the frame's portrait would.
    mock.dfHoverHook = function(_, on)
        local dim = on and db.portraitDimHover and (PO and PO.DIM) or 1
        c.portrait:SetAlpha(dim)
    end
end

-- ============================================================
-- THE ROUND OUTLINE (DandersFrames' circle shape spec, Frames/Create.lua CIRCLE
-- BANDS): what the resting glow and the selection / hover / aggro highlights trace
-- on a Ring frame instead of its square -- a circle on the frame's centre, the
-- outer ring's diameter, cut with our hole mask.
-- ============================================================
function R.CircleShape(f, db)
    local geo = R.Geometry(db)
    local outer = geo.rings[#geo.rings]
    local d = outer and outer.outer or geo.size
    return { circle = { x = geo.size / 2, y = geo.size / 2, d = d }, hole = R.HOLE }
end

-- ============================================================
-- TEXT DESIGNER SPOTS (frame.dfTDAnchorSpot; DandersFrames' TextDesigner/Render.lua
-- SPOT ANCHORS). Where each ring anchor sits, as x, y from the frame's centre, from
-- the last ring layout (f.dfUFRingGeom). nil on a Bars frame: the renderer then
-- uses the frame's own edges (top, bottom, centre, left, right).
--   RING_ABOVE / RING_BELOW   the outer ring's top / bottom edge
--   RING_CENTER               the middle
--   RING_GAP_LEFT / _RIGHT    the middle of the outer ring's band on that side when
--                             no section of it covers that side (an open gap), else
--                             the ring's outer edge there
-- ============================================================
R.SIDE_ANGLE = { RING_GAP_LEFT = 0.25, RING_GAP_RIGHT = 0.75 }

-- Does any section of `ring` cover the point `angle` (a share of a turn clockwise
-- from the bottom)?
function R.Covers(ring, angle)
    for _, s in ipairs(ring.sections) do
        local a, len = R.Arc(s)
        if len >= 1 then return true end
        local d = (angle - a) % 1
        if d <= len then return true end
    end
    return false
end

function R.AnchorSpot(f, key)
    local geo = rawget(f, "dfUFRingGeom")
    local outer = geo and geo.rings[#geo.rings]
    if not outer then return nil end
    local r = outer.outer / 2
    if key == "RING_ABOVE" then return 0, r end
    if key == "RING_BELOW" then return 0, -r end
    if key == "RING_CENTER" then return 0, 0 end
    local angle = R.SIDE_ANGLE[key]
    if not angle then return nil end
    local sign = (key == "RING_GAP_LEFT") and -1 or 1
    if R.Covers(outer, angle) then return sign * r, 0 end
    return sign * (outer.outer + outer.inner) / 4, 0
end

-- ============================================================
-- THE FRAME VIEW's answers (Core.lua UF:FrameDB, Preview.lua P:PreviewDB).
-- handled, value for `key` on a RING-style unit; false for anything else.
-- ============================================================
R.FORCED = {
    resourceBarEnabled = false,
    healPredictionEnabled = false,
    reducedMaxHealthEnabled = false,
    -- On the hidden health bar (a child of it), so they never show.
    absorbBarMode = "OVERLAY",
    healAbsorbBarMode = "OVERLAY",
    absorbBarShowOvershield = false,
    -- The missing-health bar is never shown; the background is hidden (R:Layout).
    backgroundMode = "BACKGROUND",
    frameShowBorder = false,
    frameBorderShadowEnabled = false,
    portraitShape = "CIRCLE",
}

function R.FrameValue(db, key)
    if not R.IsRing(db) then return false end
    if key == "frameWidth" or key == "frameHeight" then return true, R.Size(db) end
    -- The style's own Text Designer template (Core.lua PER-UNIT DESIGNER TEMPLATES).
    if key == "textDesignerPreset" then return true, db[UF.RING_TEXT_KEY] end
    local v = R.FORCED[key]
    if v ~= nil then return true, v end
    if (key == "classPowerEnabled" or key == "classPowerDetached") and R.HasBar(db, "CLASSPOWER") then
        return true, key == "classPowerEnabled"
    end
    return false
end

-- ============================================================
-- ARC BARS (the kit ClassPower.lua shares)
-- ============================================================
local function Mask(owner, tex, path, wrap)
    local m = owner:CreateMaskTexture()
    m:SetTexture(path, wrap, wrap)
    tex:AddMaskTexture(m)
    return m
end

-- A radial StatusBar with its two ring masks. `level` above its parent.
function R.NewArcBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(K.WHITE)
    bar.dfArcTexture = K.WHITE
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local radial = Enum and Enum.StatusBarRenderMode and Enum.StatusBarRenderMode.Radial
    if radial ~= nil and bar.SetRenderMode then bar:SetRenderMode(radial) end
    local tex = bar:GetStatusBarTexture()
    bar.dfOuterMask = Mask(bar, tex, R.DISC, "CLAMPTOBLACKADDITIVE")
    bar.dfInnerMask = Mask(bar, tex, R.HOLE, "CLAMPTOWHITE")
    return bar
end

-- What a section draws with: its bar's own texture setting. A track takes the frame's
-- background texture on a health section; "Solid" and the others stay plain.
function R.FillTexture(db, sec)
    if sec.bar == "CLASSPOWER" then return db.classPowerTexture or K.BAR end
    local amount = R.AMOUNTS[sec.bar]
    local path
    if amount then
        path = db[amount.texture] or K.BAR
    elseif sec.bar == "POWER" then
        path = db.resourceBarTexture or K.BAR
    else
        path = db.healthTexture or K.BAR
    end
    -- The bar's Mirror tick picks the file's mirrored twin.
    local keys = R.LayerKeys(sec.bar)
    if keys and DF.ResolveBarTexture then path = DF:ResolveBarTexture(path, false, db[keys.mirror]) end
    return path
end

function R.TrackTexture(db, sec)
    local bg = db.backgroundTexture
    if sec.bar == "HEALTH" and bg and bg ~= "" and bg ~= "Solid" then return bg end
    return K.WHITE
end

-- Only when the path changes. Setting a file may hand back a new texture object, which
-- has none of the old one's masks; offsets and colours follow from the callers, which
-- call this before R.ShapeArcBar and paint afterwards.
function R.SetArcTexture(bar, path)
    if bar.dfArcTexture == path then return end
    bar.dfArcTexture = path
    bar.dfArcTileKey = nil
    local old = bar:GetStatusBarTexture()
    if DF.SafeSetStatusBarTexture then
        DF:SafeSetStatusBarTexture(bar, path)
    else
        bar:SetStatusBarTexture(path)
    end
    local tex = bar:GetStatusBarTexture()
    if tex ~= old then
        tex:AddMaskTexture(bar.dfOuterMask)
        tex:AddMaskTexture(bar.dfInnerMask)
    end
end

-- The tiling settings on an arc, as a bar's (Frames/TextureLayers.lua), measured on the
-- ring's square: a repeat of Tile Size pixels, Fit to Bar being the ring's thickness.
--   override   the Tile setting (nil / "AUTO": the texture's own)
--   sizeValue  the Tile Size setting. allowPreset: Auto uses the texture's preset size
--              (the base of health and power has no Tile Size control, so never there)
-- Call before R.ShapeArcBar: setting a file can reset the radial offsets.
function R.SetArcTile(bar, override, sizeValue, ring, allowPreset)
    if not (DF.ResolveTileMode and DF.ApplyBarTextureTiling) then return end
    if override == "AUTO" then override = nil end
    local path = bar.dfAppliedTexture or bar.dfArcTexture
    local v = tonumber(sizeValue)
    local asked = v == DF.TILE_SIZE_FIT or (v ~= nil and v > 0)
    local mode = DF:ResolveTileMode(path, override)
    if not mode and asked and override ~= "OFF" then mode = "BOTH" end
    local unit = 0
    if v == DF.TILE_SIZE_FIT then
        unit = ring.thickness
    elseif asked then
        unit = v
    elseif allowPreset and DF.GetBarTextureTileSize then
        unit = DF:GetBarTextureTileSize(path) or 0
    end
    local custom = mode ~= nil and unit > 0
    local key = tostring(override) .. ":" .. tostring(mode) .. ":" .. (custom and unit or 0) .. ":" .. ring.outer
    if bar.dfArcTileKey == key then return end
    bar.dfArcTileKey = key
    bar.dfTileOverride = override
    local tex = bar:GetStatusBarTexture()
    if custom then
        -- Wrap without the tile flags: the texcoords decide how many repeats.
        tex:SetTexture(path, "REPEAT", "REPEAT")
        tex:SetHorizTile(false)
        tex:SetVertTile(false)
        local repeats = ring.outer / unit
        tex:SetTexCoord(0, (mode == "BOTH" or mode == "HORIZ") and repeats or 1,
            0, (mode == "BOTH" or mode == "VERT") and repeats or 1)
    else
        tex.dfWrapPath = nil
        DF:ApplyBarTextureTiling(bar, path)
    end
end

-- A section's fill: its bar's texture and tiling.
function R.SetFillTexture(bar, db, sec, ring)
    R.SetArcTexture(bar, R.FillTexture(db, sec))
    local keys = R.LayerKeys(sec.bar)
    if keys then R.SetArcTile(bar, db[keys.tileMode], db[keys.tileSize], ring, R.AMOUNTS[sec.bar] ~= nil) end
end

-- Size `bar` to the ring (diameters) on `center`, and draw the arc start..start+len.
function R.ShapeArcBar(bar, center, outer, inner, start, len, reverse, feather)
    bar:ClearAllPoints()
    bar:SetPoint("CENTER", center, "CENTER", 0, 0)
    bar:SetSize(outer, outer)
    bar.dfOuterMask:ClearAllPoints()
    bar.dfOuterMask:SetPoint("CENTER", bar, "CENTER", 0, 0)
    bar.dfOuterMask:SetSize(outer, outer)
    bar.dfInnerMask:ClearAllPoints()
    bar.dfInnerMask:SetPoint("CENTER", bar, "CENTER", 0, 0)
    -- A ring as thick as its radius has no hole: a 0-size mask would cut nothing.
    local hole = inner > 0 and inner or 0.01
    bar.dfInnerMask:SetSize(hole, hole)
    local tex = bar:GetStatusBarTexture()
    local s, e = R.Offsets(start, len, reverse)
    if tex.SetRadialProgressBarStartOffset then tex:SetRadialProgressBarStartOffset(s) end
    if tex.SetRadialProgressBarEndOffset then tex:SetRadialProgressBarEndOffset(e) end
    if tex.SetRadialProgressBarReverse then tex:SetRadialProgressBarReverse(reverse and true or false) end
    if tex.SetRadialProgressBarFeather then tex:SetRadialProgressBarFeather(tonumber(feather) or 0) end
end

-- ============================================================
-- TEXTURE LAYERS (<bar>TextureLayersEnabled, <bar>Layer2* and 3*)
-- On a bar (Frames/TextureLayers.lua) a clip frame anchored to the fill cuts the
-- layers. A radial fill's rect never shrinks, so that can't cut anything here. Each
-- layer is a radial bar of its own instead: the fill's arc and value, the layer's
-- texture, tiling, colour and blend. A child of its fill, so it hides and range-fades
-- with it.
-- fill.dfLayers  the layers showing, bottom first (values: R.PutValues)
-- ============================================================
R.LAYER_PREFIX = { HEALTH = "health", POWER = "resourceBar", SHIELD = "absorbBar",
                   HEALABSORB = "healAbsorbBar", INCOMING = "healPrediction" }

-- A bar's texture settings keys (Frames/TextureLayers.lua); nil for class power.
function R.LayerKeys(barName)
    return DF.TEXTURE_LAYER_KEYS and DF.TEXTURE_LAYER_KEYS[R.LAYER_PREFIX[barName]]
end

local function PaintLayer(layer, db)
    layer:SetStatusBarColor(K.RGBA(db[layer.dfColorKey], 1, 1, 1, 1))
    local tex = layer:GetStatusBarTexture()
    if tex.SetBlendMode then tex:SetBlendMode(db[layer.dfBlendKey] or "BLEND") end
end

function R.LayoutFillLayers(fill, center, ring, start, len, reverse, feather, db, barName)
    local keys = R.LayerKeys(barName)
    local on = keys and db[keys.on]
    local pool, active = fill.dfLayerPool, {}
    for _, n in ipairs(DF.TEXTURE_LAYER_EXTRA or {}) do
        local kn = keys and keys[n]
        local layer = pool and pool[n]
        if on and db[kn.enabled] and db[kn.texture] then
            if not layer then
                pool = pool or {}
                fill.dfLayerPool = pool
                layer = R.NewArcBar(fill)
                pool[n] = layer
            end
            R.SetArcTexture(layer, DF:ResolveBarTexture(db[kn.texture], false, db[kn.mirror]))
            R.SetArcTile(layer, db[kn.tileMode], db[kn.tileSize], ring, true)
            R.ShapeArcBar(layer, center, ring.outer, ring.inner, start, len, reverse, feather)
            layer:SetFrameLevel(fill:GetFrameLevel() + n - 1)
            layer.dfColorKey, layer.dfBlendKey = kn.color, kn.blend
            PaintLayer(layer, db)
            layer:Show()
            active[#active + 1] = layer
        elseif layer then
            layer:Hide()
        end
    end
    fill.dfLayers = active
end

-- Value and range onto fills and their layers. Any of them can be secret: passed on unread.
function R.PutValues(list, lo, hi, v)
    if not list then return end
    for i = 1, #list do
        local bar = list[i]
        if not K.IsNil(hi) then bar:SetMinMaxValues(lo, hi) end
        if not K.IsNil(v) then bar:SetValue(v) end
        local layers = bar.dfLayers
        if layers then
            for j = 1, #layers do
                if not K.IsNil(hi) then layers[j]:SetMinMaxValues(lo, hi) end
                if not K.IsNil(v) then layers[j]:SetValue(v) end
            end
        end
    end
end

-- The layers' colours, without laying the rings out.
function R:PaintLayers(f)
    local c = f and f.dfUFRings
    if not (c and c.arcs) then return end
    local db = K.DB(f)
    local function Paint(fill)
        for _, layer in ipairs(fill.dfLayers or {}) do PaintLayer(layer, db) end
    end
    for _, arc in ipairs(c.arcs) do Paint(arc.fill) end
    for _, bar in ipairs(c.overlays or {}) do Paint(bar) end
end

-- ============================================================
-- THE ELEMENT
-- f.dfUFRings          the container (centred on the frame, ringSize square)
-- f.dfUFRingHealth     the health fills (written by R.HookHealth)
-- f.dfUFRingPower      the power fills
-- f.dfUFRingAmounts    { SHIELD = bars, HEALABSORB = bars, INCOMING = bars }
-- f.dfUFRingGeom       the last geometry (Text Designer's ring anchors read it)
-- ============================================================
function R:Attach(f)
    if not f or f.dfUFRings then return end
    local c = CreateFrame("Frame", nil, f)
    c:Hide()
    c.arcs = {}
    c.overlays = {}
    f.dfUFRings = c
    R.HookHealth(f)
    return c
end

local function Each(list, fn)
    if not list then return end
    for i = 1, #list do fn(list[i]) end
end

-- Fills and their layers: what a layer shares with its fill. Its colour is its own.
local function EachLayered(list, fn)
    if not list then return end
    for i = 1, #list do
        local bar = list[i]
        fn(bar)
        local layers = bar.dfLayers
        if layers then
            for j = 1, #layers do fn(layers[j]) end
        end
    end
end

local function SetValueOn(bar, v, interp)
    if interp ~= nil then bar:SetValue(v, interp) else bar:SetValue(v) end
end

-- Every write DandersFrames makes to the frame's health bar and its fill texture
-- is copied onto the health fills (values and colours pass through unread, so a
-- secret is safe). Hooked once per frame; a frame in BARS style has no fills and
-- the hooks return at once.
function R.HookHealth(f)
    local hb = f and f.healthBar
    if not hb or not hooksecurefunc or f.dfUFRingHooked then return end
    f.dfUFRingHooked = true
    hooksecurefunc(hb, "SetMinMaxValues", function(_, lo, hi)
        EachLayered(f.dfUFRingHealth, function(b) b:SetMinMaxValues(lo, hi) end)
    end)
    hooksecurefunc(hb, "SetValue", function(_, v, interp)
        EachLayered(f.dfUFRingHealth, function(b) SetValueOn(b, v, interp) end)
    end)
    hooksecurefunc(hb, "SetStatusBarColor", function(_, r, g, b, a)
        Each(f.dfUFRingHealth, function(bar)
            if K.IsNil(a) then bar:SetStatusBarColor(r, g, b) else bar:SetStatusBarColor(r, g, b, a) end
        end)
    end)
    R.HookHealthTexture(f)
end

-- The fill texture's colour and alpha (DandersFrames colours the texture, not the
-- bar). Re-run after a layout: a new texture object gets its own hooks.
function R.HookHealthTexture(f)
    local hb = f and f.healthBar
    local tex = hb and hb.GetStatusBarTexture and hb:GetStatusBarTexture()
    if not tex or not hooksecurefunc or f.dfUFRingHookedTex == tex then return end
    f.dfUFRingHookedTex = tex
    hooksecurefunc(tex, "SetVertexColor", function(self, r, g, b, a)
        if f.dfUFRingHookedTex ~= self then return end
        Each(f.dfUFRingHealth, function(bar)
            local t = bar:GetStatusBarTexture()
            if K.IsNil(a) then t:SetVertexColor(r, g, b) else t:SetVertexColor(r, g, b, a) end
        end)
    end)
    hooksecurefunc(tex, "SetAlpha", function(self, a)
        if f.dfUFRingHookedTex ~= self then return end
        EachLayered(f.dfUFRingHealth, function(bar) bar:GetStatusBarTexture():SetAlpha(a) end)
    end)
    if tex.SetAlphaFromBoolean then
        hooksecurefunc(tex, "SetAlphaFromBoolean", function(self, flag, ifTrue, ifFalse)
            if f.dfUFRingHookedTex ~= self then return end
            EachLayered(f.dfUFRingHealth, function(bar)
                local t = bar:GetStatusBarTexture()
                if t.SetAlphaFromBoolean then t:SetAlphaFromBoolean(flag, ifTrue, ifFalse) end
            end)
        end)
    end
end

-- New fills start from what the health bar shows now (after that, the hooks).
function R.SyncHealth(f)
    local list, hb = f.dfUFRingHealth, f.healthBar
    if not (list and #list > 0 and hb) then return end
    local lo, hi = hb:GetMinMaxValues()
    local v = hb:GetValue()
    local tex = hb:GetStatusBarTexture()
    local r, g, b
    if tex and tex.GetVertexColor then r, g, b = tex:GetVertexColor() end
    local a = tex and tex.GetAlpha and tex:GetAlpha()
    EachLayered(list, function(bar)
        if not K.IsNil(lo) and not K.IsNil(hi) then bar:SetMinMaxValues(lo, hi) end
        if not K.IsNil(v) then bar:SetValue(v) end
        if not K.IsNil(a) then bar:GetStatusBarTexture():SetAlpha(a) end
    end)
    for _, bar in ipairs(list) do
        if not K.IsNil(r) then bar:GetStatusBarTexture():SetVertexColor(r, g, b) end
    end
end

-- The health bar, its background and the missing-health bar go see-through in RING
-- style. Only on a change of style, so a BARS frame is never touched.
function R.HideBars(f, on)
    on = on and true or false
    if (f.dfUFRingBarsHidden or false) == on then return end
    f.dfUFRingBarsHidden = on
    if f.healthBar then f.healthBar:SetAlpha(on and 0 or 1) end
    if f.background then
        if on then f.background:Hide() else f.background:Show() end
    end
    if on and f.missingHealthBar then f.missingHealthBar:Hide() end
end

-- A track's colour: the section's own, else the bar's background colour.
function R.TrackColor(db, sec)
    if type(sec.trackColor) == "table" then return K.RGBA(sec.trackColor, 0, 0, 0, 0.6) end
    local amount = R.AMOUNTS[sec.bar]
    if amount then return K.RGBA(db[amount.background], 0, 0, 0, 0.5) end
    if sec.bar == "POWER" then return K.RGBA(db.resourceBarBackgroundColor, 0, 0, 0, 0.8) end
    if sec.bar == "CLASSPOWER" then return K.RGBA(db.classPowerEmptyColor, 0.15, 0.15, 0.15, 0.6) end
    return K.RGBA(db.backgroundColor, 0.1, 0.1, 0.1, 0.8)
end

-- A fill with no track, over a health section.
local function AcquireOverlay(c, i)
    local bar = c.overlays[i]
    if bar then return bar end
    bar = R.NewArcBar(c)
    c.overlays[i] = bar
    return bar
end

local function AcquireArc(c, i)
    local arc = c.arcs[i]
    if arc then return arc end
    arc = { track = R.NewArcBar(c) }
    arc.track:SetMinMaxValues(0, 1)
    arc.track:SetValue(1)
    arc.fill = R.NewArcBar(c)
    c.arcs[i] = arc
    return arc
end

function R:Layout(f)
    local c = f and f.dfUFRings
    if not c then return end
    local db = K.DB(f)
    local on = R.IsRing(db)
    R.HideBars(f, on)
    if not on then
        c:Hide()
        c.used = nil
        f.dfUFRingHealth, f.dfUFRingPower, f.dfUFRingGeom, f.dfUFRingAmounts = nil, nil, nil, nil
        return
    end
    R.HookHealthTexture(f)
    local geo = R.Geometry(db)
    f.dfUFRingGeom = geo
    c:ClearAllPoints()
    c:SetPoint("CENTER", f, "CENTER", 0, 0)
    c:SetSize(geo.size, geo.size)
    -- Over the (hidden) bars, under the text and the frame's icons.
    c:SetFrameLevel(f:GetFrameLevel() + R.LEVEL_RINGS)

    local used, overlays, health, power = 0, 0, {}, {}
    local amounts = { SHIELD = {}, HEALABSORB = {}, INCOMING = {} }
    for _, ring in ipairs(geo.rings) do
        for _, sec in ipairs(ring.sections) do
            -- Class power draws its own pips into the ring (ClassPower.lua).
            if sec.bar ~= "CLASSPOWER" then
                used = used + 1
                local arc = AcquireArc(c, used)
                local a, len = R.Arc(sec)
                R.SetArcTexture(arc.track, R.TrackTexture(db, sec))
                R.SetFillTexture(arc.fill, db, sec, ring)
                R.ShapeArcBar(arc.track, c, ring.outer, ring.inner, a, len, false, 0)
                R.ShapeArcBar(arc.fill, c, ring.outer, ring.inner, a, len, sec.reverse, sec.feather)
                arc.fill:SetFrameLevel(arc.track:GetFrameLevel() + 1)
                R.LayoutFillLayers(arc.fill, c, ring, a, len, sec.reverse, sec.feather, db, sec.bar)
                arc.sec = sec
                arc.track:Show()
                arc.fill:Show()
                local list = amounts[sec.bar]
                if list then
                    list[#list + 1] = arc.fill
                elseif sec.bar == "POWER" then
                    power[#power + 1] = arc.fill
                else
                    health[#health + 1] = arc.fill
                    for n, on in ipairs(R.ON_HEALTH) do
                        if db[on.key] ~= false then
                            overlays = overlays + 1
                            local bar = AcquireOverlay(c, overlays)
                            R.SetFillTexture(bar, db, on, ring)
                            local reverse = sec.reverse and true or false
                            if on.farEnd then reverse = not reverse end
                            R.ShapeArcBar(bar, c, ring.outer, ring.inner, a, len, reverse, 0)
                            -- Room above each fill for its two layers.
                            bar:SetFrameLevel(arc.fill:GetFrameLevel() + n * 3)
                            R.LayoutFillLayers(bar, c, ring, a, len, reverse, 0, db, on.bar)
                            bar:Show()
                            local onList = amounts[on.bar]
                            onList[#onList + 1] = bar
                        end
                    end
                end
            end
        end
    end
    for i = used + 1, #c.arcs do
        c.arcs[i].track:Hide()
        c.arcs[i].fill:Hide()
    end
    for i = overlays + 1, #c.overlays do c.overlays[i]:Hide() end
    f.dfUFRingHealth, f.dfUFRingPower, f.dfUFRingAmounts = health, power, amounts
    c.used = used
    R:PaintTracks(f)
    R:PaintAmounts(f)
    c:Show()
    R.SyncHealth(f)
    if not f.dfUFPreview then
        R:FeedPower(f)
        R:FeedAmounts(f)
    end
    R:ApplyRange(f)
end

-- The tracks' colours, without laying the rings out.
function R:PaintTracks(f)
    local c = f and f.dfUFRings
    if not (c and c.arcs and c.used and f.dfUFRingPower) then return end
    local db = K.DB(f)
    for i = 1, c.used do
        local arc = c.arcs[i]
        arc.track:SetStatusBarColor(R.TrackColor(db, arc.sec))
    end
end

-- Range fade: tracks with Background Alpha, power fills with Power Bar Alpha, amounts
-- with Absorb Bar Alpha. A health fill's alpha is the health bar's, copied onto its
-- texture, so its frame stays at 1.
function R:ApplyRange(f)
    local c = f and f.dfUFRings
    if not (c and c.arcs and f.dfUFRingPower) then return end
    local db = K.DB(f)
    local trackA = tonumber(db and db.oorBackgroundAlpha) or 0.1
    local powerA = tonumber(db and db.oorPowerBarAlpha) or 0.2
    local amountA = tonumber(db and db.oorAbsorbBarAlpha) or 0.2
    local isPower = {}
    for _, bar in ipairs(f.dfUFRingPower) do isPower[bar] = true end
    for _, arc in ipairs(c.arcs) do
        K.RangeAlpha(f, arc.track, 1, trackA)
        if isPower[arc.fill] then
            K.RangeAlpha(f, arc.fill, 1, powerA)
        elseif arc.sec and R.AMOUNTS[arc.sec.bar] then
            K.RangeAlpha(f, arc.fill, 1, amountA)
        else
            arc.fill:SetAlpha(1)
        end
    end
    for _, bar in ipairs(c.overlays) do K.RangeAlpha(f, bar, 1, amountA) end
end

-- An amount's colour: its bar's setting. Incoming follows Heal Prediction's Show mode.
function R.AmountColor(db, bar)
    if bar == "SHIELD" then return K.RGBA(db.absorbBarColor, 0, 0.84, 1, 0.8) end
    if bar == "HEALABSORB" then return K.RGBA(db.healAbsorbBarColor, 1, 0.25, 0.25, 0.8) end
    local mode = db.healPredictionShowMode
    if mode == "MINE" then return K.RGBA(db.healPredictionMyColor, 0, 0.8, 0.2, 0.7) end
    if mode == "OTHERS" then return K.RGBA(db.healPredictionOthersColor, 0, 0.5, 0.8, 0.7) end
    return K.RGBA(db.healPredictionAllColor, 0, 0.7, 0.4, 0.7)
end

function R:PaintAmounts(f)
    local amounts = f and f.dfUFRingAmounts
    if not amounts then return end
    local db = K.DB(f)
    for bar, list in pairs(amounts) do
        local r, g, b, a = R.AmountColor(db, bar)
        local blend = db[R.AMOUNTS[bar].blend] or "BLEND"
        for _, fill in ipairs(list) do
            fill:SetStatusBarColor(r, g, b, a)
            local tex = fill:GetStatusBarTexture()
            if tex.SetBlendMode then tex:SetBlendMode(blend) end
        end
    end
end

-- One calculator per amount, set the way DandersFrames' bars set theirs
-- (Frames/Bars.lua). A shield is measured against max health, so it shows at full
-- health too.
local calculators
local function Calculators()
    if calculators or not CreateUnitHealPredictionCalculator then return calculators end
    local shield = CreateUnitHealPredictionCalculator()
    shield:SetDamageAbsorbClampMode(2)
    shield:SetHealAbsorbMode(0)
    local healAbsorb = CreateUnitHealPredictionCalculator()
    healAbsorb:SetHealAbsorbClampMode(0)
    healAbsorb:SetHealAbsorbMode(1)
    local incoming = CreateUnitHealPredictionCalculator()
    incoming:SetIncomingHealClampMode(0)
    incoming:SetIncomingHealOverflowPercent(1.0)
    incoming:SetHealAbsorbMode(0)
    calculators = { SHIELD = shield, HEALABSORB = healAbsorb, INCOMING = incoming }
    return calculators
end

-- The value and its max, from one snapshot. Both can be secret: passed on unread.
local function ReadAmount(unit, bar, db)
    local calc = Calculators()[bar]
    if bar ~= "INCOMING" then
        UnitGetDetailedHealPrediction(unit, nil, calc)
        local v
        if bar == "SHIELD" then v = calc:GetDamageAbsorbs() else v = calc:GetHealAbsorbs() end
        return v, calc:GetMaximumHealth()
    end
    UnitGetDetailedHealPrediction(unit, "player", calc)
    local all, mine, others = calc:GetIncomingHeals()
    local mode = db.healPredictionShowMode
    local v = all
    if mode == "MINE" then v = mine elseif mode == "OTHERS" then v = others end
    return v, calc:GetMaximumHealth()
end

function R:FeedAmounts(f)
    local amounts = f and f.dfUFRingAmounts
    if not amounts or f.dfUFPreview or not Calculators() then return end
    local unit = f.unit
    if not (unit and UnitExists and UnitExists(unit)) then return end
    local db = K.DB(f)
    for bar, list in pairs(amounts) do
        if #list > 0 then
            local v, mx = ReadAmount(unit, bar, db)
            R.PutValues(list, 0, mx, v)
        end
    end
end

-- The power fills: the unit's power, in the resource bar's colour.
function R:FeedPower(f)
    local list = f and f.dfUFRingPower
    if not (list and #list > 0) or f.dfUFPreview then return end
    local unit = f.unit
    if not (unit and UnitExists and UnitExists(unit)) then return end
    local db = K.DB(f)
    local cur, mx = UnitPower(unit), UnitPowerMax(unit)
    local r, g, b = 0, 0.5, 1
    if DF.GetResourceBarColor then r, g, b = DF:GetResourceBarColor(unit, db) end
    R.PutValues(list, 0, mx, cur)
    for _, bar in ipairs(list) do bar:SetStatusBarColor(r, g, b, 1) end
end

R.POWER_EVENTS = { UNIT_POWER_UPDATE = true, UNIT_MAXPOWER = true, UNIT_DISPLAYPOWER = true }

-- Health too: an incoming heal is clamped to the missing health, and a shield and a
-- heal absorb are measured against the max.
R.AMOUNT_EVENTS = { UNIT_ABSORB_AMOUNT_CHANGED = true, UNIT_HEAL_ABSORB_AMOUNT_CHANGED = true,
                    UNIT_HEAL_PREDICTION = true, UNIT_HEALTH = true, UNIT_MAXHEALTH = true }

function R:OnUnitEvent(f, event)
    if R.POWER_EVENTS[event] then R:FeedPower(f) end
    if R.AMOUNT_EVENTS[event] then R:FeedAmounts(f) end
end

function R:Refresh(f)
    if f and f.dfUFRingPower then
        R:FeedPower(f)
        R:FeedAmounts(f)
    end
end

function R:OnUnitChanged(f) R:Refresh(f) end

-- A preview: the sample's power and amount shares. Health comes through the hooks,
-- from the test painter's write to the health bar.
function R:Preview(f)
    if not (f and f.dfUFRings) then return end
    R:Layout(f)
    local list = f.dfUFRingPower
    if not list then return end
    local t = f.dfTestData
    local pct = type(t) == "table" and tonumber(t.powerPercent) or 0.8
    local db = K.DB(f)
    local r, g, b = 0, 0.5, 1
    if DF.GetResourceBarColor then
        if f.dfUFUnit == "player" then
            r, g, b = DF:GetResourceBarColor("player", db)
        else
            r, g, b = DF:GetResourceBarColor(nil, db, type(t) == "table" and t.class or nil, "MANA")
        end
    end
    R.PutValues(list, 0, 1, pct)
    for _, bar in ipairs(list) do bar:SetStatusBarColor(r, g, b, 1) end
    for name, bars in pairs(f.dfUFRingAmounts or {}) do
        local amount = R.AMOUNTS[name]
        local share = (type(t) == "table" and db[amount.testShow] ~= false) and tonumber(t[amount.testValue]) or 0
        R.PutValues(bars, 0, 1, share)
    end
    R.SyncHealth(f)
end

E:Register(R)
