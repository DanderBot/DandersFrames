-- ============================================================
-- THE HEALTH RECT WITH A RESOURCE BAR PLACEMENT STRIP
-- Frames/HealthRect.lua is the ONE place that decides the health bar's rect. With a
-- Placement strip ACROSS the fill, the strip's side stops at the strip's inner edge
-- (a strip along the fill is cut out instead, test_health_bar_insets.lua) -- so this
-- file runs a VERTICAL bar, where Below / Above are across -- but only on a frame MEANT to carry a bar
-- (DF:NoteResourceBarWanted), never following the bar's momentary hides. A change
-- re-anchors once, re-clips reduced max health inside the new rect, and re-measures
-- the absorb / heal bars one frame later (a moved anchor does not resize until the
-- next draw). Reduced Max Health nests its strip inside the same rect.
--
-- Loaded REAL: HealthRect.lua and ReducedMaxHealth.lua. The source guards at the end
-- pin the shape: one rect, no Show/Hide watch.
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
        frameShowBorder = false,
        resourceBarEnabled = true, resourceBarMatchWidth = true, resourceBarPlacement = "BOTTOM",
        resourceBarAnchor = "CENTER", resourceBarOrientation = "HORIZONTAL",
        resourceBarHeight = 4, resourceBarX = 0, resourceBarY = 1,
        resourceBarStripX = 0, resourceBarStripY = 1,
        reducedMaxHealthEnabled = false, reducedMaxHealthClipHealthBar = true,
        reducedMaxHealthColor = { r = 0.5, g = 0.5, b = 0.5, a = 0.8 },
        healthOrientation = "VERTICAL",
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

local function Frame(name, db, opts)
    local f = { name = name, db = db, healthBar = Bar(name .. ".health"),
                missingHealthBar = Bar(name .. ".missing"), dfPowerBar = Bar(name .. ".power"), unit = "party1" }
    for k, v in pairs(opts or {}) do f[k] = v end
    f.IsShown = function() return true end
    return f
end

-- What every decision site does: record the answer, then let the rect follow.
local function decide(f, wanted)
    DF:NoteResourceBarWanted(f, wanted)
    DF:SyncHealthBarRect(f, f.db or currentDB)
end

-- ============================================================
print("-- Per frame: the WANTED answer moves only that frame")
-- ============================================================
do
    currentDB = baseDB()
    local healer = Frame("healer", currentDB)
    local dps = Frame("dps", currentDB)
    for _, f in ipairs({ healer, dps }) do DF:AnchorHealthBarsToPadding(f, currentDB) end
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 0, "start: never decided, full health bar")

    decide(healer, true)                          -- role filter lets the healer's bar in
    decide(dps, false)                            -- ...and keeps the DPS's out
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 5, "healer wants a bar: its health bar stops at the strip")
    eq(healer.missingHealthBar.points.BOTTOMRIGHT.y, 5, "...and the missing-health overlay follows it")
    eq(healer.dfHealthRectB, 5, "...and the rect is remembered")
    eq(dps.healthBar.points.BOTTOMRIGHT.y, 0, "the DPS frame (bar filtered out) keeps its full health bar")

    local before = healer.healthBar.clears
    decide(healer, true)                          -- every full update re-decides
    eq(healer.healthBar.clears, before, "same answer again: nothing re-anchors")

    -- ★ the bar hiding for a moment (death, disconnect, secret power) is NOT a decision
    healer.dfPowerBar:Hide()
    DF:SyncHealthBarRect(healer, currentDB)
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 5, "bar hidden but still wanted: the health bar does not jump")

    decide(healer, false)                         -- role change / roster change / solo off
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 0, "no longer wanted: back to full size")
    decide(healer, true)
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 5, "wanted again: shrinks again")

    -- the measured bars catch up one frame later, live and test alike
    absorbCalls = {}
    flushTimers()
    eq(#absorbCalls, 1, "deferred: the live frame's absorbs re-measure next frame")
    check(healer.dfAbsorbState == nil, "deferred: the absorb layout cache is dropped")

    local tf = Frame("test", currentDB, { dfIsTestFrame = true, dfTestIndex = 3 })
    DF:AnchorHealthBarsToPadding(tf, currentDB)
    testRefreshCalls = {}
    decide(tf, true)
    eq(tf.healthBar.points.BOTTOMRIGHT.y, 5, "test mode: the preview frame shrinks too")
    flushTimers()
    eq(testRefreshCalls[1], 3, "test mode: the preview's health/absorb pass re-runs for its slot")

    -- settings changes with the bar wanted: the layout pass re-reads them
    currentDB.resourceBarPlacement = "OVER"
    DF:SyncHealthBarRect(healer, currentDB)
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 0, "Placement back to On Top: full size")
    currentDB.resourceBarPlacement = "RIGHT"
    currentDB.resourceBarStripX = -2
    currentDB.healthOrientation = "HORIZONTAL"     -- right of a horizontal bar is across it
    DF:SyncHealthBarRect(healer, currentDB)
    eq(healer.healthBar.points.BOTTOMRIGHT.x, -6, "Right of Health Bar pushed in 2: the right side stops at 6")
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 0, "...and the bottom is full again")
    currentDB.resourceBarPlacement, currentDB.resourceBarStripX = "BOTTOM", 0
    currentDB.healthOrientation = "VERTICAL"
    DF:SyncHealthBarRect(healer, currentDB)
    flushTimers()

    -- Along the fill the rect stays whole; only where health is seen takes the strip.
    currentDB.healthOrientation = "HORIZONTAL"
    DF:SyncHealthBarRect(healer, currentDB)
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 0, "horizontal bar, below: full size (the strip is cut out)")
    eq(healer.dfHealthVisB, 5, "...and the seen rect stops at the strip")
    currentDB.healthOrientation = "VERTICAL"
    DF:SyncHealthBarRect(healer, currentDB)
    eq(healer.healthBar.points.BOTTOMRIGHT.y, 5, "Fill Direction back to vertical: below is across, shrinks")
    flushTimers()

    -- Unit frames: the same rect, per frame.
    local sa = Frame("sa", currentDB, { dfStandalone = true, unit = "player" })
    DF:AnchorHealthBarsToPadding(sa, currentDB)
    decide(sa, true)
    eq(sa.healthBar.points.BOTTOMRIGHT.y, 5, "standalone: wanted -> the health bar stops at the strip")
    decide(sa, false)
    eq(sa.healthBar.points.BOTTOMRIGHT.y, 0, "standalone: not wanted -> full size again")
    currentDB.resourceBarDetached = true
    decide(sa, true)
    eq(sa.healthBar.points.BOTTOMRIGHT.y, 0, "standalone: a detached bar never shrinks it")
    currentDB.resourceBarDetached = nil
    decide(sa, false)
    flushTimers()

    -- A unit frames preview (a test frame with no dfTestIndex) repaints with its own index.
    testRefreshCalls = {}
    local pv = Frame("pv", currentDB, { dfStandalone = true, dfIsTestFrame = true, dfUFPreview = true, index = 7 })
    DF:AnchorHealthBarsToPadding(pv, currentDB)
    decide(pv, true)
    flushTimers()
    eq(testRefreshCalls[1], 7, "unit frames preview: the deferred refresh repaints it with f.index")
    decide(pv, false)
    flushTimers()
end

-- ============================================================
print("-- Reduced Max Health nests inside the shrunk rect")
-- ============================================================
do
    currentDB = baseDB({ reducedMaxHealthEnabled = true })
    local f = Frame("rmh", currentDB, { dfIsTestFrame = true, dfTestReducedMaxPct = 0.25, dfTestIndex = 1 })
    DF:CreateReducedMaxHealthBar(f, currentDB)
    DF:AnchorHealthBarsToPadding(f, currentDB)
    local rmh = f.dfReducedMaxHealthBar

    decide(f, true)
    DF:UpdateReducedMaxHealth(f)
    local hp = f.healthBar.points
    eq(rmh.points.BOTTOMRIGHT.y, 5, "the reduced strip spans the SHRUNK health rect, above the resource strip")
    eq(hp.BOTTOMLEFT.y, 5, "clipped health bar: frame-side bottom edge stops at the strip")
    check(hp.TOPLEFT.rel == rmh.fill and hp.TOPRIGHT.rel == rmh.fill,
        "clipped health bar: full-health edge still on the reduced band")

    -- no longer wanted while clipped: re-clip inside the FULL rect, not left stale
    decide(f, false)
    hp = f.healthBar.points
    eq(rmh.points.BOTTOMRIGHT.y, 0, "not wanted: the reduced strip grows back to the full rect")
    eq(hp.BOTTOMLEFT.y, 0, "not wanted: clipped health bar's bottom back to the padding")
    check(hp.TOPRIGHT.rel == rmh.fill, "not wanted: still clipped to the reduced band")

    -- and the per-tick path still skips when nothing moved
    local clears = f.healthBar.clears
    DF:UpdateReducedMaxHealth(f)
    eq(f.healthBar.clears, clears, "health tick with nothing moved: not re-anchored")

    decide(f, true)
    eq(f.healthBar.points.BOTTOMLEFT.y, 5, "wanted again: re-clipped inside the shrunk rect")

    -- a strip on the reduced end (horizontal fill, reduced on the right, Right of Health Bar)
    currentDB.resourceBarPlacement = "RIGHT"
    currentDB.resourceBarStripX = 0
    currentDB.healthOrientation = "HORIZONTAL"
    DF:SyncHealthBarRect(f, currentDB)
    eq(rmh.points.BOTTOMRIGHT.x, -4, "Right of Health Bar: the reduced band ends at the strip, not under it")
    eq(f.healthBar.points.BOTTOMLEFT.y, 0, "...and the bottom is full")
    flushTimers()
end

-- ============================================================
print("-- One health rect: no anchor site restates it, no Show/Hide watch")
-- ============================================================
do
    local create = df_file_source("Frames/Create.lua")
    check(not create:find("healthBar:SetPoint", 1, true), "Create.lua: health bar anchored only via the shared function")
    check(not create:find("missingHealthBar:SetPoint", 1, true), "Create.lua: missing-health bar too")
    local _, n = create:gsub("DF:AnchorHealthBarsToPadding%(frame, db%)", "")
    eq(n, 2, "Create.lua: both creation paths call the shared function")
    local update = df_file_source("Frames/Update.lua")
    for _, sig in ipairs({ "function DF:AnchorHealthBarsToPadding", "function DF:GetHealthBarInsets",
                           "function DF:SyncHealthBarRect", "function DF:GetResourceBarRoomEdge",
                           "function DF:NoteResourceBarWanted" }) do
        check(not update:find(sig, 1, true), "Update.lua: no second copy -- " .. sig)
    end
    local rmhSrc = df_file_source("Frames/ReducedMaxHealth.lua")
    check(not rmhSrc:find("framePadding", 1, true), "ReducedMaxHealth.lua: never re-derives the rect from framePadding")
    check(not rmhSrc:find("local l, t, r, b", 1, true), "ReducedMaxHealth.lua: one return order (l, r, t, b)")
    local bars = df_file_source("Frames/Bars.lua")
    local lay = bars:find("function DF:LayoutResourceBar(frame, db)", 1, true)
    local layEnd = bars:find("\nfunction DF:ApplyResourceBarLayout", lay, true)
    check(bars:sub(lay, layEnd):find("DF:SyncHealthBarRect(frame, db)", 1, true),
        "Bars.lua: a resource bar re-layout (slider drag) re-syncs the health rect")
    check(not bars:find("hooksecurefunc(bar, \"Show\"", 1, true), "Bars.lua: no Show/Hide watch on the bar")
    for _, file in ipairs({ "Frames/Bars.lua", "Frames/TextureLayers.lua", "Frames/ReducedMaxHealth.lua",
                            "Frames/Update.lua", "Frames/HealthRect.lua", "Frames/Create.lua" }) do
        local src = df_file_source(file)
        for _, w in ipairs({ "WatchPowerBarForHealthRect", "resourceBarShrinkHealth" }) do
            check(not src:find(w, 1, true), file .. ": no " .. w)
        end
    end
    -- every decision site records the answer before the rect is read
    local _, nUpd = update:gsub("DF:NoteResourceBarWanted%(frame, showPower%)", "")
    eq(nUpd, 2, "Update.lua: the live update and UpdatePower both record the answer")
    local tm = options_file_source("TestMode/TestMode.lua")
    local note = tm:find("DF:NoteResourceBarWanted(frame, DF:TestResourceBarWanted(", 1, true)
    local anchor = note and tm:find("DF:AnchorHealthBarsToPadding(frame, db)", note, true)
    check(note and anchor, "TestMode.lua: the preview records the answer before placing the health bar")
    local dispel = df_file_source("Features/Dispel.lua")
    local _, nDis = dispel:gsub("DF:GetHealthVisibleInsets%(frame, db%)", "")
    eq(nDis, 2, "Dispel.lua: the wash and the edge strips sit on the seen health rect, not over the strip")
end

restore()
