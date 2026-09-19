local NS = ...

-- ============================================================
-- ONE RETAINED BUILD PER MODE -- DandersFrames_Options/GUI/Panel.lua
-- ------------------------------------------------------------
-- The leak this pins: flipping the settings panel between Party and Raid used to
-- REBUILD the page on every click, parking the whole previous page in
-- GUI._trashFrame -- which WoW never collects and nothing ever empties (~800 KB a
-- click, measured in game 2026-09-18). A page now keeps at most one build per
-- mode and a switch swaps them.
--
-- ★ SECTION 1 IS BEHAVIOURAL, NOT A SOURCE SEARCH. Panel.lua is far too tangled in
-- the live client to load whole, but BuildPage and the helpers above it close over
-- only GUI, DF, L, ResolveRowHeight and CreateFrame -- so the block is cut out of
-- the REAL source by its own markers and run against fakes. A widget here is a
-- table that counts its Hide/Show/SetParent calls; "trashed" means SetParent was
-- handed GUI._trashFrame.
--
-- ⚠ If the markers move, the extraction fails LOUDLY (a check, not a crash) --
-- move the markers here with them.
--
-- Section 2 pins the wiring that cannot be reached any other way (the mode tabs,
-- the flag through RefreshCurrentPage, search, undo, the opted-out pages) by
-- source shape. Weaker, and deliberately limited to call sites.
-- ============================================================

local panel = options_file_source("GUI/Panel.lua")

-- ------------------------------------------------------------
-- The block under test, cut out of the real file.
-- ------------------------------------------------------------
local START_NEW = "    local MODE_BUILD_FIELDS = {"
local START_OLD = "    local function BuildPage(page, builderFunc)"
local STOP      = "    -- Trash frame: detached from the GUI hierarchy."

local s = panel:find(START_NEW, 1, true) or panel:find(START_OLD, 1, true)
local e = panel:find(STOP, 1, true)
check(s and e and e > s, "modebuilds: BuildPage can be cut out of Panel.lua by its markers")

local BuildPage
if s and e and e > s then
    local body = panel:sub(s, e - 1)
    local chunk = "local GUI, DF, L, ResolveRowHeight = ...\n" .. body .. "\nreturn BuildPage\n"
    local fn, err = loadstring(chunk, "@Panel.lua:BuildPage")
    check(fn ~= nil, "modebuilds: the cut-out BuildPage compiles (" .. tostring(err) .. ")")
    if fn then
        BuildPage = function(GUI, DF, page, builder)
            local bp = fn(GUI, DF, {}, function(_, h) return h end)
            return bp(page, builder)
        end
    end
end

-- ------------------------------------------------------------
-- Fakes
-- ------------------------------------------------------------
local TRASH = { name = "trash" }

local function Widget(tag)
    local w = { tag = tag, shown = true, hides = 0, shows = 0, onShows = 0 }
    function w:Hide() self.shown = false; self.hides = self.hides + 1 end
    function w:Show()
        if not self.shown then self.onShows = self.onShows + 1 end
        self.shown = true; self.shows = self.shows + 1
    end
    function w:IsShown() return self.shown end
    function w:ClearAllPoints() self.cleared = true end
    function w:SetParent(p) self.parent = p; if p == TRASH then self.trashed = (self.trashed or 0) + 1 end end
    function w:SetSize() end
    return w
end

-- One harness: a GUI, a DF and a page wired to a builder that records its builds.
local function Harness(opts)
    opts = opts or {}
    local H = { builds = 0, closes = 0, restates = 0, built = {} }
    H.GUI = {
        SelectedMode = "party",
        _trashFrame = TRASH,
        IsTabDisabledForCurrentMode = function() return false end,
        PageRefreshStates = function() H.restates = H.restates + 1 end,
        CloseAllPopoutRows = function() H.closes = H.closes + 1 end,
    }
    H.DF = { db = { party = { mode = "party" }, raid = { mode = "raid" } } }
    H.page = { tabName = "test_page", child = {} }
    if opts.single then H.page.singleModeBuild = true end
    if opts.fields then H.page.modeBuildFields = opts.fields end

    BuildPage(H.GUI, H.DF, H.page, function(self, db, Add)
        H.builds = H.builds + 1
        local list = {}
        for i = 1, 3 do
            local w = Widget(db.mode .. i)
            Add(w, 10)
            list[#list + 1] = w
        end
        -- a per-build page field, and the popout tools' holders
        self.rangeSpellInput = list[1]
        self._popoutHolders = { Widget(db.mode .. "-holder") }
        H.built[#H.built + 1] = { mode = db.mode, widgets = list, holders = self._popoutHolders }
    end)
    function H:Switch(mode)
        self.GUI.SelectedMode = mode
        self.page:RefreshCached()
    end
    return H
end

local function anyTrashed(list)
    for _, w in ipairs(list) do if w.trashed then return true end end
    return false
end
local function allShown(list)
    for _, w in ipairs(list) do if not w.shown then return false end end
    return true
end
local function allHidden(list)
    for _, w in ipairs(list) do if w.shown then return false end end
    return true
end

-- Guarded, so running this file against the pre-fix Panel.lua FAILS rather than
-- crashes (the method is new).
local function IndexBuild(page)
    if page.RefreshForIndex then page:RefreshForIndex()
    else check(false, "modebuilds: the page has RefreshForIndex") end
end

local savedCreateFrame = CreateFrame
CreateFrame = function() return Widget("spacer") end

-- ============================================================
-- 1. BEHAVIOUR
-- ============================================================
if BuildPage then
    -- A valid build is never trashed by a switch, and each mode is built once.
    do
        local H = Harness()
        H.page:RefreshCached()
        eq(H.builds, 1, "modebuilds: the first visit builds")
        local party = H.built[1]

        H:Switch("raid")
        eq(H.builds, 2, "modebuilds: the first raid visit builds raid")
        local raid = H.built[2]
        check(not anyTrashed(party.widgets), "modebuilds: switching to raid does not trash the party build")
        check(allHidden(party.widgets), "modebuilds: the party build is hidden while raid is up")
        check(H.closes >= 1, "modebuilds: a switch closes the open row panels (they are wired to the outgoing mode)")

        H:Switch("party")
        eq(H.builds, 2, "modebuilds: switching back to a valid party build does NOT rebuild")
        check(not anyTrashed(party.widgets) and not anyTrashed(raid.widgets),
              "modebuilds: switching back trashes nothing")
        check(allShown(party.widgets), "modebuilds: the party build comes back up")
        check(allHidden(raid.widgets), "modebuilds: the raid build goes away")
        check(party.widgets[1].onShows >= 1,
              "modebuilds: a swapped-in build is re-shown, so its widgets' OnShow value repaint runs")
        eq(H.page.children[1], party.widgets[1], "modebuilds: page.children is the party build again")
        eq(H.page.rangeSpellInput, raid.widgets[1],
           "modebuilds: a page field NOT declared per-build is left alone (declared ones: below)")
        eq(H.page._popoutHolders, party.holders, "modebuilds: the popout holders travel with their build")

        for _ = 1, 20 do H:Switch("raid"); H:Switch("party") end
        eq(H.builds, 2, "modebuilds: 20 more round trips build nothing")
        check(not anyTrashed(party.widgets) and not anyTrashed(raid.widgets),
              "modebuilds: 20 more round trips trash nothing -- the leak")
    end

    -- Declared per-build page fields are swapped with the build.
    do
        local H = Harness({ fields = { "rangeSpellInput" } })
        H.page:RefreshCached()
        H:Switch("raid")
        H:Switch("party")
        eq(H.page.rangeSpellInput, H.built[1].widgets[1],
           "modebuilds: a modeBuildFields entry comes back with its own build")
        H:Switch("raid")
        eq(H.page.rangeSpellInput, H.built[2].widgets[1],
           "modebuilds: ...and the other build's with the other")
    end

    -- Invalidate hits BOTH modes; each invalid build is trashed once, when rebuilt.
    do
        local H = Harness()
        H.page:RefreshCached()
        H:Switch("raid")
        local party, raid = H.built[1], H.built[2]
        H.page:Invalidate()
        H:Switch("party")
        eq(H.builds, 3, "modebuilds: after Invalidate the party build is rebuilt")
        eq(party.widgets[1].trashed, 1, "modebuilds: the invalid party build is trashed when it is rebuilt")
        check(not anyTrashed(raid.widgets), "modebuilds: the invalid raid build is not trashed before its rebuild")
        H:Switch("raid")
        eq(H.builds, 4, "modebuilds: Invalidate also invalidated the raid build")
        eq(raid.widgets[1].trashed, 1, "modebuilds: ...which is trashed once, when rebuilt")
        H:Switch("party"); H:Switch("raid")
        eq(H.builds, 4, "modebuilds: the fresh builds are served from then on")
        eq(party.widgets[1].trashed, 1, "modebuilds: nothing is trashed twice")
    end

    -- Invalidate(mode) hits only that mode.
    do
        local H = Harness()
        H.page:RefreshCached()
        H:Switch("raid")
        H.page:Invalidate("party")
        H:Switch("raid")
        eq(H.builds, 2, "modebuilds: Invalidate('party') leaves the raid build valid")
        H:Switch("party")
        eq(H.builds, 3, "modebuilds: ...and the party build invalid")
    end

    -- Refresh() rebuilds the CURRENT mode only, and invalidates the other one.
    do
        local H = Harness()
        H.page:RefreshCached()
        H:Switch("raid")
        local party, raid = H.built[1], H.built[2]
        H.page:Refresh()
        eq(H.builds, 3, "modebuilds: Refresh always rebuilds")
        eq(H.built[3].mode, "raid", "modebuilds: ...the current mode")
        eq(raid.widgets[1].trashed, 1, "modebuilds: Refresh trashes the current mode's old build")
        check(not anyTrashed(party.widgets), "modebuilds: Refresh does not trash the other mode's build")
        H:Switch("party")
        eq(H.builds, 4, "modebuilds: Refresh invalidated the other mode's build (data changed)")
        eq(party.widgets[1].trashed, 1, "modebuilds: ...which is trashed once, on its rebuild")
    end

    -- RefreshForIndex rebuilds the current mode and leaves the other one valid.
    do
        local H = Harness()
        H.page:RefreshCached()
        H:Switch("raid")
        IndexBuild(H.page)
        eq(H.builds, 3, "modebuilds: the search index rebuild re-runs the builder")
        H:Switch("party")
        eq(H.builds, 3, "modebuilds: ...without invalidating the other mode's build")
    end

    -- A build bound to a mode table that has since been REPLACED is never served.
    do
        local H = Harness()
        H.page:RefreshCached()
        H:Switch("raid")
        H.DF.db.party = { mode = "party" }
        H:Switch("party")
        eq(H.builds, 3, "modebuilds: a replaced mode table forces a rebuild")
    end

    -- A search-index style build of a page last shown in the other mode parks
    -- that build rather than trashing it.
    do
        local H = Harness()
        H.page:RefreshCached()                 -- party
        H.GUI.SelectedMode = "raid"
        IndexBuild(H.page)               -- raid, straight through DoBuild
        check(not anyTrashed(H.built[1].widgets), "modebuilds: DoBuild in the other mode parks, never trashes")
        H:Switch("party")
        eq(H.builds, 2, "modebuilds: ...and the parked build is served again")
    end

    -- No db ("clicks" mode): nothing happens at all.
    do
        local H = Harness()
        H.page:RefreshCached()
        H:Switch("clicks")
        eq(H.builds, 1, "modebuilds: clicks mode builds nothing")
        check(allShown(H.built[1].widgets), "modebuilds: clicks mode leaves the build on screen alone")
        eq(H.closes, 0, "modebuilds: clicks mode closes nothing")
    end

    -- THE OPT-OUT: page.singleModeBuild keeps the old one-build path exactly.
    do
        local H = Harness({ single = true })
        H.page:RefreshCached()
        H:Switch("raid")
        eq(H.builds, 2, "modebuilds[single]: raid builds")
        eq(H.built[1].widgets[1].trashed, 1, "modebuilds[single]: the old build is trashed on the switch, as before")
        H:Switch("party")
        eq(H.builds, 3, "modebuilds[single]: switching back rebuilds, as before")
        eq(H.built[2].widgets[1].trashed, 1, "modebuilds[single]: ...trashing the raid build")
        check(H.page._modeBuilds == nil, "modebuilds[single]: no per-mode slots are ever kept")
        eq(H.closes, 0, "modebuilds[single]: the swap path is never taken")
        H.page:Invalidate()
        check(H.page.builtForMode == nil and H.page.cacheValid == false,
              "modebuilds[single]: Invalidate still clears builtForMode, as before")
        H:Switch("party")
        eq(H.builds, 4, "modebuilds[single]: and the next visit rebuilds")
    end
end

CreateFrame = savedCreateFrame

-- ============================================================
-- 2. THE WIRING (source shape)
-- ============================================================
local function count(src, needle)
    local n, i = 0, 1
    while true do
        local a = src:find(needle, i, true)
        if not a then return n end
        n, i = n + 1, a + #needle
    end
end

-- The mode tabs go through the cached path, and after the Sync, invalidate
-- what it replaced.
eq(count(panel, "        GUI:RefreshCurrentPageForModeSwitch()"), 2,
   "modebuilds: both mode tabs refresh through the cached path")
eq(count(panel, "        GUI:UpdateTabAvailability()\n        GUI:RefreshCurrentPage()"), 0,
   "modebuilds: no mode tab forces a rebuild any more")
eq(count(panel, "        DF:SyncLinkedSections()\n"
    .. "        -- The sync just replaced the other mode's tables for every synced page;\n"
    .. "        -- a retained build of those pages must not be served. See the function.\n"
    .. "        if GUI.InvalidateSyncedPages then GUI:InvalidateSyncedPages() end"), 2,
   "modebuilds: both mode tabs invalidate the synced pages right after the sync")

-- The flag through RefreshCurrentPage: consumed first, and routed to the cache.
check(panel:find("local cached = GUI._refreshCurrentPageCached\n        GUI._refreshCurrentPageCached = nil", 1, true) ~= nil,
      "modebuilds: RefreshCurrentPage consumes the cached flag before anything can return")
check(panel:find("if cached and not page.singleModeBuild and page.RefreshCached then\n                page:RefreshCached()\n            else\n                page:Refresh()", 1, true) ~= nil,
      "modebuilds: the flag routes to RefreshCached, and an opted-out page still to Refresh")
check(panel:find("GUI._refreshCurrentPageCached = true\n        GUI:RefreshCurrentPage()\n        GUI._refreshCurrentPageCached = nil", 1, true) ~= nil,
      "modebuilds: the mode-switch refresh goes through GUI:RefreshCurrentPage by name (the Auto Layouts wrapper)")
check(panel:find("function GUI:InvalidateAllPages(mode)", 1, true) ~= nil
      and panel:find("if page.Invalidate then page:Invalidate(mode) end", 1, true) ~= nil,
      "modebuilds: InvalidateAllPages passes an optional mode through")

-- Search indexes without invalidating the other mode's builds.
local search = options_file_source("Features/Search.lua")
check(search:find("if page.RefreshForIndex then\n                page:RefreshForIndex()", 1, true) ~= nil,
      "modebuilds: the search index rebuild uses RefreshForIndex")

-- An undo that is not repainted now invalidates its mode's retained builds.
local undo = df_file_source("Core/SettingsUndo.lua")
check(undo:find("GUI:InvalidateAllPages(mode)", 1, true) ~= nil,
      "modebuilds: an undo of the other mode's setting invalidates that mode's builds")

-- The opted-out pages, and the page that declares per-build fields.
local auras   = options_file_source("GUI/Pages/Auras.lua")
local modules = options_file_source("GUI/Pages/Modules.lua")
local options = options_file_source("GUI/Pages/Options.lua")
for _, pair in ipairs({
    { auras,   "pageNicknames" },
    { auras,   "pageTextDesigner" },
    { auras,   "pageFilterDesigner" },
    { auras,   "pageAuraDesigner" },
}) do
    local v = pair[2]
    check(pair[1]:find("if " .. v .. " then " .. v .. ".singleModeBuild = true end", 1, true) ~= nil,
          "modebuilds: " .. v .. " is opted out of the retained builds")
end
-- The three Modules.lua pages are opted out by TAB NAME in Panel.lua (so the
-- opt-out does not have to live in Modules.lua). Pin both halves: the name is in
-- the set, and it is the tab that page is really created under.
local panelSrc = options_file_source("GUI/Panel.lua")
for _, pair in ipairs({
    { "pageAutoProfiles", "profiles_auto" },
    { "pageImportExport", "profiles_importexport" },
    { "pageDebugConsole", "debug_console" },
}) do
    local v, tab = pair[1], pair[2]
    check(panelSrc:find("%s" .. tab .. " = true,") ~= nil,
          "modebuilds: " .. v .. " is opted out of the retained builds (by tab name)")
    check(modules:find("local " .. v .. " = CreateSubTab%([^,]+, \"" .. tab .. "\"") ~= nil,
          "modebuilds: " .. v .. " is really created under tab " .. tab)
end
check(panelSrc:find("if page and SINGLE_MODE_TABS[page.tabName] then page.singleModeBuild = true end", 1, true) ~= nil,
      "modebuilds: BuildPage applies the tab-name opt-outs")
check(options:find('pageFading.modeBuildFields = { "rangeSpellInput", "rangeSpellInfoLabel" }', 1, true) ~= nil,
      "modebuilds: the Fading page swaps its range-spell fields with its build")
