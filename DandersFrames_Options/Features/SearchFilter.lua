-- ☠ Companion addon: take the parent's table from the global it publishes
-- (see the same note at the head of Features/Search.lua).
local DF = DandersFrames
local Search = DF.Search
local GUI = DF.GUI
local L = DF.L

local pairs, ipairs, type, rawget, rawset, next, pcall =
    pairs, ipairs, type, rawget, rawset, next, pcall
local gsub = string.gsub

-- ============================================================
-- SETTINGS SEARCH -- THE PAGE LIST'S IN-PLACE FILTER
-- The search box at the top of the page list does not swap the page for a
-- results view (Home's box does that). It NARROWS what is already there:
--   * the page list keeps only the pages with something matching on them
--     (GUI:UpdateTabLayout asks FilterNavHides per row);
--   * the page shows only the matching controls, the cards and headers that hold
--     them, and opens a shut card that holds a match -- for as long as the search
--     runs, never saved (FilterPagePass, run first in every page state pass);
--   * clearing the box puts every page back exactly as it was.
-- People navigate as normal; the set is just smaller. A query stays in the box
-- across module switches and re-filters the new module's pages.
--
-- WHAT COUNTS AS A MATCH is Features/SearchMatch.lua's every-word answer over
-- the registry, scoped to the pages the list is showing. A match a page would
-- not show anyway (its "only shown when" condition is off) does not put the page
-- in the list. A page whose own name matches is shown whole, and so is a page
-- built around a designer (a fill widget): designers are one unit, never
-- narrowed from the inside. Pinned panels and Click-Casting are not touched.
--
-- ★ NO FRAMES PER KEYSTROKE. The filter only marks widgets that exist (hidden
-- by the same passes that apply "only shown when"), so it cannot grow a cache
-- the way the old result cards did. The registry it reads is the search's own,
-- built in budgeted slices and never in combat; only the pages of the view in
-- front of the user are added to it.
-- ============================================================

-- Short: a keystroke now costs a cached match and, only when the answer
-- changed, one relayout of the page on screen (see RefreshFilter).
local FILTER_DEBOUNCE = 0.1

local F = {
    text     = "",      -- what the box says (trimmed)
    active   = false,   -- a computed query is narrowing the window
    compiled = nil,     -- Search:CompileQuery's answer for `text`
    hit      = {},      -- entry -> score, every-word matches in the view
    indexed  = nil,     -- entry -> true, everything the index the hits came from holds
    inView   = {},      -- page name -> true, the pages the list is showing
    pageHit  = {},      -- page name -> true, pages with a visible match (or a matching name)
    pageWhole = {},     -- page name -> true, pages whose own name matches
    any      = false,   -- anything matched at all
    viewSig  = nil,     -- the in-view page set the last compute saw
    gen      = 0,       -- bumped by every compute; caches key on it
}
Search.Filter = F

-- ------------------------------------------------------------
-- SMALL HELPERS
-- ------------------------------------------------------------
local function PageDB(page)
    local own = GUI.PageBuildDb and page and GUI.PageBuildDb(page)
    if own then return own end
    return DF.db and DF.db[GUI.SelectedMode]
end

-- "Only shown when": the widget's own condition, read the way the page pass reads it.
local function CondHidden(w, db)
    local h = type(w) == "table" and rawget(w, "hideOn")
    if type(h) ~= "function" or not db then return false end
    local ok, r = pcall(h, db)
    return ok and r and true or false
end

local function PageTexts(page, name)
    name = name or (page and page.tabName) or ""
    local label = page and (page.searchTabLabel or page.tabLabel) or nil
    return label, (gsub(name, "_", " "))
end

local function PageHasFill(page)
    for _, w in ipairs(page.children or {}) do
        if type(w) == "table" and rawget(w, "layoutFill") then return true end
    end
    return false
end

-- Would this registry entry's control be drawn, filter aside?
local dbByTab = {}
local function EntryWouldShow(entry)
    local w = entry.sourceWidget
    if type(w) ~= "table" then return true end
    local tab = entry.tab
    local db = dbByTab[tab]
    if db == nil then
        db = PageDB(GUI.Pages and GUI.Pages[tab]) or false
        dbByTab[tab] = db
    end
    if not db then return true end
    if CondHidden(w, db) then return false end
    local g = rawget(w, "settingsGroup")
    if type(g) == "table" and CondHidden(g, db) then return false end
    return true
end

-- ------------------------------------------------------------
-- COMPUTE -- which pages and entries the query keeps, for the view showing.
-- Returns false while the registry is still being built for it (the window then
-- stays unfiltered until the build lands and calls back).
-- ------------------------------------------------------------
local waitingForCombat

local function ViewPages()
    local inView, names = {}, {}
    for name, btn in pairs(GUI.Tabs or {}) do
        if GUI.Pages and GUI.Pages[name] and GUI:IsTabInView(btn) then
            inView[name] = true
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return inView, table.concat(names, ",")
end

local function Deactivate()
    F.active, F.compiled, F.any = false, nil, false
    F.hit, F.pageHit, F.pageWhole, F.indexed = {}, {}, {}, nil
    F.memo = nil
end

-- ★ ONE COMPUTE PER QUERY. The page list is laid out by many callers (every page
-- select, every category fold, the filter itself), and each asks for the answer;
-- the answer only moves with the query, the pages in view, the mode or the
-- registry, so it is computed once for those and handed back after.
local function MemoKey(sig)
    local reg = Search.Registry
    return F.text .. "\1" .. sig .. "\1" .. tostring(GUI.SelectedMode) .. "\1"
        .. tostring(reg) .. "\1" .. tostring(reg and #reg or 0)
end

function Search:_FilterCompute()
    if F.text == "" then Deactivate() return true end

    local inView, sig = ViewPages()
    F.inView = inView
    local viewMoved = (sig ~= F.viewSig)
    F.viewSig = sig
    if F.memo and F.memo == MemoKey(sig) and not self.RegistryBuilding then
        return true, viewMoved
    end

    -- The view's deferred pages (one unit's pages) join the index; nothing else.
    self:IncludeScopedPages(inView)
    self:TryReuseRegistry()
    if self:RegistryIsStale() or self.RegistryBuilding then
        -- A build creates frames: never in combat. Try again once it ends.
        if InCombatLockdown() then
            if not waitingForCombat then
                waitingForCombat = CreateFrame("Frame")
                waitingForCombat:SetScript("OnEvent", function(f)
                    f:UnregisterEvent("PLAYER_REGEN_ENABLED")
                    Search:RefreshFilter(true)
                end)
            end
            waitingForCombat:RegisterEvent("PLAYER_REGEN_ENABLED")
        elseif not (self.RegistryBuilding and F.waitToken == self._buildToken) then
            -- ONE wait per build. The list is laid out again and again while a
            -- build runs (every page select does it), and each would otherwise
            -- queue another refresh for when it lands. A build that was dropped
            -- (InvalidateRegistry drops its waiters too) has a new token by then,
            -- so this asks again rather than waiting on nothing.
            self:EnsureRegistryAsync(function(ok)
                F.waitToken = nil
                if ok then Search:RefreshFilter(true) end
            end)
            F.waitToken = self._buildToken
        end
        Deactivate()
        return false, viewMoved
    end

    local compiled = self:CompileQuery(F.text)
    if not compiled then Deactivate() return true, viewMoved end

    F.gen = F.gen + 1
    F.keepCache = {}
    dbByTab = {}
    F.compiled = compiled
    F.indexed = compiled.index and compiled.index.indexed or nil
    F.hit = self:MatchEntries(compiled, function(e) return e.tab ~= nil and inView[e.tab] == true end)

    local pageHit, pageWhole = {}, {}
    for entry in pairs(F.hit) do
        if not pageHit[entry.tab] and EntryWouldShow(entry) then pageHit[entry.tab] = true end
    end
    for name in pairs(inView) do
        local label, spaced = PageTexts(GUI.Pages[name], name)
        if self:TextMatchesAll(compiled, { { label, literal = true }, { spaced, literal = true } }) then
            pageWhole[name] = true
            pageHit[name] = true
        end
    end
    F.pageHit, F.pageWhole = pageHit, pageWhole
    F.any = next(pageHit) ~= nil
    F.active = true
    F.memo = MemoKey(sig)
    return true, viewMoved
end

-- ------------------------------------------------------------
-- THE PAGE PASS -- GUI.FilterPagePass(page, db), first thing in every page
-- state pass (GUI/Panel.lua). Marks; never lays out.
-- ------------------------------------------------------------
local function ClearGroup(g)
    if g.ClearChildFilter then g:ClearChildFilter() end
    for _, e in ipairs(rawget(g, "groupChildren") or {}) do
        local cw = e.widget
        if type(cw) == "table" and rawget(cw, "groupChildren") then ClearGroup(cw) end
    end
end

-- Both answer whether they MOVED anything: the filter only lays a page out
-- again when its marks changed (RefreshFilter).
local function RestoreCard(section)
    local moved = false
    if rawget(section, "dfFilterOpened") then
        section.dfFilterOpened = nil
        section.expanded = false
        if section.ShowFold then section:ShowFold() end
        moved = true
    end
    section.dfFilterUser = nil
    return moved
end

local function OpenCard(section)
    if section.expanded or rawget(section, "dfFilterUser") then return false end
    section.dfFilterOpened = true
    section.expanded = true
    if section.ShowFold then section:ShowFold() end
    return true
end

function Search:_UnfilterPage(page)
    for _, w in ipairs(page.children or {}) do
        if type(w) == "table" then
            if rawget(w, "dfFilterHidden") then rawset(w, "dfFilterHidden", nil) end
            if rawget(w, "groupChildren") then ClearGroup(w) end
            if rawget(w, "sectionChildren") then RestoreCard(w) end
        end
    end
    page._dfFiltered = nil
    return true
end

local function SameCol(a, b)
    return a == b or a == "both" or b == "both"
end

-- Marks the page; returns true when any mark moved (so a relayout is due).
function Search:_FilterPage(page, db)
    local name = page.tabName
    if not (F.active and F.any and name and F.inView[name]) or F.pageWhole[name] or PageHasFill(page) then
        if page._dfFiltered then return self:_UnfilterPage(page) end
        return false
    end
    local moved = not page._dfFiltered
    page._dfFiltered = true
    local keepCache = F.keepCache or {}
    F.keepCache = keepCache
    local function Mark(w, hidden)
        if rawget(w, "dfFilterHidden") ~= hidden then
            rawset(w, "dfFilterHidden", hidden)
            moved = true
        end
    end

    local compiled = F.compiled
    local label, spaced = PageTexts(page, name)
    local cardMatch = {}
    local function CardMatched(section)
        if type(section) ~= "table" then return false end
        local m = cardMatch[section]
        if m == nil then
            m = self:TextMatchesAll(compiled, { rawget(section, "sectionTitleText"),
                { label, literal = true }, { spaced, literal = true } })
            cardMatch[section] = m
        end
        return m
    end

    -- A control is kept when its card's title matches, or its own setting does,
    -- and its "only shown when" would show it.
    -- The match half is cached per widget per query (a page is swept again on
    -- every setting change); the condition half is read live.
    local function Matches(w, section)
        local c = keepCache[w]
        if c ~= nil then return c end
        if CardMatched(section) then
            c = true
        else
            local e = rawget(w, "searchEntry")
            if type(e) ~= "table" then
                c = false
            elseif F.hit[e] then
                c = true
            elseif F.indexed and F.indexed[e] then
                c = false
            else
                c = self:EntryMatchesAll(compiled, e, section and rawget(section, "sectionTitleText"), label, name)
                    and true or false
            end
        end
        keepCache[w] = c
        return c
    end
    local function Keep(w, section)
        if not Matches(w, section) then return false end
        return not CondHidden(w, db)
    end

    -- A box: decide its rows (headers inside it follow the rows under them), mark
    -- them, and say whether anything is left.
    local function DecideGroup(g, section)
        local kids = rawget(g, "groupChildren") or {}
        local keep, any = {}, false
        for j, e in ipairs(kids) do
            local cw = e.widget
            if type(cw) == "table" and not rawget(cw, "isSectionHeader") then
                local k
                if rawget(cw, "groupChildren") then
                    k = not CondHidden(cw, db) and DecideGroup(cw, section)
                else
                    k = Keep(cw, section)
                end
                keep[j] = k and true or false
                if k then any = true end
            end
        end
        for j, e in ipairs(kids) do
            local cw = e.widget
            if type(cw) == "table" and rawget(cw, "isSectionHeader") then
                local k = false
                for n = j + 1, #kids do
                    local nw = kids[n].widget
                    if type(nw) == "table" and rawget(nw, "isSectionHeader") then break end
                    if keep[n] then k = true break end
                end
                keep[j] = k
            end
        end
        if g.SetChildFiltered then
            for j, e in ipairs(kids) do
                if e.widget then
                    local want = (not keep[j]) or nil
                    if e.filterHidden ~= want then moved = true end
                    g:SetChildFiltered(e.widget, not keep[j])
                end
            end
        end
        return any
    end

    local children = page.children or {}
    local cardKept = {}
    for _, w in ipairs(children) do
        if type(w) == "table" and not rawget(w, "settingsGroup") then
            local hidden = nil
            local section = rawget(w, "collapsibleSection")
            local later = rawget(w, "sectionChildren") or rawget(w, "isSectionHeader")
            if later or rawget(w, "rightAlign") or rawget(w, "isSyncPoint") then
                hidden = nil   -- decided below (cards, headers), or never filtered
            elseif rawget(w, "isPageFooter") then
                hidden = true
            elseif rawget(w, "isSettingsGroup") then
                local any = not CondHidden(w, db) and DecideGroup(w, section)
                if any then
                    if section then cardKept[section] = true end
                else
                    hidden = true
                end
            elseif Keep(w, section) then
                if section then cardKept[section] = true end
            else
                hidden = true
            end
            -- Cards and headers are marked once, below: marking them shown here and
            -- hidden there would count as a change on every pass.
            if not later then Mark(w, hidden) end
        end
    end

    -- Cards: kept when anything in them is (or their title matches), and opened
    -- for the search when shut.
    for _, w in ipairs(children) do
        if type(w) == "table" and rawget(w, "sectionChildren") then
            if cardKept[w] or CardMatched(w) then
                Mark(w, nil)
                if OpenCard(w) then moved = true end
            else
                Mark(w, true)
                if RestoreCard(w) then moved = true end
            end
        end
    end

    -- Bare headers laid straight on the page: kept only over something kept,
    -- in their own column, up to the next bare header there.
    for i, h in ipairs(children) do
        if type(h) == "table" and rawget(h, "isSectionHeader") and not rawget(h, "settingsGroup") then
            local col = rawget(h, "layoutCol") or 1
            local keep = false
            for j = i + 1, #children do
                local w = children[j]
                if type(w) == "table" and not rawget(w, "settingsGroup") then
                    local wcol = rawget(w, "layoutCol") or 1
                    if SameCol(col, wcol) then
                        if rawget(w, "isSectionHeader") then break end
                        if not (rawget(w, "rightAlign") or rawget(w, "isSyncPoint"))
                            and not rawget(w, "dfFilterHidden") then
                            keep = true
                            break
                        end
                    end
                end
            end
            Mark(h, (not keep) or nil)
        end
    end
    return moved
end

GUI.FilterPagePass = function(page, db)
    local ok, err = pcall(Search._FilterPage, Search, page, db)
    if not ok and err then geterrorhandler()(err) end
    if page and page.tabName and page.tabName == GUI.CurrentPageName and Search._FilterNote then
        Search:_FilterNote()
    end
end

-- ------------------------------------------------------------
-- THE PAGE LIST -- asked by GUI:UpdateTabLayout (GUI/Panel.lua).
-- ------------------------------------------------------------
local afterView

-- The page on screen has nothing matching: go to the first page that does, so a
-- filtered window never opens on an empty page.
local function MoveOffEmptyPage()
    if not (F.active and F.any) then return end
    local cur = GUI.CurrentPageName
    if not cur or not F.inView[cur] or F.pageHit[cur] then return end
    local best, bestY
    for name, btn in pairs(GUI.Tabs or {}) do
        if F.pageHit[name] and btn:IsShown() then
            local _, _, _, _, y = btn:GetPoint(1)
            if y and (not bestY or y > bestY) then best, bestY = name, y end
        end
    end
    if best and GUI.SelectTab then GUI.SelectTab(best) end
end

GUI.FilterNavPrepare = function()
    if F.text == "" then
        if F.active then Deactivate() end
        return false
    end
    local _, viewMoved = Search:_FilterCompute()
    if viewMoved and F.active and not afterView then
        -- A module switch lays the list out before it selects its page; look once
        -- the switch is finished.
        afterView = true
        C_Timer.After(0, function()
            afterView = nil
            MoveOffEmptyPage()
            Search:RefreshFilter(false)
        end)
    end
    return F.active
end

GUI.FilterNavHides = function(btn)
    return F.active and not F.pageHit[btn.tabName]
end

local emptyText
GUI.FilterNavDone = function()
    local show = F.active and not F.any
    if show and not emptyText and GUI.tabContainer then
        emptyText = GUI.tabContainer:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
        emptyText:SetPoint("TOPLEFT", GUI.tabContainer, "TOPLEFT", 8, -12)
        emptyText:SetPoint("TOPRIGHT", GUI.tabContainer, "TOPRIGHT", -8, -12)
        emptyText:SetJustifyH("LEFT")
        emptyText:SetWordWrap(true)
    end
    if emptyText then
        if show then emptyText:SetText(L["No settings found.\nTry different keywords."]) end
        emptyText:SetShown(show)
    end
end

-- ------------------------------------------------------------
-- DRIVING IT
-- ------------------------------------------------------------
-- The note over a page the query found nothing on: the page itself is emptied
-- by the filter, and Enter in the box goes to the first page that matches.
-- ONE font string for the window, made the first time it is needed.
local noteText
function Search:_FilterNote()
    local cur = GUI.CurrentPageName
    local show = F.active and F.any and cur and F.inView[cur] and not F.pageHit[cur] and true or false
    if show and not noteText and GUI.contentFrame then
        noteText = GUI.contentFrame:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
        noteText:SetPoint("TOPLEFT", GUI.contentFrame, "TOPLEFT", 16, -16)
        noteText:SetPoint("TOPRIGHT", GUI.contentFrame, "TOPRIGHT", -16, -16)
        noteText:SetJustifyH("LEFT")
        noteText:SetWordWrap(true)
        noteText:SetText(L["Nothing on this page matches. Press Enter to go to a page that does."])
    end
    if noteText then noteText:SetShown(show) end
end

-- What the page list shows: changes only when the set of listed pages does.
local function NavSig()
    if not F.active then return "off" end
    if not F.any then return "none" end
    local names = {}
    for name in pairs(F.pageHit) do names[#names + 1] = name end
    table.sort(names)
    return table.concat(names, ",")
end

-- ★ A KEYSTROKE'S WHOLE COST, and it is kept small on purpose (the first version
-- re-laid the list, swept and re-laid the page twice, and could switch pages,
-- on every key):
--   * the answer is computed once per query (MemoKey);
--   * the page list is laid out again only when the set of listed pages moved;
--   * the page on screen is marked, and laid out ONCE, only when a mark moved;
--   * the page on screen is never switched while typing (Enter does that).
-- `moved` is kept for callers that know the registry under the answer changed.
function Search:RefreshFilter(moved)
    local before = F.navDrawn
    if F.text ~= "" then self:_FilterCompute() else Deactivate() end
    local after = NavSig()
    if after ~= before or moved then
        F.navDrawn = after
        if GUI.UpdateTabLayout then GUI:UpdateTabLayout() end
    end
    local cur = GUI.CurrentPageName
    local page = cur and GUI.Pages and GUI.Pages[cur]
    if page then
        local ok, changed = pcall(self._FilterPage, self, page, PageDB(page))
        if not ok then
            geterrorhandler()(changed)
        elseif changed and page.RefreshStates then
            page:RefreshStates()
            -- A narrowed page is shorter: start it at the top.
            if rawget(page, "SetVerticalScroll") or (type(page.SetVerticalScroll) == "function") then
                pcall(page.SetVerticalScroll, page, 0)
            end
        end
    end
    self:_FilterNote()
end

-- Enter in the box: when the page on screen has nothing matching, go to the
-- first listed page that does.
function Search:FilterJump()
    if F.active and F.any then MoveOffEmptyPage() end
end

-- Focus on the box: get the view's index built before the first letter, as a
-- query would (budgeted, never in combat), so typing finds it ready.
function Search:WarmFilterIndex()
    if InCombatLockdown() or not GUI.Tabs then return end
    local inView = ViewPages()
    self:IncludeScopedPages(inView)
    self:TryReuseRegistry()
    if (self:RegistryIsStale() or self.RegistryBuilding) and not (self.RegistryBuilding and F.waitToken == self._buildToken) then
        self:EnsureRegistryAsync(function(ok)
            F.waitToken = nil
            if ok then
                self:_MatchIndex()
                if F.text ~= "" then self:RefreshFilter(true) end
            end
        end)
        F.waitToken = self._buildToken
    elseif self._MatchIndex then
        self:_MatchIndex()
    end
end

-- Every page a filter touched goes back as it was. Pages not on screen are put
-- right now (their marks cleared, their cards shut again) and laid out the next
-- time they are shown, which every page is on the way in.
function Search:ClearFilter()
    if self._filterTimer then self._filterTimer:Cancel(); self._filterTimer = nil end
    local had = F.text ~= "" or F.active
    F.text = ""
    Deactivate()
    F.navDrawn = nil
    for _, page in pairs(GUI.Pages or {}) do
        if page._dfFiltered then self:_UnfilterPage(page) end
    end
    local bar = F.bar
    if bar and bar.editbox and bar.editbox:GetText() ~= "" then
        bar.editbox:SetText("")
        bar.editbox:ClearFocus()
    end
    if had then
        if GUI.UpdateTabLayout then GUI:UpdateTabLayout() end
        local cur = GUI.CurrentPageName
        local page = cur and GUI.Pages and GUI.Pages[cur]
        if page and page.RefreshStates then page:RefreshStates() end
    end
    self:_FilterNote()
end

function Search:FilterActive()
    return F.active
end

function Search:SetFilterText(text)
    text = gsub(gsub(text or "", "^%s+", ""), "%s+$", "")
    if text == F.text then return end
    if text == "" then
        self:ClearFilter()
        return
    end
    F.text = text
    if self._filterTimer then return end
    self._filterTimer = C_Timer.NewTimer(FILTER_DEBOUNCE, function()
        self._filterTimer = nil
        if F.text ~= "" then self:RefreshFilter(true) end
    end)
end

-- The page list's box: the search's own bar, wired to the filter.
function Search:CreateFilterBar(parent)
    local bar = self:CreateSearchBar(parent, {
        onChange = function(text) Search:SetFilterText(text) end,
        onFocus  = function() Search:WarmFilterIndex() end,
        onEnter  = function() Search:FilterJump() end,
    })
    F.bar = bar
    return bar
end

-- ★ A "SHOW ME" LINK CLEARS THE FILTER FIRST. A link lands on a section and
-- flashes it; under a filter that section may be one the filter took off the
-- page. Every settings link goes through here (cross-links, Home's results).
do
    local baseLink = GUI.LinkToSetting
    if type(baseLink) == "function" then
        GUI.LinkToSetting = function(self, target)
            if F.text ~= "" or F.active then Search:ClearFilter() end
            return baseLink(self, target)
        end
    end
end
