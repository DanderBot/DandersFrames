local NS = ...

-- ============================================================
-- THE SEARCH INDEX TAKES A PAGE'S RETAINED BUILD INSTEAD OF BUILDING IT AGAIN
-- ------------------------------------------------------------
-- The leak this pins: every rebuild of the settings search index re-ran EVERY
-- page's builder (~34 pages), and every one of those rebuilds parked the page's
-- previous widgets in GUI._trashFrame, which WoW never collects (~800 KB a page).
-- It ran on every Party/Raid switch with results open, on the next search after
-- a switch, and on opening Changed Settings after one.
--
-- Now each page build remembers what it registered (Search:Register's capture,
-- DoBuild in GUI/Panel.lua) and the index takes those entries from any page
-- whose build for the mode being indexed is still valid. A page is built only
-- the first time it is needed in a mode, or after its data changed.
--
-- ★ BEHAVIOURAL, against the REAL code on both sides: Features/Search.lua is
-- loaded whole against a stub host, and BuildPage is cut out of GUI/Panel.lua
-- by the same markers test_mode_builds.lua uses. A widget is a table that
-- records whether it was handed GUI._trashFrame.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME. This file swaps the `DandersFrames`
-- global, C_Timer, debugprofilestop and CreateFrame; all are restored at the end.
-- ============================================================

local savedDF, savedTimer, savedProfile, savedCreateFrame =
    DandersFrames, C_Timer, debugprofilestop, CreateFrame

local pending = {}
C_Timer = {
    After = function(_, fn) pending[#pending + 1] = fn end,
    NewTimer = function(_, fn) return { Cancel = function() end, _fn = fn } end,
}
local function RunAllFrames()
    local n = 0
    while #pending > 0 and n < 200 do
        local batch = pending
        pending = {}
        for _, fn in ipairs(batch) do fn() end
        n = n + 1
    end
end
debugprofilestop = function() return 0 end

local TRASH = { name = "trash" }
local function Widget(tag)
    local w = { tag = tag, shown = true }
    function w:Hide() self.shown = false end
    function w:Show() self.shown = true end
    function w:IsShown() return self.shown end
    function w:ClearAllPoints() end
    function w:SetParent(p) self.parent = p; if p == TRASH then self.trashed = (self.trashed or 0) + 1 end end
    function w:SetSize() end
    function w:SetText() end
    return w
end
CreateFrame = function() return Widget("spacer") end

-- ---- BuildPage, cut out of the real Panel.lua ------------------------
local panel = options_file_source("GUI/Panel.lua")
local START = "    local MODE_BUILD_FIELDS = {"
local STOP  = "    -- Trash frame: detached from the GUI hierarchy."
local s, e = panel:find(START, 1, true), panel:find(STOP, 1, true)
check(s and e and e > s, "indexreuse: BuildPage can be cut out of Panel.lua by its markers")
local BuildPageFactory
if s and e and e > s then
    local chunk = "local GUI, DF, L, ResolveRowHeight = ...\n" .. panel:sub(s, e - 1) .. "\nreturn BuildPage\n"
    local fn, err = loadstring(chunk, "@Panel.lua:BuildPage")
    check(fn ~= nil, "indexreuse: the cut-out BuildPage compiles (" .. tostring(err) .. ")")
    BuildPageFactory = fn
end

-- ---- one host: the real Search.lua, a GUI, pages --------------------
local function NewHost()
    local DF = {}
    DF.L = setmetatable({}, { __index = function(_, k) return k end })
    DF.PartyDefaults = { keyA = 0, keyB = 0, keyC = 0, keyD = 0 }
    DF.RaidDefaults  = { keyA = 0, keyB = 0, keyC = 0, keyD = 0 }
    function DF:DebugWarn() end
    DF.db = { party = { mode = "party" }, raid = { mode = "raid" } }

    local H = { builds = {}, total = 0, widgets = {} }
    local GUI = {
        SelectedMode    = "party",
        CurrentPageName = "page_a",
        Pages           = {},
        SettingsBox     = { pad = 10, group = 280, colMargin = 15, minCol = 290, colGutter = 20 },
        _trashFrame     = TRASH,
        disabled        = {},
    }
    function GUI:IsTabDisabledForCurrentMode(tab) return self.disabled[tab] and true or false end
    GUI.PageRefreshStates = function() end
    function GUI:CloseAllPopoutRows() end
    function GUI:ParkPage() end
    function GUI:AdoptPage() end
    function GUI:CreateInfoBanner() return Widget("banner") end
    DF.GUI = GUI

    DandersFrames = DF
    load_options_file_into("Features/Search.lua", NS)
    DandersFrames = savedDF

    local BuildPage = BuildPageFactory(GUI, DF, {}, function(_, h) return h end)

    -- A page whose builder registers one checkbox per key, with a callback that
    -- names the mode it was built in (the Pet Frames anchor's shape).
    function H.page(name, keys, shown)
        local p = { tabName = name, tabLabel = name .. "_label", child = {}, _shown = shown or false }
        function p:IsShown() return self._shown end
        function p:Show() self._shown = true end
        function p:Hide() self._shown = false end
        GUI.Pages[name] = p
        H.builds[name] = 0
        BuildPage(p, function(self, db, Add)
            H.builds[name] = H.builds[name] + 1
            H.total = H.total + 1
            local mode = db.mode
            for _, key in ipairs(keys) do
                local w = Add(Widget(name .. ":" .. mode .. ":" .. key), 10)
                H.widgets[#H.widgets + 1] = w
                w.searchEntry = DF.Search:RegisterCheckbox("Label " .. key, key, nil, false,
                    function() return mode end)
            end
        end)
        return p
    end
    function H.anyTrashed()
        for _, w in ipairs(H.widgets) do if w.trashed then return true end end
        return false
    end
    function H.switch(mode)
        -- What the mode tabs do: flip, invalidate the index, show the page cached.
        GUI.SelectedMode = mode
        DF.Search:InvalidateRegistry()
        local cur = GUI.Pages[GUI.CurrentPageName]
        if cur then cur:RefreshCached() end
    end
    H.DF, H.GUI, H.Search = DF, GUI, DF.Search
    return H
end

local function entriesFor(Search, tab)
    local out = {}
    for _, en in ipairs(Search.Registry) do if en.tab == tab then out[#out + 1] = en end end
    return out
end

if BuildPageFactory then
    -- ============================================================
    -- 1. A VALID BUILD IS INDEXED, NOT REBUILT
    -- ============================================================
    do
        local H = NewHost()
        local a = H.page("page_a", { "keyA", "keyB" }, true)
        H.page("page_b", { "keyC" })
        a:RefreshCached()                               -- the tab the user is on
        eq(H.total, 1, "indexreuse: only the visited page is built")

        H.Search:BuildFullRegistry()
        eq(H.builds.page_a, 1, "indexreuse: the index takes the visited page's valid build")
        eq(H.builds.page_b, 1, "indexreuse: ...and builds a page that has none (unavoidable, once)")
        eq(#H.Search.Registry, 3, "indexreuse: every entry is indexed")
        eq(#entriesFor(H.Search, "page_a"), 2, "indexreuse: the reused build's entries are all there")
        local ids = {}
        for _, en in ipairs(H.Search.Registry) do
            check(en.id and not ids[en.id], "indexreuse: every indexed entry has its own id")
            ids[en.id or -1] = true
        end

        -- Built again: nothing runs.
        H.Search:InvalidateRegistry()
        H.Search:BuildFullRegistry()
        eq(H.total, 2, "indexreuse: a second index build builds nothing")
        eq(#H.Search.Registry, 3, "indexreuse: ...and indexes the same entries")
        check(not H.anyTrashed(), "indexreuse: ...and trashes nothing")
    end

    -- ============================================================
    -- 2. THE REPORTED LEAK: MODE SWITCHES WITH THE INDEX IN USE
    -- ============================================================
    do
        local H = NewHost()
        H.page("page_a", { "keyA" }, true):RefreshCached()
        H.page("page_b", { "keyB", "keyC" })
        H.page("page_c", { "keyD" })
        H.Search:EnsureRegistry()
        local afterParty = H.total

        H.switch("raid")
        H.Search:EnsureRegistry()
        eq(H.total, afterParty + 3, "indexreuse: the first raid index builds each page once for raid")
        for _, en in ipairs(H.Search.Registry) do
            eq(en.mode, "raid", "indexreuse: a raid index holds raid entries")
            eq(en.callback(), "raid", "indexreuse: ...with callbacks captured in raid")
        end
        local afterRaid = H.total

        for _ = 1, 20 do
            H.switch("party"); H.Search:EnsureRegistry()
            for _, en in ipairs(H.Search.Registry) do
                if en.callback() ~= "party" or en.mode ~= "party" then
                    check(false, "indexreuse: a party index after a switch holds only party entries")
                end
            end
            H.switch("raid"); H.Search:EnsureRegistry()
        end
        eq(H.total, afterRaid, "indexreuse: 20 more round trips with the index rebuilt each time build nothing")
        check(not H.anyTrashed(), "indexreuse: ...and trash nothing -- the leak")
        eq(#H.Search.Registry, 4, "indexreuse: the index is complete after the round trips")
    end

    -- ============================================================
    -- 3. TryReuseRegistry: ALL OR NOTHING, AND NO FRAME
    -- ============================================================
    do
        local H = NewHost()
        H.page("page_a", { "keyA" }, true):RefreshCached()
        H.page("page_b", { "keyB" })
        check(not H.Search:TryReuseRegistry(), "indexreuse: no assembly while a page has no valid build")
        check(H.Search:RegistryIsStale(), "indexreuse: ...and the index is left stale for the real build")

        H.Search:BuildFullRegistry()
        H.switch("raid")
        H.switch("party")
        local before = H.total
        eq(H.Search:EnsureRegistryAsync(function() check(false, "indexreuse: no waiter for an assembled index") end),
           "ready", "indexreuse: an index assembled from builds is ready at once")
        RunAllFrames()
        eq(H.total, before, "indexreuse: ...and built nothing")
        check(not H.Search.RegistryBuilding, "indexreuse: ...and nothing is in flight")
    end

    -- ============================================================
    -- 4. WHAT MAKES A BUILD UNUSABLE
    -- ============================================================
    do
        local H = NewHost()
        local a = H.page("page_a", { "keyA" }, true)
        local b = H.page("page_b", { "keyB" })
        a:RefreshCached()
        H.Search:BuildFullRegistry()                     -- builds b

        -- Invalidate: that page only.
        b:Invalidate()
        H.Search:InvalidateRegistry()
        H.Search:BuildFullRegistry()
        eq(H.builds.page_b, 2, "indexreuse: an invalidated page is built for the index")
        eq(H.builds.page_a, 1, "indexreuse: ...and only that page")

        -- A replaced mode table.
        H.DF.db.party = { mode = "party" }
        H.Search:InvalidateRegistry()
        H.Search:BuildFullRegistry()
        eq(H.builds.page_a, 2, "indexreuse: a build bound to a replaced mode table is not indexed")
        eq(H.builds.page_b, 3, "indexreuse: ...on any page")

        -- A page whose disabled state flipped.
        H.GUI.disabled.page_b = true
        H.Search:InvalidateRegistry()
        H.Search:BuildFullRegistry()
        eq(H.builds.page_b, 3, "indexreuse: a disabled page builds its banner, not its builder")
        eq(#entriesFor(H.Search, "page_b"), 0, "indexreuse: ...and indexes nothing")
        H.Search:InvalidateRegistry()
        H.Search:BuildFullRegistry()
        eq(#entriesFor(H.Search, "page_b"), 0, "indexreuse: the banner build is reused as indexing nothing")

        -- A page with a content cache key is never taken from a build.
        H.GUI.PageCacheKeys = { page_a = function() return "k" end }
        H.Search:InvalidateRegistry()
        H.Search:BuildFullRegistry()
        eq(H.builds.page_a, 3, "indexreuse: a page with a content cache key is always built")
    end

    -- ============================================================
    -- 5. ENTRIES ARE STAMPED WITH THEIR OWN PAGE, WHOEVER BUILT IT
    -- ============================================================
    do
        local H = NewHost()
        local a = H.page("page_a", { "keyA" }, true)
        H.page("page_b", { "keyB" })
        H.Search:BuildFullRegistry()                     -- index leaves CurrentTab on its last page
        H.Search:SetCurrentTab("somewhere_else", "Elsewhere")
        a:Refresh()                                      -- a setting's callback rebuilding the page
        eq(H.Search.CurrentTab, "somewhere_else", "indexreuse: a build puts Search's current tab back")
        H.Search:InvalidateRegistry()
        H.Search:BuildFullRegistry()
        local en = entriesFor(H.Search, "page_a")[1]
        check(en ~= nil, "indexreuse: a page rebuilt outside the index is stamped with its own tab")
        eq(en and en.tabLabel, "page_a_label", "indexreuse: ...and its own label")
        eq(#entriesFor(H.Search, "somewhere_else"), 0, "indexreuse: ...not whatever tab was current")
    end

    -- ============================================================
    -- 6. THE BUDGETED DRIVER REUSES TOO
    -- ============================================================
    do
        local H = NewHost()
        H.page("page_a", { "keyA" }, true):RefreshCached()
        H.page("page_b", { "keyB" })
        local done
        H.Search:BuildFullRegistryBudgeted(function(ok) done = ok end)
        RunAllFrames()
        check(done, "indexreuse: the budgeted build completes")
        eq(H.builds.page_a, 1, "indexreuse: the budgeted build takes the valid build")
        eq(H.builds.page_b, 1, "indexreuse: ...and builds the page without one")
        eq(#H.Search.Registry, 2, "indexreuse: ...indexing both")
    end

    -- ============================================================
    -- 7. THE OPTED-OUT PAGES FOLLOW RefreshCached
    -- ============================================================
    do
        local H = NewHost()
        local a = H.page("page_a", { "keyA" }, true)
        a.singleModeBuild = true
        a:RefreshCached()
        H.Search:BuildFullRegistry()
        eq(H.builds.page_a, 1, "indexreuse: a one-build page with a valid build is indexed from it")
        H.switch("raid")
        H.Search:EnsureRegistry()
        eq(H.builds.page_a, 2, "indexreuse: ...and rebuilt in the mode it was not built for")
    end
end

-- ============================================================
-- 8. ChangedSettings' cache key does not read "stale" after a switch
-- ============================================================
do
    local cs = options_file_source("Features/ChangedSettings.lua")
    local body = cs:match("function ChangedSettings:CacheKey%(GUI%)(.-)\nend")
    check(body ~= nil, "indexreuse: ChangedSettings:CacheKey is found")
    if body then
        local reuse = body:find("Search:TryReuseRegistry()", 1, true)
        local stale = body:find("Search:RegistryIsStale()", 1, true)
        check(reuse and stale and reuse < stale,
              "indexreuse: the ledger's cache key re-assembles the index from retained builds before calling it stale")
    end
end

DandersFrames, C_Timer, debugprofilestop, CreateFrame =
    savedDF, savedTimer, savedProfile, savedCreateFrame
