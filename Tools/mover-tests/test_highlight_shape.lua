local NS = ...

-- ============================================================
-- OUTLINED HIGHLIGHTS -- DandersFrames/Features/Highlights.lua (SHAPED OUTLINE)
-- ------------------------------------------------------------
-- A frame carrying dfHighlightShape gets its SOLID / GLOW / ANIMATED / DASHED
-- highlights drawn round the union of the rects it returns; CORNERS and every
-- frame without the field keep the plain rectangle.
--
-- What is asserted is the GEOMETRY, against a raster built here from the rects
-- themselves (not from the implementation): the band `t` deep just inside the
-- union moved by the inset -- every cell of it painted (so no notch at an inside
-- corner and no unpainted edge), nothing painted outside it (so nothing in the
-- interior past the thickness and nothing in an empty corner), and for SOLID /
-- each GLOW layer nothing painted twice.
--
-- Also: the resting glow's outline is byte-for-byte what it was before its grid
-- was shared (a snapshot taken off the pre-refactor code), the style signature
-- re-runs when the shape changes, and the slider-drag path redraws an outlined
-- highlight rather than painting the four rectangle lines over it.
--
-- ☠ ONE LUA RUNTIME FOR EVERY TEST FILE: the globals this needs are put back at
-- the end.
-- ============================================================

local G_NAMES = { "CreateFrame", "GetPhysicalScreenSize", "UnitThreatSituation", "IsInRaid" }
local G = {}
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local DF = {}
DF.Debug, DF.DebugWarn, DF.DebugError = function() end, function() end, function() end

-- The outline grid, lifted out of Frames/Create.lua by its section header (the
-- file builds tooltips at file scope, so it is not loaded whole).
do
    local src = df_file_source("Frames/Create.lua")
    local a = src:find("-- RESTED INDICATOR BUILDER", 1, true)
    local b = src:find("-- SAFE UNIT WATCH REGISTRATION", 1, true)
    assert(a and b, "rested builder section in Create.lua")
    assert(loadstring("local DF, CreateFrame, ipairs = ... " .. src:sub(a, b - 1), "@rested_builder"))(DF, CreateFrame, ipairs)
end

CreateFrame = function() return FakeUIFrame() end
load_df_file_into("Features/Highlights.lua", DF)

-- One device pixel per unit at scale 1: every snapped value is a whole number.
GetPhysicalScreenSize = function() return 1024, 768 end
local threat = 0
UnitThreatSituation = function() return threat end
IsInRaid = function() return false end

-- ---- strict fakes (no catch-all: an unset method is a loud error) ----------
local function FakeTex()
    local t = { _shown = false, _points = {}, _w = 0, _h = 0, placed = 0 }
    function t:SetColorTexture(r, g, b, a) self._color = { r, g, b, a } end
    function t:Show() self._shown = true end
    function t:Hide() self._shown = false end
    function t:IsShown() return self._shown end
    function t:SetSize(w, h) self._w, self._h = w, h end
    function t:SetWidth(w) self._w = w end
    function t:SetHeight(h) self._h = h end
    function t:GetWidth() return self._w end
    function t:GetHeight() return self._h end
    function t:ClearAllPoints() self._points = {}; self.placed = self.placed + 1 end
    function t:SetPoint(...) self._points[#self._points + 1] = { ... } end
    return t
end

local function FakeFrameBase(t)
    t._shown, t._points, t._textures, t._level = true, {}, {}, 1
    function t:Show() self._shown = true end
    function t:Hide() self._shown = false end
    function t:IsShown() return self._shown end
    function t:IsVisible() return self._shown end
    function t:ClearAllPoints() self._points = {} end
    function t:SetPoint(...) self._points[#self._points + 1] = { ... } end
    function t:SetFrameStrata(s) self._strata = s end
    function t:GetFrameStrata() return self._strata or "MEDIUM" end
    function t:SetFrameLevel(l) self._level = l end
    function t:GetFrameLevel() return self._level end
    function t:SetAlpha(a) self._alpha = a end
    function t:CreateTexture()
        local tex = FakeTex()
        self._textures[#self._textures + 1] = tex
        return tex
    end
    return t
end

-- The highlight container: parented to UIParent (scale 1), spanning its owner.
local function FakeHighlightFrame()
    local ch = FakeFrameBase({})
    function ch:GetEffectiveScale() return 1 end
    local function owner(self)
        local p = self._points[1]
        return p and p[2]
    end
    function ch:GetWidth() local o = owner(self); return o and o._w * o._scale or 0 end
    function ch:GetHeight() local o = owner(self); return o and o._h * o._scale or 0 end
    function ch:SetScript(name, fn) self._scripts = self._scripts or {}; self._scripts[name] = fn end
    function ch:GetScript(name) return self._scripts and self._scripts[name] end
    function ch:SetBackdrop(b) self._backdrop = b end
    function ch:SetBackdropBorderColor(...) self._border = { ... } end
    return ch
end
CreateFrame = function(_, _, parent, template)
    local f = FakeHighlightFrame()
    f._template = template
    if parent and parent ~= UIParent and parent._glowKids then parent._glowKids[#parent._glowKids + 1] = f end
    return f
end

local db = {
    selectionHighlightMode = "SOLID", selectionHighlightThickness = 2, selectionHighlightInset = 0,
    selectionHighlightAlpha = 1, selectionHighlightColor = { r = 1, g = 1, b = 1 },
    hoverHighlightMode = "NONE", aggroHighlightMode = "NONE",
}
function DF:GetFrameDB() return db end
function DF:MemTestDisabled() return false end
function DF:FrameInTestScope() return false end
local selected = true
DF.UnitIsUnit = function() return selected end

local function NewOwner(w, h, rects, scale)
    local f = FakeFrameBase({ _w = w, _h = h, _scale = scale or 1 })
    f.dfStandalone, f.unit, f.dfIsDead = true, "target", false
    function f:GetEffectiveScale() return self._scale end
    function f:HookScript() end
    if rects then
        f.shapeCalls = 0
        f.rects = rects
        f.dfHighlightShape = function(self) self.shapeCalls = self.shapeCalls + 1; return self.rects end
    end
    return f
end

-- ---- the raster ------------------------------------------------------------
-- Cells are 1x1 at integer coordinates (x right, y down, highlight units); a
-- cell is named by its top-left corner.
local function key(x, y) return x .. ":" .. y end

local function Union(rects, k)
    k = k or 1
    local set = {}
    for _, r in ipairs(rects) do
        for x = r[1] * k, r[3] * k - 1 do
            for y = r[2] * k, r[4] * k - 1 do set[key(x, y)] = true end
        end
    end
    return set
end

local function Bounds(set)
    local x0, y0, x1, y1 = 1e9, 1e9, -1e9, -1e9
    for kk in pairs(set) do
        local x, y = kk:match("^(-?%d+):(-?%d+)$")
        x, y = tonumber(x), tonumber(y)
        if x < x0 then x0 = x end
        if y < y0 then y0 = y end
        if x > x1 then x1 = x end
        if y > y1 then y1 = y end
    end
    return x0, y0, x1, y1
end

-- d > 0 erodes (Chebyshev), d < 0 dilates.
local function Morph(set, d)
    if d == 0 then return set end
    local x0, y0, x1, y1 = Bounds(set)
    local r = math.abs(d)
    local out = {}
    for x = x0 - r, x1 + r do
        for y = y0 - r, y1 + r do
            local all, any = true, false
            for ox = -r, r do
                for oy = -r, r do
                    if set[key(x + ox, y + oy)] then any = true else all = false end
                end
            end
            if (d > 0 and all) or (d < 0 and any) then out[key(x, y)] = true end
        end
    end
    return out
end

-- The cells `t` deep just inside the union moved by d (positive = inwards).
local function Band(set, d, t)
    local moved = Morph(set, d)
    local inner = Morph(moved, t)
    local out = {}
    for kk in pairs(moved) do
        if not inner[kk] then out[kk] = true end
    end
    return out
end

-- Cells painted by shown TOPLEFT-anchored textures; counts per cell. `filter`
-- picks textures (nil = all shown).
local function Painted(texes, filter)
    local cnt, bad = {}, nil
    for _, t in ipairs(texes) do
        if t:IsShown() and (not filter or filter(t)) then
            local p = t._points[1]
            if not (p and p[1] == "TOPLEFT" and #t._points == 1) then
                bad = "a piece not anchored by its TOPLEFT alone"
            else
                local x, y, w, h = p[4], -p[5], t._w, t._h
                if x ~= math.floor(x) or y ~= math.floor(y) or w ~= math.floor(w) or h ~= math.floor(h) then
                    bad = string.format("a piece off the pixel grid: %s,%s %sx%s", x, y, w, h)
                end
                for cx = math.floor(x), math.ceil(x + w) - 1 do
                    for cy = math.floor(y), math.ceil(y + h) - 1 do
                        local kk = key(cx, cy)
                        cnt[kk] = (cnt[kk] or 0) + 1
                    end
                end
            end
        end
    end
    return cnt, bad
end

-- painted == expected (every cell of it, nothing else), at most `maxCount` deep.
local function SameCells(cnt, expected, label, maxCount, subset)
    local missing, extra, twice, nMissing, nExtra = nil, nil, nil, 0, 0
    for kk in pairs(expected) do
        if not cnt[kk] then nMissing = nMissing + 1; missing = missing or kk end
    end
    for kk, c in pairs(cnt) do
        if not expected[kk] then nExtra = nExtra + 1; extra = extra or kk end
        if maxCount and c > maxCount then twice = twice or kk end
    end
    if not subset then
        check(nMissing == 0, string.format("%s: every cell of the outline band painted (%d missing, e.g. %s)", label, nMissing, tostring(missing)))
    end
    check(nExtra == 0, string.format("%s: nothing painted off the band (%d stray, e.g. %s)", label, nExtra, tostring(extra)))
    if maxCount then
        check(twice == nil, string.format("%s: no cell painted twice (e.g. %s)", label, tostring(twice)))
    end
end

local function Sel(f) return f.dfSelectionHighlight end

local function Apply(f, mode, t, inset)
    db.selectionHighlightMode = mode
    db.selectionHighlightThickness = t
    db.selectionHighlightInset = inset
    DF:UpdateHighlights(f)
    return Sel(f)
end

local function PlainLinesHidden(ch)
    return not (ch.topLine:IsShown() or ch.bottomLine:IsShown() or ch.leftLine:IsShown() or ch.rightLine:IsShown())
end

-- ---- the shapes (frame units, frame = 60 x 20) ---------------------------
-- Steps of 4+ so nothing snaps (edges within 3 merge, as the glow's do), and an
-- overhang tall enough that the deepest inset still leaves it twice the
-- thickness: a piece thinner than two strips is painted by both, which is
-- geometry, not a bug.
local FRAME = { 0, 0, 60, 20 }
local SHAPES = {
    { "plain rectangle",                 { FRAME } },
    { "portrait left, taller",           { FRAME, { -20, -6, 0, 26 } } },
    { "portrait right, shorter",         { FRAME, { 60, 4, 80, 16 } } },
    { "class bar above, narrower",       { FRAME, { 10, -8, 50, 0 } } },
    { "class bar above, wider",          { FRAME, { -8, -10, 68, 0 } } },
    { "bar below narrower + portrait",   { FRAME, { 10, 20, 50, 32 }, { -20, -6, 0, 26 } } },
}

print("-- Outlined SOLID: the band inside the union, inset moving the whole outline")
for _, s in ipairs(SHAPES) do
    local U = Union(s[2])
    for _, ti in ipairs({ { 1, 0 }, { 2, 0 }, { 3, 0 }, { 2, 3 }, { 2, -4 } }) do
        local f = NewOwner(60, 20, s[2])
        local ch = Apply(f, "SOLID", ti[1], ti[2])
        local label = string.format("SOLID %s, t%d inset %d", s[1], ti[1], ti[2])
        check(ch:IsShown() and PlainLinesHidden(ch), label .. ": the four rectangle lines stay hidden")
        local cnt, bad = Painted(ch._textures)
        check(bad == nil, label .. ": " .. tostring(bad))
        SameCells(cnt, Band(U, ti[2], ti[1]), label, 1)
    end
end

print("-- Outlined GLOW: four layers, each the outline grown by its offset")
for _, s in ipairs(SHAPES) do
    local U = Union(s[2])
    for _, ti in ipairs({ { 1, 0 }, { 2, 0 }, { 3, 2 }, { 2, -3 } }) do
        local f = NewOwner(60, 20, s[2])
        local t, inset = ti[1], ti[2]
        local ch = Apply(f, "GLOW", t, inset)
        local label = string.format("GLOW %s, t%d inset %d", s[1], t, inset)
        check(ch.glowLayers == nil, label .. ": no backdrop layers (they only draw a box)")
        local step = math.min(t, 2)
        for i = 1, 4 do
            local a = 1 * (1.1 - (i * 0.25))
            local cnt, bad = Painted(ch._textures, function(tex)
                return tex._color and math.abs(tex._color[4] - a) < 1e-9
            end)
            check(bad == nil, label .. ": " .. tostring(bad))
            SameCells(cnt, Band(U, -((i - 1) * step + inset), t), label .. " layer " .. i, 1)
        end
    end
end

print("-- Outlined DASHED / ANIMATED: dashes inside the band, reaching all of it")
local PATTERN = 12
for _, s in ipairs(SHAPES) do
    local U = Union(s[2])
    for _, mi in ipairs({ { "DASHED", 2, 0 }, { "DASHED", 1, 2 }, { "ANIMATED", 2, -3 } }) do
        local f = NewOwner(60, 20, s[2])
        local ch = Apply(f, mi[1], mi[2], mi[3])
        local label = string.format("%s %s, t%d inset %d", mi[1], s[1], mi[2], mi[3])
        local band = Band(U, mi[3], mi[2])
        check(PlainLinesHidden(ch), label .. ": rectangle lines hidden")
        check(ch.dfHlLoopStrips ~= nil, label .. ": marching along the outline's strips")
        local reached = {}
        local share
        for off = 0, PATTERN - 1 do
            DF:UpdateAnimatedBorder(ch, off)
            local cnt, bad = Painted(ch.animBorder.loopDashes)
            check(bad == nil, label .. " at " .. off .. ": " .. tostring(bad))
            SameCells(cnt, band, label .. " at offset " .. off, nil, true)
            local n, total = 0, 0
            for kk in pairs(cnt) do reached[kk] = true; n = n + 1 end
            for _ in pairs(band) do total = total + 1 end
            if off == 0 then share = n / total end
        end
        SameCells(reached, band, label .. " (every offset together)")
        check(share > 0.3 and share < 0.75, string.format("%s: dashed, not solid (%.2f of the band lit)", label, share))
        for _, d in ipairs({ "topDashes", "bottomDashes", "leftDashes", "rightDashes" }) do
            for _, dash in ipairs(ch.animBorder[d]) do
                check(not dash:IsShown(), label .. ": the rectangle's own dashes stay hidden")
            end
        end
    end
end

-- The phase runs on round the loop: along one loop the strips' start positions
-- only ever grow, ending at the perimeter, so the ants read as one marching line.
do
    local f = NewOwner(60, 20, SHAPES[6][2])
    local ch = Apply(f, "ANIMATED", 2, 0)
    local strips = ch.dfHlLoopStrips
    local mono = true
    for n = 2, #strips do
        if strips[n][7] < strips[n - 1][7] then mono = false end
    end
    check(mono, "ANIMATED: one loop, its dash phase continuous along the perimeter")
    check(#strips >= 12, "ANIMATED: one strip per outline edge of the stepped shape (" .. #strips .. ")")
    local last = strips[#strips]
    -- 80 x 38 bounds plus the 6-deep notch between the portrait and the bar, twice
    check(math.abs(last[7] + last[8] - 248) <= 2, "...the last ends a whole perimeter (248) round: " .. (last[7] + last[8]))
end

print("-- A small gap between the pieces is bridged into one outline")
do
    local rects = { FRAME, { -22, -6, -2, 26 } }      -- the portrait 2 off the frame
    local U = Union({ FRAME, { -22, -6, -2, 26 }, { -2, 0, 0, 20 } })
    local f = NewOwner(60, 20, rects)
    local ch = Apply(f, "SOLID", 2, 0)
    local cnt = Painted(ch._textures)
    SameCells(cnt, Band(U, 0, 2), "SOLID across a 2-unit gap", 1)
end

print("-- A scaled frame: the outline in the highlight's units")
do
    local f = NewOwner(60, 20, SHAPES[2][2], 2)
    local ch = Apply(f, "SOLID", 2, 0)
    local cnt = Painted(ch._textures)
    SameCells(cnt, Band(Union(SHAPES[2][2], 2), 0, 2), "SOLID at frame scale 2 (thickness unscaled)", 1)
end

print("-- CORNERS stays on the frame's rectangle")
do
    local f = NewOwner(60, 20, SHAPES[2][2])
    Apply(f, "SOLID", 2, 0)
    local calls = f.shapeCalls
    local ch = Apply(f, "CORNERS", 2, 0)
    eq(f.shapeCalls, calls, "CORNERS never asks for the shape")
    local stray = false
    for _, t in ipairs(ch.dfShapeTex or {}) do if t:IsShown() then stray = true end end
    check(not stray, "CORNERS: the outline's strips are hidden")
    check(ch.topLine:IsShown() and ch.topRight:IsShown(), "CORNERS: the corner pieces drawn")
    local p = ch.topRight._points[1]
    check(p and p[1] == "TOPRIGHT" and p[2] == ch, "CORNERS: anchored to the frame's own rectangle")
end

print("-- A frame without a shape: the plain renderer, untouched")
do
    local f = NewOwner(60, 20, nil)
    local ch = Apply(f, "SOLID", 2, 0)
    check(ch.topLine:IsShown() and ch.leftLine:IsShown(), "SOLID: the four lines")
    eq(ch.dfShapeTex, nil, "SOLID: no outline pool ever made")
    ch = Apply(f, "GLOW", 2, 0)
    check(ch.glowLayers and #ch.glowLayers == 4, "GLOW: the four backdrop layers")
    eq(ch.dfShapeTex, nil, "GLOW: no outline pool")
    ch = Apply(f, "ANIMATED", 2, 0)
    eq(ch.dfHlLoopStrips, nil, "ANIMATED: no loop strips")
    eq(ch.animBorder.loopDashes, nil, "ANIMATED: the edge dashes, not the loop pool")
    local lit = false
    for _, d in ipairs(ch.animBorder.topDashes) do if d:IsShown() then lit = true end end
    check(lit, "ANIMATED: the top edge's own dashes march")
    -- a shape function that answers nil is the plain rectangle too
    local g = NewOwner(60, 20, nil)
    g.dfHighlightShape = function() return nil end
    ch = Apply(g, "SOLID", 2, 0)
    check(ch.topLine:IsShown(), "a nil shape: the four lines")
end

print("-- The signature: unchanged inputs skip, a new shape re-runs")
do
    local f = NewOwner(60, 20, SHAPES[4][2])
    local ch = Apply(f, "SOLID", 2, 0)
    local placed = 0
    for _, t in ipairs(ch._textures) do placed = placed + t.placed end
    DF:UpdateHighlights(f)
    local again = 0
    for _, t in ipairs(ch._textures) do again = again + t.placed end
    eq(again, placed, "same shape, same style: nothing re-laid")
    local pool = #ch.dfShapeTex
    f.rects = { { 0, 0, 90, 20 }, { 10, -8, 50, 0 } }
    f._w = 90
    DF:UpdateHighlights(f)
    SameCells(Painted(ch._textures), Band(Union(f.rects), 0, 2), "the frame widened to 90", 1)
    f.rects = { { 0, 0, 90, 20 } }
    DF:UpdateHighlights(f)
    SameCells(Painted(ch._textures), Band(Union(f.rects), 0, 2), "the class bar switched off", 1)
    eq(#ch.dfShapeTex, pool, "re-traced from the same pool (no new textures)")
    f._scale = 2
    DF:UpdateHighlights(f)
    SameCells(Painted(ch._textures), Band(Union(f.rects, 2), 0, 2), "the frame's scale changed", 1)
end

print("-- A resize or rescale nothing re-applies: the container's own size change does")
do
    local f = NewOwner(60, 20, SHAPES[2][2])
    local ch = Apply(f, "SOLID", 2, 0)
    local onSize = ch:GetScript("OnSizeChanged")
    check(type(onSize) == "function", "an outlined highlight watches its container's size")
    f._scale = 1.5
    f.rects = { { 0, 0, 60, 20 }, { -20, -6, 0, 26 } }
    onSize(ch)
    SameCells(Painted(ch._textures), Band(Union({ { 0, 0, 90, 30 }, { -30, -9, 0, 39 } }), 0, 2),
        "re-traced at the owner's new scale", 1)
    local g = NewOwner(60, 20, nil)
    eq(Apply(g, "SOLID", 2, 0):GetScript("OnSizeChanged"), nil, "a plain highlight gets no size script")
end

print("-- Hover and aggro trace it too; aggro's health colour does not")
do
    local f = NewOwner(60, 20, SHAPES[2][2])
    db.selectionHighlightMode = "NONE"
    db.hoverHighlightMode, db.hoverHighlightThickness, db.hoverHighlightInset = "SOLID", 2, 0
    db.hoverHighlightAlpha, db.hoverHighlightColor = 1, { r = 1, g = 1, b = 1 }
    f.dfIsHovered = true
    DF:UpdateHighlights(f)
    SameCells(Painted(f.dfHoverHighlight._textures), Band(Union(SHAPES[2][2]), 0, 2), "hover SOLID", 1)
    f.dfIsHovered = false
    db.hoverHighlightMode = "NONE"
    threat = 3
    db.aggroHighlightMode, db.aggroHighlightThickness, db.aggroHighlightInset, db.aggroHighlightAlpha = "SOLID", 1, 0, 1
    DF:UpdateHighlights(f)
    SameCells(Painted(f.dfAggroHighlight._textures), Band(Union(SHAPES[2][2]), 0, 1), "aggro SOLID", 1)
    db.aggroHighlightMode = "HEALTH_COLOR"
    DF:UpdateHighlights(f)
    check(f.dfAggroActive == true and not f.dfAggroHighlight:IsShown(), "aggro HEALTH_COLOR: the health bar, no border")
    threat = 0
    db.aggroHighlightMode = "NONE"
    db.selectionHighlightMode = "SOLID"
end

print("-- The slider-drag path redraws an outlined highlight")
do
    local src = df_file_source("Core.lua")
    local a = src:find("function DF:LightweightUpdateHighlight", 1, true)
    local b = src:find("-- Drag callback for Anchor", a, true)
    assert(a and b, "LightweightUpdateHighlight in Core.lua")
    local frames = {}
    local iter = function(_, fn) for _, f in ipairs(frames) do fn(f) end end
    assert(loadstring("local DF, IterateFramesInMode = ... " .. src:sub(a, b - 1), "@lightweight_highlight"))(DF, iter)
    DF.db = { party = db }
    DF.GUI = { SelectedMode = "party" }

    local shaped = NewOwner(60, 20, SHAPES[4][2])
    local plain = NewOwner(60, 20, nil)
    frames = { shaped, plain }
    Apply(shaped, "SOLID", 2, 0)
    Apply(plain, "SOLID", 2, 0)
    db.selectionHighlightThickness = 3
    DF:LightweightUpdateHighlight("selection")
    local ch = Sel(shaped)
    check(PlainLinesHidden(ch), "outlined: the four lines are not painted over the outline")
    SameCells(Painted(ch._textures), Band(Union(SHAPES[4][2]), 0, 3), "outlined, dragged to thickness 3", 1)
    eq(Sel(plain).topLine:GetHeight(), 3, "plain: the drag still writes the lines directly")
    db.selectionHighlightInset = 2
    DF:LightweightUpdateHighlight("selection")
    SameCells(Painted(ch._textures), Band(Union(SHAPES[4][2]), 2, 3), "outlined, dragged to inset 2", 1)
    db.selectionHighlightInset = 0
    DF.db, DF.GUI = nil, nil
end

print("-- The resting glow's outline is what it was before the grid was shared")
do
    -- Taken off the pre-refactor GlowOutlinePieces (one line per shape x spread).
    local SNAP = {
        "SNAP1_8=OUT_TL,-8,-8,8,8;OUT_BL,-8,46,8,8;OUT_TR,220,-8,8,8;OUT_BR,220,46,8,8;TOP,0,-8,220,8;BOTTOM,0,46,220,8;LEFT,-8,0,8,46;RIGHT,220,0,8,46",
        "SNAP1_3=OUT_TL,-3,-3,3,3;OUT_BL,-3,46,3,3;OUT_TR,220,-3,3,3;OUT_BR,220,46,3,3;TOP,0,-3,220,3;BOTTOM,0,46,220,3;LEFT,-3,0,3,46;RIGHT,220,0,3,46",
        "SNAP2_8=OUT_TL,-60,-16,8,8;OUT_BL,-60,54,8,8;OUT_TR,-2,-16,8,8;IN_TR,-2,-8,8,8,1.0000,0.0000,0.0000,1.0000;IN_BR,-2,46,8,8,1.0000,0.0000,1.0000,0.0000;OUT_BR,-2,54,8,8;OUT_TR,220,-8,8,8;OUT_BR,220,46,8,8;TOP,-52,-16,50,8;TOP,6,-8,214,8;BOTTOM,6,46,214,8;BOTTOM,-52,54,50,8;LEFT,-60,-8,8,62;RIGHT,220,0,8,46",
        "SNAP2_3=OUT_TL,-55,-11,3,3;OUT_BL,-55,54,3,3;OUT_TR,-2,-11,3,3;IN_TR,-2,-3,3,3,1.0000,0.0000,0.0000,1.0000;IN_BR,-2,46,3,3,1.0000,0.0000,1.0000,0.0000;OUT_BR,-2,54,3,3;OUT_TR,220,-3,3,3;OUT_BR,220,46,3,3;TOP,-52,-11,50,3;TOP,1,-3,219,3;BOTTOM,1,46,219,3;BOTTOM,-52,54,50,3;LEFT,-55,-8,3,62;RIGHT,-2,-8,3,5;RIGHT,-2,49,3,5;RIGHT,220,0,3,46",
        "SNAP3_8=OUT_TL,-60,-11,8,8;OUT_BL,-60,49,8,8;OUT_TL,-8,-23,8,8;IN_TL,-8,-11,8,8,0.0000,1.0000,0.0000,1.0000;OUT_TR,220,-23,8,8;OUT_BR,220,49,8,8;TOP,0,-23,220,8;TOP,-52,-11,44,8;BOTTOM,-52,49,272,8;LEFT,-60,-3,8,52;LEFT,-8,-15,8,4;RIGHT,220,-15,8,64",
        "SNAP3_3=OUT_TL,-55,-6,3,3;OUT_BL,-55,49,3,3;OUT_TL,-3,-18,3,3;IN_TL,-3,-6,3,3,0.0000,1.0000,0.0000,1.0000;OUT_TR,220,-18,3,3;OUT_BR,220,49,3,3;TOP,0,-18,220,3;TOP,-52,-6,49,3;BOTTOM,-52,49,272,3;LEFT,-55,-3,3,52;LEFT,-3,-15,3,9;RIGHT,220,-15,3,64",
        "SNAP4_8=OUT_TL,-8,-8,8,8;OUT_BL,-8,30,8,8;OUT_TL,12,-18,8,8;IN_TL,12,-8,8,8,0.0000,1.0000,0.0000,1.0000;OUT_TR,80,-18,8,8;IN_TR,80,-8,8,8,1.0000,0.0000,0.0000,1.0000;OUT_TR,100,-8,8,8;OUT_BR,100,30,8,8;TOP,20,-18,60,8;TOP,0,-8,12,8;TOP,88,-8,12,8;BOTTOM,0,30,100,8;LEFT,-8,0,8,30;LEFT,12,-10,8,2;RIGHT,80,-10,8,2;RIGHT,100,0,8,30",
        "SNAP4_3=OUT_TL,-3,-3,3,3;OUT_BL,-3,30,3,3;OUT_TL,17,-13,3,3;IN_TL,17,-3,3,3,0.0000,1.0000,0.0000,1.0000;OUT_TR,80,-13,3,3;IN_TR,80,-3,3,3,1.0000,0.0000,0.0000,1.0000;OUT_TR,100,-3,3,3;OUT_BR,100,30,3,3;TOP,20,-13,60,3;TOP,0,-3,17,3;TOP,83,-3,17,3;BOTTOM,0,30,100,3;LEFT,-3,0,3,30;LEFT,17,-10,3,7;RIGHT,80,-10,3,7;RIGHT,100,0,3,30",
        "SNAP5_8=OUT_TL,-18,22,8,8;OUT_BL,-18,40,8,8;OUT_TL,-8,-8,8,8;IN_TL,-8,22,8,8,0.0000,1.0000,0.0000,1.0000;OUT_TR,100,-8,8,8;IN_TR,100,0,8,5,1.0000,0.0000,0.3750,1.0000;TOP,100,-3,8,3,0.3750,0.6250,0.0000,0.1406,band;IN_BR,110,25,8,8,1.0000,0.0000,1.0000,0.0000;OUT_BR,110,40,8,8;OUT_TR,140,-3,8,8;OUT_BR,140,25,8,8;TOP,0,-8,100,8;TOP,108,-3,32,8;BOTTOM,118,25,22,8;TOP,-10,22,2,8;BOTTOM,-10,40,120,8;LEFT,-18,30,8,10;LEFT,-8,0,8,22;RIGHT,110,33,8,7;RIGHT,140,5,8,20",
        "SNAP5_3=OUT_TL,-13,27,3,3;OUT_BL,-13,40,3,3;OUT_TL,-3,-3,3,3;IN_TL,-3,27,3,3,0.0000,1.0000,0.0000,1.0000;OUT_TR,100,-3,3,3;IN_TR,100,2,3,3,1.0000,0.0000,0.0000,1.0000;IN_BR,110,25,3,3,1.0000,0.0000,1.0000,0.0000;OUT_BR,110,40,3,3;OUT_TR,140,2,3,3;OUT_BR,140,25,3,3;TOP,0,-3,100,3;TOP,103,2,37,3;BOTTOM,113,25,27,3;TOP,-10,27,7,3;BOTTOM,-10,40,120,3;LEFT,-13,30,3,10;LEFT,-3,0,3,27;RIGHT,100,0,3,2;RIGHT,110,28,3,12;RIGHT,140,5,3,20",
        "SNAP6_8=OUT_TL,-8,-8,8,8;OUT_BL,-8,30,8,8;IN_BL,22,30,8,8,0.0000,1.0000,1.0000,0.0000;OUT_BL,22,50,8,8;IN_BR,60,30,8,8,1.0000,0.0000,1.0000,0.0000;OUT_BR,60,50,8,8;OUT_TR,140,-8,8,8;OUT_BR,140,30,8,8;TOP,0,-8,140,8;BOTTOM,0,30,22,8;BOTTOM,68,30,72,8;BOTTOM,30,50,30,8;LEFT,-8,0,8,30;LEFT,22,38,8,12;RIGHT,60,38,8,12;RIGHT,140,0,8,30",
        "SNAP6_3=OUT_TL,-3,-3,3,3;OUT_BL,-3,30,3,3;IN_BL,27,30,3,3,0.0000,1.0000,1.0000,0.0000;OUT_BL,27,50,3,3;IN_BR,60,30,3,3,1.0000,0.0000,1.0000,0.0000;OUT_BR,60,50,3,3;OUT_TR,140,-3,3,3;OUT_BR,140,30,3,3;TOP,0,-3,140,3;BOTTOM,0,30,27,3;BOTTOM,63,30,77,3;BOTTOM,30,50,30,3;LEFT,-3,0,3,30;LEFT,27,33,3,17;RIGHT,60,33,3,17;RIGHT,140,0,3,30",
    }
    local shapes = {
        { { 0, 0, 220, 46 } },
        { { 0, 0, 220, 46 }, { -52, -8, -2, 54 } },
        { { 0, 0, 220, 46 }, { 0, -15, 220, -1 }, { -52, -3, -2, 49 } },
        { { 0, 0, 100, 30 }, { 20, -10, 80, 0 } },
        { { 0, 0, 100, 30 }, { -10, 30, 110, 40 }, { 104, 5, 140, 25 } },
        { { 0, 0, 100, 30 }, { 101, 0.4, 140, 29.6 }, { 30, 31, 60, 50 } },
    }
    local got = {}
    for n, s in ipairs(shapes) do
        for _, sp in ipairs({ 8, 3 }) do
            local out = {}
            for _, p in ipairs(DF.GlowOutlinePieces(s, sp)) do
                local t = { p[1], p[2], p[3], p[4], p[5] }
                if p[6] then for _, c in ipairs(p[6]) do t[#t + 1] = string.format("%.4f", c) end end
                if p[7] then t[#t + 1] = "band" end
                out[#out + 1] = table.concat(t, ",")
            end
            got[#got + 1] = "SNAP" .. n .. "_" .. sp .. "=" .. table.concat(out, ";")
        end
    end
    for n, want in ipairs(SNAP) do
        eq(got[n], want, "glow outline unchanged: " .. want:match("^(SNAP%d+_%d+)"))
    end
end

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
