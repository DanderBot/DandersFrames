-- ☠ Companion addon: take the parent's table from the global it publishes
-- (see the same note at the head of Features/Search.lua).
local DF = DandersFrames
local Search = DF.Search

local pairs, ipairs, type, rawget, tostring = pairs, ipairs, type, rawget, tostring
local sort, concat = table.sort, table.concat

-- ============================================================
-- SETTINGS SEARCH -- THE PREBUILT INDEX
-- The page list's filter has to know what is on every page in view, and the
-- only live source of that is the page's own build: real frames, one page at a
-- time. Building every page the first time the box took focus was a stutter of
-- page builds. So the filter reads a PREBUILT index instead
-- (Features/SearchIndexData.lua, generated -- see its header), and a page's
-- live entries take over from its prebuilt ones as soon as the page is built:
-- clicking into the box builds nothing.
--
-- ★ LIVE WINS. Search:_FilterSource lists, per page in view, the entries of
-- the page's current build when it has one (exact: the real widgets, the
-- current mode, anything dynamic), else the prebuilt rows. A row the generator
-- did not see (drift) is found the moment its page is built; /df debug
-- searchdrift lists live entries the prebuilt index lacks.
--
-- ★ TRANSLATED AT RUNTIME. The data holds the English L[...] keys. A key is
-- looked up with rawget, never L[key]: AceLocale reports every missing key as an
-- error, and a stripped tooltip or a label built at runtime is not a key. A miss
-- reads as the English text, which is what the key is.
-- ============================================================

local L = DF.L

local function Loc(s)
    if type(s) ~= "string" or s == "" then return nil end
    local v = L and rawget(L, s)
    if type(v) == "string" and v ~= "" then return v end
    return s
end

local cache = {}   -- page name -> entries

-- The prebuilt entries for one page, made on first use and kept.
function Search:PrebuiltEntries(name)
    local data = self.PrebuiltIndex
    local rows = data and data.P and data.P[name]
    if not rows then return nil end
    local list = cache[name]
    if list then return list end
    local S, C = data.S, data.C
    local GUI = DF.GUI
    local page = GUI and GUI.Pages and GUI.Pages[name]
    local tabLabel = page and (page.searchTabLabel or page.tabLabel) or nil
    list = {}
    for i = 1, #rows, 6 do
        local labelEn = S[rows[i]]
        local titleEn = rows[i + 1] ~= 0 and S[rows[i + 1]] or nil
        local key = rows[i + 2] ~= 0 and S[rows[i + 2]] or nil
        local tipEn = rows[i + 3] ~= 0 and S[rows[i + 3]] or nil
        local cond = rows[i + 4] ~= 0 and C[rows[i + 4]] or nil
        local isTitle = rows[i + 5] == 1
        list[#list + 1] = {
            label = Loc(labelEn), labelEn = labelEn,
            section = Loc(titleEn),
            dbKey = key,
            searchKey = isTitle and ("section:" .. tostring(labelEn)) or nil,
            isSection = isTitle or nil,
            tooltipText = Loc(tipEn),
            shownWhen = cond,
            tab = name, tabLabel = tabLabel,
            prebuilt = true,
        }
    end
    cache[name] = list
    return list
end

-- "Only shown when", from the generator's record: alternatives of key = value
-- sets. Read against the page's own table; a key that table does not have means
-- the condition cannot be judged here, and the row counts as shown.
function Search:PrebuiltShown(entry, db)
    local cond = entry and entry.shownWhen
    if not cond or type(db) ~= "table" then return true end
    for _, alt in ipairs(cond) do
        local all = true
        for i = 1, #alt, 2 do
            local v = db[alt[i]]
            if v == nil then return true end
            if v ~= alt[i + 1] then all = false break end
        end
        if all then return true end
    end
    return false
end

-- ★ WHAT THE FILTER SEARCHES, for the pages in view: each page's live entries
-- when it has a current build, else its prebuilt ones. The same list (the same
-- table) comes back while nothing about it changed, so its word index is kept;
-- a page built since makes a new list and the index starts again, in slices.
-- Never builds a page.
function Search:_FilterSource(inView)
    local GUI = DF.GUI
    local names = {}
    for name in pairs(inView) do names[#names + 1] = name end
    sort(names)
    local parts, lists = {}, {}
    for _, name in ipairs(names) do
        local page = GUI.Pages and GUI.Pages[name]
        local live = page and page.GetIndexEntries and page:GetIndexEntries()
        if live then
            parts[#parts + 1] = name .. "=" .. tostring(live)
            lists[#lists + 1] = live
        else
            local pre = self:PrebuiltEntries(name)
            if pre then
                parts[#parts + 1] = name .. "=p"
                lists[#lists + 1] = pre
            end
        end
    end
    local sig = concat(parts, ",")
    local src = self._filterSourceCache
    if src and src.sig == sig then return src.list end
    local list = {}
    for _, l in ipairs(lists) do
        for _, e in ipairs(l) do list[#list + 1] = e end
    end
    self._filterSourceCache = { sig = sig, list = list }
    return list
end

-- ★ DRIFT, for the developer (/df debug searchdrift): every page that has a live
-- build is compared with its prebuilt rows, and live settings the prebuilt index
-- does not hold are listed (by key, or by label for a keyless control). Returns
-- { [page] = { "key or label", ... } } and the total.
function Search:PrebuiltDrift()
    local GUI = DF.GUI
    local data = self.PrebuiltIndex
    local out, total = {}, 0
    if not (GUI and GUI.Pages and data) then return out, 0 end
    for name, page in pairs(GUI.Pages) do
        local live = page.GetIndexEntries and page:GetIndexEntries() or rawget(page, "_searchEntries")
        if type(live) == "table" and #live > 0 then
            local have = {}
            for _, e in ipairs(self:PrebuiltEntries(name) or {}) do
                if e.dbKey then have["k:" .. e.dbKey] = true end
                if e.labelEn then have["l:" .. e.labelEn] = true end
                if e.label then have["l:" .. e.label] = true end
            end
            for _, e in ipairs(live) do
                local missing
                if type(e.dbKey) == "string" then
                    missing = not have["k:" .. e.dbKey] and e.dbKey or nil
                elseif type(e.label) == "string" then
                    missing = not have["l:" .. e.label] and e.label or nil
                end
                if missing then
                    out[name] = out[name] or {}
                    out[name][#out[name] + 1] = missing
                    total = total + 1
                end
            end
        end
    end
    return out, total
end

-- The /df debug command's body: one line per page with drift, through the
-- addon's debug console. Developer output only.
function Search:ReportPrebuiltDrift()
    local data = self.PrebuiltIndex
    if not data then
        DF:Say("Search: no prebuilt index loaded.")
        return
    end
    local out, total = self:PrebuiltDrift()
    DF:Say(string.format("Search: prebuilt index %s (%s), %d rows; %d live settings missing from it.",
        tostring(data.version), tostring(data.commit):sub(1, 8), data.rows or 0, total))
    local names = {}
    for name in pairs(out) do names[#names + 1] = name end
    sort(names)
    for _, name in ipairs(names) do
        DF:Say(string.format("  %s: %s", name, concat(out[name], ", ")))
    end
    return out, total
end
