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
--   section     { bar = "HEALTH"|"POWER"|"CLASSPOWER",
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
-- v1: the cast bar is never a ring; absorbs, heal absorbs and heal prediction are
-- not drawn in RING style; highlights keep the frame's square outline.
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
R.BARS = { HEALTH = true, POWER = true, CLASSPOWER = true }
R.BAR_ORDER = { "HEALTH", "POWER", "CLASSPOWER" }
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
R.MAX_RINGS, R.MAX_SECTIONS = 4, 4
-- Two or more sections on one ring are pulled apart by this much each side.
R.SECTION_GAP = 0.008
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
-- length. Full: the whole circle from the bottom. `multi`: the ring has more than
-- one section, so each is pulled in a little at both ends.
function R.Arc(sec, multi)
    local len = R.COVERAGE[sec and sec.coverage] or 1
    if len >= 1 then return 0, 1 end
    local mid = R.POSITIONS[sec and sec.position] or 0.5
    local a = (mid - len / 2) % 1
    if multi then
        a = (a + R.SECTION_GAP) % 1
        len = len - 2 * R.SECTION_GAP
    end
    return a, len
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

-- Where the CLASSPOWER section is: ring geometry, the section, and whether the
-- ring has others (nil when no ring has one).
function R.ClassPowerArc(db)
    if not R.IsRing(db) then return nil end
    local geo = R.Geometry(db)
    for _, ring in ipairs(geo.rings) do
        for _, s in ipairs(ring.sections) do
            if s.bar == "CLASSPOWER" then return ring, s, #ring.sections > 1, geo end
        end
    end
    return nil
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
    local multi = #ring.sections > 1
    for _, s in ipairs(ring.sections) do
        local a, len = R.Arc(s, multi)
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
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local radial = Enum and Enum.StatusBarRenderMode and Enum.StatusBarRenderMode.Radial
    if radial ~= nil and bar.SetRenderMode then bar:SetRenderMode(radial) end
    local tex = bar:GetStatusBarTexture()
    bar.dfOuterMask = Mask(bar, tex, R.DISC, "CLAMPTOBLACKADDITIVE")
    bar.dfInnerMask = Mask(bar, tex, R.HOLE, "CLAMPTOWHITE")
    return bar
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
-- THE ELEMENT
-- f.dfUFRings          the container (centred on the frame, ringSize square)
-- f.dfUFRingHealth     the health fills (written by R.HookHealth)
-- f.dfUFRingPower      the power fills
-- f.dfUFRingGeom       the last geometry (Text Designer's ring anchors read it)
-- ============================================================
function R:Attach(f)
    if not f or f.dfUFRings then return end
    local c = CreateFrame("Frame", nil, f)
    c:Hide()
    c.arcs = {}
    f.dfUFRings = c
    R.HookHealth(f)
    return c
end

local function Each(list, fn)
    if not list then return end
    for i = 1, #list do fn(list[i]) end
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
        Each(f.dfUFRingHealth, function(b) b:SetMinMaxValues(lo, hi) end)
    end)
    hooksecurefunc(hb, "SetValue", function(_, v, interp)
        Each(f.dfUFRingHealth, function(b) SetValueOn(b, v, interp) end)
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
        Each(f.dfUFRingHealth, function(bar) bar:GetStatusBarTexture():SetAlpha(a) end)
    end)
    if tex.SetAlphaFromBoolean then
        hooksecurefunc(tex, "SetAlphaFromBoolean", function(self, flag, ifTrue, ifFalse)
            if f.dfUFRingHookedTex ~= self then return end
            Each(f.dfUFRingHealth, function(bar)
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
    for _, bar in ipairs(list) do
        if not K.IsNil(lo) and not K.IsNil(hi) then bar:SetMinMaxValues(lo, hi) end
        if not K.IsNil(v) then bar:SetValue(v) end
        local t = bar:GetStatusBarTexture()
        if not K.IsNil(r) then t:SetVertexColor(r, g, b) end
        if not K.IsNil(a) then t:SetAlpha(a) end
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
    if sec.bar == "POWER" then return K.RGBA(db.resourceBarBackgroundColor, 0, 0, 0, 0.8) end
    if sec.bar == "CLASSPOWER" then return K.RGBA(db.classPowerEmptyColor, 0.15, 0.15, 0.15, 0.6) end
    return K.RGBA(db.backgroundColor, 0.1, 0.1, 0.1, 0.8)
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
        f.dfUFRingHealth, f.dfUFRingPower, f.dfUFRingGeom = nil, nil, nil
        return
    end
    R.HookHealthTexture(f)
    local geo = R.Geometry(db)
    f.dfUFRingGeom = geo
    c:ClearAllPoints()
    c:SetPoint("CENTER", f, "CENTER", 0, 0)
    c:SetSize(geo.size, geo.size)
    -- Over the (hidden) bars, under the text and the frame's icons.
    c:SetFrameLevel(f:GetFrameLevel() + 2)

    local used, health, power = 0, {}, {}
    for _, ring in ipairs(geo.rings) do
        local multi = #ring.sections > 1
        for _, sec in ipairs(ring.sections) do
            -- Class power draws its own pips into the ring (ClassPower.lua).
            if sec.bar ~= "CLASSPOWER" then
                used = used + 1
                local arc = AcquireArc(c, used)
                local a, len = R.Arc(sec, multi)
                R.ShapeArcBar(arc.track, c, ring.outer, ring.inner, a, len, false, 0)
                R.ShapeArcBar(arc.fill, c, ring.outer, ring.inner, a, len, sec.reverse, sec.feather)
                arc.fill:SetFrameLevel(arc.track:GetFrameLevel() + 1)
                arc.track:SetStatusBarColor(R.TrackColor(db, sec))
                arc.track:Show()
                arc.fill:Show()
                if sec.bar == "POWER" then power[#power + 1] = arc.fill else health[#health + 1] = arc.fill end
            end
        end
    end
    for i = used + 1, #c.arcs do
        c.arcs[i].track:Hide()
        c.arcs[i].fill:Hide()
    end
    f.dfUFRingHealth, f.dfUFRingPower = health, power
    c:Show()
    R.SyncHealth(f)
    if not f.dfUFPreview then R:FeedPower(f) end
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
    for _, bar in ipairs(list) do
        bar:SetMinMaxValues(0, mx)
        bar:SetValue(cur)
        bar:SetStatusBarColor(r, g, b, 1)
    end
end

R.POWER_EVENTS = { UNIT_POWER_UPDATE = true, UNIT_MAXPOWER = true, UNIT_DISPLAYPOWER = true }

function R:OnUnitEvent(f, event)
    if R.POWER_EVENTS[event] then R:FeedPower(f) end
end

function R:Refresh(f)
    if f and f.dfUFRingPower then R:FeedPower(f) end
end

function R:OnUnitChanged(f) R:Refresh(f) end

-- A preview: the sample's power share. Health comes through the hooks, from the
-- test painter's write to the health bar.
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
    for _, bar in ipairs(list) do
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(pct)
        bar:SetStatusBarColor(r, g, b, 1)
    end
    R.SyncHealth(f)
end

E:Register(R)
