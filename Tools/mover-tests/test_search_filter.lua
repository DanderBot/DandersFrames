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
    load_options_file_into("Features/SearchPrebuilt.lua", NS)
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
check(S.scopedPages == nil, "scope: the filter adds no page to the registry build")
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

local function Showing0(page)
    for _, w in ipairs(page.children) do
        if not rawget(w, "dfFilterHidden") and not w.isSectionHeader and not w.isPageFooter then
            if w.sectionChildren or w.searchEntry then return true end
            if w.groupChildren then
                for _, e in ipairs(w.groupChildren) do if not e.filterHidden then return true end end
            end
        end
    end
    return false
end
print("-- Filter: nothing matching anywhere")
Type("zzzqqqxx")
check(S:FilterActive(), "empty: still filtering")
local any = false
for _, btn in pairs(GUI.Tabs) do if btn._shown then any = true end end
check(not any, "empty: every row leaves the list")
GUI.RelayoutCurrentPage()
check(rawget(framePage, "_dfFiltered") and not Showing0(framePage) and GUI._note.shown,
      "empty: the page on screen shows the note and nothing under it")

print("-- Filter: typing never switches the page; an empty page says so and shows nothing")
Type("")
GUI.CurrentPageName = "auras_buffs"
selected = {}
Type("transparency")
eq(#selected, 0, "move: typing leaves the page on screen alone")
check(GUI._note and GUI._note.shown, "move: ...and says nothing on it matches")
eq(GUI._note.text, "Nothing on this page matches.", "move: the note is the short one (no Enter)")
check(rawget(buffContent, "dfFilterHidden") and rawget(buffBox, "dfFilterHidden"),
      "move: ...and nothing is left showing under it")
check(S.FilterJump == nil, "move: the dead Enter jump is gone")
GUI.CurrentPageName = "general_frame"
GUI.RelayoutCurrentPage()
check(not GUI._note.shown, "move: the note goes on a page with a match")

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

print("-- Filter: in combat it still answers, from what it has, building nothing")
NewWindow()
local p = Page("general_frame", "Frame")
Card(p, "Appearance", { { "Global Frame Fade", "frameFadeAlpha" } })
GUI.CurrentPageName = "general_frame"
local built = 0
p.Refresh = function() built = built + 1 end
p.RefreshForIndex = p.Refresh
inCombat = true
Type("fade")
check(S:FilterActive() and built == 0, "combat: the filter answers and no page is built")
inCombat = false
Type("")

print("-- Filter: every page the list shows has something showing on it")
do
    NewWindow()
    local Never = function() return true end
    -- The group Frame page's shape: bare headers over cards, a card whose header
    -- tick is a registered setting that is NOT on the page, rows whose labels do
    -- not say what the card is called.
    local function FramePage(name, label, filtered)
        local fp = Page(name, label)
        local function capture(fn) S._captureEntries = fp._entries; fn(); S._captureEntries = nil end
        local h1 = { isSectionHeader = true, layoutCol = 1 }
        capture(function() S:SetCurrentSection("Layout", h1) end)
        fp.children[#fp.children + 1] = h1
        Card(fp, "Frame Size", { { "Width", "frameWidth" } }, { col = 1 })
        local h2 = { isSectionHeader = true, layoutCol = 1, GetText = function() return "Movement" end }
        capture(function() S:SetCurrentSection("Movement", h2) end)
        fp.children[#fp.children + 1] = h2
        local mover, moverBox
        capture(function()
            mover, moverBox = Card(fp, "Permanent Mover", {
                { "Handle Position", "permanentMoverAnchor" },
                { "Show on Hover Only", "permanentMoverShowOnHover" },
            }, { col = 1, shut = true })
            S:SetCurrentSection("Permanent Mover", mover)
            mover.headerToggle = Control(fp, "Enable Permanent Mover", "permanentMover")
        end)
        if filtered then
            -- A card filtered off this page (a unit frame's): it never shows, and
            -- its header still registered -- what the old OpenSection did.
            mover.hideOn, moverBox.hideOn, h2.hideOn = Never, Never, Never
        end
        Card(fp, "Border", { { "Show Border", "frameShowBorder" } }, { col = 2 })
        return fp, mover, moverBox, h2
    end
    local gp, gMover, gBox, gHead = FramePage("general_frame", "Frame")
    local up = FramePage("uf_player_frame", "Player Frame", true)
    Card(Page("display_fading", "Fading"), "Frame Fade", { { "Global Frame Fade", "frameFadeAlpha" } })
    Card(Page("bars_health", "Health Bar"), "Colors", { { "Bar Color", "healthColor" } })

    GUI.CurrentPageName = "general_frame"
    Type("move")
    check(GUI.Tabs.general_frame._shown, "move: the group Frame page is listed")
    check(not GUI.Tabs.uf_player_frame._shown, "move: a page whose only match is a card filtered off it is not")
    GUI.RelayoutCurrentPage()
    check(not rawget(gMover, "dfFilterHidden") and gMover.expanded, "move: the Permanent Mover card shows, opened")
    check(not rawget(gHead, "dfFilterHidden"), "move: ...under its Movement header")
    for _, e in ipairs(gBox.groupChildren) do
        check(not e.filterHidden, "move: a card matched by title shows whole: " .. e.widget.label)
    end
    Type("")
    Type("movement")
    GUI.RelayoutCurrentPage()
    check(GUI.Tabs.general_frame._shown and not rawget(gMover, "dfFilterHidden") and not rawget(gHead, "dfFilterHidden"),
          "header: a bare header whose title matches shows the cards under it")
    Type("")
    Type("enable permanent")
    check(GUI.Tabs.general_frame._shown and not rawget(gMover, "dfFilterHidden"),
          "tick: a match on the card's header tick keeps the card")

    -- What "showing" means for the invariant: a card, a box with a row left in it,
    -- or a control -- not a header, not the page's tools.
    local function Showing(page)
        for _, w in ipairs(page.children) do
            if not rawget(w, "dfFilterHidden") and not (w.hideOn and w.hideOn()) and not w.isSectionHeader then
                if w.sectionChildren then return true end
                if w.groupChildren then
                    for _, e in ipairs(w.groupChildren) do
                        if not e.filterHidden and not (e.widget.hideOn and e.widget.hideOn()) then return true end
                    end
                elseif w.searchEntry then
                    return true
                end
            end
        end
        return false
    end
    for _, q in ipairs({ "move", "mover", "movement", "resting", "fade", "border", "hide", "range",
                         "cast bar", "size", "width", "handle", "permanent", "frame", "color", "show" }) do
        Type("")
        Type(q)
        for name, btn in pairs(GUI.Tabs) do
            if btn._shown then
                local page = GUI.Pages[name]
                GUI.FilterPagePass(page, DF.db.party)
                check(Showing(page), "invariant: '" .. q .. "' lists " .. name .. " and something shows on it")
            end
        end
    end
    Type("")
end

print("-- Filter: pages nobody has opened are searched from the prebuilt index, building nothing")
do
    NewWindow()
    local built = 0
    local function Unbuilt(name, label)
        local p = Page(name, label)
        p.GetIndexEntries = function() return nil end   -- no build this session
        p.Refresh = function() built = built + 1 end
        p.RefreshForIndex = p.Refresh
        return p
    end
    local fp = Unbuilt("general_frame", "Frame")
    Unbuilt("display_fading", "Fading")
    Unbuilt("general_layout", "Layout")
    -- What the generator writes (Features/SearchIndexData.lua): strings, conditions,
    -- and per page flat rows of six (label, title, key, tooltip, condition, flags).
    S.PrebuiltIndex = {
        version = "test", commit = "0", rows = 5,
        S = { "Global Frame Fade", "Frame Fade", "frameFadeAlpha", "Frame Alpha (Out of Range)", "Out of Range",
              "rangeFadeAlpha", "Width", "Size", "frameWidth", "Range Check Spell", "rangeCheckSpellID",
              "Hidden Thing", "hiddenAlpha" },
        C = { { { "showHidden", true } } },
        P = {
            general_frame  = { 1, 2, 3, 0, 0, 0,   2, 2, 0, 0, 0, 1 },
            display_fading = { 4, 5, 6, 0, 0, 0,   10, 5, 11, 0, 0, 0 },
            general_layout = { 7, 8, 9, 0, 0, 0,   12, 8, 13, 0, 1, 0 },
        },
    }
    DF.db.party.showHidden = false
    GUI.CurrentPageName = "general_frame"
    Type("fade")
    eq(built, 0, "prebuilt: focusing and typing build no page")
    check(GUI.Tabs.general_frame._shown and GUI.Tabs.display_fading._shown and not GUI.Tabs.general_layout._shown,
          "prebuilt: unopened pages are listed from the index")
    Type("")
    Type("hidden thing")
    check(not GUI.Tabs.general_layout._shown, "prebuilt: a row hidden by its recorded condition does not list its page")
    DF.db.party.showHidden = true
    Type("")
    Type("hidden thing")
    check(GUI.Tabs.general_layout._shown, "prebuilt: ...and does once the condition holds")
    Type("")
    Type("out of range")
    check(GUI.Tabs.display_fading._shown, "prebuilt: a card title row finds its page")

    print("-- Filter: a page's live build takes over from its prebuilt rows")
    -- The Frame page is opened: it now has a build whose entries the filter uses.
    fp.GetIndexEntries = function() return fp._entries end
    S:SetCurrentTab("general_frame", "Frame")
    Card(fp, "Movement", { { "Show Handle", "permanentMoverShow" } })
    Type("")
    Type("handle")
    check(GUI.Tabs.general_frame._shown, "live: a setting only the live build has is found")
    Type("")
    Type("global frame fade")
    check(not GUI.Tabs.general_frame._shown, "live: the live build replaces the prebuilt rows (it has no such setting here)")
    eq(built, 0, "live: still nothing built by the search")

    print("-- Filter: the word index fills in slices, and the answer widens as it does")
    local savedClock = debugprofilestop
    local clk = 0
    debugprofilestop = function() clk = clk + 1; return clk end
    local rows = {}
    for i = 1, 200 do
        S.PrebuiltIndex.S[#S.PrebuiltIndex.S + 1] = "Fade Thing " .. i
        local idx = #S.PrebuiltIndex.S
        rows[#rows + 1] = idx; rows[#rows + 1] = 2; rows[#rows + 1] = 0
        rows[#rows + 1] = 0; rows[#rows + 1] = 0; rows[#rows + 1] = 0
    end
    Unbuilt("big_page", "Big Page")
    S.PrebuiltIndex.P.big_page = rows
    S:SetFilterText("thing")
    local sawPartial, frames = false, 0
    while #timers > 0 and frames < 200 do
        local batch = timers; timers = {}
        for _, fn in ipairs(batch) do fn() end
        frames = frames + 1
        if S.Filter.partial then sawPartial = true end
    end
    check(sawPartial, "slices: the filter answered while the word index was still filling")
    check(not S.Filter.partial and GUI.Tabs.big_page._shown, "slices: ...and the finished answer lists the page")
    debugprofilestop = savedClock
    Type("")
end

print("-- Filter: a shown card is never an empty stretched panel")
do
    NewWindow()
    -- The card's outline as SettingsWidgets draws it (_ApplyCardFold): open runs
    -- down to the body, unless the body is filtered off the page. Recorded at
    -- each fold, so a fold left stale after a mark moved is caught.
    local function Foldable(section, body)
        section.cardBody = body
        function section:ShowFold()
            self.folds = (self.folds or 0) + 1
            self.foldOpen = (self.expanded and not rawget(body, "dfFilterHidden")) and true or false
        end
        section:ShowFold()
    end
    local pt = Page("indicators_personaltargeted", "Personal Targeted")
    local function capture(fn) S._captureEntries = pt._entries; fn(); S._captureEntries = nil end
    local cards = {}
    local function TickCard(title, tickLabel, tickKey, rows, shut)
        local section, box
        capture(function()
            section, box = Card(pt, title, rows, { col = 1, shut = shut })
            S:SetCurrentSection(title, section)
            section.headerToggle = Control(pt, tickLabel, tickKey)
        end)
        Foldable(section, box)
        cards[#cards + 1] = { section = section, box = box, title = title, expanded = section.expanded }
        return section, box
    end
    TickCard("Interrupted Visual", "Show Interrupted Visual", "personalTargetedSpellShowInterrupted", {
        { "Duration", "personalTargetedSpellInterruptedDuration" },
        { "Tint Color", "personalTargetedSpellInterruptedTintColor" },
        { "Tint Opacity", "personalTargetedSpellInterruptedTintAlpha" },
    })
    TickCard("X Mark", "Show X Mark", "personalTargetedSpellInterruptedShowX", {
        { "X Color", "personalTargetedSpellInterruptedXColor" },
        { "X Size", "personalTargetedSpellInterruptedXSize" },
    }, true)
    -- A card whose body holds a nested box with its own header and rows.
    local outer, outerBox = Card(pt, "Cast Bar Look", { { "Bar Texture", "castTexture" } }, { col = 1 })
    local sub = { isSettingsGroup = true, groupChildren = {} }
    function sub:SetChildFiltered(w, on)
        for _, e in ipairs(self.groupChildren) do if e.widget == w then e.filterHidden = on and true or nil end end
    end
    function sub:ClearChildFilter() for _, e in ipairs(self.groupChildren) do e.filterHidden = nil end end
    local subHead = { isSectionHeader = true, settingsGroup = sub }
    sub.groupChildren[1] = { widget = subHead }
    capture(function()
        for _, r in ipairs({ { "Border Size", "castBorderSize" }, { "Kick Mark Color", "castKickColor" } }) do
            local w = Control(pt, r[1], r[2])
            w.settingsGroup = sub
            sub.groupChildren[#sub.groupChildren + 1] = { widget = w }
        end
    end)
    sub.settingsGroup = outerBox
    outerBox.groupChildren[#outerBox.groupChildren + 1] = { widget = sub }
    Foldable(outer, outerBox)
    cards[#cards + 1] = { section = outer, box = outerBox, title = "Cast Bar Look", expanded = outer.expanded }
    GUI.CurrentPageName = "indicators_personaltargeted"

    local function VisibleRows(box)
        local n = 0
        for _, e in ipairs(box.groupChildren) do
            local w = e.widget
            if not e.filterHidden and not w.isSectionHeader then
                if w.groupChildren then n = n + VisibleRows(w) else n = n + 1 end
            end
        end
        return n
    end
    for _, q in ipairs({ "interrupt", "x mark", "cast", "kick", "border", "fade", "show", "hide",
                         "visual", "tint", "show x", "color" }) do
        Type("")
        Type(q)
        GUI.FilterPagePass(pt, DF.db.party)
        for _, c in ipairs(cards) do
            local sec, box = c.section, c.box
            if not rawget(sec, "dfFilterHidden") then
                local bodyHidden = rawget(box, "dfFilterHidden") and true or false
                check(sec.foldOpen == ((sec.expanded and not bodyHidden) and true or false),
                      "fold: '" .. q .. "' " .. c.title .. " is drawn for its body as it is now")
                if sec.foldOpen then
                    check(VisibleRows(box) > 0, "fold: '" .. q .. "' " .. c.title .. " is open over visible rows")
                end
                if bodyHidden then
                    check(not sec.dfFilterOpened, "fold: '" .. q .. "' " .. c.title .. " is not opened over a hidden body")
                end
            end
        end
    end
    Type("")
    Type("show")
    check(not rawget(cards[1].section, "dfFilterHidden") and rawget(cards[1].box, "dfFilterHidden"),
          "tick: 'show' keeps Interrupted Visual by its tick with its rows filtered out")
    check(not cards[1].section.foldOpen, "tick: ...and draws it as its header alone")
    Type("x mark")
    check(cards[2].section.foldOpen and VisibleRows(cards[2].box) == 2, "title: 'x mark' shows the X Mark card whole")
    Type("")
    for _, c in ipairs(cards) do
        check(c.section.expanded == c.expanded and c.section.foldOpen == c.expanded,
              "clear: " .. c.title .. " is back to its own fold, drawn as before")
        check(rawget(c.section, "dfFoldBodyHidden") == nil, "clear: ...with no filter mark left on it")
    end
end

print("-- Filter: the note shows exactly when nothing on the page shows")
do
    NewWindow()
    -- What is showing on a page after its pass: a card, a box with a row left,
    -- or a control. Headers and the page's tools are not settings.
    local function Showing(page)
        for _, w in ipairs(page.children) do
            if not rawget(w, "dfFilterHidden") and not w.isSectionHeader then
                if w.sectionChildren then return true end
                if w.groupChildren then
                    for _, e in ipairs(w.groupChildren) do
                        if not e.filterHidden and not e.widget.isSectionHeader then return true end
                    end
                elseif w.searchEntry then
                    return true
                end
            end
        end
        return false
    end
    local function Header(page, title, col)
        local h = { isSectionHeader = true, layoutCol = col or 1, GetText = function() return title end }
        page.children[#page.children + 1] = h
        return h
    end
    -- A debuff-bar-like page, built, whose live build the index cannot reuse:
    -- the filter searches its PREBUILT rows, which say less than its widgets
    -- (the reported case: the list's verdict came from rows, the page from widgets).
    local db = Page("auras_debuffs", "Debuff Bar")
    db.GetIndexEntries = function() return nil end
    Header(db, "Content")
    Card(db, "Order & Limits", { { "Sort Order", "debuffSortOrder" }, { "My Auras First", "debuffMineFirst" },
                                 { "Reverse Order", "debuffReverse" }, { "Hide Long Debuffs", "debuffMaxDurationEnabled" } })
    Card(db, "Border", { { "Show Border", "debuffShowBorder" } })
    local fr = Page("general_frame", "Frame")
    Card(fr, "Appearance", { { "Global Frame Fade", "frameFadeAlpha" } })
    local hp = Page("bars_health", "Health Bar")
    Card(hp, "Colors", { { "Bar Color", "healthColor" } })
    -- Unit frame pages, in another view.
    local uf = Page("uf_player_debuffs", "Player Debuffs", { outOfView = true })
    Card(uf, "Order & Limits", { { "Sort Order", "debuffSortOrder" } })
    S.PrebuiltIndex = { version = "t", commit = "0", rows = 1,
        S = { "Show Border", "Border", "debuffShowBorder" }, C = {},
        P = { auras_debuffs = { 1, 2, 3, 0, 0, 0 } } }

    local function NoteTruth(q, pages)
        for _, name in ipairs(pages) do
            GUI.CurrentPageName = name
            S:RefreshFilter(false)
            local page = GUI.Pages[name]
            local shows = Showing(page)
            if S:FilterActive() and S.Filter.inView[name] and page._dfFiltered then
                local noteShown = GUI._note and GUI._note.shown or false
                check(noteShown == not shows,
                      "note: '" .. q .. "' on " .. name .. " shows=" .. tostring(shows) .. " note=" .. tostring(noteShown))
            else
                check(not (GUI._note and GUI._note.shown), "note: '" .. q .. "' on " .. name .. " (not narrowed) has no note")
            end
        end
    end
    for _, q in ipairs({ "sort", "order", "limits", "content", "hide", "border", "fade", "transparency",
                         "reverse", "color", "zzzq" }) do
        Type("")
        Type(q)
        RunTimers()
        NoteTruth(q, { "auras_debuffs", "general_frame", "bars_health" })
    end

    print("-- Filter: the list follows what the page on screen shows")
    Type("")
    GUI.CurrentPageName = "auras_debuffs"
    Type("sort order")
    RunTimers()
    check(not (GUI._note and GUI._note.shown) and Showing(db), "list: 'sort order' shows the Order & Limits card, no note")
    check(GUI.Tabs.auras_debuffs._shown, "list: ...and the page is listed (its prebuilt rows did not say so)")

    print("-- Filter: after a module switch, the page shown gets the same rule")
    Type("")
    Type("sort")
    for _, btn in pairs(GUI.Tabs) do btn.inView = not btn.inView end   -- the Unit Frames view
    GUI.CurrentPageName = "uf_player_debuffs"
    GUI:UpdateTabLayout()
    RunTimers()
    S:RefreshFilter(false)
    check(not (GUI._note and GUI._note.shown) and Showing(uf), "switch: the unit page shows its match and no note")
    Type("")
    Type("fade")
    RunTimers()
    GUI.CurrentPageName = "uf_player_debuffs"
    S:RefreshFilter(false)
    check(GUI._note and GUI._note.shown and not Showing(uf), "switch: with nothing matching, the note and nothing under it")
    Type("")
    check(not (GUI._note and GUI._note.shown), "clear: the note goes with the filter")
end

print("-- Filter: the wiring in the shared files")
local P = options_file_source("GUI/Panel.lua"):gsub("\r\n", "\n")
check(P:find("if GUI.FilterPagePass then GUI.FilterPagePass(self, db) end", 1, true) ~= nil,
      "wiring: the page state pass runs the filter first")
local _, nHidden = P:gsub('rawget%(widget, "dfFilterHidden"%)', "")
eq(nHidden, 2, "wiring: both the box branch and the widget branch honour the filter mark")
check(P:find("not (navFilter and navFilter(btn))", 1, true) ~= nil, "wiring: the page list asks per row")
check(P:find("DF.Search:CreateFilterBar(tabFrame)", 1, true) ~= nil, "wiring: the page list's box is the filter bar")
local SWS = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")
check(SWS:find('local open = (body and self.expanded and not rawget(body, "dfFilterHidden")) and true or false', 1, true) ~= nil,
      "wiring: a card's outline runs only down to a body the filter left on the page")
local TOC = options_file_source("DandersFrames_Options.toc")
check(TOC:find("Features\\SearchMatch.lua", 1, true) < TOC:find("Features\\SearchFilter.lua", 1, true),
      "wiring: the filter loads after the matcher")

DandersFrames, C_Timer, GetLocale, InCombatLockdown, CreateFrame = savedDF, savedTimer, savedLocale, savedCombat, savedCF
