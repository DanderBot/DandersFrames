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
    local tab = entry.tab
    local db = dbByTab[tab]
    if db == nil then
        db = PageDB(GUI.Pages and GUI.Pages[tab]) or false
        dbByTab[tab] = db
    end
    -- A prebuilt row has no widget: its generator recorded the condition.
    if entry.prebuilt then
        return Search:PrebuiltShown(entry, db or nil)
    end
    local w = entry.sourceWidget
    if type(w) ~= "table" then return true end
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
    local src = F.source
    local ix = Search._filterIndex
    return F.text .. "|" .. sig .. "|" .. tostring(GUI.SelectedMode) .. "|"
        .. tostring(src) .. "|" .. tostring(ix and ix.n or 0)
end

function Search:_FilterCompute()
    if F.text == "" then Deactivate() return true end

    local inView, sig = ViewPages()
    F.inView = inView
    local viewMoved = (sig ~= F.viewSig)
    F.viewSig = sig
    -- ★ NO PAGE IS BUILT HERE, EVER. What the filter searches is each page's
    -- live entries when it has a current build, else its prebuilt ones
    -- (Features/SearchPrebuilt.lua). Building every page in view the first time
    -- the box took focus was the stutter on clicking into it.
    F.source = self:_FilterSource(inView)
    if F.memo and F.memo == MemoKey(sig) then
        return true, viewMoved
    end
    local compiled = self:CompileQuery(F.text, F.source, "_filterIndex")
    if not compiled then Deactivate() return true, viewMoved end
    -- The word index fills in slices: until it has everything, the answer is
    -- what it holds so far (and is asked again as it grows).
    F.partial = not (compiled.index and compiled.index.complete)

    F.gen = F.gen + 1
    F.keepCache = {}
    dbByTab = {}
    F.compiled = compiled
    F.pageWhole = {}
    F.indexed = compiled.index and compiled.index.indexed or nil
    F.hit = self:MatchEntries(compiled, function(e) return e.tab ~= nil and inView[e.tab] == true end)

    local pageHit, pageWhole = {}, {}
    -- Pages whose own name matches show whole (asked first: the dry run reads it).
    for name in pairs(inView) do
        local label, spaced = PageTexts(GUI.Pages[name], name)
        if self:TextMatchesAll(compiled, { { label, literal = true }, { spaced, literal = true } }) then
            pageWhole[name] = true
            pageHit[name] = true
        end
    end
    F.pageWhole = pageWhole
    local candidate = {}
    for entry in pairs(F.hit) do
        if not candidate[entry.tab] and EntryWouldShow(entry) then candidate[entry.tab] = true end
    end
    -- The page on screen is always asked, hit or not: a title match on it
    -- shows things the hit list does not hold.
    local cur = GUI.CurrentPageName
    local curPage = cur and inView[cur] and GUI.Pages[cur]
    if curPage and type(curPage.children) == "table" and #curPage.children > 0 then candidate[cur] = true end
    -- ★ LISTED ONLY WHEN THE PAGE WOULD SHOW SOMETHING: the same decision the
    -- page pass makes (_FilterPage, dry), on the page's own widgets. A page with
    -- no build to ask (its entries came from a build that is not on it) keeps
    -- the entry-level answer.
    for tab in pairs(candidate) do
        local page = GUI.Pages and GUI.Pages[tab]
        local kids = page and page.children
        if type(kids) == "table" and #kids > 0 then
            local ok, shows = pcall(self._FilterPage, self, page, PageDB(page), true)
            if not ok then geterrorhandler()(shows) end
            if ok and shows then pageHit[tab] = true end
        else
            pageHit[tab] = true
        end
    end
    F.pageHit, F.pageWhole = pageHit, pageWhole
    F.any = next(pageHit) ~= nil
    if F.partial and not F.any then
        Deactivate()
        F.partial = true
        return false, viewMoved
    end
    F.active = true
    F.memo = (not F.partial) and MemoKey(sig) or nil
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
    -- Cards re-folded over a filtered body get their outline back, now that
    -- every body's mark is cleared.
    for _, w in ipairs(page.children or {}) do
        if type(w) == "table" and rawget(w, "dfFoldBodyHidden") then
            rawset(w, "dfFoldBodyHidden", nil)
            if w.ShowFold then w:ShowFold() end
        end
    end
    page._dfFiltered = nil
    return true
end

local function SameCol(a, b)
    return a == b or a == "both" or b == "both"
end

-- Marks the page; returns true when any mark moved (so a relayout is due).
-- ★ `dry`: decide, mark nothing, and answer whether ANYTHING on the page would
-- be left showing. The page list asks this of every page it would list, so a
-- page is listed exactly when this pass would leave something on it -- the
-- list and the page cannot disagree (a page listed with nothing on it was the
-- 2026-11-24 report: a unit frame's Frame page listed for "move").
function Search:_FilterPage(page, db, dry)
    local name = page.tabName
    if dry then
        if F.pageWhole[name] or PageHasFill(page) then return true end
    elseif not (F.active and name and F.inView[name]) or F.pageWhole[name] or PageHasFill(page) then
        -- Not narrowed: either no filter is on (nothing to say), or the page
        -- shows whole (its name matched, or it is a designer) -- it shows.
        -- ★ A FILTER WITH NO MATCH ANYWHERE STILL NARROWS: the page then shows
        -- the note and nothing else, never its settings under "nothing matches".
        page._dfShows = (F.active and name and F.inView[name]) and true or nil
        if page._dfFiltered then return self:_UnfilterPage(page) end
        return false
    end
    local moved = false
    local anyShown = false
    local dryHidden = dry and {} or nil
    if not dry then
        moved = not page._dfFiltered
        page._dfFiltered = true
    end
    local keepCache = F.keepCache or {}
    F.keepCache = keepCache
    local function Mark(w, hidden)
        if dry then
            dryHidden[w] = hidden or false
        elseif rawget(w, "dfFilterHidden") ~= hidden then
            rawset(w, "dfFilterHidden", hidden)
            moved = true
        end
    end
    local function IsHidden(w)
        if dry then return dryHidden[w] == true end
        return rawget(w, "dfFilterHidden") and true or false
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
    -- `forced`: the control sits under a header whose title matched, so it is
    -- kept like any control in a card whose title matched.
    local function Keep(w, section, forced)
        if not (forced or Matches(w, section)) then return false end
        return not CondHidden(w, db)
    end

    -- A box: decide its rows (headers inside it follow the rows under them), mark
    -- them, and say whether anything is left.
    local function DecideGroup(g, section, forced)
        local kids = rawget(g, "groupChildren") or {}
        local keep, any = {}, false
        for j, e in ipairs(kids) do
            local cw = e.widget
            if type(cw) == "table" and not rawget(cw, "isSectionHeader") then
                local k
                if rawget(cw, "groupChildren") then
                    k = not CondHidden(cw, db) and DecideGroup(cw, section, forced)
                else
                    k = Keep(cw, section, forced)
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
        if g.SetChildFiltered and not dry then
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

    -- ★ A BARE HEADER WHOSE TITLE MATCHES shows what it heads, the way a card
    -- whose title matches shows the whole card: "movement" finds the Movement
    -- header and so the Permanent Mover card under it. What it heads: the
    -- widgets after it in its own column, up to the next bare header there.
    local underMatched = {}
    do
        local cur = {}
        for _, w in ipairs(children) do
            if type(w) == "table" and not rawget(w, "settingsGroup") then
                local col = rawget(w, "layoutCol") or 1
                if rawget(w, "isSectionHeader") then
                    local gt = rawget(w, "GetText")
                    local title = (type(gt) == "function" and gt(w)) or rawget(w, "title")
                    local m = type(title) == "string" and not CondHidden(w, db) and CardMatched({ sectionTitleText = title })
                    if col == "both" then cur[1], cur[2] = m, m else cur[col] = m end
                else
                    local m
                    if col == "both" then m = cur[1] or cur[2] else m = cur[col] end
                    if m then underMatched[w] = true end
                end
            end
        end
    end
    for _, w in ipairs(children) do
        if type(w) == "table" and not rawget(w, "settingsGroup") then
            local hidden = nil
            local section = rawget(w, "collapsibleSection")
            local later = rawget(w, "sectionChildren") or rawget(w, "isSectionHeader")
            if later or rawget(w, "rightAlign") or rawget(w, "isSyncPoint") then
                hidden = nil   -- decided below (cards, headers), or never filtered
            elseif rawget(w, "isPageFooter") then
                hidden = true
            elseif type(section) == "table" and CondHidden(section, db) then
                -- Inside a card that is not drawn at all (a card filtered off a
                -- unit frame's page hides on Never): nothing in it can show.
                hidden = true
            elseif rawget(w, "isSettingsGroup") then
                local any = not CondHidden(w, db) and DecideGroup(w, section, underMatched[w])
                if any then
                    if section then cardKept[section] = true end
                else
                    hidden = true
                end
            elseif Keep(w, section, underMatched[w]) then
                if section then cardKept[section] = true end
            else
                hidden = true
            end
            -- Cards and headers are marked once, below: marking them shown here and
            -- hidden there would count as a change on every pass.
            if not later then
                Mark(w, hidden)
                if not hidden and not (rawget(w, "rightAlign") or rawget(w, "isSyncPoint"))
                    and not CondHidden(w, db) then
                    anyShown = true
                end
            end
        end
    end

    -- Cards: kept when anything in them is (or their title matches), and opened
    -- for the search when shut.
    -- A card's header tick is one of its controls: a match on it keeps the card.
    -- A card hidden by its own condition keeps nothing, whatever matched in it.
    for _, w in ipairs(children) do
        if type(w) == "table" and rawget(w, "sectionChildren") then
            local tick = rawget(w, "headerToggle")
            local keep = not CondHidden(w, db) and (cardKept[w] or CardMatched(w) or underMatched[w]
                or (type(tick) == "table" and Matches(tick, nil)))
            if keep then
                Mark(w, nil)
                anyShown = true
                if not dry then
                    -- ★ OPENED ONLY OVER ROWS THAT SHOW. A card kept by its header
                    -- tick alone ("show", "hide") has nothing left in its body: it
                    -- shows as its header, not opened -- an opened card over a body
                    -- the filter took away was a tall empty panel.
                    local body = rawget(w, "cardBody")
                    local bodyHidden = type(body) == "table" and IsHidden(body) or false
                    if bodyHidden then
                        if RestoreCard(w) then moved = true end
                    elseif OpenCard(w) then
                        moved = true
                    end
                    -- The card's outline follows its body (SettingsWidgets'
                    -- _ApplyCardFold reads the body's mark): re-fold it whenever
                    -- that mark moved, before this pass lays the page out.
                    if (rawget(w, "dfFoldBodyHidden") or false) ~= bodyHidden then
                        rawset(w, "dfFoldBodyHidden", bodyHidden or nil)
                        if w.ShowFold then w:ShowFold() end
                        moved = true
                    end
                end
            else
                Mark(w, true)
                if not dry and RestoreCard(w) then moved = true end
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
                            and not IsHidden(w) then
                            keep = true
                            break
                        end
                    end
                end
            end
            Mark(h, (not keep) or nil)
        end
    end
    if dry then return anyShown end
    -- ★ WHAT THIS PASS LEFT SHOWING is the one answer the note reads
    -- (Search:_FilterNote) -- never the page list's earlier verdict, which is
    -- worked out ahead of the page from the index and can differ from what the
    -- page's live widgets keep.
    -- A page with no widgets yet (never built) has not been looked at: no answer.
    if #children > 0 then page._dfShows = anyShown else page._dfShows = nil end
    return moved
end

GUI.FilterPagePass = function(page, db)
    local ok, err = pcall(Search._FilterPage, Search, page, db)
    if not ok and err then geterrorhandler()(err) end
    if page and page.tabName and page.tabName == GUI.CurrentPageName and Search._FilterNote then
        Search:_ReconcileCurrentPage(page)
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
    local page = cur and GUI.Pages and GUI.Pages[cur]
    -- Shown exactly when the page's own pass left nothing showing on it.
    local show = F.active and cur and F.inView[cur] and page
        and rawget(page, "_dfShows") == false and true or false
    if show and not noteText and GUI.contentFrame then
        noteText = GUI.contentFrame:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
        noteText:SetPoint("TOPLEFT", GUI.contentFrame, "TOPLEFT", 16, -16)
        noteText:SetPoint("TOPRIGHT", GUI.contentFrame, "TOPRIGHT", -16, -16)
        noteText:SetJustifyH("LEFT")
        noteText:SetWordWrap(true)
        noteText:SetText(L["Nothing on this page matches."])
    end
    if noteText then noteText:SetShown(show) end
end

-- The page on screen, after its own pass: the page list's verdict on it follows
-- what the pass left showing, so the list, the note and the page cannot
-- disagree. (The list decides ahead of the page from the index; a page whose
-- live widgets keep more, or less, than its index rows -- a page searched from
-- prebuilt rows while open, a title that matched -- is corrected here.)
local navFixQueued
function Search:_ReconcileCurrentPage(page)
    if not F.active then return end
    local name = page and page.tabName
    if not (name and F.inView[name]) then return end
    local shows = rawget(page, "_dfShows")
    if shows == nil or (F.pageHit[name] and true or false) == shows then return end
    F.pageHit[name] = shows or nil
    F.any = next(F.pageHit) ~= nil
    if navFixQueued or not GUI.UpdateTabLayout then return end
    navFixQueued = true
    -- Out of the page's own layout pass: the list is laid out on the next frame.
    C_Timer.After(0, function()
        navFixQueued = nil
        F.navDrawn = nil
        if GUI.UpdateTabLayout then GUI:UpdateTabLayout() end
    end)
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
        self:_ReconcileCurrentPage(page)
    end
    self:_FilterNote()
end

-- ★ GROWTH: the index build landed more pages, or the word index took another
-- slice. Re-answer, at most every PROGRESS_EVERY seconds (a build reports every
-- frame). Home's results re-run once the word index is complete.
local PROGRESS_EVERY = 0.15
local function QueueProgressRefresh()
    if F.progressQueued then return end
    F.progressQueued = true
    C_Timer.After(PROGRESS_EVERY, function()
        F.progressQueued = nil
        if F.text ~= "" then Search:RefreshFilter(false) end
    end)
end
function Search:_OnIndexProgress(complete, slot)
    if slot == "_filterIndex" then
        QueueProgressRefresh()
    elseif complete and self.RefreshIfActive then
        -- The live registry's index (Home's results) finished: re-run them.
        self:RefreshIfActive()
    end
end

-- Focus on the box, or the window opening: start the word index over what the
-- filter searches, in slices. Builds no page.
function Search:WarmFilterIndex()
    if not (GUI.Tabs and GUI.Pages) then return end
    local inView = ViewPages()
    F.source = self:_FilterSource(inView)
    self:_MatchIndexFor(F.source, "_filterIndex", self.INDEX_SLICE_MS)
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
    })
    F.bar = bar
    if parent and type(parent.HookScript) == "function" then
        parent:HookScript("OnShow", function()
            C_Timer.After(1, function()
                if parent:IsVisible() then Search:WarmFilterIndex() end
            end)
        end)
    end
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
