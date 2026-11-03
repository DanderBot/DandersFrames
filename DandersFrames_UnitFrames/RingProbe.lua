local addonName, UF = ...

--@do-not-package@
-- ============================================================
-- ROUND BAR PROBE (dev only, never packaged)
-- /dfring [unit]  toggles a test panel of 12.1 radial status bars driven by the
-- unit's real health (default player). It answers, in game:
--   * does the client have the radial API at all;
--   * does a radial bar take SECRET health in combat without erroring;
--   * what start/end offsets, feather and reverse actually look like;
--   * does a mask cut a linear bar into a shape.
-- Results are written on the panel itself (no chat output). Every API call is
-- pcall'd and counted, so an error shows as a number, not a Lua error popup.
-- ============================================================

local pcall, tostring, format = pcall, tostring, string.format

local WHITE = "Interface\\Buttons\\WHITE8X8"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local ROUNDED = "Interface\\Common\\common-iconmask"

local P = { bars = {}, powerBars = {}, pips = {}, texts = {}, errors = 0, updates = 0, lastError = nil }

-- Class power by class (spec-only classes fall back to combo points, which just
-- reads 0 for them). Pip count is read once at build; a secret max falls back to 5.
local CLASS_POWER = {
    ROGUE = "ComboPoints", DRUID = "ComboPoints", PALADIN = "HolyPower", WARLOCK = "SoulShards",
    EVOKER = "Essence", MONK = "Chi", MAGE = "ArcaneCharges",
}

local function try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        P.errors = P.errors + 1
        P.lastError = label .. ": " .. tostring(err)
    end
    return ok
end

local function radialSupported()
    return Enum and Enum.StatusBarRenderMode and Enum.StatusBarRenderMode.Radial ~= nil
end

-- One radial bar: a white square fill clipped to a disc, with a darker disc on
-- top when `ring` is set so only the outer band shows.
local function RadialBar(parent, size, label, setup, ring, list, color, noBg)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size, size + 14)

    local bar = CreateFrame("StatusBar", nil, holder)
    bar:SetSize(size, size)
    bar:SetPoint("TOP")
    if not noBg then
        local bg = holder:CreateTexture(nil, "BACKGROUND")
        bg:SetTexture(WHITE)
        bg:SetVertexColor(0.15, 0.15, 0.15, 1)
        bg:SetAllPoints(bar)
        local bgMask = holder:CreateMaskTexture()
        bgMask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        bgMask:SetAllPoints(bg)
        bg:AddMaskTexture(bgMask)
    end
    bar:SetStatusBarTexture(WHITE)
    if color then bar:SetStatusBarColor(color[1], color[2], color[3], 1) else bar:SetStatusBarColor(0.2, 0.85, 0.3, 1) end
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    local tex = bar:GetStatusBarTexture()
    local mask = bar:CreateMaskTexture()
    mask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(bar)
    try("AddMaskTexture", tex.AddMaskTexture, tex, mask)
    try("SetRenderMode", bar.SetRenderMode, bar, Enum.StatusBarRenderMode.Radial)
    if setup then setup(tex) end

    if ring then
        local hole = bar:CreateTexture(nil, "OVERLAY")
        hole:SetTexture(WHITE)
        hole:SetVertexColor(0.05, 0.05, 0.05, 1)
        hole:SetPoint("CENTER")
        hole:SetSize(size * 0.72, size * 0.72)
        local holeMask = bar:CreateMaskTexture()
        holeMask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        holeMask:SetAllPoints(hole)
        hole:AddMaskTexture(holeMask)
    end

    local text = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("BOTTOM")
    text:SetText(label)

    local into = list or P.bars
    into[#into + 1] = bar
    return holder
end

-- ARC MATHS (seen in game, 2026-11-01; the API notes say otherwise): StartOffset
-- is where the fill begins (0 = bottom, clockwise), EndOffset is how much of the
-- circle is CUT OFF the end -- the arc's length is 1 - EndOffset, not End - Start.
-- So the arc a..b is Start = a, End = 1 - (b - a).

-- Class power as a ring of pips: one radial bar per pip, each covering its own
-- slice of the circle (or of `span`, an arc) and ranged i-1..i, all fed the SAME
-- secret value -- the bar clamps, so a pip is full, empty or part-filled without
-- Lua ever comparing the number. Slices are separate textures stacked on one disc.
local function PipRing(parent, size, label, count, span)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size, size + 14)
    local from, to = span and span[1] or 0, span and span[2] or 1
    local gap = 0.012
    for i = 1, count do
        local a = from + (to - from) * (i - 1) / count
        local b = from + (to - from) * i / count
        local pip = RadialBar(holder, size, "", function(tex)
            try("pip start", tex.SetRadialProgressBarStartOffset, tex, a + gap)
            try("pip end", tex.SetRadialProgressBarEndOffset, tex, 1 - ((b - gap) - (a + gap)))
        end, i == count, P.pips, { 0.95, 0.75, 0.2 }, i > 1)
        pip:SetPoint("TOP")
        P.pips[#P.pips].pipIndex = i
    end
    local text = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("BOTTOM")
    text:SetText(label)
    return holder
end

-- Text around a ring. No curved text exists in the API; the only tool is turning
-- a whole FontString (SetRotation, radians). Each label is placed at a clock angle
-- just outside the ring and fed hidden values the same way health text is, so this
-- shows whether rotated secret text renders and which spots read well.
-- angle: 0 = 12 o'clock, clockwise in degrees. rot: the text's own turn in degrees.
local function TextRing(parent, size)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size + 120, size + 60)
    local ring = RadialBar(holder, size, "", nil, true)
    ring:ClearAllPoints()
    ring:SetPoint("CENTER", holder, "CENTER", 0, -7)
    local r = size / 2 + 12
    local function label(kind, angle, rot, inside)
        local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        local rad = math.rad(angle)
        if inside then
            fs:SetPoint("CENTER", ring, "CENTER", 0, 7)
        else
            fs:SetPoint("CENTER", ring, "CENTER", r * math.sin(rad), 7 + r * math.cos(rad))
        end
        if rot ~= 0 then try("FontString:SetRotation", fs.SetRotation, fs, math.rad(rot)) end
        fs.kind = kind
        P.texts[#P.texts + 1] = fs
    end
    label("pct", 0, 0, true)          -- centre, straight
    label("name", 0, 0)               -- top, straight
    label("power", 270, 90)           -- left side, reads bottom to top
    label("health", 90, -90)          -- right side, reads top to bottom
    label("pct", 45, -45)             -- top-right, tilted along the ring
    return holder
end

-- ============================================================
-- TRANSPARENT RING (2026-11-01): the technique the real ring frames use. Each
-- texture of a ring (track and fill) takes TWO masks: Blizzard's disc at the
-- ring's OUTER diameter (CLAMPTOBLACKADDITIVE: nothing outside it), and our
-- inverted disc (Media/RingInnerMask.tga: white outside, black inside) at the
-- INNER diameter with CLAMPTOWHITE, so everything outside that square stays and
-- only the hole is cut. No dark disc on top: the world shows through the middle
-- and through the gap between two rings. Drawn OUTSIDE the panel (no backdrop
-- behind it) so that is visible. Check: no dark centre, no dark gap, round edges,
-- and nothing missing at the 3 / 6 / 9 / 12 o'clock points of the inner edge
-- (where the hole touches its mask's square: CLAMPTOWHITE must not bleed in).
-- ============================================================
local HOLE = "Interface\\AddOns\\DandersFrames_UnitFrames\\Media\\RingInnerMask"

local function MaskRing(tex, owner, outer, inner)
    local o = owner:CreateMaskTexture()
    o:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    o:SetPoint("CENTER", owner, "CENTER")
    o:SetSize(outer, outer)
    try("ring outer mask", tex.AddMaskTexture, tex, o)
    local i = owner:CreateMaskTexture()
    i:SetTexture(HOLE, "CLAMPTOWHITE", "CLAMPTOWHITE")
    i:SetPoint("CENTER", owner, "CENTER")
    i:SetSize(inner, inner)
    try("ring inner mask", tex.AddMaskTexture, tex, i)
end

-- One see-through ring: a track (dark, half alpha) and a radial fill, both masked.
-- arc (optional): { start, len, reverse, noTrack, level }. A reversed fill starts at
-- the arc's far end and runs back (Rings.lua R.Offsets). level lifts the fill over a
-- bar already on the same band. texture (optional) replaces the fill's plain white.
local function SeeThroughRing(parent, outer, thickness, list, color, arc, texture)
    local inner = outer - 2 * thickness
    local baseLevel = parent:GetFrameLevel() + 1
    if not (arc and arc.noTrack) then
        local track = CreateFrame("StatusBar", nil, parent)
        track:SetSize(outer, outer)
        track:SetPoint("CENTER")
        track:SetFrameLevel(baseLevel)
        track:SetStatusBarTexture(WHITE)
        track:SetStatusBarColor(0, 0, 0, 0.5)
        track:SetMinMaxValues(0, 1)
        track:SetValue(1)
        try("track SetRenderMode", track.SetRenderMode, track, Enum.StatusBarRenderMode.Radial)
        MaskRing(track:GetStatusBarTexture(), track, outer, inner)
        if arc then
            local tex = track:GetStatusBarTexture()
            try("track start", tex.SetRadialProgressBarStartOffset, tex, arc.start)
            try("track end", tex.SetRadialProgressBarEndOffset, tex, 1 - arc.len)
        end
    end

    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(outer, outer)
    bar:SetPoint("CENTER")
    bar:SetFrameLevel(baseLevel + 1 + (arc and arc.level or 0))
    bar:SetStatusBarTexture(texture or WHITE)
    bar:SetStatusBarColor(color[1], color[2], color[3], 1)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    try("ring SetRenderMode", bar.SetRenderMode, bar, Enum.StatusBarRenderMode.Radial)
    MaskRing(bar:GetStatusBarTexture(), bar, outer, inner)
    if arc then
        local tex = bar:GetStatusBarTexture()
        local s = arc.reverse and ((arc.start + arc.len) % 1) or arc.start
        try("arc start", tex.SetRadialProgressBarStartOffset, tex, s)
        try("arc end", tex.SetRadialProgressBarEndOffset, tex, 1 - arc.len)
        if arc.reverse then try("arc reverse", tex.SetRadialProgressBarReverse, tex, true) end
    end
    list[#list + 1] = bar
end

-- ============================================================
-- SHIELDS, HEAL ABSORBS AND INCOMING HEALS ON A RING (2026-11-03)
-- A radial fill has no moving edge to anchor to, so these can't sit at the tip of the
-- health fill as they do on a bar. Each is its own radial bar instead, fed straight
-- from the same calculator the bars read (Frames/Bars.lua UpdateAbsorb, UpdateHealAbsorb,
-- UpdateHealPrediction): no Lua maths, so a secret value goes through as it is.
-- Checks: the fills move in combat, errors stay at 0, and the numbers under the rings
-- agree with what the rings show. A shield is measured against max health
-- (clamp mode 2), so it shows in full on a frame at full health.
-- ============================================================
local COLOR_HEALTH = { 0.2, 0.85, 0.3 }
local COLOR_SHIELD = { 0.85, 0.9, 1 }
local COLOR_HEAL_ABSORB = { 0.75, 0.1, 0.15 }
local COLOR_INCOMING = { 0.55, 1, 0.65 }

local function AbsorbTest(parent, size, label, build)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size, size + 14)
    local box = CreateFrame("Frame", nil, holder)
    box:SetSize(size, size)
    box:SetPoint("TOP")
    build(box, size)
    local text = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("BOTTOM")
    text:SetText(label)
    return holder
end

local function BuildAbsorbRow(f)
    P.shieldBars, P.healAbsorbBars, P.incomingBars = {}, {}, {}
    local size = 86
    local tests = {
        { "Shield ring", function(b, s)
            SeeThroughRing(b, s, 5, P.shieldBars, COLOR_SHIELD)
            SeeThroughRing(b, s - 10, 11, P.bars, COLOR_HEALTH)
        end },
        { "Shield far end", function(b, s)
            SeeThroughRing(b, s, 14, P.bars, COLOR_HEALTH, { start = 0, len = 0.5 })
            SeeThroughRing(b, s, 14, P.shieldBars, COLOR_SHIELD, { start = 0, len = 0.5, reverse = true, noTrack = true, level = 1 })
        end },
        { "Heal absorb ring", function(b, s)
            SeeThroughRing(b, s, 5, P.healAbsorbBars, COLOR_HEAL_ABSORB)
            SeeThroughRing(b, s - 10, 11, P.bars, COLOR_HEALTH)
        end },
        { "Heal absorb over", function(b, s)
            SeeThroughRing(b, s, 14, P.bars, COLOR_HEALTH)
            SeeThroughRing(b, s, 14, P.healAbsorbBars, COLOR_HEAL_ABSORB, { start = 0, len = 1, noTrack = true, level = 1 })
        end },
        { "Incoming ring", function(b, s)
            SeeThroughRing(b, s, 5, P.incomingBars, COLOR_INCOMING)
            SeeThroughRing(b, s - 10, 11, P.bars, COLOR_HEALTH)
        end },
        { "All three", function(b, s)
            SeeThroughRing(b, s, 4, P.shieldBars, COLOR_SHIELD)
            SeeThroughRing(b, s - 8, 4, P.healAbsorbBars, COLOR_HEAL_ABSORB)
            SeeThroughRing(b, s - 16, 4, P.incomingBars, COLOR_INCOMING)
            SeeThroughRing(b, s - 24, 8, P.bars, COLOR_HEALTH)
        end },
    }
    local x = 8
    for _, t in ipairs(tests) do
        local holder = AbsorbTest(f, size, t[1], t[2])
        holder:SetPoint("TOPLEFT", x, -460)
        x = x + size + 6
    end
    local function value(name, xPos)
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", xPos, -566)
        label:SetText(name)
        local v = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        v:SetPoint("LEFT", label, "RIGHT", 6, 0)
        return v
    end
    P.shieldText = value("Shield:", 12)
    P.healAbsorbText = value("Heal absorb:", 170)
    P.incomingText = value("Incoming:", 360)
end

-- The three values, each from its own calculator with the settings the bars use:
-- shield, heal absorb, incoming heal, max health. All can be secret.
local function ReadAbsorbs(unit)
    if not CreateUnitHealPredictionCalculator then return end
    if not P.calcs then
        P.calcs = { shield = CreateUnitHealPredictionCalculator(),
                    healAbsorb = CreateUnitHealPredictionCalculator(),
                    incoming = CreateUnitHealPredictionCalculator() }
        P.calcs.shield:SetDamageAbsorbClampMode(2)
        P.calcs.shield:SetHealAbsorbMode(0)
        P.calcs.healAbsorb:SetHealAbsorbClampMode(0)
        P.calcs.healAbsorb:SetHealAbsorbMode(1)
        P.calcs.incoming:SetIncomingHealClampMode(0)
        P.calcs.incoming:SetIncomingHealOverflowPercent(1.0)
        P.calcs.incoming:SetHealAbsorbMode(0)
    end
    UnitGetDetailedHealPrediction(unit, nil, P.calcs.shield)
    UnitGetDetailedHealPrediction(unit, nil, P.calcs.healAbsorb)
    UnitGetDetailedHealPrediction(unit, nil, P.calcs.incoming)
    local shield = P.calcs.shield:GetDamageAbsorbs()
    local healAbsorb = P.calcs.healAbsorb:GetHealAbsorbs()
    local incoming = P.calcs.incoming:GetIncomingHeals()
    return shield, healAbsorb, incoming, P.calcs.shield:GetMaximumHealth()
end

local function FeedAbsorbList(list, value, max, label)
    if value == nil or max == nil then return end
    for _, bar in ipairs(list) do
        try(label .. " SetMinMaxValues", bar.SetMinMaxValues, bar, 0, max)
        try(label .. " SetValue", bar.SetValue, bar, value)
    end
end

local function FeedAbsorbs(unit)
    if not P.shieldBars then return end
    local ok, shield, healAbsorb, incoming, max = pcall(ReadAbsorbs, unit)
    if not ok then
        P.errors = P.errors + 1
        P.lastError = "calculator: " .. tostring(shield)
        return
    end
    P.calcMissing = not CreateUnitHealPredictionCalculator
    FeedAbsorbList(P.shieldBars, shield, max, "shield")
    FeedAbsorbList(P.healAbsorbBars, healAbsorb, max, "heal absorb")
    FeedAbsorbList(P.incomingBars, incoming, max, "incoming")
    local function show(fs, v, label)
        if v == nil then
            fs:SetText("none")
        else
            try(label .. " text", fs.SetText, fs, AbbreviateNumbers(v))
        end
    end
    show(P.shieldText, shield, "shield")
    show(P.healAbsorbText, healAbsorb, "heal absorb")
    show(P.incomingText, incoming, "incoming")
    P.absorbSecret = shield ~= nil and issecretvalue and issecretvalue(shield) or false
end

-- ============================================================
-- TEXTURES ON A RING (2026-11-03)
-- Does a radial fill take any image, and how does it look? Its own panel on the left of
-- the main one. Top: normal bar textures, whose lines should run straight across the
-- ring. Middle: art drawn as a ring (Media/Probe), where the shade should follow the
-- curve, and the same art on a thinner ring, which only shows part of the bevel.
-- Bottom: held at 60% so a part-filled ring shows at full health. Check there: is the
-- image cut off where the fill ends (right), or squashed into the filled part (wrong)?
-- The top two rows are fed real health, so errors must stay at 0 in combat too.
-- ============================================================
local BAR_BLIZZARD = "Interface\\TargetingFrame\\UI-StatusBar"
local BAR_BEVEL = "Interface\\AddOns\\DandersFrames\\Media\\DF_Bevel"
local ART_SHADE = "Interface\\AddOns\\DandersFrames_UnitFrames\\Media\\Probe\\RingProbeShade"
local ART_GRAIN = "Interface\\AddOns\\DandersFrames_UnitFrames\\Media\\Probe\\RingProbeGrain"

local function BuildTextureTests(panel)
    local size, gap, thick = 86, 6, 14
    local f = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    f:SetSize(3 * size + 2 * gap + 16, 3 * (size + 14 + gap) + 34)
    f:SetPoint("TOPRIGHT", panel, "TOPLEFT", -12, 0)
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        f:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
        f:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    end
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("Textures on a ring")

    local held = {}
    local half = { start = 0, len = 0.5, reverse = true }
    local tests = {
        { "Plain white", thick, P.bars },
        { "Blizzard bar", thick, P.bars, BAR_BLIZZARD },
        { "DF bevel", thick, P.bars, BAR_BEVEL },
        { "Ring shade", thick, P.bars, ART_SHADE },
        { "Ring shade thin", 6, P.bars, ART_SHADE },
        { "Ring grain", thick, P.bars, ART_GRAIN },
        { "Bar at 60%", thick, held, BAR_BLIZZARD },
        { "Ring art at 60%", thick, held, ART_SHADE },
        { "Reversed half arc", thick, held, ART_SHADE, half },
    }
    for i, t in ipairs(tests) do
        local holder = AbsorbTest(f, size, t[1], function(b, s)
            SeeThroughRing(b, s, t[2], t[3], COLOR_HEALTH, t[5], t[4])
        end)
        holder:SetPoint("TOPLEFT", 8 + ((i - 1) % 3) * (size + gap), -30 - math.floor((i - 1) / 3) * (size + 14 + gap))
    end
    for _, bar in ipairs(held) do
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0.6)
    end
    return f
end

-- ============================================================
-- TILE SIZE ON A RING (2026-11-03)
-- A bar's Tile Size repeats the image with SetTexCoord. On a ring that does nothing
-- visible, so: does a radial fill ignore texcoords, or does the bar reset them when its
-- value is written? All six use the same stripes, 8 repeats across the ring.
--   Plain texture    no bar at all: what 8 repeats should look like
--   Set before value / Set after value / Set every feed   the three possible timings
--   Tile flags       no texcoords: the image repeating at its own file size
--   Zoomed in        texcoords below 1, no repeat needed: do they do anything at all?
--   Offsets after    the repeats, then radial offsets on top, as a real ring's layout did
--   Re-anchored      the repeats, then the bar re-anchored and re-sized
--   Live value       the repeats once, then real health writes with no re-apply
-- The lines under the panel read the coordinates back off the bars, on every update. 8
-- means the bar kept them; 1 means it reset them.
-- ============================================================
local TILE_ART = "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes"
local TILE_REPEATS = 8

local function CoordOf(tex)
    local ok, _, _, _, _, urx = pcall(tex.GetTexCoord, tex)
    if ok and type(urx) == "number" then return format("%.2f", urx) end
    return "?"
end

local function BuildTileTests(above)
    local size, gap, thick = 86, 6, 14
    local f = CreateFrame("Frame", nil, above, "BackdropTemplate")
    f:SetSize(3 * size + 2 * gap + 16, 3 * (size + 14 + gap) + 66)
    f:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -8)
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        f:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
        f:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    end
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("Tile size on a ring")

    P.tileLive, P.tileHeld = {}, {}
    local function Coords(tex, u) try("tile coords", tex.SetTexCoord, tex, 0, u or TILE_REPEATS, 0, u or TILE_REPEATS) end
    -- A held ring at 60%. `before` and `after` run either side of its value being written.
    local function Held(b, s, before, after)
        local list = {}
        SeeThroughRing(b, s, thick, list, COLOR_HEALTH, nil, TILE_ART)
        local bar = list[1]
        local tex = bar:GetStatusBarTexture()
        try("tile wrap", tex.SetTexture, tex, TILE_ART, "REPEAT", "REPEAT")
        if before then before(tex) end
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0.6)
        if after then after(tex) end
        return bar, tex
    end
    local tests = {
        { "Plain texture", function(b, s)
            local tex = b:CreateTexture(nil, "ARTWORK")
            tex:SetSize(s, s)
            tex:SetPoint("CENTER")
            tex:SetTexture(TILE_ART, "REPEAT", "REPEAT")
            tex:SetVertexColor(COLOR_HEALTH[1], COLOR_HEALTH[2], COLOR_HEALTH[3], 1)
            MaskRing(tex, b, s, s - 2 * thick)
            Coords(tex)
        end },
        { "Set before value", function(b, s)
            local _, tex = Held(b, s, function(t) Coords(t) end)
            P.tileBefore = tex
        end },
        { "Set after value", function(b, s)
            local _, tex = Held(b, s, nil, function(t) Coords(t) end)
            P.tileAfter = tex
        end },
        { "Set every feed", function(b, s)
            SeeThroughRing(b, s, thick, P.tileLive, COLOR_HEALTH, nil, TILE_ART)
            local tex = P.tileLive[#P.tileLive]:GetStatusBarTexture()
            try("tile wrap", tex.SetTexture, tex, TILE_ART, "REPEAT", "REPEAT")
        end },
        { "Tile flags", function(b, s)
            Held(b, s, function(t)
                try("tile horiz", t.SetHorizTile, t, true)
                try("tile vert", t.SetVertTile, t, true)
            end)
        end },
        { "Zoomed in", function(b, s)
            Held(b, s, nil, function(t) Coords(t, 0.25) end)
        end },
        { "Offsets after", function(b, s)
            local _, tex = Held(b, s, function(t) Coords(t) end)
            try("tile start", tex.SetRadialProgressBarStartOffset, tex, 0)
            try("tile end", tex.SetRadialProgressBarEndOffset, tex, 0)
            try("tile reverse", tex.SetRadialProgressBarReverse, tex, false)
            try("tile feather", tex.SetRadialProgressBarFeather, tex, 0)
            P.tileOffsets = tex
        end },
        { "Re-anchored", function(b, s)
            local bar, tex = Held(b, s, function(t) Coords(t) end)
            bar:ClearAllPoints()
            bar:SetPoint("CENTER")
            bar:SetSize(s, s)
            P.tileAnchored = tex
        end },
        { "Live value", function(b, s)
            SeeThroughRing(b, s, thick, P.bars, COLOR_HEALTH, nil, TILE_ART)
            local tex = P.bars[#P.bars]:GetStatusBarTexture()
            try("tile wrap", tex.SetTexture, tex, TILE_ART, "REPEAT", "REPEAT")
            Coords(tex)
            P.tileValue = tex
        end },
    }
    for i, t in ipairs(tests) do
        local holder = AbsorbTest(f, size, t[1], t[2])
        holder:SetPoint("TOPLEFT", 8 + ((i - 1) % 3) * (size + gap), -30 - math.floor((i - 1) / 3) * (size + 14 + gap))
    end
    P.tileRead = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    P.tileRead:SetPoint("BOTTOMLEFT", 10, 8)
    P.tileRead:SetJustifyH("LEFT")
end

local function FeedTile(unit)
    if not P.tileLive then return end
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    for _, bar in ipairs(P.tileLive) do
        try("tile SetMinMaxValues", bar.SetMinMaxValues, bar, 0, max)
        try("tile SetValue", bar.SetValue, bar, cur)
        local tex = bar:GetStatusBarTexture()
        try("tile coords", tex.SetTexCoord, tex, 0, TILE_REPEATS, 0, TILE_REPEATS)
    end
    P.tileRead:SetText(format("Read back (8 = kept, 1 = reset): before %s, after %s\noffsets %s, re-anchored %s, live value %s",
        CoordOf(P.tileBefore), CoordOf(P.tileAfter), CoordOf(P.tileOffsets), CoordOf(P.tileAnchored), CoordOf(P.tileValue)))
end

local function TransparentRing(panel)
    local holder = CreateFrame("Frame", nil, panel)
    holder:SetSize(140, 160)
    holder:SetPoint("TOPLEFT", panel, "TOPRIGHT", 12, 0)
    -- Outer: power, 6 thick. A 6px gap. Inner: health, 10 thick.
    SeeThroughRing(holder, 120, 6, P.powerBars, { 0.25, 0.5, 1 })
    SeeThroughRing(holder, 120 - 2 * (6 + 6), 10, P.bars, { 0.2, 0.85, 0.3 })
    local text = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("BOTTOM")
    text:SetText("Transparent ring")
    return holder
end

-- A normal linear bar cut by a rounded-corner mask: the shape test.
local function ShapedLinearBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(220, 22)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(0.2, 0.85, 0.3, 1)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(WHITE)
    bg:SetVertexColor(0.15, 0.15, 0.15, 1)
    local mask = bar:CreateMaskTexture()
    mask:SetTexture(ROUNDED, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(bar)
    try("AddMaskTexture (linear)", bar:GetStatusBarTexture().AddMaskTexture, bar:GetStatusBarTexture(), mask)
    bg:AddMaskTexture(mask)
    P.bars[#P.bars + 1] = bar
    return bar
end

local function Build()
    local f = CreateFrame("Frame", "DandersFramesRingProbe", UIParent, "BackdropTemplate")
    f:SetSize(560, 640)
    f:SetPoint("CENTER", 0, 60)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        f:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
        f:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("Round bar probe (drag to move, /dfring to close)")

    P.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    P.status:SetPoint("BOTTOMLEFT", 10, 8)
    P.status:SetWordWrap(true)
    P.status:SetPoint("BOTTOMRIGHT", -10, 8)
    P.status:SetJustifyH("LEFT")
    P.frame = f

    if not radialSupported() then
        P.status:SetText("Radial API missing on this client: Enum.StatusBarRenderMode.Radial is nil.")
        return f
    end

    local x = 12
    local function place(holder)
        holder:SetPoint("TOPLEFT", x, -32)
        x = x + holder:GetWidth() + 14
    end
    place(RadialBar(f, 80, "Full disc", nil, false))
    place(RadialBar(f, 80, "Ring", nil, true))
    place(RadialBar(f, 80, "Half arc", function(tex)
        try("SetStartOffset", tex.SetRadialProgressBarStartOffset, tex, 0.25)
        try("SetEndOffset", tex.SetRadialProgressBarEndOffset, tex, 0.5)
    end, true))
    place(RadialBar(f, 80, "Feather", function(tex)
        try("SetFeather", tex.SetRadialProgressBarFeather, tex, 0.15)
    end, true))
    place(RadialBar(f, 80, "Reverse", function(tex)
        try("SetReverse", tex.SetRadialProgressBarReverse, tex, true)
    end, true))

    -- Row 2: power and class power.
    x = 12
    local function place2(holder)
        holder:SetPoint("TOPLEFT", x, -150)
        x = x + holder:GetWidth() + 14
    end
    place2(RadialBar(f, 80, "Power ring", nil, true, P.powerBars, { 0.25, 0.5, 1 }))
    place2(RadialBar(f, 80, "Power arc", function(tex)
        try("power start", tex.SetRadialProgressBarStartOffset, tex, 0.25)
        try("power end", tex.SetRadialProgressBarEndOffset, tex, 0.5)
    end, true, P.powerBars, { 0.25, 0.5, 1 }))
    local _, class = UnitClass("player")
    local token = CLASS_POWER[class] or "ComboPoints"
    P.classPower = Enum.PowerType and Enum.PowerType[token]
    local n = P.classPower and UnitPowerMax("player", P.classPower) or nil
    P.pipSecret = n ~= nil and issecretvalue and issecretvalue(n) or false
    if P.pipSecret or type(n) ~= "number" or n < 1 or n > 10 then n = 5 end
    P.pipCount, P.classToken = n, token
    place2(PipRing(f, 80, token .. " ring", n))
    place2(PipRing(f, 80, token .. " arc", n, { 0.25, 0.75 }))

    local tr = TextRing(f, 120)
    tr:SetPoint("TOPLEFT", 12, -270)

    local linear = ShapedLinearBar(f)
    linear:SetPoint("TOPLEFT", 280, -330)
    local lt = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lt:SetPoint("LEFT", linear, "RIGHT", 10, 0)
    lt:SetText("Linear bar, rounded mask")

    TransparentRing(f)
    BuildAbsorbRow(f)
    BuildTileTests(BuildTextureTests(f))
    return f
end

-- Feed the unit's real health straight in: no Lua maths on it, so this is the
-- same path a secret value takes in combat.
local function Feed()
    local unit = P.unit
    if not UnitExists(unit) then return end
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    for _, bar in ipairs(P.bars) do
        try("SetMinMaxValues", bar.SetMinMaxValues, bar, 0, max)
        try("SetValue", bar.SetValue, bar, cur)
    end
    local pcur, pmax = UnitPower(unit), UnitPowerMax(unit)
    for _, bar in ipairs(P.powerBars) do
        try("power SetMinMaxValues", bar.SetMinMaxValues, bar, 0, pmax)
        try("power SetValue", bar.SetValue, bar, pcur)
    end
    -- Class power is always the player's own (pips are built from the player's class).
    -- Raw value (unmodified = true) so soul shard fragments part-fill a pip; each pip
    -- spans one display unit of it.
    local ccur
    if P.classPower then
        ccur = UnitPower("player", P.classPower, true)
        local mod = UnitPowerDisplayMod and UnitPowerDisplayMod(P.classPower) or 1
        if (issecretvalue and issecretvalue(mod)) or mod == 0 then mod = 1 end
        for _, bar in ipairs(P.pips) do
            local i = bar.pipIndex
            try("pip SetMinMaxValues", bar.SetMinMaxValues, bar, (i - 1) * mod, i * mod)
            try("pip SetValue", bar.SetValue, bar, ccur)
        end
    end
    -- Text: the same secret-safe calls the frames' health text uses.
    for _, fs in ipairs(P.texts) do
        if fs.kind == "pct" and UnitHealthPercent and CurveConstants then
            try("pct text", fs.SetFormattedText, fs, "%.0f%%", UnitHealthPercent(unit, true, CurveConstants.ScaleTo100))
        elseif fs.kind == "health" then
            try("health text", fs.SetText, fs, AbbreviateNumbers(UnitHealth(unit, true)))
        elseif fs.kind == "power" then
            try("power text", fs.SetText, fs, AbbreviateNumbers(pcur))
        elseif fs.kind == "name" then
            try("name text", fs.SetText, fs, UnitName(unit))
        end
    end
    FeedAbsorbs(unit)
    FeedTile(unit)
    P.updates = P.updates + 1
    local function sec(v) return v ~= nil and issecretvalue and issecretvalue(v) and "yes" or "no" end
    P.status:SetText(format("Unit %s | in combat: %s | updates: %d | errors: %d\nSecret: health %s, power %s, shield %s, %s %s (pips %d%s)%s%s",
        unit, InCombatLockdown() and "yes" or "no", P.updates, P.errors,
        sec(cur), sec(pcur), P.absorbSecret and "yes" or "no", tostring(P.classToken), sec(ccur), P.pipCount or 0,
        P.pipSecret and ", max secret" or "",
        P.calcMissing and "\nNo heal prediction calculator on this client." or "",
        P.lastError and ("\nLast error: " .. P.lastError) or ""))
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, unit)
    if event:find("^UNIT_") then
        if unit == P.unit or unit == "player" then Feed() end
    else
        Feed()
    end
end)

local function Toggle(msg)
    local unit = msg and msg:match("^%s*(%S+)") or "player"
    if P.frame and P.frame:IsShown() and unit == P.unit then
        P.frame:Hide()
        events:UnregisterAllEvents()
        return
    end
    P.unit = unit
    if not P.frame then Build() end
    P.frame:Show()
    if not radialSupported() then return end
    events:RegisterEvent("UNIT_HEALTH")
    events:RegisterEvent("UNIT_MAXHEALTH")
    events:RegisterEvent("UNIT_POWER_UPDATE")
    events:RegisterEvent("UNIT_POWER_FREQUENT")
    events:RegisterEvent("UNIT_MAXPOWER")
    events:RegisterEvent("UNIT_DISPLAYPOWER")
    events:RegisterEvent("UNIT_ABSORB_AMOUNT_CHANGED")
    events:RegisterEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED")
    events:RegisterEvent("UNIT_HEAL_PREDICTION")
    events:RegisterEvent("PLAYER_TARGET_CHANGED")
    events:RegisterEvent("PLAYER_REGEN_DISABLED")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    Feed()
end

SLASH_DANDERSFRAMESRINGPROBE1 = "/dfring"
SlashCmdList.DANDERSFRAMESRINGPROBE = Toggle

-- ============================================================
-- SECRET SetEnabled TRAP (dev only)
-- /dfsecretbtn swaps the shared Button:SetEnabled for a wrapper that, when handed
-- a SECRET value, records the button's debug name (and a short stack if the game
-- allows one) BEFORE the real call errors. Results are listed on a small panel.
-- ☠ Replacing a shared widget method taints every Button: use it to find the
-- caller, then /reload. Never leave it on.
-- ============================================================
local trap = { hits = {}, order = {} }

local function TrapPanel()
    if trap.panel then return trap.panel end
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetSize(620, 200)
    f:SetPoint("TOP", 0, -80)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        f:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
        f:SetBackdropBorderColor(0.6, 0.2, 0.2, 1)
    end
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("TOPLEFT", 8, -8)
    t:SetPoint("BOTTOMRIGHT", -8, 8)
    t:SetJustifyH("LEFT")
    t:SetJustifyV("TOP")
    t:SetWordWrap(true)
    trap.text = t
    trap.panel = f
    return f
end

local function TrapRefresh()
    local lines = { "Secret SetEnabled trap ON (/reload to remove). Buttons handed a secret:" }
    for i = 1, math.min(#trap.order, 5) do
        local h = trap.hits[trap.order[i]]
        lines[#lines + 1] = format("%dx  %s\n     %s", h.count, trap.order[i], h.stack or "(no stack)")
    end
    trap.text:SetText(table.concat(lines, "\n"))
end

local function ArmTrap()
    TrapPanel():Show()
    if trap.armed then TrapRefresh(); return end
    trap.armed = true
    local mt = getmetatable(CreateFrame("Button")).__index
    local real = mt.SetEnabled
    mt.SetEnabled = function(self, value, ...)
        if issecretvalue and issecretvalue(value) then
            local okName, name = pcall(self.GetDebugName, self)
            name = okName and type(name) == "string" and name or tostring(self)
            local h = trap.hits[name]
            if not h then
                local okStack, stack = pcall(debugstack, 2, 4, 0)
                if not okStack or type(stack) ~= "string" or (issecretvalue and issecretvalue(stack)) then stack = nil end
                h = { count = 0, stack = stack }
                trap.hits[name] = h
                trap.order[#trap.order + 1] = name
            end
            h.count = h.count + 1
            TrapRefresh()
        end
        return real(self, value, ...)
    end
    TrapRefresh()
end

SLASH_DANDERSFRAMESSECRETBTN1 = "/dfsecretbtn"
SlashCmdList.DANDERSFRAMESSECRETBTN = ArmTrap
--@end-do-not-package@
