local NS = ...

-- ============================================================
-- SETTINGS SEARCH -- DandersFrames_Options/Features/Search.lua
-- ------------------------------------------------------------
-- Popout gate two moves a page's controls off the page and into a panel that
-- opens off a row. Search is built by RE-RUNNING every page's builder, so the
-- controls still register (the gate-two pages build their popout content
-- eagerly, into a hidden holder, precisely so that stays true) -- but two things
-- about a search HIT change, and both are pinned here:
--
--   1. REGISTRATION CONTEXT. An entry is stamped with whatever tab/section was
--      current when the factory ran, and is dropped outright for a key the
--      current mode has no default for. Popout content builds inside the same
--      section as the row, so the stamping has to be position-independent --
--      which it is, and this says so.
--   2. THE JUMP. "Show me" scrolls to a SECTION, not to a widget. For a control
--      that now lives inside a popout there is nothing of its own on the page to
--      land on, so NavigateToTab takes the setting's key and opens the row that
--      owns it -- read off `page._popoutRowForKey`, which any page may publish.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. This file
-- replaces the `DandersFrames` global (Search.lua takes its host off it, not off
-- the varargs) and adds a C_Timer. Both are restored at the end.
-- ============================================================

local savedDF, savedTimer = DandersFrames, C_Timer

-- ---- the WoW surface NavigateToTab touches -------------------------
-- Deferred rather than immediate: WHEN the row is opened is half of what is
-- under test (the map must be read after the jump, never captured before it),
-- so the queue is fired by hand.
local queued = {}
C_Timer = {
    After = function(delay, fn) queued[#queued + 1] = { delay = delay, fn = fn } end,
}
local function fireTimers()
    local due = queued
    queued = {}
    for _, t in ipairs(due) do t.fn() end
    return #due
end

-- ---- the host surface Search.lua reads -----------------------------
local DF = {}
DF.L = setmetatable({}, { __index = function(_, k) return k end })
DF.PartyDefaults = {
    frameShowBorder = true, frameBorderSize = 1, frameBorderShadowEnabled = false,
}
DF.RaidDefaults = {
    frameShowBorder = true, frameBorderSize = 1, frameBorderShadowEnabled = false,
    hideBlizzardRaidFrames = true,
}
function DF:DebugWarn() end
-- ⚠ SettingsBox mirrors UI.SettingsBox (DandersUI/Theme.lua). This file does not
-- load the kit, so it cannot read the real one -- test_page_parking DOES, and it
-- drives Search.lua against the genuine table, so drift is caught there rather
-- than here. These values only have to exist for Search.lua's file scope to load.
DF.GUI = {
    SelectedMode = "party",
    Pages = {},
    SettingsBox = { group = 280, pad = 10, colMargin = 5, minCol = 285, colGutter = 20 },
}
DandersFrames = DF

load_options_file_into("Features/Search.lua", NS)
local Search = DF.Search
check(Search ~= nil, "search: the file publishes DF.Search")

local function resetRegistry()
    Search.Registry = {}
    Search.RegistryBuilt = false
    Search:SetCurrentTab("general_frame", "Frame")
    Search:SetCurrentSection("Appearance")
end

-- ============================================================
-- 1. REGISTRATION CONTEXT
-- ============================================================
do
    resetRegistry()
    local e = Search:RegisterCheckbox("Show Border", "frameShowBorder", nil, false, nil)
    eq(e.tab, "general_frame", "register: the entry carries the current tab")
    eq(e.tabLabel, "Frame", "register: ...and its label, for the breadcrumb")
    eq(e.section, "Appearance", "register: ...and the section the last header set")
    eq(e.mode, "party", "register: ...and the mode it was built for")
    eq(e.widgetType, "checkbox", "register: a hoisted toggle registers as a checkbox")
    eq(e.dbKey, "frameShowBorder", "register: ...against the same db key the checkbox used")
    eq(#Search.Registry, 1, "register: and it reached the registry")

    -- The registration context is the LAST HEADER, not the widget's parent -- which
    -- is the whole reason a popout's content, built into a hidden holder, still
    -- lands in the right section.
    local slider = Search:RegisterSlider("Border Thickness", "frameBorderSize", 1, 16, 1, nil, nil)
    eq(slider.section, "Appearance", "register: popout content lands in the row's own section")
    eq(slider.minVal, 1, "register: a slider carries its range, so a result can recreate it")
    eq(slider.maxVal, 16, "register: ...both ends")
end

do
    resetRegistry()
    -- A key the current mode has no default for is dropped, not registered.
    local e = Search:RegisterSlider("Nonsense", "noSuchSettingAnywhere", 0, 1, 1, nil, nil)
    eq(e.id, nil, "register: a key absent from the mode's defaults is not stamped")
    eq(#Search.Registry, 0, "register: ...and never reaches the registry")

    -- ...and so is anything offered after the registry was sealed, which is what
    -- lets a search RESULT rebuild a real widget without re-registering itself.
    Search.RegistryBuilt = true
    local late = Search:RegisterCheckbox("Show Border", "frameShowBorder", nil, false, nil)
    eq(late.id, nil, "register: nothing registers once the registry is built")
    eq(#Search.Registry, 0, "register: ...the registry is unchanged")
    Search.RegistryBuilt = false
end

-- ============================================================
-- 2. THE JUMP
-- ============================================================
-- A fake page with one popout row, plus the LinkToSetting the navigate path
-- delegates its scroll-and-flash half to.
local function fakeRow(shown)
    local r = { opened = 0, _shown = shown ~= false }
    function r:OpenPopout() self.opened = self.opened + 1 end
    function r:IsShown() return self._shown end
    return r
end

local linked
local function newPage(map)
    return { _popoutRowForKey = map }
end
DF.GUI.LinkToSetting = function(_, target) linked = target end

local function navigate(key, map)
    linked = nil
    queued = {}
    DF.GUI.Pages = { general_frame = newPage(map) }
    Search:NavigateToTab("general_frame", "Appearance", key)
end

do
    local row = fakeRow()
    navigate("frameBorderSize", { frameBorderSize = row })
    eq(linked and linked.page, "general_frame", "jump: the section jump still runs")
    eq(linked and linked.section, "Appearance", "jump: ...at the entry's own section")
    eq(row.opened, 0, "jump: the row is not opened before the jump has settled")
    eq(fireTimers(), 1, "jump: exactly one deferred step is queued")
    eq(row.opened, 1, "jump: and it opens the row that owns the setting")
end

do
    -- A setting the page does not hand to a row: nothing to open, and the
    -- section jump alone is the whole behaviour (which is the classic layout).
    local row = fakeRow()
    navigate("frameWidth", { frameBorderSize = row })
    fireTimers()
    eq(row.opened, 0, "jump: an unmapped key opens nothing")

    navigate("frameBorderSize", nil)
    eq(fireTimers(), 1, "jump: a page with no map still queues the (harmless) lookup")

    navigate(nil, { frameBorderSize = fakeRow() })
    eq(#queued, 0, "jump: no key, no deferred step at all")
end

do
    -- A row hidden by its own predicate is not a place to dock a panel.
    local row = fakeRow(false)
    navigate("frameBorderSize", { frameBorderSize = row })
    fireTimers()
    eq(row.opened, 0, "jump: a hidden row is left closed")
end

do
    -- ☠ THE CONTRACT THAT MATTERS: the map is read AFTER the jump, never
    -- captured before it. Switching pages rebuilds the page, and a rebuild
    -- retires every row -- so the row opened has to be the one the map holds at
    -- firing time. Swapping the whole page between the call and the timer is the
    -- headless stand-in for that rebuild.
    local stale, rebuilt = fakeRow(), fakeRow()
    navigate("frameBorderSize", { frameBorderSize = stale })
    DF.GUI.Pages = { general_frame = newPage({ frameBorderSize = rebuilt }) }
    fireTimers()
    eq(stale.opened, 0, "jump: the row from before the jump is never opened")
    eq(rebuilt.opened, 1, "jump: the row the rebuilt page publishes is")
end

-- ---- restore the globals -------------------------------------------
DandersFrames = savedDF
C_Timer = savedTimer
