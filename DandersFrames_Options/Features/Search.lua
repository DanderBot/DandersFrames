-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames

-- ============================================================
-- DANDERSFRAMES SEARCH SYSTEM
-- Provides searchable settings with inline editable results
-- ============================================================

local Search = {}
DF.Search = Search

local L = DF.L

-- ============================================================
-- UI CONSTANTS (match GUI styling)
-- ============================================================
local C_BACKGROUND = {r = 0.11, g = 0.11, b = 0.11, a = 0.98}
local C_BORDER     = {r = 0, g = 0, b = 0, a = 1}
local C_ACCENT     = {r = 0.2, g = 0.6, b = 1.0, a = 1}
local C_RAID       = {r = 1.0, g = 0.4, b = 0.2, a = 1}

-- Result-card geometry. The control's own height is NOT here on purpose -- it
-- comes from the widget's preferredHeight (GUI.RowHeight owns that slot). These
-- are only the card's own chrome: the breadcrumb strip above the control, and
-- the padding around it.
-- ★ READ, NOT COPIED. Every number in this block used to be a literal justified by a
-- comment that said where the original lived ("280 is what GUI:CreateSettingsGroup
-- builds", "copied from the page layout rather than invented"). A comment is not a link:
-- it goes on claiming to mirror the page after the page has moved. They now come off
-- GUI.SettingsBox, which is the ONE declaration the page layout and CreateSettingsGroup
-- read too.
local SETTINGS_BOX = DF.GUI.SettingsBox

local CARD_PAD_X     = SETTINGS_BOX.pad
local CARD_CONTENT_Y = 28   -- top of the control, below the breadcrumb button
local CARD_CHROME    = 38   -- breadcrumb strip + top and bottom padding

-- ★ A RESULT CARD IS A SETTINGS BOX, so it is exactly as wide as one -- the same
-- SettingsBox.group that CreateSettingsGroup builds, with the same SettingsBox.pad
-- inset, so the control inside a card lands on exactly GUI:GroupInnerWidth. A search hit
-- is therefore the same size as the thing it takes you to, by construction.
--
-- The results panel spans the whole content area (about two of these side by side), and
-- letting a card have all of it was the problem: a slider stretched across the full width
-- reads as a different control from the same slider on its page.
local CARD_MAX_W = SETTINGS_BOX.group

-- ★ COLUMN GEOMETRY. GUI/Panel.lua's page layout does exactly this: column 1 at
-- x = colMargin, column 2 pinned to floor(width / 2), and it drops to one column below
-- `minCol * 2 + colGutter`.
--
-- ☠ THE COLUMNS DO NOT STRETCH -- THE GAP DOES. That is the part worth stating, because
-- it is the opposite of the obvious guess. A settings group keeps its constructed width
-- (the page only ever calls SetWidth on INDENTED widgets, via defaultColWidth), so
-- pinning column 2 to the halfway mark means the gutter is floor(width/2) - minCol and
-- therefore WIDENS as the window widens. A fixed gutter with stretching cards looks wrong
-- next to every real page, which is what the first attempt here did.
--
-- minCol deliberately exceeds the card width so the layout collapses to one column BEFORE
-- the columns touch, leaving a small gutter at the cutover instead of overlapping for the
-- last few pixels.
local COL_LEFT  = SETTINGS_BOX.colMargin
local MIN_COL_W = SETTINGS_BOX.minCol

-- Debounce before a keystroke turns into a rebuild. Every result is a real settings
-- widget, so an un-debounced OnTextChanged built the whole result set once PER LETTER --
-- typing "frame" meant five full builds of ~159 cards.
local SEARCH_DEBOUNCE = 0.25

-- The empty-results prompt. A function, not a constant: L is populated at load
-- and this file's locals are evaluated then too, so reading it lazily keeps the
-- string correct if the locale table is finished after this file runs.
local function EmptyMessage()
    return L["No settings found.\nTry different keywords."]
end

local function GetThemeColor()
    -- Follow the active mode theme (party purple / raid orange) so the whole
    -- search surface matches the rest of the GUI. Search used to pin its own blue
    -- on the sliders, dropdowns and breadcrumb while the header followed the
    -- theme; that half-and-half state read as a bug rather than as identity, so
    -- the controls now inherit the theme like every other page (Krathe,
    -- 2026-08-07). C_ACCENT survives only as the party-side fallback below, for a
    -- GUI too early in its bootstrap to answer.
    if DF.GUI and DF.GUI.GetThemeColor then return DF.GUI.GetThemeColor() end
    if DF.GUI and DF.GUI.SelectedMode == "raid" then return C_RAID else return C_ACCENT end
end

local function CreateBackdrop(frame, bgAlpha)
    -- Delegates to the shared GUI backdrop so search chrome follows the rest of
    -- the addon (and inherits pixel-grid snapping). Only the alpha is local.
    DF.GUI:CreateElementBackdrop(frame, {
        inset       = 1,
        bgColor     = { C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b,
                        bgAlpha or C_BACKGROUND.a },
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, C_BORDER.a },
    })
end

-- ============================================================
-- SEARCH REGISTRY
-- ============================================================
Search.Registry = {}
Search.CurrentTab = nil
Search.CurrentSection = nil
Search.RegistryBuilt = false

-- ============================================================
-- CONTEXT TRACKING
-- ============================================================
function Search:SetCurrentTab(tabName, tabLabel)
    self.CurrentTab = tabName
    self.CurrentTabLabel = tabLabel
    self.CurrentSection = nil
end

function Search:SetCurrentSection(sectionName)
    self.CurrentSection = sectionName
end

-- ============================================================
-- REGISTRATION FUNCTIONS
-- Now stores all metadata needed to recreate widgets
-- ============================================================
local registrationId = 0

-- The keyword bag, from the three facts an entry carries: its own label, the
-- section it was registered under and the tab that section is on.
--
-- ★ EXTRACTED FROM Register SO SetEntrySection CAN RE-RUN IT. A section that is
-- corrected AFTER registration -- which is what a popout row does to everything
-- inside its pane -- would otherwise leave the OLD section's words sitting in
-- here, and those words SCORE (see Find's keyword pass, +40 a hit). Fixing the
-- breadcrumb while leaving "auras" matching every Tooltips control would be half
-- a fix. Verbatim from where it lived; the `or {}` on the label arm is what
-- callers that pass their own keywords rely on, and it is kept.
local function BuildKeywords(entry)
    if entry.label then
        entry.keywords = entry.keywords or {}
        for word in string.gmatch(entry.label:lower(), "%w+") do
            if #word > 2 then
                table.insert(entry.keywords, word)
            end
        end
    end

    if entry.section then
        for word in string.gmatch(entry.section:lower(), "%w+") do
            if #word > 2 then
                table.insert(entry.keywords, word)
            end
        end
    end

    if entry.tab then
        table.insert(entry.keywords, entry.tab:lower())
    end
end

-- ★ CORRECT AN ENTRY'S SECTION AFTER THE FACT, keywords and all.
--
-- ☠ WHY THIS EXISTS. `entry.section` is stamped from Search.CurrentSection at
-- registration, and CurrentSection is only ever moved by GUI:CreateHeader and
-- GUI:CreateCollapsibleSection (GUI/SettingsWidgets.lua). On a CLASSIC page the
-- two interleave with the controls -- header, its controls, next header -- so
-- every entry inherits the header directly above it and the stamp is right.
--
-- A POPOUT page does not build in that order. Its band headers are created UP
-- FRONT, and then every row's pane is built EAGERLY into a hidden holder, so
-- every control on the page registers while CurrentSection still holds whichever
-- band header was created LAST -- the whole Tooltips page reading "Auras", every
-- row on a page with no band header reading whatever the previous page left.
-- Position-dependent context cannot describe a page that no longer builds in
-- position order, so the ROW names its own contents afterwards instead
-- (GUI:CreatePopoutPageTools' ClaimKeys, GUI/Controls.lua).
--
-- Guarded on `entry.id`: Register hands back keyless entries, entries for the
-- other mode's defaults and everything offered after the registry was built
-- WITHOUT adding them to the Registry, and an id is the one mark that says the
-- entry is really in there. Re-sectioning an entry nothing can find would be a
-- write nobody reads.
function Search:SetEntrySection(entry, section)
    if type(entry) ~= "table" or not entry.id then return end
    if type(section) ~= "string" or section == "" then return end
    if entry.section == section then return end

    entry.section = section
    -- Rebuilt rather than appended to: the point is to LOSE the old section's
    -- words, which an append would keep.
    entry.keywords = {}
    BuildKeywords(entry)
end

function Search:Register(entry)
    if self.RegistryBuilt then
        return entry
    end

    -- ☠ A HOISTED CONTROL IS THE PANEL'S OWN SETTING SHOWN TWICE, AND SEARCH
    -- MUST NOT SHOW IT TWICE. A popout row may draw a second widget bound to the
    -- SAME table and key as one of the controls in its pane (GUI/Controls.lua's
    -- RegisterHoistedToggle, table form) so the commonly-changed settings are
    -- back on the plate. Every db-bound factory registers whatever it is handed,
    -- so without this the registry would carry two entries with one label, one
    -- key and one section -- two identical result cards for one setting.
    --
    -- Set and cleared by the caller AROUND the build, rather than a per-widget
    -- opt-out, because the widget being suppressed is built by the KIT, which
    -- has no search of its own to be told about.
    if self.SuppressRegistration then
        return entry
    end


    -- Allow registration if we have either a string dbKey OR a searchKey for custom widgets
    local hasValidKey = (entry.dbKey and type(entry.dbKey) == "string") or 
                        (entry.searchKey and type(entry.searchKey) == "string")
    
    if not hasValidKey then
        return entry
    end
    
    -- Get current mode and check if this setting exists in that mode's defaults
    local currentMode = DF.GUI and DF.GUI.SelectedMode or "party"
    local defaults = (currentMode == "raid") and DF.RaidDefaults or DF.PartyDefaults
    
    -- If entry has a dbKey, check if it exists in the current mode's defaults
    -- Skip settings that don't exist for the current mode
    if entry.dbKey and type(entry.dbKey) == "string" and defaults then
        if defaults[entry.dbKey] == nil then
            -- This setting doesn't exist in the current mode's defaults, skip it
            return entry
        end
    end
    
    -- Specific exceptions: settings that should only appear in one mode
    -- Add dbKeys here that should be excluded from search in the opposite mode
    local partyOnlySettings = {
        -- Settings that should only appear in party mode
    }
    local raidOnlySettings = {
        -- Settings that should only appear in raid mode
        ["hideBlizzardRaidFrames"] = true,
    }
    
    if currentMode == "party" and entry.dbKey and raidOnlySettings[entry.dbKey] then
        return entry
    end
    if currentMode == "raid" and entry.dbKey and partyOnlySettings[entry.dbKey] then
        return entry
    end
    
    registrationId = registrationId + 1
    entry.id = registrationId
    entry.tab = self.CurrentTab
    entry.tabLabel = self.CurrentTabLabel
    entry.section = self.CurrentSection or "General"
    -- Store the current mode (party/raid) for filtering search results
    entry.mode = currentMode
    
    -- Auto-generate keywords from the label, the section and the tab.
    BuildKeywords(entry)

    table.insert(self.Registry, entry)
    return entry
end

-- Link a page's widget to the search entry it registered.
--
-- Tooltips are the reason this exists. A page sets `container.tooltip` AFTER the
-- factory returns, so it cannot be captured at registration time -- but a live
-- reference can be, and CreateResultWidget reads `.tooltip` off it when it builds
-- the row. That keeps one source of truth: the result shows exactly the tooltip
-- the real setting shows, with nothing duplicated into the registry.
--
-- Safe against a nil searchEntry: registration returns early for keyless entries
-- and for anything registered after the registry was built.
function Search:LinkSourceWidget(container)
    if container and container.searchEntry then
        container.searchEntry.sourceWidget = container
    end
end

function Search:InvalidateRegistry()
    self.RegistryBuilt = false
    -- ☠ ...AND STOP A BUDGETED BUILD IN FLIGHT. Its remaining slices would go on
    -- appending pages to a registry nobody is asking for any more -- and on the
    -- caller that matters (the party/raid buttons in GUI/Panel.lua) those pages
    -- would be built for the OTHER mode than the ones already in the array. The
    -- token is the abort: the drain checks it before every slice.
    self._buildToken = (self._buildToken or 0) + 1
    self.RegistryBuilding = false
    -- The waiters go with it. Every one of them is "refresh the surface that was
    -- waiting for this", and each caller that invalidates is on its way to
    -- refresh that surface itself (the mode buttons run RefreshCurrentPage two
    -- lines later) -- so firing them would be a second refresh, not a missing one.
    self._buildWaiters = nil
end

function Search:RefreshIfActive()
    -- If search results are currently shown and there's a search query, refresh the results
    if self.ResultsPanel and self.ResultsPanel:IsShown() and self.SearchBar then
        local query = self.SearchBar.editbox:GetText()
        if query and query ~= "" then
            -- Don't refresh during combat
            if not InCombatLockdown() then
                self:ShowResults(query)
            end
        end
    end
end

-- Would EnsureRegistry actually build? True when the registry was never built,
-- is empty, or was built for the other mode.
--
-- ★ SPLIT OUT SO IT IS ASKED IN ONE PLACE. A caller that wants to know whether
-- a build is about to happen -- the changed-settings ledger, which refuses to
-- trigger one in combat -- would otherwise have to restate this condition, and
-- a restated condition is one that goes stale silently: it would keep answering
-- "cheap" after a fourth staleness rule was added here.
function Search:RegistryIsStale()
    local currentMode = DF.GUI and DF.GUI.SelectedMode or "party"
    return (not self.RegistryBuilt) or #self.Registry == 0 or self.BuiltForMode ~= currentMode
end

function Search:EnsureRegistry()
    if self:RegistryIsStale() then
        self:BuildFullRegistry()
    end
end

-- ============================================================
-- THE BUILD, IN SLICES
-- ------------------------------------------------------------
-- Building the registry means RE-RUNNING EVERY PAGE'S BUILDER -- ~34 of them,
-- 700-odd widgets -- and doing all of that inside ONE execution is what the
-- ledger's first open was paying for ("lags like crazy" in game). The work is
-- not removable: the index is built from the real builders precisely so it
-- cannot drift from what the pages show. What IS removable is the single frame.
--
-- So a build is decomposed into STEPS -- one page each -- and there are two
-- drivers over the same list:
--   * BuildFullRegistry          runs every step NOW. The unchanged contract,
--                                for any caller that needs an answer inside its
--                                own execution (Find, and every existing site).
--   * BuildFullRegistryBudgeted  spends at most REGISTRY_BUILD_BUDGET_MS per
--                                execution and re-queues the rest on the next
--                                frame, so no single frame carries more than a
--                                slice. The ledger and the search box use this.
--
-- ★ THE PATTERN IS ELLESMERE'S RunBudgeted (EllesmereUI.lua), and so are its
-- rules: nothing runs in the caller's own execution (the first slice is deferred
-- too, so a caller that already spent real budget never gets this stacked on
-- top); every step runs under pcall with the error routed to the standard
-- handler and the chain CONTINUING, because a build that died mid-way would
-- strand every later page AND the completion callback, which is worse than one
-- page's failure; and every continuation gets a fresh watchdog budget.
--
-- ☠ WHAT IT DOES NOT DO: cache a registry per mode. That was considered and it
-- is not safe here, because a registry entry is not pure data -- `entry.callback`
-- and `entry.values` are captured from the PAGE BUILDER at the moment it ran, in
-- the mode it ran in. The Pet Frames anchor dropdown is the standing proof: its
-- option labels are "Below Party" / "Below Raid" by mode and its callback is
-- `isRaidMode and <raid updater> or <party updater>` (GUI/Pages/Options.lua).
-- Handing a raid search result the party entry would show the wrong words and
-- run the wrong updater. `entry.sourceWidget` has the same problem from the
-- other end: it points at a widget the NEXT build retires. So a mode switch
-- still re-pays a full build -- it just no longer pays for it in one frame.
-- ============================================================

-- Milliseconds of CPU one slice may spend. Ellesmere's default, and for the same
-- reason: small enough that no single execution can approach the 12.1 script
-- watchdog on any machine at any page count.
local REGISTRY_BUILD_BUDGET_MS = 8

-- Reset the registry and produce the step list, or nil when there is nothing to
-- build against. Shared by both drivers so they cannot disagree about what a
-- build IS.
function Search:_BeginRegistryBuild()
    self.Registry = {}
    registrationId = 0

    if not DF.GUI or not DF.GUI.Pages then
        return nil
    end

    -- Store the mode we're building for
    self.BuiltForMode = DF.GUI.SelectedMode

    -- Bumped on every build AND by InvalidateRegistry, so a budgeted drain can
    -- tell "still mine" from "superseded" between slices.
    self._buildToken = (self._buildToken or 0) + 1

    local ctx = { token = self._buildToken, steps = {} }

    for tabName, page in pairs(DF.GUI.Pages) do
      -- ☠ A PAGE MAY OPT OUT, and one has to. The changed-settings ledger
      -- (GUI/Pages/Modules.lua) BUILDS ITSELF FROM THIS REGISTRY, so refreshing
      -- it from here is a call back into the thing that is half-built:
      -- unbounded recursion at best, and at one level deep still wrong, because
      -- a nested Refresh on a page resets its children list and strands the
      -- widgets the outer Refresh already placed. Skipping it entirely also
      -- keeps its rows out of the index, which is correct on its own terms -- a
      -- report of settings is not itself a setting.
      -- Deliberately page-agnostic: any page may set `skipSearchIndex`.
      if not page.skipSearchIndex then
        ctx.steps[#ctx.steps + 1] = function()
            self:SetCurrentTab(tabName, page.tabLabel or tabName)
            self.CurrentSection = nil

            local wasShown = page:IsShown()

            if page.Refresh then
                page:Refresh()
            end

            if not wasShown then
                page:Hide()
                -- ☠ AND PUT IT BACK IN THE PAGE DOCK. Indexing means BUILDING all 34
                -- pages, and leaving 700+ freshly-built widgets parented under the
                -- settings window -- hidden or not -- is what made every later open
                -- of it freeze the game for the best part of ten seconds. Hiding a
                -- page does not take it out of the subtree the engine walks;
                -- reparenting it does. See THE PAGE DOCK in GUI/Panel.lua.
                --
                -- ⚠ Parked pages keep their anchors to the content frame, so
                -- page:Refresh() above builds correctly on a page already in the
                -- dock (which, after the first tab switch, every page but one is).
                if DF.GUI.ParkPage then DF.GUI:ParkPage(page) end
            end
        end
      end
    end

    return ctx
end

-- The tail every completed build runs, whichever driver got it there.
function Search:_FinishRegistryBuild()
    -- ⚠ THE PAGE ON SCREEN NOW, not the one that was on screen when the build
    -- started. Under the synchronous driver those are the same name and this
    -- reads exactly as it always did; under the budgeted one the user can change
    -- tabs mid-drain, and re-showing the page they navigated AWAY from would be
    -- the window changing itself under them a second after they clicked.
    local currentTab = DF.GUI and DF.GUI.CurrentPageName
    if currentTab and DF.GUI.Pages[currentTab] then
        -- The page the user is actually looking at comes back out of the dock.
        -- It was never parked by the steps above (wasShown was true for it), so
        -- this is normally a no-op -- but it is the one page that MUST be
        -- adopted when this returns, so it is asserted rather than assumed.
        if DF.GUI.AdoptPage then DF.GUI:AdoptPage(DF.GUI.Pages[currentTab]) end
        DF.GUI.Pages[currentTab]:Show()
        if DF.GUI.Pages[currentTab].RefreshStates then
            DF.GUI.Pages[currentTab]:RefreshStates()
        end
    end

    self.RegistryBuilt = true
    self.RegistryBuilding = false
end

-- Whoever asked to be told when the registry was usable, told -- ALWAYS on a
-- later execution, never inside the build's own. A waiter is "rebuild the
-- surface that was waiting for this", and every one of them can reach back into
-- the search or the ledger; running that from inside the pass that just built
-- them is the re-entrancy the skipSearchIndex flag exists to prevent.
function Search:_FlushRegistryWaiters(ok)
    local waiters = self._buildWaiters
    self._buildWaiters = nil
    if not waiters then return end
    C_Timer.After(0, function()
        for _, fn in ipairs(waiters) do
            local pcOK, err = pcall(fn, ok)
            if not pcOK and err then geterrorhandler()(err) end
        end
    end)
end

function Search:BuildFullRegistry()
    local ctx = self:_BeginRegistryBuild()
    if not ctx then
        self.RegistryBuilding = false
        self:_FlushRegistryWaiters(false)
        return
    end

    for i = 1, #ctx.steps do
        local ok, err = pcall(ctx.steps[i])
        if not ok and err then geterrorhandler()(err) end
    end

    self:_FinishRegistryBuild()
    self:_FlushRegistryWaiters(true)
end

-- The same build, spread across frames. `onDone(ok)` fires once, on the
-- execution that finished the last slice; an ABORTED build (see the token check)
-- never calls it, because the thing it would report on no longer exists.
function Search:BuildFullRegistryBudgeted(onDone, msBudget)
    local ctx = self:_BeginRegistryBuild()
    if not ctx then
        self.RegistryBuilding = false
        -- Deferred even in the failure arm: "nothing runs in the caller's
        -- execution" has to hold on every path, or a caller has to know which
        -- one it took.
        if onDone then C_Timer.After(0, function() onDone(false) end) end
        return
    end

    self.RegistryBuilding = true

    local budget = msBudget or REGISTRY_BUILD_BUDGET_MS
    local i, n = 1, #ctx.steps

    local function drain()
        -- ☠ SUPERSEDED? STOP. A mode switch or any other InvalidateRegistry
        -- bumps the token; carrying on would append pages built under the new
        -- mode to a registry whose first half was built under the old one.
        if self._buildToken ~= ctx.token then return end

        local deadline = debugprofilestop() + budget
        while i <= n do
            local ok, err = pcall(ctx.steps[i])
            i = i + 1
            if not ok and err then geterrorhandler()(err) end
            if i <= n and debugprofilestop() > deadline then
                C_Timer.After(0, drain)
                return
            end
        end

        self:_FinishRegistryBuild()
        if onDone then onDone(true) end
    end

    C_Timer.After(0, drain)
end

-- Make sure the registry is being built, and be told when it is usable.
--
-- Returns "ready" when nothing had to be built -- and in that case `onReady` is
-- NOT called, because the caller is already standing in the moment it wanted.
-- Returns "building" otherwise; `onReady(ok)` lands on a later frame.
--
-- Several callers can wait on ONE build (the ledger page and the search box both
-- do), which is the other half of why this is not just "call the budgeted
-- builder": two surfaces asking at once must not start two builds.
function Search:EnsureRegistryAsync(onReady)
    if not self:RegistryIsStale() then return "ready" end

    if onReady then
        self._buildWaiters = self._buildWaiters or {}
        self._buildWaiters[#self._buildWaiters + 1] = onReady
    end

    if not self.RegistryBuilding then
        self:BuildFullRegistryBudgeted(function(ok)
            self:_FlushRegistryWaiters(ok)
        end)
    end

    return "building"
end

-- ============================================================
-- KEYWORD ALIASES
-- ============================================================
Search.KeywordAliases = {
    -- Transparency related
    ["transparency"] = {"alpha", "opacity", "fade"},
    ["alpha"] = {"transparency", "opacity", "fade"},
    ["opacity"] = {"alpha", "transparency", "fade"},
    ["fade"] = {"alpha", "transparency", "opacity"},
    
    -- Size related
    ["size"] = {"width", "height", "scale", "thickness"},
    ["big"] = {"scale", "size", "large"},
    ["small"] = {"scale", "size"},
    
    -- Position related
    ["position"] = {"anchor", "offset", "location"},
    ["move"] = {"position", "anchor", "offset"},
    ["location"] = {"position", "anchor"},
    
    -- Color related
    ["color"] = {"colour", "rgb", "tint"},
    ["colour"] = {"color", "rgb", "tint"},
    
    -- Text related
    ["text"] = {"font", "label"},
    ["font"] = {"text", "typeface"},
    
    -- Visibility related
    ["hide"] = {"show", "visible", "hidden", "display"},
    ["show"] = {"hide", "visible", "display"},
    ["visible"] = {"hide", "show", "hidden"},
    
    -- Bar related
    ["bar"] = {"health", "resource", "power", "absorb"},
    ["health"] = {"hp", "life"},
    
    -- Icon related (NOTE: buff and debuff are NOT aliases of each other)
    ["icon"] = {"aura", "role", "leader"},
    ["aura"] = {"icon"},
    
    -- Frame related
    ["frame"] = {"unit", "party", "raid", "layout"},
    ["unit"] = {"frame", "player", "target"},
    
    -- Group label related
    ["label"] = {"group", "text", "number"},
    ["group"] = {"raid", "label"},
}

-- ============================================================
-- WORD STEMMING
-- Strips common suffixes so "buff" matches "buffs" equally
-- ============================================================
function Search:StemWord(word)
    if not word or #word < 3 then return word end
    
    word = word:lower()
    
    -- Remove common plural/verb suffixes
    -- Order matters - check longer suffixes first
    if word:sub(-3) == "ies" and #word > 4 then
        return word:sub(1, -4) .. "y"  -- "entries" -> "entry"
    elseif word:sub(-2) == "es" and #word > 3 then
        local stem = word:sub(1, -3)
        -- Handle cases like "boxes" -> "box", "classes" -> "class"
        if word:sub(-3, -3):match("[sxz]") or word:sub(-4, -3) == "ch" or word:sub(-4, -3) == "sh" then
            return stem
        end
        return word:sub(1, -2)  -- Just remove 's' for other cases
    elseif word:sub(-1) == "s" and #word > 3 and not word:sub(-2, -2):match("[su]") then
        return word:sub(1, -2)  -- "buffs" -> "buff", but not "class" -> "clas"
    elseif word:sub(-3) == "ing" and #word > 5 then
        return word:sub(1, -4)  -- "scaling" -> "scal"
    elseif word:sub(-2) == "ed" and #word > 4 then
        return word:sub(1, -3)  -- "enabled" -> "enabl"
    end
    
    return word
end

-- Check if two words match (considering stemming)
function Search:WordsMatch(word1, word2)
    if not word1 or not word2 then return false end
    
    word1 = word1:lower()
    word2 = word2:lower()
    
    -- Direct match
    if word1 == word2 then return true end
    
    -- Stemmed match
    local stem1 = self:StemWord(word1)
    local stem2 = self:StemWord(word2)
    
    if stem1 == stem2 then return true end
    
    -- One contains the other's stem (for partial matching)
    if stem1:find(stem2, 1, true) or stem2:find(stem1, 1, true) then
        return true
    end
    
    return false
end

-- Check if a word appears in text (with stemming support)
-- Returns: found (bool), isWholeWord (bool), isPartOfAnotherWord (bool)
function Search:WordInText(word, text)
    if not word or not text then return false, false, false end
    
    word = word:lower()
    text = text:lower()
    local stemmedWord = self:StemWord(word)
    
    -- First, check each word in the text individually
    for textWord in text:gmatch("%w+") do
        local stemmedTextWord = self:StemWord(textWord)
        
        -- Exact match or stemmed match of a whole word
        if textWord == word or stemmedTextWord == stemmedWord then
            return true, true, false
        end
        
        -- Check if search word is contained WITHIN this text word (e.g., "buff" in "debuff")
        -- This is a partial match and should be penalized
        if #textWord > #word and textWord:find(word, 1, true) then
            -- It's a substring of a larger word - this is NOT a good match
            -- "buff" found in "debuff" should return found=true, isWholeWord=false, isPartOfAnotherWord=true
            return true, false, true
        end
    end
    
    return false, false, false
end

-- ============================================================
-- SEARCH FUNCTION
-- Improved scoring: exact matches >> partial matches >> aliases
-- Now with stemming support
-- ============================================================
function Search:Find(query)
    if not query or query == "" then return {} end
    
    self:EnsureRegistry()
    
    query = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if #query < 2 then return {} end
    
    local results = {}
    local queryWords = {}
    local queryWordsStemmed = {}
    local numQueryWords = 0
    
    -- Split query into individual words and their stems
    for word in string.gmatch(query, "%w+") do
        table.insert(queryWords, word)
        table.insert(queryWordsStemmed, self:StemWord(word))
        numQueryWords = numQueryWords + 1
    end
    
    -- Build expanded query with aliases (but track which are exact vs aliases)
    local exactWords = {}      -- Words the user actually typed (and stems)
    local aliasWords = {}      -- Words added via aliases (lower priority)
    
    for i, word in ipairs(queryWords) do
        exactWords[word] = true
        exactWords[queryWordsStemmed[i]] = true  -- Also add stemmed version
        
        if self.KeywordAliases[word] then
            for _, alias in ipairs(self.KeywordAliases[word]) do
                if not exactWords[alias] then
                    aliasWords[alias] = true
                end
            end
        end
        -- Check aliases for stemmed word too
        if self.KeywordAliases[queryWordsStemmed[i]] then
            for _, alias in ipairs(self.KeywordAliases[queryWordsStemmed[i]]) do
                if not exactWords[alias] then
                    aliasWords[alias] = true
                end
            end
        end
    end
    
    for _, entry in ipairs(self.Registry) do
        -- All entries in registry are for the current mode (registry is rebuilt when mode changes)
        local score = 0
        local exactWordsMatched = 0
        
        local labelLower = entry.label and entry.label:lower() or ""
        local sectionLower = entry.section and entry.section:lower() or ""
        local dbKeyLower = (entry.dbKey and type(entry.dbKey) == "string") and entry.dbKey:lower() or ""
        
        -- ===========================================
        -- HIGHEST PRIORITY: Full query match in label
        -- "buff scale" found exactly in "Buff Scale" = huge bonus
        -- ===========================================
        if labelLower:find(query, 1, true) then
            score = score + 1000
            exactWordsMatched = numQueryWords
        else
            -- ===========================================
            -- Check each query word against the label
            -- ===========================================
            for i, word in ipairs(queryWords) do
                local found, isWholeWord, isPartOfAnotherWord = self:WordInText(word, labelLower)
                
                if found then
                    if isPartOfAnotherWord then
                        -- "buff" found inside "debuff" - very low score, almost a non-match
                        score = score + 5
                    elseif isWholeWord or #word >= 4 then
                        score = score + 200
                        exactWordsMatched = exactWordsMatched + 1
                    else
                        score = score + 100
                        exactWordsMatched = exactWordsMatched + 1
                    end
                end
            end
            
            -- ===========================================
            -- Lower priority: Alias word matches in label
            -- ===========================================
            for word in pairs(aliasWords) do
                local found, isWholeWord, isPartOfAnotherWord = self:WordInText(word, labelLower)
                if found and not isPartOfAnotherWord then
                    score = score + 30
                end
            end
        end
        
        -- ===========================================
        -- BONUS: Multiple query words matched = more relevant
        -- ===========================================
        if numQueryWords > 1 and exactWordsMatched >= numQueryWords then
            score = score + 500
        elseif numQueryWords > 1 and exactWordsMatched > 1 then
            score = score + (exactWordsMatched * 100)
        end
        
        -- ===========================================
        -- MEDIUM PRIORITY: Section name matches
        -- ===========================================
        for _, word in ipairs(queryWords) do
            local found, isWholeWord, isPartOfAnotherWord = self:WordInText(word, sectionLower)
            if found and not isPartOfAnotherWord then
                score = score + 50
            elseif found and isPartOfAnotherWord then
                score = score + 5  -- Minimal score for partial match
            end
        end
        
        -- ===========================================
        -- LOWER PRIORITY: Keyword matches
        -- ===========================================
        if entry.keywords then
            for _, keyword in ipairs(entry.keywords) do
                for _, word in ipairs(queryWords) do
                    if self:WordsMatch(keyword, word) then
                        score = score + 40
                    elseif keyword:find(word, 1, true) and #keyword > #word then
                        -- Word is substring of keyword - low score
                        score = score + 5
                    end
                end
                for alias in pairs(aliasWords) do
                    if self:WordsMatch(keyword, alias) then
                        score = score + 10
                    end
                end
            end
        end
        
        -- ===========================================
        -- LOWEST PRIORITY: dbKey matches
        -- ===========================================
        if dbKeyLower ~= "" then
            for _, word in ipairs(queryWords) do
                if dbKeyLower:find(word, 1, true) then
                    score = score + 25
                end
            end
        end
        
        if score > 0 then
            table.insert(results, {entry = entry, score = score})
        end
    end
    
    table.sort(results, function(a, b) return a.score > b.score end)
    
    local finalResults = {}
    for _, result in ipairs(results) do
        table.insert(finalResults, result.entry)
    end
    
    return finalResults
end

-- ============================================================
-- INLINE WIDGET FACTORIES
-- Create actual editable widgets in search results
-- ============================================================

function Search:CreateInlineCheckbox(parent, entry)
    -- A custom checkbox has no dbKey to bind, so there is nothing for the shared
    -- builder to drive -- show the label and point at the real page instead.
    if entry.isCustom or not entry.dbKey then
        local container = CreateFrame("Frame", nil, parent)
        container:SetSize(340, 30)
        container.preferredHeight = DF.GUI.RowHeight.checkbox

        local text = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        text:SetPoint("LEFT", 0, 0)
        text:SetText(entry.label)
        local ct = DF.GUI.Colors.text
        text:SetTextColor(ct.r, ct.g, ct.b)

        local note = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        note:SetPoint("LEFT", text, "RIGHT", 10, 0)
        note:SetText(L["(click header to edit)"])
        local cd = DF.GUI.Colors.textDim
        note:SetTextColor(cd.r, cd.g, cd.b)

        return container
    end

    -- Delegate to the shared checkbox builder, exactly as the slider and dropdown
    -- already do. It brings the themed box, the factory row height, the override
    -- indicators and the label-only tooltip -- all of which the hand-rolled copy
    -- here lacked. Re-registration is not a concern: Search:Register early-returns
    -- once RegistryBuilt is set, and Find() sets it before any result is built.
    local db = DF.db[DF.GUI.SelectedMode]
    return DF.GUI:CreateCheckbox(parent, entry.label, db, entry.dbKey, entry.callback)
end

function Search:CreateInlineSlider(parent, entry)
    -- Delegate to the shared slider builder so the inline search editor stays in
    -- sync with the canonical slider (drag/throttle/profile-override behaviour).
    -- db[dbKey] maps directly onto CreateSlider's dbTable/dbKey get/set, and
    -- entry.callback onto its callback.
    --
    -- accentColor is left nil ON PURPOSE: CreateSlider falls back to
    -- GetThemeColor(), so the thumb and fill track party purple / raid orange like
    -- every other slider. This used to pin Search's blue, which read as a bug
    -- rather than as identity once the results header started following the theme.
    local db = DF.db[DF.GUI.SelectedMode]
    local minVal = entry.minVal or 0
    local maxVal = entry.maxVal or 100
    local step = entry.step or 1

    -- Returns CreateSlider's container Frame (exposes .slider). The caller only
    -- repositions it via :SetPoint, so the Frame return shape is preserved.
    return DF.GUI:CreateSlider(parent, entry.label, minVal, maxVal, step,
        db, entry.dbKey, entry.callback)
end

function Search:CreateInlineColorPicker(parent, entry)
    -- Delegate to the shared colour picker. The copy that used to live here drove
    -- ColorPickerFrame itself, and had drifted from the canonical one in ways that
    -- mattered: it fired the change callbacks on the spurious swatchFunc Blizzard
    -- raises during setup (so merely OPENING the picker committed an override and
    -- ran a full refresh), and it rebuilt db[dbKey] as a fresh table on every
    -- change rather than mutating in place. The shared builder handles both, plus
    -- the themed swatch, the factory row height and the label-only tooltip.
    local db = DF.db[DF.GUI.SelectedMode]
    return DF.GUI:CreateColorPicker(parent, entry.label, db, entry.dbKey,
        entry.hasAlpha, entry.callback)
end

function Search:CreateInlineDropdown(parent, entry)
    -- Delegate to the shared dropdown builder so the inline search editor stays in
    -- sync with the canonical dropdown (menu/option-order/profile-override
    -- behaviour). db[dbKey] maps directly onto CreateDropdown's dbTable/dbKey
    -- get/set, and entry.callback onto its callback. entry.values is the same
    -- keyed value->display table (with optional _order) that was registered, so
    -- it passes straight through as the builder's options arg.
    local db = DF.db[DF.GUI.SelectedMode]
    local values = entry.values or {}

    -- Returns CreateDropdown's container Frame (exposes :UpdateText / :SetEnabled /
    -- :RebuildOptions). The caller only repositions it via :SetPoint, so the Frame
    -- return shape is preserved.
    -- NOT inline: inline mode hides the dropdown's own label, but this is a
    -- labeled setting in the search results, so keep the label (matches the
    -- slider/checkbox search widgets). No opts.accent -- the dropdown follows the
    -- mode theme like every other one (see CreateInlineSlider for the why).
    return DF.GUI:CreateDropdown(parent, entry.label, values,
        db, entry.dbKey, entry.callback)
end

-- ============================================================
-- CREATE RESULT WIDGET WITH INLINE EDITOR
-- ============================================================
function Search:CreateResultWidget(parent, entry, index)
    local widget = CreateFrame("Frame", nil, parent)
    -- Capped at one settings-box width; the panel is wider than that, and a card that
    -- used all of it did not read as a settings box any more.
    local cardW = math.min((parent:GetWidth() or CARD_MAX_W) - 20, CARD_MAX_W)
    widget:SetSize(cardW, CARD_CHROME + DF.GUI.RowHeight.checkbox)

    -- Card chrome from the shared palette. These were three retyped literals
    -- (0.14 fill, 0.25 border) that matched nothing -- the panel token is the
    -- surface every other card sits on.
    local cP, cB = DF.GUI.Colors.panel, DF.GUI.Colors.border
    CreateBackdrop(widget)
    widget:SetBackdropColor(cP.r, cP.g, cP.b, 1)
    widget:SetBackdropBorderColor(cB.r, cB.g, cB.b, 1)

    -- Clickable Breadcrumb (Tab > Section)
    local tabDisplay = entry.tabLabel or entry.tab or "Unknown"
    local sectionDisplay = entry.section or ""

    -- Create breadcrumb as a styled clickable button (shared GUI chrome). No
    -- accent override -- StyleButton falls back to the mode theme, so the
    -- breadcrumb wash matches the controls below it.
    local breadcrumb = CreateFrame("Button", nil, widget, "BackdropTemplate")
    breadcrumb:SetPoint("TOPLEFT", 8, -5)

    local fullPath = tabDisplay .. (sectionDisplay ~= "" and ("  >  " .. sectionDisplay) or "")
    DF.GUI:StyleButton(breadcrumb, {
        height = 18,
        text = fullPath,
        align = "left",
        leftPad = 8,
    })
    local breadcrumbText = breadcrumb.Text

    -- Size the button to fit the text with padding
    local textWidth = breadcrumbText:GetStringWidth()
    breadcrumb:SetWidth(textWidth + 24)

    -- Tooltip on hover (the accent wash/border hover is handled by StyleButton).
    --
    -- ⚠ TITLE PLUS A LINE, which is the house shape -- see BindingEditor and the AD
    -- editor, and ResolveTooltipSpec, which builds { title = label, lines = { desc } }
    -- for every settings widget. This passed a bare title and so rendered as a lone
    -- floating string with no body, which is why it did not look like the rest of them.
    --
    -- "Show me" rather than "Go to <tab>": the button's own label already spells the
    -- destination out ("Frame > Frame Size"), so repeating it in the title said nothing
    -- twice. The verb is also the honest one now that the target pulses on arrival --
    -- FlashWidget's own comment describes itself as the "show me" highlight.
    breadcrumb:HookScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = L["Show me"],
            lines = { L["Open this setting's own page and highlight it."] },
        })
    end)
    breadcrumb:HookScript("OnLeave", function()
        DF.GUI:HideTooltip()
    end)

    -- Click to navigate
    -- The key goes along for the ride so the jump can finish the job on a page
    -- whose control lives behind a popout row -- see NavigateToTab. Same
    -- dbKey-then-searchKey precedence the card cache uses, so the two agree on
    -- what identifies a setting.
    breadcrumb:SetScript("OnClick", function()
        Search:NavigateToTab(entry.tab, entry.section, entry.dbKey or entry.searchKey)
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    
    -- Create the actual editable widget based on type
    local inlineWidget

    if entry.widgetType == "checkbox" then
        inlineWidget = self:CreateInlineCheckbox(widget, entry)
    elseif entry.widgetType == "slider" then
        inlineWidget = self:CreateInlineSlider(widget, entry)
    elseif entry.widgetType == "colorpicker" then
        inlineWidget = self:CreateInlineColorPicker(widget, entry)
    elseif entry.widgetType == "dropdown" then
        inlineWidget = self:CreateInlineDropdown(widget, entry)
    end

    -- ☠ Take the slot height from the WIDGET, never from a number typed here.
    -- Every shared builder stamps container.preferredHeight from GUI.RowHeight,
    -- which owns the slot for its type (see GUI.RowHeight). The four literals
    -- that used to live here -- 30 checkbox, 50 slider, 30 colourpicker, 55
    -- dropdown -- disagreed with that table on all four counts (35/46/38/54),
    -- which is why the rows read as too tall and unevenly spaced against the
    -- real settings pages. Reading preferredHeight means a future change to
    -- GUI.RowHeight reaches the search results for free.
    local widgetHeight = (inlineWidget and inlineWidget.preferredHeight)
        or DF.GUI.RowHeight.checkbox
    
    if inlineWidget then
        inlineWidget:SetPoint("TOPLEFT", CARD_PAD_X, -CARD_CONTENT_Y)
        -- The shared builders anchor by two corners in a real page column; here the card
        -- IS the column. No separate cap needed: the card is already one settings box
        -- wide, so this lands on GroupInnerWidth (280 - 2*10 = 260) on its own.
        inlineWidget:SetWidth(widget:GetWidth() - CARD_PAD_X * 2)
        -- Tooltip text lives on the page's widget, not on the search entry --
        -- ResolveTooltipSpec reads .tooltip off the container it was attached to.
        -- Forward it so a result explains itself exactly as the real setting does.
        local src = entry.sourceWidget
        if src and src.tooltip ~= nil then
            inlineWidget.tooltip = src.tooltip
        end
    end

    local cardHeight = CARD_CHROME + widgetHeight
    widget:SetHeight(cardHeight)

    widget.entry = entry
    widget.inlineWidget = inlineWidget
    widget.calculatedHeight = cardHeight
    return widget
end

-- ☠ CARDS ARE CACHED AND REUSED. Building one is expensive -- it is a REAL settings
-- widget, so a single card is a frame, a breadcrumb button, the control's own container,
-- its check button / slider / swatch, its override indicators and a tooltip hit frame:
-- roughly six to ten frames. The old code built every result fresh on every call and then
-- did `SetParent(nil)` on the previous set, which does not free anything -- a WoW frame,
-- once created, is never really reclaimed. Combined with an un-debounced OnTextChanged
-- that meant typing one five-letter word over ~159 results stranded several thousand live
-- frames, each still carrying scripts. That is the "everything is sluggish until I
-- reload" -- it was not the search being slow, it was the whole UI carrying the wreckage.
--
-- The key is built from the registry entry rather than the registry's entry.id, on purpose:
--   * ids are reassigned whenever the registry rebuilds, so they are not stable;
--   * the shared builders bind dbTable/dbKey in CLOSURES at creation, so a card can never
--     be re-pointed at a different setting -- the cache has to be per setting, not a
--     generic pool;
--   * including the mode is what keeps that safe. `db` is captured as
--     DF.db[SelectedMode] at build time, so a party card must never be handed back for
--     raid. Different mode, different key, different card.
-- Total cards built is therefore bounded by the size of the registry, once each, instead
-- of growing without limit.
--
-- ☠ THE KEY MUST IDENTIFY THE RESULT, NOT JUST THE SETTING -- it was (mode, widgetType,
-- dbKey or label), which is coarser than what a card actually renders, and that is what
-- put the holes in a long result list. Two entries that share a key are handed the SAME
-- frame; ShowResults then appends it to resultWidgets twice and LayoutResults anchors it
-- twice, so the last placement wins and every earlier slot is left as an empty gap the
-- exact height of a card -- while the scroll extent still reserves room for all of them.
-- "159 found", a handful of cards, and acres of blank between them. Two ways to collide,
-- both real:
--   1. a custom checkbox registers with dbKey = nil (SettingsWidgets.lua) and identifies
--      itself by searchKey ("custom_<label>"), which this ignored entirely -- so every
--      custom checkbox sharing a label ("Enable", "Show Text") was one card;
--   2. the same dbKey registered from more than one page or section -- tab and section
--      were not in the key at all, even though the card's breadcrumb is BUILT from them,
--      so the survivor also showed the wrong breadcrumb for one of its two homes.
-- Carrying tab and section fixes both: a card is per place-a-setting-appears, which is
-- exactly what one result is.
local function cardCacheKey(entry)
    local mode = (DF.GUI and DF.GUI.SelectedMode) or "party"
    -- searchKey before label: it is what a keyless (custom) entry is actually identified
    -- by in the registry, and it is unique where a bare label is not.
    local ident = entry.dbKey or entry.searchKey or entry.label
    return table.concat({
        mode,
        tostring(entry.tab),
        tostring(entry.section),
        tostring(entry.widgetType),
        tostring(ident),
    }, "\0")
end

function Search:AcquireResultWidget(parent, entry, index)
    local panel = self.ResultsPanel
    panel.cardCache = panel.cardCache or {}
    local key = cardCacheKey(entry)

    -- ☠ THE TABLE IDENTITY IS PART OF THE CONTRACT, not just the mode name. DF.db is
    -- REASSIGNED on a profile switch (Core/Profile.lua), and the shared builders captured
    -- the OLD table in their closures -- so a card cached before the switch would happily
    -- write the previous profile's settings while the user looks at the new one. The mode
    -- in the key cannot catch that, because the mode name has not changed. Compare the
    -- actual table and rebuild if it moved.
    local liveDB = DF.db and DF.db[(DF.GUI and DF.GUI.SelectedMode) or "party"]

    local widget = panel.cardCache[key]
    if widget and widget.dfBoundDB ~= liveDB then
        -- Profile switched under us. Drop it; nothing here can be re-pointed, because the
        -- binding lives in closures. (The old frame cannot be freed -- WoW frames never
        -- are -- but a profile switch is a rare, deliberate act, unlike a keystroke.)
        widget:Hide()
        panel.cardCache[key] = nil
        widget = nil
    end

    if widget then
        -- Refresh what can legitimately have moved since it was built. The displayed
        -- VALUE needs no help -- every shared builder re-reads its db on OnShow (see
        -- CreateCheckbox's container:SetScript("OnShow", UpdateState)) -- but the entry
        -- object itself is new after a registry rebuild, so re-point the tooltip source.
        widget.entry = entry
        local inline, src = widget.inlineWidget, entry.sourceWidget
        if inline and src and src.tooltip ~= nil then
            inline.tooltip = src.tooltip
        end
        return widget
    end

    widget = self:CreateResultWidget(parent, entry, index)
    widget.dfBoundDB = liveDB
    panel.cardCache[key] = widget
    return widget
end

-- ============================================================
-- NAVIGATION
-- ============================================================
-- settingKey is optional and is only consulted for the popout-row case below;
-- every existing caller that passes two arguments behaves exactly as before.
function Search:NavigateToTab(tabName, sectionName, settingKey)
    if not tabName then return end

    -- Clear search. SelectTab hides the results itself, but the box keeps its text
    -- otherwise, and a stale query sitting in a hidden panel reads as still-searching.
    if self.SearchBar and self.SearchBar.editbox then
        self.SearchBar.editbox:SetText("")
        self.SearchBar.editbox:ClearFocus()
    end
    self:HideResults()

    -- ☠ DELEGATE TO THE SHARED LINK ACTION, do not hand-roll the jump. This used to do
    -- its own Tabs[name]:Click() plus a timed ScrollToSection -- which scrolled correctly
    -- and then never flashed, so a search result landed you on the right page with no
    -- indication of WHICH setting you had come for, while every other cross-link in the
    -- GUI pulses its target. GUI:LinkToSetting is that behaviour, and it already calls
    -- this file's own ScrollToSection to do the scrolling half; it also owns the two
    -- timings (0.12 for the tab to build, 0.05 for the scroll to settle) that the
    -- hand-rolled copy had guessed at differently.
    --
    -- ⚠ Guard the function, not the table: LinkToSetting lives in GUI/Sections.lua and a
    -- load-order slip would otherwise be a silent dead breadcrumb. Warn rather than fall
    -- back to a worse copy of the same thing.
    if DF.GUI and DF.GUI.LinkToSetting then
        DF.GUI:LinkToSetting({
            page    = tabName,
            section = (sectionName ~= "" and sectionName) or nil,
            -- ⚠ BORDER ONLY -- both flags are required. FlashWidget's fill is opt-OUT
            -- (`opts.fill ~= false`), so passing border alone would outline AND wash it.
            -- A search lands you on a whole section, which is a large target; the filled
            -- pulse over that much area is heavy, and the outline reads better at that
            -- size (Krathe, 2026-08-07).
            flash   = { fill = false, border = true },
        })
    else
        DF:DebugWarn("SEARCH", "LinkToSetting unavailable — breadcrumb cannot navigate")
    end

    self:OpenOwningPopoutRow(tabName, settingKey)
end

-- ★ THE POPOUT-ROW HALF OF THE JUMP. A page may hand a block of its settings to
-- a popout row -- a row on the page, its controls inside a panel that opens off
-- it -- and then the control a result points at has NOTHING of its own on the
-- page to scroll to. The section jump above still lands correctly (the ROW is in
-- that section, and it is what gets flashed), so this is a last step rather than
-- a replacement: open the row that owns the setting, so the control the user
-- searched for is actually on screen when they arrive.
--
-- ⚠ THE MAP IS LOOKED UP AFTER THE JUMP, NEVER CAPTURED BEFORE IT. Switching to
-- a page can rebuild it, and a rebuild retires every row -- a reference taken
-- beforehand would open a panel wired to the previous build's db table.
--
-- Deliberately page-agnostic: any page may publish `page._popoutRowForKey`
-- (db key -> row) and gets this for free; a page with none costs one nil lookup.
-- The delay clears GUI:LinkToSetting's own two timings (0.12 for the tab to
-- build, then 0.05 for the scroll to settle) so the row is in its final place
-- before a panel is docked beside it.
function Search:OpenOwningPopoutRow(tabName, settingKey)
    if not settingKey or not tabName then return end
    C_Timer.After(0.2, function()
        local page = DF.GUI and DF.GUI.Pages and DF.GUI.Pages[tabName]
        local map  = page and page._popoutRowForKey
        local row  = map and map[settingKey]
        -- IsShown, because a row hidden by its own hideOn is not a place to
        -- dock a panel; OpenPopout, because an older embedded kit may not have it.
        if row and row.OpenPopout and row:IsShown() then row:OpenPopout() end
    end)
end

function Search:ScrollToSection(tabName, sectionName)
    if not DF.GUI or not DF.GUI.Pages then return end

    local page = DF.GUI.Pages[tabName]
    if not page or not page.children then return end

    -- Find the header matching the section name — either a top-level page child OR one
    -- nested inside a settings group. Grouped pages (e.g. Colors) keep their headers in
    -- group.groupChildren, not directly in page.children, so scan both. When the header
    -- is nested, the whole group IS the section, so return the group to flash (the group
    -- frame is sized to its content in LayoutChildren) — a top-level header returns itself.
    local function matches(widget)
        return widget and widget.GetText and widget:GetText() == sectionName
    end
    local scrollTo, flashTarget
    for _, widget in ipairs(page.children) do
        if matches(widget) then
            scrollTo, flashTarget = widget, widget
            -- A COLLAPSIBLE section is only its header bar; the content sits in
            -- separate page children registered against it (RegisterChild). Two
            -- things follow: expand it if the user had it closed, since scrolling to
            -- hidden content reads as a dead link; and flash that CONTENT rather than
            -- the ~28px bar, because the content is what the link points at.
            if widget.sectionChildren then
                if not widget.expanded and widget.Toggle then widget:Toggle() end
                flashTarget = widget.sectionChildren[1] or widget
            end
        elseif widget.isSettingsGroup and widget.groupChildren then
            for _, entry in ipairs(widget.groupChildren) do
                if matches(entry.widget) then
                    scrollTo, flashTarget = entry.widget, widget   -- flash the whole group/section
                    break
                end
            end
        end
        if flashTarget then break end
    end
    -- ★ THE FAILURE THAT ACTUALLY HAPPENS. SEARCH's only other log call guards a load-order
    -- slip that cannot occur in a shipped build, while THIS -- the section name no longer
    -- resolving because it was renamed or moved into a group -- is the real "I clicked a
    -- search result and nothing happened": the jump scrolls nowhere and never flashes, in
    -- silence. Naming both halves makes it a one-line fix instead of a hunt.
    if not flashTarget then
        DF:DebugWarn("SEARCH", "ScrollToSection: %q not found on tab %q - jump did nothing",
            tostring(sectionName), tostring(tabName))
        return
    end

    -- Put the section at the TOP of the viewport.
    --
    -- ☠ TWO BUGS LIVED HERE, and both only showed on a page you had already scrolled
    -- — which is the common case, because a page keeps its scroll position when you
    -- leave and come back:
    --
    --   1. `pageTop - widgetTop` is a DELTA from the current viewport top, measured
    --      in live screen coordinates that already include however far the page is
    --      scrolled. SetVerticalScroll takes an ABSOLUTE offset from the top of the
    --      content. Passing the delta as the absolute silently landed you somewhere
    --      arbitrary the moment the page was not already at the top; it was only ever
    --      correct because the two agree when the current scroll is 0.
    --
    --   2. `if offset > 0` meant a target ABOVE the current position did nothing at
    --      all. Scroll down, click a link to a section near the top, and the page
    --      did not move -- so the flash fired off-screen above the fold and the link
    --      looked broken. Clamping to 0 instead lets it scroll UP as well as down,
    --      which is the whole point of "jump to this section".
    --
    -- Reading the current scroll and adding the delta fixes both.
    local widgetTop = scrollTo:GetTop()
    local pageTop = page:GetTop()
    if widgetTop and pageTop and page.SetVerticalScroll then
        local current = page:GetVerticalScroll() or 0
        -- 20px of air above the header, so it reads as the top of a section rather
        -- than as a line flush against the viewport edge.
        local target = current + (pageTop - widgetTop) - 20
        local maxScroll = math.max(0, (page.child:GetHeight() or 0) - (page:GetHeight() or 0))
        page:SetVerticalScroll(math.max(0, math.min(target, maxScroll)))
    end
    return flashTarget   -- the section (group or header), so GUI:LinkToSetting can flash it
end

-- ============================================================
-- SEARCH BAR
-- ============================================================
function Search:CreateSearchBar(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(150, 28)
    
    -- ☠ THE SHARED INPUT CHROME, not a private copy of it. The two literals that used to
    -- be here were `0, 0, 0, 0.7` fill and `0.3, 0.3, 0.3, 1` border -- and that border is
    -- byte-identical to Widgets.lua's INPUT_EDGE, i.e. this was the shared look, retyped.
    -- INPUT_FILL/INPUT_EDGE are file-locals over there, so GUI:StyleEditBox IS the
    -- supported way to reach them; there is no palette entry to reference instead.
    --
    -- skipFont because the FRAME is the well here, not the editbox: the editbox is inset
    -- inside it to clear the leading icon, so it is this frame that needs the backdrop and
    -- the editbox that needs the font (set below).
    --
    -- ⚠ ONE DELIBERATE VISUAL CHANGE: the fill goes 0.7 -> 0.5 alpha, because that is what
    -- INPUT_FILL is. The search box stops being very slightly darker than every other
    -- input in the addon. Say the word if you want the old value back -- it would mean
    -- re-introducing a literal, so it should be a decision rather than a drift.
    DF.GUI:StyleEditBox(frame, { skipFont = true })

    local icon = frame:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("LEFT", 6, 0)
    icon:SetSize(15, 15)
    icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\search")
    icon:SetVertexColor(0.72, 0.72, 0.72)

    local editbox = CreateFrame("EditBox", nil, frame)
    editbox:SetPoint("LEFT", 26, 0)
    editbox:SetPoint("RIGHT", -24, 0)
    editbox:SetHeight(20)
    editbox:SetFontObject(DFFontHighlightSmall)
    editbox:SetAutoFocus(false)
    editbox:SetTextInsets(2, 2, 0, 0)
    
    local placeholder = frame:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
    placeholder:SetPoint("LEFT", 26, 0)
    placeholder:SetText(L["Search..."])
    -- textDim (0.6) rather than the 0.5 literal that was here. A hair lighter; the point
    -- is that placeholder text now moves with the palette instead of being pinned.
    local cDim = DF.GUI.Colors.textDim
    placeholder:SetTextColor(cDim.r, cDim.g, cDim.b)
    
    -- Clearing is destructive, so this one overrides the shared white hover with
    -- the soft red every other destructive glyph in the GUI uses.
    local clearBtn = DF.GUI:CreateGlyphButton(frame, {
        texture    = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\close",
        size       = 16,
        color      = { 0.5, 0.5, 0.5 },
        hoverColor = { 1, 0.3, 0.3 },
        onClick    = function()
            editbox:SetText("")
            editbox:ClearFocus()
            Search:HideResults()
        end,
    })
    clearBtn:SetPoint("RIGHT", -4, 0)
    clearBtn:Hide()
    
    editbox:SetScript("OnEditFocusGained", function()
        local c = GetThemeColor()
        frame:SetBackdropBorderColor(c.r, c.g, c.b, 1)
        placeholder:Hide()
    end)

    editbox:SetScript("OnEditFocusLost", function()
        -- ⚠ Restore by RE-APPLYING the shared chrome, not by retyping the resting edge.
        -- That literal (0.3 grey) was INPUT_EDGE spelled out, and it appeared twice -- so
        -- a change to the shared input look would have fixed the resting state and left
        -- the after-focus state on the old colour, which is the sort of drift only ever
        -- noticed by accident.
        DF.GUI:StyleEditBox(frame, { skipFont = true })
        if editbox:GetText() == "" then
            placeholder:Show()
        end
    end)
    
    editbox:SetScript("OnTextChanged", function(self, userInput)
        local text = self:GetText()
        if text and text ~= "" then
            placeholder:Hide()
            clearBtn:Show()
            if userInput then
                -- Don't search during combat - building registry creates UI elements
                if InCombatLockdown() then
                    Search:CancelQueuedSearch()
                    Search:ShowCombatMessage()
                else
                    -- Debounced: one rebuild after the typing stops, not one per letter.
                    Search:QueueSearch(text)
                end
            end
        else
            if not self:HasFocus() then
                placeholder:Show()
            end
            clearBtn:Hide()
            Search:HideResults()
        end
    end)
    
    editbox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
        Search:HideResults()
    end)
    
    editbox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    
    frame.editbox = editbox
    frame.placeholder = placeholder
    frame.clearBtn = clearBtn
    
    self.SearchBar = frame
    return frame
end

-- ============================================================
-- RESULTS PANEL
-- ============================================================
function Search:CreateResultsPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    
    CreateBackdrop(panel)
    -- ⚠ These two calls are not redundant with CreateBackdrop's own colours:
    -- SetBackdrop resets a frame's piece vertex colours, so the fill and border
    -- have to be (re)stated after it. Tokens, not the literals that were here.
    local pB, pBorder = DF.GUI.Colors.background, DF.GUI.Colors.border
    panel:SetBackdropColor(pB.r, pB.g, pB.b, 1)
    panel:SetBackdropBorderColor(pBorder.r, pBorder.g, pBorder.b, 1)
    panel:Hide()
    
    local header = panel:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    header:SetPoint("TOPLEFT", 15, -15)
    header:SetText(L["Search Results"])
    local c = GetThemeColor()
    header:SetTextColor(c.r, c.g, c.b)
    panel.header = header
    
    local countText = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    countText:SetPoint("LEFT", header, "RIGHT", 10, 0)
    -- Exactly GUI.Colors.textDim, which is what this literal already was.
    local cCount = DF.GUI.Colors.textDim
    countText:SetTextColor(cCount.r, cCount.g, cCount.b)
    panel.countText = countText
    
    local noResults = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    noResults:SetPoint("CENTER", panel, "CENTER", 0, 0)
    noResults:SetText(EmptyMessage())
    local cd = DF.GUI.Colors.textDim
    noResults:SetTextColor(cd.r, cd.g, cd.b)
    noResults:Hide()
    panel.noResults = noResults
    
    -- The results panel FILLS the content box, so its right edge is the same
    -- corridor a page's is -- and it gets the same treatment: the viewport stops
    -- at the scrollbar gutter, and the bar is pinned into it against the panel
    -- rather than left wherever ScrollFrameTemplate puts it. It used to reserve
    -- a flat 30 here, twice the gutter, and the bar was not in most of it.
    local scroll = CreateFrame("ScrollFrame", nil, panel, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -45)
    scroll:SetPoint("BOTTOMRIGHT", -DF.GUI.Scroll.gutter, 10)
    DF.GUI.StyleScrollBar(scroll)
    DF.GUI.PinScrollBar(scroll, panel, -45, 10)

    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(scroll:GetWidth(), 1)
    scroll:SetScrollChild(scrollChild)
    
    panel.scroll = scroll
    panel.scrollChild = scrollChild
    panel.resultWidgets = {}
    
    self.ResultsPanel = panel
    return panel
end

-- ============================================================
-- SHOW/HIDE RESULTS
-- ============================================================
-- Coalesce keystrokes into one rebuild. OnTextChanged fires per character, and each
-- rebuild lays out every result, so without this "frame" cost five full passes over ~159
-- cards -- the visible symptom being the panel lurching as it re-laid itself under the
-- scrollbar while you were still typing or scrolling.
--
-- ⚠ Always store the LATEST query and let the timer read it when it fires, rather than
-- capturing the text in the closure: the timer must render what the box says when it
-- expires, not what it said when the first key was pressed.
function Search:QueueSearch(text)
    self._pendingQuery = text
    if self._searchTimer then return end
    self._searchTimer = C_Timer.NewTimer(SEARCH_DEBOUNCE, function()
        self._searchTimer = nil
        local q = self._pendingQuery
        self._pendingQuery = nil
        -- Re-check combat: the debounce window is long enough to have entered it, and
        -- building results creates frames.
        if q and q ~= "" and not InCombatLockdown() then
            self:ShowResults(q)
        end
    end)
end

function Search:CancelQueuedSearch()
    if self._searchTimer then
        self._searchTimer:Cancel()
        self._searchTimer = nil
    end
    self._pendingQuery = nil
end

-- Position the already-built result cards. Separate from ShowResults so a RESIZE can
-- re-run the layout without re-running the query or rebuilding a single card.
--
-- ☠ THIS IS THE PIECE THAT WAS MISSING, and it is why the gutter did not adjust: the
-- geometry was right, but it was only ever computed at search time. Pages do not
-- recompute themselves either — GUI:RefreshCurrentPage does it for them, off the resize
-- handle's OnMouseUp. The search panel is not a page, so nothing was calling it. It now
-- hangs off that same refresh (see the hook in GUI/Panel.lua) rather than growing a
-- second, private resize mechanism.
function Search:LayoutResults()
    local panel = self.ResultsPanel
    if not (panel and panel.scrollChild and panel.resultWidgets) then return end
    local scrollChild = panel.scrollChild

    -- ☠ MEASURE THE VIEWPORT, NOT THE SCROLL CHILD. scrollChild's width is set once at
    -- creation from `scroll:GetWidth()`, and the scroll frame is anchored by two corners
    -- — so at that moment it can still be 0, and it never tracks a later resize or
    -- UI-scale change. Reading it would latch the column count at 1 forever. Re-sync the
    -- child here too, since the cards anchor inside it.
    local viewW = (panel.scroll and panel.scroll:GetWidth()) or 0
    if viewW <= 0 then return end
    scrollChild:SetWidth(viewW)

    -- Same rule, same numbers, as the page layout in GUI/Panel.lua: two columns once
    -- there is room for two minimum columns plus the gutter, column 2 pinned to the
    -- halfway mark. Pinning column 2 rather than spacing it is what makes the gutter
    -- widen with the window, because the cards themselves keep their constructed width.
    local cols  = (viewW >= MIN_COL_W * 2 + SETTINGS_BOX.colGutter) and 2 or 1
    local col2X = math.floor(viewW / 2)
    local avail = viewW - COL_LEFT
    local cardW = math.min(avail, CARD_MAX_W)

    -- ⚠ INDEPENDENT PER-COLUMN CURSORS, not a row grid. Cards are not all the same height
    -- (a dropdown card is taller than a checkbox card), so locking them into rows would
    -- leave a ragged gap under every short card in a tall row. This is how the settings
    -- pages already flow: Panel.lua tracks y1 and y2 separately and only syncs them for a
    -- full-width spanner.
    local colY = {}
    for c = 1, cols do colY[c] = 0 end

    for i, widget in ipairs(panel.resultWidgets) do
        -- Round-robin by index rather than "shortest column first". Denser packing is not
        -- worth it here: results are ORDERED BY RELEVANCE, and the reading order has to
        -- stay predictable left-to-right or the ranking becomes unreadable.
        local col = ((i - 1) % cols) + 1
        local x = (col == 2) and col2X or COL_LEFT

        -- ⚠ Re-assert the width on every layout, not just at creation. Cards are CACHED,
        -- so one built before the panel resolved its width would otherwise keep that
        -- wrong width for the session. This is also what makes a resize re-fit them.
        widget:SetWidth(cardW)
        if widget.inlineWidget then
            widget.inlineWidget:SetWidth(cardW - CARD_PAD_X * 2)
        end

        -- ClearAllPoints first: a reused card still carries the anchor from wherever it
        -- sat in the previous layout — including a different column.
        widget:ClearAllPoints()
        widget:SetPoint("TOPLEFT", x, -colY[col])
        colY[col] = colY[col] + (widget.calculatedHeight or 75) + 5
    end

    -- The scroll extent is the LONGEST column, not the last one written.
    local tallest = 0
    for c = 1, cols do
        if colY[c] > tallest then tallest = colY[c] end
    end
    scrollChild:SetHeight(tallest + 20)
end

function Search:ShowResults(query)
    if not self.ResultsPanel then return end

    -- ☠ THE FIRST SEARCH OF A SESSION IS A FULL INDEX BUILD, and it used to run
    -- inside this call -- one frame, ~34 page builders, the same hitch the
    -- changed-settings ledger was reported for. It is budgeted now, so the panel
    -- SAYS it is indexing and the query is re-run when the registry lands.
    --
    -- ⚠ THE QUERY IS RE-READ FROM THE BOX on the way back, not replayed from
    -- this closure: a build takes several frames and the user goes on typing
    -- through them, so answering the query they had when they started would put
    -- stale results under a box that says something else.
    if self:RegistryIsStale() or self.RegistryBuilding then
        self:ShowBuildingMessage()
        self:EnsureRegistryAsync(function(ok)
            if not (ok and self.ResultsPanel and self.ResultsPanel:IsShown()) then return end
            if InCombatLockdown() then return end
            local live = self.SearchBar and self.SearchBar.editbox:GetText()
            if live and live ~= "" then self:ShowResults(live) end
        end)
        return
    end

    local results = self:Find(query)
    local panel = self.ResultsPanel
    local scrollChild = panel.scrollChild
    
    -- ⚠ HIDE, never SetParent(nil). These cards are cached and will be shown again; the
    -- old teardown orphaned them instead, which freed nothing and lost the reuse.
    for _, widget in ipairs(panel.resultWidgets) do
        widget:Hide()
    end
    panel.resultWidgets = {}

    local c = GetThemeColor()
    panel.header:SetTextColor(c.r, c.g, c.b)

    if #results == 0 then
        panel.noResults:Show()
        panel.countText:SetText("")
        panel.scroll:Hide()
    else
        panel.noResults:Hide()
        panel.scroll:Show()

        -- Build (or re-acquire) the cards; POSITIONING is LayoutResults' job, so that the
        -- same code runs on a resize without re-querying.
        --
        -- ⚠ A FRAME MAY ONLY ENTER THIS LIST ONCE. The cache hands back one frame per key,
        -- and a frame can only carry one anchor -- so appending the same one twice does not
        -- draw it twice, it draws it once and leaves a card-sized hole where the earlier
        -- copy was counted. cardCacheKey is what keeps distinct results distinct; this is
        -- the backstop that stops a future key collision reaching the layout as a gap.
        local placed = {}
        for i, entry in ipairs(results) do
            local widget = self:AcquireResultWidget(scrollChild, entry, i)
            if not placed[widget] then
                placed[widget] = true
                widget:Show()
                table.insert(panel.resultWidgets, widget)
            end
        end

        -- Count the cards that exist, not what Find returned. If the two ever disagree,
        -- the honest number is the one the user can confirm by scrolling.
        panel.countText:SetText(string.format(L["(%d found)"], #panel.resultWidgets))
        self:LayoutResults()
    end
    
    panel:Show()
    
    if DF.GUI and DF.GUI.Pages then
        for _, page in pairs(DF.GUI.Pages) do
            page:Hide()
        end
    end
end

function Search:HideResults()
    -- ⚠ Kill any debounced rebuild first. Clearing the box or closing the panel must not
    -- be followed a quarter of a second later by a build for a query that is now gone --
    -- that would re-show the results panel over whatever page the user just went back to.
    self:CancelQueuedSearch()
    if self.ResultsPanel then
        self.ResultsPanel:Hide()
        -- Reset the no-results text in case it was changed to the combat message.
        -- ☠ Must restore the SAME string the panel was built with. This used to
        -- put back a different, terser one, and it runs on every hide rather than
        -- only after a combat message -- so the helpful two-line prompt was only
        -- ever seen until the first time search was closed, then gone for the
        -- session. EmptyMessage() is the single source for both.
        if self.ResultsPanel.noResults then
            self.ResultsPanel.noResults:SetText(EmptyMessage())
        end
    end
    
    if DF.GUI and DF.GUI.CurrentPageName and DF.GUI.Pages then
        local currentPage = DF.GUI.Pages[DF.GUI.CurrentPageName]
        if currentPage then
            currentPage:Show()
        end
    end
end

function Search:ShowCombatMessage()
    self:ShowPanelMessage(L["Search unavailable during combat"])
end

-- The panel standing in for results while the index is still being built. Same
-- surface as the combat message and for the same reason: an empty panel reading
-- "No settings found" during a build is not a slower answer, it is a WRONG one.
-- HideResults puts EmptyMessage() back, so neither string can stick.
function Search:ShowBuildingMessage()
    self:ShowPanelMessage(L["Indexing settings..."])
end

function Search:ShowPanelMessage(text)
    if not self.ResultsPanel then return end

    local panel = self.ResultsPanel

    -- Clear existing results.
    -- ⚠ Hide only. SetParent(nil) here would orphan cards that are still in cardCache,
    -- so the next search would hand back a parentless frame that never draws.
    for _, widget in ipairs(panel.resultWidgets) do
        widget:Hide()
    end
    panel.resultWidgets = {}

    -- Show the message instead of "No results"
    panel.noResults:SetText(text)
    panel.noResults:Show()
    panel.countText:SetText("")
    panel.scroll:Hide()
    
    -- Hide current page and show results panel
    if DF.GUI and DF.GUI.CurrentPageName and DF.GUI.Pages then
        local currentPage = DF.GUI.Pages[DF.GUI.CurrentPageName]
        if currentPage then
            currentPage:Hide()
        end
    end
    panel:Show()
end

-- ============================================================
-- REGISTRATION HELPERS
-- Now store all widget metadata
-- ============================================================
function Search:RegisterCheckbox(label, dbKey, keywords, customGetSet, callback)
    return self:Register({
        label = label,
        dbKey = dbKey,
        searchKey = customGetSet and ("custom_" .. label:gsub("%s+", "_"):lower()) or nil,
        widgetType = "checkbox",
        keywords = keywords,
        isCustom = customGetSet or false,
        callback = callback,
    })
end

function Search:RegisterSlider(label, dbKey, minVal, maxVal, step, keywords, callback)
    return self:Register({
        label = label,
        dbKey = dbKey,
        widgetType = "slider",
        minVal = minVal,
        maxVal = maxVal,
        step = step,
        keywords = keywords,
        callback = callback,
    })
end

function Search:RegisterDropdown(label, dbKey, values, keywords, callback)
    return self:Register({
        label = label,
        dbKey = dbKey,
        widgetType = "dropdown",
        values = values,
        keywords = keywords,
        callback = callback,
    })
end

function Search:RegisterColorPicker(label, dbKey, hasAlpha, keywords, callback)
    return self:Register({
        label = label,
        dbKey = dbKey,
        widgetType = "colorpicker",
        hasAlpha = hasAlpha,
        keywords = keywords,
        callback = callback,
    })
end
