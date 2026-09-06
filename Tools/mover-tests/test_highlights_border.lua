local NS = ...

-- ============================================================
-- ANIMATED / DASHED BORDER DASH POOL -- DandersFrames/Features/Highlights.lua
-- ------------------------------------------------------------
-- The marching ants are N small textures per edge, pooled on the highlight
-- container. Each draw asks for ceil(run / PATTERN_LENGTH) + 2 of them and skips
-- any index the pool cannot answer -- so a pool too small for the edge does not
-- error, it just stops painting part of the way along. That is the whole of bug
-- #1118 item 2: at a hard 20 per edge, any run past ~228 units lost its tail.
--
-- Three settings reach a run that long, and none of them is exotic:
--   * Frame Width -- the slider goes to 300.
--   * Inset < 0 -- the run is width - 2*inset, so -10 costs 20 more units.
--   * Frame Scale > 1 -- the container is scaled and the highlight is not, so
--     ch:GetWidth() comes back multiplied. Nothing to model here beyond a wider
--     frame, which is what the wide cases below are.
--
-- What is asserted is the PROPERTY rather than a dash count: no stretch of an
-- edge longer than one gap may go unpainted, at any animation offset. A dash
-- count copied out of the implementation would agree with a broken pool the
-- moment someone changed PATTERN_LENGTH; "the border has no hole in it" cannot.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE, so the global
-- CreateFrame this file needs at load time is put back immediately afterwards.
-- ============================================================

local savedCreateFrame = CreateFrame

-- Highlights.lua builds two bare frames at file scope (the animator and its
-- event sink) and touches neither at load beyond RegisterEvent/SetScript.
CreateFrame = function() return FakeUIFrame() end
local DF = {}
DF.Debug, DF.DebugWarn, DF.DebugError = function() end, function() end, function() end
load_df_file_into("Features/Highlights.lua", DF)
CreateFrame = savedCreateFrame

local DASH_LENGTH, GAP_LENGTH, PATTERN_LENGTH = 6, 6, 12

-- ☠ NOT shim.lua's FakeUIFrame, and the catch-all is why: its metatable answers
-- every unset key with a truthy no-op function, so `if ch.animBorder then return`
-- would hand the initialiser a function and the pool would never be built at all.
-- These two stubs have no fallback -- an unset field really is nil, and a method
-- the draw path needs and this file forgot is a loud error rather than a silent
-- pass.
local function FakeDash()
    local t = { _shown = false, _w = 0, _h = 0, _points = {} }
    function t:SetColorTexture(r, g, b, a) self._color = { r, g, b, a } end
    function t:Show() self._shown = true end
    function t:Hide() self._shown = false end
    function t:IsShown() return self._shown end
    function t:SetSize(w, h) self._w, self._h = w, h end
    function t:GetWidth() return self._w end
    function t:GetHeight() return self._h end
    function t:ClearAllPoints() for i = #self._points, 1, -1 do self._points[i] = nil end end
    function t:SetPoint(...) self._points[#self._points + 1] = { ... } end
    function t:GetPoint(i)
        local p = self._points[i or 1]
        if not p then return nil end
        return p[1], p[2], p[3], p[4], p[5]
    end
    return t
end

local function FakeHighlight(w, h)
    local f = { _w = w, _h = h, _textures = {} }
    function f:GetWidth() return self._w end
    function f:GetHeight() return self._h end
    function f:SetSize(w2, h2) self._w, self._h = w2, h2 end
    function f:CreateTexture()
        local t = FakeDash()
        self._textures[#self._textures + 1] = t
        return t
    end
    return f
end

local function newBorderFrame(w, h, inset)
    local ch = FakeHighlight(w, h)
    DF:InitAnimatedBorder(ch)
    ch.animThickness, ch.animInset = 2, inset or 0
    ch.animR, ch.animG, ch.animB, ch.animA = 1, 1, 1, 1
    return ch
end

-- The painted spans of one edge, read back off the dashes themselves: a
-- horizontal dash is anchored at (inset + visStart) and is dashW wide, a
-- vertical one at -(inset + visStart) and is dashH tall.
-- Returns the longest unpainted stretch and where it starts.
local function worstGap(dashes, run, inset, vertical)
    local spans = {}
    for i = 1, #dashes do
        local d = dashes[i]
        if d:IsShown() then
            local _, _, _, x, y = d:GetPoint(1)
            local s = vertical and (-y - inset) or (x - inset)
            local len = vertical and d:GetHeight() or d:GetWidth()
            spans[#spans + 1] = { s = s, e = s + len }
        end
    end
    table.sort(spans, function(a, b) return a.s < b.s end)
    local worst, at, cursor = 0, 0, 0
    for _, sp in ipairs(spans) do
        if sp.s - cursor > worst then worst, at = sp.s - cursor, cursor end
        if sp.e > cursor then cursor = sp.e end
    end
    if run - cursor > worst then worst, at = run - cursor, cursor end
    return worst, at
end

-- Every offset the animator can hand out, because which dash falls off the end
-- depends on where the pattern currently sits: at offset 0 a 240-unit edge needs
-- exactly 20 dashes and the old pool got away with it. Every other offset needs
-- 21, which is how the bug hid from a casual look.
local function checkEdgesContinuous(ch, label)
    local inset = ch.animInset
    local width = ch:GetWidth() - inset * 2
    local height = ch:GetHeight() - inset * 2
    local worst, at, where = 0, 0, ""
    for step = 0, PATTERN_LENGTH - 1 do
        DF:UpdateAnimatedBorder(ch, step)
        local edges = {
            { ch.animBorder.topDashes, width, false, "top" },
            { ch.animBorder.bottomDashes, width, false, "bottom" },
            { ch.animBorder.leftDashes, height, true, "left" },
            { ch.animBorder.rightDashes, height, true, "right" },
        }
        for _, e in ipairs(edges) do
            local g, a = worstGap(e[1], e[2], inset, e[3])
            if g > worst then worst, at, where = g, a, e[4] .. " edge at offset " .. step end
        end
    end
    check(worst <= GAP_LENGTH, string.format(
        "%s: %s unpainted for %g units from %g (one gap is %g)",
        label, where, worst, at, GAP_LENGTH))
end

-- ---- the pool still starts where it always did ---------------------
do
    local ch = newBorderFrame(120, 60)
    local ok = true
    for _, key in ipairs({ "topDashes", "bottomDashes", "leftDashes", "rightDashes" }) do
        if #ch.animBorder[key] ~= 20 then ok = false end
    end
    check(ok, "each edge is seeded with 20 dashes before anything is drawn")
end

-- ---- a normal frame neither loses a dash nor grows the pool ---------
do
    local ch = newBorderFrame(120, 60)
    checkEdgesContinuous(ch, "120x60")
    eq(#ch.animBorder.topDashes, 20, "a frame this size never has to grow its pool")
end

-- ---- the reported case: 240 wide ------------------------------------
do
    local ch = newBorderFrame(240, 240)
    checkEdgesContinuous(ch, "240x240")
    eq(#ch.animBorder.topDashes, math.ceil(240 / PATTERN_LENGTH) + 2,
        "a 240-unit edge grows its pool to exactly what the draw asks for")
end

-- ---- inset -10 pulls a 220-wide frame over the same line -------------
do
    local ch = newBorderFrame(220, 220, -10)
    checkEdgesContinuous(ch, "220x220 at inset -10")
end

-- ---- the widest supported frame at the deepest inset -----------------
do
    local ch = newBorderFrame(300, 300, -10)
    checkEdgesContinuous(ch, "300x300 at inset -10 (slider maximum)")
end

-- ---- growth is one-way, and a shrink hides what it grew --------------
-- ☠ THE TRAILING HIDE NOW HAS MORE TO HIDE THAN THE POOL WAS BUILT WITH. Once an
-- edge has grown, a later narrow draw must still take every surplus dash down --
-- otherwise the frame that shrank keeps a row of ants marching off into space.
do
    local ch = newBorderFrame(240, 240)
    DF:UpdateAnimatedBorder(ch, 3)
    local grown = #ch.animBorder.topDashes
    local textures = #ch._textures
    -- Square frame, so all four edges grew to the same size: anything above this
    -- means a top-up threw the dashes it already had away and made a fresh set.
    eq(textures, 4 * grown, "growing an edge adds only the dashes it was missing")

    ch:SetSize(100, 100)
    DF:UpdateAnimatedBorder(ch, 3)
    eq(#ch._textures, textures, "a narrower draw creates no textures and destroys none")
    eq(#ch.animBorder.topDashes, grown, "the grown pool is kept for the next wide draw")

    local stray = false
    for i = 1, #ch.animBorder.topDashes do
        local d = ch.animBorder.topDashes[i]
        if d:IsShown() then
            local _, _, _, x = d:GetPoint(1)
            if x + d:GetWidth() > 100 + 0.001 then stray = true end
        end
    end
    check(not stray, "no dash is left painted past the edge after the frame shrinks")

    ch:SetSize(240, 240)
    DF:UpdateAnimatedBorder(ch, 3)
    eq(#ch._textures, textures, "going wide again reuses the pooled dashes")
end

-- ---- the static DASHED border draws through the same path ------------
-- Source census: ApplyHighlightStyle is a file-local, so the only headless way
-- to say "the fix reaches DASHED too" is to read the branch it shares.
do
    local src = df_file_source("Features/Highlights.lua")
    check(src:find('mode == "ANIMATED" or mode == "DASHED"', 1, true) ~= nil,
        "ANIMATED and DASHED still share one branch")
    check(src:find("DF:UpdateAnimatedBorder(ch, 0)", 1, true) ~= nil,
        "DASHED paints through UpdateAnimatedBorder, so it grows the pool too")
end
