local NS = ...

-- ============================================================
-- THE SEARCH REGISTRY BUILD -- SYNCHRONOUS AND BUDGETED
-- ------------------------------------------------------------
-- Building the settings index means re-running EVERY page's builder. Doing all
-- ~34 of them inside one execution is what "the Changed Settings page lags like
-- crazy when opening" was: the ledger asks for the registry from inside its own
-- page build, so the whole index landed in the frame that drew the page.
--
-- Features/Search.lua now decomposes a build into one step per page and drives
-- that list two ways -- all at once (BuildFullRegistry, the unchanged contract)
-- or a slice per frame (BuildFullRegistryBudgeted). This file drives the REAL
-- file against a stub GUI and a hand-cranked C_Timer, so a slice boundary is a
-- thing the test decides rather than a thing it hopes for.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME. This file swaps the `DandersFrames`
-- global, C_Timer and debugprofilestop; all three are restored at the end.
-- ============================================================

local savedDF, savedTimer, savedProfile = DandersFrames, C_Timer, debugprofilestop

-- ---- the fake clock and the fake frame queue -------------------------
-- debugprofilestop is what the drain measures its budget against, so the test
-- owns it: `CLOCK` only moves when a step moves it, which makes "this step blew
-- the budget" an assertion instead of a race against the machine.
local CLOCK = 0
debugprofilestop = function() return CLOCK end

-- C_Timer.After(0, fn) queues; nothing runs until RunFrame() says so. One
-- RunFrame is one game frame: it drains exactly the callbacks that were pending
-- when it started, so a continuation queued by this frame lands on the next.
local pending = {}
C_Timer = {
    After = function(_, fn) pending[#pending + 1] = fn end,
    NewTimer = function(_, fn) return { Cancel = function() end, _fn = fn } end,
}
local function RunFrame()
    local batch = pending
    pending = {}
    for _, fn in ipairs(batch) do fn() end
    return #batch
end
local function RunAllFrames(limit)
    local frames = 0
    while #pending > 0 and frames < (limit or 200) do
        RunFrame()
        frames = frames + 1
    end
    return frames
end

-- ---- one loadable copy of Search.lua, with a stub host ---------------
-- Search.lua takes its host off the `DandersFrames` GLOBAL and reads
-- DF.GUI.SettingsBox at FILE SCOPE, so the stub has to be complete and in place
-- before the load. The geometry numbers are inert here (nothing in this file
-- lays out a result card); they only have to exist.
local function NewHost()
    local DF = {}
    DF.L = setmetatable({}, { __index = function(_, k) return k end })
    -- ⚠ ONE REAL KEY, because Search:Register drops any entry whose dbKey is not
    -- in the current mode's defaults -- and an EMPTY registry counts as stale
    -- (RegistryIsStale checks #Registry), so a page that registers nothing can
    -- never leave the build looking finished.
    DF.PartyDefaults = { fakeKey = 0 }
    DF.RaidDefaults  = { fakeKey = 0 }
    function DF:DebugWarn() end

    local rec = { parked = {}, adopted = {}, built = {} }
    local GUI = {
        SelectedMode    = "party",
        CurrentPageName = "general_frame",
        Pages           = {},
        SettingsBox     = { pad = 10, group = 280, colMargin = 15, minCol = 290, colGutter = 20 },
    }
    function GUI:ParkPage(page)  rec.parked[#rec.parked + 1] = page.tabName end
    function GUI:AdoptPage(page) rec.adopted[#rec.adopted + 1] = page.tabName end
    DF.GUI = GUI

    function rec.page(name, shown)
        local p = { tabName = name, tabLabel = name, _shown = shown or false, builds = 0 }
        function p:IsShown() return self._shown end
        function p:Show() self._shown = true end
        function p:Hide() self._shown = false end
        function p:Refresh()
            self.builds = self.builds + 1
            rec.built[#rec.built + 1] = self.tabName
            -- A page builder's whole job here is to register, so the fake one
            -- does too -- see the defaults note above for why an empty registry
            -- would never read as built.
            if DF.Search then
                DF.Search:Register({ label = self.tabName, dbKey = "fakeKey" })
            end
            -- Every page costs the same fake millisecond, so "how many pages fit
            -- in one slice" is arithmetic rather than luck.
            CLOCK = CLOCK + (rec.msPerPage or 0)
        end
        function p:RefreshStates() end
        GUI.Pages[name] = p
        return p
    end

    DandersFrames = DF
    load_options_file_into("Features/Search.lua", NS)
    DandersFrames = savedDF
    return DF, GUI, rec
end

-- ============================================================
-- 1. THE SYNCHRONOUS DRIVER IS UNCHANGED
-- ============================================================
do
    local DF, GUI, rec = NewHost()
    local Search = DF.Search
    check(Search ~= nil, "registry: the file publishes DF.Search")

    rec.page("general_frame", true)
    rec.page("general_settings", false)
    rec.page("auras_buffs", false)

    Search:BuildFullRegistry()

    eq(#rec.built, 3, "sync: every page is built, in one call")
    eq(#rec.parked, 2, "sync: ...and the two that were hidden go back in the dock")
    eq(#rec.adopted, 1, "sync: exactly one page is adopted back")
    eq(rec.adopted[1], "general_frame", "sync: ...the one on screen")
    check(Search.RegistryBuilt, "sync: the registry is marked built")
    check(not Search.RegistryBuilding, "sync: ...and nothing is left in flight")
    check(not Search:RegistryIsStale() or #Search.Registry == 0,
          "sync: a built registry for the current mode is not stale")
end

-- ============================================================
-- 2. THE BUDGETED DRIVER: NOTHING IN THE CALLER'S EXECUTION
-- ------------------------------------------------------------
-- The whole point. A caller that asked for a build has spent no time on it when
-- the call returns -- not one page. This is the assertion the ledger's hitch was
-- the absence of.
-- ============================================================
do
    local DF, GUI, rec = NewHost()
    local Search = DF.Search
    rec.msPerPage = 0

    rec.page("general_frame", true)
    for i = 1, 5 do rec.page("page_" .. i, false) end

    local done = 0
    Search:BuildFullRegistryBudgeted(function(ok) done = done + (ok and 1 or 0) end)

    eq(#rec.built, 0, "budgeted: not one page is built inside the call itself")
    check(Search.RegistryBuilding, "budgeted: ...but the build is marked in flight")
    check(not Search.RegistryBuilt, "budgeted: ...and the registry is not usable yet")

    -- No step exceeds the budget, so the whole list drains in the first slice.
    eq(RunFrame(), 1, "budgeted: exactly one continuation was queued")
    eq(#rec.built, 6, "budgeted: the first slice built every page (none blew the budget)")
    check(Search.RegistryBuilt, "budgeted: the registry is built")
    check(not Search.RegistryBuilding, "budgeted: ...and nothing is in flight")
    eq(done, 1, "budgeted: the completion callback fired exactly once")
    eq(#rec.adopted, 1, "budgeted: the page on screen is adopted back, as in the sync path")
end

-- ============================================================
-- 3. THE BUDGET ACTUALLY SPLITS THE WORK
-- ------------------------------------------------------------
-- With each page costing 3ms against a 4ms budget, no slice may carry more than
-- two pages: the drain runs a step, THEN checks the deadline, so it always
-- overshoots by at most one step -- which is the correct shape (checking first
-- would make a budget smaller than one step deadlock).
-- ============================================================
do
    local DF, GUI, rec = NewHost()
    local Search = DF.Search
    rec.msPerPage = 3

    rec.page("general_frame", true)
    for i = 1, 5 do rec.page("page_" .. i, false) end

    local slices = 0
    Search:BuildFullRegistryBudgeted(nil, 4)   -- 4ms budget, 3ms per page

    local perSlice = {}
    while #pending > 0 and slices < 50 do
        local before = #rec.built
        RunFrame()
        slices = slices + 1
        perSlice[#perSlice + 1] = #rec.built - before
    end

    eq(#rec.built, 6, "split: every page is still built exactly once")
    check(slices > 1, "split: ...across more than one frame")
    for i, n in ipairs(perSlice) do
        check(n <= 2, "split: no slice carried more than the budget allows (slice " .. i .. ")")
    end
    check(Search.RegistryBuilt, "split: and the registry lands built")
end

-- ============================================================
-- 4. AN INVALIDATION MID-DRAIN ABORTS THE BUILD
-- ------------------------------------------------------------
-- ☠ THE ONE THAT WOULD CORRUPT DATA. InvalidateRegistry is what the party/raid
-- buttons call, and Search:Register filters by the CURRENT mode -- so a
-- continuation that carried on after a mode switch would append raid-mode pages
-- to a registry whose first half is party. The token check is the abort.
-- ============================================================
do
    local DF, GUI, rec = NewHost()
    local Search = DF.Search
    rec.msPerPage = 3

    rec.page("general_frame", true)
    for i = 1, 5 do rec.page("page_" .. i, false) end

    local done = 0
    Search:BuildFullRegistryBudgeted(function() done = done + 1 end)
    RunFrame()                              -- one slice lands
    local partial = #rec.built
    check(partial > 0 and partial < 6, "abort: the build is genuinely part-done")

    Search:InvalidateRegistry()
    check(not Search.RegistryBuilding, "abort: invalidating clears the in-flight flag")

    RunAllFrames()
    eq(#rec.built, partial, "abort: not one more page is built after the invalidation")
    check(not Search.RegistryBuilt, "abort: ...and the registry is never marked built")
    eq(done, 0, "abort: the completion callback never fires for a build nobody wants")
end

-- ============================================================
-- 5. EnsureRegistryAsync: ONE BUILD, MANY WAITERS
-- ------------------------------------------------------------
-- The ledger page and the search box can both ask on the same frame. Two builds
-- would be twice the work AND would have the second one reset the array the
-- first was half-way through filling.
-- ============================================================
do
    local DF, GUI, rec = NewHost()
    local Search = DF.Search
    rec.msPerPage = 3

    rec.page("general_frame", true)
    for i = 1, 5 do rec.page("page_" .. i, false) end

    local fired = {}
    local a = Search:EnsureRegistryAsync(function(ok) fired[#fired + 1] = "a" .. tostring(ok) end)
    local b = Search:EnsureRegistryAsync(function(ok) fired[#fired + 1] = "b" .. tostring(ok) end)
    eq(a, "building", "waiters: the first ask reports a build under way")
    eq(b, "building", "waiters: ...and so does the second")

    RunAllFrames()
    eq(#rec.built, 6, "waiters: every page built exactly once, not twice")
    eq(#fired, 2, "waiters: both waiters were told")
    eq(fired[1], "atrue", "waiters: ...in the order they asked")
    eq(fired[2], "btrue", "waiters: ...both with the build's result")

    -- A ready registry answers immediately and does NOT call the waiter: the
    -- caller is already standing in the moment it was waiting for.
    local extra = 0
    eq(Search:EnsureRegistryAsync(function() extra = extra + 1 end), "ready",
       "waiters: a built registry answers ready")
    RunAllFrames()
    eq(extra, 0, "waiters: ...and does not call back")
end

-- ============================================================
-- 6. NO WAITER RUNS INSIDE THE BUILD'S OWN EXECUTION
-- ------------------------------------------------------------
-- A waiter is "rebuild the surface that was waiting for this", and every one of
-- them can reach back into the search or the ledger. Running one from inside the
-- pass that just rebuilt every page is exactly the re-entrancy skipSearchIndex
-- exists to prevent, so the flush is always deferred a frame -- including on the
-- synchronous driver, so a caller never has to know which one it took.
-- ============================================================
do
    local DF, GUI, rec = NewHost()
    local Search = DF.Search

    rec.page("general_frame", true)
    rec.page("page_1", false)

    local fired = false
    Search:EnsureRegistryAsync(function() fired = true end)
    RunFrame()                              -- the build's slice
    check(Search.RegistryBuilt, "defer: the registry is built after its slice")
    check(not fired, "defer: ...but the waiter has not run in that same execution")
    RunFrame()
    check(fired, "defer: it runs on the next frame")
end

-- ============================================================
-- 7. A PAGE THAT ERRORS DOES NOT STRAND THE REST OF THE BUILD
-- ------------------------------------------------------------
-- An async chain that died mid-way would silently lose every later page AND the
-- completion callback -- so the error goes to the standard handler and the chain
-- continues. Both drivers, same rule.
-- ============================================================
do
    local DF, GUI, rec = NewHost()
    local Search = DF.Search

    rec.page("general_frame", true)
    local bad = rec.page("page_bad", false)
    function bad:Refresh() error("page blew up") end
    rec.page("page_after", false)

    local seen = {}
    local savedHandler = geterrorhandler
    geterrorhandler = function() return function(err) seen[#seen + 1] = err end end

    local done = 0
    Search:BuildFullRegistryBudgeted(function(ok) done = done + (ok and 1 or 0) end)
    RunAllFrames()
    geterrorhandler = savedHandler

    eq(#seen, 1, "error: the failing page's error reached the handler")
    eq(#rec.built, 2, "error: the other two pages were still built")
    check(Search.RegistryBuilt, "error: the build still completes")
    eq(done, 1, "error: ...and the completion callback still fires")
end

-- ============================================================
-- 8. THE PAGE ADOPTED BACK IS THE ONE ON SCREEN *NOW*
-- ------------------------------------------------------------
-- A budgeted build takes several frames and the user can change tabs inside
-- them. Re-showing the page they navigated AWAY from would be the window
-- changing itself under them a second after they clicked, so the tail reads
-- CurrentPageName at the end rather than replaying the one it started with.
-- ============================================================
do
    local DF, GUI, rec = NewHost()
    local Search = DF.Search
    rec.msPerPage = 3

    rec.page("general_frame", true)
    local later = rec.page("general_settings", false)
    for i = 1, 4 do rec.page("page_" .. i, false) end

    Search:BuildFullRegistryBudgeted()
    RunFrame()                              -- part-done

    -- The user switches tabs mid-build, exactly as SelectTab leaves things.
    GUI.Pages["general_frame"]:Hide()
    later:Show()
    GUI.CurrentPageName = "general_settings"

    RunAllFrames()
    eq(rec.adopted[#rec.adopted], "general_settings",
       "midswitch: the page adopted back is the one the user is looking at now")
    check(later:IsShown(), "midswitch: ...and it is left shown")
end

-- ============================================================
-- 9. skipSearchIndex STILL OPTS A PAGE OUT, ON BOTH DRIVERS
-- ------------------------------------------------------------
-- The ledger sets it, and the reason is recursion: that page BUILDS ITSELF from
-- this registry. Decomposing the build into steps must not have quietly dropped
-- the check into only one of the two paths.
-- ============================================================
do
    for _, mode in ipairs({ "sync", "budgeted" }) do
        local DF, GUI, rec = NewHost()
        local Search = DF.Search

        rec.page("general_frame", true)
        local out = rec.page("profiles_changed", false)
        out.skipSearchIndex = true

        if mode == "sync" then
            Search:BuildFullRegistry()
        else
            Search:BuildFullRegistryBudgeted()
            RunAllFrames()
        end

        eq(out.builds, 0, "optout: a skipSearchIndex page is never refreshed (" .. mode .. ")")
        eq(#rec.parked, 0, "optout: ...and never parked (" .. mode .. ")")
        check(Search.RegistryBuilt, "optout: the build still completes (" .. mode .. ")")
    end
end

-- Everything this file swapped, put back -- one runtime serves every suite.
DandersFrames, C_Timer, debugprofilestop = savedDF, savedTimer, savedProfile
