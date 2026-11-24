local NS = ...

-- ============================================================
-- THE PAGE LIST'S IN-PLACE FILTER -- DandersFrames_Options/Features/SearchFilter.lua
-- ------------------------------------------------------------
-- Drives the REAL Search.lua + SearchSynonyms.lua + SearchMatch.lua +
-- SearchFilter.lua against a fake window: pages are plain tables shaped like the
-- real ones (children, cards with sectionChildren, boxes with groupChildren, a
-- searchEntry on every setting control), the page list is a stub that lays rows
-- out the way GUI:UpdateTabLayout does, and the page pass is GUI.FilterPagePass.
-- ☠ ONE LUA RUNTIME FOR EVERY SUITE: globals swapped here are restored at the end.
-- ============================================================

local savedDF, savedTimer, savedLocale, savedCombat, savedCF = DandersFrames, C_Timer, GetLocale, InCombatLockdown, CreateFrame
CreateFrame = function() return { RegisterEvent = function() end, UnregisterEvent = function() end, SetScript = function() end } end

local timers = {}
C_Timer = {
    After = function(_, fn) timers[#timers + 1] = fn end,
    NewTimer = function(_, fn) local t = { fn = fn, Cancel = function(self) self.dead = true end }; timers[#timers + 1] = function() if not t.dead then fn() end end; return t end,
}
local function RunTimers()
    local n = 0
    while #timers > 0 and n < 50 do
        local batch = timers; timers = {}
        for _, fn in ipairs(batch) do fn() end
        n = n + 1
    end
end
local inCombat = false
InCombatLockdown = function() return inCombat end
GetLocale = function() return "enUS" end

-- ---- the fake window ---------------------------------------------------
local DF, GUI, S
local linkCalls, selected

local function NewWindow()
    DF = {}
    DF.L = setmetatable({}, { __index = function(_, k) return k end })
    DF.PartyDefaults = setmetatable({}, { __index = function() return 0 end })
    DF.RaidDefaults = DF.PartyDefaults
    function DF:DebugWarn() end
    DF.db = { party = {} }
    linkCalls, selected = 0, {}
    GUI = {
        SelectedMode = "party", CurrentPageName = nil, Pages = {}, Tabs = {},
        SettingsBox = { pad = 10, group = 280, colMargin = 15, minCol = 290, colGutter = 20 },
    }
    function GUI:LinkToSetting(target) linkCalls = linkCalls + 1 end
    function GUI:IsTabInView(btn) return btn.inView end
    function GUI:ParkPage() end
    function GUI:AdoptPage() end
    GUI.SelectTab = function(name) GUI.CurrentPageName = name; selected[#selected + 1] = name end
    -- The page list: the same order of asks as the real UpdateTabLayout.
    function GUI:UpdateTabLayout()
        local navFilter = GUI.FilterNavHides and GUI.FilterNavPrepare and GUI.FilterNavPrepare()
            and GUI.FilterNavHides or nil
        local y = 0
        local names = {}
        for name in pairs(GUI.Tabs) do names[#names + 1] = name end
        table.sort(names, function(a, b) return GUI.Tabs[a].order < GUI.Tabs[b].order end)
        for _, name in ipairs(names) do
            local btn = GUI.Tabs[name]
            btn._shown = btn.inView and not (navFilter and navFilter(btn)) or false
            if btn._shown then btn._y = y; y = y - 28 end
        end
        if GUI.FilterNavDone then GUI.FilterNavDone(y) end
    end
    GUI.RelayoutCurrentPage = function()
        local page = GUI.CurrentPageName and GUI.Pages[GUI.CurrentPageName]
        if page then GUI.FilterPagePass(page, DF.db.party) end
    end
    -- The note's font string, recorded.
    GUI.contentFrame = { CreateFontString = function()
        local fs = { shown = false }
        function fs:SetPoint() end
        function fs:SetJustifyH() end
        function fs:SetWordWrap() end
        function fs:SetText(t) self.text = t end
        function fs:SetShown(v) self.shown = v and true or false end
        GUI._note = fs
        return fs
    end }
    DF.GUI = GUI
    DandersFrames = DF
    load_options_file_into("Features/Search.lua", NS)
    load_options_file_into("Features/SearchSynonyms.lua", NS)
    load_options_file_into("Features/SearchMatch.lua", NS)
    load_options_file_into("Features/SearchFilter.lua", NS)
    DandersFrames = savedDF
    S = DF.Search
    -- Every page registers into its own capture; the index is assembled from them.
    S.RegistryBuilt = true
    S.BuiltForMode = "party"
end

local order = 0
local function Page(name, label, opts)
    order = order + 1
    local page = { tabName = name, tabLabel = label, children = {}, _entries = {}, deferIndex = opts and opts.defer }
    function page:IsShown() return GUI.CurrentPageName == name end
    function page:Hide() end
    function page:GetIndexEntries() return self._entries end
    page.layouts = 0
    function page:RefreshStates() self.layouts = self.layouts + 1; GUI.FilterPagePass(self, DF.db.party) end
    GUI.Pages[name] = page
    local btn = { tabName = name, inView = not (opts and opts.outOfView), order = order }
    function btn:IsShown() return self._shown end
    function btn:GetPoint() return "TOPLEFT", nil, "TOPLEFT", 0, self._y or 0 end
    GUI.Tabs[name] = btn
    S:SetCurrentTab(name, label)
    return page
end

-- A setting control: registered the way a factory registers it.
local function Control(page, label, dbKey, extra)
    S._captureEntries = page._entries
    local w = { label = label }
    w.searchEntry = S:Register({ label = label, dbKey = dbKey })
    w.searchEntry.sourceWidget = w
    S._captureEntries = nil
    for k, v in pairs(extra or {}) do w[k] = v end
    return w
end

-- A card: its header on the page, then a box (the card's body) holding rows.
local function Card(page, title, rows, opts)
    local section = {
        sectionTitleText = title, sectionChildren = {}, expanded = not (opts and opts.shut),
        layoutCol = opts and opts.col,
    }
    function section:ShowFold() self.folds = (self.folds or 0) + 1 end
    page.children[#page.children + 1] = section
    S:SetCurrentSection(title)
    local box = { isSettingsGroup = true, groupChildren = {}, collapsibleSection = section, layoutCol = opts and opts.col }
    function box:SetChildFiltered(w, on)
        for _, e in ipairs(self.groupChildren) do if e.widget == w then e.filterHidden = on and true or nil end end
    end
    function box:ClearChildFilter() for _, e in ipairs(self.groupChildren) do e.filterHidden = nil end end
    for _, r in ipairs(rows) do
        local w = r.header and { isSectionHeader = true } or Control(page, r[1], r[2], r.extra)
        w.settingsGroup = box
        box.groupChildren[#box.groupChildren + 1] = { widget = w }
    end
    page.children[#page.children + 1] = box
    section.sectionChildren[1] = box
    return section, box
end

local function RowFiltered(box, label)
    for _, e in ipairs(box.groupChildren) do
        if e.widget.label == label or (label == "<header>" and e.widget.isSectionHeader) then
            return e.filterHidden == true
        end
    end
    error("no row " .. label)
end

local function Type(text)
    S:SetFilterText(text)
    RunTimers()
end

-- ============================================================
-- THE FIXTURE
-- ============================================================
NewWindow()
local framePage = Page("general_frame", "Frame")
local appearance, appBox = Card(framePage, "Appearance", {
    { "Global Frame Fade", "frameFadeAlpha" },
    { "Show Border", "frameShowBorder" },
}, { shut = true })
local layout, layoutBox = Card(framePage, "Layout", { { "Width", "frameWidth" } })
local footer = { isPageFooter = true }
framePage.children[#framePage.children + 1] = footer

local fadingPage = Page("display_fading", "Fading")
local range, rangeBox = Card(fadingPage, "Range", {
    { "Frame Alpha (Out of Range)", "rangeFadeAlpha" },
    { "Range Check Spell", "rangeCheckSpellID" },
})

local buffPage = Page("auras_buffs", "Buff Bar")
local buffContent, buffBox = Card(buffPage, "Content", { { "Show Buffs", "showBuffs" } })

local hiddenPage = Page("bars_absorb", "Absorbs")
local absorbCard, absorbBox = Card(hiddenPage, "Overshield", {
    { "Overshield Alpha", "absorbBarOvershieldAlpha", extra = { hideOn = function() return true end } },
})

local designer = Page("auras_designer", "Aura Designer")
local island = { layoutFill = true }
designer.children[1] = island

local unitPage = Page("uf_player_health", "Player Health", { defer = true })
Card(unitPage, "Colors", { { "Health Bar Alpha", "healthBarAlpha" } })
local otherUnit = Page("uf_target_health", "Target Health", { defer = true, outOfView = true })
Card(otherUnit, "Colors", { { "Health Bar Alpha", "healthBarAlpha" } })

GUI.CurrentPageName = "general_frame"

-- ============================================================
-- 1. A QUERY NARROWS THE LIST AND THE PAGE
-- ============================================================
print("-- Filter: a query narrows the page list")
Type("transparency")
check(S:FilterActive(), "filter: active once the debounce fires")
check(GUI.Tabs.general_frame._shown and GUI.Tabs.display_fading._shown, "nav: pages with a match stay")
check(not GUI.Tabs.auras_buffs._shown, "nav: a page with no match leaves the list")
check(GUI.Tabs.uf_player_health._shown, "nav: the view's deferred page was indexed and matched")
check(S.scopedPages and S.scopedPages.uf_player_health and not S.scopedPages.uf_target_health,
      "scope: only the view's deferred pages joined the index")
check(not GUI.Tabs.bars_absorb._shown, "nav: a match its 'only shown when' hides does not keep a page")

print("-- Filter: the page shows only what matches")
check(not RowFiltered(appBox, "Global Frame Fade"), "page: the matching row stays")
check(RowFiltered(appBox, "Show Border"), "page: the other row in the same box goes")
check(appearance.expanded and appearance.dfFilterOpened, "page: a shut card holding a match is opened")
check(rawget(layout, "dfFilterHidden") and rawget(layoutBox, "dfFilterHidden"), "page: a card with no match goes, box and all")
check(rawget(footer, "dfFilterHidden"), "page: the See Also footer goes while filtering")

-- ============================================================
-- 2. CLEARING PUTS EVERYTHING BACK
-- ============================================================
print("-- Filter: clearing restores every page exactly")
GUI.CurrentPageName = "display_fading"
GUI.RelayoutCurrentPage()
check(rawget(fadingPage, "_dfFiltered"), "setup: the second page was filtered too")
Type("")
check(not S:FilterActive(), "clear: the filter is off")
check(not RowFiltered(appBox, "Show Border") and not RowFiltered(rangeBox, "Range Check Spell"),
      "clear: every row on every filtered page is back, the page off screen too")
check(not appearance.expanded and not appearance.dfFilterOpened, "clear: the card it opened is shut again")
check(rawget(layout, "dfFilterHidden") == nil and rawget(footer, "dfFilterHidden") == nil, "clear: page widgets are back")
for name, btn in pairs(GUI.Tabs) do
    check(btn._shown == (btn.inView and true or false), "clear: nav row back: " .. name)
end

-- ============================================================
-- 3. RULES
-- ============================================================
print("-- Filter: a page whose name matches is shown whole")
GUI.CurrentPageName = "auras_buffs"
Type("buff bar")
check(GUI.Tabs.auras_buffs._shown, "whole: the page is listed")
GUI.RelayoutCurrentPage()
check(not rawget(buffPage, "_dfFiltered"), "whole: ...and nothing on it is filtered")

print("-- Filter: a card whose title matches keeps everything in it")
GUI.CurrentPageName = "display_fading"
Type("range")
check(not RowFiltered(rangeBox, "Range Check Spell") and not RowFiltered(rangeBox, "Frame Alpha (Out of Range)"),
      "card: both rows of the Range card stay")

print("-- Filter: designers are never narrowed from inside")
GUI.CurrentPageName = "auras_designer"
Type("alpha")
GUI.RelayoutCurrentPage()
check(not rawget(island, "dfFilterHidden") and not rawget(designer, "_dfFiltered"), "designer: the island is left alone")

print("-- Filter: a card the user moves while filtering is theirs")
Type("")
GUI.CurrentPageName = "general_frame"
Type("transparency")
check(appearance.dfFilterOpened, "user: setup -- the filter opened the card")
-- What SetExpanded does when the user presses a card the filter opened.
appearance.dfFilterOpened, appearance.dfFilterUser, appearance.expanded = nil, true, false
GUI.RelayoutCurrentPage()
check(not appearance.expanded, "user: the filter does not open it again")
Type("")
check(not appearance.expanded and appearance.dfFilterUser == nil, "user: clearing leaves the user's fold and forgets the hand-over")
local SW = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")
check(SW:find("if self.dfFilterOpened then\n            self.dfFilterOpened = nil\n            self.dfFilterUser = true", 1, true) ~= nil,
      "user: SetExpanded hands a filter-opened card to the user")

print("-- Filter: nothing matching anywhere")
Type("zzzqqqxx")
check(S:FilterActive(), "empty: still filtering")
local any = false
for _, btn in pairs(GUI.Tabs) do if btn._shown then any = true end end
check(not any, "empty: every row leaves the list")
GUI.RelayoutCurrentPage()
check(not rawget(framePage, "_dfFiltered"), "empty: the page on screen is left whole rather than blank")

print("-- Filter: typing never switches the page; Enter goes to one that matches")
Type("")
GUI.CurrentPageName = "auras_buffs"
selected = {}
Type("transparency")
eq(#selected, 0, "move: typing leaves the page on screen alone")
check(GUI._note and GUI._note.shown, "move: ...and says nothing on it matches")
S:FilterJump()
check(#selected == 1 and selected[1] == "general_frame", "move: Enter selects the first listed page with a match (" .. tostring(selected[1]) .. ")")
GUI.RelayoutCurrentPage()
S:RefreshFilter(false)
check(not GUI._note.shown, "move: the note goes once the page has a match")

print("-- Filter: a keystroke costs one compute and at most one layout")
Type("")
GUI.CurrentPageName = "general_frame"
local matchCalls = 0
local realMatch = S.MatchEntries
S.MatchEntries = function(...) matchCalls = matchCalls + 1; return realMatch(...) end
framePage.layouts = 0
Type("transparenc")
eq(matchCalls, 1, "cost: one match for the keystroke")
eq(framePage.layouts, 1, "cost: one layout of the page on screen")
GUI:UpdateTabLayout(); GUI:UpdateTabLayout()
eq(matchCalls, 1, "cost: laying the list out again reuses the answer")
framePage.layouts = 0
Type("transparency")
eq(framePage.layouts, 0, "cost: a keystroke that changes nothing on the page lays nothing out")
S.MatchEntries = realMatch

print("-- Filter: a 'show me' link clears the filter first")
check(S:FilterActive(), "link: setup -- filtering")
GUI:LinkToSetting({ page = "auras_buffs" })
check(not S:FilterActive() and S.Filter.text == "", "link: the filter is cleared")
eq(linkCalls, 1, "link: ...and the link still runs")

print("-- Filter: never builds the index in combat")
NewWindow()
local p = Page("general_frame", "Frame")
Card(p, "Appearance", { { "Global Frame Fade", "frameFadeAlpha" } })
GUI.CurrentPageName = "general_frame"
S.RegistryBuilt = false   -- a build would be needed
p.GetIndexEntries = function() return nil end
local built = 0
p.Refresh = function() built = built + 1 end
inCombat = true
Type("fade")
check(not S:FilterActive() and built == 0, "combat: no build, no filter yet")
inCombat = false

print("-- Filter: the wiring in the shared files")
local P = options_file_source("GUI/Panel.lua"):gsub("\r\n", "\n")
check(P:find("if GUI.FilterPagePass then GUI.FilterPagePass(self, db) end", 1, true) ~= nil,
      "wiring: the page state pass runs the filter first")
local _, nHidden = P:gsub('rawget%(widget, "dfFilterHidden"%)', "")
eq(nHidden, 2, "wiring: both the box branch and the widget branch honour the filter mark")
check(P:find("not (navFilter and navFilter(btn))", 1, true) ~= nil, "wiring: the page list asks per row")
check(P:find("DF.Search:CreateFilterBar(tabFrame)", 1, true) ~= nil, "wiring: the page list's box is the filter bar")
local TOC = options_file_source("DandersFrames_Options.toc")
check(TOC:find("Features\\SearchMatch.lua", 1, true) < TOC:find("Features\\SearchFilter.lua", 1, true),
      "wiring: the filter loads after the matcher")

DandersFrames, C_Timer, GetLocale, InCombatLockdown, CreateFrame = savedDF, savedTimer, savedLocale, savedCombat, savedCF
