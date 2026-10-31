local NS = ...

-- ============================================================
-- PAGE PROVIDERS AND MODULE-OWNED PAGES
-- DandersFrames/GUI/GUI.lua            (DF.GUIPageProviders, GUI.ModulePageOwner)
-- DandersFrames_Options/GUI/ModuleRegistry.lua (RunPageProviders, SidebarModule,
--                                       SetPageModule, PageBuildKey/PageBuildDb)
-- DandersFrames_Options/GUI/Panel.lua  (the call, BuildPage's keys, the sidebar)
-- DandersFrames_Options/GUI/Rail.lua   (deck tabs for a module added later)
-- ------------------------------------------------------------
-- A DUMMY provider (this file only -- no real provider exists) turns a
-- placeholder module into a sidebar module with two tabs and pages of its own,
-- whose retained builds are keyed per tab. Section 1 runs the real registry over
-- stubs; section 2 runs the real BuildPage, cut out of Panel.lua the way
-- test_mode_builds.lua does; section 3 pins the wiring by source shape.
-- ============================================================

local savedDF = DandersFrames
local calls = {}
local function log(x) calls[#calls + 1] = x end

local GUI = {
    SelectedMode = "party",
    GlobalView = false,
    GlobalAccent = { r = 0.25 },
    GlobalPages = { general_settings = true },
}
function GUI.IsGlobalPage(name) return GUI.GlobalPages[name] == true end
function GUI.GetThemeColorFor(isRaid) return isRaid and "RAID" or "PARTY" end
function GUI:SetAccent(c) log("accent:" .. tostring(c)) end
function GUI.CurrentAccent() return "ACCENT" end
function GUI.UpdateThemeColors() log("theme") end
function GUI:ShowNormalContent() log("normal") end
function GUI:ShowClickCastingContent() end
function GUI:ShowPlaceholderContent() end
function GUI:UpdateTabAvailability() end
function GUI:RefreshCurrentPageForModeSwitch() log("refresh") end
function GUI:LastTabInView() return "dummy_a" end
function GUI:EnterView(g) GUI.GlobalView = g and true or false; log("view:" .. tostring(g)) end
GUI.SelectTab = function(n) log("tab:" .. tostring(n)) end

local errors = {}
local DF = { GUI = GUI }
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
function DF:SyncLinkedSections() end
function DF:GetDB() return { locked = true } end
function DF:GetRaidDB() return { raidLocked = true } end
DandersFrames = DF

load_options_file_into("GUI/ModuleRegistry.lua", NS)

-- A placeholder, the way the built-in "coming soon" items are registered.
GUI:RegisterModule({ id = "dummy", label = "Dummy", order = 15, comingSoon = true, placeholder = true })
check(not GUI:IsModuleOn("dummy"), "setup: the placeholder is not a usable module yet")
local genBefore = GUI._moduleGen

-- ---- the dummy provider -----------------------------------------------------
local tab = "one"
local dbs = { one = { which = "one" }, two = { which = "two" } }
local made = { cats = {}, pages = {} }
local ran = {}
DF.GUIPageProviders = {
    function() ran[#ran + 1] = "broken"; error("boom") end,
    function(G, CreateCategory, CreateSubTab, BuildPage, L)
        ran[#ran + 1] = "dummy"
        check(G == GUI and type(L) == "table", "provider: handed GUI and L")
        CreateCategory("dummy_cat", "Dummy")
        for _, name in ipairs({ "dummy_a", "dummy_b" }) do
            local page = CreateSubTab("dummy_cat", name, name)
            BuildPage(page, function() end)
            G:SetPageModule(name, "dummy")
        end
        G:SidebarModule({
            id = "dummy", label = "Dummy", order = 15,
            accent = function() return "DUMMY" end,
            tabs = { { id = "one", label = "One" }, { id = "two", label = "Two" } },
            activeTab = function() return tab end,
            defaultTab = function() return tab end,
            onTab = function(t) tab = t; log("ontab:" .. t) end,
            buildKey = function(pageName) return "dummy:" .. tab end,
            buildDb = function(pageName) return dbs[tab] end,
        })
    end,
    "not a function",
}

print("-- Providers run in order, contained")
GUI:RunPageProviders(
    function(name) made.cats[#made.cats + 1] = name end,
    function(cat, name) local p = { tabName = name, cat = cat }; made.pages[name] = p; return p end,
    function(page, fn) page.built = fn end)
eq(table.concat(ran, ","), "broken,dummy", "both providers ran, in order")
eq(#errors, 1, "the one that threw is reported once")
check(errors[1] and errors[1]:find("page provider 1 failed", 1, true), "...naming which")
eq(made.cats[1], "dummy_cat", "a provider adds a category")
check(made.pages.dummy_a and made.pages.dummy_a.built and made.pages.dummy_b, "...and pages, through BuildPage")

print("-- The placeholder became a module with tabs and a sidebar")
local def = GUI:GetModule("dummy")
check(def and not def.comingSoon and not def.placeholder and def.sidebar, "upgraded in place")
check(GUI:IsModuleOn("dummy"), "usable now")
eq(#def.tabs, 2, "two tabs")
check(GUI._moduleGen > genBefore, "the registry generation moved (the rail re-reads its items)")
local n = 0
for _, d in ipairs(GUI:GetModules()) do if d.id == "dummy" then n = n + 1 end end
eq(n, 1, "listed once")

print("-- Page ownership")
eq(GUI:ModuleForPage("dummy_a"), "dummy", "its pages are its own...")
eq(GUI:ModuleForPage("dummy_b"), "dummy", "...both of them")
check(not GUI:GetModule("group").ownsPage("dummy_a"), "...and Group Frames' catch-all no longer claims them")
eq(GUI:ModuleForPage("general_frame"), "group", "an ordinary page is still Group Frames'")
eq(GUI:ModuleForPage("general_settings"), "global", "a GLOBAL page is still Global's")

print("-- Entering, switching tabs, leaving")
calls = {}
GUI:SelectModule("dummy", "two")
eq(GUI.ModuleView, "dummy", "the module's view is up")
eq(GUI.SelectedModule, "dummy", "the window is on it")
eq(GUI.SelectedMode, "party", "the frame mode underneath is untouched")
eq(tab, "two", "its tab state followed")
local j = table.concat(calls, ",")
check(j:find("normal", 1, true) and j:find("ontab:two", 1, true) and j:find("tab:dummy_a", 1, true),
      "entered: the sidebar shown, the tab set, the last page selected (" .. j .. ")")
calls = {}
GUI:SelectModule("dummy", "one")
j = table.concat(calls, ",")
eq(tab, "one", "tab switch inside the module")
check(j:find("refresh", 1, true) and not j:find("tab:dummy", 1, true),
      "...swaps the page's build (cached refresh), no page re-selected (" .. j .. ")")
GUI:SelectModule("group", "party")
eq(GUI.ModuleView, nil, "leaving clears the view")
eq(GUI.SelectedModule, "group", "...and lands where asked")

print("-- Build keys")
local pa = made.pages.dummy_a
eq(GUI.PageBuildKey(pa), "dummy:one", "a module page's build key is its module's")
eq(GUI.PageBuildDb(pa), dbs.one, "...and so is its settings table")
tab = "two"
eq(GUI.PageBuildKey(pa), "dummy:two", "the key follows the tab")
eq(GUI.PageBuildDb(pa), dbs.two, "...and the table")
eq(GUI.PageBuildKey({ tabName = "general_frame" }), nil, "an ordinary page has none (the frame mode is used)")
eq(GUI.PageBuildDb({ tabName = "general_frame" }), nil, "...nor a table of its own")
local own = { tabName = "dummy_b", buildKey = function() return "pinned" end }
eq(GUI.PageBuildKey(own), "pinned", "a page's own buildKey wins over its module's")

-- ============================================================
-- 2. THE REAL BuildPage KEEPS ONE BUILD PER TAB
-- ============================================================
print("-- BuildPage: one retained build per tab")
local panel = options_file_source("GUI/Panel.lua")
local s = panel:find("    local MODE_BUILD_FIELDS = {", 1, true)
local e = panel:find("    -- Trash frame: detached from the GUI hierarchy.", 1, true)
check(s and e and e > s, "BuildPage can be cut out of Panel.lua by its markers")
local TRASH = {}
local function Widget(tag)
    local w = { tag = tag, shown = true }
    function w:Hide() self.shown = false end
    function w:Show() self.shown = true end
    function w:IsShown() return self.shown end
    function w:ClearAllPoints() end
    function w:SetParent(p) if p == TRASH then self.trashed = true end end
    function w:SetSize() end
    return w
end
if s and e and e > s then
    local fn, err = loadstring("local GUI, DF, L, ResolveRowHeight = ...\n" .. panel:sub(s, e - 1)
        .. "\nreturn BuildPage\n", "@Panel.lua:BuildPage")
    check(fn ~= nil, "the cut-out BuildPage compiles (" .. tostring(err) .. ")")
    if fn then
        GUI._trashFrame = TRASH
        GUI.IsTabDisabledForCurrentMode = function() return false end
        GUI.PageRefreshStates = function() end
        GUI.CloseAllPopoutRows = function() end
        DF.db = { party = { which = "party" }, raid = { which = "raid" } }
        local BuildPage = fn(GUI, DF, DF.L, function(_, h) return h end)

        local builds = {}
        local function Builder(self, db, Add)
            local w = Widget(db.which)
            Add(w, 10)
            builds[#builds + 1] = { db = db, w = w }
        end
        local page = { tabName = "dummy_a", child = {} }
        BuildPage(page, Builder)

        tab = "one"
        page:RefreshCached()
        eq(#builds, 1, "tab one: built")
        eq(builds[1].db, dbs.one, "...against tab one's table")
        eq(page.builtForMode, "dummy:one", "...keyed by the tab")
        tab = "two"
        page:RefreshCached()
        eq(#builds, 2, "tab two: its own build")
        eq(builds[2].db, dbs.two, "...against tab two's table")
        check(not builds[1].w.trashed and not builds[1].w.shown, "tab one's build parked, not trashed")
        tab = "one"
        page:RefreshCached()
        eq(#builds, 2, "back to tab one: served from its retained build, no rebuild")
        check(builds[1].w.shown and not builds[2].w.shown, "...shown again, tab two's parked")
        GUI.SelectedMode = "raid"
        page:RefreshCached()
        eq(#builds, 2, "the frame mode moving underneath does not rebuild a module page")
        GUI.SelectedMode = "party"
        page:Invalidate()
        page:RefreshCached()
        eq(#builds, 3, "invalidated: rebuilt")
        check(builds[1].w.trashed, "...and only then is the old build retired")

        local plain = { tabName = "general_frame", child = {} }
        local plainBuilds = {}
        BuildPage(plain, function(self, db, Add) Add(Widget(db.which), 10); plainBuilds[#plainBuilds + 1] = db end)
        plain:RefreshCached()
        eq(plain.builtForMode, "party", "an ordinary page is still keyed by the frame mode")
        eq(plainBuilds[1], DF.db.party, "...and built against DF.db[mode]")
    end
end

-- ============================================================
-- 3. WIRING (source shape)
-- ============================================================
print("-- Wiring")
local setupAt = panel:find("DF:SetupGUIPages(GUI, CreateCategory, CreateSubTab, BuildPage)", 1, true)
local runAt = panel:find("GUI:RunPageProviders(CreateCategory, CreateSubTab, BuildPage)", 1, true)
local layoutAt = panel:find("    GUI:UpdateTabLayout()\n\n    UpdateThemeColors()", 1, true)
check(setupAt and runAt and layoutAt and setupAt < runAt and runAt < layoutAt,
      "Panel: providers run after the built-in pages, before the nav layout and first paint")
check(panel:find("if GUI.ModuleView then return owner == GUI.ModuleView end", 1, true),
      "Panel: a module view's sidebar lists its own pages only")
check(panel:find("GUI._lastModuleViewPage[GUI.ModulePageOwner[name]] = name", 1, true),
      "Panel: each module view remembers its last page")
local sw = options_file_source("GUI/SettingsWidgets.lua")
check(sw:find("if GUI.ModulePageOwner and GUI.ModulePageOwner[tabName] then return false end", 1, true),
      "a module's page is never greyed by Party or Raid being off")
local rail = options_file_source("GUI/Rail.lua")
check(rail:find("for _, def in ipairs(GUI:GetModules()) do\n        BuildDeckTabs(def)", 1, true),
      "Rail: the refresh builds deck tabs for a module that arrived after the shell")
check(rail:find('tostring(GUI._moduleGen or 0)', 1, true), "Rail: a replaced module refreshes the rail items")
check(rail:find("elseif def and def.sidebarModule then", 1, true) and def.sidebarModule == true,
      "Rail: the window reopens on a sidebar module it was closed on")
local gui = df_file_source("GUI/GUI.lua")
check(gui:find("DF.GUIPageProviders = DF.GUIPageProviders or {}", 1, true), "resident: the provider list")

DandersFrames = savedDF
