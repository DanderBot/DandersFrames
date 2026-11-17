-- ============================================================
-- SHRINK HEALTH BAR TO FIT (resourceBarShrinkHealth)
-- Frames/HealthRect.lua is the ONE place that decides the health bar's rect.
-- With the option on, the side an edge-attached, matched power bar hugs stops at
-- the bar's inner edge -- but only while THAT frame's bar is shown. Frames/Bars.lua
-- watches the bar's Show / Hide / SetShown and re-syncs the rect; Reduced Max
-- Health nests its strip inside the same rect.
--
-- Loaded REAL: HealthRect.lua and ReducedMaxHealth.lua. The power bar watch is
-- lifted from Bars.lua by its source text (the rest of Bars.lua needs half the
-- client to load).
-- ============================================================

local saved = {}
local function stub(name, value) saved[name] = _G[name]; _G[name] = value end
local function restore() for k, v in pairs(saved) do _G[k] = v end; saved = {} end

-- ---- fakes ---------------------------------------------------------------
local function Region(name)
    local r = { name = name, points = {}, clears = 0 }
    function r:ClearAllPoints() self.points = {}; self.clears = self.clears + 1 end
    function r:SetPoint(p, rel, relP, x, y)
        if type(rel) ~= "table" then rel, relP, x, y = "parent", p, rel, relP end
        self.points[p] = { rel = rel, relPoint = relP, x = x or 0, y = y or 0 }
    end
    function r:SetBlendMode() end
    return r
end

local function Bar(name)
    local b = Region(name)
    b.fill = Region(name .. ".fill")
    b.shown = false
    function b:GetStatusBarTexture() return self.fill end
    function b:SetMinMaxValues() end
    function b:SetValue(v) self.value = v end
    function b:SetReverseFill() end
    function b:SetOrientation() end
    function b:SetStatusBarColor() end
    function b:SetFrameLevel() end
    function b:GetFrameLevel() return 3 end
    function b:Show() self.shown = true end
    function b:Hide() self.shown = false end
    function b:SetShown(v) self.shown = v and true or false end
    function b:IsShown() return self.shown end
    return b
end

-- hooksecurefunc on an instance: post-hook the method stored on the table.
stub("hooksecurefunc", function(t, method, post)
    local orig = t[method]
    t[method] = function(...) local r = orig(...); post(...); return r end
end)
local timers = {}
stub("C_Timer", { After = function(_, fn) timers[#timers + 1] = fn end })
local function flushTimers() local q = timers; timers = {}; for _, fn in ipairs(q) do fn() end end
stub("CreateFrame", function()
    local f = Bar("created")
    function f:RegisterEvent() end
    function f:SetScript() end
    return f
end)
stub("issecretvalue", function() return false end)

local function baseDB(over)
    local db = {
        framePadding = 0, frameWidth = 120, frameHeight = 50, pixelPerfect = false,
        resourceBarEnabled = true, resourceBarMatchWidth = true, resourceBarShrinkHealth = true,
        resourceBarAnchor = "BOTTOM", resourceBarOrientation = "HORIZONTAL",
        resourceBarHeight = 4, resourceBarX = 0, resourceBarY = 1,
        reducedMaxHealthEnabled = false, reducedMaxHealthClipHealthBar = true,
        reducedMaxHealthColor = { r = 0.5, g = 0.5, b = 0.5, a = 0.8 },
        healthOrientation = "HORIZONTAL",
    }
    for k, v in pairs(over or {}) do db[k] = v end
    return db
end

local currentDB = baseDB()
local absorbCalls, testRefreshCalls = {}, {}
local DF = {
    GetFrameDB = function(_, frame) return (frame and frame.db) or currentDB end,
    IsResourceBarDetached = function(_, frame, db)
        return (frame and frame.dfStandalone and db and db.resourceBarDetached) and true or false
    end,
    SafeSetStatusBarTexture = function() return true end,
    ApplyBarFillOrientation = function() end,
    BarTextureLayersWanted = function() return false end,
    DebugWarn = function() end,
    DebugActive = function() return false end,
    UpdateAbsorb = function(_, f) absorbCalls[#absorbCalls + 1] = f end,
    UpdateTestFrameHealthOnly = function(_, f, i) testRefreshCalls[#testRefreshCalls + 1] = i end,
}
load_df_file_into("Frames/HealthRect.lua", DF)
load_df_file_into("Frames/ReducedMaxHealth.lua", DF)

-- The watch, lifted from Bars.lua: the local handler through WatchPowerBarForHealthRect.
local src = df_file_source("Frames/Bars.lua")
local a = src:find("local function PowerBarVisibilityChanged(bar)", 1, true)
local w = a and src:find("function DF:WatchPowerBarForHealthRect(frame)", a, true)
local e = w and src:find("\nend\r?\n", w)
check(a and w and e, "setup: lifted the power bar watch from Bars.lua")
assert(loadstring("local DF = ...\n" .. src:sub(a, e + 4), "@watch"))(DF)

local function Frame(name, db, opts)
    local f = { name = name, db = db, healthBar = Bar(name .. ".health"),
                missingHealthBar = Bar(name .. ".missing"), dfPowerBar = Bar(name .. ".power"), unit = "party1" }
    for k, v in pairs(opts or {}) do f[k] = v end
    f.IsShown = function() return true end
    return f
end

local function insets(frame, db) return { DF:GetHealthBarInsets(frame, db) } end
local function same(t, l, r, tp, b, msg)
    eq(table.concat(t, ","), table.concat({ l, r, tp, b }, ","), msg)
end

-- ============================================================
print("-- The rect: anchors, orientation, offsets")
-- ============================================================
do
    local f = Frame("r", nil)
    f.dfPowerBar:Show()
    local db = baseDB()
    same(insets(f, db), 0, 0, 0, 5, "bottom bar, thickness 4 nudged up 1: the health bar stops 5 from the bottom")
    db = baseDB({ framePadding = 2, resourceBarY = 6 })
    same(insets(f, db), 2, 2, 2, 10, "pushed further in: no gap -- the stop moves with the bar's inner edge")
    db = baseDB({ resourceBarAnchor = "TOP", resourceBarY = -2 })
    same(insets(f, db), 0, 0, 6, 0, "top bar pushed DOWN 2 (negative Y is inward at the top)")
    db = baseDB({ resourceBarAnchor = "TOP", resourceBarY = 2 })
    same(insets(f, db), 0, 0, 2, 0, "top bar pushed UP 2, half out of the frame: only the part inside is skipped")
    db = baseDB({ resourceBarOrientation = "VERTICAL", resourceBarAnchor = "LEFT", resourceBarX = 3 })
    same(insets(f, db), 7, 0, 0, 0, "vertical bar on the left, pushed right 3")
    db = baseDB({ resourceBarOrientation = "VERTICAL", resourceBarAnchor = "RIGHT", resourceBarX = -3 })
    same(insets(f, db), 0, 7, 0, 0, "vertical bar on the right, pushed left 3")
    db = baseDB({ framePadding = 3, resourceBarY = -10 })
    same(insets(f, db), 3, 3, 3, 3, "bar pushed right out of the frame: the padding wins, never less")
    db = baseDB({ resourceBarY = 200 })
    same(insets(f, db), 0, 0, 0, 49, "absurd offset: the health bar keeps 1 unit, it never collapses")
end

-- ============================================================
print("-- The rect: layouts where it does nothing")
-- ============================================================
do
    local f = Frame("n", nil)
    f.dfPowerBar:Show()
    local cases = {
        { "option off", { resourceBarShrinkHealth = false } },
        { "centre anchor", { resourceBarAnchor = "CENTER" } },
        { "corner anchor", { resourceBarAnchor = "BOTTOMLEFT" } },
        { "horizontal bar on a side edge", { resourceBarAnchor = "LEFT" } },
        { "vertical bar on the bottom edge", { resourceBarOrientation = "VERTICAL" } },
        { "Match Width off", { resourceBarMatchWidth = false } },
    }
    for _, c in ipairs(cases) do
        same(insets(f, baseDB(c[2])), 0, 0, 0, 0, c[1] .. ": plain padding rect")
    end
    -- Unit frames (standalone frames, reading frame.dfDB) shrink like a group frame;
    -- a DETACHED bar (unit frames only) hangs outside the frame and owns no edge.
    local sa = Frame("sa", nil, { dfStandalone = true })
    sa.dfPowerBar:Show()
    same(insets(sa, baseDB()), 0, 0, 0, 5, "standalone (unit frames) frame: shrinks like a group frame")
    same(insets(sa, baseDB({ resourceBarDetached = true })), 0, 0, 0, 0, "standalone, detached bar: never shrinks")
    sa.dfPowerBar:Hide()
    same(insets(sa, baseDB()), 0, 0, 0, 0, "standalone, bar hidden: full rect")
    local grp = Frame("grp", nil); grp.dfPowerBar:Show()
    same(insets(grp, baseDB({ resourceBarDetached = true })), 0, 0, 0, 5,
        "a group frame ignores a stray resourceBarDetached (detach is standalone only)")
    eq(DF:CanShrinkHealthForPowerBar(baseDB({ resourceBarDetached = true })), false,
        "settings gate: a detached unit-frame bar greys the checkbox")
    local nobar = Frame("nb", nil); nobar.dfPowerBar = nil
    same(insets(nobar, baseDB()), 0, 0, 0, 0, "frame with no power bar: plain rect")

    eq(DF:CanShrinkHealthForPowerBar(baseDB()), true, "settings gate: default edge layout can shrink")
    eq(DF:CanShrinkHealthForPowerBar(baseDB({ resourceBarAnchor = "CENTER" })), false, "settings gate: centre greys it")
    eq(DF:CanShrinkHealthForPowerBar(baseDB({ resourceBarMatchWidth = false })), false, "settings gate: Match off greys it")
    eq(DF:CanShrinkHealthForPowerBar(baseDB({ resourceBarEnabled = false })), false, "settings gate: bar off greys it")
    eq(DF:CanShrinkHealthForPowerBar(baseDB({ resourceBarOrientation = "VERTICAL", resourceBarAnchor = "RIGHT" })), true,
        "settings gate: vertical bar on the right can shrink")
end

-- ============================================================
print("-- The rect: pixel perfect")
-- ============================================================
do
    local scale = 0.64
    DF.PixelPerfect = function(_, v) return math.floor(v / scale + 0.5) * scale end
    local f = Frame("pp", nil)
    f.dfPowerBar:Show()
    local t = insets(f, baseDB({ pixelPerfect = true, resourceBarHeight = 4, resourceBarY = 1 }))
    local b = t[4]
    -- thickness snaps (as Bars.lua's ppThickness does); the offset stays raw, as the
    -- bar's anchor offset does, so the two edges are the same number
    local expect = DF:PixelPerfect(4) + 1
    check(math.abs(b - expect) < 1e-9, "pixel perfect: thickness snapped like the bar's, offset raw like the bar's")
    t = insets(f, baseDB({ pixelPerfect = false, resourceBarHeight = 4, resourceBarY = 1 }))
    eq(t[4], 5, "pixel perfect off: raw numbers, no snapping")
    DF.PixelPerfect = nil
end

-- ============================================================
print("-- Per frame: the power bar's show / hide moves only that frame")
-- ============================================================
do
    currentDB = baseDB()
    local healer = Frame("healer", currentDB)
    local dps = Frame("dps", currentDB)
    for _, f in ipairs({ healer, dps }) do
        DF:WatchPowerBarForHealthRect(f)
        DF:AnchorHealthBarsToPadding(f, currentDB)
    end
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 0, "start: no bar shown, full health bar")

    healer.dfPowerBar:Show()                       -- role filter lets the healer's bar in
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 5, "healer's bar shows: its health bar stops at the bar")
    eq(healer.missingHealthBar.points.BOTTOMRIGHT.y, 5, "...and the missing-health overlay follows it")
    eq(dps.healthBar.points.BOTTOMRIGHT.y, 0, "the DPS frame (bar filtered out) keeps its full health bar")

    local before = healer.healthBar.clears
    healer.dfPowerBar:Show()                       -- a redundant show (every full update does one)
    healer.dfPowerBar:SetShown(true)
    eq(healer.healthBar.clears, before, "redundant show: nothing re-anchors")

    healer.dfPowerBar:Hide()                       -- role change / roster change / solo off
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 0, "bar hides: back to full size")
    healer.dfPowerBar:SetShown(true)
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 5, "SetShown(true): shrinks again")

    -- the measured bars catch up one frame later, live and test alike
    absorbCalls = {}
    flushTimers()
    eq(#absorbCalls, 1, "deferred: the live frame's absorbs re-measure next frame")
    check(healer.dfAbsorbState == nil, "deferred: the absorb layout cache is dropped")

    local tf = Frame("test", currentDB, { dfIsTestFrame = true, dfTestIndex = 3 })
    DF:WatchPowerBarForHealthRect(tf)
    DF:AnchorHealthBarsToPadding(tf, currentDB)
    testRefreshCalls = {}
    tf.dfPowerBar:Show()
    eq(tf.healthBar.points.BOTTOMRIGHT.y, 5, "test mode: the preview frame shrinks too")
    flushTimers()
    eq(testRefreshCalls[1], 3, "test mode: the preview's health/absorb pass re-runs for its slot")

    -- a settings change with the bar already shown: the layout pass re-reads it
    currentDB.resourceBarAnchor = "CENTER"
    DF:SyncHealthBarRect(healer, currentDB)
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 0, "anchor moved to centre: the health bar returns to full size")
    currentDB.resourceBarAnchor = "BOTTOM"
    currentDB.resourceBarShrinkHealth = false
    DF:SyncHealthBarRect(healer, currentDB)
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 0, "option off: full size even with the bar shown")
    currentDB.resourceBarShrinkHealth = true

    -- Unit frames: the same watch, the same per-frame rect.
    local sa = Frame("sa", currentDB, { dfStandalone = true, unit = "player" })
    DF:AnchorHealthBarsToPadding(sa, currentDB)
    DF:WatchPowerBarForHealthRect(sa)
    eq(sa.dfPowerBar.dfHealthRectWatched, true, "standalone frame: its bar is watched too")
    sa.dfPowerBar:Show()
    eq(sa.healthBar.points.BOTTOMRIGHT.y, 5, "standalone: bar shown -> the health bar stops at it")
    sa.dfPowerBar:Hide()
    eq(sa.healthBar.points.BOTTOMRIGHT.y, 0, "standalone: bar hidden -> full size again")
    currentDB.resourceBarDetached = true
    sa.dfPowerBar:Show()
    eq(sa.healthBar.points.BOTTOMRIGHT.y, 0, "standalone: a detached bar never shrinks it")
    currentDB.resourceBarDetached = nil
    sa.dfPowerBar:Hide()
    flushTimers()

    -- A unit frames preview (a test frame with no dfTestIndex) repaints with its own index.
    testRefreshCalls = {}
    local pv = Frame("pv", currentDB, { dfStandalone = true, dfIsTestFrame = true, dfUFPreview = true, index = 7 })
    DF:AnchorHealthBarsToPadding(pv, currentDB)
    DF:WatchPowerBarForHealthRect(pv)
    pv.dfPowerBar:Show()
    flushTimers()
    eq(testRefreshCalls[1], 7, "unit frames preview: the deferred refresh repaints it with f.index")
    pv.dfPowerBar:Hide()
    flushTimers()
end

-- ============================================================
print("-- Reduced Max Health nests inside the shrunk rect")
-- ============================================================
do
    currentDB = baseDB({ reducedMaxHealthEnabled = true })
    local f = Frame("rmh", currentDB, { dfIsTestFrame = true, dfTestReducedMaxPct = 0.25, dfTestIndex = 1 })
    DF:CreateReducedMaxHealthBar(f, currentDB)
    DF:WatchPowerBarForHealthRect(f)
    DF:AnchorHealthBarsToPadding(f, currentDB)
    local rmh = f.dfReducedMaxHealthBar

    f.dfPowerBar:Show()
    DF:UpdateReducedMaxHealth(f)
    local hp = f.healthBar.points
    eq(rmh.points.BOTTOMRIGHT.y, 5, "the reduced strip spans the SHRUNK health rect, above the power bar")
    eq(hp.BOTTOMLEFT.y, 5, "clipped health bar: frame-side bottom edge stops at the power bar")
    check(hp.TOPRIGHT.rel == rmh.fill and hp.BOTTOMRIGHT.rel == rmh.fill,
        "clipped health bar: full-health edge still on the reduced band")

    -- the power bar hides while clipped: re-clip inside the FULL rect, not left stale
    f.dfPowerBar:Hide()
    hp = f.healthBar.points
    eq(rmh.points.BOTTOMRIGHT.y, 0, "bar hides: the strip grows back to the full rect")
    eq(hp.BOTTOMLEFT.y, 0, "bar hides: clipped health bar's bottom back to the padding")
    check(hp.TOPRIGHT.rel == rmh.fill, "bar hides: still clipped to the reduced band")

    -- and the per-tick path still skips when nothing moved
    local clears = f.healthBar.clears
    DF:UpdateReducedMaxHealth(f)
    eq(f.healthBar.clears, clears, "health tick with nothing moved: not re-anchored")

    -- shows again: re-clips in the shrunk rect
    f.dfPowerBar:Show()
    eq(f.healthBar.points.BOTTOMLEFT.y, 5, "bar shows again: re-clipped inside the shrunk rect")
    flushTimers()
end

-- ============================================================
print("-- One health rect: no anchor site restates it")
-- ============================================================
do
    local create = df_file_source("Frames/Create.lua")
    check(not create:find("healthBar:SetPoint", 1, true), "Create.lua: health bar anchored only via the shared function")
    check(not create:find("missingHealthBar:SetPoint", 1, true), "Create.lua: missing-health bar too")
    local _, n = create:gsub("DF:AnchorHealthBarsToPadding%(frame, db%)", "")
    eq(n, 2, "Create.lua: both creation paths call the shared function")
    local _, w = create:gsub("DF:WatchPowerBarForHealthRect%(frame%)", "")
    eq(w, 2, "Create.lua: both power bars are watched from birth")
    local update = df_file_source("Frames/Update.lua")
    check(not update:find("function DF:AnchorHealthBarsToPadding", 1, true), "Update.lua: no second copy of the rect")
    local rmhSrc = df_file_source("Frames/ReducedMaxHealth.lua")
    check(not rmhSrc:find("framePadding", rmhSrc:find("function DF:RestoreHealthBarFromReducedMax", 1, true), true),
        "ReducedMaxHealth.lua: after creation it never re-derives the rect from framePadding")
    local bars = df_file_source("Frames/Bars.lua")
    local lay = bars:find("function DF:LayoutResourceBar(frame, db)", 1, true)
    local layEnd = bars:find("\nfunction DF:ApplyResourceBarLayout", lay, true)
    check(bars:sub(lay, layEnd):find("DF:SyncHealthBarRect(frame, db)", 1, true),
        "Bars.lua: a power bar re-layout (slider drag) re-syncs the health rect")
end

restore()
